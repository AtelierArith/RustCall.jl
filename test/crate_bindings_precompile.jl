# Component tests loaded by test_crate_bindings.jl.

@testset "Precompilation Support" begin
    if !isdir(SAMPLE_CRATE_PATH)
        @test_skip "Sample crate not found, skipping precompilation tests"
        return
    end

    # Check if cargo is available
    try
        run(pipeline(`$(cargo()) --version`, devnull))
    catch
        @test_skip "Cargo not available, skipping precompilation tests"
        return
    end

    # The registry name of a @rust_crate library names its build profile, so a
    # debug and a release build of one crate are two entries rather than one
    # that clobbers the other — the second used to replace the first's handle,
    # retire its liveness flag out from under live objects, and repoint its
    # module mirror at the other profile's image (#277).
    @testset "crate_library_name distinguishes the build profile" begin
        info = RustCall.scan_crate(SAMPLE_CRATE_PATH)
        release = RustCall.crate_library_name(info; release = true)
        debug = RustCall.crate_library_name(info; release = false)
        @test release != debug
        @test startswith(release, "rust_crate_$(info.name)_")
        @test startswith(debug, "rust_crate_$(info.name)_")
        # Same profile, same name — it is an identity, not a nonce.
        @test RustCall.crate_library_name(info; release = true) == release
        # ...and the default is the release profile, as everywhere else.
        @test RustCall.crate_library_name(info) == release

        # The emitted module carries the name of the profile it was built for.
        release_code = RustCall.emit_crate_module_code(info, "/tmp/r.so";
                                                       build_release = true)
        debug_code = RustCall.emit_crate_module_code(info, "/tmp/d.so";
                                                     build_release = false)
        # The name is part of the module's build record, and `_LIB_NAME` is
        # read from it (#474).
        record_of(code) = (m = Module(:CbRecord); Core.eval(m, Meta.parse("import RustCall as rustcall′RustCall"));
            Core.eval(m, Meta.parse(chopprefix(only(filter(
                l -> startswith(l, "const _BUILD_RECORD = "), split(code, '\n'))),
                "const _BUILD_RECORD = "))))
        @test record_of(release_code).lib_name == release
        @test record_of(debug_code).lib_name == debug
        @test occursin("const _LIB_NAME = _BUILD_RECORD.lib_name", release_code)

        # Two modules registered under the two names do not disturb each
        # other: separate registry entries, separate liveness flags, separate
        # mirrors — so unloading one leaves the other intact.
        policy = RustCall.crate_direct_policy()
        h1 = Ptr{Cvoid}(UInt(0xc0de0001))
        h2 = Ptr{Cvoid}(UInt(0xc0de0002))
        m1 = RustCall.CrateGenerationCell()
        m2 = RustCall.CrateGenerationCell()
        try
            RustCall.register_handle_mirror!(release, m1)
            RustCall.register_handle_mirror!(debug, m2)
            RustCall.adopt_artifact!(policy, h1; lib_name = release)
            RustCall.adopt_artifact!(policy, h2; lib_name = debug)
            @test m1[].handle == h1
            @test m2[].handle == h2
            @test m1[].alive !== m2[].alive

            RustCall.unload_artifact!(policy, release)
            @test m1[].handle == C_NULL
            @test !m1[].alive[]
            # The other profile is untouched.
            @test m2[].handle == h2
            @test m2[].alive[]
            @test haskey(RustCall.RUST_LIBRARIES, debug)
        finally
            lock(RustCall.REGISTRY_LOCK) do
                for name in (release, debug)
                    delete!(RustCall.RUST_LIBRARIES, name)
                    delete!(RustCall.ARTIFACT_ALIVE, name)
                    delete!(RustCall.HANDLE_MIRRORS, name)
                    delete!(RustCall.RETIRED_HANDLES, name)
                end
            end
        end
    end

    @testset "emit_crate_module_code" begin
        # Test generating module code as a string
        info = RustCall.scan_crate(SAMPLE_CRATE_PATH)

        # Test with absolute path
        code = RustCall.emit_crate_module_code(info, "/tmp/test_lib.so")
        @test occursin("module SampleCrate", code)
        @test occursin("const _LIB_PATH = \"/tmp/test_lib.so\"", code)
        @test occursin("function __init__()", code)
        # Since #277 Phase B5 the emitted module loads through the one loader
        # rather than calling dlopen itself, so the handle is registered and
        # `unload_library` can see this crate too (#250).
        @test occursin("RustCall.load_artifact!", code)
        @test !occursin("Libdl.dlopen", code)
        @test occursin("const _LIB_NAME = ", code)
        # ... and it opens a private generation copy, never `_LIB_PATH` itself:
        # that file is Cargo's output (or a copy of it), and a mapped image
        # cannot be overwritten on Windows (#309).
        @test occursin("RustCall.loadable_library_copy(_LIB_PATH)", code)
        @test !occursin("crate_direct_policy(), _LIB_PATH", code)
        # The module's state is ONE immutable record — handle, liveness flag
        # and generation published together — read once per call. Two `Ref`s
        # written under two different locks were not a snapshot (#277).
        @test occursin("const _LIB_GEN = rustcall′RustCall.StateView(:crate_generation, @__MODULE__)", code)
        @test !occursin("const _LIB_HANDLE", code)
        @test !occursin("const _LIB_ALIVE", code)
        # ...and `__init__` does not assign it after loading: the
        # `load_artifact!` transaction is what publishes the generation, and an
        # assignment after it would overwrite a concurrent reload's newer one.
        @test occursin("RustCall.register_handle_mirror!(_LIB_NAME, _LIB_GEN)", code)
        @test !occursin("_LIB_GEN[] = ", code)
        @test occursin("# Bindings format: $(RustCall.BINDINGS_FORMAT_VERSION)", code)
        # ...and its struct finalizers capture the destructor and the liveness
        # flag rather than resolving anything when they run (#249).
        @test occursin("_struct_generation(", code)
        @test occursin("rustcall′Base.finalizer(rustcall′RustCall.finalize_rust_object!, rustcall′obj)", code)
        @test !occursin("maxlog=10", code)

        # Test with relative path
        code_rel = RustCall.emit_crate_module_code(info, "lib/libtest.so", use_relative_path=true)
        @test occursin("const _LIB_PATH = rustcall′Base.joinpath(@__DIR__, \"lib/libtest.so\")", code_rel)

        # Test with custom module name
        code_named = RustCall.emit_crate_module_code(info, "/tmp/lib.so", module_name="CustomModule")
        @test occursin("module CustomModule", code_named)

        # A library the image imports by name that the loader would not find
        # (a PyO3 wrapper's Python DLL on Windows) is opened before it, through
        # `load_artifact!`. Process pinning is a separate generated constant:
        # plain wrappers leave the guarded preload path disabled, while a
        # Python-owned handle enables it to keep PyO3 callbacks mapped.
        @test !occursin("_PRELOAD_LIBRARIES", code)
        @test occursin("const _PIN_LIBRARY = false", code)
        @test occursin("_PIN_LIBRARY && rustcall′RustCall.preload_dependency!", code)
        code_pinned = RustCall.emit_crate_module_code(info, "/tmp/lib.so";
            pin_library = true)
        @test occursin("const _PIN_LIBRARY = true", code_pinned)
        code_preload = RustCall.emit_crate_module_code(info, "/tmp/lib.so";
            preload = ["C:\\\\Python312\\\\python312.dll"])
        @test occursin("const _PRELOAD_LIBRARIES = $(repr(("C:\\\\Python312\\\\python312.dll",)))",
                       code_preload)
        @test occursin("lib_name = _LIB_NAME, preload = _PRELOAD_LIBRARIES)", code_preload)
        @test !occursin("Libdl.dlopen", code_preload)
    end

    @testset "the plain path scans under the build's configuration (#307 review)" begin
        # A `#[cfg(feature = "x")] #[julia] fn` is in the lenient scan whether
        # or not `x` is on; the build has it only when `x` is on. The bindings
        # are emitted from a scan under the same cfg the build compiles with —
        # the requested feature set included — so the module never names a
        # symbol the library does not export.
        if !RustCall.check_rustc_available()
            @test_skip "cargo is required to probe a crate's configuration"
        else
            fn_names(info) = sort([f.name for f in info.julia_functions])
            mktempdir() do dir
                mkpath(joinpath(dir, "src"))
                write(joinpath(dir, "Cargo.toml"), """
                    [package]
                    name = "gated"
                    version = "0.1.0"
                    edition = "2021"

                    [features]
                    default = []
                    extra = []

                    [lib]
                    crate-type = ["cdylib"]

                    [workspace]
                    """)
                write(joinpath(dir, "src", "lib.rs"), """
                    #[julia]
                    pub fn base() -> i32 { 0 }

                    #[cfg(feature = "extra")]
                    #[julia]
                    pub fn extra() -> i32 { 1 }
                    """)
                lenient = RustCall.scan_crate(dir)
                @test fn_names(lenient) == ["base", "extra"]
                # Default build: `extra` is off, and the scan says so.
                default = RustCall._plain_scan_info(dir, lenient, String[], true, true)
                @test fn_names(default) == ["base"]
                # The requested build: `extra` is on, and the scan says so.
                with_extra = RustCall._plain_scan_info(dir, lenient, ["extra"], true, true)
                @test fn_names(with_extra) == ["base", "extra"]
                # `--no-default-features` alone changes nothing here, and the
                # debug profile is probed as debug.
                @test fn_names(RustCall._plain_scan_info(dir, lenient, String[], false, false)) ==
                      ["base"]
            end

            # The probe has the shape of the build. A crate *without* a cdylib is
            # built as the dependency of a generated `_julia_wrapper` root, whose
            # release profile replaces the crate's own — so the crate's
            # `[profile.release] debug-assertions = true` does not reach the
            # build, and a `#[cfg(debug_assertions)]` item is not bound. The
            # same crate with a cdylib is built as the root, its profile
            # applies, and the item is (#307 review).
            for (cdylib, expected) in ((false, ["base"]), (true, ["base", "checked"]))
                mktempdir() do dir
                    mkpath(joinpath(dir, "src"))
                    lib_table = cdylib ? "[lib]\ncrate-type = [\"cdylib\", \"rlib\"]\n" : ""
                    write(joinpath(dir, "Cargo.toml"), """
                        [package]
                        name = "profiled"
                        version = "0.1.0"
                        edition = "2021"

                        $lib_table
                        [profile.release]
                        debug-assertions = true

                        [workspace]
                        """)
                    write(joinpath(dir, "src", "lib.rs"), """
                        #[julia]
                        pub fn base() -> i32 { 0 }

                        #[cfg(debug_assertions)]
                        #[julia]
                        pub fn checked() -> i32 { 1 }
                        """)
                    lenient = RustCall.scan_crate(dir)
                    @test fn_names(lenient) == ["base", "checked"]
                    @test RustCall.crate_has_cdylib(dir) == cdylib
                    @test fn_names(RustCall._plain_scan_info(dir, lenient, String[], true, true)) ==
                          expected
                end
            end
        end
    end

    @testset "_emit_function_code" begin
        # Create a simple function signature
        func = RustCall.RustFunctionSignature(
            "add",
            ["a", "b"],
            ["i32", "i32"],
            "i32",
            false,
            String[]
        )

        code = RustCall._emit_function_code(func)
        @test occursin("function add(a, b)", code)
        @test occursin("export add", code)
        # Pointer and panic channel come from one snapshot of the module's
        # handle, so a call cannot straddle a hot reload (#277).
        @test occursin("_call_target(var\"#TC#fn#add\", \"add\")", code)
    end

    @testset "_emit_struct_code" begin
        # Create a simple struct info
        struct_info = RustCall.RustStructInfo(
            "Point",
            String[],
            [RustCall.RustMethod("new", true, false, ["x", "y"], ["f64", "f64"], "Self")],
            "",
            [("x", "f64"), ("y", "f64")],
            true,
            Dict{String, Bool}();
            # accessor symbols come from the manifest; supplied by hand here
            field_getters = Dict("x" => "Point_get_x", "y" => "Point_get_y"),
            field_setters = Dict("x" => "Point_set_x", "y" => "Point_set_y"),
        )

        code = RustCall._emit_struct_code(struct_info)
        @test occursin("mutable struct Point", code)
        @test occursin("ptr::rustcall′Base.Ptr{rustcall′Base.Cvoid}", code)
        @test occursin("finalizer", code)
        @test occursin("Point_free", code)
        @test occursin("export Point", code)
        @test occursin("Base.getproperty", code)
        @test occursin("Base.setproperty!", code)

        # Null pointer checks should be present in getproperty/setproperty!
        @test occursin("_check_not_freed", code)
    end

    @testset "_check_not_freed" begin
        # Test that _check_not_freed is defined
        @test isdefined(RustCall, :_check_not_freed)

        # Create a mock object with a non-null ptr
        obj_alive = (ptr = Ptr{Cvoid}(1),)
        @test_nowarn RustCall._check_not_freed(obj_alive, "TestType")

        # Create a mock object with a null ptr (freed)
        obj_freed = (ptr = Ptr{Cvoid}(0),)
        # One implementation for both flavours since #277 Phase B4, so the
        # exception is RustCall's own rather than a bare `error()`.
        @test_throws RustCall.RustError RustCall._check_not_freed(obj_freed, "TestType")

        # Verify error message mentions the type name
        err = try
            RustCall._check_not_freed(obj_freed, "MyStruct")
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        @test occursin("MyStruct", err.message)
        @test occursin("freed", err.message)
    end

    @testset "_emit_method_code null pointer checks" begin
        # Instance method should contain null pointer check
        method = RustCall.RustMethod("get_sum", false, true, String[], String[], "f64")
        struct_info = RustCall.RustStructInfo(
            "Point",
            String[],
            [method],
            "",
            [("x", "f64"), ("y", "f64")],
            true,
            Dict{String, Bool}()
        )

        code = RustCall._emit_method_code(struct_info, method)
        @test occursin("_check_not_freed", code)
    end

    # #279 follow-up: the six-argument `RustMethod` constructor cannot know the
    # struct name, so a hand-built method carries no `symbol`. The emitters must
    # derive `rustcall_<Struct>_<method>` rather than emit `_get_func_ptr("")`.
    @testset "hand-built RustMethod falls back to the rustcall_ symbol" begin
        ctor = RustCall.RustMethod("new", true, false, ["x", "y"], ["f64", "f64"], "Self")
        getter = RustCall.RustMethod("norm", false, false, String[], String[], "f64")
        shout = RustCall.RustMethod("shout", false, false, ["s"], ["String"], "String")
        @test ctor.symbol == ""
        @test RustCall.method_wrapper_symbol("Point", ctor) == "rustcall_Point_new"
        @test RustCall.method_wrapper_symbol("Point", getter) == "rustcall_Point_norm"
        # A manifest-backed symbol always wins over the derived one.
        manifest_backed = RustCall.RustMethod("norm", false, false, String[], String[], "f64";
                                              symbol = "rustcall_Other_norm")
        @test RustCall.method_wrapper_symbol("Point", manifest_backed) == "rustcall_Other_norm"

        struct_info = RustCall.RustStructInfo(
            "Point", String[], [ctor, getter, shout], "",
            [("x", "f64"), ("y", "f64")], true, Dict{String, Bool}()
        )

        # Source-text emitter (write_bindings_to_file).
        for m in struct_info.methods
            code = RustCall._emit_method_code(struct_info, m)
            # A constructor takes its snapshot through `_ctor_target`, which
            # also carries the destructor and the liveness flag the object it
            # allocates will capture (#277).
            resolver = m.returns_boxed_struct ? "_ctor_target" : "_call_target"
            # ...and the call site's own snapshot cache first (#253).
            cache = "var\"#TC#m#rustcall_Point_$(m.name)\""
            @test occursin("$(resolver)($cache, \"rustcall_Point_$(m.name)\"", code)
            @test !occursin("_call_target($cache, \"\"", code)
            @test !occursin("_ctor_target($cache, \"\"", code)
        end
        # The string buffers stay named after the method, not after the symbol
        # — and the function that releases the buffer is resolved *with* the
        # call, in the same snapshot, so a reload cannot make the buffer be
        # freed through the replacement image's allocator (#277).
        @test occursin("_call_target(var\"#TC#m#rustcall_Point_shout\", \"rustcall_Point_shout\", \"Point_shout_free_rust_string\")",
                       RustCall._emit_method_code(struct_info, shout))

        # In-memory emitter (@rust_crate).
        for m in struct_info.methods
            expr = string(RustCall._generate_crate_method_wrapper(struct_info, m))
            @test occursin("rustcall_Point_$(m.name)", expr)
            @test !occursin("_get_func_ptr(\"\")", expr)
        end

        # Julia struct emitter (inline blocks).
        defs = string(RustCall.emit_julia_definitions(struct_info))
        @test occursin("rustcall_Point_new", defs)
        @test occursin("rustcall_Point_norm", defs)
        @test !occursin("\"\"", defs)
    end

    @testset "an owned-String field getter snapshots its release function" begin
        # No struct in `sample_crate` has a `String` field, so the branch is
        # covered here: the getter and the function that releases the buffer it
        # returns must come from ONE snapshot. Two lookups by name could
        # straddle a hot reload, and the buffer would then be freed through the
        # replacement image's allocator (#277).
        info = RustCall.RustStructInfo(
            "Tagged", String[], RustCall.RustMethod[], "",
            [("label", "String")], true, Dict{String, Bool}();
            field_abis = Dict("label" => "string"),
            field_getters = Dict("label" => "rustcall_Tagged_label"),
            has_owned_string_helper = true,
        )

        code = RustCall._emit_struct_code(info)
        @test occursin("_call_target(var\"#TC#prop#rustcall_Tagged_label\", \"rustcall_Tagged_label\", \"Tagged_free_rust_string\")", code)
        @test occursin("_guard_panic(rustcall′RustCall.call_rust_function(rustcall′fp, rustcall′RustCall.CRustString, rustcall′Base.getfield(rustcall′self, :ptr)), rustcall′channel,", code)
        @test occursin("RustCall._take_owned_string(rustcall′raw, rustcall′freep)", code)
        # ...and never the two-lookup form it replaced.
        @test !occursin("_get_func_ptr(\"Tagged_free_rust_string\")", code)
        @test Meta.parse("module M\n" * code * "\nend") isa Expr

        # The in-memory emitter agrees.
        expr = string(RustCall._generate_crate_struct_wrapper(info))
        @test occursin("_call_target(var\"#TC#prop#rustcall_Tagged_label\", \"rustcall_Tagged_label\", \"Tagged_free_rust_string\")", expr)
    end

    @testset "_emit_struct_code finalizer is exception-safe" begin
        struct_info = RustCall.RustStructInfo(
            "SafeStruct",
            String[],
            RustCall.RustMethod[],
            "",
            [("val", "i32")],
            true,
            Dict{String, Bool}()
        )

        code = RustCall._emit_struct_code(struct_info)
        # The finalizer must not crash the GC (#93), and since #277 Phase B4 it
        # must also take no lock, resolve no symbol and log nothing (#249): a
        # finalizer can run while the running thread holds `REGISTRY_LOCK`, and
        # `@warn` allocates and can yield. The try/catch moved *into*
        # `RustCall.finalize_rust_object!`, which counts a failure instead of
        # logging it, and the destructor is captured at construction.
        @test occursin("rustcall′Base.finalizer(rustcall′RustCall.finalize_rust_object!, rustcall′obj)", code)
        # ...and the destructor is captured together with the liveness flag of
        # the generation that exports it, in one snapshot (#277).
        @test occursin("_struct_generation(var\"#TC#free#SafeStruct_free\", \"SafeStruct_free\")", code)
        @test occursin("alive::rustcall′Base.RefValue{rustcall′Base.Bool}", code)
        @test !occursin("Failed to free SafeStruct", code)
        @test !occursin("maxlog", code)
        # The shared implementation is the one that catches.
        body = read(joinpath(_SRC_DIR_CB, "structs.jl"), String)
        i = findfirst("function finalize_rust_object!", body)
        @test i !== nothing
        tail = body[first(i):end]
        tail = tail[1:first(findfirst("\nend", tail))]
        @test occursin("try", tail)
        @test occursin("catch", tail)
        @test !occursin("@warn", tail)
    end

    @testset "_generate_crate_struct_wrapper finalizer is exception-safe" begin
        struct_info = RustCall.RustStructInfo(
            "SafeWrapper",
            String[],
            RustCall.RustMethod[],
            "",
            [("val", "i32")],
            true,
            Dict{String, Bool}()
        )

        exprs = RustCall._generate_crate_struct_wrapper(struct_info)
        code_str = sprint(show, exprs)
        # Same shape as the emitted file: capture at construction, and the
        # exception safety lives in `finalize_rust_object!` (#93, #249).
        @test occursin("finalize_rust_object!", code_str)
        @test occursin("_struct_generation", code_str)
        @test !occursin("maxlog", code_str)
    end

    @testset "write_bindings_to_file" begin
        # Test writing bindings to a file
        output_dir = mktempdir()
        output_path = joinpath(output_dir, "TestBindings.jl")

        try
            result_path = RustCall.write_bindings_to_file(
                SAMPLE_CRATE_PATH,
                output_path,
                output_module_name = "TestBindings"
            )

            @test result_path == output_path
            @test isfile(output_path)

            # Read and verify content
            content = read(output_path, String)
            @test occursin("module TestBindings", content)
            @test occursin("# Auto-generated bindings", content)
            @test occursin("function __init__()", content)
            @test occursin("export", content)

            # Loading the written module leaves Cargo's output untouched: the
            # image it maps is a private generation copy, so the next
            # `cargo build` of the crate — hot reload, another binding path —
            # can still overwrite the file, which Windows refuses for a mapped
            # DLL (#309). Only *observed* here: `_LIB_PATH` is the shared
            # `test/fixtures/sample_crate` output that other workers of the
            # parallel phase build and load at the same time, so it is never
            # removed or rewritten by this test. The overwrite itself is
            # exercised in "write_bindings_to_file with relative path", on a
            # library that lives in that test's own temporary directory.
            sandbox = Module(:WrittenSandbox)
            Base.include(sandbox, output_path)
            mod = Base.invokelatest(getfield, sandbox, :TestBindings)
            built = Base.invokelatest(getfield, mod, :_LIB_PATH)
            gen = Base.invokelatest(getindex, Base.invokelatest(getfield, mod, :_LIB_GEN))
            loaded = Libdl.dlpath(gen.handle)
            @test isfile(built)
            @test realpath(loaded) != realpath(built)
            @test dirname(realpath(loaded)) == dirname(realpath(built))
            # `<lib>.rustcall.<host>.<pid>.<generation>.<ext>`: the process
            # id keeps two processes that load the same crate from choosing
            # one copy name, the host tag does the same across a shared
            # volume, and the marker is what the stale-copy sweep recognises.
            @test occursin(Regex("\\.rustcall\\.[0-9a-f]{12}\\.$(getpid())\\.[0-9a-f]{8}\\.\\d+\\.[A-Za-z]+\$"),
                           basename(loaded))
            @test Base.invokelatest(Base.invokelatest(getfield, mod, :add), 2, 3) == 5
            # The file names the format of the RustCall that wrote it — the
            # release's MAJOR.MINOR — and hands it back when included (#489).
            fmt = RustCall.BINDINGS_FORMAT_VERSION
            @test occursin("# Bindings format: $(fmt)\n", content)
            @test occursin("const _BINDINGS_FORMAT = rustcall′RustCall.check_bindings_format($(repr(fmt)))", content)
            @test Base.invokelatest(getfield, mod, :_BINDINGS_FORMAT) == fmt
            try
                RustCall.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
            catch
            end

            # The same file as another release would have written it is refused
            # when included, with the instruction to regenerate it (#489).
            current = VersionNumber(fmt)
            declared = "rustcall′RustCall.check_bindings_format($(repr(fmt)))"
            function refusal(text, tag)
                path = joinpath(output_dir, "Refused_$(tag).jl")
                write(path, text)
                err = try
                    Base.include(Module(Symbol("RefusedSandbox_", tag)), path)
                    nothing
                catch e
                    # `include` wraps it in a `LoadError`, `__init__` in an
                    # `InitError`: the refusal itself is underneath.
                    while e isa LoadError || e isa InitError
                        e = e.error
                    end
                    e
                end
                return err
            end
            for (tag, other) in (("minor", "$(current.major).$(current.minor + 1)"),
                                 ("major", "$(current.major + 1).$(current.minor)"))
                text = replace(content, "# Bindings format: $(fmt)" => "# Bindings format: $(other)",
                               declared => "rustcall′RustCall.check_bindings_format($(repr(other)))")
                err = refusal(text, tag)
                @test err isa RustCall.RustError
                err === nothing || @test occursin("write_bindings_to_file", sprint(showerror, err))
            end
            # Another patch of the same minor is the same format.
            patch = "$(current.major).$(current.minor).$(current.patch + 7)"
            @test RustCall.check_bindings_format(patch) == patch
            # A file of the retired integer format declares no
            # `_BINDINGS_FORMAT`; its `__init__` is refused when it registers
            # its generation mirror, before any library is loaded.
            legacy = replace(content, "# Bindings format: $(fmt)" => "# Bindings format: 13",
                             "const _BINDINGS_FORMAT = $(declared)\n" => "")
            @test !occursin("_BINDINGS_FORMAT", legacy)
            err = refusal(legacy, "integer")
            @test err isa RustCall.RustError
            if err !== nothing
                msg = sprint(showerror, err)
                @test occursin("integer format", msg)
                @test occursin("write_bindings_to_file", msg)
            end
        finally
            rm(output_dir, recursive=true, force=true)
        end
    end

    @testset "write_bindings_to_file with relative path" begin
        # Test writing bindings with relative library path
        output_dir = mktempdir()
        output_path = joinpath(output_dir, "src", "Bindings.jl")
        lib_rel_path = "../deps/lib"

        try
            result_path = RustCall.write_bindings_to_file(
                SAMPLE_CRATE_PATH,
                output_path,
                output_module_name = "RelativeBindings",
                relative_lib_path = lib_rel_path
            )

            @test result_path == output_path
            @test isfile(output_path)

            # Verify library was copied
            lib_dir = joinpath(output_dir, "src", lib_rel_path)
            @test isdir(lib_dir)
            libs = readdir(lib_dir)
            @test !isempty(libs)

            # Verify content uses relative path
            content = read(output_path, String)
            @test occursin("joinpath(@__DIR__", content)
            @test occursin(lib_rel_path, content)

            # The written module maps a private generation copy, never
            # `_LIB_PATH` itself, so the file it was written against can be
            # deleted and rewritten while the module is loaded — the operation
            # a `cargo build` or a regeneration needs and Windows refuses for
            # a mapped DLL (#309). `_LIB_PATH` here is the copy under this
            # test's own temporary directory, so no other worker sees the
            # removal.
            sandbox = Module(:RelativeSandbox)
            Base.include(sandbox, output_path)
            mod = Base.invokelatest(getfield, sandbox, :RelativeBindings)
            lib_path = Base.invokelatest(getfield, mod, :_LIB_PATH)
            gen = Base.invokelatest(getindex, Base.invokelatest(getfield, mod, :_LIB_GEN))
            loaded = Libdl.dlpath(gen.handle)
            @test isfile(lib_path)
            @test dirname(realpath(lib_path)) == realpath(lib_dir)
            @test realpath(loaded) != realpath(lib_path)
            @test dirname(realpath(loaded)) == realpath(lib_dir)
            @test occursin(Regex("\\.rustcall\\.[0-9a-f]{12}\\.$(getpid())\\.[0-9a-f]{8}\\.\\d+\\.[A-Za-z]+\$"),
                           basename(loaded))
            backup = joinpath(output_dir, basename(lib_path))
            cp(lib_path, backup; force = true)
            @test (rm(lib_path); !isfile(lib_path))
            cp(backup, lib_path; force = true)
            @test isfile(lib_path)
            # The module still works through its copy after the file went away
            # and came back.
            @test Base.invokelatest(Base.invokelatest(getfield, mod, :add), 2, 3) == 5
            try
                RustCall.unload_library(Base.invokelatest(getfield, mod, :_LIB_NAME); close = true)
            catch
            end
        finally
            rm(output_dir, recursive=true, force=true)
        end
    end
end
