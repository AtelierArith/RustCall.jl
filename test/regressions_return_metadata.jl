# Component tests loaded by test_regressions.jl.

# #279 follow-up: the alias must carry the return-type hints too, not just the
# symbol mappings. Otherwise an untyped `@rust f(...)` through the stored name
# misses the library-scoped entry and either takes another library's answer or
# none at all, instead of the type the aliased block declared.
@testset "#279: an aliased library keeps its return-type hints" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping alias return-type test"
        return
    end

    # Two blocks declaring the same Rust name with different return types.
    expanded_i32 = RustCall.expand_inline("""
    #[julia]
    pub fn alias_typed(x: i32) -> i32 { x }
    """)
    expanded_f64 = RustCall.expand_inline("""
    #[julia]
    pub fn alias_typed(x: i32) -> f64 { x as f64 }
    """)
    path_i32 = RustCall.compile_rust_to_shared_lib(expanded_i32.source)
    path_f64 = RustCall.compile_rust_to_shared_lib(expanded_f64.source)
    lib_i32 = "test279_ret_i32_" * string(hash(path_i32), base = 16)
    lib_f64 = "test279_ret_f64_" * string(hash(path_f64), base = 16)
    stored = "test279_ret_stored_" * string(hash(path_i32), base = 16)
    handle_i32 = Libdl.dlopen(path_i32, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    handle_f64 = Libdl.dlopen(path_f64, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)

    try
        RustCall._register_manifest(expanded_i32, lib_i32; handle = handle_i32, set_current = false)
        RustCall._register_manifest(expanded_f64, lib_f64; handle = handle_f64, set_current = false)
        @test RustCall.get_function_return_type(lib_i32, "alias_typed") === Int32
        @test RustCall.get_function_return_type(lib_f64, "alias_typed") === Float64
        # Two libraries declare the name, so a third gets no answer at all
        # rather than an arbitrary one.
        @test RustCall.get_function_return_type("test279_ret_unknown", "alias_typed") === nothing

        # Aliasing the i32 block must give the alias *its* type, not the other
        # block's and not nothing.
        RustCall._alias_reloaded_library(Main, stored, lib_i32)
        @test RustCall.get_function_return_type(stored, "alias_typed") === Int32
        @test RustCall.exported_symbol(stored, "alias_typed") == "rustcall_alias_typed"
    finally
        for name in (stored, lib_i32, lib_f64)
            lock(RustCall.REGISTRY_LOCK) do
                delete!(RustCall.RUST_LIBRARIES, name)
                RustCall.clear_library_metadata!(name)
            end
        end
        Libdl.dlclose(handle_i32)
        Libdl.dlclose(handle_f64)
    end
end

# #279 follow-up: the in-memory hit re-registers a library's volatile tables.
# The existence check and the registration must be one transaction, or an
# unload racing between them leaves metadata and `CURRENT_LIB[]` pointing at a
# library that is no longer in `RUST_LIBRARIES`.
@testset "#279: re-registering an unloaded library is refused" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping unload-race test"
        return
    end

    expanded = RustCall.expand_inline("""
    #[julia]
    pub fn raced_probe(x: i32) -> i32 { x + 2 }
    """)
    path = RustCall.compile_rust_to_shared_lib(expanded.source)
    lib_name = "test279_raced_" * string(hash(path), base = 16)
    handle = Libdl.dlopen(path, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    previous_current = RustCall.get_current_library()

    try
        RustCall._register_manifest(expanded, lib_name; handle = handle, set_current = false)
        @test RustCall.exported_symbol(lib_name, "raced_probe") == "rustcall_raced_probe"

        # The library goes away between a caller's `haskey` and its
        # re-registration; the guarded call must decline rather than register
        # metadata for a name that is no longer loaded.
        RustCall.unload_library(lib_name)
        @test !haskey(RustCall.RUST_LIBRARIES, lib_name)
        @test !RustCall._register_manifest(expanded, lib_name; require_loaded = true)

        # Nothing was left behind, and CURRENT_LIB does not dangle.
        @test RustCall.exported_symbol(lib_name, "raced_probe") == "raced_probe"
        @test RustCall.get_function_return_type(lib_name, "raced_probe") === nothing
        @test RustCall.get_current_library() != lib_name

        # Without the guard the caller is the one publishing the handle, which
        # is still allowed and still atomic.
        handle2 = Libdl.dlopen(path, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
        @test RustCall._register_manifest(expanded, lib_name; handle = handle2, set_current = false)
        @test RustCall.exported_symbol(lib_name, "raced_probe") == "rustcall_raced_probe"
    finally
        haskey(RustCall.RUST_LIBRARIES, lib_name) && RustCall.unload_library(lib_name)
        lock(RustCall.REGISTRY_LOCK) do
            RustCall.clear_library_metadata!(lib_name)
            RustCall.CURRENT_LIB[] = previous_current
        end
    end
end

# #279 follow-up: a return-type hint must never outlive the library that
# registered it. There is no name-only table, so clearing or rebuilding a
# library cannot leave its type answering for anyone else's function of the
# same name.
@testset "#279: return-type hints do not outlive their library" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping stale return-type test"
        return
    end

    expanded_a = RustCall.expand_inline("""
    #[julia]
    pub fn stale_probe(x: i32) -> i32 { x }
    """)
    expanded_b = RustCall.expand_inline("""
    #[julia]
    pub fn stale_probe(x: i32) -> f64 { x as f64 }
    """)
    # The rebuilt A returns `Result`, for which no hint is recorded at all:
    # an untyped call must fall through to inference, never to A's old `Int32`.
    expanded_a2 = RustCall.expand_inline("""
    #[julia]
    pub fn stale_probe(x: i32) -> Result<i32, i32> { Ok(x) }
    """)

    path_a = RustCall.compile_rust_to_shared_lib(expanded_a.source)
    path_b = RustCall.compile_rust_to_shared_lib(expanded_b.source)
    path_a2 = RustCall.compile_rust_to_shared_lib(expanded_a2.source)
    lib_a = "test279_stale_a_" * string(hash(path_a), base = 16)
    lib_b = "test279_stale_b_" * string(hash(path_b), base = 16)
    handles = [Libdl.dlopen(p, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
               for p in (path_a, path_b, path_a2)]

    try
        RustCall._register_manifest(expanded_a, lib_a; handle = handles[1], set_current = false)
        RustCall._register_manifest(expanded_b, lib_b; handle = handles[2], set_current = false)
        @test RustCall.get_function_return_type(lib_a, "stale_probe") === Int32
        @test RustCall.get_function_return_type(lib_b, "stale_probe") === Float64

        # Clearing A leaves B answering for itself, and A answering for nobody.
        RustCall.unload_library(lib_a)
        @test RustCall.get_function_return_type(lib_b, "stale_probe") === Float64
        @test RustCall.get_function_return_type(lib_a, "stale_probe") === Float64 ||
              RustCall.get_function_return_type(lib_a, "stale_probe") === nothing

        # A comes back declaring `Result`, so it records no hint. The old
        # `Int32` must be gone: what answers is B's own type or nothing, never
        # the value A itself last wrote.
        RustCall._register_manifest(expanded_a2, lib_a; handle = handles[3], set_current = false)
        @test RustCall.get_function_return_type(lib_a, "stale_probe") !== Int32
        @test RustCall.get_function_return_type(lib_b, "stale_probe") === Float64

        # And with B gone too, nothing is left to answer at all.
        RustCall.unload_library(lib_b)
        @test RustCall.get_function_return_type(lib_a, "stale_probe") === nothing
    finally
        # Every handle here was published into RUST_LIBRARIES, and
        # `unload_library` dlcloses what it removes — closing them again here
        # would be a double close.
        for name in (lib_a, lib_b)
            haskey(RustCall.RUST_LIBRARIES, name) && RustCall.unload_library(name)
            RustCall.clear_library_metadata!(name)
        end
    end
end

# #279 follow-up: `_alias_reloaded_library` deliberately leaves one handle in
# `RUST_LIBRARIES` under two names. The cross-library fallback must not count
# that as two candidates, or every multi-block precompiled module raises the
# ambiguity error after any identity change.
@testset "#279: an aliased handle is one candidate, not an ambiguity" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping alias ambiguity test"
        return
    end

    expanded_one = RustCall.expand_inline("""
    #[julia]
    pub fn aliased_block_fn(x: i32) -> i32 { x * 2 }
    """)
    expanded_two = RustCall.expand_inline("""
    #[julia]
    pub fn sibling_block_fn(x: i32) -> i32 { x + 3 }
    """)
    path_one = RustCall.compile_rust_to_shared_lib(expanded_one.source)
    path_two = RustCall.compile_rust_to_shared_lib(expanded_two.source)
    actual = "test279_amb_actual_" * string(hash(path_one), base = 16)
    stored = "test279_amb_stored_" * string(hash(path_one), base = 16)
    sibling = "test279_amb_sibling_" * string(hash(path_two), base = 16)
    handle_one = Libdl.dlopen(path_one, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    handle_two = Libdl.dlopen(path_two, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)

    try
        RustCall._register_manifest(expanded_one, actual; handle = handle_one, set_current = false)
        RustCall._register_manifest(expanded_two, sibling; handle = handle_two, set_current = false)
        # The reload path: one handle, two names.
        RustCall._alias_reloaded_library(Main, stored, actual)
        @test RustCall.RUST_LIBRARIES[stored][1] == RustCall.RUST_LIBRARIES[actual][1]

        # Looking the aliased block's function up from the *sibling* block has
        # to fall back across libraries and finds it twice, through the same
        # handle. That is one function, not a conflict.
        ptr_via_sibling = RustCall.get_function_pointer(sibling, "aliased_block_fn")
        ptr_direct = RustCall.get_function_pointer(actual, "aliased_block_fn")
        ptr_via_alias = RustCall.get_function_pointer(stored, "aliased_block_fn")
        @test ptr_via_sibling == ptr_direct == ptr_via_alias
        @test RustCall.call_rust_function(ptr_via_sibling, Int32, Int32(4)) == Int32(8)

        # And the other block's function still resolves from the aliased names.
        ptr_sibling_fn = RustCall.get_function_pointer(stored, "sibling_block_fn")
        @test RustCall.call_rust_function(ptr_sibling_fn, Int32, Int32(4)) == Int32(7)

        # Two genuinely different libraries exporting one name are still refused.
        expanded_clash = RustCall.expand_inline("""
        #[julia]
        pub fn aliased_block_fn(x: i32) -> i32 { x * 5 }
        """)
        path_clash = RustCall.compile_rust_to_shared_lib(expanded_clash.source)
        clash = "test279_amb_clash_" * string(hash(path_clash), base = 16)
        handle_clash = Libdl.dlopen(path_clash, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
        try
            RustCall._register_manifest(expanded_clash, clash; handle = handle_clash, set_current = false)
            @test_throws ErrorException RustCall.get_function_pointer(sibling, "aliased_block_fn")
        finally
            haskey(RustCall.RUST_LIBRARIES, clash) && RustCall.unload_library(clash)
            RustCall.clear_library_metadata!(clash)
        end
    finally
        # `stored` and `actual` are two names for one handle: drop the alias
        # without unloading, so the handle is dlclosed exactly once (by
        # `unload_library(actual)`), and never again here.
        lock(RustCall.REGISTRY_LOCK) do
            delete!(RustCall.RUST_LIBRARIES, stored)
        end
        RustCall.clear_library_metadata!(stored)
        for name in (actual, sibling)
            haskey(RustCall.RUST_LIBRARIES, name) && RustCall.unload_library(name)
            RustCall.clear_library_metadata!(name)
        end
    end
end

# #279 follow-up: the pointer and the return type must come from the same
# library. A library whose `f` returns `Result` records no hint on purpose;
# another library's primitive hint for the same name would call it with the
# wrong ABI.
@testset "#279: a return-type hint is never borrowed across libraries" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping cross-library ABI test"
        return
    end

    # A: `Result` return, so no hint is registered at all.
    expanded_a = RustCall.expand_inline("""
    #[julia]
    pub fn abi_probe(x: i32) -> Result<i32, i32> { Ok(x) }
    """)
    # B: a plain f64 return, which does register a hint.
    expanded_b = RustCall.expand_inline("""
    #[julia]
    pub fn abi_probe(x: i32) -> f64 { x as f64 }
    """)
    path_a = RustCall.compile_rust_to_shared_lib(expanded_a.source)
    path_b = RustCall.compile_rust_to_shared_lib(expanded_b.source)
    lib_a = "test279_abi_a_" * string(hash(path_a), base = 16)
    lib_b = "test279_abi_b_" * string(hash(path_b), base = 16)
    handle_a = Libdl.dlopen(path_a, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    handle_b = Libdl.dlopen(path_b, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)

    try
        RustCall._register_manifest(expanded_a, lib_a; handle = handle_a, set_current = false)
        RustCall._register_manifest(expanded_b, lib_b; handle = handle_b, set_current = false)

        # A records nothing; B's Float64 must not leak into A.
        @test RustCall.get_function_return_type(lib_a, "abi_probe") === nothing
        @test RustCall.get_function_return_type(lib_b, "abi_probe") === Float64

        # The pointer and the owning library agree, for each library.
        ptr_a, owner_a = RustCall._resolve_call(lib_a, "abi_probe")
        ptr_b, owner_b = RustCall._resolve_call(lib_b, "abi_probe")
        @test owner_a == lib_a && owner_b == lib_b
        @test ptr_a != ptr_b

        # An untyped call into B uses B's own hint.
        @test RustCall._rust_call_dynamic(lib_b, "abi_probe", Int32(3)) == 3.0

        # An untyped call into A must not come back as B's `Float64`: with no
        # hint it falls through to inference, which for a `CResult_abi_probe`
        # return cannot produce a Float64.
        untyped_a = try
            RustCall._rust_call_dynamic(lib_a, "abi_probe", Int32(3))
        catch error
            error
        end
        @test !(untyped_a isa Float64)
    finally
        # `unload_library` dlcloses both handles; do not close them again.
        for name in (lib_a, lib_b)
            haskey(RustCall.RUST_LIBRARIES, name) && RustCall.unload_library(name)
            RustCall.clear_library_metadata!(name)
        end
    end
end

# #279 follow-up: an external crate is scanned leniently — only target
# predicates are decided, because its own features and build script are not
# RustCall's to evaluate — so mutually exclusive `#[cfg(feature = ...)]`
# variants of one `#[julia] fn` both reach the registry. Source order is not
# evidence of which one was built, so no return type may be registered for
# them; a wrong primitive hint would be a wrong ABI. (Deciding the crate's
# features exactly belongs to #277 Phase B.)
@testset "#279: ambiguous cfg variants register no return type" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping ambiguous cfg variant test"
        return
    end

    mktempdir() do dir
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "cfg_variant_probe"
        version = "0.0.0"
        edition = "2021"

        [features]
        a = []

        [lib]
        crate-type = ["cdylib"]
        """)
        write(joinpath(dir, "src", "lib.rs"), """
        use rustcall_julia_macros::julia;

        #[cfg(feature = "a")]
        #[julia]
        pub fn variant_probe() -> i32 { 1 }

        #[cfg(not(feature = "a"))]
        #[julia]
        pub fn variant_probe() -> f64 { 1.0 }

        #[julia]
        pub fn unambiguous_probe() -> i32 { 2 }
        """)

        # The lenient scan the crate paths use keeps both variants.
        info = RustCall.scan_crate(dir)
        variants = filter(f -> f.name == "variant_probe", info.julia_functions)
        @test length(variants) == 2
        @test Set(f.return_type for f in variants) == Set(["i32", "f64"])
        @test all(f -> f.symbol == "rustcall_variant_probe", variants)

        lib_name = "test279_cfg_variant"
        try
            metadata = RustCall.prepare_library_metadata(
                RustCall._manifest_registry_entries(info.julia_functions)...)
            lock(RustCall.REGISTRY_LOCK) do
                RustCall.install_library_metadata!(lib_name, metadata)
            end

            # The symbol is unambiguous, so it is recorded ...
            @test RustCall.exported_symbol(lib_name, "variant_probe") ==
                  "rustcall_variant_probe"
            # ... but neither variant's return type is, so an untyped call
            # falls through to inference rather than to the wrong ABI.
            @test RustCall.get_function_return_type(lib_name, "variant_probe") === nothing
            @test RustCall.get_function_return_type(lib_name, "rustcall_variant_probe") === nothing

            # A function with only one variant is unaffected.
            @test RustCall.exported_symbol(lib_name, "unambiguous_probe") ==
                  "rustcall_unambiguous_probe"
            @test RustCall.get_function_return_type(lib_name, "unambiguous_probe") === Int32
        finally
            RustCall.clear_library_metadata!(lib_name)
        end
    end
end
