//! #569: both Rust front ends consume exact lexical borrow lookup.
use rustcall_julia_core::{cfg::CfgSet, expand, extract, manifest::Manifest};
fn abi(m: &Manifest, name: &str) -> (String, String) {
    let arg = &m.functions.iter().find(|f| f.name == name).unwrap().args[0];
    (arg.abi.clone(), arg.handle.clone())
}
#[test]
fn inline_and_crate_globs_lower_shared_and_mutable_owners() {
    let source = r#"
        #[julia] pub struct Counter { pub value: i32 }
        #[julia] pub mod operations {
            use super::*;
            #[julia] pub fn read(source: &Counter) -> i32 { source.value }
            #[julia] pub fn change(source: &mut Counter) { source.value += 1; }
        }
    "#;
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        assert_eq!(abi(&m, "read"), ("handle".into(), "Counter".into()));
        assert_eq!(abi(&m, "change"), ("handle_mut".into(), "Counter".into()));
    }
}
#[test]
fn inline_plain_shadow_inventory_and_alias_diagnostics() {
    for declaration in [
        "struct Counter;",
        "enum Counter { A }",
        "union Counter { v: i32 }",
    ] {
        let source = format!("#[julia] struct Counter; mod nested {{ use super::*; {declaration} #[julia] fn read(x: &Counter) {{ }} }}");
        let m = expand::expand(&source).unwrap().manifest;
        assert_eq!(abi(&m, "read"), ("".into(), "".into()));
    }
    let source = "#[julia] struct Counter; mod nested { use super::*; type Counter = i32; #[julia] fn read(x: &Counter) {} }";
    let m = expand::expand(source).unwrap().manifest;
    assert_eq!(abi(&m, "read"), ("borrow_unresolved".into(), "".into()));
    assert!(m.functions[0].args[0].borrow_reason.contains("alias"));
}
#[test]
fn ambiguous_glob_has_structured_diagnostic_not_selected_owner_guess() {
    let source = "#[julia] mod a { #[julia] struct Counter; } #[julia] mod b { #[julia] struct Counter; } #[julia] mod nested { use crate::a::*; use crate::b::*; #[julia] fn read(x: &Counter) {} }";
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        assert_eq!(abi(&m, "read"), ("borrow_unresolved".into(), "".into()));
        assert!(!m.functions[0].args[0].borrow_reason.is_empty());
        let encoded = toml::to_string(&m).unwrap();
        let decoded: Manifest = toml::from_str(&encoded).unwrap();
        assert_eq!(
            decoded.functions[0].args[0].borrow_reason,
            m.functions[0].args[0].borrow_reason
        );
    }
}
#[test]
fn resolved_feature_cfg_preserves_owner_but_unknown_cfg_refuses_proof() {
    let source =
        "#[cfg(feature=\"owner\")] #[julia] struct Counter; #[julia] fn read(x:&Counter) {}";
    let cfg = CfgSet::parse("feature=\"owner\"\n").unwrap();
    let m =
        extract::extract_with_cfg(source, rustcall_julia_core::Mode::Crate, Some(&cfg)).unwrap();
    assert_eq!(abi(&m, "read"), ("handle".into(), "Counter".into()));
    let m = extract::extract_crate(source).unwrap();
    assert_eq!(abi(&m, "read"), ("borrow_unresolved".into(), "".into()));
}
#[test]
fn function_type_parameter_shadows_module_owner() {
    let source = "#[julia] struct T; #[julia] fn read<T>(x: &T) {}";
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        assert_eq!(abi(&m, "read"), ("".into(), "".into()));
    }
}

#[test]
fn generated_aggregate_types_shadow_glob_owner_at_lexical_wrapper_site() {
    let source = r#"
        #[julia] mod owners { #[julia] pub struct CResult_nested__produce; }
        #[julia] mod nested {
            use crate::owners::*;
            #[julia] pub fn produce() -> Result<i32, i32> { Ok(1) }
            #[julia] pub fn read(x: &CResult_nested__produce) { let _ = x; }
        }
    "#;
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        assert_eq!(abi(&m, "read"), ("".into(), "".into()));
    }
}

