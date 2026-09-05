//! Sample crate demonstrating the #[julia] attribute from juliacall_macros.
//!
//! This crate shows how to use the #[julia] attribute to create FFI-compatible
//! functions and structs that can be automatically bound to Julia.

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
        // Success case
        let result = safe_divide(10.0, 2.0);
        assert_eq!(result.is_ok, 1);
        assert!((result.ok_value - 5.0).abs() < 1e-10);

        // Error case
        let err_result = safe_divide(10.0, 0.0);
        assert_eq!(err_result.is_ok, 0);
        assert_eq!(err_result.err_value, -1);
    }

    #[test]
    fn test_parse_positive() {
        // Success case
        let result = parse_positive(42);
        assert_eq!(result.is_ok, 1);
        assert_eq!(result.ok_value, 42);

        // Error case
        let err_result = parse_positive(-5);
        assert_eq!(err_result.is_ok, 0);
        assert_eq!(err_result.err_value, -5);
    }

    #[test]
    fn test_safe_sqrt() {
        // Some case
        let result = safe_sqrt(4.0);
        assert_eq!(result.is_some, 1);
        assert!((result.value - 2.0).abs() < 1e-10);

        // None case
        let none_result = safe_sqrt(-1.0);
        assert_eq!(none_result.is_some, 0);
    }

    #[test]
    fn test_find_positive() {
        // First positive
        let result = find_positive(5, -3);
        assert_eq!(result.is_some, 1);
        assert_eq!(result.value, 5);

        // Second positive
        let result2 = find_positive(-1, 10);
        assert_eq!(result2.is_some, 1);
        assert_eq!(result2.value, 10);

        // None case
        let none_result = find_positive(-1, -2);
        assert_eq!(none_result.is_some, 0);
    }
}

// Regression coverage for the #[julia] wrapper generators (#242 review): a
// Rust argument may be named like one of the locals the generated Julia
// wrapper introduces (`func_ptr`, `lib_name`, `c_result`, `c_option`). The
// wrappers must not shadow the argument with those locals.

/// Plain return with arguments named after generated locals
#[julia]
fn shadow_str_len(func_ptr: &str, lib_name: String) -> usize {
    func_ptr.len() + lib_name.len()
}

/// `Result` return with arguments named after generated locals
#[julia]
fn shadow_parse_int(func_ptr: &str, c_result: i32) -> Result<i32, i32> {
    func_ptr.trim().parse().map_err(|_| c_result)
}

/// `Option` return with arguments named after generated locals
#[julia]
fn shadow_first_char(func_ptr: String, c_option: u32) -> Option<u32> {
    func_ptr.chars().next().map(|c| c as u32 + c_option)
}

/// No strings involved, but still an argument named after a generated local
#[julia]
fn shadow_double(func_ptr: i32) -> i32 {
    func_ptr * 2
}

// Panic boundary coverage (#244). Every generated `extern "C"` wrapper runs the
// user body inside `catch_unwind` and records the message in its own channel,
// so calling these from Julia raises `RustCall.RustPanicError` instead of
// aborting the process.

/// Panics with a formatted message for a negative argument.
#[julia]
fn panicky(a: i32) -> i32 {
    if a < 0 {
        panic!("panicky called with a negative value: {}", a);
    }
    a * 2
}

/// Panics through a failed `assert!`.
#[julia]
fn panicky_assert(n: i32) -> i32 {
    assert!(n > 0, "n must be positive, got {}", n);
    n
}

/// Panics through `Option::unwrap` on `None`.
#[julia]
fn panicky_unwrap(present: bool) -> i32 {
    let value: Option<i32> = if present { Some(7) } else { None };
    value.unwrap()
}

/// Panics through an out-of-bounds index.
#[julia]
fn panicky_index(i: usize) -> i32 {
    let values = vec![10i32, 20, 30];
    values[i]
}

/// A `String`-returning function that panics: the wrapper's sentinel is an
/// empty buffer, so the channel has to be read before the buffer is decoded.
#[julia]
fn panicky_string(a: i32) -> String {
    if a < 0 {
        panic!("panicky_string refuses {}", a);
    }
    format!("value {}", a)
}

/// A `Result`-returning function that panics rather than returning `Err`.
#[julia]
fn panicky_result(a: i32) -> Result<i32, i32> {
    if a < 0 {
        panic!("panicky_result refuses {}", a);
    }
    Ok(a)
}

/// A struct whose method panics, to cover the method wrapper.
#[julia]
pub struct PanicCounter {
    pub value: i32,
}

#[julia]
impl PanicCounter {
    #[julia]
    pub fn new(value: i32) -> Self {
        PanicCounter { value }
    }

    #[julia]
    pub fn checked(&self) -> i32 {
        assert!(
            self.value > 0,
            "PanicCounter is not positive: {}",
            self.value
        );
        self.value
    }
}
