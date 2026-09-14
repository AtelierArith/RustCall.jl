# Monomorphizations survive the session that built them, and a batch of them
# shares one library and one mapped image (#254).
#
# Before this, every instantiation was compiled by its own `rustc` invocation
# into its own temporary directory and mapped as its own image, and nothing was
# written to the artifact cache: restarting Julia rebuilt all of them.

using RustCall
using Test
using TOML

# The child sessions do the real work: the point of the feature is what
# survives a process boundary, and that cannot be observed in one process.
const GENERICS_CACHE_CHILD = raw"""
using RustCall

const CODE = "pub fn gc254_add<T: std::ops::Add<Output = T> + Copy>(x: T, y: T) -> T { x + y }"
const TYPES = Type[Int32, Int64, Float64]

RustCall.register_generic_function("gc254_add", CODE, [:T])
const COMPILER = RustCall.get_default_compiler()

function instantiation_key(T)
    info = RustCall.GENERIC_FUNCTION_REGISTRY["gc254_add"]
    return RustCall.artifact_key(RustCall._monomorphization_id(
        info, "gc254_add", Dict{Symbol, Type}(:T => T), COMPILER))
end

# Distinct `dlopen` handles behind the instantiation libraries: one per mapped
# image, however many registry names point at it.
function mapped_images()
    handles = Set{Ptr{Cvoid}}()
    for name in RustCall.list_loaded_libraries()
        startswith(name, "rust_generic") || continue
        push!(handles, RustCall.RUST_LIBRARIES[name][1])
    end
    return length(handles)
end

emit(key, value) = println("RESULT ", key, " ", value)

mode = ARGS[1]

if mode == "batch"
    RustCall.precompile_generics("gc254_add", TYPES...)
elseif mode == "restore"
    # Asked *before* anything is monomorphized: a restorable artifact is what
    # makes the compile in `monomorphize_function` unreachable.
    for T in TYPES
        emit("restorable_$(T)",
             RustCall._restore_generic_artifact(instantiation_key(T), "gc254_add") !== nothing)
    end
end

# `cp` into the cache would move these, so an unchanged pair is the evidence
# that nothing was rebuilt.
before = Dict(T => (p = RustCall.get_cached_library(instantiation_key(T));
                    p === nothing ? "" : string(mtime(p))) for T in TYPES)

infos = [RustCall.monomorphize_function("gc254_add", Dict{Symbol, Type}(:T => T)) for T in TYPES]

for (T, info) in zip(TYPES, infos)
    after = (p = RustCall.get_cached_library(instantiation_key(T));
             p === nothing ? "" : string(mtime(p)))
    emit("cached_$(T)", after != "")
    emit("untouched_$(T)", before[T] == after)
    emit("recorded_$(T)", RustCall.load_specialization_record(instantiation_key(T)) !== nothing)
end

emit("images", mapped_images())
emit("handles", length(unique(info.handle for info in infos)))
emit("add_i32", RustCall.call_generic_function("gc254_add", Int32(2), Int32(3)))
emit("add_i64", RustCall.call_generic_function("gc254_add", Int64(7), Int64(8)))
emit("add_f64", RustCall.call_generic_function("gc254_add", 1.5, 2.25))
"""

function run_generics_cache_child(script, cache_dir, mode)
    env = copy(ENV)
    env["RUSTCALL_CACHE_DIR"] = cache_dir
    cmd = setenv(`$(Base.julia_cmd()) --project=$(pkgdir(RustCall)) $script $mode`, env)
    out = read(cmd, String)
    results = Dict{String, String}()
    for line in eachsplit(out, '\n')
        parts = split(line, ' '; limit = 3)
        length(parts) == 3 && parts[1] == "RESULT" && (results[parts[2]] = parts[3])
    end
    return results
end

