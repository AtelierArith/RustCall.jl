# Callbacks (#296): a `#[julia]` item may take a C-ABI function pointer, and a
# Julia function — a closure included — is handed to it through a
# `@cfunction` the wrapper builds from the manifest's record of the pointer's
# signature. The rules (synchronous borrow, same thread, no exception unwinds
# through Rust) are in docs/src/type_contract.md.
using RustCall
using Test

const _CB_REPO = normpath(joinpath(@__DIR__, ".."))

@testset "callbacks (#296)" begin
    @testset "the contract" begin
        c = RustCall.ffi_argument_contract("extern \"C\" fn(i64) -> i64"; abi = "callback")
        @test c.known && c.abi === :callback
        @test c.ccall_types == Type[Ptr{Cvoid}]
        @test c.surface_type === Function
        @test c.ownership === :owned_by_julia
        @test RustCall.ffi_slots(:callback) == Type[Ptr{Cvoid}]
        @test :callback in RustCall.FFI_ABI_KINDS
        @test RustCall.ffi_manifest_abi_kind("callback", :argument) === :callback
        # Return position has no owner: refused, not guessed.
        @test_throws ArgumentError RustCall.ffi_manifest_abi_kind("callback", :return)
        @test_throws ArgumentError RustCall.ffi_return_contract("extern \"C\" fn() -> i64"; abi = "callback")
        # Without the manifest column the spelling is unknown — Julia does not
        # read Rust syntax (#264) — and the position fails closed.
        @test !RustCall.ffi_argument_contract("extern \"C\" fn(i64) -> i64").known

        # The plan: the @cfunction's slot spellings, from the contract.
        plan = RustCall.ffi_callback_plan(["i64", "f64", "*const u8", "bool"], "u32", "argument `f` of `g`")
        @test plan.arg_exprs == Any[:Int64, :Float64, :(Ptr{UInt8}), :Bool]
        @test plan.ret_expr === :UInt32 && plan.ret_type === UInt32
        unit = RustCall.ffi_callback_plan(String[], "", "argument `f` of `g`")
        @test unit.ret_expr === :Cvoid && unit.ret_type === Cvoid && isempty(unit.arg_exprs)
        @test RustCall.ffi_callback_plan(String[], "()", "x").ret_type === Cvoid
        # Refused with the position named: strings, `char` (its slot is a
        # UInt32 code point), aggregates, spellings outside the table.
        for (args, ret, what) in ((["&str"], "", "parameter 1"), (["String"], "", "parameter 1"),
                                  (["char"], "", "parameter 1"), (["Vec<i32>"], "", "parameter 1"),
                                  (["i64", "Foo"], "", "parameter 2"),
                                  (String[], "&str", "return"), (String[], "char", "return"),
                                  (String[], "Option<i32>", "return"))
            err = try
                RustCall.ffi_callback_plan(args, ret, "argument `f` of `g`")
                nothing
            catch e
                e
            end
            @test err isa RustCall.RustError
            msg = sprint(showerror, err)
            @test occursin("argument `f` of `g`", msg) && occursin(what, msg)
        end

        # A hand-built signature refuses at wrapper generation, never at call
        # time: no wrapper is emitted for a callback the contract cannot build.
        bad = RustCall.RustFunctionSignature("g", ["f"], ["extern \"C\" fn(&str)"], "()", false, String[];
                                             arg_abis = ["callback"], callback_args = [["&str"]],
                                             callback_returns = [""])
        @test_throws RustCall.RustError RustCall.emit_julia_function_wrappers([bad])
        @test_throws RustCall.RustError RustCall._emit_function_code(bad)
        @test_throws ArgumentError RustCall.RustFunctionSignature("g", ["f"], ["i64"], "()", false, String[];
                                                                  callback_args = Vector{String}[])

        # The generated source of a crate binding spells the same @cfunction.
        good = RustCall.RustFunctionSignature("apply", ["f", "x"], ["extern \"C\" fn(i64) -> i64", "i64"], "i64",
                                              false, String[]; symbol = "rustcall_apply",
                                              arg_abis = ["callback", ""], callback_args = [["i64"], String[]],
                                              callback_returns = ["i64", ""])
        src = RustCall._emit_function_code(good)
        @test occursin("Base.@cfunction RustCall._callback_slot_1 Int64 (Int64,)", src)
        @test occursin("CallbackTrampoline{Int64}", src)
        @test occursin("RustCall._push_callback_frame!", src) && occursin("RustCall._pop_callback_frame!", src)
        @test occursin("try", src) && occursin("finally", src)
        @test Meta.parseall(src) isa Expr
        # More callback arguments than there are slots is refused at generation.
        many = RustCall.RustFunctionSignature("g", ["f$i" for i in 1:9], fill("extern \"C\" fn(i64) -> i64", 9), "i64",
                                              false, String[]; arg_abis = fill("callback", 9),
                                              callback_args = [["i64"] for _ in 1:9], callback_returns = fill("i64", 9))
        err = try RustCall.emit_julia_function_wrappers([many]); nothing catch e; e end
        @test err isa RustCall.RustError && occursin("more than $(RustCall.CALLBACK_SLOTS)", sprint(showerror, err))
    end

    @testset "callback frames" begin
        # No closure cfunction anywhere: each slot is a plain function with a
        # constant pointer, and the frame on top of the task's stack says
        # which Julia function it stands for.
        p1 = @cfunction(RustCall._callback_slot_1, Int64, (Int64,))
        @test p1 isa Ptr{Cvoid} && p1 != C_NULL
        @test p1 != @cfunction(RustCall._callback_slot_2, Int64, (Int64,))
        f1 = RustCall._push_callback_frame!(RustCall.CallbackTrampoline{Int64}(x -> x + 1))
        @test ccall(p1, Int64, (Int64,), 41) == 42
        # A nested frame shadows the outer one for the duration, and popping
        # it restores the outer — LIFO, whatever the pointer.
        f2 = RustCall._push_callback_frame!(RustCall.CallbackTrampoline{Int64}(x -> x * 100))
        @test ccall(p1, Int64, (Int64,), 2) == 200
        RustCall._pop_callback_frame!(f2)
        @test ccall(p1, Int64, (Int64,), 2) == 3
        # Popping by identity: a frame that is not on top is still removed.
        f3 = RustCall._push_callback_frame!(RustCall.CallbackTrampoline{Int64}(x -> -x))
        RustCall._pop_callback_frame!(f1)
        @test ccall(p1, Int64, (Int64,), 5) == -5
        RustCall._pop_callback_frame!(f3)
        @test isempty(RustCall._callback_frames())
        # Slot with no frame: an error inside the trampoline lookup, which the
        # slot function turns into a stored exception rather than an unwind
        # through the C frame? No — there is no trampoline to store into, so
        # this is the one misuse (a callback invoked after its call returned)
        # the docs call undefined; the lookup at least names it.
        @test_throws ErrorException RustCall._callback_trampoline(1)
    end

    @testset "the trampoline never lets an exception out" begin
        t = RustCall.CallbackTrampoline{Int64}(x -> x * 2)
        @test t(21) === Int64(42)
        boom = ErrorException("boom")
        failing = RustCall.CallbackTrampoline{Int64}(x -> throw(boom))
        # The sentinel comes back, the exception is stored for this task, and
        # the pending count tells the guard to look.
        @test failing(1) === Int64(0)
        @test RustCall._CALLBACK_ERRORS_PENDING[] >= 1
        # A second failure in the same window does not replace the first.
        @test RustCall.CallbackTrampoline{Cvoid}(x -> error("later"))(1) === nothing
        stored = RustCall._take_callback_error()
        @test stored !== nothing && first(stored) === boom
        @test RustCall._take_callback_error() === nothing
        # The guard re-raises the stored exception as itself, with no channel.
        RustCall.CallbackTrampoline{Bool}(x -> throw(boom))(0)
        @test_throws ErrorException RustCall.guard_rust_panic_ptr(7, C_NULL, "g")
        # ...and, once taken, the guard is the plain guard again.
        @test RustCall.guard_rust_panic_ptr(7, C_NULL, "g") == 7
        # A conversion failure is an exception like any other.
        RustCall.CallbackTrampoline{Int64}(x -> "not a number")(0)
        @test_throws MethodError RustCall.guard_rust_panic_ptr(nothing, C_NULL, "g")
        @test RustCall._CALLBACK_ERRORS_PENDING[] == 0
    end

    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping the compiled callback tests"
        return
    end

    @testset "the manifest reports the pointer's signature" begin
        code = """
        #[julia]
        pub fn apply(f: extern "C" fn(i64) -> i64, x: i64) -> i64 { f(x) }
        #[julia]
        pub fn each(n: u32, visit: unsafe extern "C" fn(u32, f64)) { for i in 0..n { unsafe { visit(i, i as f64) } } }
        #[julia]
        pub fn rust_abi(f: fn(i64) -> i64) -> i64 { f(1) }
        """
        sigs = RustCall.manifest_function_signatures(RustCall.extract_manifest(code; mode = "inline"))
        by = Dict(s.name => s for s in sigs)
        @test by["apply"].arg_abis == ["callback", ""]
        @test by["apply"].callback_args == [["i64"], String[]]
        @test by["apply"].callback_returns == ["i64", ""]
        @test by["each"].arg_abis == ["", "callback"]
        @test by["each"].callback_args[2] == ["u32", "f64"]
        @test by["each"].callback_returns[2] == ""
        # A Rust-ABI pointer is not a callback: reported as written, and a
        # Julia function cannot be passed for it.
        @test by["rust_abi"].arg_abis == [""]
        @test isempty(by["rust_abi"].callback_args[1])

        crate = """
        use rustcall_julia_macros::julia;
        #[julia]
        pub struct Acc { pub total: i64 }
        #[julia]
        impl Acc {
            #[julia]
            pub fn new(total: i64) -> Self { Acc { total } }
            #[julia]
            pub fn fold(&self, f: extern "C" fn(i64) -> i64) -> i64 { f(self.total) }
        }
        """
        infos = RustCall.manifest_struct_infos(RustCall.extract_manifest(crate; mode = "crate"))
        acc = only(infos)
        fold = only(filter(m -> m.name == "fold", acc.methods))
        @test fold.arg_abis == ["callback"]
        @test fold.callback_args == [["i64"]] && fold.callback_returns == ["i64"]
    end

    @testset "inline: a closure drives a #[julia] function" begin
        rust"""
        #[julia]
        pub fn cb_apply(f: extern "C" fn(i64) -> i64, x: i64) -> i64 { f(x) + 1 }

        #[julia]
        pub fn cb_each(n: u32, visit: extern "C" fn(u32, f64)) -> u32 {
            for i in 0..n { visit(i, i as f64 * 0.5) }
            n
        }

        #[julia]
        pub fn cb_probe(cb: extern "C" fn(*const u8) -> bool) -> bool { cb(std::ptr::null()) }

        #[julia]
        pub fn cb_twice(f: extern "C" fn(i64) -> i64, g: extern "C" fn(i64) -> i64, x: i64) -> i64 { g(f(x)) }

        #[julia]
        pub struct CbAcc { pub total: i64 }

        #[julia]
        impl CbAcc {
            pub fn new(total: i64) -> Self { CbAcc { total } }
            pub fn fold(&self, f: extern "C" fn(i64) -> i64) -> i64 { f(self.total) }
        }
        """
        @test cb_apply(x -> x * 2, 20) == 41
        @test cb_apply(identity, 5) == 6
        k = 10
        @test cb_apply(x -> x + k, 1) == 12          # a closure over a local
        seen = Float64[]
        @test cb_each(4, (i, v) -> push!(seen, v)) == 4
        @test seen == [0.0, 0.5, 1.0, 1.5]
        @test cb_probe(p -> p == C_NULL)
        @test cb_twice(x -> x + 1, x -> x * 3, 1) == 6  # two callbacks in one call: (1 + 1) * 3
        @test CbAcc(7).fold(x -> x * x) == 49
        # A callback that yields is still on this task when it resumes.
        @test cb_apply(x -> (yield(); x), 3) == 4
        # Nested: a callback that itself drives a callback through the same
        # slot; the inner frame is pushed and popped inside the outer call.
        @test cb_apply(x -> cb_apply(y -> y * 10, x), 2) == 22   # (2*10+1)+1
        @test cb_apply(x -> cb_apply(y -> y, 0) + x, 5) == 7       # inner 1, +5, +1
        @test isempty(RustCall._callback_frames())

        # An exception inside the callback surfaces at the call site as the
        # same object, and the Rust frames were left cleanly: the next call
        # works and reports no stale panic.
        boom = ErrorException("boom")
        err = try
            cb_apply(x -> throw(boom), 1)
            nothing
        catch e
            e
        end
        @test err === boom
        @test cb_apply(x -> x, 1) == 2
        @test RustCall._CALLBACK_ERRORS_PENDING[] == 0
        @test isempty(RustCall._callback_frames())   # popped on the error path too
        # A wrong return type is a conversion failure inside the callback.
        @test_throws MethodError cb_apply(x -> "s", 1)
        @test cb_apply(x -> x, 1) == 2
        # An exception on the second of many invocations: Rust ran on the
        # sentinel for the rest, and the first exception is what surfaces.
        calls = Ref(0)
        @test_throws ErrorException cb_each(5, (i, v) -> (calls[] += 1; i == 1 && error("second")))
        @test calls[] == 5

        # The frame (and through it the user's function) stays reachable for
        # the call however hard the callback allocates or collects.
        for _ in 1:20
            @test cb_apply(x -> (GC.gc(); sum(rand(10_000)) > -1 ? x : x), 3) == 4
        end
        junk = Ref{Any}(nothing)
        @test cb_each(50, (i, v) -> (junk[] = [zeros(1000) for _ in 1:20]; GC.gc(false))) == 50
    end

    @testset "exceptions are per task" begin
        rust"""
        #[julia]
        pub fn cb_task(f: extern "C" fn(i64) -> i64, x: i64) -> i64 { f(x) }
        """
        # Several tasks drive callbacks that yield and then fail: each task
        # gets its own exception, never a neighbour's.
        results = Vector{Any}(undef, 8)
        @sync for i in 1:8
            Threads.@spawn begin
                results[i] = try
                    cb_task(x -> (yield(); i % 2 == 0 ? error("task $i") : x + i), i)
                catch e
                    e
                end
            end
        end
        for i in 1:8
            if i % 2 == 0
                @test results[i] isa ErrorException && results[i].msg == "task $i"
            else
                @test results[i] == 2i
            end
        end
        @test RustCall._CALLBACK_ERRORS_PENDING[] == 0
        # The callback runs on the thread that made the call.
        tids = Int[]
        cb_task(x -> (push!(tids, Threads.threadid()); x), 0)
        @test tids == [Threads.threadid()]
    end

    @testset "@rust_crate: the generated bindings pass a callback" begin
        mktempdir() do dir
            mkpath(joinpath(dir, "src"))
            macros = joinpath(_CB_REPO, "deps", "rustcall_julia_macros")
            write(joinpath(dir, "Cargo.toml"), """
            [package]
            name = "cb_crate"
            version = "0.1.0"
            edition = "2021"

            [lib]
            crate-type = ["cdylib"]

            [dependencies]
            rustcall_julia_macros = { path = $(repr(macros)) }
            """)
            write(joinpath(dir, "src", "lib.rs"), """
            use rustcall_julia_macros::julia;

            #[julia]
            pub fn crate_apply(f: extern "C" fn(i64) -> i64, x: i64) -> i64 { f(x) * 10 }

            #[julia]
            pub struct Tally { pub total: i64 }

            #[julia]
            impl Tally {
                #[julia]
                pub fn new(total: i64) -> Self { Tally { total } }
                #[julia]
                pub fn fold(&self, f: extern "C" fn(i64) -> i64) -> i64 { f(self.total) }
            }
            """)
            bindings = @eval RustCall.@rust_crate $dir cache=false
            @test bindings.crate_apply(x -> x + 1, 4) == 50
            # The module was defined by `@eval` inside this testset's body, so
            # its constructor is newer than this world: `invokelatest`.
            tally = Base.invokelatest(bindings.Tally, 6)
            @test Base.invokelatest(bindings.fold, tally, x -> x * 7) == 42
            boom = ErrorException("crate boom")
            err = try
                bindings.crate_apply(x -> throw(boom), 1)
                nothing
            catch e
                e
            end
            @test err === boom
            @test bindings.crate_apply(identity, 1) == 10
            # The written-out file spells the same cfunction and loads.
            out = joinpath(dir, "bindings.jl")
            RustCall.write_bindings_to_file(dir, out)
            text = read(out, String)
            @test occursin("Base.@cfunction", text) && occursin("CallbackTrampoline{Int64}", text)
            @test Meta.parseall(text) isa Expr
            RustCall.unload_library(Base.invokelatest(getfield, getfield(bindings, :module_ref), :_LIB_NAME); close = true)
        end
    end
end
