//! Unit tests for the PyO3 crate scan (#275 Phase 1).

use rustcall_core::extract::extract;
use rustcall_core::manifest::{skip_reason, Attribute, Function, Manifest, Mode, ReturnKind};

fn scan(source: &str) -> Manifest {
    extract(source, Mode::Crate).expect("failed to extract crate manifest")
}

fn function<'a>(manifest: &'a Manifest, name: &str) -> &'a Function {
    manifest
        .functions
        .iter()
        .find(|f| f.name == name)
        .unwrap_or_else(|| panic!("no function named {name} in the manifest"))
}

#[test]
fn pyfunction_is_reported_with_the_phase_two_symbol() {
    let manifest = scan("#[pyfunction] pub fn add(a: i32, b: i32) -> i32 { a + b }");
    let add = function(&manifest, "add");
    assert_eq!(add.attribute, Attribute::PyFunction);
    // The symbol describes what a Phase-2 wrapper crate will emit; nothing
    // exports it today.
    assert_eq!(add.symbol, "rustcall_add");
    assert!(!add.exported);
    assert_eq!(add.vis, "pub");
    assert_eq!(add.skip_reason, "");
}

#[test]
fn qualified_and_bare_attribute_spellings_are_both_recognised() {
    let manifest = scan(
        "#[pyo3::pyfunction] pub fn a() -> i32 { 0 }\n\
         #[pyfunction] pub fn b() -> i32 { 0 }\n\
         #[other::pyfunction] pub fn c() -> i32 { 0 }",
    );
    assert_eq!(function(&manifest, "a").attribute, Attribute::PyFunction);
    assert_eq!(function(&manifest, "b").attribute, Attribute::PyFunction);
    // A `pyfunction` attribute from some other crate is not pyo3's.
    assert!(manifest.functions.iter().all(|f| f.name != "c"));
}

/// An item carrying both attributes is owned by `#[julia]`: it already exports
/// `rustcall_<name>` (#279), so a second wrapper from the PyO3 side would
/// collide on that symbol.
#[test]
fn julia_owns_an_item_that_also_carries_pyfunction() {
    for source in [
        "#[julia] #[pyfunction] pub fn dual(a: i32) -> i32 { a }",
        "#[pyfunction] #[julia] pub fn dual(a: i32) -> i32 { a }",
    ] {
        let manifest = scan(source);
        let entries: Vec<_> = manifest
            .functions
            .iter()
            .filter(|f| f.name == "dual")
            .collect();
        assert_eq!(entries.len(), 1, "exactly one entry for {source}");
        assert_eq!(entries[0].attribute, Attribute::Julia);
        assert!(entries[0].exported);
    }
}

#[test]
fn a_pyclass_that_also_carries_julia_is_owned_by_julia() {
    let manifest = scan(
        "#[julia] #[pyclass] pub struct S { pub v: i32 }\n\
         #[julia] impl S { #[julia] pub fn new(v: i32) -> Self { S { v } } }",
    );
    let entries: Vec<_> = manifest.structs.iter().filter(|s| s.name == "S").collect();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].attribute, Attribute::Julia);
}

#[test]
fn visibility_decides_reachability() {
    let manifest = scan(
        "#[pyfunction] pub fn public_fn() {}\n\
         #[pyfunction] fn private_fn() {}\n\
         #[pyfunction] pub(crate) fn crate_fn() {}\n\
         pub mod open { #[pyfunction] pub fn deep() {} }\n\
         mod closed { #[pyfunction] pub fn buried() {} }",
    );
    assert_eq!(function(&manifest, "public_fn").skip_reason, "");
    assert_eq!(
        function(&manifest, "private_fn").skip_reason,
        skip_reason::NOT_PUBLIC
    );
    assert_eq!(function(&manifest, "crate_fn").vis, "pub(crate)");
    assert_eq!(
        function(&manifest, "crate_fn").skip_reason,
        skip_reason::NOT_PUBLIC
    );
    assert_eq!(function(&manifest, "deep").skip_reason, "");
    assert_eq!(function(&manifest, "deep").module_path, vec!["open"]);
    // `pub` inside a private module is still unreachable from a wrapper crate.
    assert_eq!(
        function(&manifest, "buried").skip_reason,
        skip_reason::NOT_PUBLIC
    );
    assert_eq!(function(&manifest, "buried").module_path, vec!["closed"]);
}

