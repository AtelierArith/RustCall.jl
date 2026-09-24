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

/// A raw name Julia reserves (#514): PyO3 exposes it as `for`, and the Julia
/// binding is `for_`.
#[pyfunction]
fn r#for(x: i32) -> i32 {
    x + 1
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

/// A Python callable argument: a Julia function reaches Python as a callable
/// (PythonCall wraps it), and the host binding passes it through unchanged
/// (#424).
#[pyfunction]
fn apply_twice(f: Bound<'_, PyAny>, x: i32) -> PyResult<i32> {
    let once: i32 = f.call1((x,))?.extract()?;
    let twice: i32 = f.call1((once,))?.extract()?;
    Ok(twice)
}

/// An interpreter object return: the host keeps it as a `PythonCall.Py`
/// rather than converting it, which is the policy for every spelling the
/// emitter has no Julia type for (#424).
#[pyfunction]
fn echo_object(x: Py<PyAny>) -> Py<PyAny> {
    x
}

/// `#[pyo3(pass_module)]`: PyO3 injects the module object at the call, so the
/// host binding drops it from the Julia signature (#424).
#[pyfunction]
#[pyo3(pass_module)]
fn module_name(_module: &Bound<'_, PyModule>) -> String {
    "sample_crate_pyo3_host".to_string()
}

#[pyclass]
struct Point {
    #[pyo3(get, set)]
    x: f64,
    #[pyo3(get, set)]
    y: f64,
}

/// A one-argument `#[new]` whose argument maps to the untyped Julia `Any`
/// (#433): the emitted `Wrapper(obj::Any)` used to overwrite Julia's
/// synthesized single-field constructor `Wrapper(x)`, which is a hard error
/// during precompilation. The handle struct now carries an explicit inner
/// constructor, so Julia synthesizes none and the emitted one is a new method.
#[pyclass]
struct Wrapper {
    #[pyo3(get)]
    value: i32,
}

#[pymethods]
impl Wrapper {
    #[new]
    fn new(obj: Py<PyAny>) -> PyResult<Self> {
        let value: i32 = Python::attach(|py| obj.bind(py).extract().unwrap_or(0));
        Ok(Wrapper { value })
    }

    fn tag(&self) -> String {
        format!("wrapper:{}", self.value)
    }
}

/// Properties declared through accessor methods, under Python names Julia
/// reserves (#524): the host reads them under their Julia names and looks the
/// Python attribute up.
#[pyclass]
struct Gate {
    level: i32,
}

#[pymethods]
impl Gate {
    #[new]
    fn new(level: i32) -> Self {
        Gate { level }
    }

    /// The property `for`, read as `gate.for_`, writable through `set_for`.
    #[getter]
    fn r#for(&self) -> i32 {
        self.level
    }

    #[setter]
    fn set_for(&mut self, value: i32) {
        self.level = value;
    }

    /// An explicit name Julia reserves: `end`, read as `gate.end_`; get-only.
    #[getter(end)]
    fn last(&self) -> i32 {
        self.level * 2
    }

    /// A `get_` prefix PyO3 drops: the property `plain`.
    #[getter]
    fn get_plain(&self) -> i32 {
        self.level + 1
    }

    /// A getter returning another class: the host wraps it into `Point`, as
    /// it does a method's class return (PR #525 review).
    #[getter]
    fn anchor(&self, py: Python<'_>) -> PyResult<Py<Point>> {
        Py::new(
            py,
            Point {
                x: self.level as f64,
                y: 0.0,
            },
        )
    }

    /// A setter taking another class: the host passes the Python object the
    /// Julia handle holds, as it does a method's class argument.
    #[setter]
    fn set_anchor(&mut self, point: PyRef<'_, Point>) {
        self.level = point.x as i32;
    }

    /// A numpy setter: the host converts a Julia array with `numpy.asarray`,
    /// as it does a method's numpy argument.
    #[getter]
    fn samples(&self) -> i32 {
        self.level
    }

    #[setter]
    fn set_samples(&mut self, values: PyReadonlyArray1<f64>) {
        self.level = values.as_array().iter().sum::<f64>() as i32;
    }

    /// A getter returning the class through `Self` behind a wrapper: `Self`
    /// is the enclosing class however it is wrapped (PR #525 review).
    #[getter]
    fn twin(&self, py: Python<'_>) -> PyResult<Py<Self>> {
        Py::new(py, Gate { level: self.level })
    }

    /// A setter taking the class through `Self` behind a wrapper.
    #[setter]
    fn set_twin(&mut self, other: PyRef<'_, Self>) {
        self.level = other.level;
    }

    /// A method returning and taking `Self` behind wrappers, like the
    /// accessors above.
    fn copied(&self, py: Python<'_>) -> Py<Self> {
        Py::new(py, Gate { level: self.level }).unwrap()
    }

    fn level_of(&self, other: PyRef<'_, Self>) -> i32 {
        other.level
    }
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

    /// A raw method name (#514): PyO3 exposes it as `match`, a name Julia
    /// does not reserve, so the binding is `match`.
    fn r#match(&self) -> f64 {
        self.x + self.y
    }

    /// A `#[staticmethod]` returning the class itself.
    #[staticmethod]
    fn origin() -> Self {
        Point { x: 0.0, y: 0.0 }
    }

    /// A `#[classmethod]`: Python's bound descriptor passes the class, so the
    /// host binding drops that argument from the Julia signature (#424).
    #[classmethod]
    fn named_origin(_cls: &Bound<'_, pyo3::types::PyType>) -> Self {
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
    m.add_function(wrap_pyfunction!(r#for, m)?)?;
    m.add_function(wrap_pyfunction!(interpreter_token, m)?)?;
    m.add_function(wrap_pyfunction!(parse, m)?)?;
    m.add_function(wrap_pyfunction!(add_default, m)?)?;
    m.add_function(wrap_pyfunction!(total_norm, m)?)?;
    m.add_function(wrap_pyfunction!(array_sum, m)?)?;
    m.add_function(wrap_pyfunction!(doubled, m)?)?;
    m.add_function(wrap_pyfunction!(apply_twice, m)?)?;
    m.add_function(wrap_pyfunction!(echo_object, m)?)?;
    m.add_function(wrap_pyfunction!(module_name, m)?)?;
    m.add_class::<Point>()?;
    m.add_class::<Wrapper>()?;
    m.add_class::<Gate>()?;
    Ok(())
}