#[test]
fn unresolved_cfg_generated_helper_and_cfg_attr_cannot_hide_glob_shadow() {
    let source = r#"
        #[julia] mod owners { #[julia] pub struct CResult_nested__produce; }
        #[julia] mod nested {
            use crate::owners::*;
            #[cfg(feature="x")] #[julia] pub fn produce() -> Result<i32, i32> { Ok(1) }
            #[julia] pub fn read(x: &CResult_nested__produce) { let _ = x; }
        }
    "#;
    let unknown = extract::extract_crate(source).unwrap();
    assert_eq!(abi(&unknown, "read").0, "borrow_unresolved");
    for (text, expected) in [("feature=\"x\"\n", ""), ("", "handle")] {
        let cfg = CfgSet::parse(text).unwrap();
        let m = extract::extract_with_cfg(source, rustcall_julia_core::Mode::Crate, Some(&cfg))
            .unwrap();
        assert_eq!(abi(&m, "read").0, expected);
    }
    let source = "#[julia] struct Counter; mod nested { use super::*; #[cfg_attr(feature=\"x\", derive(MakeCounter))] struct Trigger; #[julia] fn read(x:&Counter) {} }";
    assert_eq!(
        abi(&expand::expand(source).unwrap().manifest, "read").0,
        "borrow_unresolved"
    );
}
#[test]
fn inline_runtime_type_binding_shadows_glob_owner() {
    let source = "#[julia] mod owners { #[julia] struct __RustCallBoundary; } use owners::*; #[julia] fn read(x:&__RustCallBoundary) {}";
    assert_eq!(
        abi(&expand::expand(source).unwrap().manifest, "read"),
        ("".into(), "".into())
    );
}

#[test]
fn unresolved_conditional_field_helper_obscures_glob_without_methods() {
    let source = r#"
        #[julia] mod owners { #[julia] pub struct Producer_RustCallOwnedString; }
        use crate::owners::*;
        #[cfg(feature="x")] #[julia] pub struct Producer { pub label: String }
        #[julia] pub fn read(x: &Producer_RustCallOwnedString) { let _ = x; }
    "#;
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        assert_eq!(abi(&m, "read").0, "borrow_unresolved");
    }
}

#[test]
fn resolved_builtin_path_module_preserves_qualified_and_glob_owner_borrows() {
    let source = r#"
        #[path="selected.rs"] #[julia] pub mod owners { #[julia] pub struct Owner { pub value: i32 } }
        #[julia] pub fn qualified(x: &owners::Owner) -> i32 { x.value }
        #[julia] pub mod consumer { use crate::owners::*; #[julia] pub fn read(x: &Owner) -> i32 { x.value } }
    "#;
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        assert_eq!(
            abi(&m, "qualified"),
            ("handle".into(), "owners__Owner".into())
        );
        assert_eq!(abi(&m, "read"), ("handle".into(), "owners__Owner".into()));
    }
}

#[test]
fn inline_derive_owners_share_mode_aware_struct_selection_for_borrows() {
    let source = r#"
        #[derive(JuliaStruct)] pub struct Owner { pub value: i32 }
        #[julia] pub fn read(x: &Owner) -> i32 { x.value }
        #[julia] pub fn change(x: &mut Owner) { x.value += 1; }
        #[julia] pub mod consumer { use super::*; #[julia] pub fn glob(x: &Owner) -> i32 { x.value } }
    "#;
    let inline = expand::expand(source).unwrap().manifest;
    assert_eq!(abi(&inline, "read"), ("handle".into(), "Owner".into()));
    assert_eq!(
        abi(&inline, "change"),
        ("handle_mut".into(), "Owner".into())
    );
    assert_eq!(abi(&inline, "glob"), ("handle".into(), "Owner".into()));
    // Derive-only structs are not selected opaque owners in crate mode.
    let krate = extract::extract_crate(source).unwrap();
    assert_eq!(abi(&krate, "read"), ("".into(), "".into()));
    assert_eq!(abi(&krate, "change"), ("".into(), "".into()));
}

