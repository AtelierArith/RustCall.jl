//! A `#[julia] impl` block in another module than its struct (#315).
//!
//! The crate scan collects structs and impl blocks across the whole module
//! tree and marries them by resolved path, so the manifest lists the methods
//! the proc-macro emits wherever the block was written. The multi-file layouts
//! walk the tree the way `rustcall-extract --crate-root` does, one
//! `TreeScan::file` call per file with its real module path.

use rustcall_core::extract::{extract_crate, TreeScan};
use rustcall_core::manifest::{Manifest, Mode, Struct};

/// Scan `files` — `(module path, label, source)` — as one crate.
fn scan_tree(files: &[(&[&str], &str, &str)]) -> Result<Manifest, String> {
    let mut manifest = Manifest::new(Mode::Crate);
    let mut scan = TreeScan::new();
    for (path, label, source) in files {
        let path: Vec<String> = path.iter().map(|s| s.to_string()).collect();
        scan.file(source, None, &path, true, &[], &mut manifest, label)
            .map_err(|e| e.to_string())?;
    }
    scan.finish(&mut manifest).map_err(|e| e.to_string())?;
    manifest.sort();
    Ok(manifest)
}

fn the_struct<'a>(manifest: &'a Manifest, name: &str) -> &'a Struct {
    manifest
        .structs
        .iter()
        .find(|s| s.name == name)
        .unwrap_or_else(|| panic!("no struct `{name}` in {manifest:?}"))
}

fn method_symbols(s: &Struct) -> Vec<String> {
    let mut v: Vec<String> = s.methods.iter().map(|m| m.symbol.clone()).collect();
    v.sort();
    v
}

const LIB_RS: &str = r#"
    mod ops;
    mod more;
    #[julia] pub struct Gauge { pub value: i32 }
    #[julia] impl Gauge { #[julia] pub fn new(value: i32) -> Self { Self { value } } }
"#;

/// The layout of the issue: `struct Gauge` in `lib.rs`, `impl crate::Gauge`
/// in `ops.rs`. The proc-macro emits `rustcall_Gauge_read`; so says the
/// manifest, and the method sits on the struct.
#[test]
fn an_impl_in_a_sibling_file_binds_its_methods() {
    let manifest = scan_tree(&[
        (&[], "src/lib.rs", LIB_RS),
        (
            &["ops"],
            "src/ops.rs",
            "#[julia] impl crate::Gauge { #[julia] pub fn read(&self) -> i32 { self.value } }",
        ),
        (
            &["more"],
            "src/more.rs",
            r#"
            use crate::Gauge;
            #[julia] impl Gauge {
                #[julia] pub fn label(&self) -> String { format!("{}", self.value) }
            }
            "#,
        ),
    ])
    .unwrap();
    let gauge = the_struct(&manifest, "Gauge");
    assert_eq!(gauge.ffi_name, "Gauge");
    assert!(gauge.module_path.is_empty());
    assert_eq!(
        method_symbols(gauge),
        vec![
            "rustcall_Gauge_label",
            "rustcall_Gauge_new",
            "rustcall_Gauge_read"
        ]
    );
    // The crate flavour's wrapper declares a buffer of its own, and the
    // manifest names it rather than leaving Julia to derive it (#342).
    let label = gauge.methods.iter().find(|m| m.name == "label").unwrap();
    assert_eq!(label.return_abi, "string");
    assert_eq!(label.string_owner, "Gauge_label");
    assert!(manifest.structs.len() == 1, "{:?}", manifest.structs);
}

/// `super::Gauge` from a child file module: the file module is transparent to
/// the symbol scheme, so `super::` from `ops` is the crate root for the macro
/// as well as for the resolver.
#[test]
fn super_from_a_child_file_module_reaches_the_root_struct() {
    let manifest = scan_tree(&[
        (&[], "src/lib.rs", LIB_RS),
        (
            &["ops"],
            "src/ops.rs",
            "#[julia] impl super::Gauge { #[julia] pub fn read(&self) -> i32 { self.value } }",
        ),
    ])
    .unwrap();
    assert_eq!(
        method_symbols(the_struct(&manifest, "Gauge")),
        vec!["rustcall_Gauge_new", "rustcall_Gauge_read"]
    );
}

