//! A crate marked for RustCall **and** for PyO3, in separate items.
//!
//! `#[julia]` is additive since #279: it keeps the annotated item and emits
//! `rustcall_<name>` next to it, inside *this* crate. The PyO3 items have no
//! entry point until RustCall generates a wrapper crate for them (#275
//! Phase 2). Both end up in one cdylib and one Julia module, which is what
//! this crate is here to prove.
//!
//! An item marked *both* ways belongs to `#[julia]`, which already exports the
//! symbol a PyO3 wrapper would want; the scan reports it through that path and
//! does not describe a second wrapper.

use juliacall_macros::julia;
use pyo3::prelude::*;

/// RustCall's own: exported by this crate as `rustcall_julia_double`.
#[julia]
pub fn julia_double(x: i32) -> i32 {
    x * 2
}

/// RustCall's own, with the string ABI.
#[julia]
pub fn julia_shout(s: String) -> String {
    format!("{}!", s.to_uppercase())
}

/// PyO3's own: the generated wrapper crate exports `rustcall_py_triple`.
#[pyfunction]
pub fn py_triple(x: i32) -> i32 {
    x * 3
}

/// Marked both ways, so `#[julia]` owns it and the PyO3 scan stands aside.
#[julia]
#[pyfunction]
pub fn shared_add(a: i32, b: i32) -> i32 {
    a + b
}

#[pyclass]
pub struct Tally {
    #[pyo3(get, set)]
    pub count: i64,
}

#[pymethods]
impl Tally {
    #[new]
    pub fn new(count: i64) -> Self {
        Tally { count }
    }

    pub fn doubled(&self) -> i64 {
        self.count * 2
    }
}
