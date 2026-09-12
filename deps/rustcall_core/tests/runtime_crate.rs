//! `deps/rustcall_julia_macros/src/rt.rs` is generated, not hand-written.
//!
//! The quiet panic hook exists in two places: at the root of every file RustCall
//! writes whole (`panic_hook_items()`), and compiled once into the runtime crate
//! every `#[julia]` crate depends on. They must be the *same* items — a
//! `#[julia]` wrapper and an inline `rust"""` wrapper get the same silence, and
//! `src/loadpolicy.jl` resolves one symbol name for both (#304).
//!
//! Regenerate with `UPDATE_GOLDEN=1 cargo test` (then `cargo fmt`) and review
//! the diff.

use std::fs;
use std::path::PathBuf;

fn runtime_module_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../rustcall_julia_macros/src/rt.rs")
}

#[test]
fn runtime_crate_module_matches_the_generator() {
    let path = runtime_module_path();

    if std::env::var_os("UPDATE_GOLDEN").is_some_and(|value| value == "1") {
        fs::write(&path, rustcall_core::codegen::runtime_module_source())
            .unwrap_or_else(|error| panic!("failed to update {}: {error}", path.display()));
        eprintln!(
            "rewrote {}; run `cargo fmt` before committing",
            path.display()
        );
        return;
    }

    let source = fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
    let checked_in: syn::File = syn::parse_file(&source)
        .unwrap_or_else(|error| panic!("{} is not valid Rust: {error}", path.display()));

    // Both sides are re-printed by `prettyplease` before the comparison, so what
    // is compared is the syntax tree and not the layout: the checked-in file is
    // formatted by `rustfmt` (CI runs `cargo fmt --check` on this crate) while
    // the generator formats with `prettyplease`, and a doc comment survives a
    // `quote!` as a raw string literal and a parse as a plain one. Non-doc
    // comments are invisible to `syn`, so the file's header is free to explain
    // itself.
    let expected: syn::File = syn::parse2(rustcall_core::codegen::panic_hook_items())
        .expect("the quiet-hook items are not a valid Rust file");
    assert_eq!(
        prettyplease::unparse(&checked_in),
        prettyplease::unparse(&expected),
        "{} and `panic_hook_items()` have drifted apart; regenerate with \
         `UPDATE_GOLDEN=1 cargo test`, then `cargo fmt`",
        path.display()
    );
}

/// The two names Julia resolves on an image are the reason this file exists.
#[test]
fn the_runtime_module_exports_the_symbols_julia_resolves() {
    let source = rustcall_core::codegen::runtime_module_source();
    for symbol in [
        rustcall_core::codegen::INSTALL_PANIC_HOOK_SYMBOL,
        rustcall_core::codegen::UNINSTALL_PANIC_HOOK_SYMBOL,
    ] {
        assert!(
            source.contains(&format!("pub extern \"C\" fn {symbol}()")),
            "the runtime module must export {symbol}"
        );
    }
    assert!(source.contains("pub struct __RustCallBoundary"));
}
