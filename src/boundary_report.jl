# The FFI surface report of #441: which argument and return positions of the
# wrappers RustCall generates the FFI contract cannot describe.
#
# Computed by the wrapper generators themselves (#454): `_boundary_report`
# runs the same emitters `rust"""..."""` and `@rust_crate` run — in the
# collecting mode of `src/ffi_contract.jl`, where every position a generator
# decides is recorded and a refusal is a finding instead of a `RustError` — and
# prints what they recorded. No rule about what is wrapped, what is examined
# or what is refused lives here; a rule added to a generator is in the report
# by construction.

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

The report is the wrapper generators' own account of the surface (#454): the
generators that `rust\"\"\"` and `@rust_crate` run are run here in a
collecting mode, so exactly the positions generation decides are examined —
the arguments and return of every `#[julia]` function and of every method the
mode wraps (every `pub` method inline, the `#[julia]` methods of a crate),
`Result` / `Option` payloads, and the getter of every readable field — and
every refusal generation would make is a finding. What generation does not
decide is not reported: a generic item is monomorphized later under types not
known yet, a plain `#[no_mangle] extern "C"` function is exported as written,
and a constructor, or any method returning the struct itself, returns a
handle.

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
    # The same conversion `@rust_str` and `scan_crate` apply, and then the
    # same emitters, in collecting mode (#454): the block's definitions for an
    # inline manifest, the module tree `emit_crate_module` splices for a
    # crate. Their output is discarded; what they recorded is the report.
    functions = manifest_function_signatures(manifest)
    structs = manifest_struct_infos(manifest)
    collector = _collect_boundary() do
        if get(manifest, "mode", "") == "inline"
            _inline_wrapper_exprs(functions, structs)
        else
            _crate_wrapper_exprs(_module_tree(functions, structs))
        end
    end
    unsupported = _BoundaryFinding[
        _BoundaryFinding((p.item, p.position, p.rust_type, p.abi, p.reason))
        for p in collector.positions if p.reason !== nothing]
    checked = length(collector.positions)
    _print_boundary_report(io, label, unsupported, checked)
    return (; unsupported, checked)
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
