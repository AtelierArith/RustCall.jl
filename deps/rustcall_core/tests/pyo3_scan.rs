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

/// A crate that makes pyo3 optional writes its markers behind a feature gate.
/// The crate scan evaluates `#[cfg]` leniently, so the `cfg_attr` is still
/// there when the scan looks — reading only the outer attribute would hide
/// exactly the crates on the `:python_free` path.
#[test]
fn markers_nested_in_cfg_attr_are_recognised() {
    let manifest = scan(
        "#[cfg_attr(feature = \"python\", pyfunction)] pub fn gated(a: i32) -> i32 { a }\n\
         #[cfg_attr(feature = \"python\", pyo3::pyfunction)] pub fn gated_q(a: i32) -> i32 { a }\n\
         #[cfg_attr(feature = \"python\", pyclass)] pub struct G { #[cfg_attr(feature = \"python\", pyo3(get, set))] pub x: f64 }\n\
         #[cfg_attr(feature = \"python\", pymethods)] impl G {\n\
            #[cfg_attr(feature = \"python\", new)] pub fn new(x: f64) -> Self { G { x } }\n\
            #[cfg_attr(feature = \"python\", staticmethod)] pub fn zero() -> Self { G { x: 0.0 } }\n\
         }",
    );
    assert_eq!(
        function(&manifest, "gated").attribute,
        Attribute::PyFunction
    );
    assert_eq!(
        function(&manifest, "gated_q").attribute,
        Attribute::PyFunction
    );

    let g = manifest.structs.iter().find(|s| s.name == "G").unwrap();
    assert_eq!(g.attribute, Attribute::PyClass);
    assert_eq!(g.fields[0].getter, "rustcall_G_get_x");
    assert_eq!(g.fields[0].setter, "rustcall_G_set_x");
    let by = |n: &str| g.methods.iter().find(|m| m.name == n).unwrap();
    assert!(by("new").is_constructor);
    assert!(by("zero").is_static);
}

/// `#[pyo3(get)]` on a private field gives Python a descriptor, because pyo3
/// generates it inside the crate. A wrapper crate compiled outside cannot read
/// `Struct::field`, so the scan must not advertise an accessor for it.
#[test]
fn private_pyclass_fields_get_no_accessors() {
    let manifest = scan(
        "#[pyclass] pub struct P { #[pyo3(get, set)] pub open: f64, #[pyo3(get, set)] closed: f64 }",
    );
    let p = manifest.structs.iter().find(|s| s.name == "P").unwrap();
    let open = p.fields.iter().find(|f| f.name == "open").unwrap();
    let closed = p.fields.iter().find(|f| f.name == "closed").unwrap();
    assert_eq!(open.vis, "pub");
    assert!(open.ffi_compatible);
    assert_eq!(open.getter, "rustcall_P_get_open");
    assert_eq!(closed.vis, "");
    assert!(!closed.ffi_compatible);
    assert_eq!(closed.getter, "");
    assert_eq!(closed.setter, "");
}

/// A `PyResult` method must carry the same structured description a free
/// function gets: Phase 2 lowers it to an opaque error and must not have to
/// re-read the Rust type spelling (Rust syntax is parsed only here, #264).
#[test]
fn methods_record_their_return_shape() {
    let manifest = scan(
        "#[pyclass] pub struct P {}\n\
         #[pymethods] impl P {\n\
            pub fn ok(&self) -> PyResult<f64> { unimplemented!() }\n\
            pub fn plain(&self) -> f64 { 0.0 }\n\
            pub fn nothing(&self) {}\n\
            pub fn maybe(&self) -> Option<i32> { None }\n\
            pub fn fallible(&self) -> Result<i32, u8> { Ok(0) }\n\
         }",
    );
    let p = manifest.structs.iter().find(|s| s.name == "P").unwrap();
    let by = |n: &str| p.methods.iter().find(|m| m.name == n).unwrap();
    assert_eq!(by("ok").return_kind, ReturnKind::PyResult);
    assert_eq!(by("ok").ok_type, "f64");
    assert_eq!(by("ok").skip_reason, "");
    assert_eq!(by("plain").return_kind, ReturnKind::Plain);
    assert_eq!(by("nothing").return_kind, ReturnKind::Unit);
    assert_eq!(by("maybe").return_kind, ReturnKind::Option);
    assert_eq!(by("maybe").inner_type, "i32");
    assert_eq!(by("fallible").return_kind, ReturnKind::Result);
    assert_eq!(by("fallible").ok_type, "i32");
    assert_eq!(by("fallible").err_type, "u8");
}

