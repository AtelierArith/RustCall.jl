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
    # Reasons the Phase-2 *generator* refuses an item (#275 Phase 2).
    "unsupported_arg" => "an argument type the wrapper cannot lower: neither FFI-compatible " *
                         "nor a `String`/`&str`",
    "unsupported_return" => "a return type the wrapper cannot lower: it does not cross the " *
                            "C ABI as a single value",
    "py_result_payload" => "a `PyResult` whose `Ok` type does not fit in the `CResult` " *
                           "aggregate; widening this is tracked in #303",
    "cfg_undecided" => "the item is behind a `#[cfg]` the scan could not decide, so whether " *
                       "the build the wrapper links against has it is unknown",
)

"""
    PYO3_OPAQUE_ERROR

The error a lowered `PyResult` reports. It is fixed, and deliberately so.

Creating and dropping a `PyErr` without a Python interpreter is safe;
**rendering** one is not — `Display`/`Debug` on a `PyErr` asserts inside pyo3
that the interpreter is initialized, and the resulting panic crossing
`extern "C"` aborts the process. Reading only the exception *type* would still
need a `Python` token, which a wrapper crate by definition does not have. So the
generated wrapper drops the `PyErr` and reports the fixed code
`rustcall_core::wrap::PYERR_CODE`, and this is the sentence Julia raises for it.

Must equal `rustcall_core::wrap::PYERR_MESSAGE`; `test/test_pyo3_wrapper.jl`
checks that it does.
"""
const PYO3_OPAQUE_ERROR =
    "PyErr (Python-side error; message unavailable without an interpreter)"

"""
    PYO3_ERROR_CODE

The `i32` a lowered `PyResult` carries in the `Err` slot
(`rustcall_core::wrap::PYERR_CODE`). It is the only value the wrapper produces,
so the Julia side never decodes it — it reports `PYO3_OPAQUE_ERROR` instead —
but the number is part of the ABI and is written down here.
"""
const PYO3_ERROR_CODE = Int32(1)

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
- `interpreter::String`: the interpreter a `:link_libpython` build pins
  `PYO3_PYTHON` to, decided together with `rpath` by `python_link_source` so
  the two never name different Pythons; `""` when none could be identified
  (pyo3 then picks for itself). Part of the wrapper's artifact identity.
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
    interpreter::String
end

function PyO3LinkPlan(mode::Symbol, feature_flags::Vector{String}, rpath::String,
                      reason::String, dependency_default_features::Bool = true;
                      pyo3_features::Vector{String} = String[],
                      crate_features::Vector{String} = String[],
                      cfg_text::String = "", resolved::Bool = false,
                      interpreter::String = "")
    PyO3LinkPlan(mode, feature_flags, rpath, reason, dependency_default_features,
                 pyo3_features, crate_features, cfg_text, resolved, interpreter)
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
    pyo3_link_plan(crate_path; features = String[], default_features = true,
                   release = true) -> PyO3LinkPlan

The plan for building a wrapper crate against `crate_path` **under a given
feature set**, which is named the way Cargo and `@rust_crate` name one:
`features` are extra crate features to enable, `default_features = false` is
`--no-default-features`. The default is the crate's own default features.

`release` is the profile the wrapper will be built with, and the cfg probe
follows it: `debug_assertions` is set in a debug build and not in a release
one, so a `#[cfg(debug_assertions)]` item scanned under the other profile would
be decided the wrong way round (#307 review).

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
                        default_features::Bool = true, release::Bool = true)
    manifest_path = joinpath(String(crate_path), "Cargo.toml")
    isfile(manifest_path) ||
        throw(RustError("Cargo.toml not found in: $(crate_path)"))
    flags = _pyo3_feature_flags(features, default_features)
    plan = _pyo3_resolved_plan(crate_path, flags; release = release)
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
    _pyo3_resolved_plan(crate_path, flags; release = true) -> Union{PyO3LinkPlan, Nothing}

