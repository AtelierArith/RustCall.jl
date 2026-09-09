use std::{
    collections::BTreeMap,
    fs,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

#[test]
fn manifest_and_wrap_follow_the_same_generated_include() {
    let root = std::env::temp_dir().join(format!(
        "rustcall-generated-cli-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(root.join("generated space")).unwrap();
    fs::write(
        root.join("lib.rs"),
        r#"pub mod api { include!(concat!(env!("OUT_DIR"), "/api.rs")); }"#,
    )
    .unwrap();
    fs::write(
        root.join("generated space/api.rs"),
        "#[pyo3::pyfunction] pub fn generated_answer() -> i32 { 42 }",
    )
    .unwrap();
    #[cfg(unix)]
    {
        let destination = root.join("implementation.rs");
        fs::rename(root.join("generated space/api.rs"), &destination).unwrap();
        std::os::unix::fs::symlink(destination, root.join("generated space/api.rs")).unwrap();
    }
    fs::write(
        root.join("env.toml"),
        toml::to_string(&BTreeMap::from([(
            "OUT_DIR",
            root.join("generated space").to_str().unwrap(),
        )]))
        .unwrap(),
    )
    .unwrap();
    for command in ["manifest", "wrap"] {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_rustcall-extract"));
        cmd.arg(command);
        if command == "manifest" {
            cmd.args(["--mode", "crate"]);
        } else {
            cmd.args(["--crate-name", "generated_probe303"]);
        }
        let output = cmd
            .arg("--crate-root")
            .arg(root.join("lib.rs"))
            .arg("--build-env-file")
            .arg(root.join("env.toml"))
            .arg("--inputs-out")
            .arg(root.join("inputs.toml"))
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let parsed: toml::Value =
            toml::from_str(std::str::from_utf8(&output.stdout).unwrap()).unwrap();
        let inputs: BTreeMap<String, Vec<std::path::PathBuf>> =
            toml::from_str(&fs::read_to_string(root.join("inputs.toml")).unwrap()).unwrap();
        let expected: std::collections::BTreeSet<_> =
            [root.join("lib.rs"), root.join("generated space/api.rs")]
                .into_iter()
                .flat_map(|path| [fs::canonicalize(&path).unwrap(), path])
                .collect();
        assert_eq!(
            inputs["files"]
                .iter()
                .cloned()
                .collect::<std::collections::BTreeSet<_>>(),
            expected
        );
        assert!(inputs["files"].contains(&fs::canonicalize(root.join("lib.rs")).unwrap()));
        assert!(inputs["files"]
            .contains(&fs::canonicalize(root.join("generated space/api.rs")).unwrap()));
        let manifest = if command == "manifest" {
            &parsed
        } else {
            &parsed["manifest"]
        };
        assert_eq!(
            manifest["functions"][0]["name"].as_str(),
            Some("generated_answer")
        );
        assert_eq!(
            manifest["functions"][0]["module_path"][0].as_str(),
            Some("api")
        );
        if command == "wrap" {
            assert!(parsed["lib_rs"]
                .as_str()
                .unwrap()
                .contains("generated_probe303::api::generated_answer"));
        }
    }
    fs::write(root.join("env.toml"), "").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_rustcall-extract"))
        .args([
            "manifest",
            "--mode",
            "crate",
            "--skip-unparsable",
            "--crate-root",
        ])
        .arg(root.join("lib.rs"))
        .arg("--build-env-file")
        .arg(root.join("env.toml"))
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("OUT_DIR"));
    fs::remove_dir_all(&root).unwrap();
}
