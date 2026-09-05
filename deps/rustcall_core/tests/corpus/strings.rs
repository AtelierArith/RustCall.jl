//! `String` / `&str` arguments and returns on `#[julia]` free functions (#242).

#[julia]
pub fn shout(input: String) -> String {
    input.to_uppercase()
}

#[julia]
pub fn concat(a: &str, b: &str, times: u32) -> String {
    let mut out = String::new();
    for _ in 0..times {
        out.push_str(a);
        out.push_str(b);
    }
    out
}

#[julia]
pub fn byte_len(s: &str) -> usize {
    s.len()
}

#[julia]
pub fn greeting() -> &'static str {
    "hello"
}

#[cfg(unix)]
#[julia]
pub fn unix_name(s: String) -> String {
    s
}

// Parentheses and invisible groups name the same type (`(String)` is `String`).
#[julia]
pub fn consume(s: (String)) -> usize {
    s.len()
}

#[julia]
pub fn paren_ref(s: &(str)) -> (usize) {
    s.len()
}

// Struct methods with string arguments and returns: in crate mode the
// wrappers use per-method buffer types (`Greeter_shout_RustCallOwnedString`).
#[julia]
pub struct Greeter {
    pub count: u32,
}

#[julia]
impl Greeter {
    #[julia]
    pub fn new(count: u32) -> Self {
        Self { count }
    }

    #[julia]
    pub fn shout(&self, suffix: &str) -> String {
        format!("{}{}", self.count, suffix)
    }

    #[julia]
    pub fn label(&self) -> &str {
        "greeter"
    }

    #[julia]
    pub fn take(&mut self, s: String) -> usize {
        self.count += 1;
        s.len()
    }
}
