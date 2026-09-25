// A PyO3 type path means what it means in the module it is written in (PR
// #525 review): one resolver (`paths::resolve_type_path`) reads the module's
// own declarations and `use` items — renames, globs of the crate's modules —
// and falls back to the prelude only for a bare name nothing else binds.
use pyo3::prelude::*;

#[pyclass]
pub struct Node {
    pub level: i32,
}

pub mod a {
    use pyo3::prelude::*;

    /// Shadows `std::option::Option` in `a`, and nowhere else.
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

    /// An aliased crate root is that crate.
    #[pyfunction]
    pub fn total(values: np::PyReadonlyArray1<'_, f64>) -> f64 {
        values.as_array().sum()
    }

    /// A renamed pyo3 item and a renamed class.
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

    /// The glob brings `a::Option` in.
    #[pyfunction]
    pub fn via_glob(x: Option<i32>) -> i32 {
        x.0
    }

    /// A path through another module names that module's item, never the
    /// prelude.
    #[pyfunction]
    pub fn through(x: super::a::Option<i32>, y: crate::b::Option<i32>) -> i32 {
        x.0 + y.map(|v| v.0).unwrap_or(0)
    }
}
