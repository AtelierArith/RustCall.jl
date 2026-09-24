# The Julia name of a Rust item (#514).
#
# Rust and Julia reserve different words. A Rust function may be called
# `function`, `end` or `quote`, and a raw identifier (`r#for`, `r#let`) makes
# every Rust keyword available as a name — but in Julia those are reserved, so a
# binding spelled that way does not parse in a file `write_bindings_to_file`
# writes, and one defined from an expression cannot be called by name.
#
# `julia_binding_name` is the one place that turns a Rust name into the Julia
# name it is bound under. Every item kind reads it — free functions
# (`julia_function_name`), methods (`julia_method_name`), fields and their
# accessors (`julia_field_name`), struct types (`julia_struct_name`) and
# submodules (`_julia_module_name`) — in every emitter (inline `rust"""`, the
# crate expression emitter, the crate source-text emitter) and in the layout
# checks that refuse two items bound under one name. Exported Rust symbols are
# decided on the Rust side and never read these names.

"""
    _is_plain_julia_identifier(name::AbstractString) -> Bool

Whether Julia reads `name` on its own as a plain identifier. `Base.isidentifier`
accepts the reserved words (`for`, `end`, `function`, ...), so the name is also
parsed: exactly a usable identifier parses to a `Symbol` — a keyword parses to
an incomplete expression and `true` / `false` to a `Bool`. The set of reserved
words is therefore Julia's own, not a list kept here.
"""
_is_plain_julia_identifier(name::AbstractString) =
    Base.isidentifier(name) && Meta.parse(name; raise = false) isa Symbol

"""
    _spells_julia_identifier(name::AbstractString) -> Bool

Whether every character of `name` may appear in a Julia identifier at its
position — true for the reserved words as well, including `true` / `false`,
which `Base.isidentifier` rejects.
"""
function _spells_julia_identifier(name::AbstractString)
    isempty(name) && return false
    Base.is_id_start_char(first(name)) || return false
    return all(Base.is_id_char, name)
end

"""
    julia_binding_name(rust_name::AbstractString) -> String

The name a Rust item is bound under in Julia — the one decision, for every item
kind (#514):

- a raw identifier loses its prefix (`r#type` → `type`): `r#foo` and `foo` are
  one Rust name, and `#` would start a comment in a written module;
- a name Julia reserves (`Meta.parse` does not read it as a plain identifier:
  `for`, `end`, `function`, `quote`, `true`, ...) gets a trailing underscore
  (`r#for` → `for_`, `end` → `end_`), so the binding parses and can be called by
  name;
- every other name is kept as it is.

A name that is not a Julia identifier at all has no spelling and is refused.
The trailing underscore can meet a name the crate already binds (`r#for` beside
`for_`); the layout checks compare the names this function returns, so that
crate is refused with both items named rather than bound with one replacing
the other. The exported Rust symbols do not depend on this name.
"""
function julia_binding_name(rust_name::AbstractString)
    name = startswith(rust_name, "r#") ? String(SubString(rust_name, 3)) : String(rust_name)
    _is_plain_julia_identifier(name) && return name
    if _spells_julia_identifier(name)
        bound = name * "_"
        _is_plain_julia_identifier(bound) && return bound
    end
    error("the Rust name `$rust_name` has no Julia spelling: `$name` is not a Julia " *
          "identifier. Rename the item (#514).")
end

"""
    julia_function_name(f::RustFunctionSignature) -> String

The Julia name of a free function: `julia_binding_name` of its Rust name.
"""
julia_function_name(f::RustFunctionSignature) = julia_binding_name(f.name)

"""
    julia_method_name(m::RustMethod) -> String

The name a method is bound under in Julia: `julia_binding_name` of the
manifest's `julia_name` — a trait impl's method that shares its name with
another method of the struct, `Far_m` (#506) — or of the Rust name. The one
reader, for every emitter and the layout checks.
"""
julia_method_name(m::RustMethod) = julia_binding_name(isempty(m.julia_name) ? m.name : m.julia_name)

"""
    julia_field_name(field::AbstractString) -> String

The Julia property name of a struct field, and the stem of its accessors
(`get_<name>`, `set_<name>!`): `julia_binding_name` of the Rust field name. The
accessor *symbols* keep the Rust side's spelling (`field_getters`).
"""
julia_field_name(field::AbstractString) = julia_binding_name(field)

"""
    julia_struct_name(info::RustStructInfo) -> String

The Julia type name of a struct: `julia_binding_name` of its Rust name. The
exported symbols hang off `info.ffi_name`, which is not a Julia name.
"""
julia_struct_name(info::RustStructInfo) = julia_binding_name(info.name)

"""
    _check_julia_name_clashes(functions, structs, where_::AbstractString)

Refuse two items of one generated module that `julia_binding_name` binds under
one Julia name although Rust tells them apart (#514): a name Julia reserves
meeting the name it is renamed to — `fn r#for` beside `fn for_`, a method
`r#end` beside a method `end_` of the same struct, a field `r#let` beside a
field `let_`. The later definition would silently replace the earlier (or add
a method to it), so the layout is refused with both items named. Items are
compared within the scope Julia binds them in: free functions of the module,
methods of one struct, fields of one struct. Two entries for one Rust item
(`#[cfg]` variants) are one item. Struct types and submodules are checked
against every other name of the module by `_check_module_names`.
"""
function _check_julia_name_clashes(functions, structs, where_::AbstractString)
    function claim!(bound::Dict{String, String}, name::String, what::String)
        prior = get(bound, name, nothing)
        if prior !== nothing && prior != what
            error("cannot lay out the bindings of $where_: $prior and $what would both be " *
                  "bound in Julia as `$name`. A Rust name Julia reserves is bound with a " *
                  "trailing underscore (`r#for` as `for_`), so it cannot sit beside an item " *
                  "already called that. Rename one of them (#514).")
        end
        bound[name] = what
        return nothing
    end
    bound_functions = Dict{String, String}()
    for f in functions
        _binds_julia_wrapper(f) || continue  # no binding, no name (#491)
        claim!(bound_functions, julia_function_name(f),
               "the function `$(qualified_name(f.module_path, f.name))`")
    end
    for s in structs
        _binds_julia_struct(s) || continue  # no type, no name (#503)
        owner = qualified_name(s.module_path, s.name)
        bound_methods = Dict{String, String}()
        for m in s.methods
            (isempty(m.skip_reason) && !m.is_constructor) || continue
            claim!(bound_methods, julia_method_name(m), "the method `$(_boundary_label(s, m))`")
        end
        bound_fields = Dict{String, String}()
        for (field, _) in s.fields
            (field_is_accessible(s, field) || field_is_writable(s, field)) || continue
            claim!(bound_fields, julia_field_name(field), "the field `$owner.$field`")
        end
    end
    return nothing
end
