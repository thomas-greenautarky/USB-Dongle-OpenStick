FROM debian:bookworm

RUN dpkg --add-architecture arm64 && \
    apt-get update && apt-get install -y \
    binfmt-support \
    cpio \
    crossbuild-essential-arm64 \
    debootstrap \
    device-tree-compiler \
    dosfstools \
    e2fsprogs \
    android-sdk-libsparse-utils \
    git \
    kmod \
    libudev-dev:arm64 \
    parted \
    python3 \
    qemu-user-static \
    wget \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY . /build/

ENTRYPOINT ["/build/build.sh"]
