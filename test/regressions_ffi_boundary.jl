# Component tests loaded by test_regressions.jl.

# A counting stand-in for `<fn>_free_rust_string` (#460 item 3). A plain
# top-level function, not a closure: closure `@cfunction` does not exist on
# aarch64.
const _FREED_460 = Ref(0)
_release_460(ptr::Ptr{UInt8}, len::UInt, cap::UInt) = (_FREED_460[] += 1; nothing)

@testset "#460: FFI boundary correctness" begin
    repo_src = normpath(joinpath(@__DIR__, "..", "src"))
    src_text(file) = read_source_tree(joinpath(repo_src, file))

    @testset "item 1: an inline setter converts to the field's slot type" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required for the inline setter"
        else
            rust"""
            #[julia]
            pub struct Scale460 { pub factor: f64, pub count: i32 }

            #[julia]
            impl Scale460 {
                pub fn new() -> Self { Self { factor: 0.0, count: 0 } }
                pub fn factor_bits(&self) -> u64 { self.factor.to_bits() }
                pub fn count_value(&self) -> i32 { self.count }
            }
            """
            s = Scale460()
            # An `Int` on an `f64` field: converted, not passed in an integer
            # register for Rust to read a float register.
            s.factor = 3
            @test s.factor === 3.0
            @test factor_bits(s) == reinterpret(UInt64, 3.0)
            s.factor = 1//2
            @test s.factor === 0.5
            # An `Int64` on an `i32` field is narrowed, and refused when it
            # does not fit rather than truncated.
            s.count = 7
            @test count_value(s) === Int32(7)
            @test_throws InexactError (s.count = 2^40)
            @test count_value(s) === Int32(7)
            @test_throws InexactError (s.factor = 1 + 2im)
        end
    end

    @testset "item 3: the guard releases an owned buffer it will not decode" begin
        # A counting release function stands in for `<fn>_free_rust_string`.
        freed = _FREED_460
        freed[] = 0
        fp = @cfunction(_release_460, Cvoid, (Ptr{UInt8}, UInt, UInt))
        begin
            buf = Ptr{UInt8}(UInt(0x1000))
            raw = RustCall.CRustString(buf, UInt(3), UInt(8))
            # A callback's exception pending, no panic: released, then raised.
            RustCall.CallbackTrampoline{Int64}(x -> error("cb"))(0)
            @test_throws ErrorException RustCall.check_rust_panic_ptr(C_NULL, "f", raw, fp)
            @test freed[] == 1
            # Nothing pending: the caller decodes and releases it; the guard
            # does not touch it.
            RustCall.check_rust_panic_ptr(C_NULL, "f", raw, fp)
            @test freed[] == 1
            # A Result aggregate releases its active payload only.
            ok = RustCall.CResultType{RustCall.CRustString, RustCall.CRustString}(
                UInt8(1), raw, RustCall.CRustString(C_NULL, UInt(0), UInt(0)))
            RustCall.CallbackTrampoline{Int64}(x -> error("cb"))(0)
            @test_throws ErrorException RustCall.check_rust_panic_ptr(C_NULL, "f", ok, fp)
            @test freed[] == 2
            err = RustCall.CResultType{Int64, RustCall.CRustString}(UInt8(0), 0, raw)
            RustCall.CallbackTrampoline{Int64}(x -> error("cb"))(0)
            @test_throws ErrorException RustCall.guard_rust_panic_ptr(err, C_NULL, "f", fp)
            @test freed[] == 3
            # ...and never the inactive one.
            only_ok_plain = RustCall.CResultType{Int64, RustCall.CRustString}(UInt8(1), 5, raw)
            RustCall.CallbackTrampoline{Int64}(x -> error("cb"))(0)
            @test_throws ErrorException RustCall.check_rust_panic_ptr(C_NULL, "f", only_ok_plain, fp)
            @test freed[] == 3
            some = RustCall.COptionType{RustCall.CRustString}(UInt8(1), raw)
            none = RustCall.COptionType{RustCall.CRustString}(UInt8(0), raw)
            RustCall.CallbackTrampoline{Int64}(x -> error("cb"))(0)
            @test_throws ErrorException RustCall.check_rust_panic_ptr(C_NULL, "f", none, fp)
            @test freed[] == 3
            RustCall.CallbackTrampoline{Int64}(x -> error("cb"))(0)
            @test_throws ErrorException RustCall.check_rust_panic_ptr(C_NULL, "f", some, fp)
            @test freed[] == 4
        end
        @test RustCall._CALLBACK_ERRORS_PENDING[] == 0
        # Every generator guards an undecoded owned buffer with its release
        # function: no crate wrapper guards `nothing` before decoding, and no
        # owned-string read checks the channel without the buffer.
        crate = src_text("crate_bindings/crate_bindings.jl")
        @test !occursin("_guard_panic(nothing", crate)
        @test occursin("rustcall′channel, \$name, rustcall′freep)", crate)
        @test occursin("check_rust_panic_ptr(channel, func_name, raw, target.free_ptr)", src_text("ffi/structs.jl"))
    end

    @testset "item 4: CompilationError display" begin
        # 100 lines, one error on line 70: lines 1-50, 70 and 91-100 are
        # shown; 51-69 (19 lines) and 71-90 (20 lines) are omitted, each
        # counted exactly.
        source = join(["let x$(i) = $(i);" for i in 1:100], "\n")
        e = RustCall.CompilationError("failed", "error: bad\n --> src/lib.rs:70:5\n", source, "rustc")
        text = sprint(showerror, e)
        @test occursin("let x50 = 50;", text)
        @test !occursin("let x51 = 51;", text)
        @test !occursin("let x69 = 69;", text)
        @test occursin(">>> ", text) && occursin("let x70 = 70;", text)
        @test !occursin("let x71 = 71;", text) && !occursin("let x90 = 90;", text)
        @test occursin("let x91 = 91;", text) && occursin("let x100 = 100;", text)
        @test occursin("(19 lines omitted)", text)
        @test occursin("(20 lines omitted)", text)
        # Non-ASCII text is cut by characters, never mid-character.
        long = repeat("é", 600)
        e2 = RustCall.CompilationError("failed", "no locations here", long, "rustc")
        text2 = sprint(showerror, e2)
        @test occursin(repeat("é", 500) * "...", text2)
        @test !occursin(repeat("é", 501), text2)
        e3 = RustCall.RuntimeError("failed", "f"; arguments = Any[repeat("α", 150)],
                                   context = Dict{String, Any}("note" => repeat("ü", 300)))
        text3 = sprint(showerror, e3)
        @test occursin(repeat("α", 97) * "...", text3)
        @test !occursin(repeat("α", 98), text3)
        @test occursin(repeat("ü", 197) * "...", text3)
        @test !occursin(repeat("ü", 198), text3)
        @test RustCall._truncate_chars("short", 10) == "short"
    end

    @testset "item 5: rustc keeps RustToolChain's whole command" begin
        base = setenv(`rustc-from-artifact --sysroot /opt/sysroot`, "RUSTCALL_460" => "1"; dir = "/tmp")
        cmd = RustCall.rustc_command(["--crate-type=cdylib", "-o", "out", "in.rs"]; base = base)
        @test cmd.exec == ["rustc-from-artifact", "--sysroot", "/opt/sysroot",
                           "--crate-type=cdylib", "-o", "out", "in.rs"]
        @test cmd.env == base.env
        @test cmd.dir == base.dir
        # No caller keeps only the executable.
        for file in ("build/compiler.jl", "macros/generics.jl", "macros/manifest.jl")
            @test !occursin("rustc().exec[1]", src_text(file))
        end
        if RustCall.check_rustc_available()
            # The default command is the resolved toolchain's own.
            @test RustCall.rustc_command(["--version"]).exec[1:end-1] == RustCall.rustc().exec
            @test success(RustCall.rustc_command(["--version"]))
        end
    end

    @testset "item 6: RustBox never drops through the untyped helper" begin
        @test RustCall._rust_box_drop_symbol(UInt8) === nothing
        @test RustCall._rust_box_drop_symbol(Ptr{Cvoid}) === nothing
        @test RustCall._rust_box_drop_symbol(Int64) === :rust_box_drop_i64
        # An unsupported `T` gets an inert drop target, and an explicit drop
        # marks the box dropped without calling Rust on memory Rust never
        # allocated as a `Box<T>` (here, Julia's own `malloc`).
        target = RustCall._ownership_drop_target(UInt8, :box)
        @test target[1] == C_NULL
        mem = Libc.malloc(16)
        try
            box = RustCall.RustBox{UInt8}(mem)
            @test box.free_ptr == C_NULL
            RustCall.drop!(box)
            @test box.dropped
            @test box.ptr == C_NULL
        finally
            Libc.free(mem)
        end
    end
end