Ask Cargo what a build of `crate_path` under `flags` resolves to, and turn the
answer into a plan. `nothing` when Cargo is unavailable or the crate does not
resolve — the caller then falls back to `_pyo3_conservative_plan`. The cfg
probe runs under the profile the wrapper will be built with (`release`).
"""
function _pyo3_resolved_plan(crate_path::AbstractString, flags::Vector{String};
                             release::Bool = true)
    resolved = _cargo_resolved_features(crate_path, flags)
    resolved === nothing && return nothing
    crate_features, pyo3_features, pyo3_active = resolved
    cfg_text = _crate_build_cfg_text(crate_path; features = flags,
                                     profile = release ? "release" : "debug")
    # `cargo tree` answered but `cargo rustc -- --print cfg` did not: the plan
    # knows the feature graph and nothing about the configuration the build
    # compiles under, so the scan cannot be run in strict mode. Saying
    # `resolved = true` here made `scan_report` fall back to a lenient scan
    # without ever saying so (#294 review).
    if isempty(cfg_text)
        return _pyo3_unresolved_cfg_plan(crate_path, flags, crate_features,
                                         pyo3_features, pyo3_active)
    end

    label = isempty(flags) ? "the crate's default features" : join(flags, " ")
    no_defaults = "--no-default-features" in flags

    if !pyo3_active
        return PyO3LinkPlan(:python_free, copy(flags), "",
                            "with $(label), Cargo does not resolve pyo3 at all, so the wrapper " *
                            "links no libpython", !no_defaults;
                            crate_features = crate_features, cfg_text = cfg_text, resolved = true)
    end

    if "extension-module" in pyo3_features && !extension_module_is_linkable()
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

    rpath, interpreter = _python_link_source_or_empty()
    detail = isempty(rpath) ?
        " — and the interpreter's library directory could not be located (tried " *
        "RUSTCALL_PYTHON_LIBDIR, python3-config --ldflags and sysconfig LIBDIR)" :
        "; $(rpath) is put on the linker's search path at wrapper-build time" *
        (Sys.iswindows() ? " (Windows resolves the DLL through PATH at load time, not an rpath)" :
                           " and recorded as an rpath")
    extension_note = "extension-module" in pyo3_features ?
        ". On Windows pyo3 still links the interpreter's import library with " *
        "`extension-module`, so this build is linkable where a Unix one would not be" : ""
    return PyO3LinkPlan(:link_libpython, copy(flags), rpath,
                        "with $(label), Cargo resolves pyo3, so the wrapper cdylib links " *
                        "libpython$(detail)$(extension_note)", !no_defaults;
                        pyo3_features = pyo3_features, crate_features = crate_features,
                        cfg_text = cfg_text, resolved = true, interpreter = interpreter)
end

"""
    extension_module_is_linkable() -> Bool

Whether a wrapper cdylib that resolves pyo3 with `extension-module` can still be
linked and loaded on this target.

On Unix it cannot: `extension-module` tells pyo3 to leave libpython's symbols
undefined for the importing interpreter to supply, which the #275 MWE confirmed
is fatal for a cdylib Julia loads — macOS does not even link it, and Linux links
it but fails `dlopen` under both `RTLD_NOW` and `RTLD_LAZY`
(`undefined symbol: _Py_Dealloc`).

**Windows has no such mode.** A DLL there must resolve every import at link
time, so pyo3 links `python3X.lib` regardless of `extension-module`, and the
resulting wrapper loads exactly like any other `:link_libpython` build as long
as the interpreter's DLL directory is on `PATH`. Classifying such a build
`:unlinkable` on Windows refused a crate that works.
"""
extension_module_is_linkable() = Sys.iswindows()

"""
    _pyo3_unresolved_cfg_plan(crate_path, flags, crate_features, pyo3_features, pyo3_active)

The plan for a build whose **feature graph** Cargo resolved but whose
configuration it would not print (`cargo rustc -- --print cfg` failed: an
offline registry, a `build.rs` that does not run here, a target without a
toolchain).