/// The same within one file: a marked child module through `super::` and
/// `crate::`, an unmarked one through `use`. (The golden corpus holds the full
/// manifest of this layout, `cross_module_impl.crate.toml`.)
#[test]
fn marked_and_unmarked_inline_modules_attach_to_the_root_struct() {
    let manifest = extract_crate(
        r#"
        #[julia] pub struct Gauge { pub value: i32 }
        #[julia] pub mod ops {
            #[julia] impl super::Gauge { #[julia] pub fn read(&self) -> i32 { self.value } }
        }
        #[julia] pub mod more {
            #[julia] impl crate::Gauge { #[julia] pub fn bump(&mut self) { self.value += 1 } }
        }
        pub mod plain {
            use super::Gauge;
            #[julia] impl Gauge { #[julia] pub fn twice(&self) -> i32 { self.value * 2 } }
        }
        "#,
    )
    .unwrap();
    let gauge = the_struct(&manifest, "Gauge");
    assert_eq!(
        method_symbols(gauge),
        vec![
            "rustcall_Gauge_bump",
            "rustcall_Gauge_read",
            "rustcall_Gauge_twice"
        ]
    );
    let bump = gauge.methods.iter().find(|m| m.name == "bump").unwrap();
    assert!(bump.is_mutable);
}

/// A struct in a marked module, its block in a sibling marked module by full
/// path: the symbols are the struct's (`a__C`), not the block's (`b__C`).
#[test]
fn a_full_path_names_a_struct_in_another_marked_module() {
    let manifest = extract_crate(
        r#"
        #[julia] pub mod a { #[julia] pub struct C { pub v: i32 } }
        #[julia] pub mod b {
            #[julia] impl crate::a::C { #[julia] pub fn get(&self) -> i32 { self.v } }
        }
        "#,
    )
    .unwrap();
    let c = the_struct(&manifest, "C");
    assert_eq!(c.ffi_name, "a__C");
    assert_eq!(c.module_path, vec!["a".to_string()]);
    assert_eq!(method_symbols(c), vec!["rustcall_a__C_get"]);
}

/// The resolver keeps two same-named structs apart the way the PyO3 scan does:
/// a bare `impl C` in `b` is `b::C`, `impl super::C` from `b::inner` is `b::C`,
/// `impl crate::a::C` is `a::C` wherever it is written.
#[test]
fn same_named_structs_in_two_modules_get_their_own_blocks() {
    let manifest = extract_crate(
        r#"
        #[julia] pub mod a { #[julia] pub struct C { pub v: i32 } }
        #[julia] pub mod b {
            #[julia] pub struct C { pub v: i32 }
            #[julia] impl C { #[julia] pub fn own(&self) -> i32 { self.v } }
            #[julia] pub mod inner {
                #[julia] impl super::C { #[julia] pub fn up(&self) -> i32 { self.v } }
            }
            #[julia] impl crate::a::C { #[julia] pub fn far(&self) -> i32 { self.v } }
        }
        "#,
    )
    .unwrap();
    let a = manifest
        .structs
        .iter()
        .find(|s| s.ffi_name == "a__C")
        .unwrap();
    let b = manifest
        .structs
        .iter()
        .find(|s| s.ffi_name == "b__C")
        .unwrap();
    assert_eq!(method_symbols(a), vec!["rustcall_a__C_far"]);
    assert_eq!(
        method_symbols(b),
        vec!["rustcall_b__C_own", "rustcall_b__C_up"]
    );
}

