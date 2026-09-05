# FFI manifest consumption.
#
# Julia never parses Rust source. Every signature it needs comes from the
# manifest produced by the `rustcall-extract` CLI (deps/rustcall_extract), which
# shares its `syn`-based core with the `juliacall_macros` proc-macro. This module
# locates the CLI, runs it, validates the manifest schema, and converts the
# manifest into the `RustFunctionSignature` / `RustStructInfo` values the code
# emitters consume.

using TOML
using SHA: sha256

"""
Manifest schema version this version of RustCall.jl understands. Must match
`rustcall_core::manifest::SCHEMA_VERSION`.
"""
const MANIFEST_SCHEMA_VERSION = 1

"""
    ExtractorError <: Exception

Raised when the `rustcall-extract` CLI is missing, fails, or produces a manifest
with an unsupported schema version.
"""
struct ExtractorError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ExtractorError) = print(io, "ExtractorError: ", e.msg)

# ----------------------------------------------------------------------------
# Locating and fingerprinting the extractor
# ----------------------------------------------------------------------------

const _EXTRACTOR_PATH = Ref{String}("")
const _EXTRACTOR_DIGEST = Ref{String}("")
const _TOOLCHAIN_FINGERPRINT = Ref{String}("")
const _EXTRACTOR_LOCK = ReentrantLock()

"""
    extractor_path() -> String

Path to the `rustcall-extract` binary. Honors the `RUSTCALL_EXTRACT` environment
variable, otherwise uses the binary built by `Pkg.build("RustCall")`.
"""
function extractor_path()
    lock(_EXTRACTOR_LOCK) do
        if !isempty(_EXTRACTOR_PATH[]) && isfile(_EXTRACTOR_PATH[])
            return _EXTRACTOR_PATH[]
        end
        candidates = String[]
        env = get(ENV, "RUSTCALL_EXTRACT", "")
        isempty(env) || push!(candidates, env)
        bin = Sys.iswindows() ? "rustcall-extract.exe" : "rustcall-extract"
        root = joinpath(dirname(@__DIR__), "deps", "rustcall_extract", "target")
        push!(candidates, joinpath(root, "release", bin))
        push!(candidates, joinpath(root, "debug", bin))
        for c in candidates
            if isfile(c)
                _EXTRACTOR_PATH[] = c
                return c
            end
        end
        throw(ExtractorError("""
        rustcall-extract binary not found. Looked at:
        $(join("  " .* candidates, "\n"))

        Run `using Pkg; Pkg.build("RustCall")` to build it, or set the
        RUSTCALL_EXTRACT environment variable to an existing binary.
        """))
    end
end

"""
    extractor_digest() -> String

SHA-256 of the extractor binary. Part of every cache key, so rebuilding the
extractor (new codegen, new schema) invalidates cached artifacts.
"""
function extractor_digest()
    lock(_EXTRACTOR_LOCK) do
        if isempty(_EXTRACTOR_DIGEST[])
            _EXTRACTOR_DIGEST[] = bytes2hex(open(sha256, extractor_path()))
        end
        return _EXTRACTOR_DIGEST[]
    end
end

"""
    _rust_sources_digest(dirs...) -> String

SHA-256 over the `src/*.rs` and `Cargo.toml` files of the given crate
directories, sorted by path. Used so that editing `juliacall_macros` or
`rustcall_core` invalidates artifacts built through Cargo.
"""
function _rust_sources_digest(dirs::AbstractString...)
    ctx = IOBuffer()
    for dir in dirs
        files = String[]
        for (root, _, names) in walkdir(dir)
            for n in names
                if endswith(n, ".rs") || n == "Cargo.toml"
                    push!(files, joinpath(root, n))
                end
            end
        end
        for f in sort(files)
            print(ctx, relpath(f, dir), "\0")
            write(ctx, read(f))
            print(ctx, "\0")
        end
    end
    return bytes2hex(sha256(take!(ctx)))
end

