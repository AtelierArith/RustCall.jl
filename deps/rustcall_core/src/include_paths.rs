//! Resolve include paths using the environment of the build being scanned.
//! Never consult the extractor process's environment: its OUT_DIR belongs to
//! neither the target crate nor necessarily the selected feature/profile build.
use std::collections::BTreeMap;
use syn::{parse::Parser, punctuated::Punctuated, Expr, Lit, Token};

#[derive(Clone, Debug, Default)]
pub struct IncludeEnvironment(pub BTreeMap<String, String>);

impl IncludeEnvironment {
    pub fn resolve(&self, tokens: proc_macro2::TokenStream) -> Result<String, String> {
        let expr: Expr = syn::parse2(tokens).map_err(|e| format!("invalid include path: {e}"))?;
        self.expression(&expr)
    }

    fn expression(&self, expr: &Expr) -> Result<String, String> {
        match expr {
            Expr::Lit(value) => match &value.lit {
                Lit::Str(value) => Ok(value.value()),
                _ => Err("include path requires a string literal".into()),
            },
            Expr::Paren(value) => self.expression(&value.expr),
            Expr::Group(value) => self.expression(&value.expr),
            Expr::Macro(value) if value.mac.path.is_ident("concat") => {
                let args = Punctuated::<Expr, Token![,]>::parse_terminated
                    .parse2(value.mac.tokens.clone())
                    .map_err(|e| format!("invalid concat! include path: {e}"))?;
                let mut result = String::new();
                for arg in args {
                    result.push_str(&self.expression(&arg)?);
                }
                Ok(result)
            }
            Expr::Macro(value) if value.mac.path.is_ident("env") => {
                let args = Punctuated::<syn::LitStr, Token![,]>::parse_terminated
                    .parse2(value.mac.tokens.clone())
                    .map_err(|e| format!("invalid env! include path: {e}"))?;
                if !(1..=2).contains(&args.len()) {
                    return Err(
                        "env! include path requires a name and optional error message".into(),
                    );
                }
                let name = args.first().unwrap().value();
                self.0.get(&name).cloned().ok_or_else(|| {
                    format!("include path needs `{name}` from the target Cargo build environment")
                })
            }
            _ => Err(
                "unsupported include path expression; expected a string, concat! or env!".into(),
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use quote::quote;

    #[test]
    fn target_environment_resolves_nested_generated_path() {
        let env = IncludeEnvironment(BTreeMap::from([(
            "OUT_DIR".into(),
            "/target/a b/日本語".into(),
        )]));
        assert_eq!(
            env.resolve(quote!(concat!(env!("OUT_DIR"), concat!("/", "api.rs"),)))
                .unwrap(),
            "/target/a b/日本語/api.rs"
        );
        assert_eq!(env.resolve(quote!("plain.rs")).unwrap(), "plain.rs");
        assert_eq!(
            env.resolve(quote!(env!("OUT_DIR", "custom error")))
                .unwrap(),
            "/target/a b/日本語"
        );
    }

    #[test]
    fn missing_build_environment_is_not_replaced_by_host_environment() {
        let env = IncludeEnvironment::default();
        assert!(env
            .resolve(quote!(env!("PATH")))
            .unwrap_err()
            .contains("target Cargo build environment"));
        assert!(env
            .resolve(quote!(concat!(env!("OUT_DIR"), "/api.rs")))
            .is_err());
        assert!(env.resolve(quote!(arbitrary_macro!())).is_err());
        assert!(env.resolve(quote!(env!())).is_err());
    }
}
