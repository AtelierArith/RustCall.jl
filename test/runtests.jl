using RustCall
using Test

# Include cache tests
include("test_cache.jl")

# Include ownership tests
include("test_ownership.jl")

# Include array/collection tests
include("test_arrays.jl")

# Include generics tests
include("test_generics.jl")

# Include error handling tests
include("test_error_handling.jl")

# Include llvmcall tests
include("test_llvmcall.jl")

# Include Rust helpers integration tests
include("test_rust_helpers_integration.jl")

# Include documentation examples tests
include("test_docs_examples.jl")

# Phase 3: External library integration tests
include("test_dependencies.jl")
include("test_cargo.jl")
include("test_ndarray.jl")
include("test_external_crates.jl")

# Examples converted to tests
include("test_basic_examples.jl")
include("test_advanced_examples.jl")
include("test_ownership_examples.jl")
include("test_struct_examples.jl")
include("test_phase4_ndarray.jl")
include("test_phase4_pi.jl")
include("test_generic_struct.jl")
include("test_julia_to_rust_simple.jl")
include("test_julia_to_rust_struct.jl")
include("test_julia_to_rust_generic.jl")

# Phase 5: #[julia] attribute tests
include("test_julia_attribute.jl")

# Phase 6: Crate bindings tests (Maturin-like feature)
include("test_crate_bindings.jl")

# Hot reload tests
include("test_hot_reload.jl")

# Types, memory, and safety fixes
include("test_types_memory_safety.jl")

# LLVM/Codegen bug fix tests
include("test_llvm_fixes.jl")

# Regression reproduction tests
include("test_regressions.jl")

# Parsing, generics, and hot-reload fixes (#168, #169, #170, #172, #173, #184, #185)
include("test_parsing_generics_hotreload_fixes.jl")
