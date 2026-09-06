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
    "symbol_collision" => "another item already claims the symbol a wrapper would give this one; " *
                          "module-qualified symbols are tracked in #300",
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

# ----------------------------------------------------------------------------
# Phase 1.5: can a wrapper crate be linked and loaded at all?
# ----------------------------------------------------------------------------

"""
    PyO3LinkPlan

One candidate build of a wrapper crate against a PyO3 crate: which Cargo
features it uses, whether the resulting cdylib can be linked and loaded, and the
configuration to scan the crate under (#275 Phase 1.5).

# Fields
- `mode::Symbol`: one of

  | mode | meaning |
  | --- | --- |
  | `:python_free` | pyo3 is not in the resolved dependency graph of this build, so nothing links libpython |
  | `:link_libpython` | pyo3 is resolved: the wrapper cdylib hard-links libpython and only loads if the interpreter's library directory is on the runtime search path |
  | `:unlinkable` | pyo3's resolved features include `extension-module`: the wrapper cdylib cannot be loaded (it does not link on macOS, and fails `dlopen` on Linux) |

- `feature_flags::Vector{String}`: the Cargo flags that select this build
  (`[]`, `["--no-default-features"]`, `["--all-features"]`).
- `crate_features::Vector{String}`: the root package's features **as Cargo
  resolved them** under those flags.
- `pyo3_features::Vector{String}`: pyo3's resolved features, empty when pyo3 is
  not in the graph. `extension-module` here is what makes a build
  `:unlinkable`.
- `dependency_default_features::Bool`: what the wrapper's
  `[dependencies.<crate>]` entry must set. `false` is how a target crate's
  default features are switched off — the `cargo build --no-default-features`
  **flag applies to the package being built**, i.e. the wrapper, and does not
  reach a dependency's defaults.
- `cfg_text::String`: `rustc --print cfg` for this build, or `""` when Cargo
  could not answer. `scan_report` hands it to the extractor so `#[cfg]` and
  `#[cfg_attr]` are evaluated by the real evaluator and the manifest contains
  exactly the items this build has.
- `resolved::Bool`: whether Cargo answered. `false` means the plan is the
  conservative reading of `Cargo.toml` described below.
- `reason::String`: why this mode was chosen, in words.

# Cargo resolves the features, RustCall does not

Feature activation is transitive, target-dependent, and renameable
(`python = { package = "pyo3" }`), and a `#[cfg]` predicate has Boolean
structure (`all`, `any`, `not`). Reimplementing any of that in Julia gets it
wrong in a new way for every crate shape, so the plan asks Cargo instead:
`cargo tree -e features` gives the resolved feature set of the root package and
of pyo3 itself, and `cargo rustc -- --print cfg` gives the configuration the
crate scan then runs under, in strict mode.

When Cargo cannot answer — it is not installed, or the crate does not resolve —
the plan falls back to a deliberately **conservative** read of `Cargo.toml`
that does no resolution at all: any pyo3 declaration listing `extension-module`
is `:unlinkable`, any other pyo3 declaration is `:link_libpython`, and only a
crate with no pyo3 declaration at all is `:python_free`. `resolved` is `false`
and `reason` says so.

# Why `:link_libpython` exists

Disabling `extension-module` is **not** enough to get a Python-free build:
verified in the #275 MWE, any build whose graph contains pyo3 links libpython,
and the resulting cdylib fails to `dlopen` unless the loader can find it. The
only genuinely Python-free build is one in which pyo3 is not resolved at all.

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
    dependency_default_features::Bool
    pyo3_features::Vector{String}
    crate_features::Vector{String}
    cfg_text::String
    resolved::Bool
end

function PyO3LinkPlan(mode::Symbol, feature_flags::Vector{String}, rpath::String,
                      reason::String, dependency_default_features::Bool = true;
                      pyo3_features::Vector{String} = String[],
                      crate_features::Vector{String} = String[],
                      cfg_text::String = "", resolved::Bool = false)
    PyO3LinkPlan(mode, feature_flags, rpath, reason, dependency_default_features,
                 pyo3_features, crate_features, cfg_text, resolved)
end

"""
    pyo3_dependency_toml(plan, name, path) -> String

