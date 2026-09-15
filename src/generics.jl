# Generic function support for RustCall.jl
# Phase 2: Monomorphization and type parameter inference

# Import required functions and constants from other modules
# These will be available when this file is included after ruststr.jl and codegen.jl

"""
    TraitBound

Represents a single trait bound with optional type parameters.

# Fields
- `trait_name::String`: Name of the trait (e.g., "Copy", "Add")
- `type_params::Vector{String}`: Type parameters for the trait (e.g., ["Output = T"] for Add<Output = T>)
"""
struct TraitBound
    trait_name::String
    type_params::Vector{String}
end

function Base.show(io::IO, tb::TraitBound)
    if isempty(tb.type_params)
        print(io, tb.trait_name)
    else
        print(io, tb.trait_name, "<", join(tb.type_params, ", "), ">")
    end
end

function Base.:(==)(a::TraitBound, b::TraitBound)
    a.trait_name == b.trait_name && a.type_params == b.type_params
end

"""
    TypeConstraints

Represents all trait bounds for a type parameter.

# Fields
- `bounds::Vector{TraitBound}`: List of trait bounds (e.g., [Copy, Clone, Add<Output = T>])
"""
struct TypeConstraints
    bounds::Vector{TraitBound}
end

TypeConstraints() = TypeConstraints(TraitBound[])

function Base.show(io::IO, tc::TypeConstraints)
    print(io, join(string.(tc.bounds), " + "))
end

function Base.isempty(tc::TypeConstraints)
    isempty(tc.bounds)
end

function Base.:(==)(a::TypeConstraints, b::TypeConstraints)
    a.bounds == b.bounds
end

struct GenericCargoContext
    dependencies::Tuple
    env::String
    config::String
    lockfile::String
    package_name::String
end

function _generic_cargo_context(dependencies, env, config, lockfile)
    specs = Tuple((; dep.name, dep.version, features = Tuple(dep.features), dep.git,
                    path = dep.path === nothing ? nothing : abspath(dep.path)) for dep in dependencies)
    GenericCargoContext(specs, String(env), String(config), String(lockfile),
                        cargo_block_package(dependencies))
end

_generic_cargo_dependencies(context::GenericCargoContext) =
    DependencySpec[DependencySpec(dep.name, dep.version, collect(String, dep.features),
                                  dep.git, dep.path) for dep in context.dependencies]

_generic_cargo_identity(::Nothing) = (; dependencies = String[], build_env = Pair{String, String}[])
function _generic_cargo_identity(context::GenericCargoContext)
    env = _cargo_build_env(context.env)
    _cargo_config_digest(env; dir = tempdir()) == context.config || throw(RustError(
        "Cargo configuration changed since generic registration; evaluate the original rust block again"))
    (; dependencies = artifact_dependency_strings(_generic_cargo_dependencies(context)),
       build_env = Pair{String, String}["cargo-env" => context.env,
           "cargo-config" => context.config, "cargo-lockfile" => context.lockfile,
           "cargo-package" => context.package_name])
end

function _compile_generic_source(source::String, compiler::RustCompiler, context)
    context === nothing && return compile_rust_to_shared_lib(wrap_rust_code(source); compiler)
    _generic_cargo_identity(context) # Recheck immediately before building.
    dependencies = _generic_cargo_dependencies(context)
    env = _cargo_build_env(context.env)
    # Source edits change the dependency-content identity, but the captured
    # lockfile still names the original generated root package. Keep that
    # package name while building the newly identified specialization.
    project = create_cargo_project(context.package_name, dependencies)
    try
        write_rust_code_to_project(project, wrap_rust_code(source))
        lock_digest = ""
        if !isempty(context.lockfile)
            lock_path = joinpath(project.path, "Cargo.lock")
            write(lock_path, context.lockfile)
            lock_digest = _file_content_digest(lock_path)
        end
        id = _cargo_block_id(wrap_rust_code(source), dependencies, context.env;
                            cargo_config = context.config, cargo_lock = lock_digest)
        path = build_cargo_project_cached(project, id; env, locked = !isempty(context.lockfile))
        cached = get_cargo_cached_library(artifact_key(id))
        cached !== nothing && isfile(cached) && return cached
        # Cache publication is best-effort. Keep the successful build alive
        # after cleaning its Cargo project, as the direct rustc path does.
        retained = joinpath(mktempdir(), basename(path))
        cp(path, retained)
        return retained
    catch err
        if err isa CargoBuildError && occursin("persisted Cargo.lock", err.message)
            throw(CargoBuildError(
                "Cargo specialization cannot replay its registered Cargo.lock. " *
                "Re-evaluate the original rust block to capture changed dependency manifests; " *
                "clearing the persisted lock store does not update this registration.",
                err.stderr, err.project_path))
        end
        rethrow()
    finally
        compiler.debug_mode || cleanup_cargo_project(project)
    end
end

"""
    _cached_generic_artifact(cache_key, member) -> Union{Nothing, NamedTuple}

The record and the verified cached library an earlier session left for
`cache_key`, or `nothing` when there is none that covers `member` (#254).

Both halves are required. The library is verified against its checksum by
`load_cached_library`; a record with no library, a library with no record, an
unreadable record, a record of another format version and a record that does
not carry `member` all read as a miss, and a miss only costs the rebuild that
used to happen unconditionally.

`artifact_key` decides identity, and it folds in the toolchain fingerprint —
the extractor digest and the `rustcall_core` sources — so a cached library can
never have been emitted by a different symbol scheme than the record describes.

This is the **probe**: it materializes nothing, so asking whether an
instantiation is already cached costs a TOML parse and a checksum, not a copy
of the library. `_restore_generic_artifact` is the half that produces a file to
open.
"""
function _cached_generic_artifact(cache_key::String, member::AbstractString)
    record = load_specialization_record(cache_key)
    record === nothing && return nothing
    # Checked before the checksum: a record that does not describe the member
    # being asked for is a miss whatever its library turns out to be.
    any(p -> first(p) == member, record.members) || return nothing
    get_cached_library(record.library_key) === nothing && return nothing
    cached = try
        load_cached_library(record.library_key)
    catch e
        @debug "Ignoring a cached monomorphization that failed verification" cache_key exception = e
        return nothing
    end
    return (; record, cached)
end

"""
    _restore_generic_artifact(cache_key, member) -> Union{Nothing, NamedTuple}

The file to open and the specialization metadata for an artifact an earlier
session already produced for `cache_key`, or `nothing` when
`_cached_generic_artifact` finds none covering `member`.

# Which file is opened, and why it matters

`load_artifact!` gives the same *path* the same handle and the same liveness
flag ("one image, one flag"), so the file a restore opens decides whether two
instantiations share an image — and whether rebuilding after an unload gets a
fresh one.

- An artifact **private to one instantiation** (`library_key == cache_key`) is
  opened from a **private copy**, exactly as a freshly compiled one is opened
  from its own build directory. Retiring an instantiation and asking for it
  again therefore still produces a *new* image with its own statics and its own
  liveness flag, which is what `test/test_generic_struct.jl` asserts for #291.
  Reading the cache must not change that; it only removes the compile.
- A **batch** (`library_key != cache_key`, written by `_batch_monomorphize`) is
  opened from **one** copy shared by the whole batch — `_shared_batch_copy`.
  Several instantiations naming one library is what a batch *is*, so they must
  share one mapped image, in the session that built it and in every later one;
  one path per batch is what gives them one.

Nothing is ever mapped from the cache directory itself. The cache is a
**mutable** store: a concurrent publisher of the same batch calls
`save_cached_library(..., force = true)` on exactly that path, `clear_cache()`
removes it, and on Windows the replacement fails outright while something has
it open. A copy is also what the freshly-built path has always done, and
`src/loadpolicy.jl` records why (#253 review of #254).
"""
function _restore_generic_artifact(cache_key::String, member::AbstractString)
    found = _cached_generic_artifact(cache_key, member)
    found === nothing && return nothing
    try
        if found.record.library_key == cache_key
            return (; members = found.record.members,
                     lib_path = _private_artifact_copy(found.cached), batch_key = nothing)
        end
        # `batch_key` travels with the path so the publication can check that
        # the memo still names this copy (`_batch_copy_is_current`, #397).
        return (; members = found.record.members,
                 lib_path = _shared_batch_copy(found.record.library_key, found.cached),
                 batch_key = found.record.library_key)
    catch e
        @debug "Could not copy a restored monomorphization" cache_key exception = e
        return nothing
    end
end

# A copy nothing else will ever open: a fresh image, its own statics, its own
# liveness flag, exactly as a build of this instantiation would have produced.
function _private_artifact_copy(cached::String)
    private = joinpath(mktempdir(), basename(cached))
    cp(cached, private)
    return private
end

"""
    _BATCH_LIBRARY_COPIES

`library_key` → the one path this process opens that batch from.

A batch library holds several instantiations, and `load_artifact!` keys the
handle and the liveness flag on the **path**, so every member has to name the
same file or the batch stops being one image. That file cannot be the cached
one (see `_restore_generic_artifact`), so it is a copy — made once, remembered
here, and used by every member for the life of the process.
"""
const _BATCH_LIBRARY_COPIES = _state_view(:batch_library_copies, Dict{String, String}())

function _shared_batch_copy(library_key::String, cached::String)
    existing = get(_BATCH_LIBRARY_COPIES, library_key, nothing)
    existing === nothing || return existing
    # Copied outside STATE — it is file I/O — and published only if no other
    # task has already supplied this key. Whoever is recorded wins, so every
    # member of the batch opens one path and therefore one image; a loser's
    # copy is an unused temporary file.
    private = _private_artifact_copy(cached)
    return get!(_BATCH_LIBRARY_COPIES, library_key, private)
end

