# PyO3 crates that carry no RustCall attribute (#275).
#
# Phase 1 (`scan_report`) reports what the extractor found in such a crate:
# which `#[pyfunction]` / `#[pyclass]` items a wrapper crate could wrap, and why
# the others cannot be. Phase 1.5 (`pyo3_link_plan`) answers the question that
# has to be settled *before* any wrapper crate is built: can the wrapper be
# linked and loaded at all, and under which flags.
#
# Nothing here builds anything. The link plan is read from the target crate's
# `Cargo.toml`; the scan runs the extractor over its sources.

# ----------------------------------------------------------------------------
# Phase 1: reporting the scan
# ----------------------------------------------------------------------------

"""
    PYO3_SKIP_REASONS

Human-readable text for each `skip_reason` the extractor records
(`rustcall_core::manifest::skip_reason`). A reason may carry a detail after a
colon (`pyo3_type:Python<'_>`); `pyo3_skip_explanation` splits it off.
"""
const PYO3_SKIP_REASONS = Dict{String, String}(
    "not_public" => "not `pub`, so a wrapper crate cannot name it (rustc E0603)",
    "pyo3_type" => "the signature uses a type that needs a live Python interpreter",
    "pymodule" => "a `#[pymodule]` initializer: it only means something to Python's import machinery",
    "generic" => "generic; monomorphizing PyO3 items is not supported",
    "owner_skipped" => "its `#[pyclass]` is itself skipped",
)

"""
    pyo3_skip_explanation(reason::AbstractString) -> String

Turn a manifest `skip_reason` into a sentence. Unknown reasons are passed
through unchanged so a newer extractor never produces an empty explanation.
"""
function pyo3_skip_explanation(reason::AbstractString)
    isempty(reason) && return ""
    kind, _, detail = partition_skip_reason(reason)
    text = get(PYO3_SKIP_REASONS, kind, kind)
    return isempty(detail) ? text : "$(text) ($(detail))"
end

"""
    partition_skip_reason(reason) -> (kind, has_detail, detail)

Split `"pyo3_type:Python<'_>"` into `("pyo3_type", true, "Python<'_>")`.
"""
function partition_skip_reason(reason::AbstractString)
    idx = findfirst(==(':'), reason)
    idx === nothing && return (String(reason), false, "")
    return (String(reason[1:prevind(reason, idx)]), true, String(reason[nextind(reason, idx):end]))
end

"""
    scan_report(crate_path; io = stdout) -> NamedTuple

Report what a crate offers to RustCall, including the items it marks only for
PyO3 (#275 Phase 1).

Prints three groups and returns them as
`(; julia, wrappable, skipped, plan)`:

* `julia` — items carrying a RustCall attribute (`#[julia]`, `#[julia_pyo3]`),
  which `@rust_crate` wraps today;
* `wrappable` — PyO3 items with an empty `skip_reason`: a Phase-2 wrapper crate
  will be able to export `rustcall_<name>` for each of them;
* `skipped` — PyO3 items that cannot be wrapped, each with its reason;
* `plan` — the `PyO3LinkPlan` for the crate (see `pyo3_link_plan`).

The scan needs no build: it runs the extractor over the crate's sources and
reads its `Cargo.toml`.

```julia
RustCall.scan_report("/path/to/some_pyo3_crate")
```
"""
function scan_report(crate_path::AbstractString; io::IO = stdout)
    info = scan_crate(String(crate_path))
    plan = pyo3_link_plan(crate_path)

    julia_items = Any[info.julia_functions...; info.julia_structs...]
    wrappable = Any[]
    skipped = Any[]
    for f in info.pyo3_functions
        push!(isempty(f.skip_reason) ? wrappable : skipped, f)
    end
    for s in info.pyo3_structs
        push!(isempty(s.skip_reason) ? wrappable : skipped, s)
        for m in s.methods
            push!(isempty(m.skip_reason) ? wrappable : skipped, m)
        end
    end

    println(io, "Crate $(info.name) v$(info.version) ($(info.path))")
    println(io, "  RustCall items (wrapped today): $(length(julia_items))")
    for item in julia_items
        println(io, "    $(_pyo3_item_label(item))")
    end
    println(io, "  PyO3 items wrappable by Phase 2: $(length(wrappable))")
    for item in wrappable
        println(io, "    $(_pyo3_item_label(item))")
    end
    println(io, "  PyO3 items skipped: $(length(skipped))")
    for item in skipped
        println(io, "    $(_pyo3_item_label(item)) — $(pyo3_skip_explanation(item.skip_reason))")
    end
    println(io, "  Link plan: $(plan.mode) — $(plan.reason)")

    return (julia = julia_items, wrappable = wrappable, skipped = skipped, plan = plan)
