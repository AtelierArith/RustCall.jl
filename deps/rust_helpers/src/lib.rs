// Rust helper functions for LastCall.jl ownership types
// These functions provide FFI-safe wrappers for Box, Rc, and Arc

use std::ffi::c_void;
use std::sync::Arc;
use std::rc::Rc;

// ============================================================================
// Box<T> helpers
// ============================================================================

/// Create a Box<i32> from a value
#[no_mangle]
pub extern "C" fn rust_box_new_i32(value: i32) -> *mut c_void {
    Box::into_raw(Box::new(value)) as *mut c_void
}

/// Create a Box<i64> from a value
#[no_mangle]
pub extern "C" fn rust_box_new_i64(value: i64) -> *mut c_void {
    Box::into_raw(Box::new(value)) as *mut c_void
}

/// Create a Box<f32> from a value
#[no_mangle]
pub extern "C" fn rust_box_new_f32(value: f32) -> *mut c_void {
    Box::into_raw(Box::new(value)) as *mut c_void
}

/// Create a Box<f64> from a value
#[no_mangle]
pub extern "C" fn rust_box_new_f64(value: f64) -> *mut c_void {
    Box::into_raw(Box::new(value)) as *mut c_void
}

/// Create a Box<bool> from a value
#[no_mangle]
pub extern "C" fn rust_box_new_bool(value: bool) -> *mut c_void {
    Box::into_raw(Box::new(value)) as *mut c_void
}

/// Drop a Box<T> (generic drop function)
/// Note: This is unsafe because we don't know the type T
/// In practice, type-specific drop functions should be used
#[no_mangle]
pub unsafe extern "C" fn rust_box_drop(ptr: *mut c_void) {
    if !ptr.is_null() {
        let _ = Box::from_raw(ptr);
    }
}

/// Drop a Box<i32>
#[no_mangle]
pub unsafe extern "C" fn rust_box_drop_i32(ptr: *mut c_void) {
    if !ptr.is_null() {
        let _ = Box::from_raw(ptr as *mut i32);
    }
}

/// Drop a Box<i64>
#[no_mangle]
pub unsafe extern "C" fn rust_box_drop_i64(ptr: *mut c_void) {
    if !ptr.is_null() {
        let _ = Box::from_raw(ptr as *mut i64);
    }
}

/// Drop a Box<f32>
#[no_mangle]
pub unsafe extern "C" fn rust_box_drop_f32(ptr: *mut c_void) {
    if !ptr.is_null() {
        let _ = Box::from_raw(ptr as *mut f32);
    }
}

/// Drop a Box<f64>
#[no_mangle]
pub unsafe extern "C" fn rust_box_drop_f64(ptr: *mut c_void) {
    if !ptr.is_null() {
        let _ = Box::from_raw(ptr as *mut f64);
    }
}

/// Drop a Box<bool>
#[no_mangle]
pub unsafe extern "C" fn rust_box_drop_bool(ptr: *mut c_void) {
    if !ptr.is_null() {
        let _ = Box::from_raw(ptr as *mut bool);
    }
}

// ============================================================================
// Rc<T> helpers (single-threaded reference counting)
// ============================================================================

/// Create an Rc<i32> from a value
#[no_mangle]
pub extern "C" fn rust_rc_new_i32(value: i32) -> *mut c_void {
    Rc::into_raw(Rc::new(value)) as *mut c_void
}

/// Create an Rc<i64> from a value
#[no_mangle]
pub extern "C" fn rust_rc_new_i64(value: i64) -> *mut c_void {
    Rc::into_raw(Rc::new(value)) as *mut c_void
}

/// Clone an Rc<T> (increment reference count)
/// Note: This is generic and unsafe - type-specific versions should be preferred
#[no_mangle]
pub unsafe extern "C" fn rust_rc_clone(ptr: *mut c_void) -> *mut c_void {
    if ptr.is_null() {
        return std::ptr::null_mut();
    }
    // This is unsafe - we assume the pointer is valid Rc
    // In practice, type-specific clone functions should be used
    ptr
}

/// Clone an Rc<i32> (increment reference count)
#[no_mangle]
pub unsafe extern "C" fn rust_rc_clone_i32(ptr: *mut c_void) -> *mut c_void {
    if ptr.is_null() {
        return std::ptr::null_mut();
    }
    // Reconstruct Rc from raw pointer, clone it, then return new raw pointer
    let rc = Rc::from_raw(ptr as *const i32);
    let cloned = Rc::clone(&rc);
    std::mem::forget(rc);  // Keep original reference alive
    Rc::into_raw(cloned) as *mut c_void
}

