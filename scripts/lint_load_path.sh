#!/usr/bin/env bash
# Fail when Julia source outside src/loadpolicy.jl opens or unloads a compiled
# artifact by hand.
#
# Since #277 Phase B there is exactly one place that turns a compiled file into
# a usable library: `load_artifact!` in src/loadpolicy.jl, with
# `unload_artifact!` and `alias_artifact!` as the reverse and the aliasing
# operations. Before that there were twelve `dlopen` sites with four different
# flag sets and eight open-coded `RUST_LIBRARIES[...] = ...` writes, which is
# what made the same user-visible construct behave differently depending on the
# door it came through (#250) and left a window in which a library was visible
# before its symbol table was (#279).
#
# Three rules, all scoped to `src/`:
#
#   1. `Libdl.dlopen` only in src/loadpolicy.jl. Allowlisted:
#      src/llvmcodegen.jl, the deprecated LLVM IR path scheduled for removal
#      with #265 Phase 2.
#   2. `Libdl.dlclose` only in src/loadpolicy.jl. Closing an image is half of a
#      registry transaction, never a standalone act.
#   3. No `RUST_LIBRARIES[...] = ...` outside src/loadpolicy.jl. The handle and
#      the metadata that describes it must be published together.
#
# Usage: bash scripts/lint_load_path.sh [src]

set -euo pipefail

dir="${1:-src}"
# Matches whether "$dir" was given as a relative or an absolute path.
loader='(^|/)loadpolicy\.jl:'
# The deprecated LLVM IR path (#265 Phase 2 removes it).
llvm='(^|/)llvmcodegen\.jl:'
# The two @rust_crate module templates (the in-memory `quote` and its emitted
# twin), whose dlopen runs in the *generated* module rather than in RustCall.
# #277 Phase B5 routes them through the loader and this allowlist goes away.
template='(^|/)crate_bindings\.jl:'
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

# Rule 1: dlopen. Comment lines and docstring mentions are not call sites, so
# only an actual application `dlopen(` counts.
hits=$(grep -rnE --include='*.jl' 'Libdl\.dlopen\(' "$dir" \
       | grep -viE '^[^:]*:[0-9]+: *#' \
       | grep -vE "$loader" | grep -vE "$llvm" | grep -vE "$template" || true)
if [[ -n "$hits" ]]; then
    report "A compiled artifact may only be opened by load_artifact! (issue #277)." \
           "Call RustCall.load_artifact!(policy, path; lib_name, ...); the policy owns the dlopen flags." \
           "$hits"
fi

# Rule 2: dlclose.
hits=$(grep -rnE --include='*.jl' 'Libdl\.dlclose\(' "$dir" \
       | grep -viE '^[^:]*:[0-9]+: *#' \
       | grep -vE "$loader" | grep -vE "$llvm" || true)
if [[ -n "$hits" ]]; then
    report "A loaded image may only be closed by unload_artifact! (issue #277)." \
           "Call RustCall.unload_artifact!(policy, lib_name), which purges the registry rows too." \
           "$hits"
fi

# Rule 3: direct RUST_LIBRARIES writes.
hits=$(grep -rnE --include='*.jl' 'RUST_LIBRARIES\[[^]]*\] *=' "$dir" \
       | grep -viE '^[^:]*:[0-9]+: *#' \
       | grep -vE "$loader" || true)
if [[ -n "$hits" ]]; then
    report "The library registry may only be written by src/loadpolicy.jl (issue #277)." \
           "load_artifact! / adopt_artifact! publish the handle and its symbol table in one transaction." \
           "$hits"
fi

if [[ $status -ne 0 ]]; then
    exit 1
fi

echo "OK: loading, unloading and registration go through src/loadpolicy.jl in $dir"
