FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=clang
ENV CXX=clang++
ENV LANG=C.UTF-8

# ── Core build tools & LLVM/Clang toolchain ──────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        clang \
        lld \
        llvm \
        llvm-dev \
        libclang-rt-dev \
        afl++ \
        python3 \
        python3-pip \
        python3-venv \
        gdb \
        git \
        curl \
        wget \
        unzip \
        pkg-config \
        cmake \
        ninja-build \
        autoconf \
        automake \
        libtool \
    && rm -rf /var/lib/apt/lists/*

# ── pwndbg (GDB plugin for exploit-dev) ──────────────────────────────
RUN git clone --depth 1 https://github.com/pwndbg/pwndbg.git /opt/pwndbg \
    && cd /opt/pwndbg \
    && ./setup.sh

# ── Build ICU from source with ASan + coverage instrumentation ───────
ARG ICU_VERSION=release-76-1
RUN git clone --depth 1 --branch ${ICU_VERSION} \
        https://github.com/unicode-org/icu.git /opt/icu-src

RUN mkdir -p /opt/icu-build && cd /opt/icu-build \
    && /opt/icu-src/icu4c/source/configure \
        --prefix=/opt/icu-install \
        --enable-static \
        --disable-shared \
        --disable-tests \
        --disable-samples \
        CFLAGS="-fsanitize=address,fuzzer-no-link -fno-omit-frame-pointer -g -O1" \
        CXXFLAGS="-fsanitize=address,fuzzer-no-link -fno-omit-frame-pointer -g -O1" \
        LDFLAGS="-fsanitize=address" \
    && make -j$(nproc) \
    && make install

ENV ICU_HOME=/opt/icu-install
ENV ICU_SRC=/opt/icu-src

WORKDIR /app

# Container stays alive — Claude Code drives it via docker exec
CMD ["sleep", "infinity"]