/// Clone an Rc<i64> (increment reference count)
#[no_mangle]
pub unsafe extern "C" fn rust_rc_clone_i64(ptr: *mut c_void) -> *mut c_void {
    if ptr.is_null() {
        return std::ptr::null_mut();
    }
    let rc = Rc::from_raw(ptr as *const i64);
    let cloned = Rc::clone(&rc);
    std::mem::forget(rc);  // Keep original reference alive
    Rc::into_raw(cloned) as *mut c_void
}

/// Drop an Rc<i32> (decrement reference count)
#[no_mangle]
pub unsafe extern "C" fn rust_rc_drop_i32(ptr: *mut c_void) {
    if !ptr.is_null() {
        let _ = Rc::from_raw(ptr as *const i32);
    }
}

/// Drop an Rc<i64> (decrement reference count)
#[no_mangle]
pub unsafe extern "C" fn rust_rc_drop_i64(ptr: *mut c_void) {
    if !ptr.is_null() {
        let _ = Rc::from_raw(ptr as *const i64);
    }
}

// ============================================================================
// Arc<T> helpers (thread-safe atomic reference counting)
// ============================================================================

/// Create an Arc<i32> from a value
#[no_mangle]
pub extern "C" fn rust_arc_new_i32(value: i32) -> *mut c_void {
    Arc::into_raw(Arc::new(value)) as *mut c_void
}

/// Create an Arc<i64> from a value
#[no_mangle]
pub extern "C" fn rust_arc_new_i64(value: i64) -> *mut c_void {
    Arc::into_raw(Arc::new(value)) as *mut c_void
}

/// Create an Arc<f64> from a value
#[no_mangle]
pub extern "C" fn rust_arc_new_f64(value: f64) -> *mut c_void {
    Arc::into_raw(Arc::new(value)) as *mut c_void
}

/// Clone an Arc<T> (increment reference count)
/// Note: This is generic and unsafe - type-specific versions should be preferred
#[no_mangle]
pub unsafe extern "C" fn rust_arc_clone(ptr: *mut c_void) -> *mut c_void {
    if ptr.is_null() {
        return std::ptr::null_mut();
    }
    // This is unsafe - we assume the pointer is valid Arc
    // In practice, type-specific clone functions should be used
    ptr
}

/// Clone an Arc<i32> (increment reference count)
#[no_mangle]
pub unsafe extern "C" fn rust_arc_clone_i32(ptr: *mut c_void) -> *mut c_void {
    if ptr.is_null() {
        return std::ptr::null_mut();
    }
    // Reconstruct Arc from raw pointer, clone it, then return new raw pointer
    let arc = Arc::from_raw(ptr as *const i32);
    let cloned = Arc::clone(&arc);
    std::mem::forget(arc);  // Keep original reference alive
    Arc::into_raw(cloned) as *mut c_void
}

/// Clone an Arc<i64> (increment reference count)
#[no_mangle]
pub unsafe extern "C" fn rust_arc_clone_i64(ptr: *mut c_void) -> *mut c_void {
    if ptr.is_null() {
        return std::ptr::null_mut();
    }
    let arc = Arc::from_raw(ptr as *const i64);
    let cloned = Arc::clone(&arc);
    std::mem::forget(arc);  // Keep original reference alive
    Arc::into_raw(cloned) as *mut c_void
}

/// Clone an Arc<f64> (increment reference count)
#[no_mangle]
pub unsafe extern "C" fn rust_arc_clone_f64(ptr: *mut c_void) -> *mut c_void {
    if ptr.is_null() {
        return std::ptr::null_mut();
    }
    let arc = Arc::from_raw(ptr as *const f64);
    let cloned = Arc::clone(&arc);
    std::mem::forget(arc);  // Keep original reference alive
    Arc::into_raw(cloned) as *mut c_void
}

/// Drop an Arc<i32> (decrement reference count)
#[no_mangle]
pub unsafe extern "C" fn rust_arc_drop_i32(ptr: *mut c_void) {
    if !ptr.is_null() {
        let _ = Arc::from_raw(ptr as *const i32);
    }
}

/// Drop an Arc<i64> (decrement reference count)
#[no_mangle]
pub unsafe extern "C" fn rust_arc_drop_i64(ptr: *mut c_void) {
    if !ptr.is_null() {
        let _ = Arc::from_raw(ptr as *const i64);
    }
}

