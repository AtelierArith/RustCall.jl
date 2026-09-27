# Component tests loaded by test_regressions.jl.

# Since #279 a Rust item and the C symbol that exposes it can differ, and the
# mapping between them is recorded per library. It must stay that way: a
# library exporting `#[julia] fn f` as `rustcall_f` must not decide how a
# *different* library's plain `#[no_mangle] fn f` resolves, and unloading the
# first must not leave a mapping that redirects later lookups to a symbol that
# is gone.
@testset "#279: name -> symbol resolution is scoped to one library" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping per-library symbol resolution test"
        return
    end

    # Library A: `#[julia]`, so the C entry point is `rustcall_scoped_probe`
    # and the Rust name is not exported at all.
    expanded_a = RustCall.expand_inline("""
    #[julia]
    pub fn scoped_probe(x: i32) -> i32 { x + 1 }
    """)
    # Library B: a plain `#[no_mangle]` function of the same Rust name,
    # exported under that name.
    expanded_b = RustCall.expand_inline("""
    #[no_mangle]
    pub extern "C" fn scoped_probe(x: i32) -> i32 { x + 100 }
    """)

    path_a = RustCall.compile_rust_to_shared_lib(expanded_a.source)
    path_b = RustCall.compile_rust_to_shared_lib(expanded_b.source)
    lib_a = "test279_a_" * string(hash(path_a), base = 16)
    lib_b = "test279_b_" * string(hash(path_b), base = 16)
    handle_a = Libdl.dlopen(path_a, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    handle_b = Libdl.dlopen(path_b, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
    unloaded = Set{String}()
    unload!(name) = (name in unloaded || (push!(unloaded, name); RustCall.unload_library(name)))

    try
        lock(RustCall.REGISTRY_LOCK) do
            RustCall.RUST_LIBRARIES[lib_a] = (handle_a, Dict{String, Ptr{Cvoid}}())
            RustCall.RUST_LIBRARIES[lib_b] = (handle_b, Dict{String, Ptr{Cvoid}}())
        end
        RustCall._register_manifest(expanded_a, lib_a)
        RustCall._register_manifest(expanded_b, lib_b)

        # The mapping is not visible across libraries, and a library that
        # recorded nothing resolves the name to itself.
        @test RustCall.exported_symbol(lib_a, "scoped_probe") == "rustcall_scoped_probe"
        @test RustCall.exported_symbol(lib_b, "scoped_probe") == "scoped_probe"
        @test RustCall.exported_symbol("test279_unknown_lib", "scoped_probe") == "scoped_probe"
        # A's Rust name really is not a C symbol; B's really is.
        @test Libdl.dlsym(handle_a, "scoped_probe"; throw_error = false) === nothing
        @test Libdl.dlsym(handle_b, "rustcall_scoped_probe"; throw_error = false) === nothing

        # Both are callable and each resolves to its own library's symbol.
        ptr_a = RustCall.get_function_pointer(lib_a, "scoped_probe")
        ptr_b = RustCall.get_function_pointer(lib_b, "scoped_probe")
        @test ptr_a != ptr_b
        @test RustCall.call_rust_function(ptr_a, Int32, Int32(1)) == Int32(2)
        @test RustCall.call_rust_function(ptr_b, Int32, Int32(1)) == Int32(101)

        # Unloading A drops its mapping; B keeps resolving.
        unload!(lib_a)
        @test RustCall.exported_symbol(lib_a, "scoped_probe") == "scoped_probe"
        @test RustCall.exported_symbol(lib_b, "scoped_probe") == "scoped_probe"
        ptr_b_again = RustCall.get_function_pointer(lib_b, "scoped_probe")
        @test RustCall.call_rust_function(ptr_b_again, Int32, Int32(1)) == Int32(101)
    finally
        unload!(lib_a)
        unload!(lib_b)
    end
end

# #279 follow-up: a library handle and the name-to-symbol mappings its manifest
# describes must become visible together. Publishing the handle first left a
# window in which a concurrent `ensure_loaded` / `@rust f(...)` saw the library
# but not the mapping, and resolved `f` to `f` instead of `rustcall_f`.
@testset "#279: a library and its symbol mappings are published together" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping concurrent publication test"
        return
    end

    rust"""
    #[julia]
    pub fn concurrent_probe(x: i32) -> i32 { x * 7 }
    """
    lib_name = RustCall.get_current_library()

    # The mapping is in place for the library that is now current.
    @test RustCall.exported_symbol(lib_name, "concurrent_probe") == "rustcall_concurrent_probe"

    # Several tasks calling the attributed function concurrently: every call
    # resolves and returns, none races the publication of the handle.
    results = Vector{Int32}(undef, 32)
    @sync for i in 1:length(results)
        Threads.@spawn begin
            results[i] = concurrent_probe(Int32(i))
        end
    end
    @test results == Int32[i * 7 for i in 1:length(results)]

    # The same through `@rust`, which resolves the Rust name at call time.
    macro_results = Vector{Int32}(undef, 16)
    @sync for i in 1:length(macro_results)
        Threads.@spawn begin
            macro_results[i] = @rust concurrent_probe(Int32(i))::Int32
        end
    end
    @test macro_results == Int32[i * 7 for i in 1:length(macro_results)]

    # Reloading the very same block (the in-memory hit path) keeps the mapping.
    RustCall.ensure_loaded(lib_name, "#[julia]\npub fn concurrent_probe(x: i32) -> i32 { x * 7 }")
    @test RustCall.exported_symbol(lib_name, "concurrent_probe") == "rustcall_concurrent_probe"
    @test concurrent_probe(Int32(3)) == Int32(21)
end

# #279 follow-up: registering one loaded handle under a second name has to
# carry the name-to-symbol mappings over, or a lookup through the alias
# resolves `f` to `f`, misses `rustcall_f`, and falls back to the ambiguous
# cross-library search.
@testset "#279: an aliased library keeps its symbol mappings" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping alias mapping test"
        return
    end

    expanded = RustCall.expand_inline("""
    #[julia]
    pub fn aliased_probe(x: i32) -> i32 { x - 1 }
    """)
    path = RustCall.compile_rust_to_shared_lib(expanded.source)
    actual = "test279_actual_" * string(hash(path), base = 16)
    stored = "test279_stored_" * string(hash(path), base = 16)
    handle = Libdl.dlopen(path, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)

    try
        RustCall._register_manifest(expanded, actual; handle = handle, set_current = false)
        @test RustCall.exported_symbol(actual, "aliased_probe") == "rustcall_aliased_probe"
        # The alias has nothing of its own yet.
        @test RustCall.exported_symbol(stored, "aliased_probe") == "aliased_probe"

        RustCall._alias_reloaded_library(Main, stored, actual)
        @test RustCall.exported_symbol(stored, "aliased_probe") == "rustcall_aliased_probe"
        ptr = RustCall.get_function_pointer(stored, "aliased_probe")
        @test RustCall.call_rust_function(ptr, Int32, Int32(5)) == Int32(4)
        # The return-type hints travel with the mappings.
        @test RustCall.get_function_return_type(stored, "aliased_probe") === Int32

        # Dropping the alias must not disturb the library it pointed at.
        RustCall.clear_library_metadata!(stored)
        @test RustCall.exported_symbol(actual, "aliased_probe") == "rustcall_aliased_probe"
        @test RustCall.get_function_return_type(actual, "aliased_probe") === Int32
    finally
        for name in (stored, actual)
            lock(RustCall.REGISTRY_LOCK) do
                delete!(RustCall.RUST_LIBRARIES, name)
                RustCall.clear_library_metadata!(name)
            end
        end
        Libdl.dlclose(handle)
    end
end
