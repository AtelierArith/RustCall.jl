//! The Rust half of `examples/SampleCrate.jl`.
//!
//! Every `#[julia]` item here is bound to Julia by RustCall.jl: `deps/build.jl`
//! of the package runs `RustCall.write_bindings_to_file` over this crate and
//! writes `src/generated/Bindings.jl`, which `src/SampleCrate.jl` includes and
//! wraps. The crate contains no Julia and the package contains no Rust.
//!
//! A trimmed twin of RustCall's own test fixture `test/fixtures/sample_crate`,
//! which carries extra items the test suite needs (`panicky_*`, `Divider`, …).

use juliacall_macros::julia;

// ============================================================================
// Simple Functions
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

/// Upper-case a string (String argument and return, #242)
#[julia]
fn shout(input: String) -> String {
    input.to_uppercase()
}

/// Join two borrowed strings with a separator, `times` times
#[julia]
fn join_repeat(a: &str, b: &str, sep: &str, times: u32) -> String {
    let piece = format!("{a}{sep}{b}");
    std::iter::repeat_n(piece, times as usize)
        .collect::<Vec<_>>()
        .join(sep)
}

/// Number of Unicode scalar values (not bytes) in the string
#[julia]
fn char_count(s: &str) -> usize {
    s.chars().count()
}

/// A static borrowed string
#[julia]
fn crate_greeting() -> &'static str {
    "hello from sample_crate"
}

/// Parse an integer (Result with a string argument)
#[julia]
fn parse_int(s: &str) -> Result<i32, i32> {
    s.trim().parse().map_err(|_| -1)
}

/// First Unicode scalar value (Option with a String argument)
#[julia]
fn first_char(s: String) -> Option<u32> {
    s.chars().next().map(|c| c as u32)
}

/// Lifetime-qualified borrowed string in and out
#[julia]
fn identity_str<'a>(s: &'a str) -> &'a str {
    s
}

/// Calculate the nth Fibonacci number
#[julia]
fn fibonacci(n: u32) -> u64 {
    match n {
        0 => 0,
        1 => 1,
        _ => {
            let mut a = 0u64;
            let mut b = 1u64;
            for _ in 2..=n {
                let c = a + b;
                a = b;
                b = c;
            }
            b
        }
    }
}

/// Check if a number is prime
#[julia]
fn is_prime(n: u32) -> bool {
    if n < 2 {
        return false;
    }
    if n == 2 {
        return true;
    }
    if n % 2 == 0 {
        return false;
    }
    let sqrt_n = (n as f64).sqrt() as u32;
    for i in (3..=sqrt_n).step_by(2) {
        if n % i == 0 {
            return false;
        }
    }
    true
}

// ============================================================================
// Result<T, E> Functions
// ============================================================================

/// Safe division - returns Err(-1) if dividing by zero
#[julia]
fn safe_divide(a: f64, b: f64) -> Result<f64, i32> {
    if b == 0.0 {
        Err(-1)
    } else {
        Ok(a / b)
    }
}

/// Parse a positive integer - returns Err with the original number if negative
#[julia]
fn parse_positive(n: i32) -> Result<u32, i32> {
    if n >= 0 {
        Ok(n as u32)
    } else {
        Err(n)
    }
}

// ============================================================================
// Option<T> Functions
// ============================================================================

/// Find the square root only for non-negative numbers
#[julia]
fn safe_sqrt(n: f64) -> Option<f64> {
    if n < 0.0 {
        None
    } else {
        Some(n.sqrt())
    }
}

/// Find the first positive number in two inputs
#[julia]
fn find_positive(a: i32, b: i32) -> Option<i32> {
    if a > 0 {
        Some(a)
    } else if b > 0 {
        Some(b)
    } else {
        None
    }
}

// ============================================================================
// Simple Struct
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

    /// Calculate distance from origin
    #[julia]
    pub fn distance_from_origin(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }

    /// Calculate distance to another point
    #[julia]
    pub fn distance_to(&self, other_x: f64, other_y: f64) -> f64 {
        let dx = self.x - other_x;
        let dy = self.y - other_y;
        (dx * dx + dy * dy).sqrt()
    }

    /// Translate the point by dx, dy
    #[julia]
    pub fn translate(&mut self, dx: f64, dy: f64) {
        self.x += dx;
        self.y += dy;
    }
}

// ============================================================================
// Counter Struct (demonstrates mutable state)
// ============================================================================

/// A simple counter
#[julia]
pub struct Counter {
    pub value: i32,
}

#[julia]
impl Counter {
    /// Create a new counter with initial value
    #[julia]
    pub fn new(initial: i32) -> Self {
        Counter { value: initial }
    }

    /// Increment the counter
    #[julia]
    pub fn increment(&mut self) {
        self.value += 1;
    }