#[test]
fn a_module_item_is_reported_exactly_once() {
    let manifest = scan("pub mod inner { #[pyfunction] pub fn deep() {} }");
    let entries: Vec<_> = manifest
        .functions
        .iter()
        .filter(|f| f.name == "deep")
        .collect();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].module_path, vec!["inner"]);
}

#[test]
fn pyo3_typed_signatures_are_skipped_with_the_offending_type() {
    let manifest = scan(
        "#[pyfunction] pub fn a(py: Python<'_>) {}\n\
         #[pyfunction] pub fn b(o: &PyAny) {}\n\
         #[pyfunction] pub fn c(o: Bound<'_, PyList>) {}\n\
         #[pyfunction] pub fn d() -> PyObject { unimplemented!() }\n\
         #[pyfunction] pub fn e() -> Py<PyList> { unimplemented!() }\n\
         #[pyfunction] pub fn f(o: pyo3::PyRef<'_, i32>) {}\n\
         #[pyfunction] pub fn g(v: Vec<PyObject>) {}",
    );
    for (name, detail) in [
        ("a", "Python<'_>"),
        ("b", "PyAny"),
        ("c", "Bound<'_, PyList>"),
        ("d", "PyObject"),
        ("e", "Py<PyList>"),
        ("f", "pyo3::PyRef<'_, i32>"),
        // Nested inside another type: the walk finds it.
        ("g", "PyObject"),
    ] {
        assert_eq!(
            function(&manifest, name).skip_reason,
            skip_reason::detailed(skip_reason::PYO3_TYPE, detail),
            "skip reason of {name}"
        );
    }
}

/// `PyResult<T>` is wrappable: creating and dropping a `PyErr` needs no
/// interpreter, only rendering one does. The manifest records the `Ok` type so
/// Phase 2 can lower it to an opaque error flag.
#[test]
fn py_result_is_recorded_not_skipped() {
    let manifest = scan(
        "#[pyfunction] pub fn parse(s: &str) -> PyResult<i32> { unimplemented!() }\n\
         #[pyfunction] pub fn nothing() -> PyResult<()> { Ok(()) }\n\
         #[pyfunction] pub fn obj() -> PyResult<PyObject> { unimplemented!() }",
    );
    let parse = function(&manifest, "parse");
    assert_eq!(parse.return_kind, ReturnKind::PyResult);
    assert_eq!(parse.ok_type, "i32");
    assert_eq!(parse.err_type, "");
    assert_eq!(parse.skip_reason, "");

    assert_eq!(function(&manifest, "nothing").ok_type, "()");
    assert_eq!(function(&manifest, "nothing").skip_reason, "");

    // The `Ok` type is checked like any other type.
    let obj = function(&manifest, "obj");
    assert_eq!(obj.return_kind, ReturnKind::PyResult);
    assert_eq!(
        obj.skip_reason,
        skip_reason::detailed(skip_reason::PYO3_TYPE, "PyObject")
    );
}

#[test]
fn generic_pyfunctions_are_skipped() {
    let manifest = scan("#[pyfunction] pub fn identity<T>(x: T) -> T { x }");
    assert_eq!(
        function(&manifest, "identity").skip_reason,
        skip_reason::GENERIC
    );
}

#[test]
fn pymodule_initialisers_are_skipped() {
    let manifest = scan("#[pymodule] fn demo(m: &Bound<'_, PyModule>) -> PyResult<()> { Ok(()) }");
    let demo = function(&manifest, "demo");
    assert_eq!(demo.attribute, Attribute::PyModule);
    assert_eq!(demo.skip_reason, skip_reason::PYMODULE);
}