/// A block whose header names no `#[julia]` struct fails the scan with the
/// path it looked at — never a struct silently without its methods.
#[test]
fn an_unresolved_header_is_reported_not_dropped() {
    let err = scan_tree(&[
        (
            &[],
            "src/lib.rs",
            "mod ops; #[julia] pub struct Gauge { pub value: i32 }",
        ),
        (
            &["ops"],
            "src/ops.rs",
            "#[julia] impl crate::Meter { #[julia] pub fn read(&self) -> i32 { 0 } }",
        ),
    ])
    .expect_err("an impl naming no #[julia] struct must fail the scan");
    assert!(
        err.contains("`impl crate::Meter` (line 1 in src/ops.rs)"),
        "{err}"
    );
    assert!(err.contains("names no #[julia] struct"), "{err}");
    assert!(err.contains("at `crate`"), "{err}");

    // A plain struct without `#[julia]` is not a target either.
    let err = extract_crate(
        r#"
        pub struct Plain { pub v: i32 }
        #[julia] impl Plain { #[julia] pub fn get(&self) -> i32 { self.v } }
        "#,
    )
    .expect_err("a #[julia] impl of a plain struct must fail the scan")
    .to_string();
    // The struct is found — resolution follows Rust's own rules — and refused
    // for carrying no `#[julia]`, which names the fix (#315 review).
    assert!(err.contains("not a `#[julia]` struct"), "{err}");
    assert!(err.contains("the crate root"), "{err}");

    // A block with no `#[julia]` method emits nothing, whatever it names.
    let manifest = extract_crate(
        r#"
        pub struct Plain { pub v: i32 }
        #[julia] impl Plain { pub fn get(&self) -> i32 { self.v } }
        "#,
    )
    .unwrap();
    assert!(manifest.structs.is_empty());
}

/// Two structs of one name and a bare header that nothing disambiguates: the
/// scan says which two and how to pick.
#[test]
fn an_ambiguous_bare_header_is_reported() {
    let err = extract_crate(
        r#"
        #[julia] pub mod a { #[julia] pub struct C { pub v: i32 } }
        #[julia] pub mod b { #[julia] pub struct C { pub v: i32 } }
        #[julia] pub mod c {
            #[julia] impl C { #[julia] pub fn get(&self) -> i32 { self.v } }
        }
        "#,
    )
    .expect_err("an ambiguous impl header must fail the scan")
    .to_string();
    assert!(err.contains("`impl C` (line 5) is ambiguous"), "{err}");
    assert!(err.contains("`crate::a` and `crate::b`"), "{err}");
    assert!(err.contains("`impl crate::a::C`"), "{err}");
}

/// The proc-macro derives a method's symbol from the header and the marked
/// modules around the block. When that is not the struct's own path the
/// wrappers would be exported under one stem and `free` under another, so the
/// scan refuses the block and spells the header that agrees.
#[test]
fn a_header_the_macro_would_qualify_differently_is_refused() {
    // Bare `impl Gauge` inside a marked module, for the root struct: the macro
    // would emit `rustcall_ops__Gauge_read`; `Gauge_free` is the struct's.
    let err = extract_crate(
        r#"
        #[julia] pub struct Gauge { pub value: i32 }
        #[julia] pub mod ops {
            use super::Gauge;
            #[julia] impl Gauge { #[julia] pub fn read(&self) -> i32 { self.value } }
        }
        "#,
    )
    .expect_err("a header the macro qualifies differently must fail the scan")
    .to_string();
    assert!(err.contains("`impl Gauge` (line 5)"), "{err}");
    assert!(err.contains("inside the `#[julia]` module `ops`"), "{err}");
    assert!(err.contains("`rustcall_ops__Gauge_<method>`"), "{err}");
    assert!(err.contains("has the FFI name `Gauge`"), "{err}");
    assert!(
        err.contains("write the header as `impl crate::Gauge`"),
        "{err}"
    );

    // A struct in a file module named by its full path: `shapes` does not
    // qualify symbols, but the macro cannot know that from `crate::shapes::Gauge`.
    let err = scan_tree(&[
        (&[], "src/lib.rs", "mod shapes; mod ops;"),
        (
            &["shapes"],
            "src/shapes.rs",
            "#[julia] pub struct Gauge { pub value: i32 }",
        ),
        (
            &["ops"],
            "src/ops.rs",
            "#[julia] impl crate::shapes::Gauge { #[julia] pub fn read(&self) -> i32 { 0 } }",
        ),
    ])
    .expect_err("a header naming a file module must fail the scan");
    assert!(
        err.contains("`impl crate::shapes::Gauge` (line 1 in src/ops.rs)"),
        "{err}"
    );
    assert!(err.contains("`rustcall_shapes__Gauge_<method>`"), "{err}");
    assert!(
        err.contains("`crate::shapes::Gauge`, has the FFI name `Gauge`"),
        "{err}"
    );
    assert!(err.contains("`use crate::shapes::Gauge;`"), "{err}");

    // The spelling the message asks for passes.
    let manifest = scan_tree(&[
        (&[], "src/lib.rs", "mod shapes; mod ops;"),
        (
            &["shapes"],
            "src/shapes.rs",
            "#[julia] pub struct Gauge { pub value: i32 }",
        ),
        (
            &["ops"],
            "src/ops.rs",
            "use crate::shapes::Gauge; #[julia] impl Gauge { #[julia] pub fn read(&self) -> i32 { 0 } }",
        ),
    ])
    .unwrap();
    assert_eq!(
        method_symbols(the_struct(&manifest, "Gauge")),
        vec!["rustcall_Gauge_read"]
    );
}

