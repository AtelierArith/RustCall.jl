# One source, every door: the properties that must not depend on which front
# door compiled and loaded a block (#269, #250, #277).
#
# Phase A of #277 recorded four decisions each door made for itself — dlopen
# flags, panic strategy, registration, finalizer policy. Phase B routed every
# door through `load_artifact!`. This file is the behavioural check that they
# really did converge: the *same* Rust source is taken through the direct-rustc
# door, the Cargo door and (where cargo is available) a `@rust_crate` crate,
# and each door is asserted to give the same answers.

using Test
using RustCall
using Libdl

const _CONF_RUSTC = RustCall.check_rustc_available()
const _CONF_CARGO = try
    success(run(pipeline(`cargo --version`, devnull, devnull); wait = true))
catch
    false
end

"""Every registry keyed by library name, for the "unload leaves nothing" check."""
function _conformance_registry_rows(lib_name)
    lock(RustCall.REGISTRY_LOCK) do
        Dict{Symbol, Int}(
            :RUST_LIBRARIES =>
                Int(haskey(RustCall.RUST_LIBRARIES, lib_name)),
            :FUNCTION_SYMBOLS_BY_LIB =>
                count(k -> first(k) == lib_name, keys(RustCall.FUNCTION_SYMBOLS_BY_LIB)),
            :FUNCTION_RETURN_TYPES_BY_LIB =>
                count(k -> first(k) == lib_name, keys(RustCall.FUNCTION_RETURN_TYPES_BY_LIB)),
            :FUNCTION_REGISTRY_BY_LIB =>
                count(k -> first(k) == lib_name, keys(RustCall.FUNCTION_REGISTRY_BY_LIB)),
            :FUNCTION_REGISTRY =>
                count(v -> v.lib_name == lib_name, values(RustCall.FUNCTION_REGISTRY)),
            :MONOMORPHIZED_FUNCTIONS =>
                count(v -> v.lib_name == lib_name, values(RustCall.MONOMORPHIZED_FUNCTIONS)),
            :IRUST_FUNCTIONS =>
                count(v -> first(v) == lib_name, values(RustCall.IRUST_FUNCTIONS)),
            :RUST_MODULE_REGISTRY =>
                Int(haskey(RustCall.RUST_MODULE_REGISTRY, lib_name)),
            :PANIC_CHANNELS =>
                count(k -> first(k) == lib_name, keys(RustCall.PANIC_CHANNELS)),
            :ARTIFACT_ALIVE =>
                Int(haskey(RustCall.ARTIFACT_ALIVE, lib_name)),
            :CURRENT_LIB =>
                Int(RustCall.CURRENT_LIB[] == lib_name),
        )
    end
end

"""Is `symbol` reachable through the *process-global* namespace?"""
function _visible_globally(symbol)
    Sys.isunix() || return missing   # Windows LoadLibrary has no such notion
    rtld_default = Sys.isapple() ? Ptr{Cvoid}(-2) : C_NULL
    return ccall(:dlsym, Ptr{Cvoid}, (Ptr{Cvoid}, Cstring), rtld_default, symbol) != C_NULL
end

