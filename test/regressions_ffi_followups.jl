# Component tests loaded by test_regressions.jl.

# ---------------------------------------------------------------------------
# #276 Phase B, Codex review follow-ups.
# ---------------------------------------------------------------------------

# The monomorphized call path derived its `ccall` signature from the *runtime*
# Julia types of the arguments rather than from the slots the manifest recorded,
# so a fixed `char` parameter of a generic function received Julia's
# left-aligned UTF-8 `Char` bits where Rust expects a `UInt32` code point.
@testset "#276: a monomorphized call converts to the recorded slots" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        rust"""
        #[julia]
        pub fn rc276_tag<T: std::fmt::Display>(value: T, sep: char) -> char {
            let _ = format!("{}", value);
            sep.to_ascii_uppercase()
        }
        #[julia]
        pub fn rc276_shout_char(c: char) -> char { c.to_ascii_uppercase() }
        """

        # Non-generic: `char` in and `char` out, converted in both directions.
        @test rc276_shout_char('a') === 'A'
        @test rc276_shout_char('π') === 'π'
        @test rc276_shout_char('𝄞') === '𝄞'

        # Generic with a fixed `char` argument and a `char` return: the slot
        # comes from the specialized manifest, not from `typeof(sep)`.
        @test RustCall.call_generic_function("rc276_tag", Int32(1), 'q') === 'Q'
        @test RustCall.call_generic_function("rc276_tag", Float64(2.5), 'π') === 'π'

        # The recorded slot really is the code point, and the specialized
        # return type really is the surface `Char`.
        info = RustCall.monomorphize_function("rc276_tag", Dict{Symbol, Type}(:T => Int32))
        @test info.return_type === Char
        @test info.arg_types[2] === UInt32
        @test RustCall.ffi_slot_convert(info.arg_types[2], 'π') === UInt32(0x3c0)
    end
end

@testset "#276: a char slot that is not a scalar value is rejected" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        # A Rust `char` is always a Unicode scalar value, so a slot that is not
        # one did not come from a `char`. Reading it as a `Char` anyway would
        # construct an invalid one; the conversion refuses instead. The bad
        # value is produced on the Rust side, through a symbol that returns a
        # raw `u32` read back through the `char` surface type.
        code = """
        #[no_mangle]
        pub extern "C" fn rc276_bad_char() -> u32 { 0x0011_0000 }
        #[no_mangle]
        pub extern "C" fn rc276_surrogate() -> u32 { 0x0000_d800 }
        #[no_mangle]
        pub extern "C" fn rc276_good_char() -> u32 { 0x0000_03c0 }
        """
        lib = RustCall._compile_and_load_rust(code, "test_regressions", 0)
        good = RustCall.get_function_pointer(lib, "rc276_good_char")
        @test RustCall.call_rust_function(good, Char) === 'π'
        for sym in ("rc276_bad_char", "rc276_surrogate")
            ptr = RustCall.get_function_pointer(lib, sym)
            @test_throws RustCall.RustError RustCall.call_rust_function(ptr, Char)
        end
    end
end

# A specialized generic whose fixed return type the contract does not cover used
# to become `Any` silently, bypassing `FFI_STRICT`.
@testset "#276: an unsupported specialized return obeys FFI_STRICT" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        ctx = "rc276_boxed_i32(i32) -> Vec<f64>"
        previous = RustCall.FFI_STRICT[]
        try
            RustCall.FFI_STRICT[] = :error
            err = try
                RustCall._specialized_return_type("Vec<f64>", ctx)
                nothing
            catch e
                e
            end
            @test err isa RustCall.RustError
            @test occursin(ctx, sprint(showerror, err))

            RustCall.FFI_STRICT[] = :warn
            @test RustCall._specialized_return_type("Vec<f64>", ctx) === Any
            # A supported type is unaffected in either mode, and `char` comes
            # back as the surface type.
            @test RustCall._specialized_return_type("i32", ctx) === Int32
            @test RustCall._specialized_return_type("char", ctx) === Char
            @test RustCall._specialized_return_type("()", ctx) === Cvoid
        finally
            RustCall.FFI_STRICT[] = previous
        end
    end
end

