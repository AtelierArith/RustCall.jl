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
    let counter_ptr = rustcall_Counter_new(10);
    assert_eq!(rustcall_Counter_get_value(counter_ptr), 10);
    rustcall_Counter_increment(counter_ptr);
    assert_eq!(rustcall_Counter_get_value(counter_ptr), 11);
    Counter_free(counter_ptr);

    // Test Result<T, E> functions
    println!("Testing Result<T, E> functions...");

    // Test divide (success case)
    let div_result = rustcall_divide(10.0, 2.0);
    assert!(div_result.is_ok());
    assert!((*div_result.ok().unwrap() - 5.0).abs() < 1e-10);

    // Test divide (error case - division by zero)
    let div_err = rustcall_divide(10.0, 0.0);
    assert!(!div_err.is_ok());
    assert_eq!(*div_err.err().unwrap(), -1);

    // Test parse_positive (success case)
    let parse_result = rustcall_parse_positive(42);
    assert!(parse_result.is_ok());
    assert_eq!(*parse_result.ok().unwrap(), 42);

    // Test parse_positive (error case)
    let parse_err = rustcall_parse_positive(-5);
    assert!(!parse_err.is_ok());
    assert_eq!(*parse_err.err().unwrap(), -5);

    // Test Option<T> functions
    println!("Testing Option<T> functions...");

    // Test safe_divide (Some case)
    let opt_result = rustcall_safe_divide(10.0, 2.0);
    assert!(opt_result.is_some());
    assert!((*opt_result.some().unwrap() - 5.0).abs() < 1e-10);

    // Test safe_divide (None case)
    let opt_none = rustcall_safe_divide(10.0, 0.0);
    assert!(!opt_none.is_some());

    // Test find_first_positive (Some case - first arg)
    let find_result = rustcall_find_first_positive(5, -3);
    assert!(find_result.is_some());
    assert_eq!(*find_result.some().unwrap(), 5);

    // Test find_first_positive (Some case - second arg)
    let find_result2 = rustcall_find_first_positive(-1, 10);
    assert!(find_result2.is_some());
    assert_eq!(*find_result2.some().unwrap(), 10);

    // Test find_first_positive (None case)
    let find_none = rustcall_find_first_positive(-1, -2);
    assert!(!find_none.is_some());

    // Test Builder pattern (issue #160)
    println!("Testing builder pattern...");

    // Test constructor
    let builder_ptr = rustcall_Builder_new();
    assert_eq!(rustcall_Builder_get_x(builder_ptr), 0);

    // Test builder method (NOT a constructor — should take a pointer, not return a boxed one)
    let x_val = rustcall_Builder_set_x(builder_ptr, 10);
    assert_eq!(x_val, 10);
    assert_eq!(rustcall_Builder_get_x(builder_ptr), 10);

    // Test static constructor (create_default returns Self)
    let builder2_ptr = rustcall_Builder_create_default();
    assert_eq!(rustcall_Builder_get_x(builder2_ptr), 42);

    Builder_free(builder_ptr);
    Builder_free(builder2_ptr);

    // #279: `#[julia]` is additive, so every annotated item is still callable
    // from Rust with the signature it was written with.
    assert_eq!(simple_add(2, 3), 5);
    assert_eq!(divide(10.0, 2.0), Ok(5.0));
    assert_eq!(divide(1.0, 0.0), Err(-1));
    assert_eq!(parse_positive(7), Ok(7u32));
    assert_eq!(safe_divide(9.0, 3.0), Some(3.0));
    assert_eq!(find_first_positive(-1, -2), None);
    let mut counter = Counter::new(1);
    counter.increment();
    assert_eq!(counter.get_value(), 2);

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

// ============================================================================
// Result / Option on struct methods (#268)
// ============================================================================

#[julia]
pub struct Divider {
    pub scale: i32,
}

#[julia]
impl Divider {
    #[julia]
    pub fn new(scale: i32) -> Self {
        Divider { scale }
    }

    #[julia]
    pub fn checked_div(&self, d: i32) -> Result<i32, String> {
        if d == 0 {
            Err("zero".to_string())
        } else {
            Ok(self.scale / d)
        }
    }

    #[julia]
    pub fn ratio(&self, d: i32) -> Option<f64> {
        if d == 0 {
            None
        } else {
            Some(self.scale as f64 / d as f64)
        }
    }

    #[julia]
    pub fn describe(&self, unit: String) -> Result<String, String> {
        if unit.is_empty() {
            Err("empty".to_string())
        } else {
            Ok(format!("{} {}", self.scale, unit))
        }
    }
}

/// The generated wrappers return the C aggregates and hand an owned buffer
/// back for each string payload; the annotated methods keep their Rust
/// signatures (#268, #279).
#[test]
fn method_result_and_option_lower_to_aggregates() {
    let ptr = rustcall_Divider_new(10);

    let ok = rustcall_Divider_checked_div(ptr, 2);
    assert!(ok.is_ok());
    assert_eq!(ok.ok().copied(), Some(5));

    let err = rustcall_Divider_checked_div(ptr, 0);
    assert!(!err.is_ok());
    let buf = err.err().expect("Err payload");
    let message = unsafe { std::slice::from_raw_parts(buf.ptr as *const u8, buf.len) }.to_vec();
    assert_eq!(String::from_utf8(message).unwrap(), "zero");
    Divider_checked_div_free_rust_string(buf.ptr, buf.len, buf.cap);

    let some = rustcall_Divider_ratio(ptr, 4);
    assert!(some.is_some());
    assert_eq!(some.some().copied(), Some(2.5));
    assert!(!rustcall_Divider_ratio(ptr, 0).is_some());

    let unit = "m".to_string();
    let both = rustcall_Divider_describe(ptr, unit.as_ptr(), unit.len());
    assert!(both.is_ok());
    let buf = both.ok().expect("Ok payload");
    let text = unsafe { std::slice::from_raw_parts(buf.ptr as *const u8, buf.len) }.to_vec();
    assert_eq!(String::from_utf8(text).unwrap(), "10 m");
    Divider_describe_free_rust_string(buf.ptr, buf.len, buf.cap);

    // The methods themselves are untouched.
    let d = Divider::new(10);
    assert_eq!(d.checked_div(2), Ok(5));
    assert_eq!(d.ratio(0), None);
    assert_eq!(d.describe("m".to_string()), Ok("10 m".to_string()));

    Divider_free(ptr);
}
