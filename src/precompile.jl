# `__init__` eagerly loads the ownership helper library, and that load path is
# the only thing that exercises a broad family of `_state_read`/`_state_mutate`
# specializations: the do-block closures in `src/RustCall.jl` and
# `_state_mutate_storage!` (`src/state_filter.jl`) are keyed by the concrete
# state-container type, and `load_artifact!` touches `Dict{Ptr{Cvoid}, Int}`,
# `Dict{Ptr{Cvoid}, RetiredImage}`, `Dict{String, Ref{Bool}}`, several `Ref`s and
# the deferred-drop `Vector{DeferredDrop}` in one go.
#
# Precompilation never runs `__init__`, so those specializations are absent from
# the package image and every `using RustCall` JIT-compiles them in-process.
# Measured on Julia 1.13 the path costs ~0.65 s of a ~0.86 s load (`@time_imports`
# reports 97% compilation time for `__init__`; `--compile=min` drops the load to
# ~0.21 s), dominated by one 40–80 ms compile per container type.
#
# The workload below replays those state operations against throwaway
# containers so the native code lands in the image. The dummy views are removed
# before returning, so no serializable state — let alone a pointer — survives
# into the `.ji`. It runs only while generating output; at `using` time this file
# does nothing.
function _precompile_init_load_path()
    added = Symbol[]
    add(name, value) = begin
        STATE.value.values[name] = value
        push!(added, name)
        StateView(name)
    end
    try
        ptr = Ptr{Cvoid}(0)

        # OWNED_HANDLES[handle] = count (setindex! with (value, key))
        _state_mutate(add(:__precompile_owned_handles, Dict{Ptr{Cvoid}, Int}()),
                      :setindex!, 1, ptr)

        # RETIRED_HANDLES: delete!(view, handle)
        _state_mutate(add(:__precompile_retired_handles,
                          Dict{Ptr{Cvoid}, RetiredImage}()),
                      :delete!, ptr)

        # HANDLE_ONLY_ALIVE[handle] = alive
        _state_mutate(add(:__precompile_handle_only_alive,
                          Dict{Ptr{Cvoid}, Ref{Bool}}()),
                      :setindex!, Ref(false), ptr)

        # ARTIFACT_ALIVE[name] = alive
        _state_mutate(add(:__precompile_artifact_alive,
                          Dict{String, Ref{Bool}}()),
                      :setindex!, Ref(false), "lib")

        # RUST_HELPERS_LIB[] = handle
        _state_mutate(add(:__precompile_rust_helpers_lib,
                          Ref{Union{Nothing, Ptr{Cvoid}}}(nothing)),
                      :setindex!, ptr)

        # DROP_WARNING_SHOWN[] = flag, and the per-image liveness flags
        _state_mutate(add(:__precompile_drop_warning_shown, Ref{Bool}(false)),
                      :setindex!, true)

        # The deferred-drop queue, as `flush_deferred_drops` drains it.
        queue = add(:__precompile_deferred_drops, DeferredDrop[])
        _state_mutate(queue, :push!,
                      DeferredDrop(ptr, "RustBox{Int32}", :rust_box_drop_i32))
        _state_read(queue, copy)
        _state_mutate(queue, :empty!)

        # `preloaded_libraries` and roster queries copy a populated registry.
        _state_read(add(:__precompile_rust_libraries,
                        Dict{String, Tuple{Ptr{Cvoid}, Dict{String, Ptr{Cvoid}}}}()),
                    copy)
    finally
        for name in added
            delete!(STATE.value.values, name)
        end
    end
    return nothing
end


