# Component tests loaded by test_regressions.jl.

# #247: the monomorphization key sorted the type *values*, so which parameter
# got which type never reached the key. `pair<T=i32, U=i64>` and
# `pair<T=i64, U=i32>` shared one MONOMORPHIZED_FUNCTIONS entry (and one symbol
# suffix), and the second call ran the first one's machine code.
@testset "#247: permuted generic parameters do not share an instantiation" begin
    info = RustCall.GenericFunctionInfo(
        "rc247_reg_pair", "pub fn rc247_reg_pair<T, U>(a: T, b: U) -> T { let _ = b; a }",
        [:T, :U], Dict{Symbol, RustCall.TypeConstraints}(), "", ["T", "U"], "T",
        "rc247_reg_pair", nothing, "")
    compiler = RustCall.get_default_compiler()
    ab = Dict{Symbol, Type}(:T => Int32, :U => Int64)
    ba = Dict{Symbol, Type}(:T => Int64, :U => Int32)

    id_ab = RustCall._monomorphization_id(info, "rc247_reg_pair", ab, compiler)
    id_ba = RustCall._monomorphization_id(info, "rc247_reg_pair", ba, compiler)
    @test id_ab.type_params == ["T" => "Int32", "U" => "Int64"]
    @test id_ba.type_params == ["T" => "Int64", "U" => "Int32"]
    @test RustCall.artifact_key(id_ab) != RustCall.artifact_key(id_ba)
    # The registry that used to collide is now keyed by that value.  Registry
    # views are backed by RustCall.STATE (#251), rather than naked Dict globals.
    @test RustCall.MONOMORPHIZED_FUNCTIONS isa RustCall.StateView
end

# #278 B6: a precompiled module stores the *inputs* of a `rust"""` block, never
# a key — `toolchain` and `compiler` are properties of the loading session, so a
# stored key would pin a rustc that may since have been upgraded. The name a
# later session derives therefore routinely differs from the stored one, and
# `_resolve_lib` has to rebind the registry entry rather than only alias it.
@testset "#278: a reloaded block rebinds its stored name" begin
    @test RustCall.RustBlockSnapshot("fn f() {}", "", "t", 2).artifact_schema ==
          RustCall.ARTIFACT_ID_SCHEMA_VERSION
    @test RustCall.RustBlockSnapshot("fn f() {}", "", "t", 2, "").cargo_env == ""
    @test RustCall.RustBlockSnapshot("fn f() {}", "", "t", 2, nothing, 0).artifact_schema == 0

    if RustCall.check_rustc_available()
        code = """
        #[no_mangle]
        pub extern "C" fn rc278_snapshot_probe() -> i32 { 7 }
        """
        compiler = RustCall.get_default_compiler()
        cfg = RustCall._cfg_snapshot(:strict)
        actual = RustCall._compile_and_load_rust(code, "snapshot", 0; cfg_text = cfg,
                                                 compiler_target = compiler.target_triple,
                                                 compiler_level = compiler.optimization_level)
        block = RustCall.RustBlockSnapshot(code, cfg, compiler.target_triple,
                                           compiler.optimization_level)
        @test RustCall.ensure_loaded(actual, block) == actual

        # A stale name that happens to be registered short-circuits ...
        stale = "rust_rc278_stale_name"
        lock(RustCall.REGISTRY_LOCK) do
            RustCall.RUST_LIBRARIES[stale] = RustCall.RUST_LIBRARIES[actual]
        end
        try
            @test RustCall.ensure_loaded(stale, block) == stale
            # ... unless the snapshot predates the current identity encoding,
            # in which case the stored name is not evidence of anything:
            # recompute, and let the caller alias. Never an error.
            old = RustCall.RustBlockSnapshot(code, cfg, compiler.target_triple,
                                             compiler.optimization_level, nothing, 0)
            @test RustCall.ensure_loaded(stale, old) == actual

            # `_resolve_lib` rebinds __RUSTCALL_LIBS and the module's active
            # library to the name the manifest was registered under, keeping the
            # alias in RUST_LIBRARIES for callers that still name the old one.
            mod = Module(:RC278ResolveProbe)
            Core.eval(mod, :(const __RUSTCALL_LIBS = Dict{String, Any}()))
            Core.eval(mod, :(const __RUSTCALL_ACTIVE_LIB = Ref("")))
            # The bindings were defined a moment ago, in a newer world than the
            # one this code was compiled in. Julia 1.12 warns on a direct
            # `getfield` here ("in a world prior to its definition world") and
            # says it will error in a future version, so read them the same way
            # `_resolve_lib` does — `@invokelatest`.
            libs = @invokelatest getfield(mod, :__RUSTCALL_LIBS)
            active = @invokelatest getfield(mod, :__RUSTCALL_ACTIVE_LIB)
            libs[stale] = old
            active[] = stale

            RustCall._resolve_lib(mod, "")
            @test haskey(libs, actual)
            @test !haskey(libs, stale)
            @test active[] == actual
            @test lock(() -> haskey(RustCall.RUST_LIBRARIES, stale), RustCall.REGISTRY_LOCK)
        finally
            lock(RustCall.REGISTRY_LOCK) do
                delete!(RustCall.RUST_LIBRARIES, stale)
                RustCall.clear_library_metadata!(stale)
            end
        end
    end
