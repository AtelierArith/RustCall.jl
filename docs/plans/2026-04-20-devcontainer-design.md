# Devcontainer Design

**Date:** 2026-04-20

## Goal

Add a repository-scoped `.devcontainer` setup so contributors can open `RustCall.jl` in a VS Code dev container with Julia, Rust, and the package build prerequisites ready to go.

## Constraints

- Reuse the existing `.devcontainer/devcontainer.json` draft instead of replacing it with a Dockerfile-based setup.
- Keep the configuration Linux-focused and minimal; the repository already tests Windows and macOS in CI.
- Ensure the first container setup can instantiate the Julia environment and build the Rust helper library.
- Keep the setup maintainable in-repo without introducing extra container build assets unless they provide clear value.

## Options Considered

### 1. Extend `devcontainer.json` only

Use the existing Ubuntu base image, keep the Julia feature, install Rust and required Ubuntu packages from a setup script, and run `Pkg.instantiate()` plus `Pkg.build("RustCall")` automatically.

**Pros**

- Smallest diff.
- Keeps the existing draft.
- Easy to understand and maintain.

**Cons**

- Some setup work happens after container creation rather than during image build.

### 2. Add a custom `Dockerfile`

Bake Julia, Rust, and build packages into a custom image referenced by `devcontainer.json`.

**Pros**

- Higher reproducibility at image-build time.

**Cons**

- More files and maintenance burden.
- Unnecessary for the current repository needs.

### 3. Add Docker Compose

Model the development container with compose for future multi-service expansion.

**Pros**

- Flexible if the repository later depends on companion services.

**Cons**

- Overbuilt for a single-package development environment.

## Chosen Approach

Proceed with option 1.

The final setup will:

- keep `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`
- install Julia via the existing Julia devcontainer feature
- install Rust stable plus `clippy` and `rustfmt` during post-create setup
- install only basic Ubuntu build dependencies needed for Rust and Julia package builds
- set `JULIA_PROJECT=@.` for interactive use inside the container
- persist Julia and Cargo caches with named volumes
- document the devcontainer workflow briefly in `README.md`

## Validation

- Verify `devcontainer.json` parses as valid JSON.
- Run the repository setup command locally: `julia --project -e 'using Pkg; Pkg.instantiate(); Pkg.build("RustCall")'`.
- Review the resulting git diff and publish a draft PR.