/// An unmarked inline module cuts the chain of marked modules: whatever is
/// inside it is expanded by the item-level macro, which sees no module, so a
/// marked module below it starts a chain of its own — `b::f`, not `a::b::f`.
/// The scan records what the macro does.
#[test]
fn an_unmarked_module_cuts_the_symbol_path() {
    let manifest = extract_crate(
        r#"
        #[julia] pub mod a {
            pub mod x {
                #[julia] pub mod b { #[julia] pub fn f() -> i32 { 1 } }
            }
        }
        "#,
    )
    .unwrap();
    assert_eq!(manifest.functions[0].symbol, "rustcall_b__f");
    assert_eq!(manifest.functions[0].module_path, vec!["b".to_string()]);
}

/// The crate-wide duplicate check runs across files with both locations.
#[test]
fn duplicate_symbols_across_files_name_both_files() {
    let err = scan_tree(&[
        (&[], "src/lib.rs", "mod x; mod y;"),
        (&["x"], "src/x.rs", "#[julia] pub fn run() -> i32 { 1 }"),
        (&["y"], "src/y.rs", "#[julia] pub fn run() -> i32 { 2 }"),
    ])
    .expect_err("two file modules exporting one symbol must fail the scan");
    assert!(
        err.contains("duplicate exported symbol `rustcall_run`"),
        "{err}"
    );
    assert!(err.contains("in src/x.rs"), "{err}");
    assert!(err.contains("in src/y.rs"), "{err}");
}

/// The inline flavour matches across the block too, so a `rust"""` block with
/// the split layout wraps the same methods and both flavours agree.
#[test]
fn the_inline_flavour_attaches_across_modules_as_well() {
    let src = r#"
        #[julia] pub struct Gauge { pub value: i32 }
        pub mod ops {
            #[julia] impl super::Gauge { #[julia] pub fn read(&self) -> i32 { self.value } }
        }
    "#;
    let inline = rustcall_core::expand::expand(src).unwrap();
    let gauge = the_struct(&inline.manifest, "Gauge");
    assert_eq!(method_symbols(gauge), vec!["rustcall_Gauge_read"]);
    assert!(
        inline.source.contains("fn rustcall_Gauge_read("),
        "{}",
        inline.source
    );
    let krate = extract_crate(&src.replace("pub mod ops", "#[julia] pub mod ops")).unwrap();
    assert_eq!(
        method_symbols(the_struct(&krate, "Gauge")),
        method_symbols(gauge)
    );
}