end

# #249: the free symbol is per-owner, so two libraries can both export
# `X_free_rust_string`. Picking it by name from a global table frees a buffer
# through the wrong allocator; it must be resolved inside the library that
# allocated the value.
@testset "#249: the free symbol is resolved inside the allocating library" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping per-library free-symbol test"
    else
        source = n -> """
        #[julia]
        pub struct Rc249X { }
        impl Rc249X {
            pub fn new() -> Self { Self { } }
            pub fn label(&self) -> String { "$n".to_string() }
        }
        """
        expanded_a = RustCall.expand_inline(source("alpha"))
        expanded_b = RustCall.expand_inline(source("beta"))
        path_a = RustCall.compile_rust_to_shared_lib(expanded_a.source)
        path_b = RustCall.compile_rust_to_shared_lib(expanded_b.source)
        lib_a = "test249_a_" * string(hash(path_a), base = 16)
        lib_b = "test249_b_" * string(hash(path_b), base = 16)
        handle_a = Libdl.dlopen(path_a, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
        handle_b = Libdl.dlopen(path_b, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
        try
            lock(RustCall.REGISTRY_LOCK) do
                RustCall.RUST_LIBRARIES[lib_a] = (handle_a, Dict{String, Ptr{Cvoid}}())
                RustCall.RUST_LIBRARIES[lib_b] = (handle_b, Dict{String, Ptr{Cvoid}}())
            end
            RustCall._register_manifest(expanded_a, lib_a)
            RustCall._register_manifest(expanded_b, lib_b)

            # Both libraries export the same free symbol — the name alone
            # cannot say which allocator owns a buffer.
            free_a = RustCall.get_function_pointer(lib_a, "Rc249X_free_rust_string")
            free_b = RustCall.get_function_pointer(lib_b, "Rc249X_free_rust_string")
            @test free_a != free_b

            # The generated call passes the *library* alongside the symbol, so
            # each buffer is released by the library that allocated it.
            info_a = only(RustCall.manifest_struct_infos(expanded_a.manifest))
            m = only(mm for mm in info_a.methods if mm.name == "label")
            c = RustCall.ffi_return_contract(m.return_type; abi = m.return_abi,
                                             owner = info_a.name)
            @test c.free_symbol == "Rc249X_free_rust_string"

            ptr_a = RustCall.call_rust_function(
                RustCall.get_function_pointer(lib_a, "rustcall_Rc249X_new"), Ptr{Cvoid})
            ptr_b = RustCall.call_rust_function(
                RustCall.get_function_pointer(lib_b, "rustcall_Rc249X_new"), Ptr{Cvoid})
            @test RustCall._call_rust_owned_string(lib_a, "rustcall_Rc249X_label",
                                                   c.free_symbol, ptr_a) == "alpha"
            @test RustCall._call_rust_owned_string(lib_b, "rustcall_Rc249X_label",
                                                   c.free_symbol, ptr_b) == "beta"
        finally
            RustCall.unload_library(lib_a)
            RustCall.unload_library(lib_b)
        end
    end
end
