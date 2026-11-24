# Rust ASTs with syn

RustCall.jl relies on [syn](https://docs.rs/syn/latest/syn/), a Rust crate for
parsing Rust syntax into an **abstract syntax tree (AST)**. Together with
[quote](https://docs.rs/quote/latest/quote/) and
[proc-macro2](https://docs.rs/proc-macro2/latest/proc_macro2/), it provides the
building blocks for procedural macros, source analysis and code generation.

This page introduces the tools with small standalone Rust programs, then
connects them to RustCall's FFI pipeline. See [How RustCall Calls Rust](internals.md)
for the Julia-side architecture.

## From source to AST

A parser turns source text into structured data. For example, a Rust
function with a `#[julia]` attribute is a `syn::ItemFn`, with fields for its
attributes, visibility, signature and body:

```text
ItemFn
├── attrs: [#[julia]]
├── vis: pub
├── sig: Signature
│   ├── ident: add
│   ├── inputs
│   │   ├── FnArg::Typed: a: i32
│   │   └── FnArg::Typed: b: i32
│   ├── generics: (none)
│   └── output: ReturnType::Type → i32
└── block
    └── a + b
```

The diagram is a simplified tree, not the exact Debug representation.
Unlike regular expressions over text, this representation distinguishes
a function name from an argument pattern, a type, a lifetime or an attribute.
It also handles nested syntax according to Rust's grammar.

Create a small Cargo project:

```bash
cargo new syn-demo
cd syn-demo
```

Replace the empty `[dependencies]` section in its `Cargo.toml` with:

```toml
[dependencies]
syn = { version = "2", features = ["full", "extra-traits", "visit", "visit-mut"] }
quote = "1"
proc-macro2 = "1"
prettyplease = "0.2"
```

Save the following as `src/main.rs`:

```rust
use syn::ItemFn;

fn main() {
    let source = r#"
        #[julia]
        pub fn add(a: i32, b: i32) -> i32 {
            a + b
        }
    "#;

    let ast: ItemFn = syn::parse_str(source).unwrap();
    println!("{:#?}", ast);
}
```

Run `cargo run` to inspect the full AST. The `full` feature enables the
complete file/item syntax used here, and `extra-traits` enables the Debug
implementation. Parsing the attribute does not require the RustCall
procedural macro to be installed: the attribute is syntax in this string.

## The principal AST types

| Type | Syntax represented |
|---|---|
| `syn::File` | A source file |
| `syn::Item` | A top-level or module item (enum) |
| `syn::ItemFn` | Function definition |
| `syn::ItemStruct`, `ItemEnum` | Struct and enum definitions |
| `syn::ItemImpl`, `ItemTrait` | Impl block and trait definition |
| `syn::ItemMod` | Module declaration or inline module |
| `syn::Signature` | Function signature |
| `syn::FnArg`, `ReturnType` | Arguments and return syntax |
| `syn::Expr`, `Type`, `Pat` | Expressions, types and patterns |
| `syn::Attribute`, `Generics` | Attributes and generic parameters |

`ItemFn` has four public fields: `attrs: Vec<Attribute>`,
`vis: Visibility`, `sig: Signature` and `block: Box<Block>`.
`Signature` contains the identifier, generics, input arguments, return type,
ABI, and modifiers such as `async`, `const` and `unsafe`. Its argument
list is a `Punctuated<FnArg, Token![,]>`: punctuation is represented too.

## Extracting signatures

Replace `src/main.rs` with the next example (each program on this page is
standalone). It walks the function signature without inspecting the body:

```rust
use quote::ToTokens;
use syn::{FnArg, ItemFn, ReturnType};

fn main() {
    let f: ItemFn = syn::parse_str(
        "fn add(a: i32, b: i32) -> i32 { a + b }"
    ).unwrap();

    println!("Function: {}", f.sig.ident);

    for arg in &f.sig.inputs {
        match arg {
            FnArg::Typed(arg) => {
                println!("Argument: {} : {}",
                    arg.pat.to_token_stream(),
                    arg.ty.to_token_stream());
            }
            FnArg::Receiver(_) => println!("Receiver"),
        }
    }

    match &f.sig.output {
        ReturnType::Default => println!("Return: ()"),
        ReturnType::Type(_, ty) =>
            println!("Return: {}", ty.to_token_stream()),
    }
}
```

Expected output:

```text
Function: add
Argument: a : i32
Argument: b : i32
Return: i32
```

`ToTokens` prints the syntactic representation. For a real FFI generator,
do not assume a printed type name is its resolved semantic type; match
the AST structure and apply an explicit ABI contract instead.

## Finding annotated items

To inspect a source file rather than a single function, use `syn::parse_file`.
This example selects root-level functions carrying the bare `#[julia]`
attribute:

```rust
use syn::Item;

fn main() {
    let source = r#"
        #[julia]
        fn add(a: i32, b: i32) -> i32 { a + b }

        fn internal_function() {}

        #[julia]
        fn square(x: f64) -> f64 { x * x }
    "#;

    let file = syn::parse_file(source).unwrap();
    for item in &file.items {
        if let Item::Fn(f) = item {
            if f.attrs.iter().any(|a| a.path().is_ident("julia")) {
                println!("{}", f.sig.ident);
            }
        }
    }
}
```

Expected output:

```text
add
square
```

This deliberately small example does not follow external `mod foo;` files,
resolve qualified/aliased attribute paths or evaluate `#[cfg]`.
RustCall has separate module-tree traversal and configuration logic for those
parts of crate analysis.

## The roles of syn, quote and proc-macro2

| Crate | Role |
|---|---|
| `proc-macro2` | Token streams, identifiers and spans usable outside a procedural macro |
| `syn` | Parse tokens or text into AST nodes; traverse and transform those nodes |
| `quote` | Construct token streams with interpolation (`#value`) |
| `prettyplease` | Format a `syn::File` into readable Rust source |

```text
Rust source string                 Compiler-provided tokens
        │                                     │
        ▼                                     │
proc_macro2::TokenStream ◄─────────────────────┘
        │
        │ syn: parse_str / parse2 (or parse_file for a file)
        ▼
Typed Rust AST
        │
        ├── inspect → metadata / TOML manifest
        │
        └── transform / quote! → TokenStream
                                     │
                                     ├── procedural macro output
                                     └── syn::parse2::<syn::File>
                                              → prettyplease::unparse
                                              → Rust source text
```

`syn::parse_str::<T>` parses a string as a particular syntax type;
`syn::parse2::<T>` takes a `proc_macro2::TokenStream`.
`syn::parse::<T>` accepts the compiler's `proc_macro::TokenStream` in
a procedural macro. Spans associate tokens with source locations and help
produce diagnostics; they are not a semantic analysis of the source.

`proc-macro2` lets an ordinary executable and a procedural macro share
the same token-oriented implementation. This is especially useful to RustCall:
the extractor is a CLI, while the crate attribute runs inside the compiler.

## Transforming an AST and generating code

Because AST nodes are Rust values, we can change a function's identifier,
convert the modified node into tokens, and format the result:

```rust
use quote::{format_ident, quote};
use syn::ItemFn;

fn main() {
    let mut f: ItemFn = syn::parse_str(
        "fn add(a: i32, b: i32) -> i32 { a + b }"
    ).unwrap();
    f.sig.ident = format_ident!("renamed_add");

    let tokens = quote! { #f };
    let file: syn::File = syn::parse2(tokens).unwrap();
    println!("{}", prettyplease::unparse(&file));
}
```

Expected output:

```rust
fn renamed_add(a: i32, b: i32) -> i32 {
    a + b
}
```

The `#f` in `quote!` interpolates the tokens of the AST node; it is
conceptually similar to interpolating an expression in Julia's `quote`.
`syn::parse_quote!` is a convenient inverse for constructing AST nodes from
quoted tokens.

### A minimal FFI wrapper generator

A more relevant example preserves the original Rust function and adds
a separate C-ABI export. For simplicity, the example is restricted to
the exact two-`i32` signature shown here:

```rust
use quote::{format_ident, quote};
use syn::ItemFn;

fn main() {
    let f: ItemFn = syn::parse_str(
        "fn add(a: i32, b: i32) -> i32 { a + b }"
    ).unwrap();

    let name = &f.sig.ident;
    let wrapper = format_ident!("rustcall_{}", name);

    let generated = quote! {
        #f

        #[unsafe(no_mangle)]
        pub extern "C" fn #wrapper(a: i32, b: i32) -> i32 {
            #name(a, b)
        }
    };

    let file: syn::File = syn::parse2(generated).unwrap();
    println!("{}", prettyplease::unparse(&file));
}
```

Expected generated source (formatting may vary):

```rust
fn add(a: i32, b: i32) -> i32 {
    a + b
}
#[unsafe(no_mangle)]
pub extern "C" fn rustcall_add(a: i32, b: i32) -> i32 {
    add(a, b)
}
```

The unsafe export attribute uses modern Rust syntax (Rust 1.82+).
The program only prints source; it does not compile or load the wrapper.
This is a teaching example, not RustCall's production wrapper: it has no
panic boundary, does not validate arbitrary signatures, and does not manage
borrows, ownership or multi-slot return values. RustCall emits those
details using its shared FFI contract and code generation.

## Traversal and transformation APIs

| Cargo feature | Purpose |
|---|---|
| `full` | File and item ASTs |
| `parsing` | Parsing tokens or text |
| `printing` | Turning AST nodes into tokens |
| `extra-traits` | Additional Debug, equality and hashing implementations |
| `clone-impls` | Clone implementations |
| `visit` | Recursive traversal through shared references |
| `visit-mut` | Recursive in-place modification |
| `fold` | Owned AST transformation |

Some features are enabled by default; the first example explicitly enables
the additional features it needs. With `visit`, implement only the node
types of interest and call the default traversal to continue into children:

```rust
use syn::{visit::Visit, ItemFn};

#[derive(Default)]
struct FunctionCollector {
    names: Vec<String>,
}

impl<'ast> Visit<'ast> for FunctionCollector {
    fn visit_item_fn(&mut self, node: &'ast ItemFn) {
        self.names.push(node.sig.ident.to_string());
        // Delegate to the default visitor to recurse into children.
        syn::visit::visit_item_fn(self, node);
    }
}

fn main() {
    let file = syn::parse_file(
        "fn top() {} mod nested { fn inner() {} }"
    ).unwrap();
    let mut collector = FunctionCollector::default();
    collector.visit_file(&file);

    assert_eq!(collector.names, vec!["top", "inner"]);
}
```

The example visits an inline module. Loading a separate module file or
expanding a macro requires additional work beyond the visitor.

## How RustCall uses syn

The shared Rust core's
[Cargo.toml](https://github.com/AtelierArith/RustCall.jl/blob/main/deps/rustcall_julia_core/Cargo.toml)
declares these dependencies (the selected entries are shown):

```toml
syn = { version = "2.0", features = [
    "full", "parsing", "printing", "extra-traits",
    "visit", "visit-mut", "clone-impls"
] }
proc-macro2 = { version = "1.0", features = ["span-locations"] }
quote = "1.0"
prettyplease = "0.2"
```

It also uses Serde and TOML for the manifest and other support crates.
Both inline Rust and the external-crate attribute use the shared core,
so the Rust-side wrapper rules and signature descriptions come from the
same implementation.

```text
rust"""..."""                   #[julia] in a Cargo crate
      │                                  │
      ▼                                  ▼
rustcall-extract (CLI)           rustcall_julia_macros_impl
      │                          (procedural macro)
      └──────────────┬───────────────────┘
                     ▼
           rustcall_julia_core
           syn-based AST / shared codegen
              ├── extract.rs
              ├── expand.rs
              ├── codegen.rs
              └── specialize.rs
                     │
      ┌──────────────┴──────────────┐
      ▼                             ▼
FFI manifest (extractor)      C-ABI wrapper code
      │                             │
Julia wrapper generation         rustc / Cargo
      │                             │
      └───────── ccall ─────────────┘
```

The main source files under `deps/` are:

| File | Responsibility |
|---|---|
| [rustcall_julia_core/src/extract.rs](https://github.com/AtelierArith/RustCall.jl/blob/main/deps/rustcall_julia_core/src/extract.rs) | Extract FFI metadata from Rust syntax and crate module trees |
| [rustcall_julia_core/src/expand.rs](https://github.com/AtelierArith/RustCall.jl/blob/main/deps/rustcall_julia_core/src/expand.rs) | Expand inline `#[julia]` items |
| [rustcall_julia_core/src/codegen.rs](https://github.com/AtelierArith/RustCall.jl/blob/main/deps/rustcall_julia_core/src/codegen.rs) | Generate C-ABI wrappers and associated helpers |
| [rustcall_julia_core/src/specialize.rs](https://github.com/AtelierArith/RustCall.jl/blob/main/deps/rustcall_julia_core/src/specialize.rs) | AST-level specialization of supported inline generic items |
| [rustcall_julia_macros_impl/src/lib.rs](https://github.com/AtelierArith/RustCall.jl/blob/main/deps/rustcall_julia_macros_impl/src/lib.rs) | Procedural macro entry point delegating to the shared core |

The extractor parses source files using `syn::parse_file(source)?`.
The procedural macro instead receives compiler tokens and uses, for example,
`syn::parse::<ItemFn>(item.clone())`. For an ordinary external crate,
the extractor separately scans its source to obtain the manifest, while the
procedural macro generates the actual wrapper during compilation.

Julia consumes the TOML manifest rather than implementing another Rust
parser. This separation is a deliberate project invariant: Rust syntax is
parsed only on the Rust side, and the source lint checks against
regex-based Rust parsing in Julia.

## Comparison with Julia metaprogramming

| Julia | Rust ecosystem (approximate counterpart) |
|---|---|
| `Meta.parse` | `syn::parse_str` |
| `Expr` | Typed AST nodes such as `syn::Expr`, `syn::Item` |
| `Symbol` as an identifier | `syn::Ident` / `proc_macro2::Ident` |
| `quote ... end` | `quote! { ... }` (tokens), or `syn::parse_quote!` (AST) |
| Dollar interpolation in quoted expressions | `#value` interpolation in `quote!` |
| MacroTools.jl traversal | `syn::visit`, `visit_mut`, `fold` and Rust pattern matching |
| Julia macro | Rust procedural macro |

The analogy is not exact: Julia's ordinary surface syntax uses a generic
`Expr` representation, whereas syn defines a typed AST for Rust's grammar.
Rust procedural macros exchange tokens with the compiler, not syn ASTs
directly.

## What syn cannot tell you

syn is a **syntax parser, not the Rust compiler**.

| Capability | syn alone |
|---|---|
| Parse Rust syntax and inspect annotations | Yes |
| Construct and transform ASTs | Yes |
| Read the written type, lifetime and generic syntax | Yes |
| General name resolution and type inference | No |
| Trait solving and borrow checking | No |
| Expand arbitrary macros or evaluate build configuration | No |
| Determine general type layouts and ABI compatibility | No |
| Compile machine code | No |

For instance:

```rust
type MyFloat = f64;

fn compute(x: MyFloat) -> MyFloat {
    x * x
}
```

syn can report `MyFloat` as a type path and recognize the alias declaration.
It does not generally resolve aliases, imports, associated types or the
actual layout of a type across a crate graph. The caller may implement
limited resolution or configuration analysis, but rustc remains the
authority on compilation. Parsing a function also does not make it safe to
call through an arbitrary C ABI.

That distinction explains why RustCall has a supported FFI type contract
rather than promising to bind every possible Rust type. See
[The FFI Type Contract](type_contract.md) and [External Crate Bindings](crate_bindings.md).

## Further reading

The same techniques can be used for FFI generators, syntax-based static
analysis, refactoring, documentation extraction and domain-specific
languages. For semantic analysis, use compiler-aware tools instead.

- [syn API documentation](https://docs.rs/syn/latest/syn/)
- [syn repository](https://github.com/dtolnay/syn)
- [quote API documentation](https://docs.rs/quote/latest/quote/)
- [proc-macro2 API documentation](https://docs.rs/proc-macro2/latest/proc_macro2/)
- [prettyplease API documentation](https://docs.rs/prettyplease/latest/prettyplease/)
- [Rust Reference: procedural macros](https://doc.rust-lang.org/reference/procedural-macros.html)