The `[dependencies.<name>]` entry a Phase-2 wrapper crate must write for `plan`
to hold. This is where `dependency_default_features` takes effect: nothing on
the `cargo build` command line can turn off a *dependency's* default features.
"""
function pyo3_dependency_toml(plan::PyO3LinkPlan, name::AbstractString, path::AbstractString)
    io = IOBuffer()
    println(io, "[dependencies.", name, "]")
    println(io, "path = ", repr(String(path)))
    plan.dependency_default_features || println(io, "default-features = false")
    isempty(plan.crate_features) ||
        println(io, "features = [", join((repr(f) for f in plan.crate_features), ", "), "]")
    return String(take!(io))
end

"""
    pyo3_link_plan(crate_path; features = String[], default_features = true) -> PyO3LinkPlan

The plan for building a wrapper crate against `crate_path` **under a given
feature set**, which is named the way Cargo and `@rust_crate` name one:
`features` are extra crate features to enable, `default_features = false` is
`--no-default-features`. The default is the crate's own default features.

The plan is for that set only — it does not go looking for a better one. Use
`pyo3_feature_candidates` to see which features activate pyo3 and which pull
`extension-module`, then ask for the set you want.

# Worked example

```toml
[features]
default = ["extension"]
python = ["dep:pyo3"]
extension = ["python", "pyo3/extension-module"]
```

The default build is `:unlinkable` (`extension` pulls `extension-module`), and
so is `--all-features`. `default_features = false` alone is `:python_free` but
compiles none of the crate's `#[cfg(feature = "python")]` API. The build that
works is the one a person picks from the candidates:

```julia
RustCall.pyo3_feature_candidates(crate)
# ("python",    activates_pyo3 = true,  extension_module = false)
# ("extension", activates_pyo3 = true,  extension_module = true)

plan = RustCall.pyo3_link_plan(crate; features = ["python"], default_features = false)
plan.mode   # :link_libpython
```
"""
function pyo3_link_plan(crate_path::AbstractString; features::Vector{String} = String[],
                        default_features::Bool = true)
    manifest_path = joinpath(String(crate_path), "Cargo.toml")
    isfile(manifest_path) ||
        throw(RustError("Cargo.toml not found in: $(crate_path)"))
    flags = _pyo3_feature_flags(features, default_features)
    plan = _pyo3_resolved_plan(crate_path, flags)
    plan === nothing || return plan
    return _pyo3_conservative_plan(TOML.parsefile(manifest_path))
end

"""
    pyo3_feature_candidates(crate_path) -> Vector{NamedTuple}

Which of the crate's own features activate pyo3, and which of those also pull
`extension-module` — answered by Cargo, one resolution per feature:

```julia
[(feature = "python",    activates_pyo3 = true,  extension_module = false),
 (feature = "extension", activates_pyo3 = true,  extension_module = true)]
```

A feature that does not reach pyo3 at all is not listed. Empty when the crate
has no `[features]` table, or when Cargo cannot resolve it — which is not the
same as "no feature activates pyo3", so check `pyo3_link_plan(...).resolved`
before reading anything into an empty list.
"""
function pyo3_feature_candidates(crate_path::AbstractString)
    manifest_path = joinpath(String(crate_path), "Cargo.toml")
    isfile(manifest_path) ||
        throw(RustError("Cargo.toml not found in: $(crate_path)"))
    features = get(TOML.parsefile(manifest_path), "features", Dict{String, Any}())
    features isa AbstractDict || return NamedTuple[]

    out = NamedTuple[]
    for name in sort(collect(keys(features)))
        name == "default" && continue
        resolved = _cargo_resolved_features(crate_path,
                                            ["--no-default-features", "--features", String(name)])
        resolved === nothing && continue
        _, pyo3_features, pyo3_active = resolved
        pyo3_active || continue
        push!(out, (feature = String(name), activates_pyo3 = true,
                    extension_module = "extension-module" in pyo3_features))
    end
    return out
end

"""
    _pyo3_feature_flags(features, default_features) -> Vector{String}

