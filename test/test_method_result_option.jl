# `Result` / `Option` returns on `#[julia]` struct methods (#268).
#
# A method returning `Result<T, E>` / `Option<T>` is lowered exactly like a free
# function: the wrapper returns `CResult_<Struct>_<method>` /
# `COption_<Struct>_<method>`, and a `String` / `&str` payload travels as the
# owner's owned-string buffer, released through `<owner>_free_rust_string`. The
# three Julia emitters — inline `rust"""`, in-memory `@rust_crate`, and the
# source text `write_bindings_to_file` writes — must all decode that into
# `RustResult` / `RustOption`.

using Test
using RustCall

const MRO_SAMPLE_CRATE = joinpath(dirname(@__DIR__), "examples", "sample_crate")

# ---------------------------------------------------------------------------
# Manifest: the columns that used to be empty for methods
# ---------------------------------------------------------------------------

@testset "#268: manifest reports Result/Option on methods" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        source = """
        #[julia]
        pub struct Div { n: i32 }

        impl Div {
            pub fn new(n: i32) -> Self { Div { n } }
            pub fn checked_div(&self, d: i32) -> Result<i32, String> {
                if d == 0 { Err("zero".to_string()) } else { Ok(self.n / d) }
            }
            pub fn find(&self, k: i32) -> Option<f64> {
                if k == 0 { None } else { Some(self.n as f64 / k as f64) }
            }
            pub fn describe(&self, unit: String) -> Result<String, String> {
                if unit.is_empty() { Err("empty".to_string()) } else { Ok(format!("{} {}", self.n, unit)) }
            }
            pub fn label(&self) -> Option<&'static str> { Some("div") }
        }
        """
        info = only(RustCall.manifest_struct_infos(RustCall.expand_inline(source).manifest))
        m = Dict(x.name => x for x in info.methods)

        @test m["checked_div"].return_kind === :result
        @test m["checked_div"].ok_type == "i32"
        @test m["checked_div"].err_type == "String"
        @test m["checked_div"].ok_abi == ""
        @test m["checked_div"].err_abi == "string"

        @test m["find"].return_kind === :option
        @test m["find"].inner_type == "f64"
        @test m["find"].inner_abi == ""

        @test m["describe"].return_kind === :result
        @test m["describe"].ok_abi == "string"
        @test m["describe"].err_abi == "string"

        # A `&str` payload is copied into an owned buffer, never borrowed: the
        # aggregate outlives the call's temporaries in Julia's hands.
        @test m["label"].return_kind === :option
        @test m["label"].inner_abi == "string"

        # A constructor is boxed before the `Result` lowering is consulted.
        @test m["new"].return_kind === :plain
        @test m["new"].returns_boxed_struct

        # The expanded source carries the payload aggregates and the struct's
        # owned-string buffer, which the methods now share.
        expanded = RustCall.expand_inline(source).source
        @test occursin("CResult_Div_checked_div", expanded)
        @test occursin("COption_Div_find", expanded)
        @test occursin("CResult_Div_describe", expanded)
        @test occursin("Div_RustCallOwnedString", expanded)
        @test occursin("Div_free_rust_string", expanded)
        @test info.has_owned_string_helper
    end
end

@testset "#268: generic struct methods keep the plain lowering" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        # A generic struct's methods are registered for monomorphization
        # (`inline_generic_wrappers`) and return the type as written, so their
        # manifest entry must NOT claim the `CResult_*` ABI — nothing generates
        # it for them.
        source = """
        #[julia]
        pub struct Holder<T> { value: T }

        impl<T: Copy> Holder<T> {
            pub fn new(value: T) -> Self { Holder { value } }
            pub fn checked(&self, ok: bool) -> Result<i32, i32> {
                if ok { Ok(1) } else { Err(0) }
            }
        }
        """
        info = only(RustCall.manifest_struct_infos(RustCall.expand_inline(source).manifest))
        m = Dict(x.name => x for x in info.methods)
        @test m["checked"].return_kind === :plain
        @test m["checked"].ok_type == ""
        @test !occursin("CResult_Holder_checked", RustCall.expand_inline(source).source)
    end
end

# ---------------------------------------------------------------------------
# Path 1: inline rust""" blocks
# ---------------------------------------------------------------------------