@testset "#254: a monomorphization outlives its session" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required to build a monomorphization"
    else
        mktempdir() do dir
            script = joinpath(dir, "generics_cache_child.jl")
            write(script, GENERICS_CACHE_CHILD)
            cache = joinpath(dir, "cache")

            built = run_generics_cache_child(script, cache, "build")
            # The first session compiles and publishes each instantiation.
            @test built["cached_Int32"] == "true"
            @test built["cached_Int64"] == "true"
            @test built["cached_Float64"] == "true"
            @test built["recorded_Int32"] == "true"
            @test built["recorded_Float64"] == "true"
            @test built["add_i32"] == "5"
            @test built["add_f64"] == "3.75"
            # Built one at a time, each into its own library: three images.
            @test built["images"] == "3"

            restored = run_generics_cache_child(script, cache, "restore")
            # The load-bearing assertion: every instantiation is restorable
            # before any of them is asked for, so no `rustc` runs at all.
            @test restored["restorable_Int32"] == "true"
            @test restored["restorable_Int64"] == "true"
            @test restored["restorable_Float64"] == "true"
            # And nothing was rebuilt over the cached libraries.
            @test restored["untouched_Int32"] == "true"
            @test restored["untouched_Int64"] == "true"
            @test restored["untouched_Float64"] == "true"
            # The restored instantiations are the same functions.
            @test restored["add_i32"] == "5"
            @test restored["add_i64"] == "15"
            @test restored["add_f64"] == "3.75"
        end
    end
end

@testset "#254: a batch is one library and one image" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required to build a monomorphization"
    else
        mktempdir() do dir
            script = joinpath(dir, "generics_cache_child.jl")
            write(script, GENERICS_CACHE_CHILD)
            cache = joinpath(dir, "cache")

            batched = run_generics_cache_child(script, cache, "batch")
            # Three instantiations, one compiled library, one mapped image —
            # the k-images-for-k-types growth of #254.
            @test batched["handles"] == "1"
            @test batched["images"] == "1"
            @test batched["add_i32"] == "5"
            @test batched["add_i64"] == "15"
            @test batched["add_f64"] == "3.75"

            # A later session that instantiates lazily finds the batch and opens
            # exactly that one image, rather than one per type.
            reused = run_generics_cache_child(script, cache, "restore")
            @test reused["restorable_Int32"] == "true"
            @test reused["restorable_Float64"] == "true"
            @test reused["images"] == "1"
            # The batch is one library, so there is no per-instantiation one.
            @test reused["cached_Int32"] == "false"
            @test reused["recorded_Int32"] == "true"
            @test reused["add_f64"] == "3.75"
        end
    end
end

@testset "#254: restoring an instantiation still gets a fresh image" begin
    # Reading the cache removes the compile and nothing else. An instantiation's
    # library is private to it, so it is opened from a private copy: retiring an
    # image and asking for the instantiation again must still produce a *new*
    # image with its own liveness flag, not hand back the retired one — which is
    # what opening the shared cache file would do ("one image, one flag" applies
    # to one path). `test/test_generic_struct.jl` asserts the same thing for a
    # generic struct group, through its Rust statics.
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required to build a monomorphization"
    else
        mktempdir() do dir
            withenv("RUSTCALL_CACHE_DIR" => dir) do
                RustCall._reset_cache_dir_memo!()
                code = "pub fn gc254_image<T: std::ops::Add<Output = T> + Copy>(x: T, y: T) -> T { x + y }"
                RustCall.register_generic_function("gc254_image", code, [:T])
                first_info = nothing
                second = nothing
                try
                    bind = Dict{Symbol, Type}(:T => Int32)
                    first_info = RustCall.monomorphize_function("gc254_image", bind)
                    @test RustCall.call_generic_function("gc254_image", Int32(2), Int32(3)) == Int32(5)

                    RustCall.unload_library(first_info.lib_name)
                    # Restored from the cache: no `rustc`, but its own image.
                    @test RustCall._restore_generic_artifact(
                        RustCall.artifact_key(RustCall._monomorphization_id(
                            RustCall.GENERIC_FUNCTION_REGISTRY["gc254_image"], "gc254_image",
                            bind, RustCall.get_default_compiler())),
                        "gc254_image") !== nothing
                    second = RustCall.monomorphize_function("gc254_image", bind)
                    @test second.handle != first_info.handle
                    @test RustCall.call_generic_function("gc254_image", Int32(2), Int32(3)) == Int32(5)
                finally
                    # Both generations share one registry name (one artifact
                    # key), so one unload retires whichever is registered.
                    live = second === nothing ? first_info : second
                    live === nothing || RustCall.unload_library(live.lib_name)
                    lock(RustCall.REGISTRY_LOCK) do
                        delete!(RustCall.GENERIC_FUNCTION_REGISTRY, "gc254_image")
                    end
                    RustCall._reset_cache_dir_memo!()
                end
            end
        end
    end