# ----------------------------------------------------------------------------
# The crate scan / hash / host-artifact path (#449)
# ----------------------------------------------------------------------------
#
# `scan_crate`, `compute_crate_hash` and the cache lookup of
# `build_pyo3_extension` are the first thing a `pyo3_host_import` (or a
# `@rust_crate` facade's first call) runs in a fresh session, and none of it was
# in the image: measured on Julia 1.13 the first `scan_crate` of a small crate
# spent ~1.9 s compiling and the first `compute_crate_hash` ~0.6 s, against
# ~10 ms once warm. A downstream package cannot bake it — the callees are
# reached through `Dict{String, Any}` values, so
# `Base.precompile(pyo3_host_import, (String,))` compiles the thin method and
# stops — and it cannot *execute* the host path while precompiling, because that
# needs a Python interpreter, which may not be started then.
#
# So RustCall executes the interpreter-free part itself, here, against a
# throwaway crate written to a temporary directory. Three rules:
#
#   * **No `rustc`, no `cargo`, no Python.** `RustToolChain` may have to
#     download the toolchain, and the compiler identity is memoized in STATE.
#     Every memo the path would fill by running a tool is filled with a
#     placeholder for the duration: the cfg snapshot is passed in, the
#     dependency graph memo holds the answer Cargo gives for a crate with no
#     path dependency, the toolchain fingerprint and compiler identity are
#     fixed strings, and the cache directory is the temporary one.
#   * **The extractor is optional.** A fresh checkout precompiles before
#     `Pkg.build`, so the scan half is skipped, quietly, when `extractor_path()`
#     resolves nothing or the binary does not answer (a stale schema included);
#     the hash and lookup halves run on a hand-built `CrateInfo` regardless.
#   * **Nothing is left behind.** A temporary path or a placeholder memo would
#     be serialised into the `.ji`, so every view the path touches is snapshotted
#     first and restored in `finally`; `test_precompile.jl` compares every state
#     value before and after.

const _PRECOMPILE_PROBE_CARGO_TOML = """
[package]
name = "rustcall_precompile_probe"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib", "rlib"]

[dependencies]
pyo3 = { version = "0.29", features = ["extension-module"] }
rustcall_julia_macros = "0.6"
"""

const _PRECOMPILE_PROBE_LIB_RS = """
use pyo3::prelude::*;
use rustcall_julia_macros::julia;

#[julia]
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[julia]
pub fn shout(input: String) -> String {
    input.to_uppercase()
}

#[julia]
pub fn checked_div(a: i64, b: i64) -> Result<i64, String> {
    if b == 0 { Err("division by zero".to_string()) } else { Ok(a / b) }
}

#[julia]
pub struct Counter {
    value: i64,
}

#[julia]
impl Counter {
    pub fn new(value: i64) -> Self {
        Counter { value }
    }
    pub fn get(&self) -> i64 {
        self.value
    }
    pub fn bump(&mut self, by: i64) {
        self.value += by;
    }
}

#[pyfunction]
fn double(x: i64) -> i64 {
    x * 2
}

#[pyfunction]
#[pyo3(signature = (a, b = 10))]
fn add_default(a: i32, b: i32) -> i32 {
    a + b
}

#[pyfunction]
fn parse(s: &str) -> PyResult<i32> {
    s.trim().parse::<i32>().map_err(|_| pyo3::exceptions::PyValueError::new_err("not an integer"))
}

#[pyclass]
struct Gauge {
    #[pyo3(get, set)]
    level: f64,
}

#[pymethods]
impl Gauge {
    #[new]
    fn new(level: f64) -> Self {
        Gauge { level }
    }
    fn scaled(&self, k: f64) -> f64 {
        self.level * k
    }
    #[getter]
    fn half(&self) -> f64 {
        self.level / 2.0
    }
}

#[pymodule]
fn rustcall_precompile_probe(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(double, m)?)?;
    m.add_function(wrap_pyfunction!(add_default, m)?)?;
    m.add_function(wrap_pyfunction!(parse, m)?)?;
    m.add_class::<Gauge>()?;
    Ok(())
}
"""

# A plausible `--print cfg` text; it decides nothing here (the probe crate has
# no `#[cfg]`), it only keeps the scan on the `cfg = :lenient` route a
# `@rust_crate` / host scan takes without asking rustc for the real one.
const _PRECOMPILE_PROBE_CFG_TEXT =
    "debug_assertions\npanic=\"unwind\"\ntarget_family=\"unix\"\ntarget_os=\"linux\"\n" *
    "target_pointer_width=\"64\"\nunix\n"

# The views the workload writes through (directly or by way of the path it
# runs), each restored to its snapshot when the workload returns.
_precompile_scan_views() = (_RUSTC_CFG_FILE, _PATH_DEP_GRAPH_CACHE, _EXTRACTOR_PATH,
                            _EXTRACTOR_DIGEST, _EXTRACTOR_SOURCE_DIGEST,
                            _TOOLCHAIN_FINGERPRINT, _ARTIFACT_COMPILER_IDENTITY)

