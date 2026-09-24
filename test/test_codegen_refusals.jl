using Test
using RustCall

# Every refusal the Rust codegen makes reaches the boundary report through the
# manifest (#503). `rustcall_julia_core::refusal` decides each refusal once;
# the expansion emits its `compile_error!` and the manifest keeps the item with
# the refusal as its `skip_reason`. The Rust corpus
# (`deps/rustcall_julia_core/tests/refusals.rs`) asserts both halves for every
# kind in every position; this file asserts the Julia half: every such item is
# listed by `inline_boundary_report` / `boundary_report` at its entry point,
# gets no binding, and takes no name.

_cr_positions(report) = Set((u.item, u.position) for u in report.unsupported)

# The kinds the Rust side declares (`skip_reason::CODEGEN_REFUSALS`), read from
# its source by this test only — `src/` never reads Rust syntax.
function _cr_rust_codegen_refusals()
    manifest_rs = joinpath(pkgdir(RustCall), "deps", "rustcall_julia_core", "src", "manifest.rs")
    text = read(manifest_rs, String)
    values = Dict(m[1] => m[2] for m in eachmatch(r"pub const ([A-Z_0-9]+): &str = \"([a-z_0-9]+)\";", text))
    block = match(r"pub const CODEGEN_REFUSALS: &\[&str\] = &\[([^\]]*)\];", text)
    block === nothing && error("CODEGEN_REFUSALS not found in $(manifest_rs)")
    names = [strip(n) for n in split(block[1], ',') if !isempty(strip(n))]
    return Set(values[n] for n in names)
end