if RustCall.check_rustc_available()
    rust"""
    #[julia]
    pub struct InlineDivider {
        pub scale: i32,
    }

    impl InlineDivider {
        pub fn new(scale: i32) -> Self { InlineDivider { scale } }

        pub fn checked_div(&self, d: i32) -> Result<i32, String> {
            if d == 0 {
                Err(format!("cannot divide {} by zero", self.scale))
            } else {
                Ok(self.scale / d)
            }
        }

        pub fn ratio(&self, d: i32) -> Option<f64> {
            if d == 0 { None } else { Some(self.scale as f64 / d as f64) }
        }

        pub fn describe(&self, unit: String) -> Result<String, String> {
            if unit.is_empty() {
                Err("empty unit".to_string())
            } else {
                Ok(format!("{} {}", self.scale, unit))
            }
        }

        pub fn tag(&self, prefix: &str) -> Option<String> {
            if self.scale > 0 { Some(format!("{}{}", prefix, self.scale)) } else { None }
        }

        pub fn bump(&mut self, by: i32) -> Result<i32, String> {
            if by < 0 {
                Err("cannot bump by a negative amount".to_string())
            } else {
                self.scale += by;
                Ok(self.scale)
            }
        }

        pub fn parse_scale(text: &str) -> Result<i32, String> {
            text.trim().parse::<i32>().map_err(|_| format!("bad scale {}", text))
        }

        pub fn wide(&self, n: usize) -> Result<String, String> {
            Ok("x".repeat(n))
        }

        pub fn panicky(&self, d: i32) -> Result<i32, String> {
            if d < 0 { panic!("panicky refuses {}", d); }
            Ok(self.scale)
        }

        pub fn panicky_opt(&self, d: i32) -> Option<f64> {
            assert!(d >= 0, "panicky_opt refuses {}", d);
            Some(self.scale as f64)
        }
    }
    """
end

@testset "#268: inline rust\"\"\" struct methods" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        d = InlineDivider(Int32(10))

        ok = checked_div(d, Int32(2))
        @test ok isa RustCall.RustResult{Int32, String}
        @test RustCall.is_ok(ok)
        @test RustCall.unwrap(ok) == Int32(5)

        err = checked_div(d, Int32(0))
        @test RustCall.is_err(err)
        @test err.value == "cannot divide 10 by zero"

        some = ratio(d, Int32(4))
        @test some isa RustCall.RustOption{Float64}
        @test RustCall.unwrap(some) == 2.5
        @test RustCall.is_none(ratio(d, Int32(0)))

        both = describe(d, "meters")
        @test both isa RustCall.RustResult{String, String}
        @test RustCall.unwrap(both) == "10 meters"
        @test describe(d, "").value == "empty unit"

        @test RustCall.unwrap(tag(d, "s")) == "s10"

        # `&mut self`
        @test RustCall.unwrap(bump(d, Int32(5))) == Int32(15)
        @test RustCall.is_err(bump(d, Int32(-1)))
        @test RustCall.unwrap(checked_div(d, Int32(3))) == Int32(5)

        # static
        @test RustCall.unwrap(parse_scale(" 7 ")) == Int32(7)
        @test RustCall.is_err(parse_scale("seven"))

        # A panic in a `Result`/`Option` method raises rather than decoding the
        # uninitialized sentinel payload (#244).
        @test_throws RustCall.RustPanicError panicky(d, Int32(-1))
        @test RustCall.unwrap(panicky(d, Int32(1))) == Int32(15)
        @test_throws RustCall.RustPanicError panicky_opt(d, Int32(-1))
    end
end

@testset "#268: an owned String payload is released" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        d = InlineDivider(Int32(1))
        chunk = 1 << 20   # 1 MiB per call
        # Warm up, then measure the resident high-water mark across calls that
        # would leak 1000 MiB if the `Ok` buffer were never handed back to
        # `InlineDivider_free_rust_string`. `Sys.maxrss()` is a coarse,
        # monotonic-within-process high-water mark: under `Pkg.test()`'s
        # parallel runner, unrelated sibling worker processes' own memory use
        # was measured to move a leak-free run's mark by ~190-440 MiB on its
        # own (0 MiB and up to ~85 MiB for the same workload run in complete
        # isolation), so both the workload and the threshold here are sized an
        # order of magnitude past that: a real per-call leak is unambiguous at
        # ~1000 MiB, comfortably clear of the noise this measurement carries.
        for _ in 1:5
            @test length(RustCall.unwrap(wide(d, chunk))) == chunk
        end
        GC.gc(true)
        before = Sys.maxrss()
        for i in 1:1000
            s = RustCall.unwrap(wide(d, chunk))
            @test length(s) == chunk
            i % 20 == 0 && GC.gc(false)
        end
        GC.gc(true)
        growth = Sys.maxrss() - before
        @test growth < 700 * 1024 * 1024
    end
end

# ---------------------------------------------------------------------------
# Path 2 and 3: @rust_crate (in memory) and write_bindings_to_file (source text)
# ---------------------------------------------------------------------------

