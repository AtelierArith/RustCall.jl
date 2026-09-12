# Where RustCall's two native build products live (#258).
#
# `Pkg.build("RustCall")` compiles two crates with Cargo:
#
#   * `deps/rust_helpers`    → the ownership helper cdylib (`RUST_HELPERS_LIB`)
#   * `deps/rustcall_extract` → the `rustcall-extract` CLI (`extractor_path()`)
#
# Through v0.3.x both landed in `deps/<crate>/target/`, i.e. **inside the
# installed package directory**. That is the pre-1.3 `Pkg.build` model and it
# breaks wherever the package tree is not writable — shared/HPC depots, baked
# container images, system images, `Distributed` workers on a read-only mount.
#
# Since #258 the build location depends on what the package tree *is*:
#
#   * An **installed** package (a tree under some `DEPOT_PATH` entry's
#     `packages/` directory) is read-only by contract, so its products go to a
#     scratch space — `<depot>/scratchspaces/<RustCall UUID>/native-v1/<slug>/`.
#     The `<slug>` is Pkg's own per-version directory name, so two installed
#     RustCall versions in one depot never share a target directory and a v0.3
#     process can never pick up a v0.4 extractor.
#   * A **checkout** (a `Pkg.develop`ed clone, a git worktree, this repository)
#     keeps building in `deps/<crate>/target/`, where it already builds: the
#     documented developer commands (`cd deps/rustcall_extract && cargo build
#     --release`) write there, and sending `Pkg.build` somewhere else would
#     only mean paying for the same crates twice.
#
# This file is the single place that answers "where is it?". It is included by
# `src/RustCall.jl` **and** by `deps/build.jl`, which runs in a bare Pkg build
# environment before the module exists — so nothing here may reference any
# RustCall binding, and its only dependencies are `Scratch` and `Base`.

using Scratch: Scratch

"""
    RUSTCALL_UUID

RustCall's package UUID, as declared in `Project.toml`.

Spelled out rather than read from `Project.toml` because `deps/build.jl` needs
it before the module exists, and `Scratch` namespaces a space by UUID.
`test/test_native_layout.jl` asserts the two agree.
"""
const RUSTCALL_UUID = Base.UUID("7ac5b1a4-9e37-4f0e-9aa3-3305a66bfb1c")

"""
    NATIVE_SCRATCH_NAME

Name of the scratch space holding native build products of *installed*
packages. Bumping it abandons every previously built product, so it changes
only when the layout below changes — not when a crate changes, which Cargo
already notices by itself.
"""
const NATIVE_SCRATCH_NAME = "native-v1"

"""
    NATIVE_PRODUCTS

The two crates `deps/build.jl` builds, keyed by product. `crate` is the
directory under `deps/`, `env` the environment variable that overrides the
resolved path outright.
"""
const NATIVE_PRODUCTS = (
    rust_helpers = (crate = "rust_helpers", env = "RUSTCALL_RUST_HELPERS"),
    extractor = (crate = "rustcall_extract", env = "RUSTCALL_EXTRACT"),
)

"""
    native_package_root() -> String

The RustCall package directory — the parent of the `src/` this file lives in,
whether it was included by `src/RustCall.jl` or by `deps/build.jl`.
"""
native_package_root() = dirname(@__DIR__)

"""
    native_product_filename(kind::Symbol) -> String

The file Cargo produces for `kind` on this platform.
"""
function native_product_filename(kind::Symbol)
    if kind === :rust_helpers
        return Sys.iswindows() ? "rust_helpers.dll" :
               Sys.isapple() ? "librust_helpers.dylib" : "librust_helpers.so"
    elseif kind === :extractor
        return Sys.iswindows() ? "rustcall-extract.exe" : "rustcall-extract"
    end
    throw(ArgumentError("unknown native product: $(kind)"))
end

"""
    native_crate_dir(kind::Symbol) -> String

The crate directory under `deps/` whose `Cargo.toml` builds `kind`.
"""
function native_crate_dir(kind::Symbol)
    haskey(NATIVE_PRODUCTS, kind) ||
        throw(ArgumentError("unknown native product: $(kind)"))
    return joinpath(native_package_root(), "deps", NATIVE_PRODUCTS[kind].crate)
