//! The Rust half of `examples/RustCrateMacro.jl`.
//!
//! Every `#[julia]` item here is bound to Julia by `@rust_crate`, which runs in
//! the package's `src/RustCrateMacro.jl` while the package is precompiled: it
//! scans this crate, builds it, and defines the generated module
//! `RustCrateMacro.Bindings` in memory. The crate contains no Julia and the
//! package contains no `deps/build.jl`.
//!
//! Nothing here knows about the inline `rust"""` block in
//! `src/RustCrateMacro.jl`: the crate and the block become two independent
//! libraries. `test/runtests.jl` checks that they coexist, including a
//! same-named `add` defined in a scratch module, which must resolve to that
//! module's library rather than to this crate's.

use rustcall_julia_macros::julia;

// ============================================================================
// Simple functions
// ============================================================================

/// Add two integers
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

/// Multiply two floating-point numbers
#[julia]
fn multiply(a: f64, b: f64) -> f64 {
    a * b
}

/// Upper-case a string (owned `String` in and out)
#[julia]
fn shout(input: String) -> String {
    input.to_uppercase()
}

/// Join two borrowed strings with a separator
#[julia]
fn join_repeat(a: &str, b: &str, sep: &str, times: u32) -> String {
    let piece = format!("{a}{sep}{b}");
    std::iter::repeat_n(piece, times as usize)
        .collect::<Vec<_>>()
        .join(sep)
}

// ============================================================================
// Result / Option
// ============================================================================

/// Safe division: `Err(-1)` when dividing by zero
#[julia]
fn safe_divide(a: f64, b: f64) -> Result<f64, i32> {
    if b == 0.0 {
        Err(-1)
    } else {
        Ok(a / b)
    }
}

/// Square root of a non-negative number, `None` otherwise
#[julia]
fn safe_sqrt(n: f64) -> Option<f64> {
    if n < 0.0 {
        None
    } else {
        Some(n.sqrt())
    }
}

// ============================================================================
// A struct with methods
// ============================================================================

/// A 2D point
#[julia]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[julia]
impl Point {
    /// Create a new point
    #[julia]
    pub fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    /// Distance from the origin
    #[julia]
    pub fn norm(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }

    /// Translate the point by `dx`, `dy` (`&mut self`)
    #[julia]
    pub fn translate(&mut self, dx: f64, dy: f64) {
        self.x += dx;
        self.y += dy;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add() {
        assert_eq!(add(2, 3), 5);
    }

    #[test]
    fn test_multiply() {
        assert!((multiply(2.0, 3.0) - 6.0).abs() < 1e-10);
    }

    #[test]
    fn test_safe_divide() {
        assert_eq!(safe_divide(10.0, 2.0), Ok(5.0));
        assert_eq!(safe_divide(10.0, 0.0), Err(-1));
    }

    #[test]
    fn test_safe_sqrt() {
        assert_eq!(safe_sqrt(4.0), Some(2.0));
        assert_eq!(safe_sqrt(-1.0), None);
    }

    #[test]
    fn test_point() {
        let p = Point::new(3.0, 4.0);
        assert!((p.norm() - 5.0).abs() < 1e-10);
    }
}
