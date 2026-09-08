//! What a file pulls in, and who follows it (#343).
//!
//! `include!("api.rs")` compiles the fragment's items into the module that
//! includes them. Before #343 the `#[julia]` walk read the fragment by itself,
//! which meant the PyO3 scan never saw it and an out-of-line `mod` declared
//! inside it was reported to nobody. Both scans now see every file exactly
//! once: the scan *reports* a fragment ([`PendingInclude`]) the way it reports
//! an out-of-line `mod`, and the caller — `rustcall-extract`, the only layer
//! that touches the filesystem — reads it and feeds it back at the position
//! the report carries.
//!
//! The position is what makes the two kinds different. A file of the module
//! tree is its own module; a fragment is not a module at all, so it keeps the
//! including module's path, the including `#[julia] mod` chain, and the
//! including `#[cfg]`. Only the *directory* is the fragment's own, which is
//! rustc's rule: `include!("frag/api.rs")` in `src/lib.rs` with `mod nested;`
//! inside `api.rs` wants `src/frag/nested.rs`, and it wants that whether or
//! not the `include!` sits in an inline module.

use rustcall_core::extract::{FilePosition, TreeScan};
use rustcall_core::manifest::{Manifest, Mode};

/// Scan one source at `position` and return what it pulls in.
fn pull_ins(
    scan: &mut TreeScan,
    manifest: &mut Manifest,
    source: &str,
    position: &FilePosition,
    label: &str,
) -> rustcall_core::extract::PullIns {
    scan.file(source, None, position, manifest, label)
        .unwrap_or_else(|e| panic!("scanning {label} failed: {e}"))
}

#[test]
fn an_include_is_reported_with_the_including_position() {
    let mut scan = TreeScan::new();
    let mut manifest = Manifest::new(Mode::Crate);
    let pulled = pull_ins(
        &mut scan,
        &mut manifest,
        "include!(\"api.rs\");",
        &FilePosition::module(&[], true, &[]),
        "src/lib.rs",
    );
    assert_eq!(pulled.includes.len(), 1);
    assert_eq!(pulled.includes[0].path, "api.rs");
    assert!(pulled.includes[0].position.module_path.is_empty());
    assert!(pulled.includes[0].position.symbol_path.is_empty());
    assert!(pulled.includes[0].position.marked);
    assert!(pulled.includes[0].position.reachable);
    assert!(pulled.modules.is_empty());
}

/// The fragment's items are expanded where the `include!` is written, so a
/// `#[julia] mod` around it qualifies their symbols: the reported position
/// carries that chain, and dropping it would export the fragment's items under
/// crate-root symbols (#300).
#[test]
fn an_include_inside_a_marked_module_keeps_the_symbol_chain() {
    let mut scan = TreeScan::new();
    let mut manifest = Manifest::new(Mode::Crate);
    let pulled = pull_ins(
        &mut scan,
        &mut manifest,
        "#[julia] pub mod ops { include!(\"api.rs\"); }",
        &FilePosition::module(&[], true, &[]),
        "src/lib.rs",
    );
    assert_eq!(pulled.includes.len(), 1);
    let position = &pulled.includes[0].position;
    assert_eq!(position.module_path, vec!["ops".to_string()]);
    assert_eq!(position.symbol_path, vec!["ops".to_string()]);
    assert!(position.marked);

    // And scanning the fragment at that position gives the item the module's
    // symbol, not the crate root's.
    pull_ins(
        &mut scan,
        &mut manifest,
        "#[julia] pub fn run() -> i32 { 1 }",
        position,
        "src/api.rs",
    );
    scan.finish(&mut manifest).unwrap();
    let f = &manifest.functions[0];
    assert_eq!(f.name, "run");
    assert_eq!(f.module_path, vec!["ops".to_string()]);
    assert_eq!(f.symbol, "rustcall_ops__run");
}