end

"""
    _real_path(path) -> String

`realpath` where it works, `abspath` where it does not (a path that does not
exist yet, a directory that cannot be `stat`ed). Only used to compare two
directory paths, where a failure to canonicalise is not fatal.
"""
function _real_path(path::AbstractString)
    try
        return realpath(path)
    catch
        return abspath(path)
    end
end

"""
    _under_directory(path, parent) -> Bool

Whether `path` is `parent` or lies inside it, comparing canonicalised paths.
"""
function _under_directory(path::AbstractString, parent::AbstractString)
    p = _real_path(path)
    q = _real_path(parent)
    p == q && return true
    sep = Base.Filesystem.path_separator
    return startswith(p, endswith(q, sep) ? q : q * sep)
end

"""
    native_installed_slug(root = native_package_root()) -> Union{String, Nothing}

Pkg's per-version directory name for this package tree when it is an
**installed** package — a tree under some `DEPOT_PATH` entry's `packages/`
directory, as in `<depot>/packages/RustCall/<slug>` — and `nothing` for a
checkout.

The slug is derived from the registered version's tree hash, so it is short,
stable, and already distinguishes two installed versions from each other. That
makes it the right name for a per-installation build directory: no digest of
our own, and no path long enough to trouble Windows.
"""
function native_installed_slug(root::AbstractString = native_package_root())
    for depot in DEPOT_PATH
        isempty(depot) && continue
        packages = joinpath(String(depot), "packages")
        isdir(packages) || continue
        _under_directory(root, packages) || continue
        # `<depot>/packages/<Name>/<slug>`; anything shallower is not an
        # installed package tree and is left to the checkout branch.
        parent = dirname(_real_path(root))
        _under_directory(parent, packages) && parent != _real_path(packages) &&
            return basename(_real_path(root))
    end
    return nothing
end

"""
    native_is_installed_package(root = native_package_root()) -> Bool

Whether this package tree must be treated as read-only; see
`native_installed_slug`.
"""
native_is_installed_package(root::AbstractString = native_package_root()) =
    native_installed_slug(root) !== nothing

"""
    _depot_is_writable(depot) -> Bool

Whether a scratch space can actually be created under `depot`.

`mkpath` succeeding is not enough — it is a no-op on an existing directory
whatever its mode — so this creates the `scratchspaces` directory and then
writes and removes a uniquely named probe file inside it. A read-only
`DEPOT_PATH[1]` (shared/HPC depots, baked container images) fails here and the
next depot is tried.
"""
function _depot_is_writable(depot::AbstractString)
    dir = joinpath(depot, "scratchspaces")
    try
        mkpath(dir)
        probe = joinpath(dir, ".rustcall-write-probe-$(getpid())-$(rand(UInt64))")
        touch(probe)
        rm(probe; force = true)
        return true
    catch e
        @debug "Depot is not writable for RustCall" depot exception = e
        return false
    end
end

"""
    _writable_depot() -> Union{String, Nothing}

The first entry of `DEPOT_PATH` a scratch space can be created in, or `nothing`
when there is none.

`Scratch.get_scratch!` defaults to `first(DEPOT_PATH)`; RustCall scans instead,
so a read-only first depot with a writable one behind it still works (#252).
Both the compilation cache (`get_cache_dir`) and the native build products
(`native_target_dir`) choose their depot here.
"""
function _writable_depot()
    for depot in DEPOT_PATH
        isempty(depot) && continue
        _depot_is_writable(depot) && return String(depot)
    end
    return nothing
end

"""
    native_scratch_dir(depot) -> String

The path of the native scratch space under `depot`, without creating it.

Goes through `Scratch.scratch_dir`, so `Scratch.with_scratch_directory` in a
test redirects lookups and creations together.
"""
native_scratch_dir(depot::AbstractString) =
    Scratch.scratch_dir(string(RUSTCALL_UUID), NATIVE_SCRATCH_NAME;
                        depot_path = String(depot))