"""
    toolchain_fingerprint() -> String

Fingerprint of everything that influences generated code besides the user's
source: extractor binary, manifest schema, `rustcall_core` and
`juliacall_macros` sources, `rustc`/`cargo` versions and the host target.
Included in all cache keys.
"""
function toolchain_fingerprint()
    lock(_EXTRACTOR_LOCK) do
        if isempty(_TOOLCHAIN_FINGERPRINT[])
            deps = joinpath(dirname(@__DIR__), "deps")
            parts = String[
                "schema=$(MANIFEST_SCHEMA_VERSION)",
                "extractor=$(extractor_digest())",
                "core=$(_rust_sources_digest(joinpath(deps, "rustcall_core"), joinpath(deps, "juliacall_macros")))",
                "rustc=$(_get_rustc_version())",
                "cargo=$(_get_cargo_version())",
                "target=$(Sys.MACHINE)",
            ]
            _TOOLCHAIN_FINGERPRINT[] = bytes2hex(sha256(join(parts, "\n")))
        end
        return _TOOLCHAIN_FINGERPRINT[]
    end
end

const _cached_cargo_version = Ref{String}("")
function _get_cargo_version()::String
    if isempty(_cached_cargo_version[])
        try
            _cached_cargo_version[] = strip(read(`$(cargo()) --version`, String))
        catch
            _cached_cargo_version[] = "unknown"
        end
    end
    return _cached_cargo_version[]
end

"""
    _reset_extractor_state!()

Forget the cached extractor path/digest and fingerprint (used by tests after
rebuilding or swapping the extractor).
"""
function _reset_extractor_state!()
    lock(_EXTRACTOR_LOCK) do
        _EXTRACTOR_PATH[] = ""
        _EXTRACTOR_DIGEST[] = ""
        _TOOLCHAIN_FINGERPRINT[] = ""
    end
    lock(_EXPANSION_LOCK) do
        empty!(_EXPANSION_CACHE)
    end
    return nothing
end

# ----------------------------------------------------------------------------
# Running the extractor
# ----------------------------------------------------------------------------

function _run_extractor(args::Vector{String}; stdin_data::Union{Nothing, String} = nothing)
    exe = extractor_path()
    out = IOBuffer()
    err = IOBuffer()
    cmd = `$exe $args`
    proc = if stdin_data === nothing
        run(pipeline(cmd; stdout = out, stderr = err); wait = false)
    else
        run(pipeline(cmd; stdin = IOBuffer(stdin_data), stdout = out, stderr = err); wait = false)
    end
    wait(proc)
    if !success(proc)
        throw(ExtractorError("rustcall-extract $(join(args, " ")) failed:\n$(String(take!(err)))"))
    end
    return String(take!(out))
end

function _parse_manifest(text::AbstractString)
    dict = try
        TOML.parse(String(text))
    catch e
        throw(ExtractorError("failed to parse manifest TOML: $e"))
    end
    version = get(dict, "schema_version", nothing)
    if version != MANIFEST_SCHEMA_VERSION
        throw(ExtractorError(
            "manifest schema version mismatch: the rustcall-extract binary produced " *
            "schema $(version) but this RustCall.jl expects $(MANIFEST_SCHEMA_VERSION). " *
            "Rebuild with `Pkg.build(\"RustCall\")`."))
    end
    return dict
end

"""
    ExpandedInline

Result of expanding an inline `rust\"\"\"` block: the transformed source that goes
to `rustc` and the manifest describing it.
"""
struct ExpandedInline
    source::String
    manifest::Dict{String, Any}
end

const _EXPANSION_CACHE = Dict{String, ExpandedInline}()
const _EXPANSION_LOCK = ReentrantLock()

"""
    expand_inline(code::String) -> ExpandedInline

Expand `#[julia]` items of an inline block ahead of `rustc` and return the
manifest. Results are memoized per source text so macro expansion and the later
compile step spawn the extractor only once.
"""
function expand_inline(code::String)
    cached = lock(_EXPANSION_LOCK) do
        get(_EXPANSION_CACHE, code, nothing)
    end
    cached === nothing || return cached

    result = mktempdir() do dir
        src = joinpath(dir, "block.rs")
        manifest_path = joinpath(dir, "manifest.toml")
        write(src, code)
        source = _run_extractor(["expand", "--manifest", manifest_path, src])
        manifest = _parse_manifest(read(manifest_path, String))
        ExpandedInline(source, manifest)
    end
    lock(_EXPANSION_LOCK) do
        _EXPANSION_CACHE[code] = result
    end
    return result