/// A `#[julia]` struct method is reported with a return kind too, so no
/// consumer has to infer one from the type spelling.
#[test]
fn julia_methods_record_a_plain_return_kind() {
    let manifest = scan(
        "#[julia] pub struct S { pub v: i32 }\n\
         #[julia] impl S {\n\
            #[julia] pub fn get(&self) -> i32 { self.v }\n\
            #[julia] pub fn set(&mut self, v: i32) { self.v = v; }\n\
         }",
    );
    let s = manifest.structs.iter().find(|s| s.name == "S").unwrap();
    let by = |n: &str| s.methods.iter().find(|m| m.name == n).unwrap();
    assert_eq!(by("get").return_kind, ReturnKind::Plain);
    assert_eq!(by("set").return_kind, ReturnKind::Unit);
}

/// A single-file scan can only *see* an out-of-line module declaration; it
/// reports it as pending so a caller that reads files can follow it.
#[test]
fn out_of_line_modules_are_reported_as_pending() {
    let file = syn::parse_file(
        "pub mod open;\nmod closed;\n#[path = \"other.rs\"] pub mod aliased;\npub mod inline { pub mod deeper; }",
    )
    .expect("parse");
    let mut manifest = Manifest::new(Mode::Crate);
    let pending = rustcall_core::pyo3::extract_pyo3_items(&file.items, &mut manifest);

    let by = |n: &str| pending.iter().find(|m| m.name == n).unwrap();
    assert_eq!(pending.len(), 4);
    assert!(by("open").reachable);
    assert_eq!(by("open").module_path, vec!["open"]);
    assert!(by("open").dir_components.is_empty());
    assert!(!by("closed").reachable);
    assert_eq!(by("aliased").path_attr.as_deref(), Some("other.rs"));
    assert_eq!(by("deeper").module_path, vec!["inline", "deeper"]);
    // rustc resolves `mod inline { pub mod deeper; }` in `src/lib.rs` at
    // `src/inline/deeper.rs`: the inline module is a directory component.
    assert_eq!(by("deeper").dir_components, vec!["inline"]);
    // The declarations themselves contribute no items.
    assert!(manifest.functions.is_empty());
}

/// `impl C` is legal in any module that has `C` in scope, and in a multi-file
/// crate the class and its `#[pymethods]` routinely live apart. Matching them
/// per module level would silently drop every such class's methods.
#[test]
fn pymethods_attach_across_module_boundaries() {
    let manifest = scan(
        "pub mod shapes { #[pyclass] pub struct Circle { #[pyo3(get)] pub r: f64 } }\n\
         #[pymethods] impl shapes::Circle {\n\
            #[new] pub fn new(r: f64) -> Self { unimplemented!() }\n\
            pub fn area(&self) -> f64 { 0.0 }\n\
         }",
    );
    let circle = manifest
        .structs
        .iter()
        .find(|s| s.name == "Circle")
        .expect("Circle missing");
    assert_eq!(circle.module_path, vec!["shapes"]);
    let names: Vec<&str> = circle.methods.iter().map(|m| m.name.as_str()).collect();
    assert_eq!(names, vec!["new", "area"]);
    assert_eq!(circle.methods[0].symbol, "rustcall_Circle_new");
}