The Cargo flags naming a feature set: `--no-default-features` and
`--features a,b`, in the spelling `cargo build` takes.
"""
function _pyo3_feature_flags(features::Vector{String}, default_features::Bool)
    flags = String[]
    default_features || push!(flags, "--no-default-features")
    isempty(features) || append!(flags, ["--features", join(features, ",")])
    return flags
end

"""
    _pyo3_resolved_plan(crate_path, flags) -> Union{PyO3LinkPlan, Nothing}

Ask Cargo what a build of `crate_path` under `flags` resolves to, and turn the
answer into a plan. `nothing` when Cargo is unavailable or the crate does not
resolve — the caller then falls back to `_pyo3_conservative_plan`.
"""
function _pyo3_resolved_plan(crate_path::AbstractString, flags::Vector{String})
    resolved = _cargo_resolved_features(crate_path, flags)
    resolved === nothing && return nothing
    crate_features, pyo3_features, pyo3_active = resolved
    cfg_text = _crate_build_cfg_text(crate_path; features = flags)

    label = isempty(flags) ? "the crate's default features" : join(flags, " ")
    no_defaults = "--no-default-features" in flags

    if !pyo3_active
        return PyO3LinkPlan(:python_free, copy(flags), "",
                            "with $(label), Cargo does not resolve pyo3 at all, so the wrapper " *
                            "links no libpython", !no_defaults;
                            crate_features = crate_features, cfg_text = cfg_text, resolved = true)
    end

    if "extension-module" in pyo3_features
        return PyO3LinkPlan(:unlinkable, copy(flags), "",
                            "with $(label), pyo3 resolves with the `extension-module` feature, " *
                            "which leaves libpython's symbols to the Python interpreter that " *
                            "imports the module. A wrapper cdylib is not loaded that way: on " *
                            "macOS it does not even link, and on Linux it links but fails to " *
                            "dlopen under both RTLD_NOW and RTLD_LAZY (undefined symbol: " *
                            "_Py_Dealloc). `pyo3_feature_candidates` lists the features that " *
                            "activate pyo3 without it", !no_defaults;
                            pyo3_features = pyo3_features, crate_features = crate_features,
                            cfg_text = cfg_text, resolved = true)
    end

    rpath = _python_library_dir_or_empty()
    detail = isempty(rpath) ?
        " — and the interpreter's library directory could not be located (tried " *
        "RUSTCALL_PYTHON_LIBDIR, python3-config --ldflags and sysconfig LIBDIR)" :
        "; $(rpath) is added as an rpath at wrapper-build time"
    return PyO3LinkPlan(:link_libpython, copy(flags), rpath,
                        "with $(label), Cargo resolves pyo3, so the wrapper cdylib links " *
                        "libpython$(detail)", !no_defaults;
                        pyo3_features = pyo3_features, crate_features = crate_features,
                        cfg_text = cfg_text, resolved = true)
end

"""
    _cargo_resolved_features(crate_path, flags) -> Union{Tuple, Nothing}

`(crate_features, pyo3_features, pyo3_active)` as Cargo resolves them for a
build of `crate_path` under `flags`, from

    cargo tree -e features,normal --prefix none --format "{p}|{f}" --no-dedupe

which prints one line per package with its **resolved** feature list — the
transitive closure, with target-specific tables and renamed dependencies
already applied.

The edge filter is `features,normal`: a wrapper crate depends on the target
crate's library, so its dev- and build-dependencies are not in the graph it
builds. Without the filter a crate whose *dev*-dependency on pyo3 enables
`extension-module` would be reported `:unlinkable` for a build that never
activates it.