/// An unmarked inline module cuts the symbol chain and refuses `#[julia]`
/// items; a fragment included there inherits exactly that, so the refusal
/// happens when the fragment is scanned rather than being silently exported at
/// the crate root.
#[test]
fn an_include_inside_an_unmarked_module_inherits_the_refusal() {
    let mut scan = TreeScan::new();
    let mut manifest = Manifest::new(Mode::Crate);
    let pulled = pull_ins(
        &mut scan,
        &mut manifest,
        "pub mod ops { include!(\"api.rs\"); }",
        &FilePosition::module(&[], true, &[]),
        "src/lib.rs",
    );
    let position = &pulled.includes[0].position;
    assert!(!position.marked);
    let err = scan
        .file(
            "#[julia] pub fn run() -> i32 { 1 }",
            None,
            position,
            &mut manifest,
            "src/api.rs",
        )
        .expect_err("a #[julia] item in an unmarked module is refused");
    assert!(
        err.to_string().contains("not marked"),
        "unexpected error: {err}"
    );
}

/// The acceptance case of #343: `lib.rs` includes `api.rs`, which declares
/// `mod nested;`. The declaration is reported — with the *including* module's
/// path, because the fragment is not a module — so the caller resolves it and
/// the `#[julia]` item inside lands in the manifest.
#[test]
fn a_mod_declared_inside_a_fragment_is_reported() {
    let mut scan = TreeScan::new();
    let mut manifest = Manifest::new(Mode::Crate);
    let root = pull_ins(
        &mut scan,
        &mut manifest,
        "include!(\"api.rs\");",
        &FilePosition::module(&[], true, &[]),
        "src/lib.rs",
    );
    let fragment = pull_ins(
        &mut scan,
        &mut manifest,
        "pub mod nested;\n#[julia] pub fn from_api() -> i32 { 1 }",
        &root.includes[0].position,
        "src/api.rs",
    );
    assert_eq!(fragment.modules.len(), 1);
    assert_eq!(fragment.modules[0].name, "nested");
    assert_eq!(fragment.modules[0].module_path, vec!["nested".to_string()]);
    assert!(fragment.modules[0].dir_components.is_empty());

    pull_ins(
        &mut scan,
        &mut manifest,
        "#[julia] pub fn deep() -> i32 { 2 }",
        &FilePosition::module(
            &fragment.modules[0].module_path,
            fragment.modules[0].reachable,
            &fragment.modules[0].cfg,
        ),
        "src/nested.rs",
    );
    scan.finish(&mut manifest).unwrap();
    manifest.sort();
    let names: Vec<&str> = manifest.functions.iter().map(|f| f.name.as_str()).collect();
    assert_eq!(names, vec!["deep", "from_api"]);
    let deep = manifest
        .functions
        .iter()
        .find(|f| f.name == "deep")
        .expect("deep");
    // A **file** module is transparent to the `#[julia]` symbol scheme — the
    // proc-macro that expands `nested.rs` cannot see the `mod nested;` that
    // reaches it, so the symbol is the crate-root one (#300). What #343
    // changes is that the item is in the manifest at all: before, no `mod`
    // declared inside a fragment was ever followed.
    assert!(deep.module_path.is_empty());
    assert_eq!(deep.symbol, "rustcall_deep");
}

/// The same for PyO3: the scan that generates a wrapper crate (#275 Phase 2)
/// now sees a fragment's items too, because both scans are fed by the one
/// walk. Before #343 the `#[julia]` walk read the fragment alone and this
/// function was missing from the manifest while the wrapper still needed it.
#[test]
fn a_pyo3_item_in_a_fragment_reaches_the_manifest() {
    let mut scan = TreeScan::new();
    let mut manifest = Manifest::new(Mode::Crate);
    let root = pull_ins(
        &mut scan,
        &mut manifest,
        "pub mod api;",
        &FilePosition::module(&[], true, &[]),
        "src/lib.rs",
    );
    let api = pull_ins(
        &mut scan,
        &mut manifest,
        "include!(\"api/items.rs\");",
        &FilePosition::module(
            &root.modules[0].module_path,
            root.modules[0].reachable,
            &root.modules[0].cfg,
        ),
        "src/api.rs",
    );
    pull_ins(
        &mut scan,
        &mut manifest,
        "#[pyfunction] pub fn shout(s: String) -> String { s }\n\
         #[pyclass] pub struct Point { pub x: f64 }",
        &api.includes[0].position,
        "src/api/items.rs",
    );
    scan.finish(&mut manifest).unwrap();
    let f = manifest
        .functions
        .iter()
        .find(|f| f.name == "shout")
        .expect("the fragment's #[pyfunction] is in the manifest");
    assert_eq!(f.module_path, vec!["api".to_string()]);
    let s = manifest
        .structs
        .iter()
        .find(|s| s.name == "Point")
        .expect("the fragment's #[pyclass] is in the manifest");
    assert_eq!(s.module_path, vec!["api".to_string()]);
}