The mode is decided from the feature graph exactly as a fully resolved plan
decides it — that part *is* known — but `cfg_text` is empty and `resolved` is
`false`, so `scan_report` scans leniently and says so, and the Phase-2 wrapper
refuses any `#[cfg]`-carrying item (`cfg_undecided`) instead of generating a
call it cannot justify.
"""
function _pyo3_unresolved_cfg_plan(crate_path::AbstractString, flags::Vector{String},
                                   crate_features::Vector{String},
                                   pyo3_features::Vector{String}, pyo3_active::Bool)
    label = isempty(flags) ? "the crate's default features" : join(flags, " ")
    no_defaults = "--no-default-features" in flags
    note = "with $(label), Cargo resolved the feature graph but would not print the " *
           "configuration this build compiles under (`cargo rustc -- --print cfg` failed), " *
           "so every #[cfg] item is reported and none of them can be wrapped"
    mode, rpath, interpreter = if !pyo3_active
        (:python_free, "", "")
    elseif "extension-module" in pyo3_features && !extension_module_is_linkable()
        (:unlinkable, "", "")
    else
        (:link_libpython, _python_link_source_or_empty()...)
    end
    return PyO3LinkPlan(mode, copy(flags), rpath, note, !no_defaults;
                        pyo3_features = pyo3_features, crate_features = crate_features,
                        cfg_text = "", resolved = false, interpreter = interpreter)
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
        if "extension-module" in feats && !extension_module_is_linkable()
            return PyO3LinkPlan(:unlinkable, String[], "",
                                "[dependencies.$(dep.key)] lists the `extension-module` feature, " *
                                "and a wrapper cdylib that resolves pyo3 with it cannot be loaded" *
                                note)
        end
    end
    # Same rule as the resolved path: on Windows a DLL resolves every import at
    # link time, so pyo3 links the interpreter's import library whether or not
    # `extension-module` is on, and the build is linkable. The two paths must
    # not disagree about one crate.
    extension = any(dep -> "extension-module" in
                        String[String(f) for f in get(dep.spec, "features", String[])], found)
    rpath, interpreter = _python_link_source_or_empty()
    return PyO3LinkPlan(:link_libpython, String[], rpath,
                        "the crate declares a pyo3 dependency, so the wrapper cdylib may link " *
                        "libpython" *
                        (extension ?
                         ". On Windows pyo3 still links the interpreter's import library with " *
                         "`extension-module`, so this build is linkable where a Unix one would " *
                         "not be" : "") * note; interpreter = interpreter)
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
3. macOS only: `sysconfig.get_config_var("PYTHONFRAMEWORKPREFIX")`, the
   directory *containing* `Python3.framework`;
4. `python3-config --ldflags`, taking its `-L` directory;
5. `sysconfig.get_config_var("LIBDIR")` of `python3`.

Only an existing directory is returned.

This is the directory half of `python_link_source`, which decides the
directory and the interpreter (`PYO3_PYTHON`) together; an explicit
`PYO3_PYTHON` changes which interpreter steps 3–5 ask.

# Why the framework prefix comes first on macOS

A framework build of Python is linked as
`@rpath/Python3.framework/Versions/3.x/Python3`, so the rpath the wrapper needs
is the directory holding the `.framework`, not `LIBDIR` (which is
`…/Versions/3.x/lib`, one level *inside* it). Handing the linker `LIBDIR`
produces a cdylib whose `@rpath` reference cannot be resolved and which then
fails to load — with a message about a missing `Python3.framework`, not about
the directory that was wrong.
"""
python_library_dir() = python_link_source()[1]

"""
    python_link_source() -> (libdir::String, interpreter::String)

The library directory a `:link_libpython` wrapper links against **and the
interpreter it pins `PYO3_PYTHON` to**, decided together so the two cannot
name different Pythons: pyo3's build script configures itself for
`PYO3_PYTHON` while the linker searches `libdir`, and a pair taken from two
sources is a cdylib configured for one ABI and linked against another (#307
review). Either half is `""` when it cannot be identified.

In order:

1. `PYO3_PYTHON`, when set, is the interpreter — an explicit choice, a virtual
   environment or a Conda interpreter, is never replaced by the first `python3`
   on `PATH`. The directory is `RUSTCALL_PYTHON_LIBDIR` if that is set, else
   what **that** interpreter reports (its framework prefix on macOS, its
   `sysconfig` `LIBDIR` otherwise).
2. `RUSTCALL_PYTHON_LIBDIR` alone is the directory; the interpreter is the
   `python3` / `python` on `PATH`, the one `python3-config` describes.
3. A loaded CondaPkg names both: `<envdir>/lib` and the environment's own
   `python`.
4. Otherwise the `python3` / `python` on `PATH`: its `sys.executable`, and its
   directory from the framework prefix (macOS), `python3-config --ldflags`, or
   `sysconfig` `LIBDIR`, in that order.
"""
function python_link_source()
    override = get(ENV, "RUSTCALL_PYTHON_LIBDIR", "")
    override_dir = isempty(override) ? "" : (isdir(override) ? String(override) : "")

    pinned = get(ENV, "PYO3_PYTHON", "")
    if !isempty(pinned)
        dir = isempty(override) ? _python_library_dir_of(pinned) : override_dir
        return (dir, String(pinned))
    end
    isempty(override) || return (override_dir, _python_executable_on_path())

    conda = _condapkg_link_source()
    conda === nothing || return conda

    for exe in ("python3", "python")
        interpreter = _python_executable(exe)
        isempty(interpreter) && continue
        dir = Sys.isapple() ? _python_framework_prefix(exe) : ""
        isempty(dir) && (dir = _python_config_libdir())
        isempty(dir) && (dir = _python_sysconfig_libdir(exe))
        return (dir, interpreter)
    end
    return ("", "")
end

_python_link_source_or_empty() = try
    python_link_source()
catch
    ("", "")
end

# `sys.executable` of `exe`; "" when it cannot be run.
function _python_executable(exe::AbstractString)
    try
        path = strip(read(`$exe -c "import sys; print(sys.executable)"`, String))
        return isempty(path) ? "" : String(path)
    catch
        return ""
    end
end

function _python_executable_on_path()
    for exe in ("python3", "python")
        path = _python_executable(exe)
        isempty(path) || return path
    end
    return ""
end

