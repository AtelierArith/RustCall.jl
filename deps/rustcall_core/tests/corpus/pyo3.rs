#[julia_pyo3]
pub fn dual_add(left: i32, right: i32) -> i32 {
    left + right
}

#[julia_pyo3]
pub struct DualCounter {
    pub value: i32,
}

#[julia_pyo3]
impl DualCounter {
    pub fn new(value: i32) -> Self {
        Self { value }
    }

    pub fn increment(&mut self, amount: i32) {
        self.value += amount;
    }
}
