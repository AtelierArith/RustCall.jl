//! `#[cfg]` predicates are recorded in the manifest. Without a configuration
//! (as here, in the golden run) every item is reported; the CLI with
//! `--cfg-file` drops the inactive ones.

#[cfg(unix)]
#[julia]
pub fn unix_only(x: i32) -> i32 {
    x + 1
}

#[cfg(all(windows, feature = "wide"))]
#[julia]
pub fn windows_wide() -> Result<u32, i32> {
    Ok(1)
}

#[julia]
#[cfg(not(target_os = "freebsd"))]
pub fn maybe(x: f64) -> Option<f64> {
    if x > 0.0 { Some(x) } else { None }
}

#[cfg(unix)]
#[julia]
pub struct Handle {
    pub fd: i32,
    #[cfg(target_os = "linux")]
    pub epoll: i32,
}

impl Handle {
    pub fn fd(&self) -> i32 {
        self.fd
    }
    #[cfg(target_os = "linux")]
    pub fn epoll(&self) -> i32 {
        self.epoll
    }
}

#[cfg(feature = "extra")]
mod extra {
    #[julia]
    pub fn bonus() -> i32 {
        42
    }
}
