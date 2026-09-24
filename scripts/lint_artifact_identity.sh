#!/usr/bin/env bash
# Fail when Julia source outside src/artifact_id.jl builds artifact identity by hand.
#
# Since #278 there is exactly one answer to "which compiled artifact corresponds
# to this request?": build an `ArtifactId` and call `artifact_key`. Every other
# formula is a place that can silently drift — that is what produced #247 (a
# monomorphization key that lost parameter order), #252 (a `rustc` in the key
# that is not the `rustc` that compiles) and the repeated Cargo cache patches.
#
# Four rules, all scoped to `src/`; the first three allowlist only
# `src/artifact_id.jl`, the fourth also `src/short_name.jl`:
#
#   1. No hand-rolled digest of concatenated key material
#      (`sha256("$(a)_$(b)")`). Concatenation is not injective; the netstring
#      encoder in src/artifact_id.jl is.
#   2. No truncation of a digest outside `artifact_short_id`. Truncation exists
#      for human-readable names only, in one place, at one length.
#   3. No session-randomized `hash()` for an identifier. Julia's `hash` is
#      randomized per process, so a name derived from it can never be matched
#      again — see the rule at the top of src/cache.jl.
#   4. No short id naming a path or a Cargo package outside `src/short_name.jl`
#      (#504). A short id that is a location must be owned by the full key it
#      came from (a claim record, and a lock from build start through
#      copy-out), and `short_name` / `short_name_path` / `with_short_name` /
#      `with_owned_short_name` are where that happens. Any other
#      `artifact_short_id(` call must carry one of two markers on its line:
#        `# short-id: label` — a name that is never a location: an in-process
#          registry name (`RUST_LIBRARIES`), a Rust symbol inside its own
#          library, a Cargo package in a fresh private project, a log field;
#        `# short-id: lease` — a token that is not derived from an artifact key
#          and whose path is owned by a lease of its own (the host / instance
#          tags of a generation copy, src/loadpolicy.jl).
#      A marked line may not itself build a path (`joinpath`, `mkpath`,
#      `mktempdir`, `CargoProject`, `CARGO_TARGET_DIR`).
#
# Usage: bash scripts/lint_artifact_identity.sh [src]

set -euo pipefail

dir="${1:-src}"
# Matches whether "$dir" was given as a relative or an absolute path.
allow='(^|/)artifact_id\.jl:'
status=0

report() {
    local title="$1" hint="$2" hits="$3"
    echo "$title"
    echo "$hint"
    echo
    echo "$hits"
    echo
    status=1
}

# Rule 1: sha256 over an interpolated string literal — i.e. key material joined
# by hand. `sha256(read(path))` and `sha256(take!(io))` are fine.
hits=$(grep -rnE --include='*.jl' 'sha256\("[^"]*\$' "$dir" | grep -vE "$allow" || true)
if [[ -n "$hits" ]]; then
    report "Artifact identity must not be built by string concatenation (issue #278)." \
           "Build a RustCall.ArtifactId and call artifact_key; see src/artifact_id.jl." \
           "$hits"
fi

# Rule 2: truncating a digest anywhere but `artifact_short_id`.
hits=$(grep -rnE --include='*.jl' '\[1:[0-9A-Z_]+\]' "$dir" \
       | grep -viE '^[^:]*:[0-9]+: *#' \
       | grep -iE 'hash|digest|key|sha256|fingerprint|identity' \
       | grep -vE "$allow" || true)
if [[ -n "$hits" ]]; then
    report "A digest may only be truncated by artifact_short_id (issue #278)." \
           "Use RustCall.artifact_short_id(key, n); lookup keys are never truncated." \
           "$hits"
fi

# Rule 3: Julia's randomized `hash()` used to derive an identifier. Comment
# lines and the *_hash helpers (stable_content_hash, hash_dependencies,
# compute_crate_hash) are not this.
hits=$(grep -rnE --include='*.jl' '(^|[^A-Za-z0-9_.])hash\([^)]' "$dir" \
       | grep -viE '^[^:]*:[0-9]+: *#' \
       | grep -vE '[A-Za-z0-9_]hash\(' \
       | grep -vE "$allow" || true)
if [[ -n "$hits" ]]; then
    report "Julia's hash() is randomized per session and must not name an artifact (issue #278)." \
           "Use RustCall.artifact_key / artifact_short_id, or stable_content_hash for plain content." \
           "$hits"
fi

# Rule 4: a short id outside the ownership helper, unless marked as a label or
# a lease-owned token — and a marked line may not build a path itself.
short_allow='(^|/)(artifact_id|short_name)\.jl:'
hits=$(grep -rnE --include='*.jl' 'artifact_short_id\(' "$dir" \
       | grep -viE '^[^:]*:[0-9]+: *#' \
       | grep -vE "$short_allow" \
       | grep -vE '# short-id: (label|lease)' || true)
if [[ -n "$hits" ]]; then
    report "A short id may name a path or a Cargo package only through src/short_name.jl (issue #504)." \
           "Use short_name / short_name_path with claim_short_name! / with_short_name / with_owned_short_name, or mark a pure label with '# short-id: label'." \
           "$hits"
fi
hits=$(grep -rnE --include='*.jl' 'artifact_short_id\(.*# short-id: (label|lease)' "$dir" \
       | grep -vE "$short_allow" \
       | grep -E 'joinpath|mkpath|mktempdir|CargoProject|CARGO_TARGET_DIR' || true)
if [[ -n "$hits" ]]; then
    report "A line marked '# short-id: label' / 'lease' builds a path (issue #504)." \
           "A short id that is a location goes through src/short_name.jl, which owns it by the full key." \
           "$hits"
fi

if [[ $status -ne 0 ]]; then
    exit 1
fi

echo "OK: artifact identity goes through src/artifact_id.jl, short names through src/short_name.jl, in $dir"
