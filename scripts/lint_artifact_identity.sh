#!/usr/bin/env bash
# Fail when Julia source outside src/artifact_id.jl builds artifact identity by hand.
#
# Since #278 there is exactly one answer to "which compiled artifact corresponds
# to this request?": build an `ArtifactId` and call `artifact_key`. Every other
# formula is a place that can silently drift — that is what produced #247 (a
# monomorphization key that lost parameter order), #252 (a `rustc` in the key
# that is not the `rustc` that compiles) and the repeated Cargo cache patches.
#
# Three rules, all scoped to `src/` and all allowlisting only `src/artifact_id.jl`:
#
#   1. No hand-rolled digest of concatenated key material
#      (`sha256("$(a)_$(b)")`). Concatenation is not injective; the netstring
#      encoder in src/artifact_id.jl is.
#   2. No truncation of a digest outside `artifact_short_id`. Truncation exists
#      for human-readable names only, in one place, at one length.
#   3. No session-randomized `hash()` for an identifier. Julia's `hash` is
#      randomized per process, so a name derived from it can never be matched
#      again — see the rule at the top of src/cache.jl.
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

if [[ $status -ne 0 ]]; then
    exit 1
fi

echo "OK: artifact identity goes through src/artifact_id.jl in $dir"