# (label, source, item, skip_reason kind) — the inline positions of the Rust
# corpus: a free function, a method beside its struct, a method of a generic
# struct, and a method in a block in another module.
const CR_INLINE_CASES = [
    ("unsafe fn", "#[julia] pub unsafe fn danger(p: *const i32) -> i32 { *p }",
     "danger", "unsafe_fn"),
    ("generic unsafe fn", "#[julia] pub unsafe fn g503<T: Copy>(x: T) -> T { x }",
     "g503", "unsafe_fn"),
    ("unsafe method", """
        #[julia] pub struct S { pub n: i32 }
        impl S { pub unsafe fn read(&self, p: *const i32) -> i32 { *p + self.n } }
        """, "S::read", "unsafe_fn"),
    ("unsafe method of a generic struct", """
        #[julia] pub struct W<T> { pub v: T }
        impl<T: Copy> W<T> { pub unsafe fn peek(&self, p: *const T) -> T { *p } }
        """, "W::peek", "unsafe_fn"),
    ("unsafe method in a foreign block", """
        #[julia] pub struct G { pub v: f64 }
        pub mod ops { impl super::G { pub unsafe fn peek(&self, p: *const f64) -> f64 { *p } } }
        """, "G::peek", "unsafe_fn"),
    ("const-generic fn", "#[julia] pub fn sized<const N: usize>() -> usize { N }",
     "sized", "generic_signature"),
    ("generic method of a concrete struct", """
        #[julia] pub struct S { pub n: i32 }
        impl S { pub fn echo<T: Copy>(&self, x: T) -> T { x } }
        """, "S::echo", "generic_signature"),
    ("method-level generic of a generic struct", """
        #[julia] pub struct W<T> { pub v: T }
        impl<T: Copy> W<T> { pub fn pair<U: Copy>(&self, u: U) -> U { u } }
        """, "W::pair", "generic_signature"),
    ("generic method in a foreign block", """
        #[julia] pub struct G { pub v: f64 }
        pub mod ops { impl super::G { pub fn scaled<T: Into<f64>>(&self, k: T) -> f64 { self.v * k.into() } } }
        """, "G::scaled", "generic_signature"),
    ("impl Trait fn", "#[julia] pub fn shown(x: impl Copy) -> i32 { let _ = x; 1 }",
     "shown", "impl_trait"),
    ("impl Trait method", """
        #[julia] pub struct S { pub n: i32 }
        impl S { pub fn shown(&self, x: impl Copy) -> i32 { let _ = x; self.n } }
        """, "S::shown", "impl_trait"),
    ("impl Trait method of a generic struct", """
        #[julia] pub struct W<T> { pub v: T }
        impl<T: Copy> W<T> { pub fn shown(&self, x: impl Copy) -> T { let _ = x; self.v } }
        """, "W::shown", "impl_trait"),
    ("impl Trait method in a foreign block", """
        #[julia] pub struct G { pub v: f64 }
        pub mod ops { impl super::G { pub fn shown(&self, x: impl Copy) -> f64 { let _ = x; self.v } } }
        """, "G::shown", "impl_trait"),
    ("non-FFI Result payload", "#[julia] pub fn many(a: i32) -> Result<Vec<i32>, i32> { Ok(vec![a]) }",
     "many", "non_ffi_payload"),
    ("Self inside a macro", raw"""
        macro_rules! same { ($t:ty) => { $t }; }
        #[julia] pub struct S { pub n: i32 }
        impl S { pub fn other(&self, o: &same!(Self)) -> i32 { o.n + self.n } }
        """, "S::other", "unspellable_self"),
    ("Self inside a macro in a foreign block", raw"""
        macro_rules! same { ($t:ty) => { $t }; }
        #[julia] pub struct G { pub v: f64 }
        pub mod ops { impl super::G { pub fn other(&self, o: &same!(Self)) -> f64 { o.v } } }
        """, "G::other", "unspellable_self"),
    ("'static lowered str", "#[julia] pub fn keep(s: &'static str) -> usize { s.len() }",
     "keep", "lowered_str_lifetime"),
    ("returned lowered str lifetime", """
        #[julia] pub struct S { pub n: i32 }
        impl S { pub fn first<'a>(&self, s: &'a str) -> &'a u8 { &s.as_bytes()[0] } }
        """, "S::first", "lowered_str_lifetime"),
    ("lowered str lifetime in a foreign block", """
        #[julia] pub struct G { pub v: f64 }
        pub mod ops { impl super::G { pub fn keep(&self, s: &'static str) -> usize { s.len() } } }
        """, "G::keep", "lowered_str_lifetime"),
    ("elided return borrowing a lowered str", "#[julia] pub fn first(s: &str) -> &u8 { &s.as_bytes()[0] }",
     "first", "lowered_str_borrow"),
    ("static method borrowing a lowered str", """
        #[julia] pub struct S { pub n: i32 }
        impl S { pub fn first(s: &str) -> &u8 { &s.as_bytes()[0] } }
        """, "S::first", "lowered_str_borrow"),
    ("foreign-block method borrowing a lowered str", """
        #[julia] pub struct G { pub v: f64 }
        pub mod ops { impl super::G { pub fn first(s: &str) -> &u8 { &s.as_bytes()[0] } } }
        """, "G::first", "lowered_str_borrow"),
]

@testset "Julia's refusal table is the Rust codegen's (#503)" begin
    @test Set(keys(RustCall.RUST_CODEGEN_REFUSALS)) == _cr_rust_codegen_refusals()
    for kind in keys(RustCall.RUST_CODEGEN_REFUSALS)
        @test RustCall._rust_refuses(kind)
        @test RustCall._rust_refuses("$(kind):detail")
        # Every kind is explained, not passed through as its bare name.
        @test RustCall.pyo3_skip_explanation(kind) != kind
    end
    # Reasons the codegen does not refuse for are not refusals.
    for reason in ("", "not_public", "generic", "unsupported_return:Vec<u8>", "owner_skipped:x")
        @test !RustCall._rust_refuses(reason)
    end
end