# The library directory `exe` itself reports: its framework prefix on macOS
# (see `python_library_dir` for why that comes first), else its `sysconfig`
# `LIBDIR`. "" when it reports neither or cannot be run.
function _python_library_dir_of(exe::AbstractString)
    if Sys.isapple()
        prefix = _python_framework_prefix(exe)
        isempty(prefix) || return prefix
    end
    return _python_sysconfig_libdir(exe)
end

# The directory holding `<name>.framework` for a macOS framework build of
# Python; "" for a non-framework build or when the interpreter cannot be asked.
function _python_framework_prefix(exe::AbstractString)
    try
        code = "import sysconfig; " *
               "print(sysconfig.get_config_var('PYTHONFRAMEWORKPREFIX') or '')"
        dir = strip(read(`$exe -c $code`, String))
        return !isempty(dir) && isdir(dir) ? String(dir) : ""
    catch
        return ""
    end
end

# CondaPkg is not a dependency of RustCall; it is used only when the user's
# session already loaded it (PythonCall), in which case its environment holds
# the interpreter the wrapper should link against — both halves of the pair.
# `nothing` when CondaPkg is not loaded or its environment has no `lib`.
function _condapkg_link_source()
    for (id, mod) in Base.loaded_modules
        id.name == "CondaPkg" || continue
        try
            env = String(Base.invokelatest(getfield(mod, :envdir)))
            dir = joinpath(env, "lib")
            isdir(dir) || break
            exe = Sys.iswindows() ? joinpath(env, "python.exe") : joinpath(env, "bin", "python")
            return (dir, isfile(exe) ? exe : "")
        catch
        end
        break
    end
    return nothing
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

function _python_sysconfig_libdir(exe::AbstractString)
    try
        code = "import sysconfig; print(sysconfig.get_config_var('LIBDIR') or '')"
        dir = strip(read(`$exe -c $code`, String))
        return isdir(dir) ? String(dir) : ""
    catch
        return ""
    end
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
    # `-L native=` is the search path the *linker* uses, and is portable.
    # The runtime search path is not: `-Wl,-rpath` is a GNU/Apple ld option
    # that link.exe rejects outright, and Windows has no rpath concept at all —
    # the loader finds a DLL through the executable's directory and `PATH`. So
    # on Windows only the search path is emitted, and the caller is responsible
    # for making the interpreter's DLL directory reachable at load time (#294
    # review).
    Sys.iswindows() && return String["-L", "native=$(plan.rpath)"]
    return String["-L", "native=$(plan.rpath)",
                  "-C", "link-arg=-Wl,-rpath,$(plan.rpath)"]
end

# ----------------------------------------------------------------------------
# Phase 2: generating, building and binding the wrapper crate
#
# Lives here rather than in crate_bindings.jl because it is written in terms of
# `PyO3LinkPlan`, and pyo3.jl is included after crate_bindings.jl (the scan it
# reports comes from `scan_crate`). `generate_bindings` calls into it at run
# time, which needs no include-order relationship.
# ----------------------------------------------------------------------------

"""
    PyO3Wrapper

A built wrapper crate for a PyO3 crate that carries no RustCall attribute
(#275 Phase 2).

- `info`: a `CrateInfo` whose `julia_functions` / `julia_structs` are the items
  the **wrapper** exports, so every existing emitter binds them exactly as it
  binds `#[julia]` ones;
- `plan`: the `PyO3LinkPlan` the wrapper was built under;
- `source`: the generated `lib.rs` and the manifest that describes it;
- `lib_path`: the compiled cdylib;
- `lib_name`: the `RUST_LIBRARIES` key, which includes the feature set, so two
  builds of one crate under different features do not clobber each other;
- `skipped`: the PyO3 items that were *not* wrapped, each with its reason.
"""
struct PyO3Wrapper
    info::CrateInfo
    plan::PyO3LinkPlan
    source::WrapperCrateSource
    lib_path::String
    lib_name::String
    skipped::Vector{Any}
end

"""
    crate_needs_pyo3_wrapper(info::CrateInfo) -> Bool

Whether `@rust_crate` should generate a wrapper crate for the PyO3 items of
this crate rather than bind only its `#[julia]` ones (#275 Phase 2).

It should exactly when the scan found a PyO3 item a wrapper *could* export. A
crate whose PyO3 items are all skipped, or which has none, takes the pre-#275
path unchanged — so nothing that worked before now runs a Cargo feature
resolution it does not need.

This is the cheap pre-check, on the lenient scan `scan_crate` already did.
`build_pyo3_wrapper` has the final say: under the build's own configuration a
marker behind a feature that is off is simply not there, and it returns
`nothing` so the caller falls back to the same pre-#275 path.
"""
function crate_needs_pyo3_wrapper(info::CrateInfo)
    any(isempty(f.skip_reason) for f in info.pyo3_functions) && return true
    for st in info.pyo3_structs
        isempty(st.skip_reason) || continue
        (any(isempty(m.skip_reason) for m in st.methods) ||
         !isempty(st.field_getters) || !isempty(st.field_setters)) && return true
    end
    return false
