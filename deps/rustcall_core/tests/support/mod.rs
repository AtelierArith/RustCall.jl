//! Shared helpers for the tests that *compile* generated code with a plain
//! `rustc`.

use std::path::Path;
use std::{fs, process::Command};

/// Build the `rustcall_julia_macros` runtime as an rlib and return the
/// `--extern` value that puts it in scope.
///
/// Crate-flavour output (`PanicHook::Runtime`) names
/// `::rustcall_julia_macros::__RustCallBoundary`, because `#[julia]` cannot emit
/// the crate-wide quiet-hook state itself and takes it from the crate it came
/// from instead (#304). A test that compiles that output with a bare `rustc`
/// has to supply the crate, and the honest way to supply it is to build it from
/// the same generator the real crate's `src/rt.rs` is generated from.
pub fn runtime_extern_arg(dir: &Path) -> String {
    let source = dir.join("rustcall_julia_macros.rs");
    let rlib = dir.join("librustcall_julia_macros.rlib");
    fs::write(&source, rustcall_core::codegen::runtime_module_source()).unwrap();
    let build = Command::new("rustc")
        .args([
            "--edition=2021",
            "--crate-type=rlib",
            "--crate-name=rustcall_julia_macros",
            "-C",
            "panic=unwind",
        ])
        .arg(&source)
        .arg("-o")
        .arg(&rlib)
        .output()
        .unwrap();
    assert!(
        build.status.success(),
        "failed to build the runtime rlib: {}",
        String::from_utf8_lossy(&build.stderr)
    );
    format!("rustcall_julia_macros={}", rlib.display())
}
