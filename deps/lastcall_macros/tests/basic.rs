use lastcall_macros::julia;

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

fn main() {
    // Verify the functions are callable
    let result = simple_add(1, 2);
    assert_eq!(result, 3);

    let product = public_multiply(2.0, 3.0);
    assert!((product - 6.0).abs() < 1e-10);

    // Verify struct FFI functions exist
    let mut point = TestPoint { x: 1.0, y: 2.0 };
    let ptr = &mut point as *mut TestPoint;

    unsafe {
        assert!((TestPoint_get_x(ptr) - 1.0).abs() < 1e-10);
        TestPoint_set_x(ptr, 5.0);
        assert!((TestPoint_get_x(ptr) - 5.0).abs() < 1e-10);
    }

    // Verify Counter FFI functions exist
    let counter_ptr = Counter_new(10);
    unsafe {
        assert_eq!(Counter_get_value(counter_ptr), 10);
        Counter_increment(counter_ptr);
        assert_eq!(Counter_get_value(counter_ptr), 11);
        Counter_free(counter_ptr);
    }

    println!("All tests passed!");
}

// We need to manually declare the Counter_free function since
// Counter doesn't have #[julia] on it directly
#[no_mangle]
pub extern "C" fn Counter_free(ptr: *mut Counter) {
    if !ptr.is_null() {
        unsafe { drop(Box::from_raw(ptr)); }
    }
}
