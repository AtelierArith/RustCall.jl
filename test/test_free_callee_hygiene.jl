using Test, RustCall

const FREE_CALLEE579_SOURCE = raw"""
#[julia] pub fn identity579(identity579: i32) -> i32 { identity579 + 1 }
#[julia] pub fn callback(callback: extern "C" fn() -> i32) -> i32 { callback() }
#[julia] pub fn text579(text579: &str) -> usize { text579.len() }
#[julia] pub fn owned579(owned579: String) -> usize { owned579.len() }
#[julia] pub fn slices579(slices579: &[f64]) -> f64 { slices579.iter().sum() }
#[julia] pub fn mutable579(mutable579: &mut [f64]) { for value in mutable579 { *value *= 2.0; } }
#[julia] pub fn text_ptr(text: &str) -> usize { text.len() }
#[julia] pub fn text_bytes(text: &str) -> usize { text.len() }
#[julia] pub fn text_cow(text: &str) -> usize { text.len() }
#[julia] pub fn data_len(data: &[f64]) -> usize { data.len() }
#[julia] pub fn _rustcall_boundary(value: i32) -> i32 { value + 20 }
#[julia] pub fn guard_argument579(_rustcall_boundary: i32) -> i32 { _rustcall_boundary + 30 }
#[julia] pub fn K579(K579: i32) -> i32 { K579 + 7 }
#[julia] pub fn K579_ptr(K579: &str) -> usize { K579.len() }
#[julia] pub mod nested579 {
    pub fn helper579(value: i32) -> i32 { value * 3 }
    #[julia] pub fn nested_value579(nested_value579: i32) -> i32 { nested_value579 + 10 }
    #[julia] pub fn qualified579(qualified579: i32) -> i32 { self::helper579(qualified579) }
}
#[julia] pub mod r#type {
    #[julia] pub fn r#for(r#for: i32) -> i32 { r#for + 2 }
}
"""

function _free_callee579_metadata(manifest)
    functions = manifest["functions"]
    function item(name, path = String[])
        only(
            entry for entry in functions if
            entry["name"] == name && get(entry, "module_path", String[]) == path
        )
    end
    for (name, argument, symbol) in (
        ("identity579", "identity579", "rustcall_identity579"),
        ("callback", "callback", "rustcall_callback"),
        ("text579", "text579", "rustcall_text579"),
        ("owned579", "owned579", "rustcall_owned579"),
        ("slices579", "slices579", "rustcall_slices579"),
        ("mutable579", "mutable579", "rustcall_mutable579"),
        ("text_ptr", "text", "rustcall_text_ptr"),
        ("text_bytes", "text", "rustcall_text_bytes"),
        ("text_cow", "text", "rustcall_text_cow"),
        ("data_len", "data", "rustcall_data_len"),
        ("_rustcall_boundary", "value", "rustcall__rustcall_boundary"),
        ("guard_argument579", "_rustcall_boundary", "rustcall_guard_argument579"),
        ("K579", "K579", "rustcall_K579"),
        ("K579_ptr", "K579", "rustcall_K579_ptr"),
    )
        entry = item(name)
        @test entry["name"] == name
        @test only(entry["args"])["name"] == argument
        @test entry["symbol"] == symbol
    end
    nested = item("nested_value579", ["nested579"])
    @test only(nested["args"])["name"] == "nested_value579"
    @test nested["symbol"] == "rustcall_nested579__nested_0value579"
    raw = item("r#for", ["r#type"])
    @test only(raw["args"])["name"] == "r#for"
    @test raw["symbol"] == "rustcall_type__for"
end

function _free_callee579_call(mod, signatures; flat::Bool)
    by_name = Dict(
        Symbol(RustCall.qualified_name(signature.module_path, signature.name)) =>
            signature for signature in signatures if !signature.is_generic
    )
    return function (name, args...)
        signature = by_name[name]
        scope = mod
        if !flat
            for segment in signature.module_path
                scope = Base.invokelatest(
                    getfield,
                    scope,
                    Symbol(RustCall._julia_module_name(segment)),
                )
            end
        end
        function_name = Symbol(RustCall.julia_function_name(signature))
        Base.invokelatest(Base.invokelatest(getfield, scope, function_name), args...)
    end
end