#[test]
fn anchored_module_aliases_preserve_qualified_and_glob_owner_proof() {
    let source = r#"
        #[julia] pub struct Owner { pub value: i32 }
        use crate as root;
        #[julia] pub fn root_read(x: &root::Owner) -> i32 { x.value }
        #[julia] pub mod consumer {
            use self as here;
            use super as parent;
            use crate as root;
            use root::*;
            #[julia] pub fn here_read(x: &here::Owner) -> i32 { x.value }
            #[julia] pub fn parent_read(x: &parent::Owner) -> i32 { x.value }
            #[julia] pub fn glob_read(x: &mut Owner) { x.value += 1; }
        }
    "#;
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        for name in ["root_read", "here_read", "parent_read"] {
            assert_eq!(abi(&m, name), ("handle".into(), "Owner".into()));
        }
        assert_eq!(abi(&m, "glob_read"), ("handle_mut".into(), "Owner".into()));
    }
}

#[test]
fn raw_identifier_plain_shadow_has_the_same_lexical_name() {
    let source = r#"
        #[julia] pub struct Counter { pub value:i32 }
        #[julia] pub mod consumer { use super::*; pub struct r#Counter { pub value:i64 } #[julia] pub fn read(value:&Counter)->i64 { value.value } }
    "#;
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        assert_eq!(abi(&m, "read"), ("".into(), "".into()));
    }
}

#[test]
fn raw_owner_module_and_renamed_import_keep_original_codegen_spelling() {
    let source = r#"
        #[julia] pub mod r#owners { #[julia] pub struct r#Owner { pub value:i32 } #[julia] pub fn internal(x:&Owner)->i32{x.value} }
        use crate::r#owners as r#alias;
        use crate::owners::r#Owner as r#Renamed;
        #[julia] pub fn normal(x:&alias::Owner)->i32 {x.value}
        #[julia] pub fn raw(x:&r#alias::r#Owner)->i32 {x.value}
        #[julia] pub fn renamed(x:&Renamed)->i32 {x.value}
    "#;
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        for name in ["normal", "raw", "renamed", "internal"] {
            assert_eq!(abi(&m, name), ("handle".into(), "owners__Owner".into()));
        }
        assert_eq!(m.structs[0].name, "r#Owner");
        assert_eq!(m.structs[0].module_path, vec!["r#owners"]);
    }
}

#[test]
fn unicode_nfc_plain_shadow_has_the_same_lexical_name() {
    let source = "#[julia] pub struct Kounter {pub value:i32} #[julia] pub mod consumer { use super::*; pub struct \u{212a}ounter {pub value:i64} #[julia] pub fn read(value:&Kounter)->i64{value.value} }";
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        assert_eq!(abi(&m, "read"), ("".into(), "".into()));
    }
}

#[test]
fn unicode_nfc_type_and_module_import_aliases_preserve_ascii_owner_identity() {
    let source = "#[julia] pub mod data { #[julia] pub struct Kounter { pub value:i32 } } use crate::data as \u{212a}; use crate::data::Kounter as \u{212a}ounter; #[julia] pub fn type_alias(x:&Kounter)->i32{x.value} #[julia] pub fn module_alias(x:&K::Kounter)->i32{x.value} #[julia] pub fn original_spelling(x:&\u{212a}ounter)->i32{x.value}";
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        for name in ["type_alias", "module_alias", "original_spelling"] {
            assert_eq!(abi(&m, name), ("handle".into(), "data__Kounter".into()));
        }
        assert!(m
            .functions
            .iter()
            .find(|f| f.name == "original_spelling")
            .unwrap()
            .args[0]
            .rust_type
            .contains('\u{212a}'));
    }
}

