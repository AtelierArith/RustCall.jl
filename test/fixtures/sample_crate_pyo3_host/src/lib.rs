use numpy::{IntoPyArray, PyArray1, PyReadonlyArray1};
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

/// A defaulted argument: Julia gets one method per arity and PyO3 supplies the
/// default it was written with.
#[pyfunction]
#[pyo3(signature = (a, b = 10))]
fn add_default(a: i32, b: i32) -> i32 {
    a + b
}

/// A `Vec` of class references: the Julia side passes its `Point` handles.
#[pyfunction]
fn total_norm(points: Vec<PyRef<'_, Point>>) -> f64 {
    points.iter().map(|p| p.norm()).sum()
}

/// A numpy array argument: a Julia `AbstractVector` reaches Python as a
/// `juliacall.VectorValue`, which PyO3's extractor rejects (it wants a real
/// `numpy.ndarray`), so the host binding converts it with `numpy.asarray`
/// first (#424).
#[pyfunction]
fn array_sum(values: PyReadonlyArray1<f64>) -> f64 {
    values.as_array().iter().sum()
}

/// A numpy array return: PythonCall converts the ndarray back to a Julia
/// `Vector{Float64}` (#424).
#[pyfunction]
fn doubled(values: PyReadonlyArray1<f64>) -> Py<PyArray1<f64>> {
    let out = values.as_array().iter().map(|v| v * 2.0).collect::<Vec<_>>();
    Python::attach(|py| out.into_pyarray(py).unbind())
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

    /// A defaulted method: one Julia method per arity.
    #[pyo3(signature = (factor, offset = 0.0))]
    fn scaled_by(&self, factor: f64, offset: f64) -> PyResult<f64> {
        Ok(self.norm() * factor + offset)
    }

    /// A class-typed return written as the Rust type, not `Self`: the Julia
    /// binding wraps it into `Point`.
    fn mirrored(&self) -> Point {
        Point {
            x: -self.x,
            y: -self.y,
        }
    }

    /// A class-typed argument: the Julia binding passes the Python object the
    /// handle holds.
    fn distance_to(&self, other: &Point) -> f64 {
        ((self.x - other.x).powi(2) + (self.y - other.y).powi(2)).sqrt()
    }
}

#[pymodule]
fn sample_crate_pyo3_host(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(add, m)?)?;
    m.add_function(wrap_pyfunction!(private_add, m)?)?;
    m.add_function(wrap_pyfunction!(interpreter_token, m)?)?;
    m.add_function(wrap_pyfunction!(parse, m)?)?;
    m.add_function(wrap_pyfunction!(add_default, m)?)?;
    m.add_function(wrap_pyfunction!(total_norm, m)?)?;
    m.add_function(wrap_pyfunction!(array_sum, m)?)?;
    m.add_function(wrap_pyfunction!(doubled, m)?)?;
    m.add_class::<Point>()?;
    Ok(())
}
