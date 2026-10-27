# A Linux environment matching the Ubuntu CI jobs (runner image ubuntu-26.04),
# for reproducing Linux-only failures such as the `:link_libpython` PyO3
# testsets, which need a linkable libpython (python3-dev).
#
#   docker build -t rustcall-ci .devcontainer/ubuntu-26.04
#   docker run --rm -it -v "$PWD":/src:ro rustcall-ci
#   # then, inside: git clone /src /work && cd /work
#
# Clone rather than build in the bind mount: a checkout builds into
# deps/<crate>/target, which the host's own build uses.
FROM ubuntu:26.04

ARG JULIA_VERSION=1.13.2
ARG RUST_VERSION=stable

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git pkg-config python3 python3-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://install.julialang.org | sh -s -- --yes --default-channel ${JULIA_VERSION}
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain ${RUST_VERSION}

ENV PATH=/root/.juliaup/bin:/root/.cargo/bin:${PATH}
