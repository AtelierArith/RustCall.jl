// Callbacks (#296): a `#[julia]` item may take a C-ABI function pointer. The
// wrapper passes it through as written; the manifest reports the pointer's
// own signature so the Julia side can build a `@cfunction` for it without
// reading Rust syntax.

#[julia]
pub fn apply(f: extern "C" fn(i64) -> i64, x: i64) -> i64 {
    f(x)
}

#[julia]
pub fn each(n: u32, visit: unsafe extern "C" fn(u32, f64)) {
    for i in 0..n {
        unsafe { visit(i, i as f64) }
    }
}

#[julia]
pub fn probe(cb: extern "C" fn(*const u8) -> bool) -> bool {
    cb(std::ptr::null())
}

// Not a callback the contract can build: a Rust-ABI pointer is reported as
// written, with no `callback_args`.
#[julia]
pub fn rust_abi(f: fn(i64) -> i64) -> i64 {
    f(1)
}

#[julia]
pub struct Acc {
    pub total: i64,
}

#[julia]
impl Acc {
    pub fn new(total: i64) -> Self {
        Acc { total }
    }

    pub fn fold(&self, f: extern "C" fn(i64) -> i64) -> i64 {
        f(self.total)
    }
}