function _precompile_snapshot_views(views)
    return Dict{Symbol, Any}(view.name => _state_read(view) do value
        value isa Ref ? value[] : copy(value)
    end for view in views)
end

function _precompile_restore_views!(views, snapshot::Dict{Symbol, Any})
    for view in views
        saved = snapshot[view.name]
        if saved isa AbstractDict
            _state_mutate(view, :empty!)
            _state_mutate(view, :merge!, saved)
        else
            _state_mutate(view, :setindex!, saved)
        end
    end
    return nothing
end

"""
    _precompile_crate_scan_path() -> (; scanned, hashed, located)

Run the interpreter-free half of the host path against a throwaway crate so the
native code lands in the package image (#449); see the section comment above.
Returns which halves ran: `scanned` is `false` when no extractor answered, and
the other two are always `true` unless the workload raised.
"""
function _precompile_crate_scan_path()
    views = _precompile_scan_views()
    snapshot = _precompile_snapshot_views(views)
    scanned = false
    hashed = false
    located = false
    try
        mktempdir() do dir
            crate = joinpath(dir, "probe")
            mkpath(joinpath(crate, "src"))
            write(joinpath(crate, "Cargo.toml"), _PRECOMPILE_PROBE_CARGO_TOML)
            write(joinpath(crate, "src", "lib.rs"), _PRECOMPILE_PROBE_LIB_RS)

            info = try
                scanned_info = scan_crate(crate; cfg_text = _PRECOMPILE_PROBE_CFG_TEXT,
                                          allow_cargo = false)
                _pyo3_extension_module_name(scanned_info)
                scanned = true
                scanned_info
            catch err
                # No extractor (`extractor_path()`), one that fails or one of
                # another schema (`_parse_manifest`): the scan half is what the
                # binary decides, the rest of the path is not.
                err isa ExtractorError || rethrow()
                CrateInfo("rustcall_precompile_probe", abspath(crate), "0.1.0",
                          DependencySpec[], RustFunctionSignature[], RustStructInfo[],
                          String[joinpath(crate, "src", "lib.rs")])
            end

            # The answer `cargo tree` gives for a crate with no path dependency,
            # stamped the way `local_path_dependency_dirs` validates it, so the
            # hash below is a memo hit and Cargo is never run.
            canonical = _canonical_dir(crate)
            graph = ("cargo-tree", String[crate])
            _state_mutate(_PATH_DEP_GRAPH_CACHE, :setindex!,
                          (_graph_stamps(graph[2]), graph), canonical)
            _TOOLCHAIN_FINGERPRINT[] = "precompile-workload-toolchain"
            _ARTIFACT_COMPILER_IDENTITY[] = "rustc=precompile-workload\ncargo=precompile-workload"

            compute_crate_hash(info)   # what a `@rust_crate` build keys on
            hashed = true
            artifact = _pyo3_extension_artifact(
                joinpath(dir, "cache"), info, "rustcall_precompile_probe", "python3",
                ".cpython-313-x86_64-linux-gnu.so",
                "CPython|3.13.0|cpython-313-x86_64-linux-gnu|libpython3.13.so|/usr/lib|True")
            isfile(artifact.lib_path)
            located = true

            # The memo-miss side of the dependency graph, short of running
            # `cargo tree`: the manifest walk it falls back to and the parser of
            # its output. And the extractor's identity record, which the
            # toolchain fingerprint reads on its first use.
            manifest = joinpath(crate, "Cargo.toml")
            _declared_path_dependencies(manifest)
            _collect_manifest_path_deps!(String[crate], crate, Set{String}())
            _crate_dir_from_tree_line("rustcall_precompile_probe v0.1.0 ($(crate))")
            scanned && extractor_source_digest()
        end
    finally
        _precompile_restore_views!(views, snapshot)
    end
    return (; scanned, hashed, located)
end

