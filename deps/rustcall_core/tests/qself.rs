//! Qualified paths (`<T as Trait>::Item`) are substituted by `specialize`
//! (follow-up of #264).

use rustcall_core::specialize::specialize;

#[test]
fn substitutes_inside_qualified_paths() {
    let src = r#"
pub trait Unit { type Out; fn unit(&self) -> Self::Out; }
impl Unit for i32 { type Out = i64; fn unit(&self) -> i64 { *self as i64 } }
pub fn lift<T: Unit>(x: T) -> <T as Unit>::Out { <T as Unit>::unit(&x) }
"#;
    let sp = specialize(
        src,
        "lift",
        &[("T".to_string(), "i32".to_string())],
        "lift_i32",
    )
    .unwrap();
    let f = &sp.manifest.functions[0];
    assert_eq!(f.name, "lift_i32");
    assert_eq!(f.args[0].rust_type, "i32");
    assert_eq!(f.return_type, "<i32 as Unit>::Out");
    // The generic original stays in the source; the specialization must be
    // fully concrete.
    let specialized = sp
        .source
        .split("fn lift_i32")
        .nth(1)
        .expect("specialized fn present");
    assert!(
        specialized.contains("(x: i32) -> <i32 as Unit>::Out"),
        "{}",
        sp.source
    );
    assert!(specialized.contains("<i32 as Unit>::unit(&x)"));
    assert!(!specialized.contains("<T as Unit>"));
}

#[test]
fn substitutes_associated_types_in_bounds_and_where_clauses() {
    let src = r#"
pub trait Store { type Key; }
pub fn first<S: Store>(s: &S, k: <S as Store>::Key) -> i32 where <S as Store>::Key: Copy { 0 }
"#;
    let sp = specialize(
        src,
        "first",
        &[("S".to_string(), "MyStore".to_string())],
        "first_my",
    )
    .unwrap();
    let specialized = sp
        .source
        .split("fn first_my")
        .nth(1)
        .expect("specialized fn present");
    assert!(
        specialized.contains("k: <MyStore as Store>::Key"),
        "{}",
        sp.source
    );
    assert!(specialized.contains("<MyStore as Store>::Key: Copy"));
    assert!(!specialized.contains("<S as Store>"));
}