"""
    _cache_generic_library(library_key, lib_path, source, members, compiler)
        -> Union{String, Nothing}

Publish a freshly built monomorphization library under `library_key` and return
the path inside the cache, or `nothing` when it could not be published.

Publishing is best-effort and never changes what the caller *loads*: a build
opens the file it just produced, as it always has. Only a later restore reads
the cache (`_restore_generic_artifact`).
"""
function _cache_generic_library(library_key::String, lib_path::String, source::String,
                                members, compiler::RustCompiler)
    try
        metadata = CacheMetadata(
            library_key,
            stable_content_hash(source),
            "$(compiler.optimization_level)_$(compiler.emit_debug_info)",
            compiler.target_triple,
            now(),
            String[fn.symbol for (_, fn) in members],
        )
        return save_cached_library(library_key, lib_path, metadata)
    catch e
        @warn "Failed to save a monomorphized library to the cache: $e"
        return nothing
    end
end

# Best-effort: a record that cannot be written costs a rebuild next session.
function _record_generic_specialization(cache_key::String, library_key::String, members)
    try
        save_specialization_record(cache_key, SpecializationRecord(library_key, members))
    catch e
        @warn "Failed to record a monomorphization in the cache: $e"
    end
    return nothing
end

"""
    GenericFunctionInfo

Information about a generic Rust function that needs monomorphization.
"""
struct GenericFunctionInfo
    name::String
    code::String
    type_params::Vector{Symbol}  # e.g., [:T, :U]
    constraints::Dict{Symbol, TypeConstraints}  # e.g., :T => TypeConstraints([Copy, Clone])
    context::String  # Additional code (e.g., struct definitions) needed for compilation
    arg_types::Vector{String}  # Rust argument types as recorded in the manifest (e.g. ["T", "i32"])
    return_type::String  # Rust return type as recorded in the manifest
    path::String  # Qualified name inside `code` (`api::deep::f`); equals `name` at the file root
    compiler::Union{Nothing, RustCompiler}  # compiler the block was expanded for (nothing: default)
    # Non-empty when the function cannot be specialized lazily: the reason,
    # raised as a `RustError` by `monomorphize_function`. Set for generics of a
    # manually registered Cargo manifest whose build context is unavailable.
    # Normal Cargo blocks retain their context and specialize through Cargo.
    blocked::String
    # Non-nothing for generic struct wrappers. All members of one group are
    # specialized into a single cdylib so allocation and destruction share an
    # allocator (#291).
    group::Union{Nothing, Symbol}
    cargo::Union{Nothing, GenericCargoContext}
end

GenericFunctionInfo(name, code, type_params, constraints, context, arg_types,
                    return_type, path, compiler, blocked, group) =
    GenericFunctionInfo(name, code, type_params, constraints, context, arg_types,
                        return_type, path, compiler, blocked, group, nothing)

# Keep the public positional constructor used by older tests and extensions.
GenericFunctionInfo(name, code, type_params, constraints, context, arg_types,
                    return_type, path, compiler, blocked) =
    GenericFunctionInfo(name, code, type_params, constraints, context, arg_types,
                        return_type, path, compiler, blocked, nothing)

"""
Registry for generic functions.
Maps function name to GenericFunctionInfo.
"""
const GENERIC_FUNCTION_REGISTRY = _state_view(:generic_function_registry,
    Dict{String, GenericFunctionInfo}())

"""
Registry for monomorphized function instances.

Keyed by `artifact_key` of the monomorphization `ArtifactId`
(`_monomorphization_id`), which records the parameter bindings in **declaration
order** together with the source, the compiler snapshot and the toolchain. The
previous key was `(func_name, tuple(sort(values(type_params))...))`: sorting the
*values* discarded which parameter got which type, so `pair<T=i32, U=i64>` and
`pair<T=i64, U=i32>` shared one entry and the second call ran the first one's
machine code (#247).
"""
const MONOMORPHIZED_FUNCTIONS = _state_view(:monomorphized_functions,
    Dict{String, FunctionInfo}())

"""
    MonomorphizationOwner

Who an instantiation belongs to: the registered generic's name and the
concrete **types** it was instantiated with, in the generic's parameter order
(`_owner_binding`). Parameter *names* are not part of it: a re-registration
may spell `f<T>` as `f<U>`, and an `impl` wrapper in a struct group may name
the struct's parameter differently from the struct — the same instantiation
either way (#397 review). Immutable, so it can sit in a state table.
"""
struct MonomorphizationOwner
    generic::String
    binding::Tuple
end

_owner_binding(info::GenericFunctionInfo, type_params) =
    Tuple(Type[type_params[p] for p in info.type_params])

"""
    MONOMORPHIZATION_OWNERS

Artifact key of an instantiation → the `MonomorphizationOwner` it belongs to.

`MONOMORPHIZED_FUNCTIONS` is keyed by the artifact identity, which folds the
source, the bindings and the toolchain into one digest — the right key for a
lookup, and one nothing can enumerate *by generic*. `release_generics(f)` has
to find every instantiation of `f` without being told their types, so each
instantiation records its owner when it is published (#397). The bindings are
recorded too, not recomputed: `release_generics(f, T)` selects rows by them,
and an identity recomputed *now* would miss an instantiation built under a
different default compiler or a since re-registered source (#397 review).
Written and cleared in the same transactions as `MONOMORPHIZED_FUNCTIONS`.
"""
const MONOMORPHIZATION_OWNERS =
    _state_view(:monomorphization_owners, Dict{String, MonomorphizationOwner}())

"""
    ReleasedGenericImage

One image a non-closing `release_generics` retired: the library name it was
registered under, the handle and generation that identify that image (a name
is reused by the next image of the same instantiation; a handle value can be
too, once closed — the pair is the identity, as in `_image_is_current`), and
the bindings of this generic it carried.
"""
struct ReleasedGenericImage
    lib::String
    handle::Ptr{Cvoid}
    generation::Int
    # The image's liveness flag: one per mapped image, never shared with the
    # next image of the name (a closed image's pointer value can be), so it
    # is what tells this retirement from a later one under the same name.
    alive::Base.RefValue{Bool}
    carried::Tuple
end

"""
    RELEASED_GENERIC_IMAGES

Generic name → the images (`ReleasedGenericImage`) a **non-closing**
`release_generics` of that generic retired and left mapped, one entry per
retired image.

A release in two steps is the safe way to reclaim: retire now, so no new call
reaches the image, and close later, once nothing holds a pointer or an object
from it. By then the retirement has purged every row and owner, so the closing
call would find no instantiation to select; this is what it drains instead
(#397 review). An entry is recorded in the transaction that *precedes* the
retirement and withdrawn if that retirement did not happen, so a concurrent
closing release can never find the rows gone and the record not yet there. A
closing release closes the entries whose image is retired now, keeps the ones
whose image is still live (a retirement in flight), and forgets the rest — an
image closed or replaced by other means.
"""
const RELEASED_GENERIC_IMAGES =
    _state_view(:released_generic_images, Dict{String, Tuple{Vararg{ReleasedGenericImage}}}())

"""
    GENERIC_IMAGE_PATHS

Registry name of a monomorphization image → the file it was opened from.

`release_generics` needs it for one thing (#397): a batch image is opened from
a process-private copy that `_BATCH_LIBRARY_COPIES` remembers, and opening that
same path again hands back the *retired* image — same handle, same flag — so
the memo has to be dropped with the image. The registry does not keep a
library's path, and a retirement recorded by `unload_artifact!` has none to
give, so the loader of an instantiation writes it here in the transaction that
publishes the instantiation. Written under `REGISTRY_LOCK`; a stale entry for
a name that was unloaded some other way is overwritten the next time that name
is loaded.
"""
const GENERIC_IMAGE_PATHS = _state_view(:generic_image_paths, Dict{String, String}())

# An object's image is immutable even after the source registration changes.
# Keep original wrapper names alongside the compiled snapshots, indexed by
# artifact name and image-lifetime flag: unloading and rebuilding identical
# source reuses the name but must not replace an old object's member snapshots.
const GENERIC_STRUCT_ARTIFACTS = _state_view(:generic_struct_artifacts,
    Dict{Tuple{String, Base.RefValue{Bool}}, Dict{String, FunctionInfo}}())

# Caller holds STATE and has made this image inert. Retired, still-live
# generations retain their members; explicit reclamation releases the maps.
function _forget_generic_image!(alive::Base.RefValue{Bool})
    for key in keys(GENERIC_STRUCT_ARTIFACTS)
        key[2] === alive && delete!(GENERIC_STRUCT_ARTIFACTS, key)
    end
    return nothing
end

function _generic_artifact_member(lib_name::String, func_name::String,
                                  alive::Base.RefValue{Bool})
    lock(REGISTRY_LOCK) do
        members = get(GENERIC_STRUCT_ARTIFACTS, (lib_name, alive), nothing)
        members === nothing && return nothing
        info = get(members, func_name, nothing)
        info === nothing && throw(RustError(
            "Generic member '$func_name' is unavailable in the object's image '$lib_name'"))
        return info
    end
end

"""
    _monomorphization_id(generic_info, func_name, type_params, compiler) -> ArtifactId

The identity of one instantiation of a generic function: the registered source
(context plus generic code), the parameter bindings **in declaration order**,
and the compiler snapshot the instantiation is built under. Cargo-backed
registrations additionally identify their dependencies, captured environment,
configuration and exact lockfile; direct rustc registrations leave those empty.

Throws `ArgumentError` when `type_params` does not bind every declared
parameter.
"""
function _monomorphization_id(generic_info, func_name::AbstractString, type_params, compiler)
    return ArtifactId(;
        kind = "monomorphization",
        source = isempty(generic_info.context) ? generic_info.code :
                 generic_info.context * "\n" * generic_info.code,
        type_params = artifact_type_params(generic_info.type_params, type_params),
        target_triple = compiler.target_triple,
        codegen = artifact_codegen_options(compiler),
        _generic_cargo_identity(generic_info.cargo)...,
        extra = Pair{String, String}["function" => String(func_name)],
    )
end

# Julia type name -> short Rust-flavoured identifier, for the human-readable
# part of a monomorphized symbol. Never load-bearing: the artifact key decides
# identity, this only decides how the symbol reads.
const _MONOMORPHIZATION_TYPE_SUFFIX = Base.ImmutableDict(Base.ImmutableDict{String, String}(),
    "Int32" => "i32",
    "Int64" => "i64",
    "UInt32" => "u32",
    "UInt64" => "u64",
    "Float32" => "f32",
    "Float64" => "f64",
    "Bool" => "bool",
)

