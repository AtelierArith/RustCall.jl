//! `#[julia_pyo3]` is deprecated (#275 Phase 3): `#[julia]` is additive since
//! #279 and composes with PyO3's own attributes, which do the Python half
//! better than a RustCall macro ever did. The attribute still expands as
//! before, so existing crates keep building, but rustc must say so at every
//! use site — that is what makes a deprecation a deprecation rather than a
//! note in a changelog.
//!
//! `#[deprecated]` on a `#[proc_macro_attribute]` produces `use of deprecated
//! macro` at the use site. A `trybuild` test cannot observe a warning, so this
//! test builds a fixture crate that uses the attribute on a function, a struct
//! and an impl block with a nested `cargo check` and reads the compiler
//! messages. The nested build gets a target directory of its own: sharing the
//! outer one would contend for Cargo's build lock.

use std::path::PathBuf;
use std::process::Command;

fn fixture() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("uses_julia_pyo3")
}

#[test]
fn julia_pyo3_warns_at_every_use_site() {
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_string());
    let target = std::env::temp_dir().join(format!(
        "rustcall-julia-pyo3-deprecated-{}",
        std::process::id()
    ));
    let output = Command::new(cargo)
        .args(["check", "--quiet", "--message-format=json"])
        .current_dir(fixture())
        .env("CARGO_TARGET_DIR", &target)
        // The fixture must see the warning whatever the outer environment
        // says about lints.
        .env_remove("RUSTFLAGS")
        .env_remove("CARGO_ENCODED_RUSTFLAGS")
        .output()
        .expect("cargo could not be spawned");
    let _ = std::fs::remove_dir_all(&target);
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "the fixture must still build — deprecation is a warning, not an error:\n{}\n{}",
        stdout,
        String::from_utf8_lossy(&output.stderr)
    );

    // One `compiler-message` per use site: the function, the struct, the impl.
    let deprecations: Vec<&str> = stdout
        .lines()
        .filter(|line| line.contains("\"reason\":\"compiler-message\""))
        .filter(|line| line.contains("\"level\":\"warning\""))
        .filter(|line| line.contains("use of deprecated macro `julia_pyo3`"))
        .collect();
    assert_eq!(
        deprecations.len(),
        3,
        "expected one deprecation warning per `#[julia_pyo3]` use site, got:\n{stdout}"
    );
    // The note tells the user what to write instead, and where to read more.
    for line in &deprecations {
        assert!(
            line.contains("#[julia]"),
            "the note names the replacement: {line}"
        );
        assert!(line.contains("#275"), "the note names the issue: {line}");
    }
}