end

@testset "#254: a damaged specialization record is a miss, not a failure" begin
    mktempdir() do dir
        withenv("RUSTCALL_CACHE_DIR" => dir) do
            RustCall._reset_cache_dir_memo!()
            try
                key = "0"^64
                spec = RustCall.SpecializedFunction("", "f_i32", "rustcall_f_i32",
                                                    ["i32"], "i32", [""], false, false, "f_i32")
                record = RustCall.SpecializationRecord(key,
                    Pair{String, RustCall.SpecializedFunction}["f" => spec])
                path = RustCall.save_specialization_record(key, record)

                back = RustCall.load_specialization_record(key)
                @test back !== nothing
                @test back.library_key == key
                @test first(only(back.members)) == "f"
                @test last(only(back.members)).symbol == "rustcall_f_i32"
                @test last(only(back.members)).arg_types == ["i32"]
                # The source is deliberately not persisted.
                @test isempty(last(only(back.members)).source)

                # A record from another format version is no record at all.
                text = read(path, String)
                write(path, replace(text, "schema_version = 1" => "schema_version = 99"))
                @test RustCall.load_specialization_record(key) === nothing

                # So is an unparsable one, and a missing one.
                write(path, "this is not TOML = = =")
                @test RustCall.load_specialization_record(key) === nothing
                rm(path)
                @test RustCall.load_specialization_record(key) === nothing

                # A record that parses as TOML but says something a record
                # cannot mean is a miss too, not a `MethodError` out of the
                # reconstruction — the callers treat this as a lookup, and a
                # throw would abort a monomorphization the cache exists only to
                # speed up (#254 review).
                RustCall.save_specialization_record(key, record)
                for (field, bad) in ("arg_types" => [1], "arg_abis" => "not a list",
                                     "symbol" => 7, "name" => [], "ffi_name" => 1.5,
                                     "return_type" => true,
                                     "has_owned_string_helper" => "yes")
                    doc = TOML.parsefile(path)
                    doc["functions"][1][field] = bad
                    open(io -> TOML.print(io, doc), path, "w")
                    @test RustCall.load_specialization_record(key) === nothing
                    @test RustCall._cached_generic_artifact(key, "f") === nothing
                end

                # A record with no library beside it never claims a hit.
                RustCall.save_specialization_record(key, record)
                @test RustCall._restore_generic_artifact(key, "f") === nothing
                @test RustCall._cached_generic_artifact(key, "f") === nothing
                # ...and neither does one that does not name the member asked
                # for. The probe answers that without touching the library, so
                # `precompile_generics` does not copy a dylib per skipped type.
                @test RustCall._cached_generic_artifact(key, "other") === nothing
            finally
                RustCall._reset_cache_dir_memo!()
            end
        end
    end
end