end

"""
    build_pyo3_wrapper(info; features, default_features, release, cache_enabled) -> PyO3Wrapper

Generate, build and load-prepare the wrapper crate for `info` (#275 Phase 2).

The steps, in the order their failures matter:

1. **Decide whether a wrapper can be linked at all.** `pyo3_link_plan` asks
   Cargo to resolve the feature set, and `pyo3_link_rustflags` raises for an
   `:unlinkable` build or a `:link_libpython` one with no interpreter library
   directory. Nothing is generated or compiled before that is settled.
2. **Generate.** `wrap_crate` re-runs the scan `scan_crate` reported and turns
   it into a `lib.rs` plus the manifest of what that file exports.
3. **Build.** A temporary Cargo project with `crate-type = ["cdylib"]`, the
   target crate as its only dependency (with the plan's features, and
   `default-features` switched off there when the plan says so — nothing on the
   `cargo build` command line can do that for a *dependency*), `panic =
   "unwind"` pinned as every RustCall build is, and the plan's link flags.
4. **Cache.** Under an `ArtifactId` of kind `pyo3-wrapper` whose codegen fields
   carry the feature set and the link flags, so a build under other features is
   a different artifact rather than a silent cache hit.

# The scan is lenient, and that is deliberate

A PyO3 marker can be conditional (`#[cfg_attr(feature = "python", pyfunction)]`)
while the item it marks is not. The wrapper calls the *item*, so it can be built
even for a feature set in which nothing is exposed to Python — which is how a
crate with an optional pyo3 dependency gets a wrapper that links no libpython at
all. Scanning strictly under such a build would report no PyO3 item and wrap
nothing.

The price is that an item whose own `#[cfg]` predicate is undecided cannot be
called safely, so the generator refuses it with `cfg_undecided` rather than
guessing. When Cargo resolved the build's configuration, the plan carries it,
the scan is strict, and no item is refused for that reason.
"""
function build_pyo3_wrapper(info::CrateInfo;
                            features::Vector{String} = String[],
                            default_features::Bool = true,
                            release::Bool = true,
                            cache_enabled::Bool = true)
    plan = pyo3_link_plan(info.path; features = features, default_features = default_features,
                          release = release)

    cargo_toml = parse_cargo_toml(joinpath(info.path, "Cargo.toml"))
    source_files = sort(find_rust_sources(info.path))
    lib_root, tree_files = _crate_scan_inputs(info.path, cargo_toml, source_files)
    # The scan that feeds the generator runs under the configuration the build
    # is actually compiled with whenever Cargo could answer, so an item behind
    # a `#[cfg]` is *decided* rather than refused: asking for
    # `features = ["python"]` and then declaring every feature-gated item
    # undecidable would refuse exactly the API that was requested. Only an
    # unresolved plan falls back to lenient evaluation, where the generator
    # does refuse such an item (`cfg_undecided`) rather than call something the
    # build may not have.
    cfg, cfg_text = isempty(plan.cfg_text) ? (:lenient, nothing) : (:cargo, plan.cfg_text)
    source = wrap_crate(tree_files; crate_name = crate_rust_identifier(info.name, cargo_toml),
                        cfg = cfg, cfg_text = cfg_text,
                        crate_root = lib_root, skip_unparsable = true)

    functions, structs, skipped, pyo3_exports = _pyo3_wrapper_items(source.manifest)
    # Nothing PyO3 to wrap under this feature set — a crate whose markers are
    # all behind a feature that is off exposes no Python API in this build, and
    # so has nothing for a wrapper crate to export. The caller falls back to the
    # pre-#275 path rather than building an empty cdylib.
    pyo3_exports == 0 && return nothing

    # Raises for :unlinkable and for :link_libpython with no interpreter
    # directory. After generation, which compiles nothing, and before the build.
    rustflags = pyo3_link_rustflags(plan)

    wrapper_info = CrateInfo(info.name, info.path, info.version, info.dependencies,
                             functions, structs, info.source_files,
                             info.pyo3_functions, info.pyo3_structs)

    build_env = _pyo3_wrapper_build_env(plan, rustflags)
    key = compute_crate_hash(info; release = release, kind = "pyo3-wrapper",
                             features = features, default_features = default_features,
                             build_env = build_env)
    lib_name = "rust_crate_$(info.name)_$(artifact_short_id(key))"

    cached = cache_enabled ? get_cargo_cached_library(key) : nothing
    lib_path = if cached !== nothing && isfile(cached)
        @debug "Using cached PyO3 wrapper library" key=artifact_short_id(key, 8)
        cached
    else
        _build_pyo3_wrapper_project(info, plan, source, rustflags, release, key, cache_enabled)
    end

    return PyO3Wrapper(wrapper_info, plan, source, lib_path, lib_name, skipped)