function _rust_type_suffix(t)::String
    type_str = string(t)
    suffix = get(_MONOMORPHIZATION_TYPE_SUFFIX, type_str,
                 replace(type_str, "Int" => "i", "UInt" => "u", "Float" => "f"))
    # Julia's parametric type display contains braces and module separators.
    # This readable part must be a Rust identifier; the artifact digest still
    # distinguishes types whose display names sanitize to the same suffix.
    return join(isascii(c) && (isletter(c) || isdigit(c) || c == '_') ? c : '_'
                for c in suffix)
end

# ============================================================================
# Julia -> Rust type names for monomorphization
# ============================================================================

const _JULIA_TO_RUST_TYPE = Base.ImmutableDict(Base.ImmutableDict{Type, String}(),
    Int8 => "i8", Int16 => "i16", Int32 => "i32", Int64 => "i64",
    UInt8 => "u8", UInt16 => "u16", UInt32 => "u32", UInt64 => "u64",
    Float32 => "f32", Float64 => "f64",
    Bool => "bool",
    String => "*const u8",
    Cstring => "*const u8",
)

"""
    julia_type_to_rust_string(jt::Type) -> String

Rust spelling of a Julia type used to instantiate a generic parameter
(`Int32 -> "i32"`, `Point{Float64} -> "Point<f64>"`). Throws for unsupported types.
"""
function julia_type_to_rust_string(jt::Type)
    haskey(_JULIA_TO_RUST_TYPE, jt) && return _JULIA_TO_RUST_TYPE[jt]
    if jt isa DataType && !isempty(jt.parameters) && all(p -> p isa Type, jt.parameters)
        base = String(nameof(jt))
        params = join((julia_type_to_rust_string(p) for p in jt.parameters), ", ")
        return "$base<$params>"
    end
    error("Unsupported type for generic specialization: $jt")
end

"""
    infer_type_parameters(func_name::String, arg_types::Vector{Type}) -> Dict{Symbol, Type}

Infer type parameters for a generic function from argument types.

Each Rust argument type recorded in the manifest that is exactly a type
parameter name (`x: T`) binds that parameter to the Julia type of the
corresponding argument. Parameters that never appear as a bare argument type
cannot be inferred and must be supplied explicitly.

# Example
```julia
# For function: fn identity<T>(x: T) -> T
# Called with: identity(Int32(42))
# Returns: Dict(:T => Int32)
```
"""
function infer_type_parameters(func_name::String, arg_types::Vector{<:Type})
    generic_info = lock(REGISTRY_LOCK) do
        get(GENERIC_FUNCTION_REGISTRY, func_name, nothing)
    end
    if generic_info === nothing
        error("Function '$func_name' is not registered as a generic function")
    end

    type_params = Dict{Symbol, Type}()
    sig_arg_types = generic_info.arg_types
    type_param_set = Set(generic_info.type_params)

    if length(sig_arg_types) != length(arg_types)
        error("Generic function '$func_name' takes $(length(sig_arg_types)) argument(s) but $(length(arg_types)) were given")
    end

    for (rust_type, jt) in zip(sig_arg_types, arg_types)
        param = Symbol(strip(rust_type))
        param in type_param_set || continue
        if haskey(type_params, param) && type_params[param] != jt
            error("Conflicting types for parameter $param in '$func_name': $(type_params[param]) vs $jt")
        end
        type_params[param] = jt
    end

    missing_params = [p for p in generic_info.type_params if !haskey(type_params, p)]
    if !isempty(missing_params)
        error("Cannot infer type parameter(s) $(join(string.(missing_params), ", ")) of '$func_name' from argument types $(arg_types); the parameter does not appear as a bare argument type")
    end

    return type_params
end

"""
    monomorphize_function(func_name::String, type_params::Dict{Symbol, Type}) -> FunctionInfo

Monomorphize a generic function with specific type parameters.

# Arguments
- `func_name`: Name of the generic function
- `type_params`: Mapping from type parameter symbols to concrete types

# Returns
- FunctionInfo for the monomorphized function

# Example
```julia
# Register generic function
register_generic_function("identity", "pub fn identity<T>(x: T) -> T { x }", [:T])

# Monomorphize with Int32
info = monomorphize_function("identity", Dict{Symbol, Type}(:T => Int32))
# Returns FunctionInfo for identity_i32
```
"""
function monomorphize_function(func_name::String, type_params::Dict{Symbol, <:Type})
    # An attempt publishes nothing when the image it resolved against was
    # released between its `load_artifact!` and its publication (#397 review):
    # two tasks racing on one instantiation both end on the winner's handle,
    # and `release_generics` can retire that image while the loser is still
    # between the two steps. Publishing then would cache a pointer into a
    # retired — or, with `close = true`, unmapped — image as if it were the
    # fresh one the release promised. So the loser starts over, and gets the
    # fresh image like any other caller.
    #
    # Bounded by time, not by a count of attempts: the releasing task holds no
    # lock between dropping the batch memo and retiring the image, and a batch
    # sibling can lose the `:insert_only` load to the old incumbent as often
    # as it tries while that task has not run — a fixed number of attempts
    # could all be spent before one retirement proceeds (#397 review). Each
    # attempt therefore gives the thread away and then waits a little longer,
    # and only an image that keeps being released for `_MONOMORPHIZE_SETTLE_SECONDS`
    # is an error. The clock starts at the first rejected publication, not at
    # the call: the first attempt may compile, and a cold Cargo build takes
    # longer than the whole allowance (#397 review).
    deadline = Inf
    backoff = 0.001
    while true
        info = _monomorphize_function_once(func_name, type_params)
        info === nothing || return info
        deadline = min(deadline, time() + _MONOMORPHIZE_SETTLE_SECONDS)
        time() < deadline ||
            error("An instantiation of '$func_name' could not be published: the image it " *
                  "resolved against kept being released for $(_MONOMORPHIZE_SETTLE_SECONDS) s")
        @debug "An instantiation of '$func_name' was released while being published; retrying"
        yield()
        sleep(backoff)
        backoff = min(2backoff, 0.1)
    end
end

# How long `monomorphize_function` keeps retrying an instantiation whose image
# is being released under it before giving up. A release is one retirement
# transaction; seconds of them in a row is a program releasing in a loop, not
# a race.
const _MONOMORPHIZE_SETTLE_SECONDS = 10.0

# Whether the image an instantiation resolved its pointers on — `handle`, at
# `generation` of `lib_name` — is still the one registered under that name.
# Checked under `REGISTRY_LOCK` in the transaction that publishes an
# instantiation, so that a publication and a release of the same image are
# serialized: whichever comes second sees the other (#397 review).
#
# The generation is compared as well as the handle, because a handle is not an
# identity: with `close = true` the released image is unmapped, and the
# instantiation's *next* image — registered under the same name, since the
# name is derived from the artifact key — can be handed the same pointer value
# by the dynamic loader. Pointer equality alone would then let a task that
# resolved its symbols on the closed image publish them against the new one.
# Every load of a name advances `ARTIFACT_GENERATIONS[name]`, so the pair is
# what names one image. Caller holds REGISTRY_LOCK.
function _image_is_current(lib_name::String, handle::Ptr{Cvoid}, generation::Int)
    entry = get(RUST_LIBRARIES, lib_name, nothing)
    return entry !== nothing && entry[1] == handle &&
           get(ARTIFACT_GENERATIONS, lib_name, 0) == generation
end

# The positional binding a `release_generics` argument names. A bare type or a
# tuple of types is taken as it is — it is matched against what the rows
# *recorded*, not against the current registration, so an instantiation built
# before the generic was re-registered with another arity (`f<T>` to
# `f<T, U>`) is still released by the spelling that built it (#397 review). A
# mapping names parameters and must go through the current registration.
function _release_binding(registered, instantiation)
    instantiation isa Type && return (instantiation,)
    if instantiation isa Tuple && !isempty(instantiation) && all(t -> t isa Type, instantiation)
        return Tuple(Type[t for t in instantiation])
    end
    return _owner_binding(registered, _generic_binding(registered, instantiation))
end

# Whether the image an instantiation is about to be published against was
# opened from the copy the batch memo names — or the instantiation is not from
# a batch at all. Trivially true for the task that installed the image: it
# opened `lib_path` itself. An `:insert_only` loser was handed the incumbent,
# whose own path the loader recorded (`ARTIFACT_IMAGE_PATHS`); a private
# instantiation is opened from a copy of its own, so a loser's path never
# matches there and is never asked to. Caller holds REGISTRY_LOCK.
function _opened_from_current_copy(batch_key, artifact::LoadedArtifact, lib_name::String,
                                   lib_path::String)
    batch_key === nothing && return true
    artifact.installed && return true
    return registered_image_path(lib_name) == lib_path
end

# Whether the batch copy an instantiation was opened from is still the one the
# memo names — or the instantiation is not from a batch at all. A reader can
# take the path out of `_BATCH_LIBRARY_COPIES` *before* `release_generics`
# drops it and open it *after* the release: `dlopen` of that path hands back
# the retired image, `load_artifact!` adopts its flag and advances the
# generation, and `_image_is_current` alone would then accept a publication
# of the very image the release promised to replace — same statics and all.
# The memo is dropped in the release transaction, so a path no longer in it
# is a copy that was released under the reader; the caller then retires what
# it revived and starts over (#397 review). Caller holds REGISTRY_LOCK.
function _batch_copy_is_current(batch_key::Union{Nothing, String}, lib_path::String)
    batch_key === nothing && return true
    return get(_BATCH_LIBRARY_COPIES, batch_key, nothing) == lib_path
end