function _free_callee579_checks(call)
    @test call(:identity579, Int32(41)) == 42
    @test call(:callback, () -> Int32(42)) == 42
    @test_throws ErrorException call(:callback, () -> error("callee callback failure"))
    @test isempty(RustCall._callback_frames())
    @test call(:callback, () -> (GC.gc(); Int32(7))) == 7
    @test call(:text579, "αβ") == 4
    @test call(:owned579, "αβ") == 4
    @test call(:slices579, [1.0, 2.0, 3.0]) == 6.0
    values = [1.0, 2.0]
    @test call(:mutable579, values) === nothing
    @test values == [2.0, 4.0]
    for function_name in (:text_ptr, :text_bytes, :text_cow)
        @test call(function_name, "hello") == 5
    end
    @test call(:data_len, [1.0, 2.0, 3.0]) == 3
    @test call(:_rustcall_boundary, Int32(2)) == 22
    @test call(:guard_argument579, Int32(2)) == 32
    @test call(:K579, Int32(5)) == 12
    @test call(:K579_ptr, "λ") == 2
    @test call(Symbol("nested579::nested_value579"), Int32(3)) == 13
    @test call(Symbol("nested579::qualified579"), Int32(3)) == 9
    @test call(Symbol("r#type::r#for"), Int32(40)) == 42
    @test isempty(RustCall._callback_frames())
end

@testset "free Rust callees survive wrapper bindings across public emitters (#579)" begin
    source = FREE_CALLEE579_SOURCE
    manifest = RustCall.extract_manifest(source; mode = "inline")
    _free_callee579_metadata(manifest)
    signatures = RustCall.manifest_function_signatures(manifest)
    inline = Module(gensym(:FreeCalleeInline579))
    Core.eval(inline, :(using RustCall))
    inline_lib =
        Core.eval(inline, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
    try
        @testset "inline" begin
            _free_callee579_checks(_free_callee579_call(inline, signatures; flat = true))
        end
    finally
        RustCall.unload_library(inline_lib; close = true)
    end
    mktempdir() do root
        crate = joinpath(root, "crate")
        mkpath(joinpath(crate, "src"))
        runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
        write(
            joinpath(crate, "Cargo.toml"),
            """
[package]
name = "free_callee_hygiene579"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib"]
[dependencies]
rustcall_julia_macros = { path = "$runtime" }
""",
        )
        write(
            joinpath(crate, "src", "lib.rs"),
            "use rustcall_julia_macros::julia;\n" * source,
        )
        crate_manifest =
            RustCall.extract_manifest([joinpath(crate, "src", "lib.rs")]; mode = "crate")
        _free_callee579_metadata(crate_manifest)
        proxy = @rust_crate crate
        direct = getfield(proxy, :module_ref)
        output = joinpath(root, "WrittenFreeCallee579.jl")
        RustCall.write_bindings_to_file(
            crate,
            output;
            output_module_name = "WrittenFreeCallee579",
        )
        sandbox = Module(gensym(:FreeCalleeSandbox579))
        Base.include(sandbox, output)
        persisted = Base.invokelatest(getfield, sandbox, :WrittenFreeCallee579)
        try
            for (name, mod) in (("direct", direct), ("persisted", persisted))
                @testset "$name" begin
                    _free_callee579_checks(
                        _free_callee579_call(mod, signatures; flat = false),
                    )
                end
            end
        finally
            for mod in (direct, persisted)
                lib = Base.invokelatest(getfield, mod, :_LIB_NAME)
                haskey(RustCall.RUST_LIBRARIES, lib) &&
                    RustCall.unload_library(lib; close = true)
            end
        end
    end
end

@testset "generic specialization retains the original free callee (#579)" begin
    source = raw"""
    #[julia] pub fn choose579<T: Copy>(choose579: T) -> T { choose579 }
    """
    mod = Module(gensym(:GenericFreeCallee579))
    Core.eval(mod, :(using RustCall))
    lib = Core.eval(mod, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
    try
        @test Core.eval(mod, :(@rust choose579(Int32(42))::Int32)) == 42
        @test Core.eval(mod, :(@rust choose579(2.5)::Float64)) == 2.5
        # A warm specialization must keep the same item, argument meaning and image.
        @test Core.eval(mod, :(@rust choose579(Int32(7))::Int32)) == 7
    finally
        RustCall.unload_library(lib; close = true)
    end
end
