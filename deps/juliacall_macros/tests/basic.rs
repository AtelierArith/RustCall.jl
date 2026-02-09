#![allow(clippy::not_unsafe_ptr_arg_deref)]

use juliacall_macros::julia;

// Test that #[julia] on functions compiles correctly
#[julia]
fn simple_add(a: i32, b: i32) -> i32 {
    a + b
}

// Test that #[julia] on pub fn compiles correctly
#[julia]
pub fn public_multiply(a: f64, b: f64) -> f64 {
    a * b
}

// ============================================================================
// Result<T, E> tests
// ============================================================================

// Test Result<T, E> returning function
#[julia]
fn divide(a: f64, b: f64) -> Result<f64, i32> {
    if b == 0.0 {
        Err(-1)
    } else {
        Ok(a / b)
    }
}

// Test Result with different types
#[julia]
fn parse_positive(n: i32) -> Result<u32, i32> {
    if n >= 0 {
        Ok(n as u32)
    } else {
        Err(n)
    }
}

// ============================================================================
// Option<T> tests
// ============================================================================

// Test Option<T> returning function
#[julia]
fn safe_divide(a: f64, b: f64) -> Option<f64> {
    if b == 0.0 {
        None
    } else {
        Some(a / b)
    }
}

// Test Option with integer type
#[julia]
fn find_first_positive(a: i32, b: i32) -> Option<i32> {
    if a > 0 {
        Some(a)
    } else if b > 0 {
        Some(b)
    } else {
        None
    }
}

// Test that #[julia] on structs compiles correctly
#[julia]
pub struct TestPoint {
    pub x: f64,
    pub y: f64,
}

// Test impl block with #[julia] methods
pub struct Counter {
    value: i32,
}

#[julia]
impl Counter {
    #[julia]
    pub fn new(initial: i32) -> Self {
        Self { value: initial }
    }

    #[julia]
    pub fn increment(&mut self) {
        self.value += 1;
    }

    #[julia]
    pub fn get_value(&self) -> i32 {
        self.value
    }
}

// ============================================================================
// Builder pattern tests (issue #160: constructor detection)
// ============================================================================

// Test that builder-pattern instance methods returning Self are NOT treated as constructors
#[allow(dead_code)]
pub struct Builder {
    x: i32,
    y: i32,
}

#[allow(clippy::new_without_default)]
#[julia]
impl Builder {
    // This IS a constructor (static method named "new")
    #[julia]
    pub fn new() -> Self {
        Self { x: 0, y: 0 }
    }

    // This is NOT a constructor — it's a builder method (has &mut self)
    #[julia]
    pub fn set_x(&mut self, x: i32) -> i32 {
        self.x = x;
        self.x
    }

    // Static method that returns Self IS a constructor
    #[julia]
    pub fn create_default() -> Self {
        Self { x: 42, y: 42 }
    }

    #[julia]
    pub fn get_x(&self) -> i32 {
        self.x
    }
}

// We need to manually declare Builder_free
#[no_mangle]
pub extern "C" fn Builder_free(ptr: *mut Builder) {
    if !ptr.is_null() {
        unsafe {
            drop(Box::from_raw(ptr));
        }
    }
}

fn main() {
    // Verify the functions are callable
    let result = simple_add(1, 2);
    assert_eq!(result, 3);

    let product = public_multiply(2.0, 3.0);
    assert!((product - 6.0).abs() < 1e-10);

    // Verify struct FFI functions exist
    let mut point = TestPoint { x: 1.0, y: 2.0 };
    let ptr = &mut point as *mut TestPoint;

    assert!((TestPoint_get_x(ptr) - 1.0).abs() < 1e-10);
    TestPoint_set_x(ptr, 5.0);
    assert!((TestPoint_get_x(ptr) - 5.0).abs() < 1e-10);

    // Verify Counter FFI functions exist
    let counter_ptr = Counter_new(10);
    assert_eq!(Counter_get_value(counter_ptr), 10);
    Counter_increment(counter_ptr);
    assert_eq!(Counter_get_value(counter_ptr), 11);
    Counter_free(counter_ptr);

    // Test Result<T, E> functions
    println!("Testing Result<T, E> functions...");

    // Test divide (success case)
    let div_result = divide(10.0, 2.0);
    assert_eq!(div_result.is_ok, 1);
    assert!((div_result.ok_value - 5.0).abs() < 1e-10);

    // Test divide (error case - division by zero)
    let div_err = divide(10.0, 0.0);
    assert_eq!(div_err.is_ok, 0);
    assert_eq!(div_err.err_value, -1);

    // Test parse_positive (success case)
    let parse_result = parse_positive(42);
    assert_eq!(parse_result.is_ok, 1);
    assert_eq!(parse_result.ok_value, 42);

    // Test parse_positive (error case)
    let parse_err = parse_positive(-5);
    assert_eq!(parse_err.is_ok, 0);
    assert_eq!(parse_err.err_value, -5);

    // Test Option<T> functions
    println!("Testing Option<T> functions...");

    // Test safe_divide (Some case)
    let opt_result = safe_divide(10.0, 2.0);
    assert_eq!(opt_result.is_some, 1);
    assert!((opt_result.value - 5.0).abs() < 1e-10);

    // Test safe_divide (None case)
    let opt_none = safe_divide(10.0, 0.0);
    assert_eq!(opt_none.is_some, 0);

    // Test find_first_positive (Some case - first arg)
    let find_result = find_first_positive(5, -3);
    assert_eq!(find_result.is_some, 1);
    assert_eq!(find_result.value, 5);

    // Test find_first_positive (Some case - second arg)
    let find_result2 = find_first_positive(-1, 10);
    assert_eq!(find_result2.is_some, 1);
    assert_eq!(find_result2.value, 10);

    // Test find_first_positive (None case)
    let find_none = find_first_positive(-1, -2);
    assert_eq!(find_none.is_some, 0);

    // Test Builder pattern (issue #160)
    println!("Testing builder pattern...");

    // Test constructor
    let builder_ptr = Builder_new();
    assert_eq!(Builder_get_x(builder_ptr), 0);

    // Test builder method (NOT a constructor — should take a pointer, not return a boxed one)
    let x_val = Builder_set_x(builder_ptr, 10);
    assert_eq!(x_val, 10);
    assert_eq!(Builder_get_x(builder_ptr), 10);

    // Test static constructor (create_default returns Self)
    let builder2_ptr = Builder_create_default();
    assert_eq!(Builder_get_x(builder2_ptr), 42);

    Builder_free(builder_ptr);
    Builder_free(builder2_ptr);

    println!("All tests passed!");
}

// We need to manually declare the Counter_free function since
// Counter doesn't have #[julia] on it directly
#[no_mangle]
pub extern "C" fn Counter_free(ptr: *mut Counter) {
    if !ptr.is_null() {
        unsafe {
            drop(Box::from_raw(ptr));
        }
    }
}