    /// Decrement the counter
    #[julia]
    pub fn decrement(&mut self) {
        self.value -= 1;
    }

    /// Add a value to the counter
    #[julia]
    pub fn add(&mut self, amount: i32) {
        self.value += amount;
    }

    /// Get the current value
    #[julia]
    pub fn get(&self) -> i32 {
        self.value
    }

    /// Reset to zero
    #[julia]
    pub fn reset(&mut self) {
        self.value = 0;
    }
}

// ============================================================================
// Labeler Struct (methods with String / &str arguments and returns, #242)
// ============================================================================

/// Counts the labels it produced
#[julia]
pub struct Labeler {
    pub count: u32,
}

#[julia]
impl Labeler {
    /// Create a labeler
    #[julia]
    pub fn new(count: u32) -> Self {
        Labeler { count }
    }

    /// Owned `String` return built from a borrowed argument
    #[julia]
    pub fn label(&mut self, name: &str) -> String {
        self.count += 1;
        format!("{}#{}", name, self.count)
    }

    /// `String` argument, plain return
    #[julia]
    pub fn byte_len(&self, s: String) -> usize {
        s.len()
    }

    /// Borrowed `&str` return (no string arguments)
    #[julia]
    pub fn kind(&self) -> &str {
        "labeler"
    }

    /// `&str` return that may borrow from the argument: copied out
    #[julia]
    pub fn echo<'a>(&self, s: &'a str) -> &'a str {
        s
    }

    /// Static method with a string argument
    #[julia]
    pub fn shout(s: &str) -> String {
        s.to_uppercase()
    }
}

// ============================================================================
// Rectangle Struct (demonstrates computed properties)
// ============================================================================

/// A rectangle
#[julia]
pub struct Rectangle {
    pub width: f64,
    pub height: f64,
}

#[julia]
impl Rectangle {
    /// Create a new rectangle
    #[julia]
    pub fn new(width: f64, height: f64) -> Self {
        Rectangle { width, height }
    }

    /// Calculate area
    #[julia]
    pub fn area(&self) -> f64 {
        self.width * self.height
    }

    /// Calculate perimeter
    #[julia]
    pub fn perimeter(&self) -> f64 {
        2.0 * (self.width + self.height)
    }

    /// Check if it's a square
    #[julia]
    pub fn is_square(&self) -> bool {
        (self.width - self.height).abs() < 1e-10
    }

    /// Scale the rectangle
    #[julia]
    pub fn scale(&mut self, factor: f64) {
        self.width *= factor;
        self.height *= factor;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add() {
        assert_eq!(add(2, 3), 5);
        assert_eq!(add(-1, 1), 0);
    }

    #[test]
    fn test_multiply() {
        assert!((multiply(2.0, 3.0) - 6.0).abs() < 1e-10);
    }

    #[test]
    fn test_fibonacci() {
        assert_eq!(fibonacci(0), 0);
        assert_eq!(fibonacci(1), 1);
        assert_eq!(fibonacci(10), 55);
    }

    #[test]
    fn test_is_prime() {
        assert!(!is_prime(0));
        assert!(!is_prime(1));
        assert!(is_prime(2));
        assert!(is_prime(7));
        assert!(!is_prime(9));
    }

    #[test]
    fn test_point() {
        let p = Point::new(3.0, 4.0);
        assert!((p.distance_from_origin() - 5.0).abs() < 1e-10);
    }

    #[test]
    fn test_counter() {
        let mut c = Counter::new(0);
        c.increment();
        assert_eq!(c.get(), 1);
        c.add(5);
        assert_eq!(c.get(), 6);
    }

    #[test]
    fn test_rectangle() {
        let r = Rectangle::new(3.0, 4.0);
        assert!((r.area() - 12.0).abs() < 1e-10);
        assert!((r.perimeter() - 14.0).abs() < 1e-10);
        assert!(!r.is_square());
    }

    #[test]
    fn test_safe_divide() {
        assert_eq!(safe_divide(10.0, 2.0), Ok(5.0));
        assert_eq!(safe_divide(10.0, 0.0), Err(-1));
    }

    #[test]
    fn test_parse_positive() {
        assert_eq!(parse_positive(42), Ok(42));
        assert_eq!(parse_positive(-5), Err(-5));
    }

    #[test]
    fn test_safe_sqrt() {
        assert_eq!(safe_sqrt(4.0), Some(2.0));
        assert_eq!(safe_sqrt(-1.0), None);
    }

    #[test]
    fn test_find_positive() {
        assert_eq!(find_positive(5, -3), Some(5));
        assert_eq!(find_positive(-1, 10), Some(10));
        assert_eq!(find_positive(-1, -2), None);
    }
}
