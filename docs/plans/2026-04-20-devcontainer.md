# Devcontainer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a minimal repository devcontainer that provisions Julia, Rust, and the package build prerequisites for RustCall.jl contributors.

**Architecture:** Reuse the existing `.devcontainer/devcontainer.json` draft, add one setup script for post-create provisioning, and document the workflow in `README.md`. Keep the environment Linux-only and avoid introducing a custom Dockerfile unless the minimal setup proves insufficient.

**Tech Stack:** Dev Containers (`devcontainer.json`), Ubuntu 24.04 base image, Julia feature, Rust toolchain via `rustup`, Julia package manager, git/GitHub.

---

### Task 1: Record the container configuration

**Files:**
- Modify: `.devcontainer/devcontainer.json`
- Create: `.devcontainer/post-create.sh`

**Step 1: Write the configuration changes**

- Expand `devcontainer.json` to include Rust-aware VS Code extensions, cache mounts, a post-create hook, and the runtime environment variables needed by Julia and Cargo.
- Add `post-create.sh` to install Ubuntu build prerequisites, install the Rust stable toolchain if absent, add `clippy` and `rustfmt`, and run `Pkg.instantiate()` plus `Pkg.build("RustCall")`.

**Step 2: Run a focused validation**

Run: `python3 -m json.tool .devcontainer/devcontainer.json >/dev/null`
Expected: exit code 0

### Task 2: Document contributor usage

**Files:**
- Modify: `README.md`

**Step 1: Add a short devcontainer section**

- Explain that contributors can reopen the repository in the dev container.
- State that the container installs Rust and builds `RustCall` on first creation.
- Keep the note short and near the local setup instructions.

**Step 2: Review rendered markdown context**

Run: `sed -n '1,170p' README.md`
Expected: new section appears in the setup area with concise instructions.

### Task 3: Verify repository setup and publish

**Files:**
- Modify: `.devcontainer/devcontainer.json`
- Create: `.devcontainer/post-create.sh`
- Modify: `README.md`

**Step 1: Run repository setup verification**

Run: `julia --project -e 'using Pkg; Pkg.instantiate(); Pkg.build("RustCall")'`
Expected: exit code 0

**Step 2: Review git diff**

Run: `git status --short && git diff -- .devcontainer README.md docs/plans`
Expected: only the intended devcontainer and planning changes are present.

**Step 3: Commit and publish**

- Commit the planning docs intentionally.
- Commit the devcontainer implementation intentionally.
- Push the topic branch and open a draft PR titled `[codex] add devcontainer`.
