# TF 1.x environment (CPU). From the project root:
#   docker build -t radl-tf1 python
#   docker run --rm -v "${PWD}:/work" -w /work/python radl-tf1 python data.py --url <CAMUS zip/tar url>
#   ... python train.py ; python quantize.py ; python export.py
FROM tensorflow/tensorflow:1.15.5-py3
RUN pip install nibabel pillow
# ARMv7 hard-float cross gcc for static ZedBoard (Cortex-A9) binaries (make -C c cross)
RUN apt-get update && apt-get install -y --no-install-recommends gcc-arm-linux-gnueabihf libc6-dev-armhf-cross \
 && rm -rf /var/lib/apt/lists/*
