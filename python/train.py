"""Train ResNet-8 (TF 1.x) on CAMUS 2CH vs 4CH -> build/float_params.npz."""
import numpy as np
import tensorflow as tf

from data import BN_EPS, BUILD, DATA, SIZE

EPOCHS, BATCH, LR = 40, 32, 1e-3
JITTER = 6  # augmentation: random translation of up to +-JITTER px


def conv_bn(x, k, c_out, stride, name, training, relu=True):
    pad = (k - 1) // 2  # symmetric, as the accelerator pads; tf 'same' pads stride 2 asymmetrically
    if pad:
        x = tf.pad(x, [[0, 0], [pad, pad], [pad, pad], [0, 0]])
    x = tf.layers.conv2d(x, c_out, k, stride, 'valid', use_bias=False, name=name + '_conv',
                         kernel_initializer=tf.initializers.he_normal())
    x = tf.layers.batch_normalization(x, epsilon=BN_EPS, training=training, name=name + '_bn')
    return tf.nn.relu(x) if relu else x


def resnet8(x, training):
    x = conv_bn(x, 3, 16, 2, 'stem', training)
    for i, (ch, s) in enumerate([(16, 1), (32, 2), (64, 2)], 1):
        h = conv_bn(x, 3, ch, s, 'b%dc1' % i, training)
        h = conv_bn(h, 3, ch, 1, 'b%dc2' % i, training, relu=False)
        sc = x if s == 1 else conv_bn(x, 1, ch, s, 'b%dsc' % i, training, relu=False)
        x = tf.nn.relu(h + sc)
    return tf.layers.dense(tf.reduce_mean(x, [1, 2]), 2, name='fc')


def augment(xb, rng):
    p = np.pad(xb, ((0, 0), (JITTER, JITTER), (JITTER, JITTER), (0, 0)), 'constant')
    o = rng.randint(0, 2 * JITTER + 1, (len(xb), 2))
    return np.stack([p[i, a:a + SIZE, b:b + SIZE] for i, (a, b) in enumerate(o)])


def main():
    d = np.load(str(DATA / 'camus112.npz'))
    x = d['x'].astype(np.float32)[..., None] / 255
    y, split = d['y'].astype(np.int32), d['split']
    tr, va, te = (np.where(split == s)[0] for s in range(3))
    rng = np.random.RandomState(0)
    tf.set_random_seed(0)

    x_ph = tf.placeholder(tf.float32, [None, SIZE, SIZE, 1])
    y_ph = tf.placeholder(tf.int32, [None])
    training = tf.placeholder(tf.bool)
    logits = resnet8(x_ph, training)
    loss = tf.losses.sparse_softmax_cross_entropy(y_ph, logits)
    correct = tf.reduce_sum(tf.cast(tf.equal(tf.argmax(logits, 1, output_type=tf.int32), y_ph), tf.int32))
    step = tf.train.get_or_create_global_step()
    lr = tf.train.cosine_decay(LR, step, EPOCHS * (len(tr) // BATCH))
    with tf.control_dependencies(tf.get_collection(tf.GraphKeys.UPDATE_OPS)):
        train_op = tf.train.AdamOptimizer(lr).minimize(loss, step)

    def acc(sess, idx):
        return sum(sess.run(correct, {x_ph: x[idx[i:i + 100]], y_ph: y[idx[i:i + 100]], training: False})
                   for i in range(0, len(idx), 100)) / len(idx)

    BUILD.mkdir(exist_ok=True)
    ckpt = str(BUILD / 'best.ckpt')
    saver = tf.train.Saver()
    best = -1
    with tf.Session() as sess:
        sess.run(tf.global_variables_initializer())
        for ep in range(EPOCHS):
            perm = rng.permutation(tr)
            for i in range(0, len(perm) - BATCH + 1, BATCH):
                b = perm[i:i + BATCH]
                sess.run(train_op, {x_ph: augment(x[b], rng), y_ph: y[b], training: True})
            v = acc(sess, va)
            print('epoch %d val acc %.3f' % (ep + 1, v), flush=True)
            if v > best:
                best = v
                saver.save(sess, ckpt)
        saver.restore(sess, ckpt)
        print('best val acc %.3f, test acc %.3f' % (best, acc(sess, te)))
        keep = tf.trainable_variables() + [v for v in tf.global_variables() if 'moving_' in v.name]
        np.savez(str(BUILD / 'float_params.npz'), **{v.name[:-2]: val for v, val in zip(keep, sess.run(keep))})


if __name__ == '__main__':
    main()
