# Monomorphizations survive the session that built them, and a batch of them
# shares one library and one mapped image (#254).
#
# Before this, every instantiation was compiled by its own `rustc` invocation
# into its own temporary directory and mapped as its own image, and nothing was
# written to the artifact cache: restarting Julia rebuilt all of them.

using RustCall
using Test

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
        emit("restorable_$(T)", RustCall._restore_generic_artifact(instantiation_key(T)) !== nothing)
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
                            bind, RustCall.get_default_compiler()))) !== nothing
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

                # A record with no library beside it never claims a hit.
                RustCall.save_specialization_record(key, record)
                @test RustCall._restore_generic_artifact(key) === nothing
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
    # A bare type cannot bind two parameters, and the arity is checked.
    @test_throws ArgumentError RustCall._generic_binding(double, Int32)
    @test_throws ArgumentError RustCall._generic_binding(double, (Int32,))
    @test_throws ArgumentError RustCall._generic_binding(double, Dict(:T => Int32))
    @test_throws ArgumentError RustCall._generic_binding(single, "i32")

    @test_throws ErrorException RustCall.precompile_generics("gc254_not_registered", Int32)
end
