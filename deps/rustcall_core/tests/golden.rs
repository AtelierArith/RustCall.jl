use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use rustcall_core::manifest::Mode;

fn corpus_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/corpus")
}

fn assert_or_update(path: &Path, actual: &str) {
    if std::env::var_os("UPDATE_GOLDEN").is_some_and(|value| value == "1") {
        fs::write(path, actual).unwrap_or_else(|error| {
            panic!("failed to update golden file {}: {error}", path.display())
        });
        return;
    }

    let expected = fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("failed to read golden file {}: {error}", path.display()));
    assert_eq!(
        actual.replace("\r\n", "\n"),
        expected.replace("\r\n", "\n"),
        "golden mismatch for {}",
        path.display()
    );
}

fn corpus_sources() -> Vec<PathBuf> {
    let mut sources: Vec<_> = fs::read_dir(corpus_dir())
        .expect("failed to read golden corpus directory")
        .map(|entry| entry.expect("failed to read corpus entry").path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "rs"))
        .filter(|path| {
            !path
                .file_stem()
                .is_some_and(|stem| stem.to_string_lossy().ends_with(".expanded"))
        })
        .collect();
    sources.sort();
    sources
}

#[test]
fn corpus_matches_golden_files() {
    let sources = corpus_sources();
    assert!(!sources.is_empty(), "golden corpus must not be empty");

    for source_path in sources {
        let source = fs::read_to_string(&source_path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", source_path.display()));
        let stem = source_path
            .file_stem()
            .expect("corpus source must have a file stem")
            .to_string_lossy();

        let expanded = rustcall_core::expand::expand(&source)
            .unwrap_or_else(|error| panic!("failed to expand {}: {error}", source_path.display()));
        let inline_toml = expanded
            .manifest
            .to_toml()
            .expect("failed to serialize inline manifest");
        let crate_manifest = rustcall_core::extract::extract(&source, Mode::Crate)
            .unwrap_or_else(|error| panic!("failed to extract {}: {error}", source_path.display()));
        let crate_toml = crate_manifest
            .to_toml()
            .expect("failed to serialize crate manifest");

        let expanded_again = rustcall_core::expand::expand(&source)
            .expect("second expansion of the same corpus source failed");
        let crate_again = rustcall_core::extract::extract(&source, Mode::Crate)
            .expect("second crate extraction of the same corpus source failed");
        assert_eq!(expanded.source, expanded_again.source);
        assert_eq!(expanded.manifest, expanded_again.manifest);
        assert_eq!(crate_manifest, crate_again);

        assert_or_update(
            &source_path.with_file_name(format!("{stem}.inline.toml")),
            &inline_toml,
        );
        assert_or_update(
            &source_path.with_file_name(format!("{stem}.crate.toml")),
            &crate_toml,
        );
        assert_or_update(
            &source_path.with_file_name(format!("{stem}.expanded.rs")),
            &expanded.source,
        );
    }
}

#[test]
fn compilable_wrappers_build_as_cdylib() {
    if Command::new("rustc").arg("--version").output().is_err() {
        eprintln!("skipping cdylib check because rustc is not available on PATH");
        return;
    }

    let source_path = corpus_dir().join("struct_wrappers.rs");
    let source = fs::read_to_string(&source_path).expect("failed to read compilation corpus");
    let expanded = rustcall_core::expand::expand(&source).expect("failed to expand corpus");

    let temp_dir = std::env::temp_dir().join(format!(
        "rustcall_core_golden_{}_{}",
        std::process::id(),
        std::thread::current().name().unwrap_or("test")
    ));
    fs::create_dir_all(&temp_dir).expect("failed to create rustc output directory");
    let expanded_path = temp_dir.join("struct_wrappers.rs");
    fs::write(&expanded_path, expanded.source).expect("failed to write expanded Rust source");
    let library_path = temp_dir.join("rustcall_golden_cdylib");

    let output = Command::new("rustc")
        .arg("--edition=2021")
        .arg("--crate-name=rustcall_golden")
        .arg("--crate-type=cdylib")
        .arg(&expanded_path)
        .arg("-o")
        .arg(&library_path)
        .output()
        .expect("failed to invoke rustc");

    if let Err(error) = fs::remove_dir_all(&temp_dir) {
        eprintln!("failed to remove {}: {error}", temp_dir.display());
    }
    assert!(
        output.status.success(),
        "rustc rejected expanded struct/Result/Option wrappers:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
}
