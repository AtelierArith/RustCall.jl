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
# decided on the Rust side and never read these names. A generated wrapper's
# parameters are named from it too, through `julia_parameter_names` (#516).

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
    julia_parameter_names(rust_names; reserved = ()) -> Vector{String}

The Julia parameter names of a function's or method's arguments, in order — the
one decision for every emitter (#516). The `RustFunctionSignature` and
`RustMethod` constructors apply it, so `arg_names` is already this list
wherever a wrapper is generated: inline `rust\"\"\"`, the crate expression and
source-text emitters, and the PyO3 host.

- an argument is named by `julia_binding_name` (`r#for` → `for_`, `end` →
  `end_`), so a written bindings file parses;
- an argument with no readable Julia name — a pattern (`(a, b): (i32, i32)`),
  `_`, or a spelling that is no Julia identifier — is named `arg<i>` after its
  position;
- a name another parameter already has gets further underscores (`end` beside
  `end_` is `end__`). Names that need no change are claimed first, so they are
  never the ones renamed;
- a name a wrapper uses itself is never a parameter (#526) and gets
  underscores instead: one of `_JULIA_EMITTER_NAMES` (`pointer` → `pointer_`,
  `obj` → `obj_`, `Int32` → `Int32_`), a `CResult_` / `COption_` aggregate
  (`_reserved_aggregate_name`), and one of `reserved` — every name the item's
  own crate or block defines, which only its caller knows
  (`manifest_function_signatures` / `manifest_struct_infos` pass
  `_manifest_reserved_names`, the one-namespace definitions; PR #527 review: a
  struct `foo` is read by its wrappers, so a parameter `foo` is `foo_`, while a
  parameter `Foo` is kept).

Every result is a plain, readable identifier and distinct from the others, and
applying the function to its own result changes nothing. The locals a wrapper
introduces are chosen against this list (`_generated_local`).
"""
function julia_parameter_names(rust_names; reserved = ())
    names = String[String(n) for n in rust_names]
    readable(n) = _is_plain_julia_identifier(n) && !all(==('_'), n)
    wanted = map(enumerate(names)) do (i, n)
        bound = try
            julia_binding_name(n)
        catch err
            err isa ErrorException || rethrow()
            ""
        end
        readable(bound) ? bound : "arg$(i)"
    end
    unusable(w) = w in _JULIA_EMITTER_NAMES || _reserved_aggregate_name(w) || w in reserved
    result = Vector{String}(undef, length(names))
    taken = Set{String}()
    # Names kept as written first, so a renamed one yields to them.
    for (i, (n, w)) in enumerate(zip(names, wanted))
        if n == w && !(w in taken) && !unusable(w)
            result[i] = w
            push!(taken, w)
        end
    end
    for (i, w) in enumerate(wanted)
        isassigned(result, i) && continue
        # Off a reserved prefix first (`CResult_f` → `arg_CResult_f`): an
        # underscore alone would never leave it.
        _reserved_aggregate_name(w) && (w = "arg_" * w)
        while w in taken || unusable(w)
            w *= "_"
        end
        result[i] = w
        push!(taken, w)
    end
    return result
end

"""
    _reserved_aggregate_name(name) -> Bool

Whether `name` is spelled like a `CResult_<stem>` / `COption_<stem>` aggregate,
the Julia types a `Result` / `Option` wrapper reads its payload through: the
extractor names them per item, so the prefix is reserved rather than each name.
"""
_reserved_aggregate_name(name::AbstractString) =
    startswith(name, "CResult_") || startswith(name, "COption_")

"""
    _JULIA_EMITTER_NAMES

The names a generated wrapper uses without qualification and a parameter must
therefore never take (#526): the helpers of a generated `@rust_crate` module
(`_call_target`, `_guard_panic`, ...), the Base functions and constants the
wrappers call (`pointer`, `sizeof`, `getfield`, `nothing`, ...), the PyO3
host's receiver `obj` and its module import `_pyo3_module`, and the types the
wrappers name (`Int32`, `Ptr`, `RustResult`, ...). The item's own types are
reserved by the caller that knows them (`julia_parameter_names`'s `reserved`),
and a local a wrapper introduces is renamed instead (`_generated_local`). `test/test_parameter_names.jl`
derives the set from what every emitter emits and fails, naming it, when an
emitter reads a name that is not here.
"""
const _JULIA_EMITTER_NAMES = (
    # The PyO3 host (`src/pyo3_host.jl`): the receiver of an instance method,
    # the module's lazy import and array conversion.
    "obj", "_pyo3_module", "_pyo3_asarray",
    # The generated `@rust_crate` module's helpers (both crate emitters).
    "_call_target", "_ctor_target", "_check_not_freed", "_guard_panic",
    "_result_payload", "call_rust_function",
    # ... and the module-level ones it defines for itself.
    "__init__", "_get_func_ptr", "_symbol", "_required_symbol", "_struct_generation",
    "_vec_target", "_live_handle",
    "_call_rust_owned_string_ptr", "_call_rust_borrowed_string_ptr",
    # Base.
    "getfield", "pointer", "sizeof", "isa", "rethrow", "sprint", "showerror",
    "nothing",
    # The modules and types the wrappers name.
    "RustCall", "PythonCall", "RustResult", "RustOption", "String", "Ptr", "Cvoid",
    "Csize_t", "C_NULL", "Bool", "Int32", "UInt", "Float64",
)

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
    JuliaDefinition(name, scope, owner, what, parent)

One definition a generated module makes, as the emitter makes it (#514).
`name` is the Julia name, `scope` says what Julia keys the definition by,
`owner` is the Rust item it comes from, `what` names that item in a message,
and `parent` is the Julia type a method, constructor or accessor belongs to
(`""` for anything else).

- `:binding` — a type or a submodule: a constant of the module;
- `:free` — a method with untyped positional arguments: a free function, a
  constructor (`S(args...)`), the bare form of a static method, a PyO3-host
  static method;
- `(:static, T)` — `name(::Type{T}, args...)`;
- `(:self, T)` — `name(self::T, args...)`: an instance method, a field accessor;
- `(:prop, T)` — a property of `T` (a `getproperty` / `setproperty!` branch),
  which lives on the type, not in the module;
- `:registry` — a key of the `@rust` name table of a `rust\"\"\"` block (the
  exported functions, hand-written exports included, and the generics).

Every other scope is a method of the module-level generic function `name`, so
all of them share the module's one namespace with the types and submodules.
"""
struct JuliaDefinition
    name::String
    scope::Any
    owner::String
    what::String
    parent::String
end

"""
    julia_definitions(functions, structs; modules = String[], accessors = false)
        -> Vector{JuliaDefinition}

What a `#[julia]` emitter defines in one module for these items. The emitters are
`rust\"\"\"` (`_inline_wrapper_exprs`) and both crate emitters
(`_crate_wrapper_exprs`, `emit_crate_module_code`).

The definitions are: free functions, struct types and their constructors,
static methods (the typed form, and the bare form unless
`_static_method_collisions` withholds it — the helper the emitters use),
instance methods and properties. With `accessors`, also the `get_<f>` /
`set_<f>!` helpers of the crate expression emitter. `modules` are the Rust
segments of the child modules.

Every name is the one the emitter binds (`julia_function_name`,
`julia_method_name`, `julia_field_name`, `julia_struct_name`,
`_julia_module_name`).
"""
function julia_definitions(functions, structs; modules = String[], accessors::Bool = false,
                           registry = nothing)
    defs = JuliaDefinition[]
    add!(name, scope, owner; what = owner, parent = "") =
        push!(defs, JuliaDefinition(name, scope, owner, what, parent))
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
            # A constructor is a static method returning the struct; one with a
            # receiver is bound under its own name, as every emitter binds it
            # (`method.is_static && method.is_constructor`, PR #527 review).
            if m.is_constructor && m.is_static
                add!(T, :free, struct_owner; what, parent = T)
            elseif m.is_static
                name = julia_method_name(m)
                add!(name, (:static, T), what; parent = T)
                name in colliding || add!(name, :free, what; parent = T)
            else
                add!(julia_method_name(m), (:self, T), what; parent = T)
            end
        end
        for (field, _) in s.fields
            readable = field_is_accessible(s, field)
            writable = field_is_writable(s, field)
            (readable || writable) || continue
            jfield = julia_field_name(field)
            what = "the field `$owner.$field`"
            add!(jfield, (:prop, T), what; parent = T)
            accessors || continue
            readable && add!("get_$jfield", (:self, T), what; parent = T)
            writable && add!("set_$(jfield)!", (:self, T), what; parent = T)
        end
    end
    for segment in modules
        add!(_julia_module_name(segment), :binding, "the module `$segment`")
    end
    # The `@rust` registry of a `rust\"\"\"` block (`_registry_signatures`): every
    # exported function — hand-written `#[no_mangle] extern "C"` exports
    # included — and every generic, keyed by the name `@rust` is called with
    # (`_manifest_registry_entries`, `register_generic_function`). Two
    # entries under one key would replace one another in the table.
    if registry !== nothing
        for f in registry
            (f.exported || f.is_generic) || continue
            _rust_refuses(f.skip_reason) && continue
            add!(julia_function_name(f), :registry,
                 "the function `$(qualified_name(f.module_path, f.name))`")
        end
    end
    return defs
end

"""
    _check_julia_definitions(defs, where_)

Refuse a module whose definitions (`JuliaDefinition`) would replace one another.
A module has one namespace: every type, submodule and module-level generic
function shares it, and a method of any struct is a method of the module's
function of that name. Two rules decide it. Both read only the definitions,
never a list of item kinds.

1. **One key, one owner.** Two definitions with the same name and scope, made
   by different Rust items, are one method defined twice. The later one
   replaces the earlier. This covers:
   - `fn r#for` beside `fn for_`;
   - `struct r#for` beside `struct for_`;
   - a method `get_x` beside the accessor of a field `x`;
   - a free function beside a PyO3-host static method bound without its type.

   Different scopes are ordinary overloading. Instance methods of two structs,
   or a free function beside an instance method, add methods to one generic
   function.
2. **A type or module name is taken whole.** A name bound to a type or a
   submodule may be used by no function, except the type's own constructors
   and methods (`parent`), which add methods to the type after it is defined.
   So `struct A` with a method bound as `for_` beside `struct for_` is refused,
   and so is a free function named like a struct. Otherwise the emitter would
   define a function where the type goes, and the type definition would fail
   as a constant redefinition.
"""
function _check_julia_definitions(defs, where_::AbstractString)
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
    bindings = Dict(def.name => def for def in defs if def.scope === :binding)
    for def in defs
        # A property lives on its type and a registry key in `@rust`'s table,
        # neither in the module's namespace.
        (def.scope === :binding || def.scope === :registry ||
         (def.scope isa Tuple && first(def.scope) === :prop)) && continue
        binding = get(bindings, def.name, nothing)
        binding === nothing || def.parent == def.name || refuse(binding, def)
    end
    return nothing
end

"""
    _check_julia_name_clashes(functions, structs, where_; modules, accessors)

`_check_julia_definitions` over `julia_definitions` of these items. `rust\"\"\"`
(`src/ruststr.jl`) and the crate layout check (`_check_module_names`) run it
before emitting anything, and the PyO3 host runs the same check over its own
definitions (`_pyo3_host_definitions`).
"""
_check_julia_name_clashes(functions, structs, where_::AbstractString;
                          modules = String[], accessors::Bool = false, registry = nothing) =
    _check_julia_definitions(julia_definitions(functions, structs; modules, accessors, registry),
                             where_)
