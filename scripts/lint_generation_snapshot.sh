#!/usr/bin/env bash
# Fail when an FFI entry point resolves what it needs one piece at a time.
#
# The rule (#277): a library can be replaced while a program runs — that is
# what a hot reload is — so **every FFI entry point takes one snapshot under
# one lock and uses only that snapshot**. Function pointer, panic channel,
# owned-`String` release function, struct destructor, liveness flag and return
# ABI all belong to one generation of one image. Nothing after the snapshot may
# look anything up by library name.
#
# Resolving two of those separately is not a slower version of the same thing,
# it is a different program: the call enters the retired image while the
# channel, the `free`, or the return ABI comes from its replacement. That is a
# lost panic, a buffer released through the wrong allocator, or a scalar read
# as a struct.
#
# The snapshot constructors are the only places allowed to resolve a piece:
#
#   * `resolve_call_target`            src/ruststr.jl   — a call's pointer, channel,
#                                                         release fn, return ABI
#   * `artifact_generation_snapshot`   src/structs.jl   — a struct's destructor + flag
#   * `generic_struct_generation_snapshot`
#                                      src/structs.jl   — the generic counterpart
#   * `_call_target` / `_struct_generation`
#                                      src/crate_bindings.jl — inside a @rust_crate module
#
# So this lint forbids, outside the file that *defines* each of them, the
# individual resolvers they are made of.
#
# Allowlist: src/llvmcodegen.jl, the deprecated LLVM IR path that #265 Phase 2
# removes; it keeps its own lookups and is not part of the supported call path.
#
# Usage: bash scripts/lint_generation_snapshot.sh [src]

set -euo pipefail

dir="${1:-src}"
llvm='(^|/)llvmcodegen\.jl:'
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

# `name(` used as a call, ignoring comment lines, the file that defines it, and
# `function name(` / docstring signature lines.
call_sites() {
    local pattern="$1" owner="$2"
    grep -rnE --include='*.jl' "(^|[^[:alnum:]_.])${pattern}\(" "$dir" \
        | grep -viE '^[^:]*:[0-9]+: *#' \
        | grep -vE "(^|/)${owner}:" \
        | grep -vE "$llvm" \
        | grep -vE '^[^:]*:[0-9]+: *(function|const) ' \
        | grep -vE "^[^:]*:[0-9]+: *${pattern}\(" || true
}

# 1. The liveness flag is never taken on its own: it must come from the same
#    locked read as the destructor it will be paired with.
hits=$(call_sites 'artifact_alive_ref' 'loadpolicy\.jl')
if [[ -n "$hits" ]]; then
    report "A liveness flag may only be taken as part of a snapshot (issue #277)." \
           "Use artifact_generation_snapshot / generic_struct_generation_snapshot, which return the destructor and the flag of ONE generation." \
           "$hits"
fi

# 2. Likewise a destructor.
hits=$(call_sites 'struct_free_pointer' 'structs\.jl')
if [[ -n "$hits" ]]; then
    report "A struct destructor may only be taken as part of a snapshot (issue #277)." \
           "Use artifact_generation_snapshot(lib, struct) — it pairs the destructor with the liveness flag of the image that exports it." \
           "$hits"
fi

# 3. ...and a panic channel.
hits=$(call_sites 'panic_channel_pointer' 'codegen\.jl')
if [[ -n "$hits" ]]; then
    report "A panic channel may only be taken as part of a snapshot (issue #277)." \
           "Use resolve_call_target(lib, fn).channel, resolved with the function pointer it belongs to." \
           "$hits"
fi

# 4. A bare function pointer by name is the classic half-snapshot: the call
#    would then need a second lookup for its channel and its return ABI.
hits=$(call_sites 'get_function_pointer' 'ruststr\.jl')
if [[ -n "$hits" ]]; then
    report "A call pointer may only be taken as part of a snapshot (issue #277)." \
           "Use resolve_call_target(lib, fn), which returns the pointer, the panic channel, the owned-String release function and the return ABI of one generation." \
           "$hits"
fi

# 5. The return ABI decides how the return slot is read, so it belongs to the
#    snapshot too: a pointer from the retired generation read with the
#    replacement's ABI is memory corruption, not a wrong answer.
hits=$(call_sites 'get_function_return_type' 'codegen\.jl')
if [[ -n "$hits" ]]; then
    report "A return type may only be taken as part of a snapshot (issue #277)." \
           "Use CallTarget.return_type / CallTarget.func_info from resolve_call_target." \
           "$hits"
fi

# 6. The generated @rust_crate modules read their generation exactly once per
#    call, through `_LIB_GEN[]`. A template that reached for a handle or a flag
#    any other way would be back to two unsynchronised cells.
hits=$(grep -rnE --include='*.jl' '_LIB_HANDLE|_LIB_ALIVE' "$dir" \
       | grep -viE '^[^:]*:[0-9]+: *#' \
       | grep -vE '^[^:]*:[0-9]+: *(push!\(lines, ")?#' || true)
if [[ -n "$hits" ]]; then
    report "A @rust_crate module publishes ONE record, not two Refs (issue #277)." \
           "The template's state is _LIB_GEN::Ref{CrateGeneration}; read it once per call. Two cells written under two different locks are not a snapshot." \
           "$hits"
fi

if [[ $status -ne 0 ]]; then
    exit 1
fi

echo "OK: every FFI entry point in $dir resolves through a generation snapshot"