@testset "#254: precompile_generics reads its instantiations" begin
    code = "pub fn gc254_pair<T: Copy, U: Copy>(a: T, b: U) -> i64 { let _ = (a, b); 0 }"
    single = RustCall.GenericFunctionInfo(
        "gc254_one", code, [:T], Dict{Symbol, RustCall.TypeConstraints}(),
        "", ["T"], "i64", "gc254_one", nothing, "")
    double = RustCall.GenericFunctionInfo(
        "gc254_pair", code, [:T, :U], Dict{Symbol, RustCall.TypeConstraints}(),
        "", ["T", "U"], "i64", "gc254_pair", nothing, "")

    @test RustCall._generic_binding(single, Int32) == Dict{Symbol, Type}(:T => Int32)
    @test RustCall._generic_binding(double, (Int32, Int64)) ==
          Dict{Symbol, Type}(:T => Int32, :U => Int64)
    @test RustCall._generic_binding(double, Dict(:T => Int32, :U => Int64)) ==
          Dict{Symbol, Type}(:T => Int32, :U => Int64)
    # A tuple of pairs is a mapping, not two positional types.
    @test RustCall._generic_binding(double, (:T => Int32, :U => Int64)) ==
          Dict{Symbol, Type}(:T => Int32, :U => Int64)
    @test RustCall._generic_binding(double, [:T => Int32, :U => Int64]) ==
          Dict{Symbol, Type}(:T => Int32, :U => Int64)
    @test RustCall._generic_binding(single, :T => Int32) == Dict{Symbol, Type}(:T => Int32)
    # A bare type cannot bind two parameters, and the arity is checked.
    @test_throws ArgumentError RustCall._generic_binding(double, Int32)
    @test_throws ArgumentError RustCall._generic_binding(double, (Int32,))
    @test_throws ArgumentError RustCall._generic_binding(double, Dict(:T => Int32))
    @test_throws ArgumentError RustCall._generic_binding(single, "i32")
    # A map naming a parameter the generic does not declare is refused here
    # rather than asking the extractor to specialize a parameter that is not
    # there, and a non-type value names itself.
    @test_throws ArgumentError RustCall._generic_binding(single, Dict(:T => Int32, :Z => Int64))
    @test_throws ArgumentError RustCall._generic_binding(single, Dict(:T => "i32"))

    @test_throws ErrorException RustCall.precompile_generics("gc254_not_registered", Int32)
end

@testset "#254: a batch is never mapped from the cache file" begin
    # `load_artifact!` keys the handle and the liveness flag on the *path*, so
    # every member of a batch has to name one file or the batch stops being one
    # image — and that file must not be the cached one. The cache is a mutable
    # store: a concurrent publisher of the same batch calls `save_cached_library`
    # on exactly that path, `clear_cache()` removes it, and on Windows the
    # replacement fails outright while something has it open (#254 review).
    mktempdir() do dir
        withenv("RUSTCALL_CACHE_DIR" => dir) do
            RustCall._reset_cache_dir_memo!()
            key = "1"^64
            try
                cached = joinpath(RustCall.get_cache_dir(),
                                  "pretend_batch" * RustCall.get_library_extension())
                mkpath(dirname(cached))
                write(cached, "the batch, as published")

                copy1 = RustCall._shared_batch_copy(key, cached)
                @test copy1 != cached
                @test !startswith(abspath(copy1), abspath(RustCall.get_cache_dir()))
                @test read(copy1, String) == "the batch, as published"
                # One path per batch: a second member gets the same file.
                @test RustCall._shared_batch_copy(key, cached) == copy1

                # A publisher replacing the cached file leaves the mapped copy
                # alone, and the batch keeps naming it.
                write(cached, "a concurrent publisher's replacement")
                @test read(copy1, String) == "the batch, as published"
                @test RustCall._shared_batch_copy(key, cached) == copy1

                # ...and the private arm is the opposite: a fresh file every
                # time, which is what makes a rebuilt instantiation a new image.
                private1 = RustCall._private_artifact_copy(cached)
                private2 = RustCall._private_artifact_copy(cached)
                @test private1 != private2
            finally
                delete!(RustCall._BATCH_LIBRARY_COPIES, key)
                RustCall._reset_cache_dir_memo!()
            end
        end
    end
