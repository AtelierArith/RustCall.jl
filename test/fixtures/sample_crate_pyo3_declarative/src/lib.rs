//! The declarative-module fixture of the PyO3 Python-host path (#424).
//!
//! Everything is inside one `#[pymodule] mod`, so PyO3 registers `direct` and
//! `Gauge` on the imported module and `nested` on its `inner` submodule. The
//! host path must reach them at `module.direct`, `module.Gauge` and
//! `module.inner.nested`.

use pyo3::prelude::*;

#[pymodule]
mod sample_crate_pyo3_declarative {
    use pyo3::prelude::*;

    #[pyfunction]
    pub fn direct(x: i32) -> i32 {
        x * 2
    }

    #[pyclass]
    pub struct Gauge {
        #[pyo3(get, set)]
        pub value: i32,
        /// Get-only: the host binding must not expose a setter for it.
        #[pyo3(get)]
        pub label: String,
    }

    #[pymethods]
    impl Gauge {
        #[new]
        fn new(value: i32, label: String) -> Self {
            Gauge { value, label }
        }

        /// A read-only Python property: the host binding must say so.
        #[getter]
        fn doubled(&self) -> i32 {
            self.value * 2
        }
    }

    #[pymodule]
    mod inner {
        use pyo3::prelude::*;

        #[pyfunction]
        pub fn nested(x: i32) -> i32 {
            x + 100
        }
    }
}
