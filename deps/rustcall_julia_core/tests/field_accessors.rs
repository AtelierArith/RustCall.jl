//! Which fields of a `#[julia]` struct get a generated getter and setter
//! (#453): exactly those whose value crosses `extern "C"` on its own — a
//! primitive, a raw pointer, `()` or a `String` (as an owned buffer) — plus,
//! for a generic struct, a field typed by one of its own type parameters. A
//! `Vec<T>`, a struct by value or any other aggregate gets none, whatever the
//! field's visibility, so a struct holding one binds as an opaque handle.

use rustcall_julia_core::{
    codegen::transform_struct_crate, expand::expand, extract::extract, manifest::Mode,
    manifest::Struct,
};

const BAG: &str = r#"
    pub struct Inner { a: i32 }
    #[julia]
    pub struct Bag {
        items: Vec<i32>,
        pub xs: Vec<f64>,
        inner: Inner,
        pub shared: Inner,
        n: i32,
        pub label: String,
        name: String,
        p: *mut u8,
    }
    #[julia]
    impl Bag {
        #[julia]
        pub fn count(&self) -> usize { self.items.len() }
    }
"#;

const WITH_ACCESSORS: [&str; 4] = ["n", "label", "name", "p"];
const WITHOUT_ACCESSORS: [&str; 4] = ["items", "xs", "inner", "shared"];

fn assert_accessors(flavour: &str, bag: &Struct) {
    for field in &bag.fields {
        let expected = WITH_ACCESSORS.contains(&field.name.as_str());
        assert!(
            expected || WITHOUT_ACCESSORS.contains(&field.name.as_str()),
            "{flavour}: unexpected field {}",
            field.name
        );
        assert_eq!(field.ffi_compatible, expected, "{flavour}: {}", field.name);
        assert_eq!(
            !field.getter.is_empty(),
            expected,
            "{flavour}: {}",
            field.name
        );
        assert_eq!(
            !field.setter.is_empty(),
            expected,
            "{flavour}: {}",
            field.name
        );
    }
}

fn assert_emitted(flavour: &str, source: &str) {
    for name in WITH_ACCESSORS {
        assert!(
            source.contains(&format!("Bag_get_{name}")),
            "{flavour}: {name}"
        );
        assert!(
            source.contains(&format!("Bag_set_{name}")),
            "{flavour}: {name}"
        );
    }
    for name in WITHOUT_ACCESSORS {
        assert!(
            !source.contains(&format!("Bag_get_{name}")),
            "{flavour}: {name}"
        );
        assert!(
            !source.contains(&format!("Bag_set_{name}")),
            "{flavour}: {name}"
        );
    }
}

#[test]
fn crate_flavour_reports_and_emits_only_scalar_and_string_accessors() {
    let manifest = extract(BAG, Mode::Crate).unwrap();
    assert_accessors("crate", &manifest.structs[0]);
    // The proc macro must emit exactly what the manifest claims exists.
    let file = syn::parse_file(BAG).unwrap();
    let item = file
        .items
        .iter()
        .find_map(|item| match item {
            syn::Item::Struct(s) if s.ident == "Bag" => Some(s.clone()),
            _ => None,
        })
        .unwrap();
    assert_emitted("crate", &transform_struct_crate(item, &[]).to_string());
}

#[test]
fn inline_flavour_reports_and_emits_only_scalar_and_string_accessors() {
    let expanded = expand(BAG).unwrap();
    let bag = expanded
        .manifest
        .structs
        .iter()
        .find(|s| s.name == "Bag")
        .unwrap();
    assert_accessors("inline", bag);
    assert_emitted("inline", &expanded.source);
}

#[test]
fn generic_struct_keeps_type_parameter_fields_only() {
    let expanded = expand(
        r#"
        #[julia]
        pub struct Holder<T> { value: T, items: Vec<T> }
        impl<T> Holder<T> {
            pub fn new(value: T) -> Self { Holder { value, items: Vec::new() } }
        }
        "#,
    )
    .unwrap();
    let holder = &expanded.manifest.structs[0];
    let field = |name: &str| holder.fields.iter().find(|f| f.name == name).unwrap();
    assert_eq!(field("value").getter, "Holder_get_value");
    assert!(field("items").getter.is_empty() && field("items").setter.is_empty());
    let wrappers: Vec<&str> = holder
        .generic_wrappers
        .iter()
        .map(|w| w.name.as_str())
        .collect();
    assert!(wrappers.contains(&"Holder_get_value"));
    assert!(!wrappers.contains(&"Holder_get_items"));
    assert!(!wrappers.contains(&"Holder_set_items"));
}