end

# ---------------------------------------------------------------------------
# Releasing instantiations (#397)
# ---------------------------------------------------------------------------
#
# Lazy instantiation maps one image per type, and until #397 nothing ever
# unmapped one. `release_generics` is the explicit answer: it retires the
# images behind a generic's instantiations exactly as `unload_library` retires
# a library — out of the registry, still mapped — so a pointer or object that
# still holds one keeps working, and the next call gets a fresh image.

@testset "#397: release_generics retires instantiations" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required to build a monomorphization"
    else
        RustCall.register_generic_function("gc397_id",
            "pub fn gc397_id<T: Copy>(x: T) -> T { x }", [:T])
        images() = count(n -> startswith(n, "rust_generic"), RustCall.list_loaded_libraries())
        cached(T) = RustCall.get_monomorphized_function("gc397_id", Dict{Symbol, Type}(:T => T))
        owned() = [k for (k, o) in RustCall.MONOMORPHIZATION_OWNERS if o == "gc397_id"]
        try
            @testset "every instantiation of a generic, and the registry count comes down" begin
                before = images()
                @test RustCall.call_generic_function("gc397_id", Int32(1)) == Int32(1)
                @test RustCall.call_generic_function("gc397_id", Int64(2)) == Int64(2)
                @test RustCall.call_generic_function("gc397_id", 3.5) == 3.5
                @test images() == before + 3
                @test length(owned()) == 3
                old = cached(Int32)
                @test old !== nothing
                old_alive = RustCall.alive_ref_for_handle(old.handle, old.lib_name)
                @test old_alive[]

                @test RustCall.release_generics("gc397_id") == 3
                @test images() == before
                @test isempty(owned())
                @test all(T -> cached(T) === nothing, (Int32, Int64, Float64))
                # Retired, not closed: the image is still mapped and its flag
                # still says live, so anything holding it keeps working.
                @test old.handle in RustCall.retired_handles()
                @test old_alive[]
                @test RustCall._call_monomorphized(old, Int32(9)) == Int32(9)

                # The next call gets a fresh image — from the cache, so no
                # rebuild, but a different mapping with its own flag.
                @test RustCall.call_generic_function("gc397_id", Int32(4)) == Int32(4)
                fresh = cached(Int32)
                @test fresh !== nothing
                @test fresh.handle != old.handle
                @test RustCall.alive_ref_for_handle(fresh.handle, fresh.lib_name) !== old_alive
                @test images() == before + 1
                @test RustCall.release_generics("gc397_id") == 1
                RustCall.close_retired_handles!(RustCall.retired_handles(old.lib_name))
                @test !old_alive[]
            end

            @testset "only the listed instantiations" begin
                RustCall.call_generic_function("gc397_id", Int32(1))
                RustCall.call_generic_function("gc397_id", Int64(2))
                @test RustCall.release_generics("gc397_id", Int64) == 1
                @test cached(Int32) !== nothing
                @test cached(Int64) === nothing
                @test RustCall.release_generics("gc397_id", Int64) == 0
                @test RustCall.release_generics("gc397_id") == 1
            end

            @testset "a batch is one image, so it is released as one" begin
                RustCall.precompile_generics("gc397_id", Int8, Int16)
                a, b = cached(Int8), cached(Int16)
                @test a !== nothing && b !== nothing
                @test a.handle == b.handle
                copies_before = length(RustCall._BATCH_LIBRARY_COPIES)
                # Asking for one member retires the library both live in, and
                # the count says what actually left the registry: both.
                @test RustCall.release_generics("gc397_id", Int8) == 2
                @test cached(Int8) === nothing
                @test cached(Int16) === nothing
                # ...and forgets the shared copy, or the next restore would open
                # the same path and get the retired image back.
                @test length(RustCall._BATCH_LIBRARY_COPIES) < copies_before
                @test RustCall.call_generic_function("gc397_id", Int16(6)) == Int16(6)
                again = cached(Int16)
                @test again !== nothing
                @test again.handle != b.handle
                @test RustCall.release_generics("gc397_id") == 1
            end

            @testset "a publication is refused once its image was released" begin
                # Two tasks racing on one instantiation both end on the
                # winner's handle; `release_generics` can retire it while the
                # loser is between its load and its publication. The guard the
                # publication runs under `REGISTRY_LOCK` is what stops the
                # loser caching a pointer into the retired image as if it were
                # the fresh one the release promised (#397 review).
                RustCall.call_generic_function("gc397_id", Float32(1))
                info = cached(Float32)
                current(i, gen = i.generation) = lock(RustCall.REGISTRY_LOCK) do
                    RustCall._image_is_current(i.lib_name, i.handle, gen)
                end
                @test current(info)
                @test RustCall.release_generics("gc397_id") == 1
                @test !current(info)
                @test !lock(RustCall.REGISTRY_LOCK) do
                    RustCall._image_is_current("rust_generic_never_registered", info.handle,
                                               info.generation)
                end
                # A retry after the refusal is an ordinary instantiation: a
                # fresh image, cached like any other.
                fresh = RustCall.monomorphize_function("gc397_id", Dict{Symbol, Type}(:T => Float32))
                @test fresh.handle != info.handle
                @test cached(Float32) !== nothing
                # A handle is not an identity: the next image of this name is a
                # later generation, and a pointer resolved on the released
                # image is refused even if the loader had reused the value.
                @test fresh.lib_name == info.lib_name
                @test fresh.generation > info.generation
                @test current(fresh)
                @test !current(fresh, info.generation)
                @test RustCall.release_generics("gc397_id") == 1
            end

            @testset "a batch path taken before a release does not revive the image" begin
                # The reader that `_batch_copy_is_current` exists for: it takes
                # the copy's path out of the memo, a release drops the memo and
                # retires the image, and only then does it open the path — and
                # `dlopen` hands back the retired image, flag adopted,
                # generation advanced. Played through the real code with the
                # restore taken early (`restored_override`); the attempt must
                # publish nothing and retire what it revived, and the next
                # instantiation must be a fresh image (#397 review).
                RustCall.precompile_generics("gc397_id", UInt32, UInt64)
                before = cached(UInt32)
                bind = Dict{Symbol, Type}(:T => UInt32)
                key = RustCall.artifact_key(RustCall._monomorphization_id(
                    RustCall.GENERIC_FUNCTION_REGISTRY["gc397_id"], "gc397_id",
                    bind, RustCall.get_default_compiler()))
                # The reader's first step: the path, from the memo, before the release.
                restored = RustCall._restore_generic_artifact(key, "gc397_id")
                @test restored.batch_key !== nothing
                @test lock(RustCall.REGISTRY_LOCK) do
                    RustCall._batch_copy_is_current(restored.batch_key, restored.lib_path)
                end
                @test RustCall.release_generics("gc397_id") == 2
                @test !lock(RustCall.REGISTRY_LOCK) do
                    RustCall._batch_copy_is_current(restored.batch_key, restored.lib_path)
                end
                # The reader's second step, through the real attempt: it
                # revives the retired image, notices, retires it again and
                # publishes nothing.
                @test RustCall._monomorphize_function_once("gc397_id", bind;
                                                           restored_override = restored) === nothing
                @test cached(UInt32) === nothing
                @test !(before.lib_name in RustCall.list_loaded_libraries())
                # The retry — any caller — gets a fresh image, not the old statics.
                fresh = RustCall.monomorphize_function("gc397_id", bind)
                @test fresh.handle != before.handle
                @test RustCall.call_generic_function("gc397_id", UInt32(3)) == UInt32(3)
                @test RustCall.release_generics("gc397_id") >= 1
                RustCall.close_retired_handles!(RustCall.retired_handles(before.lib_name))
                # And a private (non-batch) instantiation has nothing to check.
                @test lock(RustCall.REGISTRY_LOCK) do
                    RustCall._batch_copy_is_current(nothing, "/anything")
                end
            end

            @testset "only the release that retires the image counts it" begin
                # Two concurrent releases of one image both capture its
                # generation before either retires it; only the first
                # retirement happens, and only that call may report the count.
                # The retirement is conditional on the captured generation, so
                # the second call — and a release racing a re-instantiation
                # that registered a newer image under the name — does nothing
                # (#397 review). Played out through the primitive.
                RustCall.call_generic_function("gc397_id", UInt16(1))
                info = cached(UInt16)
                # A stale generation retires nothing and reports so...
                @test !RustCall.unload_artifact!(RustCall.generics_policy(), info.lib_name;
                                                 expect_generation = info.generation - 1)
                @test info.lib_name in RustCall.list_loaded_libraries()
                @test cached(UInt16) !== nothing
                # ...the right one retires it...
                @test RustCall.unload_artifact!(RustCall.generics_policy(), info.lib_name;
                                                expect_generation = info.generation)
                @test !(info.lib_name in RustCall.list_loaded_libraries())
                # ...and a second release of what is already gone counts nothing.
                @test RustCall.release_generics("gc397_id", UInt16) == 0
                RustCall.close_retired_handles!(RustCall.retired_handles(info.lib_name))
            end

            @testset "close = true flips the flag and closes" begin
                RustCall.call_generic_function("gc397_id", UInt8(1))
                info = cached(UInt8)
                alive = RustCall.alive_ref_for_handle(info.handle, info.lib_name)
                @test alive[]
                @test RustCall.release_generics("gc397_id"; close = true) == 1
                @test !alive[]
                @test !(info.handle in RustCall.retired_handles())
            end

            @test_throws ErrorException RustCall.release_generics("gc397_not_registered")
        finally
            RustCall.release_generics("gc397_id"; close = true)
            lock(RustCall.REGISTRY_LOCK) do
                delete!(RustCall.GENERIC_FUNCTION_REGISTRY, "gc397_id")
            end
        end
    end