end

_pyo3_item_label(f::RustFunctionSignature) =
    "fn $(qualified_name(f.module_path, f.name)) -> $(f.return_type) [$(f.attribute)]"
_pyo3_item_label(s::RustStructInfo) = "struct $(qualified_name(s.module_path, s.name)) [$(s.attribute)]"
_pyo3_item_label(m::RustMethod) = "method $(m.name) -> $(m.return_type)"

# ----------------------------------------------------------------------------
# Phase 1.5: can a wrapper crate be linked and loaded at all?
# ----------------------------------------------------------------------------

"""
    PyO3LinkPlan

How a Phase-2 wrapper crate would have to be built against a PyO3 crate, and
whether it can be built at all (#275 Phase 1.5).

# Fields
- `mode::Symbol`: one of

  | mode | meaning |
  | --- | --- |
  | `:python_free` | the crate's pyo3 dependency is optional (or absent), so the wrapper is built with the feature **off** and links no libpython |
  | `:link_libpython` | pyo3 is a mandatory dependency: the wrapper cdylib hard-links libpython and only loads if the interpreter's library directory is on the runtime search path |
  | `:unlinkable` | the crate enables pyo3's `extension-module` feature unconditionally: the wrapper cdylib cannot be loaded (it does not link on macOS, and fails `dlopen` on Linux) |

- `feature_flags::Vector{String}`: Cargo flags the wrapper build must pass for
  the plan to hold (e.g. `--no-default-features`).
- `rpath::String`: the interpreter's library directory for `:link_libpython`,
  empty when it could not be located (then `pyo3_link_rustflags` raises).
- `reason::String`: why this mode was chosen, in words.

# Why `:link_libpython` exists at all

Disabling `extension-module` is **not** enough to get a Python-free build:
verified in the #275 MWE, any build of a crate with a non-optional pyo3
dependency links libpython, and the resulting cdylib fails to `dlopen` unless
the loader can find it. The only genuinely Python-free case is a crate whose
pyo3 dependency is itself optional.

# Why "optional pyo3" is rare

`#[cfg_attr(feature = "python", ...)]` works for the item attributes
(`pyfunction`, `pyclass`, `pymethods`) but **not** for the inner ones (`new`,
`staticmethod`, `getter`, `setter`, `pyo3(get, set)`): the outer macro runs
before `cfg_attr` expands, so rustc reports `cannot find attribute 'new' in
this scope`. Real crates therefore make pyo3 mandatory, which makes
`:link_libpython` the common case rather than the exception.
"""
struct PyO3LinkPlan
    mode::Symbol
    feature_flags::Vector{String}
    rpath::String
    reason::String
end

"""
    pyo3_link_plan(crate_path) -> PyO3LinkPlan

Decide, from the crate's `Cargo.toml` alone, whether a wrapper crate built
against it can be linked and loaded, and under which flags. Nothing is built
and no Python is started; see `PyO3LinkPlan` for the three modes.

The `[dependencies.pyo3]` entry (`optional`, `features`, `default-features`)
and the `[features]` table decide the answer: a feature that is reachable from
`default` is on unless the build passes `--no-default-features`, which is what
the returned `feature_flags` say.
"""
function pyo3_link_plan(crate_path::AbstractString)
    manifest_path = joinpath(String(crate_path), "Cargo.toml")
    isfile(manifest_path) ||
        throw(RustError("Cargo.toml not found in: $(crate_path)"))
    cargo = TOML.parsefile(manifest_path)
    return _pyo3_link_plan(cargo)
end

