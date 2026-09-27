# Regression reproduction tests for known issues.

using RustCall
using Test
using Libdl

include("source_helpers.jl")

all_signatures(code; mode = "inline") = RustCall.manifest_function_signatures(
    RustCall.extract_manifest(code; mode = mode); only_attributed = false
)
attributed_signatures(code; mode = "inline") = RustCall.manifest_function_signatures(
    RustCall.extract_manifest(code; mode = mode)
)
signature_for(code, name; mode = "inline") = only(
    filter(sig -> sig.name == name, all_signatures(code; mode = mode))
)

include("regressions_known.jl")
include("regressions_prevention.jl")
include("regressions_library_symbols.jl")
include("regressions_return_metadata.jl")
include("regressions_ffi_contract.jl")
include("regressions_owned_strings.jl")
include("regressions_reload_generics.jl")
include("regressions_ffi_followups.jl")
include("regressions_ffi_boundary.jl")