end

"""
    _pyo3_wrapper_build_env(plan, rustflags) -> Vector{Pair{String, String}}

The build-environment half of a wrapper's `ArtifactId`. The environment the
build inherits is part of the artifact, not just the flags RustCall adds:
`RUSTFLAGS` and the rest of the #282 allowlist reach `cargo` through
`_build_pyo3_wrapper_project`, so two builds under different ambient flags are
different binaries. So are the plan's link flags — and, for `:link_libpython`,
the interpreter the build pins `PYO3_PYTHON` to: it is decided by the plan,
*before* the key, so a wrapper configured for one Python never answers a lookup
made for another that happens to share its library directory (#307 review;
#278's rule that identity is exhaustive). A `:python_free` build pins nothing
and records nothing.
"""
function _pyo3_wrapper_build_env(plan::PyO3LinkPlan, rustflags::Vector{String})
    build_env = artifact_build_env()
    push!(build_env, "rustcall-link-flags" => join(rustflags, " "))
    plan.mode === :link_libpython &&
        push!(build_env, "rustcall-pyo3-python" => plan.interpreter)
    return build_env
end

"""
    crate_rust_identifier(package_name, cargo_toml) -> String

The name **Rust code** refers to this crate by, which is not always its package
name: `[lib] name = "..."` renames the library target, and a dependent crate
then writes `that_name::item`. Cargo also maps `-` to `_` in an identifier.

Generated wrapper code names the dependency by path, so getting this wrong is
an unresolved-crate compile error in code the user never wrote.
"""
function crate_rust_identifier(package_name::AbstractString, cargo_toml::AbstractDict)
    lib = get(cargo_toml, "lib", nothing)
    name = lib isa AbstractDict ? String(get(lib, "name", String(package_name))) :
                                  String(package_name)
    return replace(name, '-' => '_')
end

"""
    _pyo3_wrapper_items(manifest) -> (functions, structs, skipped, pyo3_exports)

Split the wrapper crate's manifest into what Julia binds and what it reports.

**Both origins are bound.** A crate may carry `#[julia]` items *and* PyO3-only
ones; the wrapper crate exports the second kind and links the first, whose
`rustcall_*` symbols the dependency's own object code already provides (the
generated `lib.rs` keeps the glob import that pulls them into the cdylib).
Returning only the PyO3 entries silently dropped every `#[julia]` function and
struct of such a crate from the module `@rust_crate` handed back.

Only entries the generator actually emitted are bound: a `skip_reason` means no
symbol exists, and generating a Julia definition for one would produce a
`dlsym` failure at the first call instead of a message at scan time. Methods are
filtered inside their class for the same reason, and the class keeps its fields
untouched because the generator already cleared the accessors it did not emit.

`pyo3_exports` counts the **PyO3-origin** items that were emitted, which is what
decides whether a wrapper crate is worth building at all.
"""
function _pyo3_wrapper_items(manifest::Dict)
    skipped = Any[]
    functions = RustFunctionSignature[]
    pyo3_exports = 0

    # `#[julia]` items first, unchanged: the wrapper crate does not generate
    # them, it links them.
    for f in manifest_function_signatures(manifest)
        f.is_generic || push!(functions, f)
    end
    for f in manifest_function_signatures(manifest; origins = PYO3_ATTRIBUTE_ORIGINS)
        if isempty(f.skip_reason) && f.exported && !f.is_generic
            push!(functions, f)
            pyo3_exports += 1
        else
            push!(skipped, f)
        end
    end

    structs = RustStructInfo[]
    append!(structs, manifest_struct_infos(manifest))
    for st in manifest_struct_infos(manifest; origins = PYO3_ATTRIBUTE_ORIGINS)
        if !isempty(st.skip_reason)
            push!(skipped, st)
            continue
        end
        kept = RustMethod[]
        for m in st.methods
            isempty(m.skip_reason) ? push!(kept, m) : push!(skipped, m)
        end
        # Every accessor the wrapper emits is an export, a setter with no
        # getter included (#307 review).
        pyo3_exports += length(kept) + count(!isempty, values(st.field_getters)) +
                        count(!isempty, values(st.field_setters))
        push!(structs, RustStructInfo(
            st.name, st.type_params, kept, st.context_code, st.fields,
            st.has_derive_julia_struct, st.derive_options;
            field_abis = st.field_abis, field_getters = st.field_getters,
            field_setters = st.field_setters, has_clone = st.has_clone,
            has_owned_string_helper = st.has_owned_string_helper,
            has_borrowed_string_helper = st.has_borrowed_string_helper,
            generic_wrappers = st.generic_wrappers, constraints = st.constraints,
            module_path = st.module_path, attribute = st.attribute, vis = st.vis,
            skip_reason = st.skip_reason, python_name = st.python_name,
            cfg_features = st.cfg_features))
    end
    return functions, structs, skipped, pyo3_exports
