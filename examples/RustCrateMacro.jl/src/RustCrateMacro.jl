"""
    RustCrateMacro

A Julia package that shows the three RustCall front doors working **together**:

- a Rust crate annotated with `#[julia]` (`rustcall_julia_macros`), under
  `deps/macro_crate/`;
- the **`@rust_crate` macro**, which binds that crate here — scanning it,
  building it and defining the generated `Bindings` submodule while this
  package is *precompiled*, with no `deps/build.jl` and no generated file;
- an inline **`rust\"\"\"` block** (the `@rust_str` macro), which compiles a
  second, independent library into RustCall's cache.

The first two are the subject of `../RustCrateMacroPyO3Only.jl`, but there the
crate is PyO3-only. This example is the common case — a crate that carries
`#[julia]` — bound by the macro instead of by `write_bindings_to_file`
(`../SampleCrate.jl`). The inline block is what `../MyExample.jl` is about. The
point here is not any one of them alone but that all three coexist in one
package and can compose: `inline_norm` runs the inline library's arithmetic on
a `Point` built by the `@rust_crate` bindings.

`RustCrateMacro.Bindings` is the module `@rust_crate` generated; the functions
this module exports are the crate's items plus the inline block's, plus a thin
Julia layer (`safe_divide`, `safe_sqrt`, `inline_norm`).
"""
module RustCrateMacro

using RustCall
using RustCall: is_ok, is_some, unwrap

# The `@rust_crate` front door. `submodule="Bindings"` defines the generated
# module here, as `RustCrateMacro.Bindings`, which is what makes the
# `using .Bindings` below possible (#339). The crate is scanned, built and the
# module generated while this package is precompiled; at load time the module's
# `__init__` opens the cached library and nothing is rebuilt.
@rust_crate joinpath(@__DIR__, "..", "deps", "macro_crate") submodule="Bindings"

# Exactly the names this module re-exports unchanged from the generated module.
# `safe_divide` and `safe_sqrt` are deliberately *not* imported: the wrappers
# below are new functions of this module calling `Bindings.<name>`, so nothing
# here shadows or extends an imported binding.
using .Bindings: add, multiply, shout, join_repeat,
                 Point, translate, norm

# ============================================================================
# The inline `rust"""` (`@rust_str`) block, beside the `@rust_crate` bindings
# ============================================================================
#
# A second library, compiled into RustCall's cache the same way. Its names are
# `inline_*` on purpose: a `rust"""` block in the same module that declares a
# name the crate exports shadows that bare name, so the two namespaces are kept
# disjoint and the tests check the shadowing case in a scratch module instead.

rust"""
#[julia]
fn inline_hypot(a: f64, b: f64) -> f64 {
    (a * a + b * b).sqrt()
}

#[julia]
fn inline_join(left: &str, right: &str) -> String {
    format!("{left}-{right}")
}
"""

# ============================================================================
# Exports
# ============================================================================

# Names the `#[julia]` crate exposes through `@rust_crate`, re-exported
# unchanged. `Counter`-style method names that would shadow `Base` are absent
# here for the same reason as in `../SampleCrate.jl`.
export add, multiply, shout, join_repeat
export Point, translate, norm

# The inline `rust"""` block's functions.
export inline_hypot, inline_join

# Julia-side conveniences defined below.
export safe_divide, safe_sqrt, inline_norm

# ============================================================================
# Julia-side conveniences
# ============================================================================

"""
    safe_divide(a::Real, b::Real) -> Float64

`a / b` computed in Rust. The crate returns `Result<f64, i32>`; this wrapper
unwraps it and throws `DivideError` on `Err`.
"""
function safe_divide(a::Real, b::Real)::Float64
    r = Bindings.safe_divide(Float64(a), Float64(b))
    is_ok(r) || throw(DivideError())
    return unwrap(r)
end

"""
    safe_sqrt(x::Real) -> Union{Float64, Nothing}

Square root computed in Rust; `nothing` for a negative input (Rust `None`).
"""
function safe_sqrt(x::Real)
    o = Bindings.safe_sqrt(Float64(x))
    return is_some(o) ? unwrap(o) : nothing
end

"""
    inline_norm(p::Point) -> Float64

The length of a `Point` built by the `@rust_crate` bindings, computed by the
inline `rust\"\"\"` block. This is the one place the two libraries are joined:
the `Point` is the crate's, the arithmetic is the block's.
"""
inline_norm(p::Point)::Float64 = inline_hypot(p.x, p.y)

end # module RustCrateMacro
