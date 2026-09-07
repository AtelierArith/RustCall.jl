"""
    SampleCrate

A Julia package with its Rust crate embedded under `deps/sample_crate/`.

The two halves live in separate files:

- **Rust**: `deps/sample_crate/src/lib.rs` — the implementation, marked with
  `#[julia]` where it should be callable from Julia. No Julia file contains
  Rust source.
- **Julia**: this file — idiomatic wrappers over the generated bindings — and
  `src/generated/Bindings.jl`, which `deps/build.jl` writes with
  `RustCall.write_bindings_to_file` (run `Pkg.build("SampleCrate")`).

`SampleCrate.Bindings` is the generated module, exposed as is; the functions
this module exports are the Julia-side conveniences on top of it.
"""
module SampleCrate

using RustCall
using RustCall: RustResult, RustOption, is_ok, is_err, is_some, is_none, unwrap

const _BINDINGS_FILE = joinpath(@__DIR__, "generated", "Bindings.jl")
if !isfile(_BINDINGS_FILE)
    # First use from a fresh checkout, before any `Pkg.build("SampleCrate")`:
    # run the build step now so that `using SampleCrate` and `Pkg.test()` work
    # without a manual step. `Pkg.build("SampleCrate")` is still the way to
    # regenerate after editing the Rust crate.
    @info "SampleCrate: no generated bindings yet; running deps/build.jl"
    include(joinpath(@__DIR__, "..", "deps", "build.jl"))
end
include(_BINDINGS_FILE)
# Only the names this module re-exports unchanged are imported. The ones
# wrapped below (`safe_divide`, `safe_sqrt`, …) are *not*: they are new
# functions of this module that call `Bindings.<name>` explicitly, so nothing
# here shadows or extends an imported binding.
using .Bindings: add, multiply, fibonacci, is_prime,
                 shout, join_repeat, char_count, crate_greeting, identity_str,
                 Point, Counter, Labeler, Rectangle,
                 distance_from_origin, distance_to, translate,
                 increment, decrement,
                 label, byte_len, kind, echo,
                 area, perimeter, is_square, scale

# Names the Rust crate exports through `#[julia]`, re-exported unchanged.
export add, multiply, fibonacci, is_prime
export shout, join_repeat, char_count, crate_greeting, identity_str
export Point, Counter, Labeler, Rectangle
export distance_from_origin, distance_to, translate
# `Counter`'s `get` and `reset` would shadow `Base.get` / `Base.reset`, so they
# are not re-exported: call them as `SampleCrate.Bindings.get(c)`, or use the
# Julia-side `value` / `reset!` below.
export increment, decrement, value, reset!
export label, byte_len, kind, echo
export area, perimeter, is_square, scale

# Julia-side conveniences defined below.
export safe_divide, parse_positive, safe_sqrt, find_positive, parse_int, first_char
export distance

# ============================================================================
# Result<T, E> → Julia: return the value, throw on Err
# ============================================================================

"""
    safe_divide(a::Real, b::Real) -> Float64

`a / b` computed in Rust. Rust returns `Result<f64, i32>`; the Julia wrapper
unwraps it and throws `DivideError` when the crate reported `Err`.
"""
function safe_divide(a::Real, b::Real)::Float64
    r = Bindings.safe_divide(Float64(a), Float64(b))
    is_ok(r) || throw(DivideError())
    return unwrap(r)
end

"""
    parse_positive(n::Integer) -> UInt32

`n` as an unsigned integer. Rust returns `Result<u32, i32>` with the offending
value as the error; the wrapper throws `DomainError` for a negative input.
"""
function parse_positive(n::Integer)::UInt32
    r = Bindings.parse_positive(Int32(n))
    # `RustResult.value` holds the `Err` payload when `is_err(r)`.
    is_ok(r) || throw(DomainError(r.value, "parse_positive expects a non-negative integer"))
    return unwrap(r)
end

"""
    parse_int(s::AbstractString) -> Int32

Parse an integer in Rust (`str::parse`). Throws `ArgumentError` when Rust
returns `Err`.
"""
function parse_int(s::AbstractString)::Int32
    r = Bindings.parse_int(String(s))
    is_ok(r) || throw(ArgumentError("parse_int: not an integer: $(repr(s))"))
    return unwrap(r)
end

# ============================================================================
# Option<T> → Julia: `Union{T, Nothing}`
# ============================================================================

"""
    safe_sqrt(x::Real) -> Union{Float64, Nothing}

Square root computed in Rust; `nothing` for a negative input (Rust `None`).
"""
function safe_sqrt(x::Real)
    o = Bindings.safe_sqrt(Float64(x))
    return is_some(o) ? unwrap(o) : nothing
end

"""
    find_positive(a::Integer, b::Integer) -> Union{Int32, Nothing}

The first positive of `a`, `b`, or `nothing` when neither is (Rust `None`).
"""
function find_positive(a::Integer, b::Integer)
    o = Bindings.find_positive(Int32(a), Int32(b))
    return is_some(o) ? unwrap(o) : nothing
end

"""
    first_char(s::AbstractString) -> Union{Char, Nothing}

The first character of `s` as a `Char`, or `nothing` for an empty string. Rust
returns `Option<u32>` (the scalar value); the wrapper converts it.
"""
function first_char(s::AbstractString)
    o = Bindings.first_char(String(s))
    return is_some(o) ? Char(unwrap(o)) : nothing
end

# ============================================================================
# Structs: a Julia method on top of the generated ones
# ============================================================================

"""
    distance(p::Point, q::Point) -> Float64

Euclidean distance between two points, through the crate's
`Point::distance_to(&self, x, y)`.
"""
distance(p::Point, q::Point)::Float64 = distance_to(p, q.x, q.y)

"""
    value(c::Counter) -> Int32

The counter's current value (`Counter::get` in Rust, renamed so it does not
shadow `Base.get`).
"""
value(c::Counter)::Int32 = Bindings.get(c)

"""
    reset!(c::Counter)

Set the counter back to zero (`Counter::reset` in Rust; the `!` marks the
mutation, and the name does not shadow `Base.reset`).
"""
reset!(c::Counter) = (Bindings.reset(c); c)

end # module SampleCrate