end

"""
    _build_pyo3_wrapper_project(info, plan, source, rustflags, release, key, cache_enabled) -> String

Write the generated wrapper crate to a temporary directory, build it, and
return a path to the result that **outlives that directory**.

`RUSTFLAGS` carries the plan's link flags; `PYO3_PYTHON` pins the interpreter
pyo3's build script probes to the one whose library directory the plan put on
the search path, so the cdylib cannot end up linked against one Python and
pointed at another.

The build directory is temporary and removed as soon as the build finishes, so
the library is copied out **before** the cleanup — into the artifact cache under
`key` when caching is on, and otherwise into a directory of its own. Returning
Cargo's own output path here left `load_artifact!` opening a file that had
already been deleted.
"""
function _build_pyo3_wrapper_project(info::CrateInfo, plan::PyO3LinkPlan,
                                     source::WrapperCrateSource,
                                     rustflags::Vector{String}, release::Bool,
                                     key::String, cache_enabled::Bool)
    wrapper_path = mktempdir(prefix = "rustcall_pyo3_wrapper_")
    mkpath(joinpath(wrapper_path, "src"))
    write(joinpath(wrapper_path, "Cargo.toml"),
          generate_pyo3_wrapper_cargo_toml(info, plan))
    write(joinpath(wrapper_path, "src", "lib.rs"), source.lib_rs)

    project = CargoProject("$(info.name)_rustcall_wrapper", "0.1.0", DependencySpec[],
                           "2021", wrapper_path)
    env = Dict{String, String}(ENV)
    isempty(rustflags) || (env["RUSTFLAGS"] = _merge_rustflags(get(env, "RUSTFLAGS", ""), rustflags))
    # Only where pyo3 is actually in the graph: a `:python_free` build has no
    # pyo3 build script to configure, and pinning an interpreter it will never
    # consult would misdescribe the build. The interpreter is the plan's — it
    # honours a caller's own `PYO3_PYTHON`, was chosen next to `plan.rpath`,
    # and is already in the artifact key (`_pyo3_wrapper_build_env`).
    if plan.mode === :link_libpython && !isempty(plan.interpreter)
        env["PYO3_PYTHON"] = plan.interpreter
    end
    try
        built = build_cargo_project(project; release = release, env = env,
                                    policy = crate_wrapper_policy())
        if cache_enabled
            try
                save_cargo_cached_library(key, built)
                cached = get_cargo_cached_library(key)
                cached === nothing || return cached
            catch e
                @debug "Failed to cache PyO3 wrapper library: $e"
            end
        end
        # No cache: keep the library somewhere the cleanup below does not reach.
        keep = joinpath(mktempdir(prefix = "rustcall_pyo3_lib_"), basename(built))
        cp(built, keep; force = true)
        return keep
    finally
        cleanup_cargo_project(project)
    end
end

# RUSTFLAGS is a whitespace-separated list; an inherited one is kept so a user's
# own flags are not silently dropped by a wrapper build.
_merge_rustflags(inherited::AbstractString, added::Vector{String}) =
    strip(string(inherited, " ", join(added, " ")))

"""
    generate_pyo3_wrapper_cargo_toml(info::CrateInfo, plan::PyO3LinkPlan) -> String

The `Cargo.toml` of a #275 Phase-2 wrapper crate.

The dependency entry comes from `pyo3_dependency_toml`, which is the only place
a **dependency's** default features can be switched off — `cargo build
--no-default-features` applies to the package being built, i.e. the wrapper. The
wrapper depends on nothing else: everything the generated code needs is `std`,
which is what makes the shape identical to a `#[julia]` crate's output.
"""
function generate_pyo3_wrapper_cargo_toml(info::CrateInfo, plan::PyO3LinkPlan)
    lines = String[
        "# Generated by RustCall.jl for the PyO3 crate `$(info.name)` (#275 Phase 2).",
        "# Link plan: $(plan.mode) — $(plan.reason)",
        "[package]",
        "name = \"$(info.name)_rustcall_wrapper\"",
        "version = \"0.1.0\"",
        "edition = \"2021\"",
        "",
        "[lib]",
        "crate-type = [\"cdylib\"]",
        "",
        rstrip(pyo3_dependency_toml(plan, info.name, info.path)),
        "",
        "[profile.release]",
        "opt-level = 3",
    ]
    # Pinned for the same reason every RustCall build pins it: the generated
    # `catch_unwind` boundary can only catch a panic that unwinds (#244).
    panic_line = cargo_profile_panic_line(crate_wrapper_policy())
    panic_line === nothing || push!(lines, panic_line)
    return join(lines, "\n") * "\n"
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