# `write_bindings_to_file(...; strict)` used to set and restore the global
# `FFI_STRICT[]` around emission, so two concurrent calls raced. `strict` is
# threaded through the emitters instead.
@testset "#276: strict is threaded, not stashed in a global" begin
    unsupported = RustCall.RustFunctionSignature(
        "rc276_histogram", ["n"], ["u32"], "Vec<f64>", false, String[])
    # The fake crate lives in its own empty directory: the emitter walks the
    # crate path, and `"."` (the test directory) holds `fixtures/*/target/`,
    # whose rustc temp directories other workers of the parallel run create and
    # remove under our feet — `readdir` then raised ENOENT instead of the
    # `RustError` under test (flaky macOS CI on #334).
    rc276_dir = mktempdir()
    info = RustCall.CrateInfo("rc276_crate", rc276_dir, "0.1.0", RustCall.DependencySpec[],
                              [unsupported], RustCall.RustStructInfo[], String[])

    previous = RustCall.FFI_STRICT[]
    try
        # Whatever the global says, each call answers by its own argument.
        for global_setting in (:error, :warn, :none)
            RustCall.FFI_STRICT[] = global_setting
            @test_throws RustCall.RustError RustCall.emit_crate_module_code(
                info, "libx.so"; strict = :error)
            @test occursin("Any", RustCall.emit_crate_module_code(
                info, "libx.so"; strict = :none))
            @test RustCall.FFI_STRICT[] === global_setting
        end

        # Concurrently, with opposite settings: the strict one throws, the
        # lenient one emits, and neither disturbs the global.
        RustCall.FFI_STRICT[] = :none
        results = Vector{Any}(undef, 2)
        @sync begin
            Threads.@spawn results[1] = try
                RustCall.emit_crate_module_code(info, "libx.so"; strict = :error)
            catch e
                e
            end
            Threads.@spawn results[2] = try
                RustCall.emit_crate_module_code(info, "libx.so"; strict = :none)
            catch e
                e
            end
        end
        @test results[1] isa RustCall.RustError
        @test results[2] isa String
        @test occursin("Any", results[2])
        @test RustCall.FFI_STRICT[] === :none
    finally
        RustCall.FFI_STRICT[] = previous
        rm(rc276_dir; recursive = true, force = true)
    end
end

# A `Result` / `Option` payload is a FIELD of a `#[repr(C)]` aggregate, so it
# holds what Rust stored — the C slot — while the caller sees the surface type.
# The two differ for `char`: declaring the field as `Char` read a `UInt32` code
# point as Julia's left-aligned UTF-8 bit pattern, and the slot-to-surface
# conversion never ran because the return type was the aggregate, not `Char`.
@testset "#276: Result / Option char payloads convert to the surface type" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        rust"""
        #[julia]
        pub fn rc276_res_char(ok: bool) -> Result<char, i32> {
            if ok { Ok('π') } else { Err(-7) }
        }
        #[julia]
        pub fn rc276_opt_char(some: bool) -> Option<char> {
            if some { Some('😀') } else { None }
        }
        #[julia]
        pub fn rc276_res_flag(ok: bool) -> Result<bool, i32> {
            if ok { Ok(true) } else { Err(-1) }
        }
        """

        ok = rc276_res_char(true)
        @test RustCall.is_ok(ok)
        @test RustCall.unwrap(ok) === 'π'
        err = rc276_res_char(false)
        @test RustCall.is_err(err)
        @test err.value === Int32(-7)

        some = rc276_opt_char(true)
        @test RustCall.is_some(some)
        @test RustCall.unwrap(some) === '😀'
        @test RustCall.is_none(rc276_opt_char(false))

        # `bool` payloads take the same path and are unaffected: a Rust `bool`
        # is one byte, and so is a Julia `Bool`, so slot and surface agree.
        @test RustCall.unwrap(rc276_res_flag(true)) === true
        @test rc276_res_flag(false).value === Int32(-1)

        # The field really is declared with the slot, and the surface type is
        # what the wrapper hands back.
        @test RustCall.ffi_return_slot_symbol_or_throw("char", "", "f() -> char") === :UInt32
        @test RustCall.ffi_return_symbol_or_throw("char", "", "f() -> char") === :Char
        @test RustCall.ffi_return_slot_symbol_or_throw("i32", "", "f() -> i32") === :Int32
        @test RustCall.ffi_return_slot_symbol_or_throw("bool", "", "f() -> bool") === :Bool
        @test RustCall.ffi_return_slot_symbol_or_throw("()", "", "f()") === :Cvoid

        # A payload that is not a Unicode scalar value is rejected rather than
        # turned into an invalid `Char`, exactly as a bare `char` return is.
        bad = RustCall.CResultType{UInt32, Int32}(0x01, 0x00110000, Int32(0))
        @test_throws RustCall.RustError RustCall.convert_c_result_to_rust_result(
            bad, Char, Int32)
        bad_opt = RustCall.COptionType{UInt32}(0x01, 0x0000d800)
        @test_throws RustCall.RustError RustCall.convert_c_option_to_rust_option(
            bad_opt, Char)
        # …and a valid one round-trips through the same helpers.
        good = RustCall.CResultType{UInt32, Int32}(0x01, 0x000003c0, Int32(0))
        @test RustCall.unwrap(RustCall.convert_c_result_to_rust_result(good, Char, Int32)) === 'π'
    end