function _pyo3_link_plan(cargo::AbstractDict)
    spec = _pyo3_dependency_spec(cargo)
    if spec === nothing
        return PyO3LinkPlan(:python_free, String[], "",
                            "the crate does not depend on pyo3; the wrapper needs no Python")
    end

    dep_features = String[String(f) for f in get(spec, "features", String[])]
    optional = get(spec, "optional", false) === true
    default_on = _pyo3_default_features(cargo)
    ext_in_dep = "extension-module" in dep_features
    ext_feature = _feature_enabling(cargo, "pyo3/extension-module")

    if optional
        # Turning the feature off removes pyo3 entirely: the wrapper links
        # nothing Python-related, which is the only genuinely Python-free case.
        enabled_by_default = _pyo3_enabled_by_default(cargo, default_on)
        flags = enabled_by_default ? ["--no-default-features"] : String[]
        note = enabled_by_default ?
            "; it is on by default, so the wrapper build passes --no-default-features" : ""
        return PyO3LinkPlan(:python_free, flags, "",
                            "pyo3 is an optional dependency, so the wrapper is built with it off$(note)")
    end

    if ext_in_dep
        # Verified on both platforms for #275. macOS: the wrapper cdylib does
        # not even link — pyo3 emits `-undefined dynamic_lookup` through
        # cargo:rustc-cdylib-link-arg from its *own* build script and that does
        # not reach a dependent crate (which is why maturin sets the flag
        # itself) — and forcing the link gives a library that fails dlopen
        # under RTLD_NOW and RTLD_LAZY alike. Linux: the cdylib links (ELF
        # tolerates undefined symbols) but dlopen fails the same way under both
        # flags (`undefined symbol: _Py_Dealloc`). Unusable either way.
        return PyO3LinkPlan(:unlinkable, String[], "",
                            "[dependencies.pyo3] enables the `extension-module` feature unconditionally, " *
                            "which leaves libpython's symbols to be resolved by the Python interpreter " *
                            "that loads the module. A wrapper cdylib is not loaded that way: on macOS it " *
                            "does not even link, and on Linux it links but fails to dlopen under both " *
                            "RTLD_NOW and RTLD_LAZY (undefined symbol: _Py_Dealloc). Make the feature " *
                            "optional (`[features] extension-module = [\"pyo3/extension-module\"]`) so the " *
                            "wrapper build can leave it off.")
    end

    if ext_feature !== nothing && ext_feature in default_on
        return PyO3LinkPlan(:link_libpython, ["--no-default-features"], _python_library_dir_or_empty(),
                            "pyo3 is a mandatory dependency and the default feature `$(ext_feature)` " *
                            "enables `extension-module`; the wrapper build must pass " *
                            "--no-default-features, and the resulting cdylib still links libpython")
    end

    rpath = _python_library_dir_or_empty()
    reason = isempty(rpath) ?
        "pyo3 is a mandatory dependency, so the wrapper cdylib links libpython — and the " *
        "interpreter's library directory could not be located (tried RUSTCALL_PYTHON_LIBDIR, " *
        "python3-config --ldflags and sysconfig LIBDIR)" :
        "pyo3 is a mandatory dependency, so the wrapper cdylib links libpython; " *
        "$(rpath) is added as an rpath at wrapper-build time"
    return PyO3LinkPlan(:link_libpython, String[], rpath, reason)
end

"""
    _pyo3_dependency_spec(cargo) -> Union{AbstractDict, Nothing}

The `pyo3` entry of the crate's `[dependencies]` (or of any
`[target.'cfg(...)'.dependencies]`), normalized to a table: the shorthand
`pyo3 = "0.29"` becomes `Dict("version" => "0.29")`. `nothing` when the crate
does not depend on pyo3 at all.
"""
function _pyo3_dependency_spec(cargo::AbstractDict)
    tables = Any[get(cargo, "dependencies", Dict{String, Any}())]
    for (_, cfg) in get(cargo, "target", Dict{String, Any}())
        cfg isa AbstractDict || continue
        push!(tables, get(cfg, "dependencies", Dict{String, Any}()))
    end
    for table in tables
        table isa AbstractDict || continue
        spec = get(table, "pyo3", nothing)
        spec === nothing && continue
        spec isa AbstractDict && return spec
        return Dict{String, Any}("version" => String(spec))
    end
    return nothing
end

"""
    _pyo3_default_features(cargo) -> Set{String}

Crate features reachable from `default`, transitively. Only names of the
crate's own features are collected; `dep:x` and `x/y` entries are dependency
activations, not features of this crate.
"""
function _pyo3_default_features(cargo::AbstractDict)
    features = get(cargo, "features", Dict{String, Any}())
    features isa AbstractDict || return Set{String}()
    out = Set{String}()
    queue = String[String(f) for f in get(features, "default", String[])]
    while !isempty(queue)
        name = popfirst!(queue)
        (occursin('/', name) || startswith(name, "dep:")) && continue
        name in out && continue
        push!(out, name)
        for next in get(features, name, String[])
            push!(queue, String(next))
        end
    end
    return out
end