Returns `(; julia, wrappable, wrapped, skipped, plan, info, candidates)`:

* `julia` — items carrying a RustCall attribute (`#[julia]`, `#[julia_pyo3]`),
  which `@rust_crate` wraps today;
* `wrappable` — PyO3 items the *scan* found no reason to reject: a wrapper crate
  can name each of them;
* `wrapped` — the items the Phase-2 **generator** actually emitted an entry point
  for, with `symbol` naming it (#275 Phase 2). It is a subset of `wrappable`:
  the generator refuses a signature it cannot lower — a `Vec` argument, a
  `PyResult<String>`, an item behind an undecided `#[cfg]` — and those appear in
  `skipped` with the reason it gave. `nothing` when the wrapper could not be
  generated at all (`generate = false`, or an `:unlinkable` plan), in which case
  `skipped` holds only the scan's own reasons;
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
                     default_features::Bool = true, release::Bool = true, io::IO = stdout,
                     generate::Bool = true)
    plan = pyo3_link_plan(crate_path; features = features, default_features = default_features,
                          release = release)
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

    # What the Phase-2 generator would actually emit. This is the column that
    # answers "and does it *build*?": the scan says an item is namable, the
    # generator says whether its signature can be lowered. Generating is cheap
    # (it runs the extractor again and compiles nothing), so the report shows
    # it by default; `generate = false` is the pure Phase-1 report.
    wrapped = nothing
    generate_error = ""
    if generate
        try
            cargo_toml = parse_cargo_toml(joinpath(String(crate_path), "Cargo.toml"))
            source_files = sort(find_rust_sources(String(crate_path)))
            lib_root, tree_files = _crate_scan_inputs(String(crate_path), cargo_toml, source_files)
            cfg, cfg_text = isempty(plan.cfg_text) ? (:lenient, nothing) : (:cargo, plan.cfg_text)
            source = wrap_crate(tree_files;
                                crate_name = crate_rust_identifier(info.name, cargo_toml),
                                cfg = cfg, cfg_text = cfg_text,
                                crate_root = lib_root, skip_unparsable = true)
            functions, structs, refused, _ = _pyo3_wrapper_items(source.manifest)
            wrapped = Any[]
            for f in functions
                String(f.attribute) in PYO3_ATTRIBUTE_ORIGINS || continue
                push!(wrapped, f)
            end
            for st in structs
                String(st.attribute) in PYO3_ATTRIBUTE_ORIGINS || continue
                push!(wrapped, st)
                append!(wrapped, st.methods)
            end
            # The generator's refusals replace the scan's list: it starts from
            # the same scan and only ever adds reasons.
            skipped = refused
        catch e
            generate_error = sprint(showerror, e)
        end
    end

    build = isempty(plan.feature_flags) ? "default features" : join(plan.feature_flags, " ")
    println(io, "Crate $(info.name) v$(info.version) ($(info.path))")
    println(io, "  Build scanned: $(build)",
            plan.resolved ? "" : " (Cargo could not resolve it; every #[cfg] item is reported)")
    println(io, "  RustCall items (wrapped today): $(length(julia_items))")
    for item in julia_items
        println(io, "    $(_pyo3_item_label(item))")
    end
    println(io, "  PyO3 items the scan can name: $(length(wrappable))")
    for item in wrappable
        println(io, "    $(_pyo3_item_label(item))")
    end
    if wrapped === nothing
        println(io, "  Wrapper crate: not generated",
                isempty(generate_error) ? "" : " ($(generate_error))")
    else
        println(io, "  Wrapper crate exports: $(length(wrapped))")
        for item in wrapped
            println(io, "    $(_pyo3_item_label(item))$(_pyo3_symbol_suffix(item))")
        end
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

    return (julia = julia_items, wrappable = wrappable, wrapped = wrapped,
            skipped = skipped, plan = plan, info = info, candidates = candidates)
end

# The exported symbol of a wrapped item, for the report. A class has no symbol
# of its own -- it is a handle its methods and accessors hang off.
_pyo3_symbol_suffix(f::RustFunctionSignature) = isempty(f.symbol) ? "" : " -> $(f.symbol)"
_pyo3_symbol_suffix(m::RustMethod) = isempty(m.symbol) ? "" : " -> $(m.symbol)"
_pyo3_symbol_suffix(s::RustStructInfo) = " -> $(ffi_struct_free_symbol(s.name))"

_pyo3_item_label(f::RustFunctionSignature) =
    "fn $(qualified_name(f.module_path, f.name)) -> $(f.return_type) [$(f.attribute)]"
_pyo3_item_label(s::RustStructInfo) = "struct $(qualified_name(s.module_path, s.name)) [$(s.attribute)]"
_pyo3_item_label(m::RustMethod) = "method $(m.name) -> $(m.return_type)"