#[test]
fn named_values_do_not_suppress_glob_type_bindings() {
    for item in [
        "pub fn Counter()->i32{7}",
        "pub const Counter:i32=7;",
        "pub static Counter:i32=7;",
    ] {
        let source = format!("#[julia] pub struct Counter{{pub value:i32}} mod values{{{item}}} #[julia] pub mod consumer{{use super::*;use crate::values::Counter;#[julia]pub fn read(value:&Counter){{let _=value;}}}}");
        for m in [
            extract::extract_crate(&source).unwrap(),
            expand::expand(&source).unwrap().manifest,
        ] {
            assert_eq!(abi(&m, "read"), ("handle".into(), "Counter".into()));
        }
    }
}
#[test]
fn named_import_private_type_and_public_value_stay_in_separate_namespaces() {
    let source = "#[julia] pub struct Counter{pub value:i32} mod values{struct Counter{value:i64} pub fn Counter()->i32{7}} #[julia] pub mod consumer{use super::*;use crate::values::Counter;#[julia]pub fn read(value:&Counter)->i32{value.value+Counter()}}";
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        assert_eq!(abi(&m, "read"), ("handle".into(), "Counter".into()));
    }
}
#[test]
fn unknown_named_external_type_still_blocks_glob_guessing() {
    let source = "#[julia] pub struct Counter{pub value:i32} #[julia] pub mod consumer{use super::*;use external::Counter;#[julia]pub fn read(value:&Counter){let _=value;}}";
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        assert_eq!(abi(&m, "read").0, "borrow_unresolved");
    }
}

#[test]
fn unindexed_extern_crate_alias_still_blocks_module_glob_guessing() {
    let source = "#[julia] pub mod Counter{#[julia]pub struct Owner{pub value:i32}} #[julia]pub mod consumer{use super::*;use external as Counter;#[julia]pub fn read(value:&Counter::Owner){let _=value;}}";
    let m = extract::extract_crate(source).unwrap();
    assert_eq!(abi(&m, "read").0, "borrow_unresolved");
}
#[test]
fn named_type_namespace_declarations_keep_precedence_over_globs() {
    for item in [
        "pub struct Counter;",
        "pub struct Counter(pub i64);",
        "pub struct Counter{pub value:i64}",
        "pub enum Counter{A}",
        "pub union Counter{pub value:i64}",
        "pub trait Counter{}",
        "pub type Counter=crate::Counter;",
    ] {
        let source=format!("#[julia]pub struct Counter{{pub value:i32}} mod types{{{item}}} #[julia]pub mod consumer{{use super::*;use crate::types::Counter;#[julia]pub fn read(value:&Counter){{let _=value;}}}}");
        for m in [
            extract::extract_crate(&source).unwrap(),
            expand::expand(&source).unwrap().manifest,
        ] {
            assert_ne!(abi(&m, "read").0, "handle");
        }
    }
}
#[test]
fn named_modules_keep_type_namespace_precedence() {
    let source = r#"
        #[julia] pub mod actual { #[julia] pub struct Owner {pub value:i32} }
        #[julia] pub mod Counter { pub struct Owner {pub value:i64} }
        pub mod facade { pub use crate::actual as Counter; }
        #[julia] pub mod consumer { use super::*; use crate::facade::Counter; #[julia]pub fn read(value:&Counter::Owner){let _=value;} }
    "#;
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        assert_eq!(abi(&m, "read"), ("handle".into(), "actual__Owner".into()));
    }
}

#[test]
fn public_type_glob_survives_private_value_only_import() {
    let source = r#"
        #[julia] pub struct Counter {pub value:i64}
        #[julia] pub mod types { #[julia]pub struct Counter {pub value:i32} }
        mod values {pub fn Counter()->i32{7}}
        pub mod facade {pub use crate::types::*; use crate::values::Counter;}
        #[julia]pub mod consumer {use super::*;use crate::facade::Counter;#[julia]pub fn read(value:&Counter)->i32{value.value}}
    "#;
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        assert_eq!(abi(&m, "read"), ("handle".into(), "types__Counter".into()));
    }
}