end

"""
    extract_manifest(files::Vector{String}; mode::String) -> Dict

Run the extractor over source files (`mode` is `"inline"` or `"crate"`).
"""
function extract_manifest(files::Vector{String}; mode::String)
    mode in ("inline", "crate") || throw(ArgumentError("mode must be \"inline\" or \"crate\""))
    isempty(files) && return Dict{String, Any}(
        "schema_version" => MANIFEST_SCHEMA_VERSION, "mode" => mode,
        "functions" => Any[], "structs" => Any[])
    text = _run_extractor(vcat(["manifest", "--mode", mode], files))
    return _parse_manifest(text)
end

"""
    extract_manifest(code::String; mode::String) -> Dict

Run the extractor over a single source string.
"""
function extract_manifest(code::String; mode::String)
    mktempdir() do dir
        src = joinpath(dir, "source.rs")
        write(src, code)
        extract_manifest([src]; mode = mode)
    end
end

"""
    SpecializedFunction

Result of instantiating a generic function via `rustcall-extract specialize`.
"""
struct SpecializedFunction
    source::String
    name::String
    arg_types::Vector{String}
    return_type::String
end

"""
    specialize_generic(source, fn_name, bindings, new_name) -> SpecializedFunction

Instantiate generic function `fn_name` found in `source` with the given
`param => rust_type` bindings under the name `new_name`. The returned source
contains the original items plus the exported specialized function.
"""
function specialize_generic(source::String, fn_name::String,
                            bindings::Vector{Pair{String, String}}, new_name::String)
    mktempdir() do dir
        src = joinpath(dir, "generic.rs")
        manifest_path = joinpath(dir, "manifest.toml")
        write(src, source)
        args = ["specialize", "--fn", fn_name, "--new-name", new_name, "--manifest", manifest_path]
        for (p, t) in bindings
            push!(args, "--bind")
            push!(args, "$p=$t")
        end
        push!(args, src)
        out = _run_extractor(args)
        manifest = _parse_manifest(read(manifest_path, String))
        fn = only(manifest["functions"])
        SpecializedFunction(
            out,
            String(fn["name"]),
            String[String(a["rust_type"]) for a in get(fn, "args", Any[])],
            String(fn["return_type"]),
        )
    end
end

# ----------------------------------------------------------------------------
# Conversion to the emitter-facing types
# ----------------------------------------------------------------------------

_mstr(d, k) = String(get(d, k, ""))
_mbool(d, k) = Bool(get(d, k, false))
_mvec(d, k) = get(d, k, Any[])

"""
    manifest_type_params(entry) -> Vector{String}

Names of the type parameters recorded for a manifest function or struct entry.
"""
manifest_type_params(entry) = String[String(tp["name"]) for tp in _mvec(entry, "type_params")]

"""
    manifest_constraints(entry) -> Dict{Symbol, TypeConstraints}

Trait bounds recorded for a manifest function or struct entry.
"""
function manifest_constraints(entry)
    out = Dict{Symbol, TypeConstraints}()
    for tp in _mvec(entry, "type_params")
        bounds = TraitBound[TraitBound(String(b["trait_name"]),
                                       String[String(x) for x in _mvec(b, "type_params")])
                            for b in _mvec(tp, "bounds")]
        out[Symbol(tp["name"])] = TypeConstraints(bounds)
    end
    return out
end

"""
    constraints_from_strings(bounds::Dict{Symbol, String}) -> Dict{Symbol, TypeConstraints}

Convert `Dict(:T => "Copy + Add<Output = T>")` style bounds to `TypeConstraints`.
The strings are parsed by the Rust-side parser: they are placed on a synthetic
generic function and read back from its manifest.
"""
function constraints_from_strings(bounds::Dict{Symbol, String})
    isempty(bounds) && return Dict{Symbol, TypeConstraints}()
    params = join(("$(p): $(strip(b))" for (p, b) in bounds), ", ")
    snippet = "fn __rustcall_bounds<$(params)>() {}"
    sigs = manifest_function_signatures(extract_manifest(snippet; mode = "inline"); only_attributed = false)
    sig = only(sigs)
    out = Dict{Symbol, TypeConstraints}()
    for p in keys(bounds)
        out[p] = get(sig.constraints, p, TypeConstraints())
    end
    return out
