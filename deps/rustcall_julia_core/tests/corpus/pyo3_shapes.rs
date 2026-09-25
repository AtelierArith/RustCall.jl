// The PyO3-host hint of every position is read off its spelling (#264, PR
// #525 review): primitives, `String` / `&str`, `Vec` / `Option` bare or under
// a std root, pyo3-numpy arrays by name (bare or behind `Py` / `Bound`), and
// `Python` / `PyModule` as injected. A class, `Self` or anything else is
// opaque: the host recognises class objects by their runtime type.
use numpy::PyReadonlyArray1;
use pyo3::prelude::*;

/// Shadows `std::option::Option`; the bare name is still hinted as one.
pub struct Option<T>(pub T);

#[pyclass]
pub struct Node {
    #[pyo3(get, set)]
    pub level: i32,
    #[pyo3(get)]
    pub label: String,
}

#[pymethods]
impl Node {
    #[new]
    pub fn new(level: i32) -> Self {
        Node { level, label: String::new() }
    }

    pub fn twin(&self, py: Python<'_>) -> PyResult<Py<Self>> {
        Py::new(py, Node { level: self.level, label: String::new() })
    }

    pub fn adopt(&mut self, other: PyRef<'_, Self>) {
        self.level = other.level;
    }

    pub fn maybe(&self, other: std::option::Option<PyRef<'_, Node>>) -> i32 {
        other.map(|o| o.level).unwrap_or(0)
    }

    pub fn own(&self, other: crate::Option<i32>) -> i32 {
        other.0
    }

    pub fn shadowed(&self, other: Option<i32>) -> i32 {
        other.0
    }

    pub fn many(&self, others: Vec<Bound<'_, Node>>) -> usize {
        others.len()
    }

    pub fn sum(&self, values: PyReadonlyArray1<'_, f64>) -> f64 {
        values.as_array().sum()
    }
}

#[pyfunction]
pub fn make(level: i32) -> Node {
    Node { level, label: String::new() }
}

#[pyfunction]
pub fn find(nodes: std::vec::Vec<pyo3::Py<Node>>, name: &str) -> core::option::Option<Py<Node>> {
    let _ = name;
    nodes.into_iter().next()
}

#[pyfunction]
pub fn anything(x: Py<PyAny>) -> Py<PyAny> {
    x
}

#[pyfunction]
#[pyo3(pass_module)]
pub fn module_name(module: &Bound<'_, PyModule>) -> String {
    let _ = module;
    String::new()
}
