//! Sample crate demonstrating the #[julia] attribute from lastcall_macros.
//!
//! This crate shows how to use the #[julia] attribute to create FFI-compatible
//! functions and structs that can be automatically bound to Julia.

use lastcall_macros::julia;

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
}
