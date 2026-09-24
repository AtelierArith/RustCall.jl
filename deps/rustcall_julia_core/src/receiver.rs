//! The receiver of a `#[julia]` method, read from its syntax in one place
//! (#509).
//!
//! A method wrapper receives the object as a raw pointer, binds it to
//! `self_obj` (`&*ptr` or `&mut *ptr`) and calls the method by path —
//! `<Buf>::m(..)` for an inherent method, `<Buf as tr::Far>::m(..)` for a
//! trait impl's (#497). A path call applies no autoref or autoderef, so the
//! receiver argument must be built from the receiver's declared shape; and the
//! pointer the wrapper takes, the borrow it binds and the manifest's
//! `is_mutable` all follow from that same shape. [`Receiver::of`] decides it
//! for both inherent and trait methods and for both flavours (the proc macro
//! and the inline `rust"""` expander); nothing else reads a receiver.
//!
//! The shape is readable only when the receiver is written as literal
//! reference layers over the implementing type — `self`, `&self`,
//! `&mut self`, `self: &Self`, `self: &mut Self`, `self: &&Self`, or the
//! type spelled exactly as the impl header spells it (`self: &Buf` in
//! `impl Buf`). A type alias (`self: Ref<'_, Self>`), a smart pointer
//! (`Box<Self>`, `Rc<Self>`, `Arc<Self>`, `Pin<&mut Self>`) or the type
//! spelled differently from the header (`self: &Buf` in `impl super::Buf`)
//! names a type the syntax cannot resolve, so the method is refused through
//! [`crate::refusal`] (`skip_reason::RECEIVER_TYPE`) rather than wrapped by a
//! guess.

use proc_macro2::TokenStream as TokenStream2;
use quote::quote;
use syn::{Ident, Signature, Type};

use crate::types::unparen;

/// One reference layer of a receiver.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Layer {
    /// `&`
    Shared,
    /// `&mut`
    Mut,
}

/// What a method's receiver is, as far as its syntax says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Receiver {
    /// No receiver: an associated function (`fn make() -> Self`).
    Static,
    /// Reference layers over the implementing type, outermost first; no layer
    /// is a receiver taken by value (`self`, `mut self`, `self: Self`).
    Layers(Vec<Layer>),
    /// A receiver whose type is not literal reference layers over the
    /// implementing type: a type alias, a smart pointer, or the type spelled
    /// otherwise than the header does. The type as written.
    Unreadable(Box<Type>),
}

impl Receiver {
    /// The receiver of `sig`. `own_ty` is the impl header's type as written
    /// (`Buf`, `super::Buf`, `Wrapper<T>`), which a typed receiver may spell
    /// in place of `Self`; `None` accepts only `Self`.
    pub fn of(sig: &Signature, own_ty: Option<&Type>) -> Receiver {
        let Some(receiver) = sig.receiver() else {
            return Receiver::Static;
        };
        let mut layers = Vec::new();
        let mut ty = unparen(&receiver.ty);
        while let Type::Reference(r) = ty {
            layers.push(if r.mutability.is_some() {
                Layer::Mut
            } else {
                Layer::Shared
            });
            ty = unparen(&r.elem);
        }
        let is_self = matches!(
            ty,
            Type::Path(tp) if tp.qself.is_none() && tp.path.is_ident("Self")
        );
        let is_own = own_ty.is_some_and(|own| same_spelling(ty, unparen(own)));
        if is_self || is_own {
            Receiver::Layers(layers)
        } else {
            Receiver::Unreadable(receiver.ty.clone())
        }
    }

    /// A plain `&self` (`&mut self` when `mutable`): the receiver a manifest
    /// entry describes with `is_static = false` and its `is_mutable`, for a
    /// wrapper spelled from the manifest alone (`crate::wrap`).
    pub fn reference(mutable: bool) -> Receiver {
        Receiver::Layers(vec![if mutable { Layer::Mut } else { Layer::Shared }])
    }

    /// Whether this is a plain `&self` or `&mut self`: one reference layer
    /// over the type, the only shape a manifest entry can describe.
    pub fn is_single_reference(&self) -> bool {
        matches!(self, Receiver::Layers(layers) if layers.len() == 1)
    }

    /// An associated function, which takes no object.
    pub fn is_static(&self) -> bool {
        matches!(self, Receiver::Static)
    }

    /// Whether the method borrows the object mutably: its innermost reference
    /// layer is `&mut`. The wrapper then takes `*mut` and binds `&mut *ptr`;
    /// the manifest's `Method.is_mutable`. A receiver taken by value (`mut
    /// self` included) works on a copy and leaves the object alone.
    pub fn is_mutable(&self) -> bool {
        matches!(self, Receiver::Layers(layers) if layers.last() == Some(&Layer::Mut))
    }

    /// Whether the wrapper can pass this receiver: every receiver but an
    /// unreadable one.
    pub fn is_readable(&self) -> bool {
        !matches!(self, Receiver::Unreadable(_))
    }

    /// `let self_obj = unsafe { &*ptr };` (`&mut *ptr` for a mutable
    /// receiver, `let mut` when the argument borrows `self_obj` itself
    /// mutably), or nothing for an associated function.
    pub(crate) fn binding(&self, self_obj: &Ident, ptr: &Ident) -> TokenStream2 {
        let Receiver::Layers(layers) = self else {
            return TokenStream2::new();
        };
        // The layer applied directly to `self_obj` in the argument is the
        // second innermost; `&mut self_obj` needs a mutable binding.
        let rebinds_mutably = layers.len() >= 2 && layers[layers.len() - 2] == Layer::Mut;
        let binding = if rebinds_mutably {
            quote! { mut #self_obj }
        } else {
            quote! { #self_obj }
        };
        if self.is_mutable() {
            quote! { let #binding = unsafe { &mut *#ptr }; }
        } else {
            quote! { let #binding = unsafe { &*#ptr }; }
        }
    }

    /// The first argument of the path call, `None` for an associated
    /// function: `self_obj` is the innermost reference, each further layer is
    /// taken again (`self: &&Self` passes `&self_obj`), and a receiver taken
    /// by value is the value behind it, `*self_obj`, exactly what method-call
    /// syntax would have auto-dereferenced.
    pub(crate) fn argument(&self, self_obj: &Ident) -> Option<TokenStream2> {
        let Receiver::Layers(layers) = self else {
            return None;
        };
        let Some((_, outer)) = layers.split_last() else {
            return Some(quote! { *#self_obj });
        };
        let borrows = outer.iter().map(|layer| match layer {
            Layer::Mut => quote! { &mut },
            Layer::Shared => quote! { & },
        });
        Some(quote! { #(#borrows)* #self_obj })
    }
}

/// Whether two types are spelled with the same tokens. The header's type and
/// a receiver naming it are compared as written: resolving either would need
/// the crate's name resolution.
fn same_spelling(a: &Type, b: &Type) -> bool {
    quote!(#a).to_string() == quote!(#b).to_string()
}
