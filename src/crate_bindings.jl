# External crate bindings: composition root.
#
# All components are included into RustCall itself, preserving the existing
# API and generated-file references. Keep this order: metadata and build
# records precede the emitter signatures that use their types. Function bodies
# may refer to later components; no bindings are generated during inclusion.
#
# The components stay beside this file so source-relative native paths retain
# their meaning, and the package's source-wide safety checks cover every part.

# Crate metadata, scanning, and Rust wrapper project generation.
include("crate_scan.jl")

# Recorded build environments, precompile inputs, and interpreter verification.
include("crate_build_env.jl")

# In-memory module template and initialization shared with written bindings.
include("crate_module_expr.jl")

# Module layout, emitted names, and traversal shared by both emitters.
include("crate_layout.jl")

# Expression wrappers and shared field and payload plans.
include("crate_wrappers_expr.jl")

# Build orchestration, binding format compatibility, and artifact keys.
include("crate_build.jl")

# Runtime binding proxies, dynamic loading, and the @rust_crate macro.
include("crate_runtime.jl")

# Persisted bindings build orchestration and library placement.
include("crate_write.jl")

# Source-text module and wrapper emission for persisted bindings.
include("crate_module_source.jl")
