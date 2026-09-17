//! Scan-only fixture for the Python-host async policy (#424).
//!
//! `pub` so the extractor's signature check, not the `not_public` check, runs:
//! an `async fn` is `async_fn` because the host path has no event loop to drive
//! the coroutine it would return. The generator must emit no binding for it.

use pyo3::prelude::*;

#[pyfunction]
pub async fn later() -> i32 {
    1
}

#[pyfunction]
pub fn now() -> i32 {
    2
}

#[pymodule]
fn sample_crate_pyo3_async(_module: &Bound<'_, PyModule>) -> PyResult<()> {
    Ok(())
}
