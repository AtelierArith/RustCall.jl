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