/// The issue's example (#342): a `#[julia] impl` block in `mod ops` whose
/// method returns a type alias private to `ops`. The wrapper is emitted inside
/// `ops`, so `Count` is in scope and the expansion compiles; the exported
/// symbol still follows the struct.
#[test]
fn a_cross_module_wrapper_is_emitted_inside_the_impls_module() {
    let src = r#"
        #[julia] pub struct Gauge { pub value: i32 }
        pub mod ops {
            type Count = i32;
            #[julia] impl super::Gauge {
                #[julia] pub fn read(&self) -> Count { self.value }
            }
        }
    "#;
    let expanded = rustcall_core::expand::expand(src).unwrap();
    let gauge = the_struct(&expanded.manifest, "Gauge");
    assert_eq!(method_symbols(gauge), vec!["rustcall_Gauge_read"]);

    // The wrapper sits between `mod ops {` and the module's closing brace, and
    // spells both the struct and the alias the way `ops` can see them.
    let body = module_body(&expanded.source, "ops");
    assert!(
        body.contains("pub extern \"C\" fn rustcall_Gauge_read(ptr: *const super::Gauge) -> Count"),
        "{body}"
    );
    assert!(
        !before_module(&expanded.source, "ops").contains("rustcall_Gauge_read"),
        "the wrapper must not stay next to the struct:\n{}",
        expanded.source
    );
    compiles_as_cdylib(&expanded.source, "cross_module_alias");
}

/// A cross-module method returning a `String` declares string buffers of its
/// own, because the struct-level ones are not in scope at the block — and the
/// manifest states that owner instead of leaving Julia to derive it from the
/// flavour (`Method.string_owner`, #342).
#[test]
fn a_cross_module_string_method_owns_its_buffer_and_says_so() {
    let src = r#"
        #[julia] pub struct Gauge { pub value: i32 }
        #[julia] impl Gauge {
            #[julia] pub fn here(&self) -> String { format!("{}", self.value) }
        }
        pub mod ops {
            #[julia] impl super::Gauge {
                #[julia] pub fn there(&self) -> String { format!("{}", self.value) }
                #[julia] pub fn split(&self) -> Result<String, String> { Ok(String::new()) }
            }
        }
    "#;
    let expanded = rustcall_core::expand::expand(src).unwrap();
    let gauge = the_struct(&expanded.manifest, "Gauge");
    let owner = |name: &str| {
        gauge
            .methods
            .iter()
            .find(|m| m.name == name)
            .unwrap_or_else(|| panic!("no method `{name}`"))
            .string_owner
            .clone()
    };
    // A method wrapped next to the struct shares the struct's buffer; one
    // wrapped at a block elsewhere carries its own.
    assert_eq!(owner("here"), "Gauge");
    assert_eq!(owner("there"), "Gauge_there");
    assert_eq!(owner("split"), "Gauge_split");
    assert!(gauge.has_owned_string_helper);

    let body = module_body(&expanded.source, "ops");
    assert!(
        body.contains("pub struct Gauge_there_RustCallOwnedString"),
        "{body}"
    );
    assert!(
        body.contains("pub extern \"C\" fn Gauge_there_free_rust_string("),
        "{body}"
    );
    assert!(
        body.contains("pub struct Gauge_split_RustCallOwnedString"),
        "{body}"
    );
    compiles_as_cdylib(&expanded.source, "cross_module_strings");
}

/// A struct with no local string method does not get the struct-level buffers
/// just because a cross-module method returns a `String`: those helpers are
/// `#[no_mangle]`, so emitting them unused would claim a symbol nothing frees.
#[test]
fn a_struct_whose_only_string_method_is_foreign_gets_no_shared_buffer() {
    let src = r#"
        #[julia] pub struct Gauge { pub value: i32 }
        pub mod ops {
            #[julia] impl super::Gauge {
                #[julia] pub fn label(&self) -> String { format!("{}", self.value) }
            }
        }
    "#;
    let expanded = rustcall_core::expand::expand(src).unwrap();
    assert!(!the_struct(&expanded.manifest, "Gauge").has_owned_string_helper);
    assert!(
        !expanded
            .source
            .contains("pub struct Gauge_RustCallOwnedString"),
        "{}",
        expanded.source
    );
    assert!(
        expanded
            .source
            .contains("pub struct Gauge_label_RustCallOwnedString"),
        "{}",
        expanded.source
    );
}