#[test]
fn public_generated_helper_imports_never_fall_through_to_glob_owners() {
    for (return_type, body, helper) in [
        (
            "String",
            "String::new()",
            "helpers__produce_RustCallOwnedString",
        ),
        (
            "&'static str",
            "\"view\"",
            "helpers__produce_RustCallBorrowedString",
        ),
        ("Result<i32, i32>", "Ok(7)", "CResult_helpers__produce"),
        ("Option<i32>", "Some(7)", "COption_helpers__produce"),
    ] {
        let source = format!(
            r#"
            #[julia] pub mod helpers {{
                #[julia] pub fn produce() -> {return_type} {{ {body} }}
            }}
            #[julia] pub mod owners {{
                #[julia] pub struct {helper} {{ pub value: i32 }}
            }}
            pub mod bridge {{ pub use crate::helpers::{helper}; }}
            #[julia] pub mod consumer {{
                use crate::bridge::{helper};
                use crate::owners::*;
                #[julia] pub fn read(value: &{helper}) {{ let _ = value; }}
                #[julia] pub fn change(value: &mut {helper}) {{ let _ = value; }}
            }}
            #[julia] pub mod glob_consumer {{
                use crate::helpers::*;
                use crate::owners::*;
                #[julia] pub fn ambiguous(value: &{helper}) {{ let _ = value; }}
            }}
        "#
        );
        let expanded = expand::expand(&source).unwrap();
        let emitted = syn::parse_file(&expanded.source).unwrap();
        let helpers = emitted
            .items
            .iter()
            .find_map(|item| match item {
                syn::Item::Mod(module) if module.ident == "helpers" => module.content.as_ref(),
                _ => None,
            })
            .unwrap();
        let declaration = helpers
            .1
            .iter()
            .find_map(|item| match item {
                syn::Item::Struct(declaration) if declaration.ident == helper => Some(declaration),
                _ => None,
            })
            .expect("claimed helper is actually emitted");
        assert!(
            matches!(declaration.vis, syn::Visibility::Public(_)),
            "{helper}"
        );
        for m in [extract::extract_crate(&source).unwrap(), expanded.manifest] {
            assert_eq!(abi(&m, "read"), ("".into(), "".into()), "{helper}");
            assert_eq!(abi(&m, "change"), ("".into(), "".into()), "{helper}");
            assert_eq!(
                abi(&m, "ambiguous"),
                ("borrow_unresolved".into(), "".into()),
                "{helper}"
            );
        }
    }
}

