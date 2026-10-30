# TF 1.x environment (CPU). From the project root:
#   docker build -t radl-tf1 python
#   docker run --rm -v "${PWD}:/work" -w /work/python radl-tf1 python data.py --url <CAMUS zip/tar url>
#   ... python train.py ; python quantize.py ; python export.py
FROM tensorflow/tensorflow:1.15.5-py3
RUN pip install nibabel pillow
# aarch64 cross gcc for static board binaries (make -C c cross)
RUN apt-get update && apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
 && rm -rf /var/lib/apt/lists/*