@testset "inline_boundary_report lists every codegen refusal (#503)" begin
    seen = Set{String}()
    for (label, source, item, kind) in CR_INLINE_CASES
        @testset "$label" begin
            manifest = RustCall.extract_manifest(source; mode = "inline")
            # The manifest carries the item, with the refusal as its reason.
            reasons = String[]
            for f in get(manifest, "functions", [])
                RustCall.qualified_name(String.(get(f, "module_path", String[])), f["name"]) == item &&
                    push!(reasons, f["skip_reason"])
            end
            for s in get(manifest, "structs", []), m in get(s, "methods", [])
                "$(s["name"])::$(m["name"])" == item && push!(reasons, m["skip_reason"])
            end
            @test length(reasons) == 1
            @test RustCall.partition_skip_reason(only(reasons))[1] == kind

            report = RustCall.inline_boundary_report(source; io = devnull)
            @test (item, "entry point") in _cr_positions(report)
            finding = only(u for u in report.unsupported if u.item == item)
            @test startswith(finding.rust_type, RustCall.RUST_CODEGEN_REFUSALS[kind])
            @test occursin(RustCall.PYO3_SKIP_REASONS[kind], finding.reason)
            # No wrapper exists, so none of its positions is examined: the
            # item's only finding is its entry point.
            @test count(u -> u.item == item, report.unsupported) == 1
            text = sprint(io -> RustCall.inline_boundary_report(source; io))
            @test occursin("$(item), entry point:", text)
            push!(seen, kind)
        end
    end
    # Every kind the inline flavour can produce is covered; a trait impl, the
    # one place `self_trait_path` arises, is wrapped only by the proc macro.
    @test seen == setdiff(Set(keys(RustCall.RUST_CODEGEN_REFUSALS)), Set(["self_trait_path"]))
end

@testset "a refused item gets no binding and takes no name (#503)" begin
    source = raw"""
        #[julia] pub fn shown(x: impl Copy) -> i32 { let _ = x; 1 }
        #[julia] pub fn first(s: &str) -> &u8 { &s.as_bytes()[0] }
        #[julia] pub struct S { pub n: i32 }
        impl S {
            pub fn new() -> Self { S { n: 1 } }
            pub fn echo<T: Copy>(&self, x: T) -> T { x }
            pub fn first(s: &str) -> &u8 { &s.as_bytes()[0] }
        }
        """
    manifest = RustCall.extract_manifest(source; mode = "inline")
    signatures = RustCall.manifest_function_signatures(manifest)
    structs = RustCall.manifest_struct_infos(manifest)
    @test !any(RustCall._binds_julia_wrapper, signatures)
    # `S::first` is static but refused: it collides with nothing, so the free
    # function `first` (refused too) and it leave no colliding name behind.
    @test isempty(RustCall._static_method_collisions(signatures, structs))
    defs = string(RustCall.emit_julia_definitions(only(structs)))
    @test !occursin("echo", defs)
    @test !occursin(":first", defs)
end

