pub struct Pair<T>
where
    T: Clone,
{
    pub left: T,
    pub right: T,
}
pub fn Pair_new<T>(left: T, right: T) -> *mut Pair<T>
where
    T: Clone,
{
    let obj = Pair::new(left, right);
    Box::into_raw(Box::new(obj))
}
pub fn Pair_first<T>(ptr: *const Pair<T>) -> T
where
    T: Clone,
{
    let self_obj = unsafe { &*ptr };
    self_obj.first()
}
pub fn Pair_inline_only<T>(ptr: *const Pair<T>) -> T
where
    T: Clone,
{
    let self_obj = unsafe { &*ptr };
    self_obj.inline_only()
}
pub fn Pair_get_left<T>(ptr: *const Pair<T>) -> T
where
    T: Clone,
    T: Copy,
{
    unsafe { (*ptr).left }
}
pub fn Pair_set_left<T>(ptr: *mut Pair<T>, value: T)
where
    T: Clone,
{
    unsafe {
        (*ptr).left = value;
    }
}
pub fn Pair_get_right<T>(ptr: *const Pair<T>) -> T
where
    T: Clone,
    T: Copy,
{
    unsafe { (*ptr).right }
}
pub fn Pair_set_right<T>(ptr: *mut Pair<T>, value: T)
where
    T: Clone,
{
    unsafe {
        (*ptr).right = value;
    }
}
pub fn Pair_free<T>(ptr: *mut Pair<T>)
where
    T: Clone,
{
    if !ptr.is_null() {
        unsafe {
            drop(Box::from_raw(ptr));
        }
    }
}
impl<T> Pair<T>
where
    T: Clone,
{
    pub fn new(left: T, right: T) -> Self {
        Self { left, right }
    }
    pub fn first(&self) -> T {
        self.left.clone()
    }
    pub fn inline_only(&self) -> T {
        self.right.clone()
    }
}
pub fn generic_identity<T>(value: T) -> T
where
    T: Clone,
{
    value
}
#[no_mangle]
pub extern "C" fn raw_increment(value: u32) -> u32 {
    value + 1
}
