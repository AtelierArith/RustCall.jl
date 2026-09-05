#[no_mangle]
pub extern "C" fn dual_add(left: i32, right: i32) -> i32 {
    left + right
}
pub struct DualCounter {
    pub value: i32,
}
#[no_mangle]
pub extern "C" fn DualCounter_free(ptr: *mut DualCounter) {
    if !ptr.is_null() {
        unsafe {
            drop(Box::from_raw(ptr));
        }
    }
}
#[no_mangle]
pub extern "C" fn DualCounter_get_value(ptr: *const DualCounter) -> i32 {
    unsafe { (*ptr).value }
}
#[no_mangle]
pub extern "C" fn DualCounter_set_value(ptr: *mut DualCounter, value: i32) {
    unsafe {
        (*ptr).value = value;
    }
}
#[no_mangle]
pub extern "C" fn DualCounter_new(value: i32) -> *mut DualCounter {
    let obj = DualCounter::new(value);
    Box::into_raw(Box::new(obj))
}
#[no_mangle]
pub extern "C" fn DualCounter_increment(ptr: *mut DualCounter, amount: i32) {
    let self_obj = unsafe { &mut *ptr };
    self_obj.increment(amount)
}
impl DualCounter {
    pub fn new(value: i32) -> Self {
        Self { value }
    }
    pub fn increment(&mut self, amount: i32) {
        self.value += amount;
    }
}