# Every registry's container type, and the operations the `StateView` API
# reaches on it. `_state_mutate_storage!` and the read callables dispatch
# dynamically on the container (`@nospecialize`, by design), so a `Base` method
# they call on a registry has no backedge from RustCall's code, and the image
# keeps it only when it is named: Julia serialises what a workload compiled only
# where the package's own code can be seen to reach it. The list used to be
# written by hand, one registry at a time, and drifted — it named
# `Dict{Ptr{Cvoid}, Ref{Bool}}` where the container holds a `RefValue{Bool}`, so
# that 48 ms was paid at every `using` regardless — so it is derived from the
# containers themselves. A concrete value type gets the value-typed operations;
# an abstract `Ref{T}` is the `RefValue{T}` the registry stores; a `Union`
# element type gets one directive per concrete member.
function _precompile_concrete_members(@nospecialize(T))
    T isa Union && return filter(isconcretetype, Base.uniontypes(T))
    isconcretetype(T) && return Any[T]
    if T isa DataType && T.name === Ref.body.name && length(T.parameters) == 1
        stored = Base.RefValue{T.parameters[1]}
        isconcretetype(stored) && return Any[stored]
    end
    return Any[]
end

function _precompile_state_container_ops()
    for value in values(STATE.value.values)
        T = typeof(value)
        if value isa AbstractDict
            K = keytype(value)
            precompile(Base.haskey, (T, K))
            precompile(Base.get, (T, K, Nothing))
            precompile(Base.getindex, (T, K))
            precompile(Base.delete!, (T, K))
            precompile(Base.copy, (T,))
            precompile(Base.iterate, (T,))
            precompile(Base.empty!, (T,))
            for V in _precompile_concrete_members(valtype(value))
                precompile(Base.get, (T, K, V))
                precompile(Base.get!, (T, K, V))
                precompile(Base.setindex!, (T, V, K))
            end
        elseif value isa Ref
            precompile(Base.getindex, (T,))
            for E in _precompile_concrete_members(eltype(value))
                precompile(Base.setindex!, (T, E))
            end
        elseif value isa AbstractVector
            precompile(Base.copy, (T,))
            precompile(Base.iterate, (T,))
            precompile(Base.empty!, (T,))
            for E in _precompile_concrete_members(eltype(value))
                precompile(Base.push!, (T, E))
            end
        end
    end
    return nothing
end

if ccall(:jl_generating_output, Cint, ()) == 1
    _precompile_init_load_path()
    # The host path's scan/hash/lookup half (#449). A failure here must not
    # fail precompilation: the image is then merely slower on the first call.
    try
        _precompile_crate_scan_path()
    catch err
        @debug "RustCall precompile workload skipped the crate scan path" exception = (err, catch_backtrace())
    end
    # The entry points as a caller spells them. The workload passes `cfg_text`
    # and `allow_cargo`, and a body specialised on those argument types is not
    # the one the plain call reaches (`cfg_text = nothing` selects the cargo
    # probe route), so the callers' own signatures are named here; and the parts
    # the workload cannot execute without a tool — the cold `cargo tree`, the
    # cfg probes, the compiler identity — are compiled from their signatures.
    precompile(scan_crate, (String,))
    # `scan_crate`'s call into `extract_manifest` carries a `crate_root` of
    # `Union{Nothing, String}`, so inference from `scan_crate` stops at it.
    precompile(Core.kwcall,
               (NamedTuple{(:mode, :skip_unparsable, :cfg, :cfg_text, :crate_root, :edition,
                            :build_env),
                           Tuple{String, Bool, Symbol, Nothing, String, String, Nothing}},
                typeof(extract_manifest), Vector{String}))
    precompile(compute_crate_hash, (CrateInfo,))
    precompile(Core.kwcall, (NamedTuple{(:python,), Tuple{String}},
                             typeof(build_pyo3_extension), String))
    # Called from the workload with a concrete argument, so inlined there; the
    # standalone instances a dynamic caller reaches are named.
    precompile(_pyo3_extension_module_name, (CrateInfo,))
    precompile(Core.kwcall, (NamedTuple{(:features, :default_features, :release),
                                        Tuple{Vector{String}, Bool, Bool}},
                             typeof(_pyo3_extension_artifact), String, CrateInfo, String,
                             String, String, String))
    precompile(toolchain_fingerprint, ())
    precompile(artifact_compiler_identity, ())
    precompile(_cargo_cfg_text, ())
    precompile(_rustc_cfg_text, ())
    precompile(_local_path_dependency_dirs_uncached, (String,))
    precompile(_cargo_tree, (String, Bool))
    # The graph memo's validation compares stamps read back from the registry
    # as `Any`.
    precompile(Base.:(==), (Vector{Pair{String, Any}}, Vector{Pair{String, Any}}))
    _precompile_state_container_ops()
end