/// A block in the class's own module wins over a same-named class elsewhere.
#[test]
fn pymethods_prefer_the_class_in_their_own_module() {
    let manifest = scan(
        "pub mod a { #[pyclass] pub struct C {}\n\
            #[pymethods] impl C { pub fn from_a(&self) -> i32 { 1 } } }\n\
         pub mod b { #[pyclass] pub struct C {}\n\
            #[pymethods] impl C { pub fn from_b(&self) -> i32 { 2 } } }",
    );
    let in_a = manifest
        .structs
        .iter()
        .find(|s| s.module_path == vec!["a".to_string()])
        .unwrap();
    let in_b = manifest
        .structs
        .iter()
        .find(|s| s.module_path == vec!["b".to_string()])
        .unwrap();
    assert_eq!(
        in_a.methods
            .iter()
            .map(|m| m.name.as_str())
            .collect::<Vec<_>>(),
        vec!["from_a"]
    );
    assert_eq!(
        in_b.methods
            .iter()
            .map(|m| m.name.as_str())
            .collect::<Vec<_>>(),
        vec!["from_b"]
    );
}

/// When two modules define a class of the same name and an impl elsewhere
/// could mean either, the block is dropped rather than attached to a guess: a
/// wrong `Struct::method` would simply not compile in Phase 2.
#[test]
fn an_ambiguous_pymethods_target_attaches_to_nothing() {
    let manifest = scan(
        "pub mod a { #[pyclass] pub struct C {} }\n\
         pub mod b { #[pyclass] pub struct C {} }\n\
         #[pymethods] impl C { pub fn guess(&self) -> i32 { 0 } }",
    );
    assert_eq!(manifest.structs.len(), 2);
    assert!(manifest.structs.iter().all(|s| s.methods.is_empty()));
}

/// An explicit `impl a::C` names the class exactly, so it must not be
/// collapsed to `C` and then declared ambiguous.
#[test]
fn a_qualified_pymethods_target_is_not_ambiguous() {
    let manifest = scan(
        "pub mod a { #[pyclass] pub struct C {} }\n\
         pub mod b { #[pyclass] pub struct C {} }\n\
         #[pymethods] impl a::C { pub fn only_a(&self) -> i32 { 0 } }",
    );
    let in_a = manifest
        .structs
        .iter()
        .find(|s| s.module_path == vec!["a".to_string()])
        .unwrap();
    let in_b = manifest
        .structs
        .iter()
        .find(|s| s.module_path == vec!["b".to_string()])
        .unwrap();
    assert_eq!(
        in_a.methods
            .iter()
            .map(|m| m.name.as_str())
            .collect::<Vec<_>>(),
        vec!["only_a"]
    );
    assert!(in_b.methods.is_empty());
}

/// A qualifier is relative to the module the impl is in, and `crate::` names
/// the root.
#[test]
fn a_qualified_target_resolves_relative_and_absolute() {
    let manifest = scan(
        "pub mod outer {\n\
            pub mod inner { #[pyclass] pub struct C {} }\n\
            #[pymethods] impl inner::C { pub fn relative(&self) -> i32 { 0 } }\n\
         }\n\
         pub mod other { #[pyclass] pub struct D {} }\n\
         #[pymethods] impl crate::other::D { pub fn absolute(&self) -> i32 { 0 } }",
    );
    let c = manifest.structs.iter().find(|s| s.name == "C").unwrap();
    assert_eq!(c.module_path, vec!["outer", "inner"]);
    assert_eq!(
        c.methods
            .iter()
            .map(|m| m.name.as_str())
            .collect::<Vec<_>>(),
        vec!["relative"]
    );
    let d = manifest.structs.iter().find(|s| s.name == "D").unwrap();
    assert_eq!(
        d.methods
            .iter()
            .map(|m| m.name.as_str())
            .collect::<Vec<_>>(),
        vec!["absolute"]
    );
}