/// The crate flavour is untouched: the proc-macro already emits every wrapper
/// at the impl site with per-method buffers, and the manifest now says so.
#[test]
fn the_crate_flavour_keeps_its_per_method_buffers() {
    let manifest = extract_crate(
        r#"
        #[julia] pub struct Gauge { pub value: i32 }
        #[julia] impl Gauge {
            #[julia] pub fn here(&self) -> String { format!("{}", self.value) }
        }
        #[julia] pub mod ops {
            #[julia] impl crate::Gauge {
                #[julia] pub fn there(&self) -> String { format!("{}", self.value) }
            }
        }
        "#,
    )
    .unwrap();
    let gauge = the_struct(&manifest, "Gauge");
    for m in &gauge.methods {
        assert_eq!(m.string_owner, format!("Gauge_{}", m.name), "{m:?}");
    }
}

/// The body of the inline module `name` in an expanded source: everything
/// between `mod <name> {` and the matching closing brace.
fn module_body<'a>(source: &'a str, name: &str) -> &'a str {
    let header = format!("mod {name} {{");
    let start = source
        .find(&header)
        .unwrap_or_else(|| panic!("no `mod {name}` in:\n{source}"))
        + header.len();
    let mut depth = 1usize;
    for (offset, ch) in source[start..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return &source[start..start + offset];
                }
            }
            _ => {}
        }
    }
    panic!("unterminated `mod {name}` in:\n{source}");
}

/// Everything before the inline module `name` starts.
fn before_module<'a>(source: &'a str, name: &str) -> &'a str {
    let header = format!("mod {name} {{");
    let start = source
        .find(&header)
        .unwrap_or_else(|| panic!("no `mod {name}` in:\n{source}"));
    &source[..start]
}