#[test]
fn pyclass_methods_come_from_every_pymethods_block() {
    let manifest = scan(
        "#[pyclass] pub struct Point { #[pyo3(get, set)] pub x: f64, #[pyo3(get)] pub y: f64, pub hidden: f64 }\n\
         #[pymethods] impl Point {\n\
            #[new] pub fn new(x: f64, y: f64) -> Self { unimplemented!() }\n\
            pub fn norm(&self) -> f64 { 0.0 }\n\
         }\n\
         #[pymethods] impl Point {\n\
            #[staticmethod] pub fn origin() -> Self { unimplemented!() }\n\
            #[getter] pub fn sum(&self) -> f64 { 0.0 }\n\
            #[setter(x)] pub fn set_x(&mut self, v: f64) {}\n\
         }",
    );
    let point = manifest
        .structs
        .iter()
        .find(|s| s.name == "Point")
        .expect("Point missing");
    assert_eq!(point.attribute, Attribute::PyClass);
    assert_eq!(point.skip_reason, "");

    let names: Vec<&str> = point.methods.iter().map(|m| m.name.as_str()).collect();
    assert_eq!(names, vec!["new", "norm", "origin", "sum", "set_x"]);

    let by = |n: &str| point.methods.iter().find(|m| m.name == n).unwrap();
    assert!(by("new").is_constructor);
    assert!(by("new").returns_boxed_struct);
    assert_eq!(by("new").symbol, "rustcall_Point_new");
    assert!(!by("norm").is_static);
    assert!(by("origin").is_static);
    // A static method returning `Self` also hands back an opaque handle.
    assert!(by("origin").returns_boxed_struct);
    assert!(!by("origin").is_constructor);
    assert_eq!(by("sum").accessor, "getter");
    assert_eq!(by("set_x").accessor, "setter");
    assert_eq!(by("set_x").python_name, "x");
    assert!(by("set_x").is_mutable);

    // Only `#[pyo3(get/set)]` fields are exposed, and `set` decides the setter.
    let fields: Vec<&str> = point.fields.iter().map(|f| f.name.as_str()).collect();
    assert_eq!(fields, vec!["x", "y"]);
    let x = &point.fields[0];
    assert_eq!(x.getter, "rustcall_Point_get_x");
    assert_eq!(x.setter, "rustcall_Point_set_x");
    assert_eq!(point.fields[1].setter, "");
}

#[test]
fn a_skipped_pyclass_exposes_nothing() {
    let manifest = scan(
        "#[pyclass] struct Secret { #[pyo3(get)] value: i32 }\n\
         #[pymethods] impl Secret { #[new] fn new(value: i32) -> Self { Secret { value } } }",
    );
    let secret = manifest
        .structs
        .iter()
        .find(|s| s.name == "Secret")
        .expect("Secret missing");
    assert_eq!(secret.skip_reason, skip_reason::NOT_PUBLIC);
    assert_eq!(secret.fields[0].getter, "");
    assert!(!secret.fields[0].ffi_compatible);
    assert_eq!(
        secret.methods[0].skip_reason,
        skip_reason::detailed(skip_reason::OWNER_SKIPPED, skip_reason::NOT_PUBLIC)
    );
}

#[test]
fn classmethods_are_static_and_skipped_for_their_pyo3_argument() {
    let manifest = scan(
        "#[pyclass] pub struct P {}\n\
         #[pymethods] impl P { #[classmethod] pub fn make(cls: &Bound<'_, PyType>) -> Self { unimplemented!() } }",
    );
    let p = manifest.structs.iter().find(|s| s.name == "P").unwrap();
    let make = &p.methods[0];
    assert!(make.is_static);
    assert_eq!(
        make.skip_reason,
        skip_reason::detailed(skip_reason::PYO3_TYPE, "Bound<'_, PyType>")
    );
}

#[test]
fn python_names_are_recorded() {
    let manifest = scan(
        "#[pyfunction]\n#[pyo3(name = \"double_it\")]\npub fn double(x: f64) -> f64 { x }\n\
         #[pyclass(name = \"Vector\")] pub struct Point { #[pyo3(get, name = \"label\")] pub tag: i32 }",
    );
    assert_eq!(function(&manifest, "double").python_name, "double_it");
    assert_eq!(function(&manifest, "double").name, "double");
    let point = manifest.structs.iter().find(|s| s.name == "Point").unwrap();
    assert_eq!(point.python_name, "Vector");
    assert_eq!(point.fields[0].python_name, "label");
}

/// A `#[pymethods]` block on a type that is not a `#[pyclass]` contributes
/// nothing: without the class there is no handle to hang the methods off.
#[test]
fn pymethods_without_a_pyclass_are_ignored() {
    let manifest = scan("pub struct Plain {}\n#[pymethods] impl Plain { pub fn f(&self) {} }");
    assert!(manifest.structs.is_empty());
}

/// Inline mode is unaffected: the scan is a crate-mode feature, because only
/// an external crate is scanned without being rewritten. An inline block still
/// reports its plain functions so `@rust f(...)` knows their return types, but
/// with no PyO3 origin and no PyO3 symbol.
#[test]
fn inline_mode_does_not_scan_pyo3_items() {
    let manifest = extract(
        "#[pyfunction] pub fn add(a: i32) -> i32 { a }",
        Mode::Inline,
    )
    .expect("inline expansion failed");
    let add = function(&manifest, "add");
    assert_eq!(add.attribute, Attribute::None);
    assert_eq!(add.symbol, "add");
    assert_eq!(add.skip_reason, "");
}
