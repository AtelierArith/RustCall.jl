#!/usr/bin/env bash
#
# Publish this tree's crates.io crates, in dependency order, but only the ones
# whose `Cargo.toml` version is not on crates.io yet.
#
# The three published crates share a version of their own, independent of the
# package's release (AGENTS.md, "Rust crate versions"), and `rustcall_extract`
# is not published. Publishing a crate whose dependencies are not on crates.io
# yet fails, so this walks `rustcall_julia_core` -> `..._macros_impl` ->
# `..._macros` and waits for each upload to reach the sparse index before
# moving on.
#
# Idempotent: a version already on crates.io is skipped, so the workflow can
# run on every green push to `main` and act only on an actual bump. Run with
# `--dry-run` to publish nothing: every crate that would be published gets
# `cargo publish --dry-run` — Cargo's own packaging, metadata and build checks
# — except one whose dependency is itself still waiting to be published in the
# same run, which Cargo cannot resolve against crates.io before that upload;
# that one is named and skipped rather than reported green. `CARGO_REGISTRY_TOKEN`
# is read by Cargo itself from the environment; it is never passed as a
# command-line argument.
#
# The workflow (`.github/workflows/PublishCrates.yml`) runs this under the
# `release` environment, which is where the token belongs — it can publish any
# crate the account owns, so it must not reach pull requests.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

dry_run=false
if [ "${1:-}" = "--dry-run" ]; then
    dry_run=true
elif [ $# -gt 0 ]; then
    echo "usage: $0 [--dry-run]" >&2
    exit 2
fi

# Dependency order: every crate is published before anything that depends on it.
crates=(rustcall_julia_core rustcall_julia_macros_impl rustcall_julia_macros)

crate_version() {
    awk '
        /^\[/ { section = $0; next }
        section == "[package]" && /^version[[:space:]]*=/ {
            line = $0
            sub(/^[^"]*"/, "", line)
            sub(/".*/, "", line)
            print line
            exit
        }
    ' "$1"
}

# Cargo's sparse-index layout: the path is chosen by the name's length.
index_path() {
    local name="$1"
    local n=${#name}
    if [ "$n" -eq 1 ]; then
        printf '1/%s' "$name"
    elif [ "$n" -eq 2 ]; then
        printf '2/%s' "$name"
    elif [ "$n" -eq 3 ]; then
        printf '3/%s/%s' "${name:0:1}" "$name"
    else
        printf '%s/%s/%s' "${name:0:2}" "${name:2:2}" "$name"
    fi
}

is_published() {
    local name="$1" version="$2"
    curl -fsS "https://index.crates.io/$(index_path "$name")" 2>/dev/null |
        grep -q "\"vers\":\"${version}\""
}

wait_for_index() {
    local name="$1" version="$2"
    for _ in $(seq 1 60); do
        if is_published "$name" "$version"; then
            return 0
        fi
        sleep 5
    done
    return 1
}

# Crates this dry run would have uploaded before the current one: every later
# crate depends on every earlier one, so their absence from crates.io is what
# keeps Cargo from checking the current crate.
unpublished_deps=()

for crate in "${crates[@]}"; do
    manifest="$root/deps/$crate/Cargo.toml"
    version="$(crate_version "$manifest")"
    if is_published "$crate" "$version"; then
        echo "$crate $version is already on crates.io; skipping"
        continue
    fi
    if $dry_run; then
        if [ ${#unpublished_deps[@]} -gt 0 ]; then
            echo "would publish $crate $version (not checked: it depends on" \
                 "${unpublished_deps[*]}, which this run would upload first)"
        else
            echo "would publish $crate $version; running cargo publish --dry-run"
            cargo publish --dry-run --manifest-path "$manifest"
        fi
        unpublished_deps+=("$crate $version")
        continue
    fi
    echo "publishing $crate $version"
    cargo publish --manifest-path "$manifest"
    if ! wait_for_index "$crate" "$version"; then
        echo "::error::$crate $version did not reach the crates.io index in time" >&2
        exit 1
    fi
done