@testset "Load conformance: every door agrees (#269)" begin

    if !_CONF_RUSTC
        @test_skip "rustc is required for the conformance suite"
    else

        # ------------------------------------------------------------------
        # Visibility (#250): a leaf artifact's symbols stay out of the global
        # namespace, on every door and in both cache states.
        # ------------------------------------------------------------------
        @testset "symbols are never published globally" begin
            source = """
                #[julia]
                fn conformance_probe(a: i32) -> i32 { a + 1 }
                """
            compiler = RustCall.get_default_compiler()

            # Fresh compile.
            lib_a = RustCall._compile_and_load_rust(source, "conformance", 1)
            @test !ismissing(_visible_globally("rustcall_conformance_probe")) &&
                  _visible_globally("rustcall_conformance_probe") == false ||
                  Sys.iswindows()
            handle_a = RustCall.get_library_handle(lib_a)
            @test Libdl.dlsym(handle_a, "rustcall_conformance_probe";
                              throw_error = false) !== nothing

            # Same source again: this is the *cache* axis, and it must not
            # change visibility. Before #277 Phase B2 the axis that did change
            # it was whether the block declared `// cargo-deps:`.
            RustCall.unload_library(lib_a)
            lib_b = RustCall._compile_and_load_rust(source, "conformance", 1)
            @test lib_b == lib_a          # same identity, so a cache hit
            if Sys.isunix()
                @test _visible_globally("rustcall_conformance_probe") == false
            end
            RustCall.unload_library(lib_b)

            # Every policy says so, which is what keeps it true for the doors
            # this test cannot reach cheaply.
            for ctor in RustCall.ALL_LOAD_POLICIES
                @test !RustCall.uses_global_symbols(ctor())
            end
        end

        # ------------------------------------------------------------------
        # #250: two modules each defining `add` call their own `add`,
        # regardless of the order they were loaded in.
        # ------------------------------------------------------------------
        @testset "same name in two modules resolves per module (#250)" begin
            mod_a = Module(:ConformanceA)
            mod_b = Module(:ConformanceB)
            Core.eval(mod_a, :(using RustCall))
            Core.eval(mod_b, :(using RustCall))

            # Deliberately the same Rust name, different bodies.
            Core.eval(mod_a, quote
                rust"""
                #[julia]
                fn conformance_add(a: i32, b: i32) -> i32 { a + b }
                """
            end)
            Core.eval(mod_b, quote
                rust"""
                #[julia]
                fn conformance_add(a: i32, b: i32) -> i32 { (a + b) * 100 }
                """
            end)

            # Each module's own wrapper reaches its own library...
            @test Core.eval(mod_a, :(conformance_add(Int32(2), Int32(3)))) == Int32(5)
            @test Core.eval(mod_b, :(conformance_add(Int32(2), Int32(3)))) == Int32(500)
            # ...and again in the other order, to show load order does not
            # decide it (which it did while both were RTLD_GLOBAL).
            @test Core.eval(mod_b, :(conformance_add(Int32(1), Int32(1)))) == Int32(200)
            @test Core.eval(mod_a, :(conformance_add(Int32(1), Int32(1)))) == Int32(2)
        end

        # ------------------------------------------------------------------
        # #250: unload leaves nothing behind, in *any* registry.
        # ------------------------------------------------------------------
        @testset "unload purges every registry (#250)" begin
            lib = RustCall._compile_and_load_rust("""
                #[julia]
                fn conformance_unload(a: i32) -> i32 { a * 3 }
                """, "conformance", 1)

            # Populate as many registries as one library can reach.
            @test (@rust conformance_unload(Int32(2))) == Int32(6)
            RustCall.register_function("conformance_unload", lib, Int32, Type[Int32])
            RustCall.panic_channel_pointer(lib, "rustcall_conformance_unload")

            before = _conformance_registry_rows(lib)
            @test before[:RUST_LIBRARIES] == 1
            @test before[:FUNCTION_SYMBOLS_BY_LIB] > 0
            @test before[:ARTIFACT_ALIVE] == 1

            alive = RustCall.artifact_alive_ref(lib)
            @test alive[]

            RustCall.unload_library(lib)

            after = _conformance_registry_rows(lib)
            for (name, count) in after
                @test count == 0
            end
            # ...and objects the library produced are retired with it.
            @test !alive[]
        end

        # ------------------------------------------------------------------
        # #250: a name collision inside ONE module is refused, with a message
        # that says which name and what to do.
        # ------------------------------------------------------------------
        @testset "a duplicate name in one module is refused (#250)" begin
            mod = Module(:ConformanceDup)
            Core.eval(mod, :(using RustCall))
            Core.eval(mod, quote
                rust"""
                #[julia]
                fn conformance_dup(a: i32) -> i32 { a }
                """
            end)
            err = try
                Core.eval(mod, quote
                    rust"""
                    #[julia]
                    fn conformance_dup(a: i32) -> i32 { a * 2 }
                    """
                end)
                nothing
            catch e
                e
            end
            @test err !== nothing
            message = sprint(showerror, err isa LoadError ? err.error : err)
            @test occursin("conformance_dup", message)
        end

        # ------------------------------------------------------------------
        # Panic containment, and the finalizer, through every door (#244, #249).
        # ------------------------------------------------------------------
        @testset "panic and lifetime behave the same on every door" begin
            doors = Pair{String, String}[]
            push!(doors, "direct rustc" => """
                #[julia]
                fn conformance_boom_rustc(a: i32) -> i32 {
                    if a < 0 { panic!("boom {}", a); }
                    a
                }

                #[julia]
                pub struct ConformanceOwnedRustc { pub value: i32 }

                impl ConformanceOwnedRustc {
                    pub fn new(value: i32) -> Self { ConformanceOwnedRustc { value } }
                    pub fn doubled(&self) -> i32 { self.value * 2 }
                }
                """)
            if _CONF_CARGO
                push!(doors, "cargo" => """
                    // cargo-deps: libc="0.2"

                    #[julia]
                    fn conformance_boom_cargo(a: i32) -> i32 {
                        if a < 0 { panic!("boom {}", a); }
                        a
                    }

                    #[julia]
                    pub struct ConformanceOwnedCargo { pub value: i32 }

                    impl ConformanceOwnedCargo {
                        pub fn new(value: i32) -> Self { ConformanceOwnedCargo { value } }
                        pub fn doubled(&self) -> i32 { self.value * 2 }
                    }
                    """)
            end

            for (door, source) in doors
                mod = Module(Symbol("Conformance_" * replace(door, " " => "_")))
                Core.eval(mod, :(using RustCall))
                # `rust"""` is a string macro: it needs a literal, so the block
                # is built as text and parsed inside the module.
                Core.eval(mod, Meta.parse("rust\"\"\"\n" * source * "\n\"\"\""))

                fname = Symbol("conformance_boom_" * (door == "cargo" ? "cargo" : "rustc"))
                sname = Symbol("ConformanceOwned" * (door == "cargo" ? "Cargo" : "Rustc"))

                # Panic: caught, and the same exception type on every door.
                @test Core.eval(mod, :($fname(Int32(4)))) == Int32(4)
                thrown = try
                    Core.eval(mod, :($fname(Int32(-1))))
                    nothing
                catch e
                    e
                end
                @test thrown isa RustCall.RustPanicError
                @test occursin("boom -1", thrown.message)
                # ...and the library still works afterwards.
                @test Core.eval(mod, :($fname(Int32(5)))) == Int32(5)

                # Lifetime: the object frees, and its finalizer holds a
                # captured destructor rather than a lookup.
                obj = Core.eval(mod, :($sname(Int32(1))))
                @test getfield(obj, :free_ptr) != C_NULL
                @test getfield(obj, :alive)[]
                # `invokelatest`: the accessors were defined by the `Core.eval`
                # a few lines up, so they live in a newer world age than this
                # (already running) test function.
                @test Base.invokelatest(getproperty, obj, :value) == Int32(1)
                finalize(obj)
                @test getfield(obj, :ptr) == C_NULL
                # A field read on a finalized object raises rather than
                # dereferencing C_NULL inside Rust (#249).
                @test_throws RustCall.RustError Base.invokelatest(getproperty, obj, :value)
            end

            @test RustCall.finalizer_failure_count() == 0
        end

        # ------------------------------------------------------------------
        # The third door: `@rust_crate`. It reaches the same boundary — which
        # it did not until the crate wrappers learned to read the panic
        # channel (the in-memory module and the emitted template both).
        # ------------------------------------------------------------------
        if !_CONF_CARGO
            @test_skip "cargo is required for the @rust_crate conformance test"
        else
            @testset "@rust_crate reaches the same boundary" begin
                crate = joinpath(dirname(dirname(pathof(RustCall))),
                                 "examples", "sample_crate")
                if !isdir(crate)
                    @test_skip "examples/sample_crate not found"
                else
                    bindings = @rust_crate crate name="ConformanceCrate"

                    # The crate's library is in the registry, which it was not
                    # before B5: `@rust_crate` kept its handle module-locally
                    # and `unload_library` could not see it (#250).
                    crate_libs = filter(n -> startswith(n, "rust_crate_"),
                                        RustCall.list_loaded_libraries())
                    @test !isempty(crate_libs)

                    @test Base.invokelatest(bindings.add, Int32(2), Int32(3)) == Int32(5)

                    thrown = try
                        Base.invokelatest(bindings.panicky, Int32(-4))
                        nothing
                    catch e
                        e
                    end
                    @test thrown isa RustCall.RustPanicError
                    @test occursin("negative value: -4", thrown.message)
                    # ...and the library still works.
                    @test Base.invokelatest(bindings.panicky, Int32(5)) == Int32(10)

                    # A failed `assert!` in a crate function, and a panicking
                    # method, reach it too.
                    @test_throws RustCall.RustPanicError Base.invokelatest(
                        bindings.panicky_assert, Int32(-1))
                    @test_throws RustCall.RustPanicError Base.invokelatest(
                        bindings.panicky_string, Int32(-1))

                    counter = Base.invokelatest(bindings.PanicCounter, Int32(-2))
                    @test_throws RustCall.RustPanicError Base.invokelatest(
                        bindings.checked, counter)
                    ok = Base.invokelatest(bindings.PanicCounter, Int32(4))
                    @test Base.invokelatest(bindings.checked, ok) == Int32(4)

                    # And the lifetime rule holds on this door as well.
                    @test getfield(counter, :free_ptr) != C_NULL
                    @test getfield(counter, :alive)[]
                    finalize(counter)
                    @test getfield(counter, :ptr) == C_NULL
                    @test RustCall.finalizer_failure_count() == 0

                    # The module does not hold a *raw* handle: unloading the
                    # library empties its mirror, so the next call reports
                    # "not loaded" instead of `dlsym`ing a closed image (#277).
                    crate_lib = first(crate_libs)
                    survivor = Base.invokelatest(bindings.PanicCounter, Int32(3))
                    RustCall.unload_library(crate_lib)
                    err = try
                        Base.invokelatest(bindings.add, Int32(1), Int32(1))
                        nothing
                    catch e
                        e
                    end
                    @test err !== nothing
                    message = sprint(showerror, err)
                    @test occursin("not loaded", message)
                    @test occursin(crate_lib, message)

                    # An object that outlived its library is inert rather than
                    # a call into unmapped code, and does not double-free.
                    @test !getfield(survivor, :alive)[]
                    failures = RustCall.finalizer_failure_count()
                    finalize(survivor)
                    finalize(survivor)
                    @test getfield(survivor, :ptr) == C_NULL
                    @test RustCall.finalizer_failure_count() == failures
                end
            end
        end
    end
end