"""
    _pyo3_enabled_by_default(cargo, default_on) -> Bool

Whether an *optional* pyo3 dependency is activated by the crate's default
features: either a default feature lists `dep:pyo3` / `pyo3/...`, or `pyo3`
itself is a default feature (the implicit feature Cargo creates for an optional
dependency).
"""
function _pyo3_enabled_by_default(cargo::AbstractDict, default_on::Set{String})
    "pyo3" in default_on && return true
    features = get(cargo, "features", Dict{String, Any}())
    features isa AbstractDict || return false
    for name in union(default_on, Set(["default"]))
        for entry in get(features, name, String[])
            e = String(entry)
            (e == "dep:pyo3" || e == "pyo3" || startswith(e, "pyo3/")) && return true
        end
    end
    return false
end

"""
    _feature_enabling(cargo, activation) -> Union{String, Nothing}

The name of a crate feature whose list contains `activation` (for example
`"pyo3/extension-module"`), or `nothing`.
"""
function _feature_enabling(cargo::AbstractDict, activation::AbstractString)
    features = get(cargo, "features", Dict{String, Any}())
    features isa AbstractDict || return nothing
    for (name, entries) in features
        entries isa AbstractVector || continue
        any(e -> String(e) == activation, entries) && return String(name)
    end
    return nothing
end

"""
    python_library_dir() -> String

The directory holding the Python interpreter's shared library, or `""` when it
cannot be found. Consulted in order:

1. `ENV["RUSTCALL_PYTHON_LIBDIR"]` — an explicit override always wins;
2. CondaPkg's environment, when `CondaPkg` is already loaded (PythonCall users);
3. `python3-config --ldflags`, taking its `-L` directory;
4. `sysconfig.get_config_var("LIBDIR")` of `python3`.

Only an existing directory is returned.
"""
function python_library_dir()
    override = get(ENV, "RUSTCALL_PYTHON_LIBDIR", "")
    isempty(override) || return isdir(override) ? String(override) : ""

    conda = _condapkg_library_dir()
    isempty(conda) || return conda

    for dir in (_python_config_libdir(), _python_sysconfig_libdir())
        isempty(dir) || return dir
    end
    return ""
end

_python_library_dir_or_empty() = try
    python_library_dir()
catch
    ""
end

# CondaPkg is not a dependency of RustCall; it is used only when the user's
# session already loaded it (PythonCall), in which case its environment holds
# the interpreter the wrapper should link against.
function _condapkg_library_dir()
    for (id, mod) in Base.loaded_modules
        id.name == "CondaPkg" || continue
        try
            dir = joinpath(Base.invokelatest(getfield(mod, :envdir)), "lib")
            isdir(dir) && return String(dir)
        catch
        end
        break
    end
    return ""
end

function _python_config_libdir()
    for exe in ("python3-config", "python-config")
        try
            flags = read(`$exe --ldflags`, String)
            for token in split(flags)
                startswith(token, "-L") || continue
                dir = String(token[3:end])
                isdir(dir) && return dir
            end
        catch
        end
    end
    return ""
end

function _python_sysconfig_libdir()
    for exe in ("python3", "python")
        try
            code = "import sysconfig; print(sysconfig.get_config_var('LIBDIR') or '')"
            dir = strip(read(`$exe -c $code`, String))
            isdir(dir) && return String(dir)
        catch
        end
    end
    return ""
end

"""
    pyo3_link_rustflags(plan::PyO3LinkPlan) -> Vector{String}

The `RUSTFLAGS` pieces a wrapper build must carry for `plan`: nothing for
`:python_free`, and `-L <dir>` plus an rpath link argument for
`:link_libpython`.

Raises `RustError` when the plan cannot be built: `:unlinkable`, or
`:link_libpython` with no interpreter library directory. This is the point
where Phase 2 fails loudly rather than producing a cdylib nothing can load;
`pyo3_link_plan` itself never raises, so a caller can inspect and report a
crate without committing to building it.
"""
function pyo3_link_rustflags(plan::PyO3LinkPlan)
    plan.mode === :python_free && return String[]
    if plan.mode === :unlinkable
        throw(RustError("this crate cannot be wrapped: $(plan.reason)"))
    end
    if isempty(plan.rpath)
        throw(RustError("""
        the wrapper cdylib will link libpython, but the interpreter's library directory
        was not found. $(plan.reason).

        Set RUSTCALL_PYTHON_LIBDIR to the directory holding libpython (the one
        `python3-config --ldflags` names), install a Python whose `python3-config` is on
        PATH, or make the crate's pyo3 dependency optional so the wrapper can be built
        without it.
        """))
    end
    return String["-L", "native=$(plan.rpath)",
                  "-C", "link-arg=-Wl,-rpath,$(plan.rpath)"]
end
