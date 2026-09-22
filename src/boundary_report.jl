# The FFI surface report of #441: which argument and return positions of the
# wrappers RustCall generates the FFI contract cannot describe.

# Attributes whose items RustCall wraps (`Attribute::generates_wrapper` in
# `rustcall_core`, minus the PyO3 origins, which `scan_report` covers).
const _BOUNDARY_ATTRIBUTES = ("julia", "derive_julia_struct")

"""
    boundary_report(crate_path; io = stdout) -> NamedTuple
    inline_boundary_report(code; io = stdout) -> NamedTuple

Check the FFI surface RustCall would generate for a crate (`@rust_crate`) or for
an inline `rust\"\"\"...\"\"\"` block, **without building or loading anything**,
and list every argument or return position the FFI contract (the manual's
"The FFI Type Contract" page) cannot describe (#441).

An unsupported *return* type already fails when the wrapper is generated. An
unsupported *argument* type — a `Vec<f64>`, a `&OtherStruct`, a slice —
compiles, and fails only when it is called, with a message about the layout of
the Julia value rather than about the Rust signature. This report names the
Rust item and position instead, before anything is built.

Only positions RustCall generates a wrapper for are examined: `#[julia]`
functions, and the methods of non-generic `#[julia]` structs that the mode
wraps (every `pub` method inline, only `#[julia]` methods in a crate). A
generic item is monomorphized later under types not known yet, and a plain
`#[no_mangle] extern "C"` function is exported as written, so neither is
checked. A constructor, or any method returning the struct itself, returns a
handle and is always describable.

Prints a summary to `io` and returns `(; unsupported, checked)`:

* `unsupported` — one `(; item, position, rust_type, abi, reason)` per position,
  where `item` is `"f"` or `"Struct::method"` and `position` is
  ``"argument `x`"``, `"return"`, `"Ok payload"`, `"Err payload"` or
  `"Some payload"`;
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
    # The lenient scan, as `scan_crate` does by default: no Cargo runs, so a
    # `#[cfg]`-carrying item is reported rather than decided.
    _, _, manifest = _crate_manifest(crate_path; allow_cargo = false)
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
        _boundary_check_entry!(unsupported, checked, String(f["name"]), f)
    end

    for s in get(manifest, "structs", Any[])
        get(s, "attribute", "none") in _BOUNDARY_ATTRIBUTES || continue
        isempty(get(s, "type_params", Any[])) || continue
        for m in get(s, "methods", Any[])
            wrapped = inline ? get(m, "vis", "") == "pub" :
                               get(m, "attribute", "none") == "julia"
            wrapped || continue
            _boundary_check_entry!(unsupported, checked, "$(s["name"])::$(m["name"])", m;
                                   returns_handle = get(m, "returns_boxed_struct", false))
        end
    end

    _print_boundary_report(io, label, unsupported, checked[])
    return (; unsupported, checked = checked[])
end

function _boundary_check_entry!(out, checked, item::String, entry::AbstractDict;
                                returns_handle::Bool = false)
    for a in get(entry, "args", Any[])
        rust_type = String(a["rust_type"])
        abi = String(get(a, "abi", ""))
        checked[] += 1
        # A callback is lowered through its own plan (#296), not the table.
        abi == "callback" && continue
        reason = _boundary_unknown(() -> ffi_argument_contract(rust_type; abi = abi), rust_type)
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
