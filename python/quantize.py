"""Fold BN, post-training int8 quantization (symmetric, per-tensor), evaluate -> build/quant.npz.

The numpy int8 forward here is bit-exact to what the C code / accelerator must compute:
  acc(int32) = sum(x_q * w_q) + b_q;  y_q = clip((acc * m0 + 2^(shift-1)) >> shift, 0, 127)
Residual add: both branches are requantized to the block-output scale, summed, then ReLU-clipped.
"""
import numpy as np

from data import BN_EPS, BUILD, DATA

MULT_BITS = 16  # requant multiplier m0 width; observed |acc| < 2^17 on the test set, so acc * m0 fits one 27x18 DSP48E2
PCT = 100       # activation range = this percentile of |x| over the calibration set (100 = max)
N_CALIB, N_GOLD = 256, 4

# name, source tensor, destination tensor, stride, pad  (tensor names = tap names below)
CONVS = [('stem', 'in', 'stem', 2, 1),
         ('b1c1', 'stem', 'b1h', 1, 1), ('b1c2', 'b1h', 'b1', 1, 1),
         ('b2c1', 'b1', 'b2h', 2, 1), ('b2c2', 'b2h', 'b2', 1, 1), ('b2sc', 'b1', 'b2', 2, 0),
         ('b3c1', 'b2', 'b3h', 2, 1), ('b3c2', 'b3h', 'b3', 1, 1), ('b3sc', 'b2', 'b3', 2, 0)]


def fold(p, name):
    """conv + BN -> (w [K][C][FY][FX], b)"""
    g, be, mu, var = (p[name + '_bn/' + k] for k in ('gamma', 'beta', 'moving_mean', 'moving_variance'))
    s = g / np.sqrt(var + BN_EPS)
    return p[name + '_conv/kernel'].transpose(3, 2, 0, 1) * s[:, None, None, None], be - mu * s


def conv(x, w, stride, pad):
    """x [N][C][H][W], w [K][C][FY][FX]. float64 keeps int8 inputs exact (partial sums < 2^53)."""
    x = np.pad(x, ((0, 0), (0, 0), (pad, pad), (pad, pad)), 'constant')
    oh, ow = (x.shape[2] - w.shape[2]) // stride + 1, (x.shape[3] - w.shape[3]) // stride + 1
    out = 0
    for i in range(w.shape[2]):
        for j in range(w.shape[3]):
            out = out + np.einsum('kc,nchw->nkhw', w[:, :, i, j],
                                  x[:, :, i:i + stride * oh:stride, j:j + stride * ow:stride], optimize=True)
    return out


def fwd_float(P, fc, x):
    """x [N][1][H][W] in [0,1] -> logits, taps"""
    c = lambda n, a, s, p: conv(a, P[n][0], s, p) + P[n][1][None, :, None, None]
    relu = lambda a: np.maximum(a, 0)
    t = {'in': x}
    a = t['stem'] = relu(c('stem', x, 2, 1))
    for i in (1, 2, 3):
        s = 1 if i == 1 else 2
        h = t['b%dh' % i] = relu(c('b%dc1' % i, a, s, 1))
        sc = a if i == 1 else c('b%dsc' % i, a, 2, 0)
        a = t['b%d' % i] = relu(c('b%dc2' % i, h, 1, 1) + sc)
    return a.mean((2, 3)) @ fc[0].T + fc[1], t


def multiplier(m):
    """m ~ m0 / 2^shift with m0 in [2^(B-1), 2^B)"""
    shift = MULT_BITS - 1 - int(np.floor(np.log2(m)))
    m0 = int(round(m * 2.0 ** shift))
    if m0 == 2 ** MULT_BITS:
        m0, shift = m0 >> 1, shift - 1
    assert shift >= 1, 'requant factor %g too large' % m
    return m0, shift


def quant_layer(w, b, s_src, s_dst, stride=0, pad=0):
    sw = np.abs(w).max() / 127
    bq = np.round(b / (s_src * sw))
    assert np.abs(bq).max() < 2 ** 31
    m0, sh = multiplier(s_src * sw / s_dst)
    return dict(w=np.clip(np.round(w / sw), -127, 127).astype(np.int8), b=bq.astype(np.int32),
                m0=m0, sh=sh, stride=stride, pad=pad)


def requant(acc, m0, sh):
    return (acc.astype(np.int64) * m0 + (1 << (sh - 1))) >> sh