`nothing` when the command fails (no cargo, an unresolvable crate, no network
for a fresh registry).
"""
function _cargo_resolved_features(crate_path::AbstractString, flags::Vector{String})
    path = abspath(String(crate_path))
    out = try
        args = String["tree", "-e", "features,normal", "--prefix", "none",
                      "--format", "{p}|{f}", "--no-dedupe"]
        append!(args, flags)
        read(pipeline(setenv(`$(cargo()) $args`; dir = path); stderr = devnull), String)
    catch e
        @debug "Could not resolve features of $(path)" exception = e
        return nothing
    end
    isempty(strip(out)) && return nothing

    package = _cargo_package_name(crate_path)
    crate_features = String[]
    pyo3_features = String[]
    pyo3_active = false
    for line in split(out, '\n')
        entry = _parse_cargo_tree_features(line)
        entry === nothing && continue
        name, feats = entry
        if name == "pyo3"
            pyo3_active = true
            for f in feats
                f in pyo3_features || push!(pyo3_features, f)
            end
        elseif name == package
            for f in feats
                f in crate_features || push!(crate_features, f)
            end
        end
    end
    return (sort(crate_features), sort(pyo3_features), pyo3_active)
end

_cargo_package_name(crate_path::AbstractString) = try
    String(TOML.parsefile(joinpath(String(crate_path), "Cargo.toml"))["package"]["name"])
catch
    ""
end

# A `cargo tree --format "{p}|{f}"` line is `<name> v<version>[ (source)]|<f1,f2>`.
# The package name is the first whitespace-separated token; the features follow
# the last `|`.
function _parse_cargo_tree_features(line::AbstractString)
    s = strip(line)
    isempty(s) && return nothing
    bar = findlast('|', s)
    bar === nothing && return nothing
    head = strip(s[1:prevind(s, bar)])
    tail = strip(s[nextind(s, bar):end])
    isempty(head) && return nothing
    name = first(split(head))
    # `cargo tree -e features` also prints feature edges as `crate feature "x"`
    # lines; those have no version token and are not packages.
    occursin(r"^v[0-9]", length(split(head)) > 1 ? split(head)[2] : "") || return nothing
    feats = String[String(strip(f)) for f in split(tail, ',') if !isempty(strip(f))]
    return (String(name), feats)
end

"""
    _pyo3_conservative_plan(cargo_toml) -> PyO3LinkPlan

The plan when Cargo could not resolve the crate. It performs **no** feature
resolution — that is exactly what got this wrong repeatedly — and reads only
whether a pyo3 dependency is declared at all:

* no pyo3 declaration anywhere (including `[target.'cfg(...)'.dependencies]`
  and renamed entries) -> `:python_free`;
* any declaration listing `extension-module` -> `:unlinkable`;
* otherwise -> `:link_libpython`, because without Cargo nothing here can show
  that the optional dependency is off in the build the wrapper would make.
"""
function _pyo3_conservative_plan(cargo_toml::AbstractDict)
    found = _pyo3_dependencies(cargo_toml)
    note = " (Cargo could not resolve this crate, so the features were not resolved; " *
           "this is the conservative reading of Cargo.toml)"
    if isempty(found)
        return PyO3LinkPlan(:python_free, String[], "",
                            "the crate declares no pyo3 dependency" * note)
    end
    for dep in found
        feats = String[String(f) for f in get(dep.spec, "features", String[])]
        if "extension-module" in feats
            return PyO3LinkPlan(:unlinkable, String[], "",
                                "[dependencies.$(dep.key)] lists the `extension-module` feature, " *
                                "and a wrapper cdylib that resolves pyo3 with it cannot be loaded" *
                                note)
        end
    end
    return PyO3LinkPlan(:link_libpython, String[], _python_library_dir_or_empty(),
                        "the crate declares a pyo3 dependency, so the wrapper cdylib may link " *
                        "libpython" * note)
end

# One pyo3 dependency declaration: the (possibly renamed) key it is declared
# under, its table, and the `[target.'...']` selector it sits behind ("" for a
# plain `[dependencies]` entry). Used only by the conservative fallback: when
# Cargo answers, none of this matters.
struct _PyO3Dependency
    key::String
    spec::Dict{String, Any}
    target::String
end

"""
    _pyo3_dependencies(cargo) -> Vector{_PyO3Dependency}

