//! `#[cfg]`-disabled items must not be reported (follow-up of #264).

use rustcall_core::cfg::CfgSet;
use rustcall_core::expand::{expand, expand_with_cfg};
use rustcall_core::extract::extract_with_cfg;
use rustcall_core::manifest::Mode;
use rustcall_core::specialize::specialize;

const SRC: &str = r#"
#[cfg(unix)]
#[julia]
pub fn only_unix() -> i32 { 1 }

#[cfg(windows)]
#[julia]
pub fn only_windows() -> i32 { 2 }

#[cfg(all(unix, feature = "extra"))]
#[julia]
pub fn needs_feature() -> Result<i32, i32> { Ok(3) }

#[julia]
pub fn always() -> Option<i32> { Some(4) }

#[cfg(not(windows))]
#[julia]
pub struct Point { pub x: f64, #[cfg(windows)] pub win_only: f64 }

#[cfg(windows)]
#[julia]
pub struct WinPoint { pub x: f64 }

impl Point {
    pub fn x(&self) -> f64 { self.x }
    #[cfg(windows)]
    pub fn win(&self) -> f64 { 0.0 }
}

#[cfg(unix)]
mod nested {
    #[julia]
    pub fn in_unix_mod() -> i32 { 5 }
    #[cfg(windows)]
    #[julia]
    pub fn in_unix_mod_win() -> i32 { 6 }
}

#[cfg(windows)]
mod winmod {
    #[julia]
    pub fn gone() -> i32 { 7 }
}
"#;

fn names(m: &rustcall_core::Manifest) -> Vec<String> {
    m.functions.iter().map(|f| f.name.clone()).collect()
}

#[test]
fn without_cfg_everything_is_reported_with_predicates() {
    let e = expand(SRC).unwrap();
    let f = |n: &str| e.manifest.functions.iter().find(|f| f.name == n).unwrap();
    assert_eq!(f("only_unix").cfg, "unix");
    assert_eq!(f("only_windows").cfg, "windows");
    assert_eq!(f("needs_feature").cfg, "all(unix, feature = \"extra\")");
    assert_eq!(f("always").cfg, "");
    assert!(names(&e.manifest).contains(&"gone".to_string()));
    let s = |n: &str| e.manifest.structs.iter().find(|s| s.name == n).unwrap();
    assert_eq!(s("Point").cfg, "not(windows)");
    assert_eq!(s("WinPoint").cfg, "windows");
}

#[test]
fn inline_mode_drops_disabled_items() {
    let set = CfgSet::default().with_name("unix");
    let e = expand_with_cfg(SRC, Some(&set)).unwrap();
    let n = names(&e.manifest);
    assert!(n.contains(&"only_unix".to_string()));
    assert!(n.contains(&"always".to_string()));
    assert!(n.contains(&"in_unix_mod".to_string()));
    assert!(!n.contains(&"only_windows".to_string()));
    assert!(
        !n.contains(&"needs_feature".to_string()),
        "feature not enabled"
    );
    assert!(!n.contains(&"in_unix_mod_win".to_string()));
    assert!(!n.contains(&"gone".to_string()));

    let structs: Vec<_> = e.manifest.structs.iter().map(|s| s.name.as_str()).collect();
    assert_eq!(structs, vec!["Point"]);
    let point = &e.manifest.structs[0];
    assert!(point.fields.iter().all(|f| f.name != "win_only"));
    assert!(point.methods.iter().any(|m| m.name == "x"));
    assert!(point.methods.iter().all(|m| m.name != "win"));

    // The expanded source contains no trace of the disabled items either.
    assert!(!e.source.contains("only_windows"));
    assert!(!e.source.contains("WinPoint"));
    assert!(!e.source.contains("winmod"));
    assert!(!e.source.contains("win_only"));
    // Decided predicates are dropped from the kept items, so the source no
    // longer depends on them; undecided ones (features) stay.
    assert!(!e.source.contains("#[cfg(unix)]"), "{}", e.source);
    assert!(!e.source.contains("#[cfg(not(windows))]"));

    // In lenient mode a feature predicate is undecided and therefore kept.
    let lenient = CfgSet::default().with_name("unix").lenient();
    let el = expand_with_cfg(SRC, Some(&lenient)).unwrap();
    assert!(el.source.contains("feature = \"extra\""), "{}", el.source);
    assert!(!el.source.contains("#[cfg(unix)]"));

    let with_feature = set.clone().with_pair("feature", "extra");
    let e2 = expand_with_cfg(SRC, Some(&with_feature)).unwrap();
    assert!(names(&e2.manifest).contains(&"needs_feature".to_string()));
}

#[test]
fn crate_mode_drops_disabled_items() {
    let set = CfgSet::default().with_name("windows");
    let m = extract_with_cfg(SRC, Mode::Crate, Some(&set)).unwrap();
    let n = names(&m);
    assert_eq!(n, vec!["only_windows", "always", "gone"]);
    let structs: Vec<_> = m.structs.iter().map(|s| s.name.as_str()).collect();
    assert_eq!(structs, vec!["WinPoint"]);
}

#[test]
fn result_wrappers_keep_cfg_attributes() {
    // The proc-macro sees `#[julia] #[cfg(...)] fn`: the generated items must
    // stay gated so an inactive function does not leak an exported symbol.
    let src = "#[julia]\n#[cfg(windows)]\npub fn r() -> Result<i32, i32> { Ok(1) }\n#[julia]\n#[cfg(windows)]\npub fn o() -> Option<i32> { None }";
    let e = expand(src).unwrap();
    let gated = e.source.matches("#[cfg(windows)]").count();
    // CResult struct + accessor impl + inner fn + extern fn, twice.
    assert_eq!(gated, 8, "{}", e.source);
}

#[test]
fn unevaluable_predicate_fails_closed() {
    let set = CfgSet::default();
    let err = expand_with_cfg(
        "#[cfg(version(\"1.80\"))] #[julia] pub fn f() -> i32 { 0 }",
        Some(&set),
    )
    .err()
    .expect("unevaluable predicate must be an error");
    assert!(err.to_string().contains("cannot evaluate #[cfg]"), "{err}");
}

#[test]
fn specialize_keeps_predicate() {
    let src = "#[cfg(unix)] pub fn id<T: Copy>(x: T) -> T { x }";
    let sp = specialize(src, "id", &[("T".to_string(), "i32".to_string())], "id_i32").unwrap();
    assert_eq!(sp.manifest.functions[0].cfg, "unix");
    assert!(sp.source.contains("#[cfg(unix)]"));
}

/// A parameter can carry its own `#[cfg]`; rustc removes it, so the manifest
/// (and hence the generated wrapper's C ABI) must not report it either.
const PARAM_SRC: &str = r#"
#[julia]
pub fn takes(a: i32, #[cfg(any())] b: i32, #[cfg(all())] c: i32) -> i32 { a + c }

#[julia]
pub fn maybe(a: i32, #[cfg(feature = "extra")] b: i32) -> Result<i32, i32> { Ok(a) }

#[julia]
pub struct Holder { pub v: i32 }

impl Holder {
    pub fn sum(&self, a: i32, #[cfg(windows)] b: i32) -> i32 { self.v + a }
}
"#;

#[test]
fn prunes_disabled_function_parameters() {
    let set = CfgSet::default().with_name("unix");
    let e = expand_with_cfg(PARAM_SRC, Some(&set)).unwrap();

    let takes = e
        .manifest
        .functions
        .iter()
        .find(|f| f.name == "takes")
        .unwrap();
    let arg_names: Vec<&str> = takes.args.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(arg_names, vec!["a", "c"], "{:?}", takes.args);

    // `feature = "extra"` is decided (strict set) and absent: the parameter goes.
    let maybe = e
        .manifest
        .functions
        .iter()
        .find(|f| f.name == "maybe")
        .unwrap();
    let arg_names: Vec<&str> = maybe.args.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(arg_names, vec!["a"]);

    let holder = e
        .manifest
        .structs
        .iter()
        .find(|s| s.name == "Holder")
        .unwrap();
    let sum = holder.methods.iter().find(|m| m.name == "sum").unwrap();
    let arg_names: Vec<&str> = sum.args.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(arg_names, vec!["a"], "{:?}", sum.args);

    // The expanded source carries neither the removed parameters nor the
    // predicates that were decided to be true.
    assert!(!e.source.contains("#[cfg(any())]"), "{}", e.source);
    assert!(!e.source.contains("#[cfg(all())]"), "{}", e.source);
    assert!(!e.source.contains("#[cfg(windows)]"), "{}", e.source);
}

#[test]
fn keeps_undecided_function_parameters_in_lenient_mode() {
    let set = CfgSet::default().with_name("unix").lenient();
    let e = expand_with_cfg(PARAM_SRC, Some(&set)).unwrap();

    // A feature predicate is undecided under Cargo, so the parameter stays and
    // its `#[cfg]` is preserved for rustc to decide.
    let maybe = e
        .manifest
        .functions
        .iter()
        .find(|f| f.name == "maybe")
        .unwrap();
    let arg_names: Vec<&str> = maybe.args.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(arg_names, vec!["a", "b"], "{:?}", maybe.args);
    assert!(e.source.contains("feature = \"extra\""), "{}", e.source);

    // Target predicates are still decided, even leniently.
    let holder = e
        .manifest
        .structs
        .iter()
        .find(|s| s.name == "Holder")
        .unwrap();
    let sum = holder.methods.iter().find(|m| m.name == "sum").unwrap();
    assert_eq!(
        sum.args.iter().map(|a| a.name.as_str()).collect::<Vec<_>>(),
        vec!["a"]
    );
}

#[test]
fn unevaluable_parameter_predicate_fails_closed() {
    let set = CfgSet::default();
    let err = expand_with_cfg(
        "#[julia] pub fn f(a: i32, #[cfg(version(\"1.80\"))] b: i32) -> i32 { a }",
        Some(&set),
    )
    .err()
    .expect("unevaluable parameter predicate must be an error");
    assert!(err.to_string().contains("cannot evaluate #[cfg]"), "{err}");
}

/// A crate-level `#![cfg(...)]` decides the whole file: rustc keeps the
/// attribute and compiles nothing, so no item may be reported either.
#[test]
fn crate_level_cfg_disables_every_item() {
    let src = r#"
#![cfg(any())]
#[julia]
pub fn f() -> i32 { 1 }
#[julia]
pub struct S { pub x: i32 }
"#;
    let set = CfgSet::default().with_name("unix");

    let e = expand_with_cfg(src, Some(&set)).unwrap();
    assert!(
        e.manifest.functions.is_empty(),
        "{:?}",
        e.manifest.functions
    );
    assert!(e.manifest.structs.is_empty(), "{:?}", e.manifest.structs);
    assert!(!e.source.contains("fn f"), "{}", e.source);
    assert!(!e.source.contains("struct S"), "{}", e.source);

    let m = extract_with_cfg(src, Mode::Crate, Some(&set)).unwrap();
    assert!(m.functions.is_empty() && m.structs.is_empty());

    // An indirectly disabled crate (`cfg_attr`) is dropped just the same.
    let indirect = "#![cfg_attr(unix, cfg(any()))]\n#[julia]\npub fn f() -> i32 { 1 }\n";
    assert!(expand_with_cfg(indirect, Some(&set))
        .unwrap()
        .manifest
        .functions
        .is_empty());
}

#[test]
fn crate_level_cfg_that_holds_keeps_the_items() {
    let set = CfgSet::default().with_name("unix");
    let e = expand_with_cfg(
        "#![cfg(unix)]\n#[julia]\npub fn f() -> i32 { 1 }\n",
        Some(&set),
    )
    .unwrap();
    assert_eq!(names(&e.manifest), vec!["f"]);
    // The decided predicate is stripped, so a later rustc run cannot flip it.
    assert!(!e.source.contains("cfg(unix)"), "{}", e.source);

    // Undecided leniently (an external crate's feature): the items stay and
    // the crate attribute is preserved for rustc.
    let lenient = CfgSet::default().with_name("unix").lenient();
    let e = expand_with_cfg(
        "#![cfg(feature = \"x\")]\n#[julia]\npub fn f() -> i32 { 1 }\n",
        Some(&lenient),
    )
    .unwrap();
    assert_eq!(names(&e.manifest), vec!["f"]);
    assert!(e.source.contains("feature = \"x\""), "{}", e.source);
}

#[test]
fn unevaluable_crate_level_predicate_fails_closed() {
    let err = expand_with_cfg(
        "#![cfg(version(\"1.80\"))]\n#[julia]\npub fn f() -> i32 { 1 }\n",
        Some(&CfgSet::default()),
    )
    .err()
    .expect("unevaluable crate predicate must be an error");
    assert!(err.to_string().contains("cannot evaluate #[cfg]"), "{err}");
}

/// Generic parameters carry attributes too; rustc drops a `#[cfg]`-disabled one.
#[test]
fn prunes_disabled_generic_parameters() {
    let set = CfgSet::default().with_name("unix");
    let src = r#"
#[julia]
pub fn f<#[cfg(any())] T, U: Copy>(x: U) -> U { x }

#[julia]
pub fn g<#[cfg(any())] 'a, #[cfg(all())] T: Copy>(x: T) -> T { x }

#[julia]
pub fn h<#[cfg(windows)] const N: usize, T: Copy>(x: T) -> T { x }
"#;
    let e = expand_with_cfg(src, Some(&set)).unwrap();
    let params = |n: &str| -> Vec<String> {
        e.manifest
            .functions
            .iter()
            .find(|f| f.name == n)
            .unwrap()
            .type_params
            .iter()
            .map(|p| p.name.clone())
            .collect()
    };
    assert_eq!(params("f"), vec!["U"], "{}", e.source);
    assert_eq!(params("g"), vec!["T"], "{}", e.source);
    assert!(!e.source.contains("'a"), "{}", e.source);
    assert!(!e.source.contains("#[cfg(all())]"), "{}", e.source);
    // The disabled const parameter is gone, so the function is an ordinary
    // generic rather than an unsupported const-generic one.
    assert_eq!(params("h"), vec!["T"], "{}", e.source);
    assert!(!e.source.contains("const N"), "{}", e.source);
    assert!(!e.source.contains("compile_error"), "{}", e.source);

    // Struct and impl generics are pruned the same way.
    let src = r#"
#[julia]
pub struct W<#[cfg(any())] T, U: Copy> { pub v: U }
impl<#[cfg(any())] T, U: Copy> W<U> {
    pub fn v(&self) -> U { self.v }
}
"#;
    let e = expand_with_cfg(src, Some(&set)).unwrap();
    assert!(!e.source.contains("T,"), "{}", e.source);
    assert!(e.source.contains("W<U"), "{}", e.source);

    // Undecided leniently: kept, predicate preserved for rustc.
    let lenient = CfgSet::default().with_name("unix").lenient();
    let e = expand_with_cfg(
        "#[julia]\npub fn f<#[cfg(feature = \"x\")] T, U: Copy>(x: U) -> U { x }\n",
        Some(&lenient),
    )
    .unwrap();
    assert!(e.source.contains("feature = \"x\""), "{}", e.source);
}

#[test]
fn unevaluable_generic_parameter_predicate_fails_closed() {
    let err = expand_with_cfg(
        "#[julia]\npub fn f<#[cfg(version(\"1.80\"))] T: Copy>(x: T) -> T { x }\n",
        Some(&CfgSet::default()),
    )
    .err()
    .expect("unevaluable generic parameter predicate must be an error");
    assert!(err.to_string().contains("cannot evaluate #[cfg]"), "{err}");
}

/// Item-level pruning cannot resolve `#[cfg]` / `cfg!` inside a body, so the
/// manifest reports their presence for callers that would compile the source
/// under another configuration (lazy specialization of a Cargo-backed block).
#[test]
fn reports_cfg_inside_function_bodies() {
    let src = r#"
#[julia]
pub fn plain<T: Copy>(x: T) -> T { x }

#[julia]
pub fn uses_macro<T: Copy>(x: T) -> T { if cfg!(panic = "unwind") { x } else { x } }

#[julia]
pub fn uses_attr<T: Copy>(x: T) -> T {
    #[cfg(debug_assertions)]
    let _y = 1;
    x
}

#[julia]
pub fn uses_cfg_attr<T: Copy>(x: T) -> T {
    #[cfg_attr(unix, allow(unused))]
    let _y = 1;
    x
}

#[julia]
pub fn nested_item<T: Copy>(x: T) -> T {
    fn helper() -> i32 { std::cfg!(unix) as i32 }
    let _ = helper();
    x
}

#[julia]
pub fn not_generic() -> i32 { cfg!(unix) as i32 }
"#;
    let e = expand(src).unwrap();
    let has = |n: &str| {
        e.manifest
            .functions
            .iter()
            .find(|f| f.name == n)
            .unwrap()
            .body_has_cfg
    };
    assert!(!has("plain"));
    assert!(has("uses_macro"));
    assert!(has("uses_attr"));
    assert!(has("uses_cfg_attr"));
    assert!(has("nested_item"));
    assert!(has("not_generic"));
}

/// `#[cfg_attr(unix, cfg_attr(unix, ... cfg(any())))]` nested `depth` times.
fn nested_cfg_attr(depth: usize) -> String {
    let mut s = "cfg(any())".to_string();
    for _ in 0..depth {
        s = format!("cfg_attr(unix, {s})");
    }
    format!("#[{s}]\n#[julia]\npub fn deep() -> i32 {{ 1 }}\n")
}

/// Expansion runs until nothing changes, so a `cfg_attr` nested deeper than
/// the old fixed number of rounds still reaches its false `cfg`.
#[test]
fn deeply_nested_cfg_attr_is_fully_expanded() {
    let set = CfgSet::default().with_name("unix");
    for depth in [1usize, 8, 10, 32] {
        let e = expand_with_cfg(&nested_cfg_attr(depth), Some(&set)).unwrap();
        assert!(
            e.manifest.functions.is_empty(),
            "depth {depth}: {:?}",
            e.manifest.functions
        );
        assert!(!e.source.contains("deep"), "depth {depth}: {}", e.source);
    }
    // A true chain is expanded away entirely.
    let src = "#[cfg_attr(unix, cfg_attr(unix, cfg_attr(unix, cfg(all()))))]\n#[julia]\npub fn deep() -> i32 { 1 }\n";
    let e = expand_with_cfg(src, Some(&set)).unwrap();
    assert_eq!(names(&e.manifest), vec!["deep"]);
    assert!(!e.source.contains("cfg"), "{}", e.source);
}

/// The remaining depth limit is a safety net: exceeding it is an error, never
/// a partial expansion that hides a false predicate.
#[test]
fn absurdly_nested_cfg_attr_fails_closed() {
    let set = CfgSet::default().with_name("unix");
    let err = expand_with_cfg(&nested_cfg_attr(100), Some(&set))
        .err()
        .expect("nesting past the limit must be an error");
    let msg = err.to_string();
    assert!(
        msg.contains("cannot evaluate #[cfg]") && msg.contains("nested deeper"),
        "{msg}"
    );
}

/// `#[cfg_attr(pred, cfg(...))]` decides whether a function is compiled just
/// like a direct `#[cfg]`, so every generated item must carry it: otherwise the
/// helper type and the inner fn stay unconditional while the exported symbol
/// disappears, and the Julia binding fails at symbol lookup.
#[test]
fn generated_items_propagate_cfg_attr() {
    let src = r#"
#[julia]
#[cfg_attr(not(feature = "ffi"), cfg(any()))]
pub fn r() -> Result<i32, i32> { Ok(1) }

#[julia]
#[cfg_attr(not(feature = "ffi"), cfg(any()))]
pub fn o() -> Option<i32> { None }
"#;
    let e = expand(src).unwrap();
    // CResult/COption struct + accessor impl + inner fn + extern fn, twice.
    let gated = e.source.matches("cfg_attr(not(feature = \"ffi\")").count();
    assert_eq!(gated, 8, "{}", e.source);

    // Only the `cfg`-producing part is copied onto the generated items; an
    // unrelated attribute stays on the exported function alone.
    let mixed = r#"
#[julia]
#[cfg_attr(not(feature = "ffi"), cfg(any()), allow(dead_code))]
pub fn r() -> Result<i32, i32> { Ok(1) }
"#;
    let e = expand(mixed).unwrap();
    assert_eq!(
        e.source
            .matches("cfg_attr(not(feature = \"ffi\"), cfg(any()))")
            .count(),
        3,
        "{}",
        e.source
    );
    assert_eq!(
        e.source.matches("allow(dead_code)").count(),
        1,
        "{}",
        e.source
    );
}
