#!/usr/bin/env bash
# Fail when Julia source in src/ tries to interpret Rust syntax with regexes.
#
# Since #264, Rust syntax is parsed exclusively on the Rust side
# (deps/rustcall_core, driven by the rustcall-extract CLI). Julia consumes the
# FFI manifest. A regex in src/ that matches Rust keywords or attributes is a
# regression of that design and must go through the manifest instead.
#
# Allowlist (RustCall's own syntax or best-effort diagnostics, not Rust grammar):
#   src/ruststr.jl      `$var` interpolation in @irust and its return-type heuristic
#   src/dependencies.jl `// cargo-deps:` / `//! ```cargo` dependency comment DSL
#   src/exceptions.jl   brace counting for compile-error hints (diagnostics only)
#
# Usage: bash scripts/lint_rust_syntax_regex.sh [src]

set -euo pipefail

dir="${1:-src}"
allow='^(src/ruststr\.jl|src/dependencies\.jl|src/exceptions\.jl):'

# Regex literals (r"..."), Regex("...") constructors and eachmatch/match calls
# whose pattern mentions Rust item keywords or attribute syntax.
pattern='(r"([^"]*[^A-Za-z_])?(fn|struct|impl|extern|where|derive|no_mangle)([^A-Za-z_][^"]*)?"|Regex\("([^"]*[^A-Za-z_])?(fn|struct|impl|extern|where|derive|no_mangle)([^A-Za-z_][^"]*)?"|r"[^"]*#\\\[|Regex\("[^"]*#\\\\\[)'

hits=$(grep -rnE --include='*.jl' "$pattern" "$dir" | grep -vE "$allow" || true)

if [[ -n "$hits" ]]; then
    echo "Julia source must not parse Rust syntax with regexes (see issue #264)."
    echo "Use the FFI manifest from rustcall-extract (src/manifest.jl) instead:"
    echo
    echo "$hits"
    exit 1
fi

echo "OK: no Rust-syntax regexes outside the allowlist in $dir"