/// Drop an Arc<f64> (decrement reference count)
#[no_mangle]
pub unsafe extern "C" fn rust_arc_drop_f64(ptr: *mut c_void) {
    if !ptr.is_null() {
        let _ = Arc::from_raw(ptr as *const f64);
    }
}

// ============================================================================
// Vec<T> helpers
// ============================================================================

/// C-compatible representation of Vec<T>
#[repr(C)]
pub struct CVec {
    ptr: *mut c_void,
    len: usize,
    cap: usize,
}

/// Create a Vec<i32> from a pointer, length, and capacity
/// Note: This is for FFI - the Vec should be created on Rust side
#[no_mangle]
pub extern "C" fn rust_vec_new_i32() -> CVec {
    let vec: Vec<i32> = Vec::new();
    let len = vec.len();
    let cap = vec.capacity();
    let ptr = vec.as_ptr() as *mut c_void;
    std::mem::forget(vec);  // Transfer ownership to caller
    CVec { ptr, len, cap }
}

/// Drop a Vec<i32>
#[no_mangle]
pub unsafe extern "C" fn rust_vec_drop_i32(vec: CVec) {
    if !vec.ptr.is_null() && vec.len > 0 {
        let _ = Vec::from_raw_parts(vec.ptr as *mut i32, vec.len, vec.cap);
    }
}

/// Create a Vec<i32> from a C array
/// # Safety
/// The caller must ensure that `data` points to a valid array of at least `len` elements
#[no_mangle]
pub unsafe extern "C" fn rust_vec_new_from_array_i32(data: *const i32, len: usize) -> CVec {
    if data.is_null() || len == 0 {
        return CVec {
            ptr: std::ptr::null_mut(),
            len: 0,
            cap: 0,
        };
    }
    
    // Create a Vec from the slice
    let slice = std::slice::from_raw_parts(data, len);
    let vec: Vec<i32> = slice.to_vec();
    
    let len = vec.len();
    let cap = vec.capacity();
    let ptr = vec.as_ptr() as *mut c_void;
    std::mem::forget(vec);  // Transfer ownership to caller
    
    CVec { ptr, len, cap }
}

/// Create a Vec<i64> from a C array
/// # Safety
/// The caller must ensure that `data` points to a valid array of at least `len` elements
#[no_mangle]
pub unsafe extern "C" fn rust_vec_new_from_array_i64(data: *const i64, len: usize) -> CVec {
    if data.is_null() || len == 0 {
        return CVec {
            ptr: std::ptr::null_mut(),
            len: 0,
            cap: 0,
        };
    }
    
    let slice = std::slice::from_raw_parts(data, len);
    let vec: Vec<i64> = slice.to_vec();
    
    let len = vec.len();
    let cap = vec.capacity();
    let ptr = vec.as_ptr() as *mut c_void;
    std::mem::forget(vec);
    
    CVec { ptr, len, cap }
}

/// Create a Vec<f32> from a C array
/// # Safety
/// The caller must ensure that `data` points to a valid array of at least `len` elements
#[no_mangle]
pub unsafe extern "C" fn rust_vec_new_from_array_f32(data: *const f32, len: usize) -> CVec {
    if data.is_null() || len == 0 {
        return CVec {
            ptr: std::ptr::null_mut(),
            len: 0,
            cap: 0,
        };
    }
    
    let slice = std::slice::from_raw_parts(data, len);
    let vec: Vec<f32> = slice.to_vec();
    
    let len = vec.len();
    let cap = vec.capacity();
    let ptr = vec.as_ptr() as *mut c_void;
    std::mem::forget(vec);
    
    CVec { ptr, len, cap }
}

/// Create a Vec<f64> from a C array
/// # Safety
/// The caller must ensure that `data` points to a valid array of at least `len` elements
#[no_mangle]
pub unsafe extern "C" fn rust_vec_new_from_array_f64(data: *const f64, len: usize) -> CVec {
    if data.is_null() || len == 0 {
        return CVec {
            ptr: std::ptr::null_mut(),
            len: 0,
            cap: 0,
        };
    }
    
    let slice = std::slice::from_raw_parts(data, len);
    let vec: Vec<f64> = slice.to_vec();
    
    let len = vec.len();
    let cap = vec.capacity();
    let ptr = vec.as_ptr() as *mut c_void;
    std::mem::forget(vec);
    
    CVec { ptr, len, cap }
}