#[test]
fn public_generated_helper_named_import_has_an_ordinary_typed_rust_control() {
    use std::{fs, process::Command};
    let source = r#"
        #[julia] pub mod helpers {
            #[julia] pub fn produce() -> String { String::new() }
        }
        #[julia] pub mod owners {
            #[julia] pub struct helpers__produce_RustCallOwnedString { pub value: i32 }
        }
        pub mod bridge { pub use crate::helpers::helpers__produce_RustCallOwnedString; }
        #[julia] pub mod consumer {
            use crate::bridge::helpers__produce_RustCallOwnedString;
            use crate::owners::*;
            #[julia] pub fn read(value: &helpers__produce_RustCallOwnedString) -> usize { value.len }
        }
    "#;
    let expanded = expand::expand(source).unwrap();
    assert_eq!(abi(&expanded.manifest, "read"), ("".into(), "".into()));
    let program = format!(
        r#"{}
        fn main() {{
            let value = helpers::helpers__produce_RustCallOwnedString {{
                ptr: std::ptr::null_mut(), len: 7, cap: 0,
            }};
            // Ordinary Rust dispatch only: no generated extern shim is called.
            assert_eq!(consumer::read(&value), 7);
            assert!(std::mem::size_of_val(&value) > std::mem::size_of::<owners::helpers__produce_RustCallOwnedString>());
        }}
    "#,
        expanded.source
    );
    let dir = std::env::temp_dir().join(format!(
        "rustcall569_helper_visibility_{}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let file = dir.join("control.rs");
    let executable = dir.join(format!("control{}", std::env::consts::EXE_SUFFIX));
    fs::write(&file, program).unwrap();
    let compilation = Command::new("rustc")
        .args(["--edition=2021", "-Awarnings"])
        .arg(&file)
        .arg("-o")
        .arg(&executable)
        .output()
        .unwrap();
    assert!(
        compilation.status.success(),
        "{}",
        String::from_utf8_lossy(&compilation.stderr)
    );
    assert!(Command::new(executable).status().unwrap().success());
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn rewriting_module_attributes_obscure_local_glob_qualified_and_self_borrows() {
    for (outer, inner) in [
        ("#[inject]", ""),
        ("", "#![inject]"),
        ("#[cfg_attr(unknown, inject)]", ""),
    ] {
        let source = format!(
            r#"
            #[julia] pub struct Counter {{ pub value: i32 }}
            {outer} #[julia] pub mod consumer {{ {inner}
                use super::*;
                #[julia] pub struct Local {{ pub value: i32 }}
                #[julia] impl Local {{ #[julia] pub fn other(&self, value: &Self) {{ let _ = value; }} }}
                #[julia] pub fn glob(value: &Counter) {{ let _ = value; }}
                #[julia] pub fn local(value: &Local) {{ let _ = value; }}
                #[julia] pub mod child {{
                    #[julia] pub fn qualified(value: &crate::Counter) {{ let _ = value; }}
                }}
            }}
            #[julia] pub mod unrelated {{
                #[julia] pub fn control(value: &crate::Counter) {{ let _ = value; }}
            }}
            use crate::consumer::Local as Reexport;
            #[julia] pub fn imported(value: &Reexport) {{ let _ = value; }}
        "#
        );
        for m in [
            extract::extract_crate(&source).unwrap(),
            expand::expand(&source).unwrap().manifest,
        ] {
            for name in ["glob", "local", "qualified", "imported"] {
                assert_eq!(
                    abi(&m, name),
                    ("borrow_unresolved".into(), "".into()),
                    "{outer} {inner}: {name}"
                );
            }
            let method = m
                .structs
                .iter()
                .find(|s| s.name == "Local")
                .unwrap()
                .methods
                .iter()
                .find(|method| method.name == "other")
                .unwrap();
            assert_eq!(method.args[0].abi, "borrow_unresolved");
            assert!(method.args[0].handle.is_empty());
            assert_eq!(abi(&m, "control"), ("handle".into(), "Counter".into()));
        }
    }
    let source = "#![inject]\n#[julia] pub struct Counter { pub value:i32 } #[julia] pub fn root(value:&Counter) {} #[julia] pub mod child { #[julia] pub fn nested(value:&crate::Counter) {} }";
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        for name in ["root", "nested"] {
            assert_eq!(abi(&m, name), ("borrow_unresolved".into(), "".into()));
        }
    }
}