end

# Both crate-path generators declare the payload with the slot and convert.
# Since #268 the conversion goes through `_result_payload`, which is
# `convert_return` for a plain payload and the copy-and-release path for an
# owned `String` one.
@testset "#276: crate Result / Option payloads use the slot type" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        sigs = RustCall.manifest_function_signatures(RustCall.extract_manifest("""
        use rustcall_julia_macros::julia;
        #[julia]
        pub fn rc276_crate_res() -> Result<char, i32> { Ok('a') }
        #[julia]
        pub fn rc276_crate_opt() -> Option<char> { Some('a') }
        """; mode = "crate"))
        res = only(f for f in sigs if f.name == "rc276_crate_res")
        opt = only(f for f in sigs if f.name == "rc276_crate_opt")

        # Compared without the qualification every emitter spells Base and
        # RustCall with (#528).
        unqualified(s) = replace(s, "rustcall′Base." => "", "rustcall′RustCall." => "",
                                 "Base." => "", "RustCall." => "")
        for emitted in unqualified.((RustCall._emit_function_code(res),
                                     string(RustCall._generate_crate_function_wrapper(res))))
            @test occursin("ok_value::UInt32", replace(emitted, " " => ""))
            @test occursin("_result_payload(Char", replace(emitted, " " => ""))
            @test occursin("RustResult{Char,Int32}", replace(emitted, " " => ""))
        end
        for emitted in unqualified.((RustCall._emit_function_code(opt),
                                     string(RustCall._generate_crate_function_wrapper(opt))))
            @test occursin("value::UInt32", replace(emitted, " " => ""))
            @test occursin("_result_payload(Char", replace(emitted, " " => ""))
        end
    end
end

# The warn-once set was read outside the lock and inserted into under it, so two
# threads could both decide the context was new.
@testset "#276: the warn-once set is tested and inserted atomically" begin
    previous = RustCall.FFI_STRICT[]
    try
        RustCall.FFI_STRICT[] = :warn
        ctx = "rc276_race_$(rand(UInt64))(i32) -> Vec<f64>"
        lock(RustCall.REGISTRY_LOCK) do
            delete!(RustCall._FFI_WARNED_CONTEXTS, ctx)
        end

        # Many tasks, one context: exactly one of them may warn.
        n = 32
        warned = zeros(Int, n)
        @sync for i in 1:n
            # `local`: without it every task would assign the same captured
            # binding and they would race on each other's logger.
            Threads.@spawn begin
                local task_logger = Test.TestLogger()
                Base.CoreLogging.with_logger(task_logger) do
                    RustCall.ffi_return_symbol_or_throw("Vec<f64>", "", ctx; strict = :warn)
                end
                warned[i] = count(r -> r.level == Base.CoreLogging.Warn, task_logger.logs)
            end
        end
        @test sum(warned) == 1
        @test ctx in RustCall._FFI_WARNED_CONTEXTS
        # A later call is silent, and still answers.
        after_logger = Test.TestLogger()
        result = Base.CoreLogging.with_logger(after_logger) do
            RustCall.ffi_return_symbol_or_throw("Vec<f64>", "", ctx; strict = :warn)
        end
        @test result === :Any
        @test isempty(after_logger.logs)
    finally
        RustCall.FFI_STRICT[] = previous
    end
end