@testset "#268: crate emitters lower method payloads" begin
    info = RustCall.scan_crate(MRO_SAMPLE_CRATE)
    divider = only(filter(s -> s.name == "Divider", info.julia_structs))
    methods = Dict(m.name => m for m in divider.methods)

    @test methods["checked_div"].return_kind === :result
    @test methods["checked_div"].err_abi == "string"
    @test methods["ratio"].return_kind === :option
    @test methods["describe"].ok_abi == "string" && methods["describe"].err_abi == "string"

    code = RustCall.emit_crate_module_code(info, "/tmp/libsample_268.so")
    # The mirror of the Rust aggregate, with the owned buffer in the payload slot.
    @test occursin("struct CResult_Divider_checked_div <: FFIByValue", code)
    @test occursin("err_value::RustCall.CRustString", code)
    @test occursin("struct COption_Divider_ratio <: FFIByValue", code)
    # The release function is snapshotted with the call pointer: a crate method
    # names its buffer after `<Struct>_<method>` (#268, #277).
    @test occursin("func_ptr, panic_channel, free_ptr = _call_target(\"rustcall_Divider_checked_div\", \"Divider_checked_div_free_rust_string\")",
                   code)
    @test occursin("_result_payload(String, c_payload.err_value, free_ptr)", code)
    # No payload is a string here, so nothing is resolved to release.
    @test occursin("func_ptr, panic_channel = _call_target(\"rustcall_Divider_ratio\")", code)
    @test occursin("_result_payload(Float64, c_payload.value, C_NULL)", code)
    # The channel is read before either payload is decoded (#244).
    at = findfirst("function checked_div(self::Divider, d)", code)
    @test at !== nothing
    body = code[first(at):end]
    body = body[1:first(findfirst("\nend", body))]
    @test findfirst("_guard_panic(nothing,", body) < findfirst("_result_payload(", body)
    @test Meta.parse(code) isa Expr

    # The in-memory emitter emits the same aggregate and decoding.
    expr = string(RustCall._generate_crate_method_wrapper(divider, methods["describe"]))
    @test occursin("CResult_Divider_describe", expr)
    @test occursin("_result_payload(String,", expr)
    @test occursin("Divider_describe_free_rust_string", expr)
end

@testset "#268: @rust_crate methods return RustResult / RustOption" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        bindings = @rust_crate MRO_SAMPLE_CRATE name="SampleCrate268"
        # A struct type is not a `Function`, so `CrateBindings` hands it back
        # unwrapped and the call needs the current world explicitly.
        d = Base.invokelatest(bindings.Divider, Int32(10))

        @test RustCall.unwrap(bindings.checked_div(d, Int32(2))) == Int32(5)
        e = bindings.checked_div(d, Int32(0))
        @test RustCall.is_err(e)
        @test e.value == "cannot divide 10 by zero"

        @test RustCall.unwrap(bindings.ratio(d, Int32(4))) == 2.5
        @test RustCall.is_none(bindings.ratio(d, Int32(0)))

        @test RustCall.unwrap(bindings.describe(d, "meters")) == "10 meters"
        @test bindings.describe(d, "").value == "empty unit"
        @test RustCall.unwrap(bindings.tag(d, "s")) == "s10"

        @test RustCall.unwrap(bindings.bump(d, Int32(5))) == Int32(15)
        @test RustCall.is_err(bindings.bump(d, Int32(-1)))
        @test RustCall.unwrap(bindings.parse_scale(" 7 ")) == Int32(7)
        @test RustCall.is_err(bindings.parse_scale("seven"))

        # The free-function counterpart, which used to be a compile error.
        @test RustCall.unwrap(bindings.describe_scale(Int32(3), "kg")) == "3 kg"
        @test bindings.describe_scale(Int32(3), "").value == "empty unit"

        @test_throws RustCall.RustPanicError bindings.panicky_div(d, Int32(-1))
        @test_throws RustCall.RustPanicError bindings.panicky_ratio(d, Int32(-1))

        # Repeated calls with owned payloads on both branches, to exercise the
        # release path on each.
        for _ in 1:200
            @test RustCall.unwrap(bindings.describe(d, "m")) == "15 m"
            @test bindings.describe(d, "").value == "empty unit"
        end
    end
end

@testset "#268: written bindings decode method payloads" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        dir = mktempdir()
        path = joinpath(dir, "Bindings268.jl")
        mod = nothing
        try
            RustCall.write_bindings_to_file(MRO_SAMPLE_CRATE, path;
                                            output_module_name = "Bindings268")
            text = read(path, String)
            @test occursin("struct CResult_Divider_checked_div <: FFIByValue", text)
            @test occursin("_result_payload", text)
            @test occursin("# Bindings format: $(RustCall.BINDINGS_FORMAT_VERSION)", text)

            mod = Base.include(Main, path)
            # The module and its bindings are younger than this world, so both
            # the lookup and the call go through `invokelatest`.
            call(name, args...) =
                Base.invokelatest(Base.invokelatest(getfield, mod, Symbol(name)), args...)
            d = call("Divider", Int32(10))

            @test RustCall.unwrap(call("checked_div", d, Int32(2))) == Int32(5)
            @test call("checked_div", d, Int32(0)).value == "cannot divide 10 by zero"
            @test RustCall.unwrap(call("ratio", d, Int32(4))) == 2.5
            @test RustCall.is_none(call("ratio", d, Int32(0)))
            @test RustCall.unwrap(call("describe", d, "meters")) == "10 meters"
            @test call("describe", d, "").value == "empty unit"
            @test RustCall.unwrap(call("tag", d, "s")) == "s10"
            @test_throws RustCall.RustPanicError call("panicky_div", d, Int32(-1))
        finally
            # Windows cannot delete a mapped DLL: unload the image the module
            # loaded before the temporary tree goes away.
            if mod !== nothing
                try
                    RustCall.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME))
                catch
                end
            end
            rm(dir; recursive = true, force = true)
        end
    end
end