# One attempt at `monomorphize_function`; `nothing` means the image resolved
# against was released before it could be published, and the caller retries.
# `restored_override` is a test seam: the result of `_restore_generic_artifact`
# taken *earlier*, so a test can play the reader whose batch path was released
# between the restore and the load (`_batch_copy_is_current`).
function _monomorphize_function_once(func_name::String, type_params::Dict{Symbol, <:Type};
                                     restored_override = nothing)
    registered = lock(REGISTRY_LOCK) do
        get(GENERIC_FUNCTION_REGISTRY, func_name, nothing)
    end
    registered === nothing && error("Function '$func_name' is not registered as a generic function")
    registered.group === nothing ||
        return _monomorphize_generic_struct_group(registered.group, func_name, type_params)

    begin
        # Retain the registration snapshot, but do not hold STATE while
        # computing identity, extracting, compiling, or opening an image.
        generic_info = registered

        # Compile the specialized function with the compiler the block was
        # expanded for (its #[cfg] snapshot), falling back to the default.
        compiler = something(generic_info.compiler, get_default_compiler())
        id = _monomorphization_id(generic_info, func_name, type_params, compiler)
        cache_key = artifact_key(id)

        cached = get(MONOMORPHIZED_FUNCTIONS, cache_key, nothing)
        cached === nothing || return cached

        isempty(generic_info.blocked) || throw(RustError(generic_info.blocked))

        # A human-readable name for the instantiation, built from the type
        # parameters in *declaration* order, plus a short id so that a permuted
        # instantiation with the same type set cannot claim the same symbol
        # (`pair<i32,i64>` and `pair<i64,i32>` both read `pair_i32_i64`, #247).
        type_suffix = join([_rust_type_suffix(t) for (_, t) in id.type_params], "_")
        specialized_name = "$(func_name)_$(type_suffix)_$(artifact_short_id(cache_key, 8))"

        # An instantiation an earlier session already built is reused whole
        # (#254): the record beside the cached library carries everything the
        # extractor said about it, so neither the extractor nor `rustc` runs.
        restored = restored_override === nothing ?
            _restore_generic_artifact(cache_key, func_name) : restored_override
        batch_key = restored === nothing ? nothing : restored.batch_key
        if restored === nothing
            # Instantiate through the extractor: the specialized function is added
            # to the registered source (context + generic code) with the concrete
            # types substituted at the AST level and exported as
            # `#[no_mangle] extern "C"`.
            bindings = Pair{String, String}[string(p) => julia_type_to_rust_string(type_params[p])
                                            for p in generic_info.type_params]
            full_source = isempty(generic_info.context) ? generic_info.code :
                          generic_info.context * "\n" * generic_info.code
            specialized = specialize_generic(full_source, generic_info.path, bindings,
                                             specialized_name)
            lib_path = _compile_generic_source(specialized.source, compiler, generic_info.cargo)
            members = Pair{String, SpecializedFunction}[func_name => specialized]
            if _cache_generic_library(cache_key, lib_path, specialized.source,
                                      members, compiler) !== nothing
                _record_generic_specialization(cache_key, cache_key, members)
            end
        else
            hit = findfirst(p -> first(p) == func_name, restored.members)
            specialized = last(restored.members[hit])
            lib_path = restored.lib_path
        end

        # Load and register the instantiation under its artifact identity.
        # `basename(lib_path)` used to be the key, but `_unique_source_name`
        # returns the constant "rust_code" outside debug mode, so *every*
        # instantiation collided on one RUST_LIBRARIES entry (the
        # `:lib_basename` divergence recorded in src/loadpolicy.jl).
        #
        # `generics_policy()` registers `:insert_only`: two tasks racing on the
        # same instantiation both compile and both `dlopen`, and the loser's
        # duplicate handle is closed by `load_artifact!` rather than replacing
        # a live entry and discarding its function-pointer cache. The exported
        # symbol is the additive wrapper the extractor emitted next to the
        # instantiation, never the instantiation's own name (#279); resolving
        # it eagerly puts it in the winner's cache inside the same transaction.
        lib_name = "rust_generic_$(artifact_short_id(cache_key))"
        specialized_symbol = specialized.symbol
        artifact = load_artifact!(generics_policy(), lib_path;
                                  lib_name, eager = (specialized_symbol,),
                                  snapshot_env = generic_info.cargo === nothing ? nothing :
                                                 _cargo_build_env(generic_info.cargo.env))

        func_ptr = Libdl.dlsym(artifact.handle, specialized_symbol; throw_error=false)
        if func_ptr === nothing || func_ptr == C_NULL
            # A restored artifact has no source to show: it was not generated
            # in this session, which is the point of restoring it (#254).
            detail = isempty(specialized.source) ? "" :
                     "\n\nSpecialized code was:\n$(specialized.source)"
            error("Function '$(specialized_symbol)' not found in library '$lib_path'." * detail)
        end

        # Return and argument types come from the manifest of the specialized
        # function, never from scanning the generated source.
        arg_types = Type[_specialized_arg_type(t, type_params) for t in specialized.arg_types]

        # Fixed `String` / `&str` parameters and returns use the string ABI
        # (#242): the specialized wrapper takes `(ptr, len)` pairs and returns
        # an owned buffer (released through `<name>_free_rust_string`) or a
        # borrowed view; see `_call_monomorphized`. A lowered string return is
        # decided here, *before* the plain return type is resolved: the buffer
        # is not a single C slot and asking the contract for one would fail
        # closed on a return the wrapper handles perfectly well.
        string_return = :none
        free_ptr = C_NULL
        if specialized.has_owned_string_helper
            string_return = :owned
            # The string helpers hang off the instantiation's FFI name — its
            # own name, qualified by the module the generic lives in (#279, #300).
            free_name = ffi_free_symbol(specialized.ffi_name)
            free_ptr = Libdl.dlsym(artifact.handle, free_name; throw_error=false)
            if free_ptr === nothing || free_ptr == C_NULL
                error("Function '$free_name' not found in library '$lib_path'")
            end
        elseif specialized.has_borrowed_string_helper
            string_return = :borrowed
        end

        # Return type from the manifest of the specialized function, never from
        # scanning the generated source. A fixed type the contract does not
        # cover goes through `FFI_STRICT[]` like every other return site.
        ret_type = if string_return === :none
            _specialized_return_type(specialized.return_type,
                                     ffi_signature_context(specialized.name,
                                                           specialized.arg_types,
                                                           specialized.return_type))
        else
            String
        end

        # Create FunctionInfo. It is a *snapshot*: it is cached and used long
        # after this lookup, so everything the call needs — the panic channel
        # included — is resolved here, against the handle the pointer came
        # from. Looking the channel up later by library name could find no
        # library (an unload between the cache hit and the call) and answer
        # `C_NULL`, while `func_ptr` still enters the mapped retired image; a
        # panic would then be read as a successful zero (#244, #277).
        channel = Libdl.dlsym(artifact.handle, ffi_panic_symbol(specialized_symbol);
                              throw_error = false)
        channel = (channel === nothing) ? C_NULL : channel
        info = FunctionInfo(specialized_symbol, lib_name, ret_type, arg_types, func_ptr,
                            specialized.arg_abis, string_return, free_ptr,
                            channel, artifact.handle, artifact.generation)

        # Cache the monomorphized function, and remember whose it is (#397).
        owner_binding = _owner_binding(registered, type_params)
        published = lock(REGISTRY_LOCK) do
            # Released while this task was between the load and here: do not
            # cache a pointer into an image the registry has let go of.
            _image_is_current(lib_name, artifact.handle, artifact.generation) || return nothing
            # A batch copy taken before a release and opened after it revives
            # the released image; that is not the fresh image the release
            # promised, so it is not published either.
            _batch_copy_is_current(batch_key, lib_path) || return :revived
            # The other order of that race: a batch member that *lost* the
            # `:insert_only` load was handed whatever image the name had, and
            # that may be the image a stale reader revived from an older copy
            # and has not retired again yet. The memo is current and so is the
            # image, yet it was not opened from the copy the memo names — not
            # published either; the retry finds a fresh image (#397 review).
            _opened_from_current_copy(batch_key, artifact, lib_name, lib_path) || return :revived
            MONOMORPHIZATION_OWNERS[cache_key] = MonomorphizationOwner(func_name, owner_binding)
            GENERIC_IMAGE_PATHS[lib_name] = lib_path
            get!(MONOMORPHIZED_FUNCTIONS, cache_key, info)
        end
        if published === :revived
            # If this task is the one that registered the retired image again,
            # retire it again — nothing was published against it — so the
            # retry does not lose the `:insert_only` race to it and opens a
            # fresh copy instead. Conditional on having installed it and on
            # the generation this load produced: a task that merely *lost* the
            # race to a fresh incumbent another caller had already registered
            # under the name must leave that incumbent alone (#397 review).
            artifact.installed &&
                unload_artifact!(generics_policy(), lib_name;
                                 expect_generation = artifact.generation)
            return nothing
        end
        return published
    end
end