#[test]
fn rewriting_module_proc_macro_has_an_ordinary_typed_rust_control() {
    use std::{fs, process::Command};
    let dir = std::env::temp_dir().join(format!(
        "rustcall569_module_attribute_{}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let macro_file = dir.join("inject.rs");
    let macro_library = dir.join(format!(
        "{}inject569{}",
        std::env::consts::DLL_PREFIX,
        std::env::consts::DLL_SUFFIX
    ));
    fs::write(&macro_file, r##"
        extern crate proc_macro;
        use proc_macro::{Delimiter, Group, TokenStream, TokenTree};
        #[proc_macro_attribute]
        pub fn inject(_: TokenStream, item: TokenStream) -> TokenStream {
            item.into_iter().map(|token| match token {
                TokenTree::Group(group) if group.delimiter() == Delimiter::Brace => {
                    let declaration: TokenStream = "#[repr(C)] pub struct Counter { pub value: i32, pub extra: i64 }".parse().unwrap();
                    let contents = declaration.into_iter().chain(group.stream()).collect();
                    TokenTree::Group(Group::new(Delimiter::Brace, contents))
                }
                token => token,
            }).collect()
        }
    "##).unwrap();
    let compile_macro = Command::new("rustc")
        .args([
            "--edition=2021",
            "--crate-type=proc-macro",
            "--crate-name=inject569",
        ])
        .arg(&macro_file)
        .arg("-o")
        .arg(&macro_library)
        .output()
        .unwrap();
    assert!(
        compile_macro.status.success(),
        "{}",
        String::from_utf8_lossy(&compile_macro.stderr)
    );
    let file = dir.join("control.rs");
    fs::write(
        &file,
        r#"
        #[repr(C)] pub struct Counter { pub value: i32 }
        #[inject569::inject]
        pub mod consumer {
            use super::*;
            pub fn read(value: &Counter) -> i64 { value.extra }
            pub fn run() -> i64 { read(&Counter { value: 1, extra: 42 }) }
        }
        fn main() {
            assert_eq!(consumer::run(), 42);
            assert!(std::mem::size_of::<consumer::Counter>() > std::mem::size_of::<Counter>());
        }
    "#,
    )
    .unwrap();
    let executable = dir.join(format!("control{}", std::env::consts::EXE_SUFFIX));
    let compilation = Command::new("rustc")
        .args(["--edition=2021", "-Awarnings", "--extern"])
        .arg(format!("inject569={}", macro_library.display()))
        .arg(&file)
        .arg("-o")
        .arg(&executable)
        .output()
        .unwrap();
    assert!(
        compilation.status.success(),
        "{}",
        String::from_utf8_lossy(&compilation.stderr)
    );
    // Only ordinary Rust dispatch on its correctly typed injected value.
    assert!(Command::new(executable).status().unwrap().success());
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn file_inner_rewrite_blocks_outside_qualified_named_glob_reexport_and_self_proofs() {
    use rustcall_julia_core::{
        extract::{FilePosition, TreeScan},
        manifest::Mode,
    };
    let mut tree = TreeScan::with_edition("2021");
    let mut manifest = Manifest::new(Mode::Crate);
    tree.file(
        r#"
        pub mod rewritten_child;
        #[julia] pub struct Counter { pub value: i32 }
        #[julia] pub fn control(value: &Counter) {}
        #[julia] pub fn qualified(value: &crate::rewritten_child::Owner) {}
        use crate::rewritten_child::Owner as Named;
        #[julia] pub fn named(value: &Named) {}
        pub mod bridge { pub use crate::rewritten_child::*; }
        use crate::bridge::*;
        #[julia] pub fn glob(value: &Owner) {}
        use crate::rewritten_child::Owner;
        #[julia] impl Owner {
            #[julia] pub fn outside(&self, value: &Self) {}
        }
    "#,
        None,
        &FilePosition::module(&[], true, &[]),
        &mut manifest,
        "lib.rs",
    )
    .unwrap();
    tree.file(
        "#![rewrite]\n#[julia] pub struct Owner { pub value: i32 }",
        None,
        &FilePosition::module(&["rewritten_child".into()], true, &[]),
        &mut manifest,
        "rewritten_child.rs",
    )
    .unwrap();
    tree.finish(&mut manifest).unwrap();
    for name in ["qualified", "named", "glob"] {
        assert_eq!(
            abi(&manifest, name),
            ("borrow_unresolved".into(), "".into()),
            "{name}"
        );
    }
    let method = manifest
        .structs
        .iter()
        .find(|s| s.name == "Owner")
        .unwrap()
        .methods
        .iter()
        .find(|method| method.name == "outside")
        .unwrap();
    assert_eq!(method.args[0].abi, "borrow_unresolved");
    assert!(method.args[0].handle.is_empty());
    assert_eq!(
        abi(&manifest, "control"),
        ("handle".into(), "Counter".into())
    );
}

#[test]
fn scoped_globs_compose_optional_slice_and_explicit_owned_return_contracts() {
    let source = r#"
        #[julia] pub mod owners {
            #[julia] pub struct Counter { pub value: i32 }
            #[julia] pub struct Factor { pub value: i32 }
        }
        #[julia] pub mod consumer {
            use crate::owners::*;
            #[julia] #[rustcall_owned_return(Factor)]
            pub fn compose(source: Option<&Counter>, values: &[i32]) -> Factor {
                Factor { value: source.map_or(0, |v| v.value) + values.iter().sum::<i32>() }
            }
            #[julia] #[rustcall_owned_return(Factor)]
            pub fn fallible(source: Option<&mut Counter>, values: &mut [i32]) -> Result<Factor, i32> {
                Ok(Factor { value: source.map_or(0, |v| v.value) + values.iter().sum::<i32>() })
            }
        }
    "#;
    for m in [
        extract::extract_crate(source).unwrap(),
        expand::expand(source).unwrap().manifest,
    ] {
        for (name, owner_abi, slice_abi) in [
            ("compose", "handle_optional", "slice"),
            ("fallible", "handle_optional_mut", "slice_mut"),
        ] {
            let f = m.functions.iter().find(|f| f.name == name).unwrap();
            assert_eq!(
                f.args[0].abi, owner_abi,
                "{} / {:?} / {}",
                name, m.mode, f.args[0].borrow_reason
            );
            assert_eq!(f.args[0].handle, "owners__Counter");
            assert!(f.args[0].borrow_reason.is_empty());
            assert_eq!(f.args[1].abi, slice_abi);
            assert_eq!(f.args[1].slice_element, "i32");
            assert_eq!(f.return_handle, "owners__Factor");
            assert!(f.skip_reason.is_empty(), "{}", f.skip_reason);
        }
    }
}

#[test]
fn rewritten_glob_context_cannot_prove_optional_or_explicit_owned_returns() {
    let source = r#"
        #[julia] pub mod owners {
            #[julia] pub struct Counter { pub value: i32 }
            #[julia] pub struct Factor { pub value: i32 }
        }
        #[rewrite] #[julia] pub mod rewritten {
            use crate::owners::*;
            #[julia] #[rustcall_owned_return(Factor)]
            pub fn compose(source: Option<&Counter>, values: &[i32]) -> Factor {
                Factor { value: 0 }
            }
        }
    "#;
    // Consumed helper recognition belongs only to selected functions;
    // this spelling on a module can still name an arbitrary proc macro.
    for source in [
        source.to_owned(),
        source.replace("#[rewrite]", "#[rustcall_owned_return(Factor)]"),
    ] {
        for m in [
            extract::extract_crate(&source).unwrap(),
            expand::expand(&source).unwrap().manifest,
        ] {
            let f = m.functions.iter().find(|f| f.name == "compose").unwrap();
            assert_eq!(f.args[0].abi, "optional_borrow");
            assert!(f.args[0].handle.is_empty());
            assert!(!f.args[0].borrow_reason.is_empty());
            assert!(f.return_handle.is_empty());
            assert!(!f.skip_reason.is_empty());
            assert!(!f.exported);
        }
    }
}

