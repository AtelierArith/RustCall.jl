//! Public item-macro counterparts of the shared codegen hygiene contract.
#![allow(clippy::not_unsafe_ptr_arg_deref)]
use rustcall_julia_macros::julia;

#[julia]
fn scalar(scalar: i32) -> i32 {
    scalar + 1
}
#[julia]
fn callback(callback: extern "C" fn() -> i32) -> i32 {
    callback() + 1
}
#[julia]
fn text_ptr(text: String) -> usize {
    text.len()
}
#[julia]
fn text_len(text: &str) -> usize {
    text.len()
}
#[julia]
fn data_ptr(data: &[i32]) -> i32 {
    data.iter().sum()
}
#[julia]
fn _rustcall_boundary(value: i32) -> i32 {
    value + 2
}
#[julia]
fn guard_argument(_rustcall_boundary: i32) -> i32 {
    _rustcall_boundary + 3
}
#[julia]
fn r#type(r#type: i32) -> i32 {
    r#type + 4
}
#[julia]
mod nested {
    #[julia]
    pub fn nested_value(nested_value: i32) -> i32 {
        nested_value + 5
    }
}

#[test]
fn item_macros_keep_original_rust_signatures_and_native_wrapper_calls() {
    extern "C" fn answer() -> i32 {
        40
    }
    assert_eq!(scalar(1), 2);
    assert_eq!(callback(answer), 41);
    assert_eq!(unsafe { rustcall_scalar(1).assume_init() }, 2);
    assert_eq!(unsafe { rustcall_callback(answer).assume_init() }, 41);
    let text = b"hello";
    assert_eq!(
        unsafe { rustcall_text_ptr(text.as_ptr(), text.len()).assume_init() },
        5
    );
    assert_eq!(
        unsafe { rustcall_text_len(text.as_ptr(), text.len()).assume_init() },
        5
    );
    let data = [4, 5];
    assert_eq!(
        unsafe { rustcall_data_ptr(data.as_ptr(), data.len()).assume_init() },
        9
    );
    assert_eq!(unsafe { rustcall__rustcall_boundary(2).assume_init() }, 4);
    assert_eq!(unsafe { rustcall_guard_argument(2).assume_init() }, 5);
    assert_eq!(unsafe { rustcall_type(2).assume_init() }, 6);
    assert_eq!(
        unsafe { nested::rustcall_nested__nested_0value(2).assume_init() },
        7
    );
}

#[test]
fn function_local_macro_items_retain_lexical_lookup() {
    // A blanket `self::callee` would not find these items in the module.
    #[julia]
    fn local(local: i32) -> i32 {
        local + 6
    }
    #[julia]
    fn local_ptr(local: String) -> usize {
        local.len()
    }
    assert_eq!(local(2), 8);
    assert_eq!(unsafe { rustcall_local(2).assume_init() }, 8);
    let text = b"hello";
    assert_eq!(
        unsafe { rustcall_local_ptr(text.as_ptr(), text.len()).assume_init() },
        5
    );
}

#[test]
fn post_call_payload_bindings_preserve_accepted_unit_constructor_names() {
    #[julia]
    pub struct Product {
        pub value: i32,
    }
    #[allow(non_camel_case_types, dead_code)]
    pub struct __rustcall_owned_value_;
    #[julia]
    #[rustcall_owned_return(Product)]
    fn __rustcall_owned_value() -> Product {
        Product { value: 3 }
    }
    let result = rustcall___rustcall_owned_value();
    assert_eq!(unsafe { (*result).value }, 3);
    unsafe {
        drop(Box::from_raw(result));
    }
}
