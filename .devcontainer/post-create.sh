#!/usr/bin/env bash

set -euo pipefail

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    libssl-dev \
    pkg-config

if ! command -v rustup >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
fi

export PATH="$HOME/.cargo/bin:$PATH"

rustup default stable
rustup component add clippy rustfmt

julia --project -e 'using Pkg; Pkg.instantiate(); Pkg.build("RustCall")'