"""
    _monomorphize_generic_struct_group(group, func_name, type_params)

Compile every wrapper of one generic struct instantiation into one cdylib.
The constructor and `free` wrapper therefore use the same allocator, and all
methods share the same generation snapshot (#291).
"""
function _monomorphize_generic_struct_group(group::Symbol, func_name::String,
                                             type_params::Dict{Symbol, <:Type})
    members = lock(REGISTRY_LOCK) do
        sort!([info for info in values(GENERIC_FUNCTION_REGISTRY)
               if info.group === group]; by = info -> info.name)
    end
    begin
        isempty(members) && error("Generic struct group '$group' is not registered")
        target = findfirst(info -> info.name == func_name, members)
        target === nothing && error("Function '$func_name' is not registered in generic struct group '$group'")
        target_info = members[target]
        type_values = Type[type_params[p] for p in target_info.type_params]
        # A method may add its own generic parameters after the struct's.
        # Constructing S<T> does not bind map<U>'s U: leave that wrapper out
        # of this instantiation instead of indexing beyond type_values
        # while merely assembling the group's cache keys.
        members = filter(info -> length(info.type_params) <= length(type_values), members)
        params_for(info) = Dict{Symbol, Type}(p => type_values[i]
                                              for (i, p) in enumerate(info.type_params))
        first_info = first(members)
        compiler = something(first_info.compiler, get_default_compiler())
        group_id = ArtifactId(;
            kind = "generic_struct",
            source = isempty(first_info.context) ? first_info.code :
                     first_info.context * "\n" * first_info.code,
            type_params = artifact_type_params(first_info.type_params, params_for(first_info)),
            target_triple = compiler.target_triple,
            codegen = artifact_codegen_options(compiler),
            _generic_cargo_identity(first_info.cargo)...,
            extra = Pair{String, String}["group" => String(group)],
        )
        group_key = artifact_key(group_id)
        member_keys = Dict{String, String}(
            info.name => artifact_key(_monomorphization_id(info, info.name,
                                                           params_for(info), compiler))
            for info in members)
        cached = get(MONOMORPHIZED_FUNCTIONS, member_keys[func_name], nothing)
        cached === nothing || return cached
        for info in members
            isempty(info.blocked) || throw(RustError(info.blocked))
        end

        # An instantiation of this group that an earlier session already built is
        # reused whole (#254). The record lists the members that build settled
        # on, so the applicability filter below — which costs one `rustc
        # --emit=metadata` per probe — is replayed rather than recomputed. A
        # record that does not cover the member being asked for is a miss: the
        # rebuild recomputes applicability and reports an inapplicable member
        # with the compiler's own diagnostics, exactly as before.
        restored = _restore_generic_artifact(group_key, func_name)
        if restored === nothing
            type_suffix = join([_rust_type_suffix(t) for (_, t) in group_id.type_params], "_")
            specs = NamedTuple[]
            for info in members
                member_params = params_for(info)
                bindings = Pair{String, String}[string(p) => julia_type_to_rust_string(member_params[p])
                                                for p in info.type_params]
                push!(specs, (fn = info.path, bindings = bindings,
                              new_name = "$(info.name)_$(type_suffix)_$(artifact_short_id(group_key, 8))"))
            end
            full_source = isempty(first_info.context) ? first_info.code :
                          first_info.context * "\n" * first_info.code
            specialized = specialize_generic_group(full_source, specs)
            if !_generic_group_typechecks(specialized.source, compiler, first_info.cargo)
                # Rust decides applicability. A concrete type can satisfy the
                # constructor's bounds without satisfying every method's bounds.
                # Keep all applicable wrappers together, including allocation and
                # destruction, and report an invalid member only when requested.
                applicable = Int[]
                for i in eachindex(specs)
                    candidate = specialize_generic_group(full_source, [specs[i]])
                    if _generic_group_typechecks(candidate.source, compiler, first_info.cargo)
                        push!(applicable, i)
                    elseif members[i].name == func_name
                        # Use the normal compiler diagnostics for the requested
                        # invalid specialization; this build is expected to fail.
                        _compile_generic_source(candidate.source, compiler, first_info.cargo)
                        error("Specialization applicability probe disagreed with compilation")
                    end
                end
                members = members[applicable]
                specs = specs[applicable]
                specialized = specialize_generic_group(full_source, specs)
            end
            lib_path = _compile_generic_source(specialized.source, compiler, first_info.cargo)
            specialized_functions = specialized.functions
            recorded = Pair{String, SpecializedFunction}[info.name => sp
                                                         for (info, sp) in zip(members, specialized_functions)]
            if _cache_generic_library(group_key, lib_path, specialized.source,
                                      recorded, compiler) !== nothing
                _record_generic_specialization(group_key, group_key, recorded)
            end
        else
            by_name = Dict{String, SpecializedFunction}(first(p) => last(p)
                                                        for p in restored.members)
            members = filter(info -> haskey(by_name, info.name), members)
            specialized_functions = SpecializedFunction[by_name[info.name] for info in members]
            lib_path = restored.lib_path
        end
        batch_key = restored === nothing ? nothing : restored.batch_key
        lib_name = "rust_generic_struct_$(artifact_short_id(group_key))"
        eager = [s.symbol for s in specialized_functions]
        artifact = load_artifact!(generics_policy(), lib_path; lib_name, eager,
                                  snapshot_env = first_info.cargo === nothing ? nothing :
                                                 _cargo_build_env(first_info.cargo.env))

        compiled = Dict{String, FunctionInfo}()
        named_members = Dict{String, FunctionInfo}()
        for (info, sp) in zip(members, specialized_functions)
            func_ptr = Libdl.dlsym(artifact.handle, sp.symbol; throw_error = false)
            (func_ptr === nothing || func_ptr == C_NULL) &&
                error("Function '$(sp.symbol)' not found in library '$lib_path'")
            arg_types = Type[_specialized_arg_type(t, params_for(info)) for t in sp.arg_types]
            string_return = :none
            free_ptr = C_NULL
            if sp.has_owned_string_helper
                string_return = :owned
                free_ptr = Libdl.dlsym(artifact.handle, ffi_free_symbol(sp.ffi_name);
                                       throw_error = false)
                (free_ptr === nothing || free_ptr == C_NULL) &&
                    error("Function '$(ffi_free_symbol(sp.ffi_name))' not found in library '$lib_path'")
            elseif sp.has_borrowed_string_helper
                string_return = :borrowed
            end
            ret_type = if string_return === :none
                try
                    _specialized_return_type(sp.return_type,
                                             ffi_signature_context(sp.name, sp.arg_types,
                                                                   sp.return_type))
                catch
                    # A group can contain a method whose concrete return is
                    # outside the FFI contract even when the constructor being
                    # requested is valid. Leave that member uncached so a
                    # later call reports the same contract error at its own
                    # call site instead of failing construction of the object.
                    info.name == func_name && rethrow()
                    continue
                end
            else
                String
            end
            channel = Libdl.dlsym(artifact.handle, ffi_panic_symbol(sp.symbol);
                                  throw_error = false)
            channel = (channel === nothing) ? C_NULL : channel
            compiled[member_keys[info.name]] =
                FunctionInfo(sp.symbol, lib_name, ret_type, arg_types, func_ptr,
                             sp.arg_abis, string_return, free_ptr, channel,
                             artifact.handle, artifact.generation)
            named_members[info.name] = compiled[member_keys[info.name]]
        end
        published = lock(REGISTRY_LOCK) do
            cached = get(MONOMORPHIZED_FUNCTIONS, member_keys[func_name], nothing)
            cached === nothing || return cached
            # Same guards as the function path: an image released between the
            # load and this publication is not cached, nor a batch copy the
            # memo no longer names, nor an incumbent opened from a copy other
            # than the one it names (#397 review).
            _image_is_current(lib_name, artifact.handle, artifact.generation) || return nothing
            _batch_copy_is_current(batch_key, lib_path) || return :revived
            _opened_from_current_copy(batch_key, artifact, lib_name, lib_path) || return :revived
            for (key, info) in compiled
                MONOMORPHIZED_FUNCTIONS[key] = info
            end
            # Every *compiled* member of the group is owned by the generic it
            # was registered as, so releasing any one member's generic releases
            # the image they share (#397). Only the keys with a row: a member
            # whose concrete type falls outside the FFI contract is left out of
            # `compiled` above, and an owner without a row is a tombstone that
            # no purge — which walks the rows — could ever remove.
            for member in members
                key = member_keys[member.name]
                haskey(compiled, key) &&
                    (MONOMORPHIZATION_OWNERS[key] =
                        MonomorphizationOwner(member.name, _owner_binding(member, params_for(member))))
            end
            GENERIC_IMAGE_PATHS[lib_name] = lib_path
            GENERIC_STRUCT_ARTIFACTS[(lib_name, artifact.alive)] = named_members
            MONOMORPHIZED_FUNCTIONS[member_keys[func_name]]
        end
        if published === :revived
            # As on the function path: retire what this task revived — and
            # only that; a loser installed nothing — so the retry opens a
            # fresh copy (#397 review).
            artifact.installed &&
                unload_artifact!(generics_policy(), lib_name;
                                 expect_generation = artifact.generation)
            return nothing
        end
        return published
    end
end

"""
    _generic_binding(generic_info, instantiation) -> Dict{Symbol, Type}

One instantiation of `precompile_generics`, normalized to the parameter map
`monomorphize_function` takes. A bare `Type` binds a single-parameter generic, a
`Tuple` of types binds the parameters in **declaration order**, and a mapping —
a `Dict`, a single `param => type` pair, or any collection of them — binds them
by name.

Every spelling is checked against the declared parameters before it is used: a
map that leaves one unbound or names one that does not exist is an
`ArgumentError` here, rather than a specialization the extractor is asked to
produce for a parameter the generic does not have.
"""
function _generic_binding(generic_info, instantiation)
    params = generic_info.type_params
    if instantiation isa Type
        length(params) == 1 || throw(ArgumentError(
            "'$(generic_info.name)' has $(length(params)) type parameters; " *
            "pass a tuple of $(length(params)) types, not a single type"))
        return Dict{Symbol, Type}(only(params) => instantiation)
    elseif instantiation isa Tuple && !isempty(instantiation) && all(p -> p isa Pair, instantiation)
        # `(:T => Int32, :U => Int64)` reads as a mapping, not as two positional
        # types: a `Pair` is not a type, so the positional branch below could
        # only reject it.
        return _generic_binding_map(generic_info, instantiation)
    elseif instantiation isa Tuple
        length(instantiation) == length(params) || throw(ArgumentError(
            "'$(generic_info.name)' has $(length(params)) type parameters but " *
            "$(length(instantiation)) types were given"))
        all(t -> t isa Type, instantiation) ||
            throw(ArgumentError("a generic instantiation must be given as types"))
        return Dict{Symbol, Type}(p => instantiation[i] for (i, p) in enumerate(params))
    elseif instantiation isa AbstractDict || instantiation isa Pair ||
           instantiation isa AbstractVector{<:Pair}
        return _generic_binding_map(generic_info, instantiation)
    end
    throw(ArgumentError("cannot read $(repr(instantiation)) as a generic instantiation; " *
                        "pass a type, a tuple of types, or a parameter mapping"))
end