end

"""
    manifest_function_signatures(manifest; only_attributed=true) -> Vector{RustFunctionSignature}

Signatures of the free functions in a manifest. With `only_attributed`, only
`#[julia]`/`#[julia_pyo3]` functions are returned (the ones that get Julia wrappers).
"""
function manifest_function_signatures(manifest::Dict; only_attributed::Bool = true)
    sigs = RustFunctionSignature[]
    for f in _mvec(manifest, "functions")
        attr = _mstr(f, "attribute")
        if only_attributed && !(attr in ("julia", "julia_pyo3"))
            continue
        end
        args = _mvec(f, "args")
        push!(sigs, RustFunctionSignature(
            _mstr(f, "name"),
            String[_mstr(a, "name") for a in args],
            String[_mstr(a, "rust_type") for a in args],
            _mstr(f, "return_type"),
            _mbool(f, "is_generic"),
            manifest_type_params(f);
            symbol = _mstr(f, "symbol"),
            attribute = Symbol(attr),
            exported = _mbool(f, "exported"),
            return_kind = Symbol(_mstr(f, "return_kind")),
            ok_type = _mstr(f, "ok_type"),
            err_type = _mstr(f, "err_type"),
            inner_type = _mstr(f, "inner_type"),
            source = _mstr(f, "source"),
            constraints = manifest_constraints(f),
            module_path = String[String(m) for m in _mvec(f, "module_path")],
        ))
    end
    return sigs
end

function _manifest_method(m)
    args = _mvec(m, "args")
    RustMethod(
        _mstr(m, "name"),
        _mbool(m, "is_static"),
        _mbool(m, "is_mutable"),
        String[_mstr(a, "name") for a in args],
        String[_mstr(a, "rust_type") for a in args],
        _mstr(m, "return_type");
        symbol = _mstr(m, "symbol"),
        is_constructor = _mbool(m, "is_constructor"),
        generic_wrapper = _mstr(m, "generic_wrapper"),
    )
end

"""
    manifest_struct_infos(manifest) -> Vector{RustStructInfo}

Struct descriptions of a manifest, in the shape the Julia emitters consume.
"""
function manifest_struct_infos(manifest::Dict)
    infos = RustStructInfo[]
    for s in _mvec(manifest, "structs")
        fields = Tuple{String, String}[]
        getters = Dict{String, String}()
        setters = Dict{String, String}()
        for f in _mvec(s, "fields")
            name = _mstr(f, "name")
            push!(fields, (name, _mstr(f, "rust_type")))
            if _mbool(f, "ffi_compatible") && !isempty(_mstr(f, "getter"))
                getters[name] = _mstr(f, "getter")
                isempty(_mstr(f, "setter")) || (setters[name] = _mstr(f, "setter"))
            end
        end
        derives = String[String(d) for d in _mvec(s, "derives")]
        derive_options = Dict{String, Bool}("JuliaStruct" => true)
        for d in derives
            derive_options[d] = true
        end
        push!(infos, RustStructInfo(
            _mstr(s, "name"),
            manifest_type_params(s),
            RustMethod[_manifest_method(m) for m in _mvec(s, "methods")],
            _mstr(s, "context_source"),
            fields,
            true,
            derive_options;
            field_getters = getters,
            field_setters = setters,
            has_clone = _mbool(s, "has_clone"),
            has_owned_string_helper = _mbool(s, "has_owned_string_helper"),
            has_borrowed_string_helper = _mbool(s, "has_borrowed_string_helper"),
            generic_wrappers = Tuple{String, String}[(_mstr(w, "name"), _mstr(w, "source"))
                                                     for w in _mvec(s, "generic_wrappers")],
            constraints = manifest_constraints(s),
            module_path = String[String(m) for m in _mvec(s, "module_path")],
        ))
    end
    return infos
end
