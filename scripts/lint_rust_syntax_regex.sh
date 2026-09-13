#!/usr/bin/env bash
# Fail when Julia source in src/ tries to interpret Rust syntax with regexes.
#
# Since #264, Rust syntax is parsed exclusively on the Rust side
# (deps/rustcall_core, driven by the rustcall-extract CLI). Julia consumes the
# FFI manifest. A regex in src/ that matches Rust keywords or attributes is a
# regression of that design and must go through the manifest instead.
#
# Allowlist (RustCall's own syntax or best-effort diagnostics, not Rust grammar):
#   src/ruststr.jl      `$var` interpolation in @irust — and nothing else since
#                       #348: the @irust return type is asked of rustc
#                       (probe_rust_expression_type in src/compiler.jl, reading
#                       --error-format=json diagnostics as data) instead of
#                       being guessed from the snippet's text
#   src/dependencies.jl `// cargo-deps:` / `//! ```cargo` dependency comment DSL
#   src/exceptions.jl   brace counting for compile-error hints (diagnostics only)
#
# Usage: bash scripts/lint_rust_syntax_regex.sh [src]

set -euo pipefail

dir="${1:-src}"
allow='^(src/ruststr\.jl|src/dependencies\.jl|src/exceptions\.jl):'

# Regex literals (r"..."), Regex("...") constructors and eachmatch/match calls
# whose pattern mentions Rust item keywords or attribute syntax.
#
# The `r"` must not be preceded by an identifier character: `var"..."` is how
# Julia spells a name that is not an identifier (the generated snapshot caches
# of #253 are `var"#TC#fn#<symbol>"`), and `raw"..."`, `b"..."` and any other
# string macro ending in `r` are not regexes either. Without the guard the `r`
# of `var` and the quote after it read as a regex literal.
pattern='((^|[^A-Za-z0-9_])r"([^"]*[^A-Za-z_])?(fn|struct|impl|extern|where|derive|no_mangle)([^A-Za-z_][^"]*)?"|Regex\("([^"]*[^A-Za-z_])?(fn|struct|impl|extern|where|derive|no_mangle)([^A-Za-z_][^"]*)?"|(^|[^A-Za-z0-9_])r"[^"]*#\\\[|Regex\("[^"]*#\\\\\[)'

hits=$(grep -rnE --include='*.jl' "$pattern" "$dir" | grep -vE "$allow" || true)

if [[ -n "$hits" ]]; then
    echo "Julia source must not parse Rust syntax with regexes (see issue #264)."
    echo "Use the FFI manifest from rustcall-extract (src/manifest.jl) instead:"
    echo
    echo "$hits"
    exit 1
fi

echo "OK: no Rust-syntax regexes outside the allowlist in $dir"