"""
    native_target_dir(kind::Symbol; depot = nothing, create = false) -> String

The `CARGO_TARGET_DIR` for `kind`: `deps/<crate>/target` in a checkout, and
`<depot>/scratchspaces/<uuid>/native-v1/<slug>/<crate>` for an installed
package.

`create = true` creates the scratch space (and registers it with `Pkg.gc`'s
usage log) and is what `deps/build.jl` passes; the lookup path leaves it alone.
`depot` names the depot to build in and defaults to `_writable_depot()`.
"""
function native_target_dir(kind::Symbol; depot = nothing, create::Bool = false)
    slug = native_installed_slug()
    slug === nothing && return joinpath(native_crate_dir(kind), "target")
    chosen = depot === nothing ? _writable_depot() : String(depot)
    if chosen === nothing
        create && error("""
        RustCall cannot place the native build products for its installed copy
        at $(native_package_root()): none of the depots in DEPOT_PATH is
        writable ($(join(DEPOT_PATH, ", "))).
        """)
        chosen = first(DEPOT_PATH)
    end
    root = create ?
        Scratch.get_scratch!(RUSTCALL_UUID, NATIVE_SCRATCH_NAME; depot_path = chosen) :
        native_scratch_dir(chosen)
    dir = joinpath(root, slug, NATIVE_PRODUCTS[kind].crate)
    create && mkpath(dir)
    return dir
end

"""
    native_product_candidates(kind::Symbol) -> Vector{String}

Every path `kind` may be found at, most authoritative first:

1. its environment override (`RUSTCALL_EXTRACT` / `RUSTCALL_RUST_HELPERS`),
   when set to a non-empty value;
2. **`native_target_dir(kind)` — the directory a build would write to right
   now.** Asking the same function the build asks is what keeps the two from
   drifting: with a read-only `DEPOT_PATH[1]` in front of a writable depot,
   `Pkg.build` lands in the writable one, and enumerating `DEPOT_PATH` in
   order would otherwise prefer a stale product the first depot happens to
   carry for the same slug;
3. for an installed package, its scratch directory under every *other* depot
   on `DEPOT_PATH`, so a package installed in a depot that has since moved
   behind another still finds its products;
4. the legacy in-package location `deps/<crate>/target/release`, for an
   installed tree built by RustCall ≤ v0.3.4 and not rebuilt since;
5. for the extractor only, the `debug` profile of each directory above.

Paths are returned whether or not they exist; callers filter. Deciding (2) for
an installed package probes each depot for writability, which creates that
depot's `scratchspaces` directory — the one `Scratch` would create anyway — and
writes nothing else.
"""
function native_product_candidates(kind::Symbol)
    file = native_product_filename(kind)
    out = String[]
    env = get(ENV, NATIVE_PRODUCTS[kind].env, "")
    isempty(env) || push!(out, env)

    # Only the extractor has ever been used from a `debug` build.
    profiles = kind === :extractor ? ("release", "debug") : ("release",)
    # The build's own answer comes first, so a fresh `Pkg.build` always wins
    # over whatever another depot happens to carry for the same slug.
    dirs = String[native_target_dir(kind)]
    slug = native_installed_slug()
    if slug !== nothing
        # Then every depot, not just the writable one: a package installed in
        # a depot that has since moved behind another still finds its build.
        for depot in DEPOT_PATH
            isempty(depot) && continue
            push!(dirs, joinpath(native_scratch_dir(String(depot)), slug,
                                 NATIVE_PRODUCTS[kind].crate))
        end
        push!(dirs, joinpath(native_crate_dir(kind), "target"))
    end
    unique!(dirs)
    for dir in dirs, profile in profiles
        push!(out, joinpath(dir, profile, file))
    end

    if kind === :rust_helpers
        # Even older: a library dropped straight into deps/.
        push!(out, joinpath(native_package_root(), "deps", file))
    end
    return unique!(out)
end

"""
    native_product_path(kind::Symbol) -> Union{String, Nothing}

The first existing entry of `native_product_candidates(kind)`, or `nothing`.
"""
function native_product_path(kind::Symbol)
    for candidate in native_product_candidates(kind)
        isfile(candidate) && return candidate
    end
    return nothing
end
