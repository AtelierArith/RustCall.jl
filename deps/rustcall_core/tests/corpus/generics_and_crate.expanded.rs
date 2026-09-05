pub struct Pair<T>
where
    T: Clone,
{
    pub left: T,
    pub right: T,
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
