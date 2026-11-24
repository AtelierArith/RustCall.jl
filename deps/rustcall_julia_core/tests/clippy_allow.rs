//! Generated entry points silence Clippy's `not_unsafe_ptr_arg_deref` (#600).
//!
//! A user crate must be able to run `cargo clippy -- -D warnings` without a
//! crate-level allow for code the macro wrote. The generated wrappers take
//! Julia's raw-pointer handles, so every `extern "C"` function the expansion
//! emits carries the allow itself.

use rustcall_julia_core::expand::expand;

const INLINE: &str = r#"
    #[julia]
    pub struct Pair {
        pub hi: f64,
        pub lo: f64,
    }

    #[julia]
    impl Pair {
        #[julia]
        pub fn new(hi: f64, lo: f64) -> Self {
            Self { hi, lo }
        }
    }

    #[julia]
    pub fn identity(x: f64) -> f64 {
        x
    }
"#;

#[test]
fn generated_entry_points_allow_not_unsafe_ptr_arg_deref() {
    let expanded = expand(INLINE).expect("inline expansion");
    let source = &expanded.source;
    let externs = source.matches("pub extern \"C\" fn").count();
    let allows = source
        .matches("#[allow(clippy::not_unsafe_ptr_arg_deref)]")
        .count();
    assert!(externs > 0, "no generated entry point:\n{source}");
    assert!(
        allows >= externs,
        "{externs} generated entry points but only {allows} allow attributes:\n{source}"
    );
}