/// A fragment nested in a fragment is followed like any other, and its
/// position is still the module that started the chain.
#[test]
fn an_include_inside_a_fragment_is_reported_too() {
    let mut scan = TreeScan::new();
    let mut manifest = Manifest::new(Mode::Crate);
    let root = pull_ins(
        &mut scan,
        &mut manifest,
        "#[julia] pub mod ops { include!(\"a.rs\"); }",
        &FilePosition::module(&[], true, &[]),
        "src/lib.rs",
    );
    let first = pull_ins(
        &mut scan,
        &mut manifest,
        "include!(\"b.rs\");",
        &root.includes[0].position,
        "src/a.rs",
    );
    assert_eq!(first.includes.len(), 1);
    assert_eq!(first.includes[0].path, "b.rs");
    assert_eq!(
        first.includes[0].position.symbol_path,
        vec!["ops".to_string()]
    );
}

/// A non-literal `include!` names a file only the build knows, and is left to
/// the compiler rather than guessed at.
#[test]
fn a_non_literal_include_is_not_reported() {
    let mut scan = TreeScan::new();
    let mut manifest = Manifest::new(Mode::Crate);
    let pulled = pull_ins(
        &mut scan,
        &mut manifest,
        "include!(concat!(env!(\"OUT_DIR\"), \"/generated.rs\"));",
        &FilePosition::module(&[], true, &[]),
        "src/lib.rs",
    );
    assert!(pulled.includes.is_empty());
}

/// The `include!` item's own `#[cfg]` gates the fragment's items as much as
/// the enclosing modules' do. Dropping it made a lenient scan describe them as
/// unconditional, and a wrapper generated from that would call items the
/// dependency's feature set may not have (#343 review).
#[test]
fn an_include_carries_its_own_cfg_into_the_fragment() {
    let mut scan = TreeScan::new();
    let mut manifest = Manifest::new(Mode::Crate);
    let pulled = pull_ins(
        &mut scan,
        &mut manifest,
        "#[cfg(feature = \"python\")] include!(\"api.rs\");",
        &FilePosition::module(&[], true, &[]),
        "src/lib.rs",
    );
    assert_eq!(pulled.includes.len(), 1);
    assert_eq!(pulled.includes[0].position.enclosing_cfg.len(), 1);

    // And it reaches the items, so a consumer sees the predicate.
    pull_ins(
        &mut scan,
        &mut manifest,
        "#[julia] pub fn gated() -> i32 { 1 }\n#[pyfunction] pub fn py_gated() -> i32 { 2 }",
        &pulled.includes[0].position,
        "src/api.rs",
    );
    scan.finish(&mut manifest).unwrap();
    for name in ["gated", "py_gated"] {
        let f = manifest
            .functions
            .iter()
            .find(|f| f.name == name)
            .unwrap_or_else(|| panic!("no `{name}` in {manifest:?}"));
        assert_eq!(
            f.cfg, "feature = \"python\"",
            "{name} lost the include's cfg"
        );
        assert_eq!(f.cfg_features, vec!["python".to_string()], "{name}");
    }
}

/// A fragment that parses as items but holds something RustCall refuses must
/// fail the scan, not be skipped: the proc-macro still wraps the item, so a
/// manifest without it is a wrong answer rather than a partial one. Only a
/// *parse* failure is a "this was never a list of items" skip (#343 review).
#[test]
fn an_unsupported_item_in_a_fragment_is_an_error_not_a_skip() {
    let mut scan = TreeScan::new();
    let mut manifest = Manifest::new(Mode::Crate);
    let pulled = pull_ins(
        &mut scan,
        &mut manifest,
        "pub mod ops { include!(\"api.rs\"); }",
        &FilePosition::module(&[], true, &[]),
        "src/lib.rs",
    );
    let err = scan
        .file(
            "#[julia] pub fn run() -> i32 { 1 }",
            None,
            &pulled.includes[0].position,
            &mut manifest,
            "src/api.rs",
        )
        .expect_err("a #[julia] item in an unmarked module is refused");
    assert!(
        matches!(err, rustcall_core::extract::ExtractError::Unsupported(_)),
        "expected Unsupported, got {err:?}"
    );
}