/// `rustc` accepts `source` as a `cdylib`. Skipped when rustc is not on PATH,
/// exactly as the golden corpus's compilation check is.
fn compiles_as_cdylib(source: &str, label: &str) {
    if std::process::Command::new("rustc")
        .arg("--version")
        .output()
        .is_err()
    {
        eprintln!("skipping the cdylib check for {label}: rustc is not available on PATH");
        return;
    }
    let dir = std::env::temp_dir().join(format!(
        "rustcall_{label}_{}_{}",
        std::process::id(),
        line!()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("lib.rs");
    std::fs::write(&path, source).unwrap();
    let output = std::process::Command::new("rustc")
        .arg("--edition=2021")
        .arg("--crate-name=rustcall_probe")
        .arg("--crate-type=cdylib")
        .arg(&path)
        .arg("-o")
        .arg(dir.join("out"))
        .output()
        .expect("failed to invoke rustc");
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    std::fs::remove_dir_all(&dir).ok();
    assert!(
        output.status.success(),
        "rustc rejected the expansion of {label}:\n{stderr}\n--- source ---\n{source}"
    );
}

/// Rust resolves `impl Gauge` by scope, not by attribute: a plain `struct
/// Gauge` beside the block is its target even though a `#[julia] struct Gauge`
/// exists elsewhere. Attaching the methods to the annotated one would describe
/// wrappers that dereference a pointer to the wrong type, so the scan refuses
/// and says which struct to annotate (#315 review).
#[test]
fn an_impl_on_a_plain_local_struct_is_refused() {
    let err = scan_tree(&[
        (
            &[],
            "src/lib.rs",
            "mod ops;\n#[julia] pub struct Gauge { pub value: i32 }",
        ),
        (
            &["ops"],
            "src/ops.rs",
            "pub struct Gauge { pub other: i32 }\n\
             #[julia] impl Gauge { #[julia] pub fn read(&self) -> i32 { self.other } }",
        ),
    ])
    .expect_err("an impl on the module's own plain struct must not attach to the annotated one");
    assert!(err.contains("not a `#[julia]` struct"), "{err}");
    assert!(err.contains("module `ops`"), "{err}");
    assert!(err.contains("src/ops.rs"), "{err}");
}

/// The same layout with an explicit path names the annotated struct, and binds.
#[test]
fn an_explicit_path_reaches_past_a_plain_local_struct() {
    let manifest = scan_tree(&[
        (
            &[],
            "src/lib.rs",
            "mod ops;\n#[julia] pub struct Gauge { pub value: i32 }",
        ),
        (
            &["ops"],
            "src/ops.rs",
            "pub struct Gauge { pub other: i32 }\n\
             #[julia] impl crate::Gauge { #[julia] pub fn read(&self) -> i32 { self.value } }",
        ),
    ])
    .expect("`impl crate::Gauge` names the annotated struct");
    assert_eq!(
        method_symbols(the_struct(&manifest, "Gauge")),
        vec!["rustcall_Gauge_read"]
    );
}

/// `include!("api.rs")` compiles that file's items into the including module,
/// with no `mod` declaration to follow: the tree walk reads it, so the items
/// the proc-macro wraps are in the manifest too (#315 review).
#[test]
fn a_literal_include_is_followed() {
    let dir = std::env::temp_dir().join(format!(
        "rustcall_include_{}_{}",
        std::process::id(),
        line!()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("api.rs"),
        "#[julia] pub fn included_add(a: i32, b: i32) -> i32 { a + b }",
    )
    .unwrap();
    // A fragment that is not a module is left to the compiler, as before.
    std::fs::write(dir.join("table.rs"), "[1, 2, 3]").unwrap();
    let lib = dir.join("lib.rs");
    let manifest = scan_tree(&[(
        &[],
        lib.to_str().unwrap(),
        "include!(\"api.rs\");\n\
         const TABLE: [i32; 3] = include!(\"table.rs\");\n\
         #[julia] pub fn root_add(a: i32, b: i32) -> i32 { a + b }",
    )])
    .expect("a literal include! is followed");
    let mut names: Vec<&str> = manifest.functions.iter().map(|f| f.name.as_str()).collect();
    names.sort();
    assert_eq!(names, vec!["included_add", "root_add"]);
    std::fs::remove_dir_all(&dir).ok();
}

/// An `enum` or a `union` is a target too — neither can carry `#[julia]`, so a
/// local one shadows a same-named annotated struct elsewhere and the block is
/// refused rather than attached to the wrong type (#315 review).
#[test]
fn an_impl_on_a_plain_local_enum_is_refused() {
    for (kind, decl) in [
        ("enum", "pub enum Gauge { A, B }"),
        ("union", "pub union Gauge { a: i32, b: u32 }"),
        (
            "type alias",
            "pub struct Other { pub v: i32 }\npub type Gauge = Other;",
        ),
    ] {
        let err = scan_tree(&[
            (
                &[],
                "src/lib.rs",
                "mod ops;\n#[julia] pub struct Gauge { pub value: i32 }",
            ),
            (
                &["ops"],
                "src/ops.rs",
                &format!(
                    "{decl}\n#[julia] impl Gauge {{ #[julia] pub fn read(&self) -> i32 {{ 0 }} }}"
                ),
            ),
        ])
        .expect_err("a #[julia] impl of a plain local type must fail the scan");
        assert!(err.contains("not a `#[julia]` struct"), "{kind}: {err}");
        assert!(err.contains("module `ops`"), "{kind}: {err}");
    }
}

/// A renamed import makes the proc-macro export `rustcall_Meter_*` while the
/// manifest resolves the struct to `Gauge`: the stems differ, so the scan
/// refuses and names the header to write (#315 review).
#[test]
fn a_renamed_import_in_an_impl_header_is_refused() {
    let err = scan_tree(&[
        (
            &[],
            "src/lib.rs",
            "mod ops;\n#[julia] pub struct Gauge { pub value: i32 }",
        ),
        (
            &["ops"],
            "src/ops.rs",
            "use crate::Gauge as Meter;\n\
             #[julia] impl Meter { #[julia] pub fn read(&self) -> i32 { self.value } }",
        ),
    ])
    .expect_err("a renamed import must not silently bind the wrong symbol");
    assert!(err.contains("impl crate::Gauge"), "{err}");
}
