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

# Whether `name` `version` is in the crates.io index. Three answers, not two:
# 0 = published, 1 = not published (the version is absent from the crate's
# index file, or the crate has no file yet — a 404 is how the index says a
# name has never been published), 2 = the index could not be asked (a
# transport failure or any other status). Treating 2 as "not published" would
# have re-run `cargo publish` for a version that is on crates.io and failed
# what should be an idempotent rerun, so a caller must decide what a 2 means.
index_status() {
    local name="$1" version="$2" body code
    body="$(mktemp)"
    code="$(curl -sS -o "$body" -w '%{http_code}' \
                "https://index.crates.io/$(index_path "$name")" 2>/dev/null || echo 000)"
    if [ "$code" = 200 ]; then
        if grep -qF "\"vers\":\"${version}\"" "$body"; then  # -F: a version is not a pattern
            rm -f "$body"
            return 0
        fi
        rm -f "$body"
        return 1
    fi
    rm -f "$body"
    if [ "$code" = 404 ]; then
        return 1
    fi
    return 2
}

# `index_status`, with an unreachable index retried a few times and then
# reported as an error rather than guessed at.
is_published() {
    local name="$1" version="$2" rc attempt
    for attempt in 1 2 3 4 5; do
        rc=0
        index_status "$name" "$version" || rc=$?
        if [ "$rc" -ne 2 ]; then
            return "$rc"
        fi
        echo "crates.io index did not answer for $name (attempt $attempt); retrying" >&2
        sleep 5
    done
    echo "::error::the crates.io index could not be reached for $name $version;" \
         "not publishing on a guess" >&2
    exit 1
}

# After an upload, the version takes a moment to reach the sparse index. An
# index that does not answer during the wait is "not there yet", not an
# error: the upload has happened, and the next run finds it.
wait_for_index() {
    local name="$1" version="$2" rc
    for _ in $(seq 1 60); do
        rc=0
        index_status "$name" "$version" || rc=$?
        if [ "$rc" -eq 0 ]; then
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
