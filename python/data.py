"""CAMUS (official NIfTI release) -> data/camus112.npz.

python data.py --url <zip/tar url>     download + extract to data/raw, then build
python data.py [--raw <extracted dir>] build from an already extracted copy
"""
import argparse
import os
import tarfile
import urllib.request
import zipfile
from pathlib import Path

import nibabel as nib
import numpy as np
from PIL import Image

# shared constants
ROOT = Path(__file__).resolve().parent.parent
DATA, BUILD = ROOT / 'data', ROOT / 'build'
SIZE = 112            # input H = W; gives the plan's ~37.4 M MACs for ResNet-8
SPLIT = (400, 50, 50)  # patients: train / val / test
BN_EPS = 1e-3


def fetch(url, raw):
    raw.mkdir(parents=True, exist_ok=True)
    arc = raw / 'archive'
    urllib.request.urlretrieve(url, str(arc))
    if zipfile.is_zipfile(str(arc)):
        zipfile.ZipFile(str(arc)).extractall(str(raw))  # zipfile sanitizes member paths
    else:
        with tarfile.open(str(arc)) as t:
            for m in t.getmembers():  # tarfile does not
                if not str((raw / m.name).resolve()).startswith(str(raw.resolve()) + os.sep):
                    raise ValueError('unsafe path in archive: ' + m.name)
            t.extractall(str(raw))
    arc.unlink()


def build(raw):
    files = sorted(raw.rglob('patient*_[24]CH_E[DS].nii.gz'))
    assert len(files) == 2000, '%d ED/ES frames found in %s, expected 2000' % (len(files), raw)
    x, y, pid = [], [], []
    for f in files:
        patient, view, _ = f.name.split('.')[0].split('_')
        a = np.clip(np.squeeze(np.asarray(nib.load(str(f)).dataobj)), 0, 255).astype(np.uint8)
        x.append(np.asarray(Image.fromarray(a).resize((SIZE, SIZE), Image.BILINEAR)))
        y.append(view == '4CH')  # 0 = 2CH, 1 = 4CH
        pid.append(int(patient[len('patient'):]))
    x, y, pid = np.stack(x), np.array(y, np.uint8), np.array(pid)
    assert np.bincount(y).tolist() == [1000, 1000], 'expected 1000 frames per view'

    ids = np.random.RandomState(0).permutation(np.unique(pid))
    assert len(ids) == sum(SPLIT), '%d patients, expected %d' % (len(ids), sum(SPLIT))
    cuts = np.cumsum(SPLIT)
    split = np.zeros(len(pid), np.uint8)  # 0 train, 1 val, 2 test
    split[np.isin(pid, ids[cuts[0]:cuts[1]])] = 1
    split[np.isin(pid, ids[cuts[1]:])] = 2
    DATA.mkdir(exist_ok=True)
    np.savez_compressed(str(DATA / 'camus112.npz'), x=x, y=y, patient=pid, split=split)
    print('saved', x.shape, 'train/val/test frames:', np.bincount(split).tolist())


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--url')
    ap.add_argument('--raw', type=Path, default=DATA / 'raw')
    a = ap.parse_args()
    if a.url:
        fetch(a.url, a.raw)
    build(a.raw)
