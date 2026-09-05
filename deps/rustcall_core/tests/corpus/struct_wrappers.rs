#[derive(JuliaStruct, Clone)]
pub struct Greeter {
    pub name: String,
    pub visits: u32,
}

impl Greeter {
    pub fn new(name: String) -> Self {
        Self { name, visits: 0 }
    }

    pub fn rename(&mut self, name: String) {
        self.name = name;
    }

    pub fn greet(&self, prefix: &str) -> String {
        format!("{prefix}, {}", self.name)
    }

    pub fn name(&self) -> &str {
        &self.name
    }
}

#[julia]
pub fn checked_double(value: i32) -> Result<i32, i32> {
    value.checked_mul(2).ok_or(value)
}

#[julia]
pub fn positive(value: i32) -> Option<i32> {
    (value > 0).then_some(value)
}
