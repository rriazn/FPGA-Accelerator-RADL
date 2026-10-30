"""build/quant.npz -> build/export/: weights.h (C), *.mem + quant_pkg.vhd (VHDL), test vectors (.bin), golden/ (hardware testbenches).

Weight layout everywhere: int8 [K][C][FY][FX], row-major. Biases int32 [K].
"""
import numpy as np

from data import BUILD
from quantize import CONVS, MULT_BITS, fwd_int

OUT = BUILD / 'export'


def c_array(ctype, name, a):
    v = np.asarray(a).ravel()
    body = ',\n  '.join(', '.join(map(str, v[i:i + 16])) for i in range(0, v.size, 16))
    return 'static const %s %s[%d] = {\n  %s\n};\n' % (ctype, name, a.size, body)


def write_mem(path, a, bits):
    """one hex value per line, two's complement; bits = 8 or 32"""
    v = np.asarray(a).ravel()
    s = v.astype('<i%d' % (bits // 8))
    assert np.array_equal(s, v), 'value out of int%d range in %s' % (bits, path)
    path.write_text(''.join('%0*x\n' % (bits // 4, u) for u in s.view('<u%d' % (bits // 8))))


def blocked(a):
    """[C][H][W] -> hardware layout [C/L][H][W][L] (D3), L = 16, or 1 for the single-channel frame"""
    C, H, W = a.shape
    L = 1 if C == 1 else 16
    assert C % L == 0, 'channel count %d is not a multiple of 16' % C
    return a.reshape(C // L, L, H, W).transpose(0, 2, 3, 1)


def golden_hw(q):
    """Hardware golden vectors for frame 0 and the frame with the largest |acc| -> golden/f<frame>/"""
    Q = {n: {k: q['%s_%s' % (n, k)] for k in ('w', 'b')} for n, *_ in CONVS}
    for n, *_ in CONVS:
        Q[n].update({k: int(q['%s_%s' % (n, k)]) for k in ('m0', 'sh', 'stride', 'pad')})
    Q['b1skip'] = dict(m0=int(q['b1skip_m0']), sh=int(q['b1skip_sh']))
    Q['fc'] = dict(w=q['fc_w'], b=q['fc_b'].astype(np.int64))
    x = q['test_x']  # [N][1][H][W]
    logits, peak = [], []
    for i in range(0, len(x), 50):
        lg, t = fwd_int(Q, x[i:i + 50], wide=True)
        logits.append(lg)
        peak.append(np.max([np.abs(v).max((1, 2, 3)) for k, v in t.items() if k.endswith('_acc')], 0))
    assert np.array_equal(np.concatenate(logits), q['test_logits']), 'rebuilt int8 model differs from quant.npz'
    peak = np.concatenate(peak)
    for f in sorted({0, int(peak.argmax())}):
        _, t = fwd_int(Q, x[f:f + 1], wide=True)
        d = OUT / 'golden' / ('f%03d' % f)
        d.mkdir(parents=True, exist_ok=True)
        # per layer: input (int8), accumulator incl. bias (int32), requant before any clip (int32)
        for n, src, *_ in CONVS + [('b1skip', 'stem')]:
            write_mem(d / (n + '_in.mem'), blocked(t[src][0]), 8)
            if n != 'b1skip':
                write_mem(d / (n + '_acc.mem'), blocked(t[n + '_acc'][0]), 32)
            write_mem(d / (n + '_rq.mem'), blocked(t[n + '_rq'][0]), 32)
        print('golden vectors: test frame %d, max |acc| %d -> %s' % (f, peak[f], d))


def main():
    q = np.load(str(BUILD / 'quant.npz'))
    OUT.mkdir(exist_ok=True)
    h = ['#pragma once\n#include <stdint.h>\n',
         '/* y = clip((acc * M0 + (1 << (SHIFT-1))) >> SHIFT, 0, 127), acc = sum(x*w) + b (int32), %d-bit M0.\n'
         '   Block outputs: requant(conv2 acc) + requant(shortcut) then clip. Zero point is 0 everywhere. */\n'
         % MULT_BITS]
    vhd = ['package quant_pkg is\n']
    for n, _, _, stride, pad in CONVS:
        w, b = q[n + '_w'], q[n + '_b']
        N = n.upper()
        h.append('/* %s: [K][C][FY][FX] */\n' % n)
        h.append('#define %s_K %d\n#define %s_C %d\n#define %s_FY %d\n#define %s_FX %d\n'
                 % (N, w.shape[0], N, w.shape[1], N, w.shape[2], N, w.shape[3]))
        h.append('#define %s_STRIDE %d\n#define %s_PAD %d\n#define %s_M0 %d\n#define %s_SHIFT %d\n'
                 % (N, stride, N, pad, N, q[n + '_m0'], N, q[n + '_sh']))
        h.append(c_array('int8_t', n + '_w', w) + c_array('int32_t', n + '_b', b))
        write_mem(OUT / (n + '_w.mem'), w, 8)
        write_mem(OUT / (n + '_b.mem'), b, 32)
        vhd.append('  constant %s_M0    : natural := %d;\n  constant %s_SHIFT : natural := %d;\n'
                   % (N, q[n + '_m0'], N, q[n + '_sh']))
    h.append('#define B1SKIP_M0 %d\n#define B1SKIP_SHIFT %d  /* block 1 identity shortcut */\n'
             % (q['b1skip_m0'], q['b1skip_sh']))
    vhd.append('  constant B1SKIP_M0    : natural := %d;\n  constant B1SKIP_SHIFT : natural := %d;\n'
               % (q['b1skip_m0'], q['b1skip_sh']))
    h.append('/* fc: 64 -> 2 on the sum-pooled b3 output (sum over POOL_N = 14x14 positions, no division);\n'
             '   the 1/POOL_N is folded into fc_b. class = argmax of the int32 logits */\n#define POOL_N %d\n'
             % q['pool_n'])
    h.append(c_array('int8_t', 'fc_w', q['fc_w']) + c_array('int32_t', 'fc_b', q['fc_b']))
    vhd.append('end package;\n')
    # layers.txt: one row per layer for runtime loaders; b1skip is the identity shortcut of block 1
    rows = ['# name K C FY FX stride pad m0 shift  (weights: <name>_w.mem, biases: <name>_b.mem)\n']
    for n, _, _, stride, pad in CONVS:
        K, C, FY, FX = q[n + '_w'].shape
        rows.append('%s %d %d %d %d %d %d %d %d\n' % (n, K, C, FY, FX, stride, pad, q[n + '_m0'], q[n + '_sh']))
    rows.append('b1skip 0 0 0 0 0 0 %d %d\n' % (q['b1skip_m0'], q['b1skip_sh']))
    rows.append('fc 2 64 1 1 0 0 0 0\n')
    (OUT / 'layers.txt').write_text(''.join(rows))
    write_mem(OUT / 'fc_w.mem', q['fc_w'], 8)
    write_mem(OUT / 'fc_b.mem', q['fc_b'], 32)
    (OUT / 'weights.h').write_text(''.join(h))
    (OUT / 'quant_pkg.vhd').write_text(''.join(vhd))

    q['test_x'].tofile(str(OUT / 'test_x.bin'))              # int8 [N][112][112]
    q['test_y'].astype(np.uint8).tofile(str(OUT / 'test_y.bin'))  # 0 = 2CH, 1 = 4CH
    q['test_logits'].astype('<i4').tofile(str(OUT / 'test_logits.bin'))  # int32 [N][2]
    np.savez(str(OUT / 'golden.npz'), **{k: q[k] for k in q.files if k.startswith('gold_')})
    golden_hw(q)
    print('wrote', OUT)


if __name__ == '__main__':
    main()
