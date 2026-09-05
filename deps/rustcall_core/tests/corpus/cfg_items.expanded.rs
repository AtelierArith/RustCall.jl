//! `#[cfg]` predicates are recorded in the manifest. Without a configuration
//! (as here, in the golden run) every item is reported; the CLI with
//! `--cfg-file` drops the inactive ones.
#[no_mangle]
#[cfg(unix)]
pub extern "C" fn unix_only(x: i32) -> i32 {
    x + 1
}
#[cfg(all(windows, feature = "wide"))]
#[repr(C)]
pub struct CResult_windows_wide {
    is_ok: u8,
    /// Only initialized when `is_ok == 1`. `MaybeUninit` keeps the
    /// inactive field free of validity invariants (e.g. `NonZeroU32`).
    ok_value: ::std::mem::MaybeUninit<u32>,
    /// Only initialized when `is_ok == 0`.
    err_value: ::std::mem::MaybeUninit<i32>,
}
#[cfg(all(windows, feature = "wide"))]
impl CResult_windows_wide {
    /// Wrap a `Result` in the C-compatible representation.
    pub fn new(value: Result<u32, i32>) -> Self {
        match value {
            Ok(v) => {
                Self {
                    is_ok: 1,
                    ok_value: ::std::mem::MaybeUninit::new(v),
                    err_value: ::std::mem::MaybeUninit::zeroed(),
                }
            }
            Err(e) => {
                Self {
                    is_ok: 0,
                    ok_value: ::std::mem::MaybeUninit::zeroed(),
                    err_value: ::std::mem::MaybeUninit::new(e),
                }
            }
        }
    }
    /// Whether the call succeeded.
    pub fn is_ok(&self) -> bool {
        self.is_ok == 1
    }
    /// The `Ok` value, if any.
    pub fn ok(&self) -> Option<&u32> {
        if self.is_ok == 1 {
            Some(unsafe { self.ok_value.assume_init_ref() })
        } else {
            None
        }
    }
    /// The `Err` value, if any.
    pub fn err(&self) -> Option<&i32> {
        if self.is_ok == 0 {
            Some(unsafe { self.err_value.assume_init_ref() })
        } else {
            None
        }
    }
}
#[cfg(all(windows, feature = "wide"))]
fn windows_wide_inner() -> Result<u32, i32> {
    Ok(1)
}
#[cfg(all(windows, feature = "wide"))]
#[no_mangle]
pub extern "C" fn windows_wide() -> CResult_windows_wide {
    CResult_windows_wide::new(windows_wide_inner())
}
#[cfg(not(target_os = "freebsd"))]
#[repr(C)]
pub struct COption_maybe {
    is_some: u8,
    /// Only initialized when `is_some == 1`.
    value: ::std::mem::MaybeUninit<f64>,
}
#[cfg(not(target_os = "freebsd"))]
impl COption_maybe {
    /// Wrap an `Option` in the C-compatible representation.
    pub fn new(value: Option<f64>) -> Self {
        match value {
            Some(v) => {
                Self {
                    is_some: 1,
                    value: ::std::mem::MaybeUninit::new(v),
                }
            }
            None => {
                Self {
                    is_some: 0,
                    value: ::std::mem::MaybeUninit::zeroed(),
                }
            }
        }
    }
    /// Whether a value is present.
    pub fn is_some(&self) -> bool {
        self.is_some == 1
    }
    /// The `Some` value, if any.
    pub fn some(&self) -> Option<&f64> {
        if self.is_some == 1 {
            Some(unsafe { self.value.assume_init_ref() })
        } else {
            None
        }
    }
}
#[cfg(not(target_os = "freebsd"))]
fn maybe_inner(x: f64) -> Option<f64> {
    if x > 0.0 { Some(x) } else { None }
}
#[cfg(not(target_os = "freebsd"))]
#[no_mangle]
pub extern "C" fn maybe(x: f64) -> COption_maybe {
    COption_maybe::new(maybe_inner(x))
}
#[cfg(unix)]
pub struct Handle {
    pub fd: i32,
    #[cfg(target_os = "linux")]
    pub epoll: i32,
}
#[no_mangle]
pub extern "C" fn Handle_free(ptr: *mut Handle) {
    if !ptr.is_null() {
        unsafe {
            drop(Box::from_raw(ptr));
        }
    }
}
#[no_mangle]
pub extern "C" fn Handle_get_fd(ptr: *const Handle) -> i32 {
    unsafe { (*ptr).fd }
}
#[no_mangle]
pub extern "C" fn Handle_set_fd(ptr: *mut Handle, value: i32) {
    unsafe {
        (*ptr).fd = value;
    }
}
#[no_mangle]
pub extern "C" fn Handle_get_epoll(ptr: *const Handle) -> i32 {
    unsafe { (*ptr).epoll }
}
#[no_mangle]
pub extern "C" fn Handle_set_epoll(ptr: *mut Handle, value: i32) {
    unsafe {
        (*ptr).epoll = value;
    }
}
#[no_mangle]
pub extern "C" fn Handle_fd(ptr: *const Handle) -> i32 {
    let self_obj = unsafe { &*ptr };
    self_obj.fd()
}
#[no_mangle]
pub extern "C" fn Handle_epoll(ptr: *const Handle) -> i32 {
    let self_obj = unsafe { &*ptr };
    self_obj.epoll()
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
    #[no_mangle]
    pub extern "C" fn bonus() -> i32 {
        42
    }
}
