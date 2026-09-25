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
    julia_parameter_names(rust_names) -> Vector{String}

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
- a name in `reserved` gets underscores too: the emitters pass every other
  name the wrapper's own definition contains (`_rename_parameters`, #526), so
  `fn echo(pointer: &str)` is `echo(pointer_)` where the wrapper calls
  `pointer`, and `Int64: i64` is `Int64_` where it converts through `Int64`.

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
    result = Vector{String}(undef, length(names))
    taken = Set{String}()
    # Names kept as written first, so a renamed one yields to them.
    for (i, (n, w)) in enumerate(zip(names, wanted))
        if n == w && !(w in taken) && !(w in reserved)
            result[i] = w
            push!(taken, w)
        end
    end
    for (i, w) in enumerate(wanted)
        isassigned(result, i) && continue
        while w in taken || w in reserved
            w *= "_"
        end
        result[i] = w
        push!(taken, w)
    end
    return result
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
            if m.is_constructor
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

# ----------------------------------------------------------------------------
# Parameter names against the emitted wrapper itself (#526)
# ----------------------------------------------------------------------------
#
# A wrapper's body names things of its own without qualification — the
# generated module's helpers, Base functions, the types it converts through
# (`Int64(x)`), its type variables, the PyO3 host's receiver `obj` — and a
# parameter spelled like one of them shadows it. No list of those names can be
# complete (PR #527 review), so the names are read off the wrapper: every
# emitter's items are first emitted with a unique placeholder for each
# parameter, every other symbol of each definition taking one is collected,
# and the parameter is named against that set.
#
# A placeholder is a name no Rust identifier can spell, so no item or
# parameter of a crate is ever taken for one (PR #527 review): it carries a
# prime (`′`, U+2032), which Julia admits in an identifier — the source-text
# emitter writes names as they are, and `Meta.parse` reads the text back to
# the same `Symbol` — and which is no `XID_Continue` character, so it occurs in
# no Rust identifier. The placeholders are recognised by identity against the
# set the probe made, never by their spelling.
_parameter_placeholder(k::Integer) = string("rustcall′arg′", k)

# The names an emitter binds itself inside a definition it generates — a
# receiver, a pointer, a panic channel, a string temporary — are in the same
# namespace (PR #527 review): `rustcall′<name>`. A crate's items and a
# wrapper's parameters are Rust identifiers and cannot spell one, so no local
# of a wrapper ever shadows a crate item the wrapper reads, and no parameter
# meets a local, by construction rather than by allocation. The source-text
# emitter writes them as they are; `Meta.parse` reads them back unchanged.
const _EMITTER_LOCAL_PREFIX = "rustcall′"
_emitter_local(name) = Symbol(_EMITTER_LOCAL_PREFIX, name)

# A copy of a function / method record with other parameter names, or of a
# struct record with other methods; every other field as it is.
_with_field(item, field::Symbol, value) =
    typeof(item)((f === field ? value : getfield(item, f) for f in fieldnames(typeof(item)))...)

"""
    _rename_parameters(functions, structs, emit) -> (functions, structs)

The items with each parameter named so that no definition an emitter makes
from them reads a name its parameter would shadow (#526). `emit(functions,
structs)` runs the emitter over the items and returns what it defines — an
`Expr`, or the source text of the source-text emitter, which is parsed.

It is run once on placeholder parameters (`rustcall′arg′<k>`, a name no Rust
identifier spells), without
logging and without recording anything for a boundary report (a throwaway
collector, so a refusal is recorded rather than raised); for every definition
that takes a placeholder, each other symbol it contains — what it reads, calls
or binds, its other parameters, its type variables — is reserved for that
item. Each item's names are then `julia_parameter_names` of its own against
its reserved set. An emitter that raises on the placeholders leaves the items
as they are: it raises again on the real ones.
"""
function _rename_parameters(functions::AbstractVector, structs::AbstractVector, emit)
    owner = Dict{Symbol, Any}()
    counter = Ref(0)
    function placeholder!(key)
        counter[] += 1
        p = _parameter_placeholder(counter[])
        owner[Symbol(p)] = key
        return p
    end
    placeholders!(key, n) = String[placeholder!(key) for _ in 1:n]
    probe_functions = [_with_field(f, :arg_names, placeholders!((:f, i), length(f.arg_names)))
                       for (i, f) in enumerate(functions)]
    probe_structs = [_with_field(s, :methods,
                                 [_with_field(m, :arg_names,
                                              placeholders!((:m, i, j), length(m.arg_names)))
                                  for (j, m) in enumerate(s.methods)])
                     for (i, s) in enumerate(structs)]
    probe = _probe_emission(() -> emit(probe_functions, probe_structs))
    probe === nothing && return functions, structs
    probe isa AbstractString && (probe = Meta.parseall(probe))
    reserved = Dict{Any, Set{String}}()
    _parameter_scopes!(reserved, probe, owner)
    named(item, key) = haskey(reserved, key) ?
        _with_field(item, :arg_names, julia_parameter_names(item.arg_names; reserved = reserved[key])) :
        item
    renamed_functions = [named(f, (:f, i)) for (i, f) in enumerate(functions)]
    renamed_structs = [_with_field(s, :methods,
                                   [named(m, (:m, i, j)) for (j, m) in enumerate(s.methods)])
                       for (i, s) in enumerate(structs)]
    return renamed_functions, renamed_structs
end

# Run an emitter for its output only: nothing logged, nothing recorded for a
# boundary report being collected on this task, `nothing` when it raises.
function _probe_emission(f)
    tls = task_local_storage()
    saved = get(tls, _BOUNDARY_COLLECTOR_KEY, nothing)
    tls[_BOUNDARY_COLLECTOR_KEY] = BoundaryCollector()
    try
        return Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
    catch err
        err isa InterruptException && rethrow()
        return nothing
    finally
        saved === nothing ? delete!(tls, _BOUNDARY_COLLECTOR_KEY) :
                            (tls[_BOUNDARY_COLLECTOR_KEY] = saved)
    end
end

# Every symbol of an expression, quoted ones included.
function _expr_symbols!(out::Set{Symbol}, x)
    if x isa Symbol
        push!(out, x)
    elseif x isa QuoteNode
        _expr_symbols!(out, x.value)
    elseif x isa Expr
        foreach(a -> _expr_symbols!(out, a), x.args)
    end
    return out
end

# Whether `x` defines a function: `function f(...)`, `f(...) = ...`, with any
# `where` / return annotation.
function _is_function_definition(x)
    x isa Expr && x.head in (:function, :(=)) && length(x.args) == 2 || return false
    sig = x.args[1]
    while sig isa Expr && sig.head in (:where, :(::))
        sig = sig.args[1]
    end
    return sig isa Expr && sig.head === :call
end

function _parameter_scopes!(reserved::AbstractDict, x, owner::AbstractDict)
    x isa Expr || return reserved
    if _is_function_definition(x)
        symbols = _expr_symbols!(Set{Symbol}(), x)
        keys_here = Set{Any}()
        others = Set{String}()
        for name in symbols
            # A placeholder the probe made is its item's parameter; every
            # other symbol — a local derived from one included, which no real
            # name can equal — is a name the definition uses.
            key = get(owner, name, nothing)
            key === nothing ? push!(others, String(name)) : push!(keys_here, key)
        end
        for key in keys_here
            union!(get!(reserved, key, Set{String}()), others)
        end
    end
    foreach(a -> _parameter_scopes!(reserved, a, owner), x.args)
    return reserved
end