def fwd_int(Q, x, wide=False):
    """x int8 [N][1][H][W] -> logits (int32 accumulators, argmax is the class), taps
    wide: also tap <layer>_acc (int32 accumulator) and <layer>_rq (requant before any clip), for hardware golden vectors"""
    def qc(n, a):
        q = Q[n]
        acc = np.rint(conv(a.astype(np.float64), q['w'].astype(np.float64), q['stride'], q['pad'])) + q['b'][None, :, None, None]
        y = requant(acc, q['m0'], q['sh'])
        if wide:
            t[n + '_acc'], t[n + '_rq'] = acc.astype(np.int64), y
        return y
    relu8 = lambda a: np.clip(a, 0, 127)
    t = {'in': x}
    a = t['stem'] = relu8(qc('stem', x))
    for i in (1, 2, 3):
        h = t['b%dh' % i] = relu8(qc('b%dc1' % i, a))
        sc = requant(a, Q['b1skip']['m0'], Q['b1skip']['sh']) if i == 1 else qc('b%dsc' % i, a)
        if wide and i == 1:
            t['b1skip_rq'] = sc
        a = t['b%d' % i] = relu8(qc('b%dc2' % i, h) + sc)
    pooled = a.astype(np.int64).sum((2, 3))  # global pool as a sum; the 1/pool_n is folded into fc_b
    return pooled @ Q['fc']['w'].T.astype(np.int64) + Q['fc']['b'], t


def batched(f, x, n=50):
    outs = [f(x[i:i + n]) for i in range(0, len(x), n)]
    return np.concatenate([o[0] for o in outs])


def main():
    p = np.load(str(BUILD / 'float_params.npz'))
    P = {n: fold(p, n) for n, *_ in CONVS}
    fc = (p['fc/kernel'].T, p['fc/bias'])
    d = np.load(str(DATA / 'camus112.npz'))
    x = d['x'].astype(np.float64)[:, None] / 255
    y, split = d['y'], d['split']
    cal = np.random.RandomState(0).permutation(np.where(split == 0)[0])[:N_CALIB]

    _, taps = fwd_float(P, fc, x[cal])
    S = {k: np.percentile(np.abs(v), PCT) / 127 for k, v in taps.items()}
    S['in'] = 1 / 127  # pixels/255 span [0,1]

    Q = {n: quant_layer(*P[n], S[src], S[dst], st, pd) for n, src, dst, st, pd in CONVS}
    Q['b1skip'] = dict(zip(('m0', 'sh'), multiplier(S['stem'] / S['b1'])))  # identity shortcut of block 1
    w = fc[0]
    sw = np.abs(w).max() / 127
    pool_n = taps['b3'].shape[2] * taps['b3'].shape[3]  # 14 x 14
    Q['fc'] = dict(w=np.clip(np.round(w / sw), -127, 127).astype(np.int8),
                   b=np.round(fc[1] * pool_n / (sw * S['b3'])).astype(np.int64))

    te = np.where(split == 2)[0]
    xq = np.round(x[te] / S['in']).astype(np.int8)
    f_acc = (batched(lambda a: fwd_float(P, fc, a), x[te]).argmax(1) == y[te]).mean()
    logits = batched(lambda a: fwd_int(Q, a), xq)
    q_acc = (logits.argmax(1) == y[te]).mean()
    f_logits = batched(lambda a: fwd_float(P, fc, a), x[te])
    print('test acc: float (BN folded) %.4f, int8 %.4f (target >= 0.90); float/int8 agree on %.4f of frames'
          % (f_acc, q_acc, (f_logits.argmax(1) == logits.argmax(1)).mean()))

    out = dict(pool_n=pool_n,scales=np.array([S[k] for k in sorted(S)]), scale_names=np.array(sorted(S)),
               test_x=xq, test_y=y[te], test_logits=logits.astype(np.int32), fc_w=Q['fc']['w'],
               fc_b=Q['fc']['b'].astype(np.int32), b1skip_m0=Q['b1skip']['m0'], b1skip_sh=Q['b1skip']['sh'])
    for n, *_ in CONVS:
        for k in ('w', 'b', 'm0', 'sh', 'stride', 'pad'):
            out['%s_%s' % (n, k)] = Q[n][k]
    for k, v in fwd_int(Q, xq[:N_GOLD])[1].items():
        out['gold_' + k] = v.astype(np.int8)
    np.savez(str(BUILD / 'quant.npz'), **out)


if __name__ == '__main__':
    main()