# The mapping spellings, all reduced to `param => type` pairs. Values are
# checked to be types here, so a wrong one names itself instead of failing as a
# `convert` deep inside the `Dict` constructor.
function _generic_binding_map(generic_info, mapping)
    params = generic_info.type_params
    pairs = mapping isa Pair ? (mapping,) : mapping
    bound = Dict{Symbol, Type}()
    for (k, v) in pairs
        name = Symbol(k)
        v isa Type || throw(ArgumentError(
            "instantiation of '$(generic_info.name)' binds $(name) to " *
            "$(repr(v)), which is not a type"))
        name in params || throw(ArgumentError(
            "'$(generic_info.name)' has no type parameter $(name); it declares " *
            "$(join(string.(params), ", "))"))
        bound[name] = v
    end
    missing_params = [p for p in params if !haskey(bound, p)]
    isempty(missing_params) || throw(ArgumentError(
        "instantiation of '$(generic_info.name)' does not bind " *
        "$(join(string.(missing_params), ", "))"))
    return bound
end

"""
    precompile_generics(func_name, instantiations...) -> Vector{FunctionInfo}

Instantiate the registered generic function `func_name` at every listed set of
concrete types, compiling all of the instantiations that are still missing into
**one** shared library with **one** `rustc` (or Cargo) invocation, and persist
them so that later sessions need none at all (#254).

Each instantiation is a type (for a single-parameter generic), a tuple of types
in declaration order, or a `param => type` mapping:

```julia
RustCall.precompile_generics("identity", Int32, Int64, Float64)
RustCall.precompile_generics("pair", (Int32, Int64), (Int64, Int32))
```

Instantiations this session already holds, and those an earlier session left in
the cache, are not rebuilt — so a second call, or a second session, compiles
nothing. Lazily instantiating a batched type later in the *same* session, or in
any later one, finds the batch library and opens exactly that one image, rather
than one image per type.

A generic **struct** group is left alone: every wrapper of one instantiation of
a group already shares a single cdylib, and its members must stay together for
allocation and destruction to share an allocator (#291). Instantiations of a
group are therefore built one at a time, through the ordinary path.

Returns the `FunctionInfo` of each requested instantiation, in the order given.
"""
function precompile_generics(func_name::AbstractString, instantiations...)
    name = String(func_name)
    registered = lock(REGISTRY_LOCK) do
        get(GENERIC_FUNCTION_REGISTRY, name, nothing)
    end
    registered === nothing && error("Function '$name' is not registered as a generic function")
    bindings = Dict{Symbol, Type}[_generic_binding(registered, inst) for inst in instantiations]
    isempty(bindings) && return FunctionInfo[]
    registered.group === nothing &&
        _batch_monomorphize(registered, name, bindings)
    return FunctionInfo[monomorphize_function(name, b) for b in bindings]
end

"""
    release_generics(func_name; close = false) -> Int
    release_generics(func_name, instantiations...; close = false) -> Int


Retire the images behind the instantiations of the registered generic
`func_name` — every one of them, or only the listed ones, spelled as for
`precompile_generics` — and return how many instantiations **left the
registry** (#397). That can exceed the number asked for: releasing is per
image, and an image built by `precompile_generics` holds several
instantiations (see below), so `release_generics(f, Int8)` against a batch of
`Int8` and `Int16` returns `2`.

Lazy instantiation maps one image per type and, until this existed, nothing
ever unmapped one: a long session touching many types accumulated them for
its lifetime. This is the explicit answer, because the implicit one is not
decidable — an instantiation hands out a raw function pointer, and a generic
struct instantiation hands out objects holding a destructor pointer and the
image's liveness flag (#291), so the registry cannot know when nothing refers
to an image any more. You can.

# What "retire" means here

Exactly what it means for `unload_library`: the instantiation leaves the
registry, so the next call at those types produces a **new** image with its
own statics and its own liveness flag, and the old image stays **mapped** —
retired, not closed — so a pointer or object still holding it keeps working,
and an object that is finalized later frees through the image that allocated
it. `close = true` also closes the retired images, flipping their liveness
flags first so that any surviving object goes inert instead of calling into
unmapped code; pass it only when you know no call into them is in flight and
no object from them is still in use, as for `unload_library(name; close = true)`.

Released in two steps is the safe way to reclaim: `release_generics(f)` now,
so no new call reaches the old images, and `release_generics(f; close = true)`
once you know nothing holds a pointer or an object from them. The closing call
also closes the images an earlier non-closing release of `f` retired and left
mapped (the typed form, those that carried one of the named types); its return
value still counts only the instantiations it retires itself.

Two consequences of how instantiations are laid out:

  * Instantiations built together by `precompile_generics` share one library.
    Releasing one of them retires that library, so the others leave the
    registry with it; each comes back — from the cache, without a rebuild — on
    its next call, as a fresh image. Releasing is per image, and the batch is
    the image.
  * A generic **struct** group is one library per instantiation, with every
    member wrapper in it (#291). Naming any member's generic releases the
    instantiation the way the members share it.

Nothing about the on-disk cache changes: a released instantiation is restored
from it on the next call and runs neither the extractor nor `rustc` (#254).
"""
function release_generics(func_name::AbstractString, instantiations...; close::Bool = false)
    name = String(func_name)
    registered = lock(REGISTRY_LOCK) do
        get(GENERIC_FUNCTION_REGISTRY, name, nothing)
    end
    registered === nothing && error("Function '$name' is not registered as a generic function")

    # Which instantiations are being released: all of the generic's, or the
    # listed bindings'. Matched on the bindings each row recorded when it was
    # published, never on an artifact key recomputed now: the key folds the
    # compiler and the source in, and an instantiation built under an earlier
    # default compiler, or before the generic was re-registered, is still this
    # generic's and still mapped (#397 review).
    selected = isempty(instantiations) ? nothing :
               Set{Tuple}(_release_binding(registered, inst) for inst in instantiations)

    # The images to retire, found under one lock: every registered
    # instantiation owned by `name` (and selected, if a set was given), grouped
    # by the library it lives in.
    # Selected once, *with* the image each row was resolved on: the handle and
    # the generation of its name. A later transaction must not re-read those
    # from the registry — between the two, another release can retire this
    # image and a concurrent caller publish a replacement under the same name,
    # and a fresh read would then authorize retiring the replacement.
    images = lock(REGISTRY_LOCK) do
        found = Dict{String, Tuple{Ptr{Cvoid}, Int}}()
        for (key, owner) in MONOMORPHIZATION_OWNERS
            owner.generic == name || continue
            selected === nothing || owner.binding in selected || continue
            info = get(MONOMORPHIZED_FUNCTIONS, key, nothing)
            info === nothing && continue
            found[info.lib_name] = (info.handle, info.generation)
        end
        found
    end
    if isempty(images)
        # Nothing live to retire — the closing step of a two-step release
        # still has the earlier retirements to close.
        close && _close_released_generic_images!(name, selected)
        return 0
    end

    released = 0
    for (lib_name, (handle, generation)) in images
        # One state transition does everything that must precede the
        # retirement (#397 review). Confirm the image selected above is still
        # the one registered under its name — same handle, same generation —
        # count what leaves with it, and drop every memo that could revive it:
        # the process-private copy a batch is opened from
        # (`_shared_batch_copy`), and the path record of every name on this
        # handle. Doing this before `unload_artifact!` rather than after is the
        # point: a restore that lands in between now makes a fresh copy and
        # loads a fresh path, and if it loses the `:insert_only` race to the
        # still-registered image it is retired with it a moment later. Counted
        # before the unload as well, because `purge_library_state!` inside it
        # drops the rows.
        #
        # The count is by handle alone. The image is the unit of retirement:
        # a batch member restored and released on its own advances its *name's*
        # generation past its siblings', yet a later load of both gives them
        # one handle again — and releasing either unloads every name on it. A
        # live row can only point at the live image of its handle (a retired
        # image's rows were purged with it), so the handle is exact.
        names, leaving, carried = lock(REGISTRY_LOCK) do
            entry = get(RUST_LIBRARIES, lib_name, nothing)
            (entry === nothing || entry[1] != handle ||
             get(ARTIFACT_GENERATIONS, lib_name, 0) != generation) && return (String[], 0, ())
            names = String[n for (n, e) in RUST_LIBRARIES if e[1] == handle]
            leaving = count(info -> info.handle == handle, values(MONOMORPHIZED_FUNCTIONS))
            # What this generic had on the image, remembered for a later
            # closing release (`RELEASED_GENERIC_IMAGES`).
            carried = Tuple(owner.binding for (key, owner) in MONOMORPHIZATION_OWNERS
                            if owner.generic == name &&
                               (info = get(MONOMORPHIZED_FUNCTIONS, key, nothing)) !== nothing &&
                               info.handle == handle)
            paths = Set{String}(GENERIC_IMAGE_PATHS[n] for n in names
                                if haskey(GENERIC_IMAGE_PATHS, n))
            for (batch, path) in collect(_BATCH_LIBRARY_COPIES)
                path in paths && delete!(_BATCH_LIBRARY_COPIES, batch)
            end
            for n in names
                delete!(GENERIC_IMAGE_PATHS, n)
            end
            # Left mapped by this release: on record *before* the retirement,
            # so a closing release racing this one never finds the rows gone
            # and the record absent; withdrawn below if nothing retired it.
            # One entry per image — two releases selecting the same image
            # share it, and whichever loses the retirement must not take the
            # winner's record with it (#397 review).
            # Values are immutable tuples replaced whole through the view, so
            # every write goes through the state container's mutation path.
            alive = get(ARTIFACT_ALIVE, lib_name, nothing)
            if !close && alive !== nothing
                entries = get(RELEASED_GENERIC_IMAGES, name, ())
                any(e -> e.alive === alive, entries) ||
                    (RELEASED_GENERIC_IMAGES[name] =
                        (entries..., ReleasedGenericImage(lib_name, handle, generation, alive, carried)))
            end
            (names, leaving, carried)
        end
        isempty(names) && continue
        # Unloading one name of an image unloads every name of it, so a batch
        # member's siblings — registered under their own names on the same
        # handle — leave the registry with it. Conditional on the generation
        # captured above: two concurrent releases of one image must not both
        # count it, and a release must not retire a *newer* image that a
        # concurrent instantiation registered under the name in between.
        # Only the call whose retirement actually happened counts.
        # Nothing follows the unload. `unload_artifact!` retires every name on
        # the handle in its own transaction, and `purge_library_state!` drops
        # each name's instantiation rows, their owners and the image's path
        # record with it — so there is no second transaction here in which a
        # replacement that reused the pointer value could be mistaken for the
        # image just retired (#397 review).
        # Always a retirement, never the loader's own `close = true`: that
        # closes every retired image carrying any of the handle's names, and
        # an older image of the same instantiation released earlier without
        # closing — whose pointers a caller may still hold — is one of them.
        # Closing is done by handle below, exactly this image (#397 review).
        retired = unload_artifact!(generics_policy(), lib_name;
                                   expect_generation = generation)
        if !retired
            # This call retired nothing. Its record stays only if the image
            # did leave the registry under someone else — another release,
            # whose record this is too — and goes if the image is still live.
            close || _withdraw_released_image!(name, lib_name, handle, generation)
            continue
        end
        released += leaving
        close && close_retired_handles!([handle])
    end
    close && _close_released_generic_images!(name, selected)
    return released
