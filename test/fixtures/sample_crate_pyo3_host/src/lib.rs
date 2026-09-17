use pyo3::prelude::*;

#[pyfunction]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

/// Not `pub`: an externally compiled wrapper crate cannot name it (rustc
/// E0603), but the `#[pymodule]` below registers it, so importing reaches it.
#[pyfunction]
fn private_add(a: i32, b: i32) -> i32 {
    a + b
}

/// A `Python<'_>` argument: `pyo3_type:Python<'_>` to the C-ABI scan, an
/// ordinary parameter here.
#[pyfunction]
fn interpreter_token(py: Python<'_>) -> i32 {
    let _ = py;
    7
}

/// A `PyResult`: the host path has an interpreter, so the `Err` is the real
/// message rather than the C-ABI path's fixed opaque sentence.
#[pyfunction]
fn parse(s: &str) -> PyResult<i32> {
    s.trim()
        .parse::<i32>()
        .map_err(|_| pyo3::exceptions::PyValueError::new_err(format!("not an integer: {s}")))
}

#[pyclass]
struct Point {
    #[pyo3(get, set)]
    x: f64,
    #[pyo3(get, set)]
    y: f64,
}

#[pymethods]
impl Point {
    #[new]
    fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    fn norm(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }

    /// A `#[staticmethod]` returning the class itself.
    #[staticmethod]
    fn origin() -> Self {
        Point { x: 0.0, y: 0.0 }
    }

    /// A `PyResult` method.
    fn scaled(&self, factor: f64) -> PyResult<f64> {
        Ok(self.norm() * factor)
    }
}

#[pymodule]
fn sample_crate_pyo3_host(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(add, m)?)?;
    m.add_function(wrap_pyfunction!(private_add, m)?)?;
    m.add_function(wrap_pyfunction!(interpreter_token, m)?)?;
    m.add_function(wrap_pyfunction!(parse, m)?)?;
    m.add_class::<Point>()?;
    Ok(())
}