/// The symbol scheme is `rustcall_<name>` (#279) and carries no module path, so
/// two `pub fn run` in different modules both want `rustcall_run` — a single
/// wrapper crate cannot export both. The scan reports the clash instead of
/// describing a manifest that cannot be built.
#[test]
fn colliding_wrapper_symbols_are_reported() {
    let manifest = scan(
        "pub mod a { #[pyfunction] pub fn run() -> i32 { 1 } }\n\
         pub mod b { #[pyfunction] pub fn run() -> i32 { 2 } }",
    );
    let entries: Vec<_> = manifest
        .functions
        .iter()
        .filter(|f| f.name == "run")
        .collect();
    assert_eq!(entries.len(), 2);
    // The first in manifest order keeps the symbol; the other is skipped with
    // the module-qualified name of the owner.
    let kept: Vec<_> = entries
        .iter()
        .filter(|f| f.skip_reason.is_empty())
        .collect();
    let clashed: Vec<_> = entries
        .iter()
        .filter(|f| !f.skip_reason.is_empty())
        .collect();
    assert_eq!(kept.len(), 1);
    assert_eq!(clashed.len(), 1);
    assert_eq!(
        clashed[0].skip_reason,
        skip_reason::detailed(skip_reason::SYMBOL_COLLISION, "a::run")
    );
}

/// A `#[julia]` item is already exported under its symbol, so it owns it: a
/// PyO3 item that wants the same one loses, whatever the source order.
#[test]
fn a_julia_export_wins_a_symbol_collision() {
    let manifest = scan(
        "#[julia] pub fn run() -> i32 { 1 }\n\
         pub mod b { #[pyfunction] pub fn run() -> i32 { 2 } }",
    );
    let pyo3 = manifest
        .functions
        .iter()
        .find(|f| f.attribute == Attribute::PyFunction)
        .unwrap();
    assert_eq!(
        pyo3.skip_reason,
        skip_reason::detailed(skip_reason::SYMBOL_COLLISION, "run")
    );
    let julia = manifest
        .functions
        .iter()
        .find(|f| f.attribute == Attribute::Julia)
        .unwrap();
    assert_eq!(julia.skip_reason, "");
    assert!(julia.exported);
}

/// Two same-named `#[pyclass]`es collide over every method and accessor symbol,
/// so the class is the unit that is reported.
#[test]
fn colliding_pyclass_names_are_reported() {
    let manifest = scan(
        "pub mod a { #[pyclass] pub struct C { #[pyo3(get)] pub v: i32 }\n\
            #[pymethods] impl C { pub fn f(&self) -> i32 { 0 } } }\n\
         pub mod b { #[pyclass] pub struct C { #[pyo3(get)] pub v: i32 }\n\
            #[pymethods] impl C { pub fn g(&self) -> i32 { 0 } } }",
    );
    let in_a = manifest
        .structs
        .iter()
        .find(|s| s.module_path == vec!["a".to_string()])
        .unwrap();
    let in_b = manifest
        .structs
        .iter()
        .find(|s| s.module_path == vec!["b".to_string()])
        .unwrap();
    assert_eq!(in_a.skip_reason, "");
    assert_eq!(
        in_b.skip_reason,
        skip_reason::detailed(skip_reason::SYMBOL_COLLISION, "a::C")
    );
    // Nothing of the losing class is advertised.
    assert!(in_b.fields[0].getter.is_empty());
    assert!(!in_b.fields[0].ffi_compatible);
    assert!(in_b.methods.iter().all(|m| !m.skip_reason.is_empty()));
}

/// The features an item's `#[cfg]` predicate depends on are recorded so a
/// consumer can reconcile the scan with a feature set without reading Rust
/// `cfg` syntax itself.
#[test]
fn cfg_features_are_recorded() {
    let manifest = scan(
        "#[cfg(feature = \"python\")] #[pyfunction] pub fn gated() -> i32 { 0 }\n\
         #[cfg(all(unix, feature = \"extra\"))] #[pyfunction] pub fn both() -> i32 { 0 }\n\
         #[cfg(unix)] #[pyfunction] pub fn target_only() -> i32 { 0 }\n\
         #[pyfunction] pub fn plain() -> i32 { 0 }",
    );
    assert_eq!(function(&manifest, "gated").cfg_features, vec!["python"]);
    assert_eq!(function(&manifest, "both").cfg_features, vec!["extra"]);
    assert!(function(&manifest, "target_only").cfg_features.is_empty());
    assert!(function(&manifest, "plain").cfg_features.is_empty());
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
