# Ubuntu 22.04 is the last release that ships clang-14, which both the kernel
# analysis build and the analyzer itself require. Built and used by ../../setup.sh.
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang clang-14 llvm-14 llvm-14-dev libclang-14-dev lld-14 \
    bear make flex bison bc libelf-dev libssl-dev openssl dwarves zstd lz4 \
    xz-utils cpio rsync kmod python3 perl git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
