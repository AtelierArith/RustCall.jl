# Tests for the FFI manifest pipeline (issue #264): the rustcall-extract CLI is
# the only component that interprets Rust syntax; Julia consumes its manifest.
using RustCall
using Test
using TOML

@testset "FFI Manifest" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping manifest tests"
        return
    end

    @testset "extractor is available and versioned" begin
        exe = RustCall.extractor_path()
        @test isfile(exe)
        @test strip(read(`$exe schema-version`, String)) == string(RustCall.MANIFEST_SCHEMA_VERSION)
        @test length(RustCall.extractor_digest()) == 64
        @test length(RustCall.toolchain_fingerprint()) == 64
    end

    # Golden files may be checked out with CRLF on Windows; compare with LF only.
    _lf(x::AbstractString) = replace(String(x), "\r\n" => "\n")
    _lf(x::AbstractDict) = Dict{String, Any}(k => _lf(v) for (k, v) in x)
    _lf(x::AbstractVector) = Any[_lf(v) for v in x]
    _lf(x) = x

    @testset "CLI output matches the golden corpus" begin
        # The corpus is the Rust-side golden test; the CLI must produce exactly
        # the same manifests so the two front ends cannot drift apart.
        corpus = joinpath(dirname(@__DIR__), "deps", "rustcall_core", "tests", "corpus")
        sources = filter(f -> endswith(f, ".rs") && !endswith(f, ".expanded.rs"), readdir(corpus))
        @test !isempty(sources)
        for src in sources
            name = first(splitext(src))
            path = joinpath(corpus, src)
            for mode in ("inline", "crate")
                golden = joinpath(corpus, "$name.$mode.toml")
                isfile(golden) || continue
                # The corpus is platform independent: no cfg filtering here.
                got = _lf(RustCall.extract_manifest([path]; mode = mode, cfg = false))
                want = _lf(TOML.parsefile(golden))
                @test got == want
            end
            expanded_golden = joinpath(corpus, "$name.expanded.rs")
            if isfile(expanded_golden)
                got = RustCall.expand_inline(_lf(read(path, String)); cfg = false).source
                @test _lf(got) == _lf(read(expanded_golden, String))
            end
        end
    end

    @testset "#[cfg]-disabled items are not reported" begin
        # `any()` is never true, `all()` always is; `unix`/`windows` follow the host.
        code = """
        #[cfg(all())]
        #[julia]
        pub fn always_on() -> i32 { 1 }

        #[cfg(any())]
        #[julia]
        pub fn never_on() -> i32 { 2 }

        #[cfg(not(windows))]
        #[julia]
        pub fn on_unix_like() -> i32 { 3 }

        #[cfg(windows)]
        #[julia]
        pub fn on_windows() -> i32 { 4 }

        #[cfg(any())]
        #[julia]
        pub struct Ghost { pub x: i32 }

        #[cfg(any())]
        mod ghost_mod {
            #[julia]
            pub fn gone() -> i32 { 5 }
        }
        """
        names(m) = String[String(f["name"]) for f in m["functions"]]

        # Without cfg filtering every item is listed with its predicate.
        raw = RustCall.extract_manifest(code; mode = "inline", cfg = false)
        @test Set(names(raw)) == Set(["always_on", "never_on", "on_unix_like", "on_windows", "gone"])
        preds = Dict(String(f["name"]) => String(f["cfg"]) for f in raw["functions"])
        @test preds["always_on"] == "all()"
        @test preds["never_on"] == "any()"
        @test preds["on_windows"] == "windows"
        @test String(only(raw["structs"])["cfg"]) == "any()"

        # With the host configuration only compiled items remain.
        host = RustCall.extract_manifest(code; mode = "inline")
        expected = Sys.iswindows() ? ["always_on", "on_windows"] : ["always_on", "on_unix_like"]
        @test Set(names(host)) == Set(expected)
        @test isempty(host["structs"])
        crate = RustCall.extract_manifest(code; mode = "crate")
        @test Set(names(crate)) == Set(expected)

        expanded = RustCall.expand_inline(code)
        @test Set(s.name for s in RustCall.manifest_function_signatures(expanded.manifest)) == Set(expected)
        @test !occursin("never_on", expanded.source)
        @test !occursin("Ghost", expanded.source)
        @test !occursin("ghost_mod", expanded.source)

        # Cache keys differ for the two views of the same source.
        @test RustCall.expand_inline(code; cfg = false).manifest != expanded.manifest
        @test RustCall.expand_inline(code) === expanded

        # The cfg file handed to the extractor is `rustc --print cfg` under the
        # flags of the actual compiler invocation, written once per flag set.
        args = RustCall._cfg_file_args(:strict)
        @test length(args) == 2 && args[1] == "--cfg-file"
        @test read(args[2], String) == RustCall._rustc_cfg_text()
        @test RustCall._cfg_file_args(true) == args
        @test RustCall._cfg_file_args(:lenient) == vcat(args, ["--cfg-lenient"])
        @test isempty(RustCall._cfg_file_args(false))
        @test isempty(RustCall._cfg_file_args(:none))
        @test_throws ArgumentError RustCall._cfg_file_args(:bogus)
        flags = RustCall._cfg_rustc_flags()
        @test any(startswith("--target="), flags) && "panic=abort" in flags
        # Direct rustc builds use opt-level 2 and panic=abort, so the strict set
        # must reflect that rather than the bare toolchain defaults.
        strict = RustCall._rustc_cfg_text()
        @test occursin("panic=\"abort\"", strict)
        @test !occursin("debug_assertions", strict)
        @test occursin("debug_assertions", RustCall._rustc_cfg_text(String["-C", "opt-level=0"]))

        # Profile predicates follow the real compiler flags.
        profile_code = """
        #[cfg(debug_assertions)]
        #[julia]
        pub fn dbg_only() -> i32 { 1 }
        #[cfg(panic = "abort")]
        #[julia]
        pub fn abort_only() -> i32 { 2 }
        #[cfg(feature = "extra")]
        #[julia]
        pub fn feature_only() -> i32 { 3 }
        """
        strict_names = names(RustCall.extract_manifest(profile_code; mode = "inline"))
        @test Set(strict_names) == Set(["abort_only"])
        # Lenient (Cargo builds): only target predicates are decided; feature and
        # profile predicates keep their items.
        lenient_names = names(RustCall.extract_manifest(profile_code; mode = "crate", cfg = :lenient))
        @test Set(lenient_names) == Set(["dbg_only", "abort_only", "feature_only"])
        lenient_host = RustCall.extract_manifest(code; mode = "crate", cfg = :lenient)
        @test Set(names(lenient_host)) == Set(expected)
        @test RustCall.expand_inline(code; cfg = :lenient).manifest != RustCall.expand_inline(code).manifest ||
              Set(names(RustCall.expand_inline(code; cfg = :lenient).manifest)) == Set(expected)
    end

    if RustCall.check_rustc_available()
        @testset "#[cfg] end to end" begin
            rust"""
            #[cfg(not(windows))]
            #[julia]
            pub fn cfg_platform_value() -> i32 { 10 }

            #[cfg(windows)]
            #[julia]
            pub fn cfg_platform_value() -> i32 { 20 }

            #[cfg(any())]
            #[julia]
            pub fn cfg_never_compiled() -> i32 { 0 }
            """
            @test cfg_platform_value() == (Sys.iswindows() ? Int32(20) : Int32(10))
            # The manifest never saw the disabled item, so no Julia wrapper exists.
            @test !isdefined(@__MODULE__, :cfg_never_compiled)
        end
    end

    @testset "manifest is identical on cache hit and miss" begin
        code = """
        #[julia]
        fn manifest_twice(a: i32) -> i32 { a + 1 }
        """
        first_run = RustCall.extract_manifest(code; mode = "inline")
        second_run = RustCall.extract_manifest(code; mode = "inline")
        @test first_run == second_run
        # expand_inline memoizes per source text
        @test RustCall.expand_inline(code).manifest == first_run
    end

    @testset "failed extraction leaves nothing behind" begin
        bad = "#[julia] fn broken(a: i32 -> i32 { a }"
        @test_throws RustCall.ExtractorError RustCall.expand_inline(bad)
        @test !haskey(RustCall._EXPANSION_CACHE, bad)
        @test_throws RustCall.ExtractorError RustCall.extract_manifest(bad; mode = "crate")
        # a later, valid block is unaffected
        good = "#[julia] fn fine(a: i32) -> i32 { a }"
        @test length(RustCall.manifest_function_signatures(RustCall.expand_inline(good).manifest)) == 1
    end

    @testset "Cargo block identity includes the dependency set" begin
        src = "#[no_mangle] pub extern \"C\" fn dep_probe() -> i32 { 1 }"
        d1 = RustCall.hash_dependencies([RustCall.DependencySpec("rand", version = "0.8")])
        d2 = RustCall.hash_dependencies([RustCall.DependencySpec("rand", version = "0.9")])
        d3 = RustCall.hash_dependencies([RustCall.DependencySpec("rand", version = "0.8", features = ["small_rng"])])
        @test RustCall._cargo_block_identity(src, d1) == RustCall._cargo_block_identity(src, d1)
        @test RustCall._cargo_block_identity(src, d1) != RustCall._cargo_block_identity(src, d2)
        @test RustCall._cargo_block_identity(src, d1) != RustCall._cargo_block_identity(src, d3)
    end

    @testset "cache keys include the toolchain fingerprint" begin
        compiler = RustCall.get_default_compiler()
        code = "#[no_mangle] pub extern \"C\" fn fp_probe() -> i32 { 1 }"
        key_before = RustCall.generate_cache_key(code, compiler)
        saved = RustCall._TOOLCHAIN_FINGERPRINT[]
        try
            RustCall._TOOLCHAIN_FINGERPRINT[] = "0"^64
            key_after = RustCall.generate_cache_key(code, compiler)
            @test key_after != key_before
        finally
            RustCall._TOOLCHAIN_FINGERPRINT[] = saved
        end
        @test RustCall.generate_cache_key(code, compiler) == key_before
    end

    @testset "direct rustc fast path for plain extern \"C\" blocks" begin
        # Blocks without #[julia] still compile through rustc directly; the
        # expanded source is the original items (no wrappers injected).
        code = """
        #[no_mangle]
        pub extern "C" fn fast_path_add(a: i32, b: i32) -> i32 { a + b }
        """
        expanded = RustCall.expand_inline(code)
        @test occursin("fast_path_add", expanded.source)
        @test !occursin("CResult", expanded.source)
        sigs = RustCall.manifest_function_signatures(expanded.manifest; only_attributed = false)
        @test length(sigs) == 1 && sigs[1].attribute == :none && sigs[1].exported
        rust"""
        #[no_mangle]
        pub extern "C" fn fast_path_add(a: i32, b: i32) -> i32 { a + b }
        """
        @test (@rust fast_path_add(Int32(2), Int32(3))) == 5
    end

    @testset "Result / Option through inline #[julia] functions" begin
        rust"""
        #[julia]
        fn manifest_div(a: f64, b: f64) -> Result<f64, i32> {
            if b == 0.0 { Err(-1) } else { Ok(a / b) }
        }

        #[julia]
        fn manifest_maybe(a: i32) -> Option<i32> {
            if a > 0 { Some(a) } else { None }
        }
        """
        ok = manifest_div(1.0, 4.0)
        @test ok isa RustCall.RustResult{Float64, Int32}
        @test RustCall.is_ok(ok) && RustCall.unwrap(ok) == 0.25
        err = manifest_div(1.0, 0.0)
        @test RustCall.is_err(err) && err.value == -1
        some = manifest_maybe(3)
        @test some isa RustCall.RustOption{Int32}
        @test RustCall.is_some(some) && RustCall.unwrap(some) == 3
        @test RustCall.is_none(manifest_maybe(-1))
    end

    @testset "#[julia] items inside inline modules" begin
        rust"""
        mod api {
            #[julia]
            pub fn mod_add(a: i32, b: i32) -> i32 { a + b }

            #[julia]
            pub struct ModPoint { x: f64 }

            impl ModPoint {
                pub fn new(x: f64) -> Self { Self { x } }
                pub fn get_x(&self) -> f64 { self.x }
            }
        }
        """
        @test mod_add(Int32(2), Int32(3)) == 5
        p = ModPoint(1.5)
        @test p.x == 1.5
        @test get_x(p) == 1.5

        # Generic items inside a module are specialized in place, so sibling
        # items and `use` imports stay in scope during monomorphization.
        rust"""
        mod gen {
            use std::ops::Add;
            fn offset() -> i32 { 100 }
            pub fn mod_twice<T: Add<Output = T> + Copy>(x: T) -> T { x + x }
            fn uses_twice() -> i32 { mod_twice(2) }
            pub fn mod_offset<T: Into<i32>>(x: T) -> i32 { let v: i32 = x.into(); v + offset() }

            #[julia]
            pub struct Cell<T> { value: T }
            impl<T: Copy> Cell<T> {
                pub fn new(value: T) -> Self { Self { value } }
                pub fn get(&self) -> T { self.value }
            }
        }
        """
        @test (@rust mod_twice(Int32(21))) == 42
        @test (@rust mod_offset(Int32(5))) == 105
        c = Cell{Int64}(Int64(9))
        @test get(c) == 9

        # impl block renaming the struct parameter (impl<U> Holder<U>)
        rust"""
        #[julia]
        pub struct Holder<T> { value: T }
        impl<U: Copy> Holder<U> {
            pub fn new(value: U) -> Self { Self { value } }
            pub fn value(&self) -> U { self.value }
        }
        """
        h = Holder{Int32}(Int32(11))
        @test value(h) == 11
        @test h.value == 11
    end

    @testset "syntax that broke the old parsers (#169, #177/#201, #184, #233)" begin
        rust"""
        // #177 / #201: nested block comments inside a function body
        #[julia]
        fn nested_comment_fn(a: i32) -> i32 {
            /* outer /* inner */ } still a comment */
            let s = r#"{ not a brace "#;
            let _ = s;
            a * 2
        }

        // #233: const expression containing `<` in a type
        #[julia]
        fn const_expr_len(x: [u8; { if 1 < 2 { 3 } else { 4 } }]) -> i32 {
            x.len() as i32
        }

        // #169 / #184: where clause and nested generics on a #[julia] struct
        #[julia]
        pub struct Bag<T> where T: Copy {
            items: Vec<Option<T>>,
            first: T,
        }

        impl<T> Bag<T> where T: Copy {
            pub fn new(first: T) -> Self { Self { items: Vec::new(), first } }
            pub fn first(&self) -> T { self.first }
        }
        """
        @test nested_comment_fn(Int32(21)) == 42
        infos = RustCall.manifest_struct_infos(RustCall.expand_inline("""
        #[julia]
        pub struct Bag<T> where T: Copy { items: Vec<Option<T>>, first: T }
        impl<T> Bag<T> where T: Copy {
            pub fn new(first: T) -> Self { Self { items: Vec::new(), first } }
            pub fn first(&self) -> T { self.first }
        }
        """).manifest)
        @test only(infos).fields == [("items", "Vec<Option<T>>"), ("first", "T")]
        @test only(infos).constraints[:T].bounds[1].trait_name == "Copy"
        b = Bag{Int32}(Int32(5))
        @test first(b) == 5
    end
end
