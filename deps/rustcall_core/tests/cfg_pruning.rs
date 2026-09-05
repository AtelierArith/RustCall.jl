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
