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

// `Result` / `Option` returns on struct methods are lowered exactly like the
// free functions above: `CResult_<Struct>_<method>` / `COption_<Struct>_<method>`,
// with a `String` payload composed onto the owner's owned-string buffer (#268).
#[julia]
pub struct Divider {
    pub scale: i32,
}

#[julia]
impl Divider {
    #[julia]
    pub fn new(scale: i32) -> Self {
        Self { scale }
    }

    #[julia]
    pub fn checked_div(&self, d: i32) -> Result<i32, String> {
        if d == 0 {
            Err("division by zero".to_string())
        } else {
            Ok(self.scale / d)
        }
    }

    #[julia]
    pub fn ratio(&self, d: i32) -> Option<f64> {
        (d != 0).then(|| self.scale as f64 / d as f64)
    }

    #[julia]
    pub fn describe(&self, unit: String) -> Result<String, String> {
        if unit.is_empty() {
            Err("empty unit".to_string())
        } else {
            Ok(format!("{} {}", self.scale, unit))
        }
    }

    #[julia]
    pub fn label(&self) -> Option<&'static str> {
        (self.scale > 0).then_some("positive")
    }
}
