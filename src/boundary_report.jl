# The FFI surface report of #441: which argument and return positions of the
# wrappers RustCall generates the FFI contract cannot describe.

# Attributes whose items RustCall wraps (`Attribute::generates_wrapper` in
# `rustcall_julia_core`, minus the PyO3 origins, which `scan_report` covers).
const _BOUNDARY_ATTRIBUTES = ("julia", "derive_julia_struct")

"""
    boundary_report(crate_path; io = stdout) -> NamedTuple
    inline_boundary_report(code; io = stdout) -> NamedTuple

Check the FFI surface RustCall would generate for a crate (`@rust_crate`) or for
an inline `rust\"\"\"...\"\"\"` block, **without building or loading anything** (no Cargo runs; a crate's target
configuration comes from `rustc --print cfg`),
and list every argument or return position the FFI contract (the manual's
"The FFI Type Contract" page) cannot describe (#441).

An unsupported *return* type already fails when the wrapper is generated. An
unsupported *argument* type — a `Vec<f64>`, a `&OtherStruct`, a slice —
compiles, and fails only when it is called, with a message about the layout of
the Julia value rather than about the Rust signature. This report names the
Rust item and position instead, before anything is built.

Only positions RustCall generates a wrapper for are examined: `#[julia]`
functions, the methods of non-generic `#[julia]` structs that the mode wraps
(every `pub` method inline, only `#[julia]` methods in a crate), and the
getters of their readable fields. A
generic item is monomorphized later under types not known yet, and a plain
`#[no_mangle] extern "C"` function is exported as written, so neither is
checked. A constructor, or any method returning the struct itself, returns a
handle and is always describable.

Prints a summary to `io` and returns `(; unsupported, checked)`:

* `unsupported` — one `(; item, position, rust_type, abi, reason)` per position,
  where `item` is `"f"`, `"Struct::method"` or `"Struct::field"` (module-qualified
  below the crate root, `"a::f"`) and `position`
  is ``"argument `x`"``, `"return"`, `"Ok payload"`, `"Err payload"`,
  `"Some payload"` or `"field getter"`;
* `checked` — how many positions were examined.

```julia
RustCall.boundary_report("deps/my_facade")
RustCall.inline_boundary_report(\"\"\"
    #[julia]
    pub fn total(values: Vec<f64>) -> f64 { values.iter().sum() }
    \"\"\")
# 1 unsupported position(s) of 2 checked:
#   total, argument `values`: Vec<f64> — Vec<f64>: not in the FFI contract
```
"""
function boundary_report(crate_path::AbstractString; io::IO = stdout)
    isfile(joinpath(crate_path, "Cargo.toml")) ||
        throw(ArgumentError("not a crate: no Cargo.toml in $(crate_path)"))
    # The lenient scan `scan_crate` does by default, but with the target
    # configuration from `rustc --print cfg` rather than the Cargo probe a
    # lenient scan would otherwise start: this report runs no Cargo and builds
    # nothing (#450 review). A feature-gated item is reported, not decided.
    _, _, manifest = _crate_manifest(crate_path; cfg_text = _rustc_cfg_text(),
                                     allow_cargo = false)
    return _boundary_report(manifest, "crate $(crate_path)", io)
end

function inline_boundary_report(code::AbstractString; io::IO = stdout)
    manifest = extract_manifest(String(code); mode = "inline")
    return _boundary_report(manifest, "inline block", io)
end

const _BoundaryFinding = NamedTuple{(:item, :position, :rust_type, :abi, :reason),
                                    NTuple{5, String}}

function _boundary_report(manifest::AbstractDict, label::AbstractString, io::IO)
    unsupported = _BoundaryFinding[]
    checked = Ref(0)
    inline = get(manifest, "mode", "") == "inline"

    for f in get(manifest, "functions", Any[])
        get(f, "attribute", "none") in _BOUNDARY_ATTRIBUTES || continue
        get(f, "is_generic", false) && continue
        _boundary_check_entry!(unsupported, checked, _boundary_name(f), f)
    end

    # Keyed by module path and name: two `S` in different modules are two
    # structs, each with its own Julia submodule (#300, #450 review).
    infos = Dict((info.module_path, info.name) => info for info in manifest_struct_infos(manifest))
    for s in get(manifest, "structs", Any[])
        get(s, "attribute", "none") in _BOUNDARY_ATTRIBUTES || continue
        isempty(get(s, "type_params", Any[])) || continue
        struct_name = _boundary_name(s)
        info = get(infos, (_boundary_module_path(s), String(s["name"])), nothing)
        info === nothing || _boundary_check_fields!(unsupported, checked, info, struct_name)
        for m in get(s, "methods", Any[])
            wrapped = inline ? get(m, "vis", "") == "pub" :
                               get(m, "attribute", "none") == "julia"
            wrapped || continue
            _boundary_check_entry!(unsupported, checked, "$(struct_name)::$(m["name"])", m;
                                   returns_handle = get(m, "returns_boxed_struct", false))
        end
    end

    _print_boundary_report(io, label, unsupported, checked[])
    return (; unsupported, checked = checked[])