@testset "boundary_report lists the crate flavour's refusals (#503)" begin
    mktempdir() do root
        crate = joinpath(root, "br_refusals")
        mkpath(joinpath(crate, "src"))
        write(joinpath(crate, "Cargo.toml"), """
            [package]
            name = "br_refusals"
            version = "0.1.0"
            edition = "2021"

            [lib]
            crate-type = ["cdylib"]

            [dependencies]
            rustcall_julia_macros = { path = $(repr(RustCall.rustcall_runtime_crate_path())) }
            """)
        write(joinpath(crate, "src", "lib.rs"), raw"""
            use rustcall_julia_macros::julia;

            macro_rules! same { ($t:ty) => { $t }; }

            pub mod tr {
                pub trait Limits { const N: usize; fn limit(&self, a: &[u8; 2]) -> i32; }
            }

            #[julia]
            pub fn id<T: Copy>(x: T) -> T { x }

            #[julia]
            pub fn maybe(a: i32) -> Option<Vec<i32>> { Some(vec![a]) }

            #[julia]
            pub fn keep(s: &'static str) -> usize { s.len() }

            #[julia]
            pub struct W<T> { pub v: T }

            #[julia]
            impl<T: Copy> W<T> {
                #[julia]
                pub fn get(&self) -> T { self.v }
            }

            #[julia]
            pub struct Buf { pub n: i32 }

            #[julia]
            impl Buf {
                #[julia]
                pub fn ok(&self) -> i32 { self.n }
                #[julia]
                pub fn limit(&self) -> i32 { self.n }
                #[julia]
                pub fn other(&self, o: &same!(Self)) -> i32 { o.n }
                #[julia]
                pub fn first(s: &str) -> &u8 { &s.as_bytes()[0] }
                #[julia]
                pub fn shown(&self, x: impl Copy) -> i32 { let _ = x; self.n }
            }

            #[julia]
            impl tr::Limits for Buf {
                const N: usize = 2;
                #[julia]
                fn limit(&self, a: &[u8; Self::N]) -> i32 { a.len() as i32 + self.n }
            }

            #[julia]
            pub mod a {
                #[julia]
                pub unsafe fn danger(p: *const i32) -> i32 { *p }
            }
            """)
        report = RustCall.boundary_report(crate; io = devnull)
        expected = Dict(
            "id" => "generic_signature",
            "maybe" => "non_ffi_payload",
            "keep" => "lowered_str_lifetime",
            "W" => "generic_signature",
            "W::get" => "generic_signature",
            "Buf::other" => "unspellable_self",
            "Buf::first" => "lowered_str_borrow",
            "Buf::shown" => "impl_trait",
            "<Buf as tr::Limits>::limit" => "self_trait_path",
            "a::danger" => "unsafe_fn",
        )
        # A refused struct is reported once, at its own entry point; its
        # methods are not examined, since it gets no Julia type.
        @test _cr_positions(report) ==
              Set((item, "entry point") for item in keys(expected) if item != "W::get")
        for u in report.unsupported
            kind = expected[u.item]
            @test startswith(u.rust_type, RustCall.RUST_CODEGEN_REFUSALS[kind])
            @test occursin(RustCall.PYO3_SKIP_REASONS[kind], u.reason)
        end
        # The manifest carries every one of them, `W::get` included.
        _, _, manifest = RustCall._crate_manifest(crate; cfg_text = RustCall._rustc_cfg_text(),
                                                  allow_cargo = false)
        structs = RustCall.manifest_struct_infos(manifest)
        w = only(s for s in structs if s.name == "W")
        @test RustCall.partition_skip_reason(w.skip_reason)[1] == "generic_signature"
        @test RustCall.partition_skip_reason(only(w.methods).skip_reason)[1] == "generic_signature"
        buf = only(s for s in structs if s.name == "Buf")
        @test Set(m.name for m in buf.methods if isempty(m.skip_reason)) == Set(["ok", "limit"])
        # An inherent `limit` and the refused `tr::Limits::limit` are two
        # entries, told apart by their trait (#503 review): the refused one is
        # reported, the inherent one is examined like any method.
        limits = [(m.trait_path, m.skip_reason) for m in buf.methods if m.name == "limit"]
        @test Set(limits) == Set([("", ""), ("tr::Limits", "self_trait_path:tr::Limits")])
        collect_report = RustCall._collect_boundary() do
            RustCall._crate_wrapper_exprs(RustCall._module_tree(
                RustCall.manifest_function_signatures(manifest), structs))
        end
        @test any(p -> p.item == "Buf::limit" && p.position == "return" && p.reason === nothing,
                  collect_report.positions)
        # The refused struct binds no name, and the module lays out.
        signatures = RustCall.manifest_function_signatures(manifest)
        tree = RustCall._module_tree(signatures, structs)
        @test RustCall._check_module_names(tree) === nothing
        exprs = string(RustCall._crate_wrapper_exprs(tree))
        @test !occursin("mutable struct W", exprs)
        @test occursin("mutable struct Buf", exprs)
    end
end

# `#[julia]` on a kind it does not expand — a `macro_rules!`, an enum, a
# `use`, ... — has no manifest entry to carry the refusal, so the report fails
# with the refusal's message instead of passing silently (#503 review).
@testset "an unsupported #[julia] item kind fails the report (#503 review)" begin
    for source in ("#[julia] macro_rules! foo { () => {}; }",
                   "#[julia] pub enum E { A }",
                   "#[julia] pub use std::mem;")
        message = try
            RustCall.inline_boundary_report(source; io = devnull)
            ""
        catch err
            sprint(showerror, err)
        end
        @test occursin("#[julia] can only be applied to functions, structs, impl blocks, " *
                       "or inline modules", message)
    end
end