end

@testset "#397: a released generic struct keeps its live objects safe" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required to build a monomorphization"
    else
        rust"""
        #[julia]
        pub struct Gc397Box<T> { value: T }
        impl<T: Copy> Gc397Box<T> {
            pub fn new(value: T) -> Self { Self { value } }
            pub fn gc397_peek(&self) -> T { self.value }
        }
        """
        failures_before = RustCall.finalizer_failure_count()
        obj = Gc397Box{Int32}(Int32(5))
        member = first(sort([n for n in keys(RustCall.GENERIC_FUNCTION_REGISTRY)
                             if startswith(n, "Gc397Box_")]))
        old_alive = getfield(obj, :alive)
        replacement = nothing
        try
            @test Base.invokelatest(gc397_peek, obj) == Int32(5)
            # One image per struct instantiation, every member in it (#291):
            # naming any member's generic releases the instantiation.
            @test RustCall.release_generics(member) >= 1
            # The object still works: its image is retired, not closed.
            @test old_alive[]
            @test Base.invokelatest(gc397_peek, obj) == Int32(5)
            @test obj.value == Int32(5)
            # A new object comes from a fresh image with its own flag.
            replacement = Gc397Box{Int32}(Int32(6))
            @test getfield(replacement, :alive) !== old_alive
            @test Base.invokelatest(gc397_peek, replacement) == Int32(6)
            # ...and the old one finalizes through the image that allocated it.
            finalize(obj)
            @test RustCall.finalizer_failure_count() == failures_before
        finally
            finalize(obj)
            replacement === nothing || finalize(replacement)
            RustCall.close_retired_handles!(RustCall.retired_handles(obj.lib_name))
            RustCall.release_generics(member; close = true)
        end
    end
end
