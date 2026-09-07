//! A PyO3 crate with an **optional** pyo3 dependency.
//!
//! Every item here is an ordinary `pub fn` in every build; only the
//! `#[pyfunction]` marker is behind the `python` feature. RustCall's scan reads
//! markers *through* `cfg_attr`, so the items are discovered whether or not the
//! feature is on, and the generated wrapper crate calls the functions
//! directly — which is why a wrapper built with the feature **off** links no
//! libpython at all (`PyO3LinkPlan` mode `:python_free`).
//!
//! The pyo3 attribute is written fully qualified (`pyo3::pyfunction`) so no
//! `use` has to be gated alongside it.

/// Wrappable in either build.
#[cfg_attr(feature = "python", pyo3::pyfunction)]
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

/// Strings travel as `(ptr, len)` pairs, with pyo3 or without it.
#[cfg_attr(feature = "python", pyo3::pyfunction)]
pub fn shout(s: String) -> String {
    format!("{}!", s.to_uppercase())
}

/// A borrowed `&str` return: no string argument to borrow from, so the wrapper
/// hands Julia a view rather than a copy.
#[cfg_attr(feature = "python", pyo3::pyfunction)]
pub fn greeting() -> &'static str {
    "hello from a pyo3-optional crate"
}

/// `&str` in and `&str` out: the result may point into the owned value the
/// wrapper built from the argument, so it leaves as an owned copy, never as a
/// view into something the call has already dropped.
#[cfg_attr(feature = "python", pyo3::pyfunction)]
pub fn echo(s: &str) -> &str {
    s
}

/// The panic boundary works the same way here.
#[cfg_attr(feature = "python", pyo3::pyfunction)]
pub fn boom(n: i32) -> i32 {
    if n < 0 {
        panic!("boom: n must not be negative");
    }
    n * 2
}

/// Skipped when the scan cannot decide the predicate: the *item* is behind the
/// feature here, not just its marker, so a wrapper built for another feature
/// set would be calling something that is not there (`cfg_undecided`).
#[cfg(feature = "python")]
#[cfg_attr(feature = "python", pyo3::pyfunction)]
pub fn only_with_python() -> i32 {
    1
}

/// Skipped: not `pub`, so a wrapper crate cannot name it (rustc E0603).
#[cfg_attr(feature = "python", pyo3::pyfunction)]
fn private_add(a: i32, b: i32) -> i32 {
    let _ = (a, b);
    a + b
}

#[cfg(feature = "python")]
#[pyo3::pymodule]
fn sample_crate_pyo3_optional(m: &pyo3::Bound<'_, pyo3::types::PyModule>) -> pyo3::PyResult<()> {
    use pyo3::types::PyModuleMethods;
    m.add_function(pyo3::wrap_pyfunction!(add, m)?)?;
    Ok(())
}