end

# Drop the record a release made for an image it then did not retire — unless
# the image is no longer the live one of its name, in which case something
# else retired it and the record describes a retired image after all (a
# concurrent release of the same image, which shares the entry).
function _withdraw_released_image!(name::String, lib_name::String, handle::Ptr{Cvoid},
                                   generation::Int)
    lock(REGISTRY_LOCK) do
        _image_is_current(lib_name, handle, generation) || return
        entries = get(RELEASED_GENERIC_IMAGES, name, nothing)
        entries === nothing && return
        kept = Tuple(e for e in entries if !(e.handle == handle && e.generation == generation))
        length(kept) == length(entries) && return
        isempty(kept) ? delete!(RELEASED_GENERIC_IMAGES, name) : (RELEASED_GENERIC_IMAGES[name] = kept)
    end
    return nothing
end

# Whether the image a history entry describes is still the one registered
# under its name — same handle, same generation, and the same flag. Caller
# holds REGISTRY_LOCK.
_released_image_is_live(e::ReleasedGenericImage) =
    _image_is_current(e.lib, e.handle, e.generation) &&
    get(ARTIFACT_ALIVE, e.lib, nothing) === e.alive

# The second step of a two-step release: close the images an earlier
# non-closing `release_generics(name)` retired — all of them, or those that
# carried one of the `selected` bindings — and forget them. Decided under the
# lock against the retired-handle records: an entry whose image is retired now
# is closed; one whose image is still the live one of its name is a retirement
# in flight and stays on record; one that is neither — closed or replaced by
# other means — is forgotten.
function _close_released_generic_images!(name::String, selected)
    to_close = lock(REGISTRY_LOCK) do
        entries = get(RELEASED_GENERIC_IMAGES, name, nothing)
        entries === nothing && return Ptr{Cvoid}[]
        handles = Ptr{Cvoid}[]
        kept = Tuple(e for e in entries if begin
            keep = if selected !== nothing && !any(b -> b in selected, e.carried)
                true
            elseif _released_image_is_live(e)
                # Still the live image of its name: a retirement in flight.
                true
            else
                # Retired now — the *same* image, by its flag: a pointer value
                # the loader reused for a later image of the name is not it.
                record = get(RETIRED_HANDLES, e.handle, nothing)
                record !== nothing && record.alive === e.alive && push!(handles, e.handle)
                false
            end
            keep
        end)
        if length(kept) != length(entries)
            isempty(kept) ? delete!(RELEASED_GENERIC_IMAGES, name) : (RELEASED_GENERIC_IMAGES[name] = kept)
        end
        unique(handles)
    end
    isempty(to_close) || close_retired_handles!(to_close)
    return nothing
end

# Compile every instantiation in `bindings` that is neither in memory nor in the
# cache into one library. Best-effort by design: whatever it leaves undone, the
# `monomorphize_function` calls that follow do one at a time.
function _batch_monomorphize(generic_info, func_name::String,
                             bindings::Vector{Dict{Symbol, Type}})
    isempty(generic_info.blocked) || throw(RustError(generic_info.blocked))
    compiler = something(generic_info.compiler, get_default_compiler())
    todo = NamedTuple[]
    seen = Set{String}()
    for params in bindings
        id = _monomorphization_id(generic_info, func_name, params, compiler)
        key = artifact_key(id)
        key in seen && continue
        push!(seen, key)
        haskey(MONOMORPHIZED_FUNCTIONS, key) && continue
        # The probe, not the restore: this only asks whether the instantiation
        # is already cached, and materializing a private copy of every cached
        # library just to answer that would copy a dylib per skipped type.
        _cached_generic_artifact(key, func_name) === nothing || continue
        push!(todo, (; key, id, params))
    end
    length(todo) < 2 && return nothing  # nothing to gain from a batch of one
    # Canonical order, so that the same set of instantiations is the same batch
    # whatever order the caller listed them in.
    sort!(todo; by = entry -> entry.key)

    full_source = isempty(generic_info.context) ? generic_info.code :
                  generic_info.context * "\n" * generic_info.code
    specs = NamedTuple[]
    for entry in todo
        # Exactly the name and bindings `monomorphize_function` would produce
        # for this instantiation on its own: `id.type_params` carries the Julia
        # type names (the readable suffix), the bindings the Rust spellings.
        suffix = join([_rust_type_suffix(t) for (_, t) in entry.id.type_params], "_")
        push!(specs, (fn = generic_info.path,
                      bindings = Pair{String, String}[string(p) => julia_type_to_rust_string(entry.params[p])
                                                      for p in generic_info.type_params],
                      new_name = "$(func_name)_$(suffix)_$(artifact_short_id(entry.key, 8))"))
    end
    specialized = specialize_generic_group(full_source, specs)
    built = try
        _compile_generic_source(specialized.source, compiler, generic_info.cargo)
    catch err
        # One inapplicable type poisons the whole batch. Fall back to building
        # the instantiations one at a time, where the caller gets the
        # compiler's diagnostics for the type that is actually at fault.
        (err isa CompilationError || err isa CargoBuildError) || rethrow()
        @debug "Batched monomorphization failed; falling back to one build per type" exception = err
        return nothing
    end

    # The batch library is one artifact of its own, and its identity is exactly
    # the set of instantiations it holds — each of which is already a full
    # artifact key. Only what was actually built is named: a request that
    # skipped some cached instantiation must not claim the identity of a
    # library that contains it.
    batch_id = ArtifactId(;
        kind = "monomorphization_batch",
        source = full_source,
        target_triple = compiler.target_triple,
        codegen = artifact_codegen_options(compiler),
        _generic_cargo_identity(generic_info.cargo)...,
        extra = Pair{String, String}[["function" => func_name];
                                     ["member" => entry.key for entry in todo]],
    )
    batch_key = artifact_key(batch_id)
    # Pair each instantiation with its wrapper **by the name it asked for**, not
    # by position in the manifest: recording one instantiation's key against
    # another's symbol would call the wrong machine code, silently (#247 is what
    # that costs).
    by_name = Dict{String, SpecializedFunction}(sp.name => sp for sp in specialized.functions)
    paired = Pair{String, SpecializedFunction}[]
    for (entry, spec) in zip(todo, specs)
        sp = get(by_name, spec.new_name, nothing)
        sp === nothing && return nothing
        push!(paired, entry.key => sp)
    end
    members = Pair{String, SpecializedFunction}[func_name => sp for (_, sp) in paired]
    _cache_generic_library(batch_key, built, specialized.source, members, compiler) === nothing &&
        return nothing
    # Each instantiation gets its own record, all naming the one library. A
    # later lazy `monomorphize_function` at any of these types therefore opens
    # that library — one path, so one image and one liveness flag.
    for (key, sp) in paired
        _record_generic_specialization(key, batch_key,
                                       Pair{String, SpecializedFunction}[func_name => sp])
    end
    return nothing
end

# Direct rustc checks only metadata. Cargo-backed checks reuse the normal
# cached build to retain dependency and build-script configuration; neither
# path loads an image while checking applicability.
function _generic_group_typechecks(source::String, compiler::RustCompiler, context = nothing)
    if context !== nothing
        try
            _compile_generic_source(source, compiler, context)
            return true
        catch err
            err isa CargoBuildError || rethrow()
            return false
        end
    end
    mktempdir() do dir
        input = joinpath(dir, "generic_group.rs")
        output = joinpath(dir, "generic_group.rmeta")
        write(input, wrap_rust_code(source))
        command = Cmd([string(rustc().exec[1]), "--crate-type=cdylib",
                       "--emit=metadata", "-C", "panic=unwind",
                       _cfg_rustc_flags(compiler)..., "-o", output, input])
        process = run(pipeline(command; stdout = devnull, stderr = devnull); wait = false)
        wait(process)
        success(process)
    end
end

"""
    register_generic_function(func_name, code, type_params, constraints, context)

Register a generic Rust function for later monomorphization.

# Arguments
- `func_name`: Name of the function
- `code`: Rust function code (with generics)
- `type_params`: List of type parameter symbols
- `constraints`: Trait bounds for type parameters (TypeConstraints or legacy Dict{Symbol, String})
- `context`: Additional code (e.g. struct definitions) needed for compilation

# Examples
```julia
# With TypeConstraints (recommended)
constraints = Dict(:T => TypeConstraints([TraitBound("Copy", []), TraitBound("Clone", [])]))
register_generic_function("identity", code, [:T], constraints)

# Legacy format (still supported)
register_generic_function("identity", code, [:T], Dict(:T => "Copy + Clone"))

# No constraints
register_generic_function("identity", code, [:T])
```
"""
function register_generic_function(
    func_name::String,
    code::String,
    type_params::Vector{Symbol},
    constraints::Dict{Symbol, TypeConstraints}=Dict{Symbol, TypeConstraints}(),
    context::String="";
    kwargs...
)
    info = _prepare_generic_function(func_name, code, type_params, constraints, context; kwargs...)
    return lock(REGISTRY_LOCK) do
        GENERIC_FUNCTION_REGISTRY[func_name] = info
        info
    end
