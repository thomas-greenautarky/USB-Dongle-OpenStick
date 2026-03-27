FROM debian:bookworm

RUN apt-get update && apt-get install -y \
    binfmt-support \
    cpio \
    debootstrap \
    device-tree-compiler \
    dosfstools \
    e2fsprogs \
    android-sdk-libsparse-utils \
    git \
    kmod \
    parted \
    qemu-user-static \
    wget \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY . /build/

ENTRYPOINT ["/build/build.sh"]
