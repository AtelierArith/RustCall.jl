# ============================================================================
# An inline `rust"""` block beside the crate
# ============================================================================
#
# `deps/build.jl` binds the crate under `deps/sample_crate/` with
# `write_bindings_to_file`. This file shows that a package can *also* carry a
# `rust"""` block (the `@rust_str` macro) in its own source, and that the two
# libraries coexist when the package is loaded.
#
# The block uses names of its own (`inline_*`) so the bare names the crate
# exports are untouched. Both sets of wrappers then live in this module:
# `inline_hypot` / `inline_join` come from the inline library, while `Point`,
# `add`, `shout`, … come from the crate's generated `Bindings`. The
# `inline_distance` below composes the two — inline Rust arithmetic over a
# `Point` built by the crate.

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

"""
    inline_distance(p::Point, q::Point) -> Float64

Euclidean distance computed by the inline `rust\"\"\"` block in `src/inline.jl`,
over two `Point`s built by the crate's generated bindings. One package, two Rust
libraries: `Point` comes from `deps/sample_crate`, the arithmetic from the
inline block.
"""
inline_distance(p::Point, q::Point)::Float64 = inline_hypot(p.x - q.x, p.y - q.y)
