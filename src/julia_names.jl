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
    rust_name(name::AbstractString) -> String

The Rust name of an item as one name, whatever its spelling: a raw identifier
without its `r#` (`r#type` → `type`), every other name as it is. `r#type` and
`type` are one Rust name, and a type spelling (`PyRef<'_, r#type>`), a symbol
(`rustcall_type_new`) or a Python attribute (`type`) carries it without the
prefix. The manifest keeps the item's own spelling — the extractor finds items
by it again (`specialize`) — so every Julia-side lookup, key or comparison of a
manifest name goes through this, and the Julia binding is derived from it by
`julia_binding_name` (#514).
"""
rust_name(name::AbstractString) =
    startswith(name, "r#") ? String(SubString(name, 3)) : String(name)

"""
    julia_binding_name(spelled::AbstractString) -> String

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
function julia_binding_name(spelled::AbstractString)
    name = rust_name(spelled)
    _is_plain_julia_identifier(name) && return name
    if _spells_julia_identifier(name)
        bound = name * "_"
        _is_plain_julia_identifier(bound) && return bound
    end
    error("the Rust name `$spelled` has no Julia spelling: `$name` is not a Julia " *
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
    JuliaDefinition(name, scope, owner, what)

One definition a generated module makes at its top level, as the emitter
makes it (#514): `name` is the Julia name, `scope` says what Julia keys the
definition by, `owner` is the Rust item it comes from and `what` names that
item in a message.

- `:binding` — a type or a submodule: a constant of the module;
- `:free` — a method with untyped positional arguments: a free function, a
  constructor (`S(args...)`), the bare form of a static method, a PyO3-host
  static method;
- `(:static, T)` — `name(::Type{T}, args...)`;
- `(:self, T)` — `name(self::T, args...)`: an instance method, a field accessor;
- `(:prop, T)` — a property of `T` (`getproperty` / `setproperty!` branch).

Two definitions of one `(name, scope)` from different owners replace one
another (or merge into one generic function), so the layout is refused. A
struct's constructors share the struct's owner: they are methods of the type.
"""
struct JuliaDefinition
    name::String
    scope::Any
    owner::String
    what::String
end

"""
    julia_definitions(functions, structs; modules = String[], accessors = false)
        -> Vector{JuliaDefinition}

What a `#[julia]` emitter — `rust\"\"\"` (`_inline_wrapper_exprs`) and both crate
emitters (`_crate_wrapper_exprs`, `emit_crate_module_code`) — defines at the top
level of one module for these items: free functions, struct types and their
constructors, static methods (the typed form, and the bare form unless
`_static_method_collisions` — the helper the emitters use — withholds it),
instance methods, properties, and with `accessors` the `get_<f>` / `set_<f>!`
helpers of the crate expression emitter; `modules` are the Rust segments of
the child modules. Every name is the one the emitter binds
(`julia_function_name`, `julia_method_name`, `julia_field_name`,
`julia_struct_name`, `_julia_module_name`).
"""
function julia_definitions(functions, structs; modules = String[], accessors::Bool = false)
    defs = JuliaDefinition[]
    add!(name, scope, owner, what = owner) = push!(defs, JuliaDefinition(name, scope, owner, what))
    colliding = _static_method_collisions(functions, structs)
    for f in functions
        _binds_julia_wrapper(f) || continue  # no binding, no name (#491)
        add!(julia_function_name(f), :free,
             "the function `$(qualified_name(f.module_path, f.name))`")
    end
    for s in structs
        _binds_julia_struct(s) || continue  # no type, no name (#503)
        T = julia_struct_name(s)
        owner = qualified_name(s.module_path, s.name)
        struct_owner = "the struct `$owner`"
        add!(T, :binding, struct_owner)
        for m in s.methods
            isempty(m.skip_reason) || continue
            what = "the method `$(_boundary_label(s, m))`"
            if m.is_constructor
                add!(T, :free, struct_owner, what)
            elseif m.is_static
                name = julia_method_name(m)
                add!(name, (:static, T), what)
                name in colliding || add!(name, :free, what)
            else
                add!(julia_method_name(m), (:self, T), what)
            end
        end
        for (field, _) in s.fields
            readable = field_is_accessible(s, field)
            writable = field_is_writable(s, field)
            (readable || writable) || continue
            jfield = julia_field_name(field)
            what = "the field `$owner.$field`"
            add!(jfield, (:prop, T), what)
            accessors || continue
            readable && add!("get_$jfield", (:self, T), what)
            writable && add!("set_$(jfield)!", (:self, T), what)
        end
    end
    for segment in modules
        add!(_julia_module_name(segment), :binding, "the module `$segment`")
    end
    return defs
end

"""
    _check_julia_definitions(defs, where_; types_first = true)

Refuse two definitions a generated module would make under one Julia name and
scope for different Rust items (`JuliaDefinition`): `fn r#for` beside
`fn for_`, `struct r#for` beside `struct for_`, a free function beside a
static method bound without its type, a method beside a field accessor of the
same name. The later definition would silently replace the earlier, or merge
into one generic function, so the layout is refused with both items named.
With `types_first = false` (an emitter that defines functions before types)
a type also refuses a function of its name that is not its own constructor.
"""
function _check_julia_definitions(defs, where_::AbstractString; types_first::Bool = true)
    refuse(prior, def) = error(
        "cannot lay out the bindings of $where_: $(prior.what) and $(def.what) would both " *
        "define `$(def.name)` in Julia. A Rust name Julia reserves is bound with a " *
        "trailing underscore (`r#for` as `for_`), so it cannot sit beside an item " *
        "already bound under that name. Rename one of them (#514).")
    seen = Dict{Tuple{String, Any}, JuliaDefinition}()
    for def in defs
        prior = get(seen, (def.name, def.scope), nothing)
        if prior === nothing
            seen[(def.name, def.scope)] = def
        elseif prior.owner != def.owner
            refuse(prior, def)
        end
    end
    types_first && return nothing
    for def in defs
        def.scope === :binding || continue
        other = get(seen, (def.name, :free), nothing)
        other === nothing || other.owner == def.owner || refuse(other, def)
    end
    return nothing
end

"""
    _check_julia_name_clashes(functions, structs, where_; modules, accessors)

`_check_julia_definitions` over `julia_definitions` of these items: what
`rust\"\"\"` (`src/ruststr.jl`) and the crate layout check
(`_check_module_names`) run before emitting anything. The PyO3 host runs the
same check over its own definitions (`_pyo3_host_definitions`).
"""
_check_julia_name_clashes(functions, structs, where_::AbstractString;
                          modules = String[], accessors::Bool = false) =
    _check_julia_definitions(julia_definitions(functions, structs; modules, accessors), where_)