end

# Parsing/preparation is separate from publication, so a struct can prepare
# all of its wrappers before publishing a single coherent source generation.
function _prepare_generic_function(
    func_name::String,
    code::String,
    type_params::Vector{Symbol},
    constraints::Dict{Symbol, TypeConstraints}=Dict{Symbol, TypeConstraints}(),
    context::String="";
    arg_types::Vector{String}=String[],
    return_type::String="",
    path::String=func_name,
    compiler::Union{Nothing, RustCompiler}=nothing,
    blocked::String="",
    group::Union{Nothing, Symbol}=nothing,
    cargo::Union{Nothing, GenericCargoContext}=nothing
)
    # Manual registrations usually pass only the source. Recover the argument
    # and return types (and, when not given, the trait bounds) from the
    # extractor's manifest so that inference and monomorphization work exactly
    # as for functions loaded from a rust\"\"\" block.
    if isempty(arg_types) || isempty(return_type) || isempty(constraints)
        sig = _manifest_signature_for(func_name, code)
        if sig !== nothing
            isempty(arg_types) && (arg_types = sig.arg_types)
            isempty(return_type) && (return_type = sig.return_type)
            isempty(constraints) && (constraints = sig.constraints)
        end
    end
    return GenericFunctionInfo(func_name, code, type_params, constraints, context, arg_types,
                               return_type, path, compiler, blocked, group, cargo)
end

function _publish_generic_struct_group!(group::Symbol, members::Vector{GenericFunctionInfo})
    names = Set(info.name for info in members)
    all(info -> info.group === group, members) || error("Inconsistent generic struct group")
    lock(REGISTRY_LOCK) do
        obsolete = [name for (name, info) in GENERIC_FUNCTION_REGISTRY
                    if info.group === group && !(name in names)]
        for name in obsolete
            delete!(GENERIC_FUNCTION_REGISTRY, name)
        end
        for info in members
            GENERIC_FUNCTION_REGISTRY[info.name] = info
        end
    end
    return nothing
end

# Backward compatibility: accept `Dict{Symbol, String}` bounds such as
# `Dict(:T => "Copy + Add<Output = T>")`. The strings are parsed by the Rust-side
# parser (through the extractor), never by Julia.
function register_generic_function(
    func_name::String,
    code::String,
    type_params::Vector{Symbol},
    constraints::Dict{Symbol, String},
    context::String="";
    kwargs...
)
    return register_generic_function(func_name, code, type_params,
                                     constraints_from_strings(constraints), context; kwargs...)
end

"""
    _manifest_signature_for(func_name, code) -> Union{RustFunctionSignature, Nothing}

Signature of the top-level function `func_name` in `code` according to the
extractor, or `nothing` when the code cannot be parsed or has no such function.
"""
function _manifest_signature_for(func_name::String, code::String)
    sigs = try
        manifest_function_signatures(extract_manifest(code; mode = "inline"); only_attributed = false)
    catch e
        @debug "Could not extract a manifest for generic function '$func_name'" exception = e
        return nothing
    end
    idx = findfirst(s -> s.name == func_name, sigs)
    return idx === nothing ? nothing : sigs[idx]
end

"""
    _specialized_return_type(rust_type::String, ctx::AbstractString) -> Type

Julia return type of a monomorphized function, from the FFI contract
(`src/ffi_contract.jl`). A raw pointer keeps its pointee (`*mut i32` is
`Ptr{Int32}`, an opaque pointee degrades to `Ptr{Cvoid}`), and `char` is the
surface `Char`, which `call_rust_function` reads out of its `UInt32` slot.

A fixed type the contract does not cover goes through the same
`ffi_return_type_or_throw` every other return site uses, so `FFI_STRICT[]`
governs it: `:error` raises naming the specialized signature, `:warn` warns once
and falls back to `Any`. It used to become `Any` silently, which is not a
well-defined `ccall` return slot (#276).
"""
function _specialized_return_type(rust_type::String, ctx::AbstractString)
    return ffi_return_type_or_throw(rust_type, "", ctx)
end

function _specialized_arg_type(rust_type::String, type_params::Dict{Symbol, <:Type})
    c = ffi_argument_contract(rust_type)
    c.known && c.abi === :void && return Cvoid
    if c.known && (c.abi === :by_value || c.abi === :pointer)
        return only(c.ccall_types)
    end
    p = Symbol(rust_type)
    return haskey(type_params, p) ? type_params[p] : Any
end

"""
    call_generic_function(func_name::String, args...)

Call a generic Rust function, automatically monomorphizing if needed.

# Arguments
- `func_name`: Name of the generic function
- `args...`: Arguments (types will be inferred from these)

# Example
```julia
# Assuming identity<T> is registered
result = call_generic_function("identity", Int32(42))
# Automatically monomorphizes to identity<Int32> and calls it
```
"""
function call_generic_function(func_name::String, args...)
    # Infer type parameters from arguments
    arg_types = map(typeof, args)
    type_params = infer_type_parameters(func_name, collect(arg_types))

    # Monomorphize (or get cached version)
    info = monomorphize_function(func_name, type_params)

    return _call_monomorphized(info, args...)
end

"""
    _call_monomorphized(info::FunctionInfo, args...)

Call a monomorphized function through its `FunctionInfo`. String arguments
(`info.arg_abis`) are checked to be valid UTF-8 (`ffi_string_argument`, #246)
and passed as `(ptr, len)` byte pairs kept alive for the duration of the call,
and a string return (`info.string_return`) is copied out of the owned or
borrowed buffer, exactly as the generated wrappers of non-generic `#[julia]`
functions do.
"""
function _call_monomorphized(info::FunctionInfo, args...)
    # The channel was resolved when `info` was built, against the same handle
    # `func_ptr` came from — so it is the channel of the wrapper that is about
    # to run, whatever has happened to the library's *name* since (#244, #277).
    channel = info.channel
    if info.string_return === :none && !any(_is_string_abi, info.arg_abis)
        return guard_rust_panic_ptr(
            call_rust_function(info.func_ptr, info.return_type,
                               _monomorphized_call_args(info, args)...),
            channel, info.name)
    end
    if length(info.arg_abis) != length(args)
        error("Function '$(info.name)' takes $(length(info.arg_abis)) argument(s) but $(length(args)) were given")
    end
    # The converted strings are collected in a vector, which is what
    # GC.@preserve keeps alive (and, through it, every string).
    strings = String[]
    call_args = Any[]
    for (i, (arg, abi)) in enumerate(zip(args, info.arg_abis))
        if _is_string_abi(abi)
            # The same UTF-8 check the non-generic wrappers make (#246). A
            # `FunctionInfo` records ABIs, not parameter names, so the message
            # names the position; the specialization's exported symbol is the
            # context. Without it a generic `#[julia] fn f<T>(s: &str, x: T)`
            # was the one string path left where invalid bytes reached
            # `String::from_utf8_lossy` and were silently replaced.
            s = ffi_string_argument(arg, i, info.name)
            push!(strings, s)
            push!(call_args, pointer(s))
            push!(call_args, sizeof(s) % Csize_t)
        else
            push!(call_args, _monomorphized_arg(info, i, arg))
        end
    end
    # A specialization is a wrapper like any other, so its panic channel is
    # read after the call (#244). `info.name` is the exported symbol of the
    # instantiation, which is what the channel is named after.
    GC.@preserve strings begin
        result = if info.string_return === :owned
            _call_rust_owned_string_ptr(info.func_ptr, info.free_ptr, call_args...)
        elseif info.string_return === :borrowed
            _call_rust_borrowed_string_ptr(info.func_ptr, call_args...)
        else
            call_rust_function(info.func_ptr, info.return_type, call_args...)
        end
        guard_rust_panic_ptr(result, channel, info.name)
    end
end

"""
    _monomorphized_call_args(info, args) -> Tuple

Every argument converted to the C slot the manifest recorded for it
(`info.arg_types`, resolved through the FFI contract at specialization time).

Without this the `ccall` signature was derived from the *runtime* Julia types of
the arguments, so `fn f<T>(x: T, c: char)` called with a Julia `Char` passed
that `Char`'s left-aligned UTF-8 bit pattern where Rust expects a `UInt32` code
point (#245, #276). A count mismatch is left alone: the receiver-passing paths
build their own argument lists and the call itself reports the mismatch.
"""
function _monomorphized_call_args(info::FunctionInfo, args::Tuple)
    length(info.arg_types) == length(args) || return args
    return ntuple(i -> _monomorphized_arg(info, i, args[i]), length(args))
end

function _monomorphized_arg(info::FunctionInfo, i::Integer, arg)
    i <= length(info.arg_types) || return arg
    return ffi_slot_convert(info.arg_types[i], arg)
end

"""
    is_generic_function(func_name::String) -> Bool

Check if a function is registered as a generic function.
"""
function is_generic_function(func_name::String)
    return haskey(GENERIC_FUNCTION_REGISTRY, func_name)
end

"""
    get_monomorphized_function(func_name::String, type_params::Dict{Symbol, Type}) -> Union{FunctionInfo, Nothing}

Get a monomorphized function instance if it exists.

Computes the same key as `monomorphize_function` (`_monomorphization_id`), which
needs the declared parameter order — so an unregistered generic, an incomplete
set of bindings, or an unidentifiable toolchain all mean "not cached" rather
than an error.
"""
function get_monomorphized_function(func_name::String, type_params::Dict{Symbol, <:Type})
    generic_info = get(GENERIC_FUNCTION_REGISTRY, func_name, nothing)
    begin
        generic_info === nothing && return nothing
        compiler = something(generic_info.compiler, get_default_compiler())
        cache_key = try
            artifact_key(_monomorphization_id(generic_info, func_name, type_params, compiler))
        catch
            return nothing
        end
        return get(MONOMORPHIZED_FUNCTIONS, cache_key, nothing)
    end
end