Every declaration of pyo3 in the crate's manifest: the plain `[dependencies]`
entry and each `[target.'cfg(...)'.dependencies]` one, matched on the `package`
field so a renamed dependency (`python = { package = "pyo3" }`) is found too.
The shorthand `pyo3 = "0.29"` is normalized to `Dict("version" => "0.29")`.
"""
function _pyo3_dependencies(cargo::AbstractDict)
    out = _PyO3Dependency[]
    _collect_pyo3_dependencies!(out, get(cargo, "dependencies", nothing), "")
    targets = get(cargo, "target", Dict{String, Any}())
    if targets isa AbstractDict
        for selector in sort(collect(keys(targets)))
            cfg = targets[selector]
            cfg isa AbstractDict || continue
            _collect_pyo3_dependencies!(out, get(cfg, "dependencies", nothing), String(selector))
        end
    end
    return out
end

function _collect_pyo3_dependencies!(out::Vector{_PyO3Dependency}, table, target::String)
    table isa AbstractDict || return out
    for key in sort(collect(keys(table)))
        name = String(key)
        spec = table[key]
        if spec isa AbstractDict
            String(get(spec, "package", name)) == "pyo3" || continue
            push!(out, _PyO3Dependency(name, Dict{String, Any}(spec), target))
        elseif name == "pyo3"
            push!(out, _PyO3Dependency(name, Dict{String, Any}("version" => String(spec)), target))
        end
    end
    return out
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

# ----------------------------------------------------------------------------
# Phase 1 reporting, which needs the plan types above
# ----------------------------------------------------------------------------

"""
    scan_report(crate_path; features = String[], default_features = true, io = stdout) -> NamedTuple

Report what a crate offers to RustCall, including the items it marks only for
PyO3 (#275 Phase 1).

The crate is scanned **under the build the plan describes**: `pyo3_link_plan`
asks Cargo to resolve `features` / `default_features`, and the scan then runs in
strict mode under that build's configuration, so `#[cfg]` and `#[cfg_attr]` on
functions, structs, impls, methods and fields are evaluated by the extractor's
own evaluator and the items listed are exactly the items that build has.

Returns `(; julia, wrappable, skipped, plan, info, candidates)`:

* `julia` — items carrying a RustCall attribute (`#[julia]`, `#[julia_pyo3]`),
  which `@rust_crate` wraps today;
* `wrappable` — PyO3 items with an empty `skip_reason`: a Phase-2 wrapper crate
  will be able to export `rustcall_<name>` for each of them;
* `skipped` — PyO3 items that cannot be wrapped, each with its reason;
* `plan` — the `PyO3LinkPlan` for the requested feature set;
* `info` — the `CrateInfo` scanned under it;
* `candidates` — `pyo3_feature_candidates(crate_path)`, the features that
  activate pyo3, so a different set can be chosen deliberately.

```julia
RustCall.scan_report("/path/to/some_pyo3_crate")
RustCall.scan_report(crate; features = ["python"], default_features = false)
```
"""
function scan_report(crate_path::AbstractString; features::Vector{String} = String[],
                     default_features::Bool = true, io::IO = stdout)
    plan = pyo3_link_plan(crate_path; features = features, default_features = default_features)
    # A resolved plan carries the cfg text of its build, so the scan runs in
    # strict mode and the manifest holds exactly that build's items. Without one
    # (no Cargo) the scan stays lenient and reports everything, which
    # `resolved = false` on the plan makes explicit.
    info = isempty(plan.cfg_text) ?
        scan_crate(String(crate_path)) :
        scan_crate(String(crate_path); cfg = :cargo, cfg_text = plan.cfg_text)

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

    candidates = try
        pyo3_feature_candidates(crate_path)
    catch
        NamedTuple[]
    end

    build = isempty(plan.feature_flags) ? "default features" : join(plan.feature_flags, " ")
    println(io, "Crate $(info.name) v$(info.version) ($(info.path))")
    println(io, "  Build scanned: $(build)",
            plan.resolved ? "" : " (Cargo could not resolve it; every #[cfg] item is reported)")
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
    if !isempty(candidates)
        println(io, "  Features that activate pyo3:")
        for c in candidates
            println(io, "    $(c.feature)",
                    c.extension_module ? " (also enables extension-module, unlinkable)" : "")
        end
    end

    return (julia = julia_items, wrappable = wrappable, skipped = skipped,
            plan = plan, info = info, candidates = candidates)
end

_pyo3_item_label(f::RustFunctionSignature) =
    "fn $(qualified_name(f.module_path, f.name)) -> $(f.return_type) [$(f.attribute)]"
_pyo3_item_label(s::RustStructInfo) = "struct $(qualified_name(s.module_path, s.name)) [$(s.attribute)]"
_pyo3_item_label(m::RustMethod) = "method $(m.name) -> $(m.return_type)"
