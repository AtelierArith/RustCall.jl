//! A trait impl's `#[julia]` method is called through the trait (#497):
//! `<Buf as tr::Far>::m(self_obj)`, spelled as the impl header spells the type
//! and the trait — the wrapper is emitted in the block's module — so it needs no
//! import and never reaches an inherent method of the same name. An inherent
//! block's method is called by path as well, `<Buf>::m(self_obj)` (#509), and
//! every exported symbol is unchanged.
//!
//! The proc-macro flavour, compiled and called, is
//! `deps/rustcall_julia_macros/tests/trait_path_methods.rs`.

use rustcall_julia_core::codegen::transform_impl_crate;

fn expanded(item: syn::ItemImpl) -> String {
    prettyplease::unparse(&syn::parse2(transform_impl_crate(item, &[])).unwrap())
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[test]
fn trait_impl_methods_are_called_through_the_trait() {
    let src = expanded(syn::parse_quote! {
        #[julia]
        impl tr::Far for Buf {
            #[julia]
            fn m(&self) -> i32 { self.n }
            #[julia]
            fn bump(&mut self, by: i32) -> i32 { by }
            #[julia]
            fn make() -> i32 { 42 }
            #[julia]
            fn take(self) -> i32 { 1 }
        }
    });
    assert!(src.contains("<Buf as tr::Far>::m(self_obj)"), "{src}");
    assert!(
        src.contains("<Buf as tr::Far>::bump(self_obj, by)"),
        "{src}"
    );
    assert!(src.contains("<Buf as tr::Far>::make()"), "{src}");
    // A receiver taken by value is the value behind the pointer, as
    // method-call syntax would have auto-dereferenced it.
    assert!(src.contains("<Buf as tr::Far>::take(*self_obj)"), "{src}");
    assert!(!src.contains("self_obj.m("), "{src}");
    assert!(!src.contains("Buf::make()"), "{src}");
    // The symbols are the ones an inherent method of the same name gets.
    for symbol in ["rustcall_Buf_m", "rustcall_Buf_bump", "rustcall_Buf_make"] {
        assert!(
            src.contains(&format!("pub extern \"C\" fn {symbol}(")),
            "{symbol}: {src}"
        );
    }
    // The panic message names the method as a Julia caller knows it.
    assert!(src.contains("\"Buf::m\""), "{src}");
}

#[test]
fn the_receiver_argument_follows_the_declared_receiver_type() {
    // A path call applies no autoref: each reference layer beyond the one
    // `self_obj` already is is taken again (PR #505 review).
    let src = expanded(syn::parse_quote! {
        #[julia]
        impl tr::Forms for Buf {
            #[julia]
            fn typed_ref(self: &Self) -> i32 { 0 }
            #[julia]
            fn ref_ref(self: &&Self) -> i32 { 0 }
            #[julia]
            fn ref_ref_ref(self: &'a &&Self) -> i32 { 0 }
            #[julia]
            fn mut_value(mut self) -> i32 { 0 }
        }
    });
    assert!(
        src.contains("<Buf as tr::Forms>::typed_ref(self_obj)"),
        "{src}"
    );
    assert!(
        src.contains("<Buf as tr::Forms>::ref_ref(&self_obj)"),
        "{src}"
    );
    assert!(
        src.contains("<Buf as tr::Forms>::ref_ref_ref(&&self_obj)"),
        "{src}"
    );
    assert!(
        src.contains("<Buf as tr::Forms>::mut_value(*self_obj)"),
        "{src}"
    );
}

#[test]
fn a_foreign_block_spells_both_paths_as_its_header_does() {
    let src = expanded(syn::parse_quote! {
        #[julia]
        impl super::tr::Near for super::Buf {
            #[julia]
            fn only_near(&self) -> i32 { self.n }
        }
    });
    assert!(
        src.contains("<super::Buf as super::tr::Near>::only_near(self_obj)"),
        "{src}"
    );
    assert!(
        src.contains("pub extern \"C\" fn rustcall_Buf_only_near("),
        "{src}"
    );
}

#[test]
fn an_inherent_block_is_called_by_path_too() {
    let src = expanded(syn::parse_quote! {
        #[julia]
        impl Buf {
            #[julia]
            pub fn m(&self) -> i32 { self.n }
            #[julia]
            pub fn make() -> i32 { 42 }
        }
    });
    // The same path call, without a trait (#509): `<Buf>::m` resolves to the
    // inherent item before any trait's, and needs nothing in scope.
    assert!(src.contains("<Buf>::m(self_obj)"), "{src}");
    assert!(src.contains("<Buf>::make()"), "{src}");
    assert!(!src.contains("self_obj.m("), "{src}");
    assert!(!src.contains(" as "), "{src}");
}
