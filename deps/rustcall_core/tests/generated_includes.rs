use rustcall_core::{
    extract::{FilePosition, TreeScan},
    include_paths::IncludeEnvironment,
    Manifest, Mode,
};
use std::collections::BTreeMap;

#[test]
fn generated_include_keeps_its_lexical_module_and_predicate() {
    let mut scan = TreeScan::with_include_environment(IncludeEnvironment(BTreeMap::from([(
        "OUT_DIR".into(),
        "/target/build/api/out".into(),
    )])));
    let mut manifest = Manifest::new(Mode::Crate);
    let pulls = scan
        .file(
            r#"
        #[cfg(feature = "python")]
        pub mod api { include!(concat!(env!("OUT_DIR"), "/api.rs")); }
    "#,
            None,
            &FilePosition::module(&[], true, &[]),
            &mut manifest,
            "src/lib.rs",
        )
        .unwrap();
    assert_eq!(pulls.includes.len(), 1);
    let include = &pulls.includes[0];
    assert_eq!(include.path, "/target/build/api/out/api.rs");
    assert_eq!(include.position.module_path, ["api"]);
    assert!(include.position.reachable);
    scan.file(
        "#[pyo3::pyfunction] pub fn generated_answer() -> i32 { 42 }",
        None,
        &include.position,
        &mut manifest,
        &include.path,
    )
    .unwrap();
    scan.finish(&mut manifest).unwrap();
    assert_eq!(manifest.functions.len(), 1);
    assert_eq!(manifest.functions[0].module_path, ["api"]);
    assert_eq!(manifest.functions[0].cfg_features, ["python"]);
}

#[test]
fn resolved_build_context_cannot_silently_omit_a_generated_include() {
    let mut scan = TreeScan::with_include_environment(IncludeEnvironment::default());
    let error = scan
        .file(
            r#"include!(concat!(env!("OUT_DIR"), "/api.rs"));"#,
            None,
            &FilePosition::module(&[], true, &[]),
            &mut Manifest::new(Mode::Crate),
            "src/lib.rs",
        )
        .unwrap_err();
    assert!(error.to_string().contains("OUT_DIR"));
}
