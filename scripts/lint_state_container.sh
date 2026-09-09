#!/usr/bin/env bash
# Fail when a mutable runtime registry is declared outside RustCall.STATE.
#
# StateView keeps the historical internal names source-compatible while making
# every operation take the Base.Lockable state lock. This lint prevents a new
# feature from reintroducing the independent-Dict pattern behind #251.
# The deferred-drop queue is stored in STATE too. Its separate lock is listed
# nowhere here because finalizers use it without taking STATE.

set -euo pipefail

dir="${1:-src}"
status=0
names=(
  RUST_LIBRARIES CURRENT_LIB MODULE_ACTIVE_LIB FUNCTION_REGISTRY
  FUNCTION_REGISTRY_BY_LIB FUNCTION_RETURN_TYPES_BY_LIB FUNCTION_SYMBOLS_BY_LIB
  PANIC_CHANNELS GENERIC_FUNCTION_REGISTRY MONOMORPHIZED_FUNCTIONS IRUST_FUNCTIONS
  HOT_RELOAD_REGISTRY RELOAD_LOCKS ARTIFACT_ALIVE ARTIFACT_GENERATIONS
  DEFERRED_DROPS
  HANDLE_MIRRORS RETIRED_HANDLES OWNED_HANDLES PRELOADED_LIBRARIES
  RUST_HELPERS_LIB DROP_WARNING_SHOWN FFI_TYPE_TABLE _FFI_UNKNOWN_SLOTS FFI_STRICT
  _FFI_WARNED_CONTEXTS DEFAULT_COMPILER _EXTRACTOR_PATH _EXTRACTOR_DIGEST
  _TOOLCHAIN_FINGERPRINT _EXPANSION_CACHE _RUSTC_CFG_TEXT _RUSTC_CFG_FILE
  _CARGO_CFG_TEXT _CRATE_CFG_TEXT _WRAPPER_CFG_TEXT _CACHE_DIR_MEMO
  DLOPEN_GLOBAL_OVERRIDE _DLOPEN_GLOBAL_WARNED DEAD_ARTIFACT _PATH_DEP_GRAPH_CACHE
  CARGO_TREE_INVOCATIONS HOT_RELOAD_ENABLED HOT_RELOAD_DEBOUNCE_SECONDS
)

for name in "${names[@]}"; do
    hits=$(grep -rnE --include='*.jl' "^[[:space:]]*const[[:space:]]+${name}[[:space:]]*=" "$dir" \
        | grep -v '_state_view' || true)
    if [[ -n "$hits" ]]; then
        echo "Mutable registry $name is not backed by RustCall.STATE:"
        echo "$hits"
        status=1
    fi
done

if [[ $status -ne 0 ]]; then
    exit 1
fi
echo "OK: mutable runtime registries are declared as StateViews"
