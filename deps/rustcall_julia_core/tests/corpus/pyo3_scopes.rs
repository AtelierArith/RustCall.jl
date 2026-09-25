// The PyO3 host's hint (`py_shape`) is read off a type's spelling and never
// resolved (PR #525 review): a crate's own `Option`, a renamed `Py` or class
// and an aliased numpy root are hinted by what they are spelled as, or not at
// all. The host converts every value by its runtime type, so a misread hint
// costs at most a conversion of the returned value, never a call.
use pyo3::prelude::*;

#[pyclass]
pub struct Node {
    pub level: i32,
}

pub mod a {
    use pyo3::prelude::*;

    /// Shadows `std::option::Option` in `a`: still hinted as an `Option`.
    pub struct Option<T>(pub T);

    #[pyfunction]
    pub fn in_a(x: Option<i32>) -> i32 {
        x.0
    }
}

pub mod b {
    use numpy as np;
    use pyo3::prelude::*;
    use pyo3::Py as Handle;

    use crate::Node as Knot;

    #[pyfunction]
    pub fn in_b(x: Option<i32>) -> Option<i32> {
        x
    }

    /// An aliased crate root: a numpy array by its type's name.
    #[pyfunction]
    pub fn total(values: np::PyReadonlyArray1<'_, f64>) -> f64 {
        values.as_array().sum()
    }

    /// A renamed pyo3 item and a renamed class: opaque.
    #[pyfunction]
    pub fn knot(node: Handle<Knot>) -> Handle<Knot> {
        node
    }

    /// An `Option` of an opaque value is still an `Option`.
    #[pyfunction]
    pub fn anything(x: Option<Py<PyAny>>) -> Option<Py<PyAny>> {
        x
    }
}

pub mod c {
    use crate::a::*;
    use pyo3::prelude::*;

    /// The glob brings `a::Option` in: still hinted as an `Option`.
    #[pyfunction]
    pub fn via_glob(x: Option<i32>) -> i32 {
        x.0
    }

    /// A path through another module is opaque.
    #[pyfunction]
    pub fn through(x: super::a::Option<i32>, y: crate::b::Option<i32>) -> i32 {
        x.0 + y.map(|v| v.0).unwrap_or(0)
    }
}