#[test]
fn rewritten_defining_file_blocks_selected_owned_and_self_return_shortcuts() {
    use rustcall_julia_core::{
        extract::{FilePosition, TreeScan},
        manifest::Mode,
    };
    let mut tree = TreeScan::with_edition("2021");
    let mut manifest = Manifest::new(Mode::Crate);
    tree.file(r#"
        pub mod rewritten_child;
        #[julia] #[rustcall_owned_return(crate::rewritten_child::Owner)]
        pub fn selected() -> crate::rewritten_child::Owner { crate::rewritten_child::Owner { value: 1 } }
        use crate::rewritten_child::Owner;
        #[julia] impl Owner {
            #[julia] #[rustcall_owned_return(Self)]
            pub fn selected_self(&self, source: Option<&Self>) -> Self { Self { value: 1 } }
        }
    "#, None, &FilePosition::module(&[], true, &[]), &mut manifest, "lib.rs").unwrap();
    tree.file(
        "#![rewrite]\n#[julia] pub struct Owner { pub value: i32 }",
        None,
        &FilePosition::module(&["rewritten_child".into()], true, &[]),
        &mut manifest,
        "rewritten_child.rs",
    )
    .unwrap();
    tree.finish(&mut manifest).unwrap();
    let f = manifest
        .functions
        .iter()
        .find(|f| f.name == "selected")
        .unwrap();
    assert!(f.return_handle.is_empty());
    assert!(!f.skip_reason.is_empty());
    assert!(!f.exported);
    let method = manifest
        .structs
        .iter()
        .find(|s| s.name == "Owner")
        .unwrap()
        .methods
        .iter()
        .find(|m| m.name == "selected_self")
        .unwrap();
    assert!(method.return_handle.is_empty());
    assert!(!method.skip_reason.is_empty());
    assert_eq!(method.args[0].abi, "optional_borrow");
    assert!(!method.args[0].borrow_reason.is_empty());
}