end

_boundary_module_path(entry) = String[String(m) for m in get(entry, "module_path", Any[])]

# The item as Rust names it: module-qualified below the crate root.
function _boundary_name(entry::AbstractDict)
    path = _boundary_module_path(entry)
    name = String(entry["name"])
    return isempty(path) ? name : join(path, "::") * "::" * name
end

function _boundary_check_entry!(out, checked, item::String, entry::AbstractDict;
                                returns_handle::Bool = false)
    callbacks = 0
    for a in get(entry, "args", Any[])
        rust_type = String(a["rust_type"])
        abi = String(get(a, "abi", ""))
        checked[] += 1
        reason = if abi == "callback"
            # Lowered through its own plan (#296), which is what wrapper
            # generation calls and what refuses a parameter or return it
            # cannot pass in one slot (#450 review) — and then through one of
            # `CALLBACK_SLOTS` trampoline slots, counted as generation counts.
            plan_error = _boundary_callback(a, item)
            if plan_error === nothing
                callbacks += 1
                callbacks <= CALLBACK_SLOTS ? nothing :
                    "`$(item)` takes more than $(CALLBACK_SLOTS) callback arguments " *
                    "(`$(a["name"])` is number $(callbacks)); at most $(CALLBACK_SLOTS) are supported (#296)."
            else
                plan_error
            end
        else
            _boundary_unknown(() -> ffi_argument_contract(rust_type; abi = abi), rust_type)
        end
        reason === nothing ||
            push!(out, _BoundaryFinding((item, "argument `$(a["name"])`", rust_type, abi, reason)))
    end

    returns_handle && return nothing
    kind = String(get(entry, "return_kind", "plain"))
    payloads = kind == "result" ? (("Ok payload", "ok_type", "ok_abi"), ("Err payload", "err_type", "err_abi")) :
               kind == "option" ? (("Some payload", "inner_type", "inner_abi"),) :
               (("return", "return_type", "return_abi"),)
    for (position, type_key, abi_key) in payloads
        rust_type = String(get(entry, type_key, ""))
        abi = String(get(entry, abi_key, ""))
        checked[] += 1
        reason = _boundary_unknown(() -> ffi_return_contract(rust_type; abi = abi), rust_type)
        reason === nothing || push!(out, _BoundaryFinding((item, position, rust_type, abi, reason)))
    end
    return nothing
end

# A readable field gets a generated getter, and its type is decided the way
# generation decides it (`field_is_accessible`, `_ffi_field_return`): an
# unsupported one fails when the struct's wrapper is generated (#450 review).
function _boundary_check_fields!(out, checked, info::RustStructInfo, struct_name::String)
    for (name, rust_type) in info.fields
        field_is_accessible(info, name) || continue
        checked[] += 1
        abi = get(info.field_abis, name, "")
        reason = _boundary_unknown(() -> _ffi_field_return(info, name, rust_type), rust_type)
        reason === nothing ||
            push!(out, _BoundaryFinding(("$(struct_name)::$(name)", "field getter", rust_type, abi, reason)))
    end
    return nothing
end

function _boundary_callback(arg::AbstractDict, item::AbstractString)
    args = String[String(t) for t in get(arg, "callback_args", Any[])]
    ret = String(get(arg, "callback_return", ""))
    try
        ffi_callback_plan(args, ret, "argument `$(arg["name"])` of `$(item)`")
    catch e
        e isa RustError || rethrow()
        return e.message
    end
    return nothing
end

# `nothing` when the contract describes the position, otherwise why it does not.
function _boundary_unknown(contract, rust_type::AbstractString)
    c = try
        contract()
    catch e
        e isa ArgumentError || rethrow()
        return sprint(showerror, e)
    end
    c.known && return nothing
    return "$(rust_type): not in the FFI contract"
end

function _print_boundary_report(io::IO, label, unsupported, checked::Int)
    if isempty(unsupported)
        println(io, "RustCall boundary report for $(label): no unsupported positions ",
                "($(checked) checked).")
        return nothing
    end
    println(io, "RustCall boundary report for $(label): $(length(unsupported)) unsupported ",
            "position(s) of $(checked) checked:")
    for u in unsupported
        println(io, "  ", u.item, ", ", u.position, ": ", u.rust_type, " — ", u.reason)
    end
    println(io, "Keep these types inside the Rust facade and expose supported types or an ",
            "opaque #[julia] struct instead; see the integration guide's limitation matrix.")
    return nothing
end
