# ============================================================================
# One Julia submodule per Rust module (#300)
# ============================================================================

"""
    ModuleNode

One module of a crate's binding layout: the items whose `module_path` is
`path`, and the modules below it. The root has an empty `path`.

The generated Julia module mirrors the Rust module tree: an item at the crate
root is bound where it always was, an item in `mod a` is bound in a submodule
`a` (`bindings.a.run()`, `bindings.a.C`), so two `run`s or two `struct C` in
different modules — which the symbol scheme keeps apart in the library — are
kept apart in Julia as well. A module that only contains other modules is
still emitted, so the path in Julia is the path in Rust.
"""
struct ModuleNode
    path::Vector{String}
    functions::Vector{RustFunctionSignature}
    structs::Vector{RustStructInfo}
    children::Vector{ModuleNode}
end

ModuleNode(path::Vector{String}) =
    ModuleNode(path, RustFunctionSignature[], RustStructInfo[], ModuleNode[])

"""
    _module_tree(info::CrateInfo) -> ModuleNode
    _module_tree(functions, structs) -> ModuleNode

Arrange a crate's items by `module_path`. Children are sorted by name, so the
layout — and a file written by `write_bindings_to_file` — is deterministic
whatever order the manifest listed the items in.
"""
_module_tree(info::CrateInfo) = _module_tree(info.julia_functions, info.julia_structs)

function _module_tree(functions, structs)
    root = ModuleNode(String[])
    node_at(path) = begin
        node = root
        for (depth, segment) in enumerate(path)
            i = findfirst(c -> last(c.path) == segment, node.children)
            if i === nothing
                push!(node.children, ModuleNode(path[1:depth]))
                sort!(node.children; by = c -> last(c.path))
                i = findfirst(c -> last(c.path) == segment, node.children)
            end
            node = node.children[i]
        end
        node
    end
    for f in functions
        push!(node_at(f.module_path).functions, f)
    end
    for s in structs
        push!(node_at(s.module_path).structs, s)
    end
    return root
end

"""
    _julia_module_name(segment::AbstractString) -> String

The Julia name of a Rust module segment: `julia_binding_name`, the rule every
item kind follows (#514). A raw identifier (`r#type`) loses its prefix — `#`
would start a comment in the written file — and a Julia keyword gets a
trailing underscore (`mod r#do` → `do_`, `mod end` → `end_`), so the
submodule parses and can be reached by name. The layout checks compare these
names, so `mod r#do` beside `mod do_` is refused.
"""
_julia_module_name(segment::AbstractString) = julia_binding_name(segment)

"""
    _check_module_names(tree::ModuleNode)

Refuse a layout Julia cannot define. Rust keeps values, types and modules in
separate namespaces, so a crate may have both `#[julia] fn a()` and `#[julia]
mod a { ... }`; Julia has one namespace per module, and the generated parent
would define function `a` and then module `a` — a constant-redefinition error
that takes the whole bindings module down (#300 review). Every child module
name is therefore checked against everything its parent binds: free functions,
struct types, every method name (static or instance — both become functions of
the parent), field accessors (`get_<f>`, `set_<f>!`), the helpers every
generated module defines (`_call_target`, `_LIB_GEN`, ...) and the `eval` /
`include` Julia defines in every module (`_JULIA_MODULE_OWN_NAMES`). Within one
node a struct's type name must not repeat a function-like binding either
(`fn C` + `struct C`).

Nothing else is reserved: the generated code reaches Base, Core and RustCall
through `GlobalRef`s or `rustcall′` aliases no Rust name can spell (#528), so an
item named `Base`, `RustCall`, `String` or `getfield` shadows nothing it uses.
Module segments must also spell a Julia identifier (`_julia_module_name`). The
error names both sides and the fix.
"""
function _check_module_names(tree::ModuleNode)
    where_ = isempty(tree.path) ? "the crate root" : "module `$(join(tree.path, "::"))`"
    # Every function-like binding of this node: what a struct's type name and a
    # child module's name must not repeat.
    taken = Dict{String, String}()
    for name in _CRATE_MODULE_HELPERS
        taken[String(name)] = "a helper every generated module defines"
    end
    for name in _CRATE_MODULE_ROOT_CONSTANTS
        taken[String(name)] = "a constant every generated module defines"
    end
    for name in _JULIA_MODULE_OWN_NAMES
        taken[String(name)] = "Julia's own `$name` of every module"
    end
    # A function-like binding may not take a name the module itself defines —
    # the build record, the library path, a snapshot helper: the wrapper would
    # redefine a `const` or add a method to RustCall's own helper (#463) — nor
    # the `eval` / `include` Julia gives every module, which it would replace.
    reserved = Set{String}(String.((_CRATE_MODULE_HELPERS..., _CRATE_MODULE_ROOT_CONSTANTS...,
                                    _JULIA_MODULE_OWN_NAMES...)))
    refuse_reserved(name, what) = name in reserved && error(
        "cannot lay out the bindings of $where_: $what binds `$name`, which every " *
        "generated module defines itself (#463). Rename it.")
    # Two items of this node the emitters would define under one Julia name
    # and scope — a Rust name Julia reserves meeting the name it is renamed
    # to, a method meeting a field accessor, two submodules (#514). The
    # expression emitter's `get_<f>` / `set_<f>!` helpers are counted.
    _check_julia_name_clashes(tree.functions, tree.structs, where_;
                              modules = [last(child.path) for child in tree.children],
                              accessors = true)
    for f in tree.functions
        _binds_julia_wrapper(f) || continue  # no binding, no name (#491)
        name = julia_function_name(f)
        refuse_reserved(name, "the function `$(qualified_name(f.module_path, f.name))`")
        get!(taken, name, "the function `$(qualified_name(f.module_path, f.name))`")
    end
    for s in tree.structs
        _binds_julia_struct(s) || continue  # no type, no name (#503)
        owner = qualified_name(s.module_path, s.name)
        for m in s.methods
            (isempty(m.skip_reason) && !m.is_constructor) || continue
            refuse_reserved(julia_method_name(m), "the method `$owner::$(m.name)`")
        end
    end
    # A method or an accessor is emitted *after* its struct, so it only clashes
    # with a type name a **later** struct of this node defines: `function C(...)`
    # before `mutable struct C` is a constant redefinition, the other order is
    # an outer constructor. A method that repeats its own struct's name is
    # therefore fine, and so is one that repeats a free function's — that adds a
    # method to it (#341 review).
    struct_position = Dict{String, Int}()
    for (i, s) in enumerate(tree.structs)
        get!(struct_position, julia_struct_name(s), i)
    end
    later_struct(name, i) = get(struct_position, name, typemax(Int)) > i
    for (i, s) in enumerate(tree.structs)
        _binds_julia_struct(s) || continue  # no type, no name (#503)
        owner = qualified_name(s.module_path, s.name)
        for m in s.methods
            (isempty(m.skip_reason) && !m.is_constructor) || continue
            later_struct(julia_method_name(m), i) || continue
            get!(taken, julia_method_name(m), "the method `$owner::$(m.name)`")
        end
        for (field, _) in s.fields
            jfield = julia_field_name(field)
            if field_is_accessible(s, field) && later_struct("get_$jfield", i)
                get!(taken, "get_$jfield", "the accessor of `$owner.$field`")
            end
            if field_is_writable(s, field) && later_struct("set_$(jfield)!", i)
                get!(taken, "set_$(jfield)!", "the accessor of `$owner.$field`")
            end
        end
    end
    # A struct is a Julia type *and* its constructor: Rust keeps `fn C` and
    # `struct C` in separate namespaces, Julia does not, so `function C` followed
    # by `mutable struct C` is a constant redefinition (#300 review). Two
    # methods of one name on different structs are fine — that is dispatch.
    for s in tree.structs
        _binds_julia_struct(s) || continue  # no type, no name (#503)
        owner = qualified_name(s.module_path, s.name)
        name = julia_struct_name(s)
        if haskey(taken, name)
            error("cannot lay out the bindings of $where_: the struct `$owner` and " *
                  "$(taken[name]) both bind `$name`, and Julia keeps functions and types " *
                  "in one namespace. Rename one of them (#300).")
        end
        taken[name] = "the struct `$owner`"
    end
    for child in tree.children
        name = _julia_module_name(last(child.path))
        if haskey(taken, name)
            error("cannot lay out the bindings of module `$(join(child.path, "::"))`: " *
                  "$where_ already binds `$name` as $(taken[name]), and Julia keeps " *
                  "functions, types and modules in one namespace, so the submodule " *
                  "`$name` would redefine it. Rename the module or the item (#300).")
        end
        # A sibling module of the same Julia name: `mod r#for` beside `mod for_` (#514).
        taken[name] = "the module `$(join(child.path, "::"))`"
        _check_module_names(child)
    end
    return nothing
end

"""
    _CRATE_MODULE_HELPERS

The names a generated crate module defines once, at its root, and every
submodule imports from its parent: the library record and the snapshot
constructors (`_call_target`, `_vec_target`, `_ctor_target`, `_struct_generation`), the
symbol cache and the panic guard. One definition per module tree, so a reload
swaps the image for every submodule at once.
"""
const _CRATE_MODULE_HELPERS = (:_LIB_NAME, :_LIB_GEN, :_symbol, :_required_symbol,
                               :_live_handle, :_get_func_ptr, :_call_target, :_vec_target, :_ctor_target,
                               :_struct_generation, :_guard_panic,
                               :_CALL_TARGET, :_STRING_TARGET, :_VEC_TARGET, :_CTOR_TARGET,
                               :_FREE_TARGET)

"""
    _CRATE_MODULE_ROOT_CONSTANTS

The other names a generated crate module binds at its root — the library path,
the build record, the preload list, the pin flag, the crate's tracked inputs,
the symbol cache and `__init__` — which a Rust item or module may not take.
`test/test_hot_reload_record.jl` collects every root binding either emitter
actually defines and asserts it is reserved here or in `_CRATE_MODULE_HELPERS`,
so a constant added to an emitter without reserving its name fails (#463).
"""
const _CRATE_MODULE_ROOT_CONSTANTS = (:_BINDINGS_FORMAT, :_LIB_PATH, :_BUILD_RECORD,
                                      :_PRELOAD_LIBRARIES, :_PIN_LIBRARY, :_CRATE_INPUTS,
                                      :_SYMBOLS, :__init__)

"""
    _target_cache_name(kind, symbol) -> Symbol

The name of the `const` a generated call site keeps its snapshot in (#253).

# Why a name at all

`@rust` and the `#[julia]` wrappers splice their `CallTargetCache` straight into
the expansion, where it needs no name and cannot collide. A `@rust_crate` module
has no such option: `write_bindings_to_file` emits the same module as **source
text**, and a live object has no source spelling. Each call site therefore
declares its cache next to the wrapper that uses it, in both emitters.

# Why `(kind, symbol)` is unique

`kind` names the *emitter*, not the tuple shape: `:fn` a free function, `:m` a
method wrapper, `:free` a struct's destructor, `:acc` a `get_x` / `set_x!`
helper, `:prop` a `getproperty` / `setproperty!` branch. Each of those emits a
given FFI symbol at most once per module — a field's getter appears in the
accessor *and* in `getproperty`, which is exactly why those two are different
kinds rather than one — so no two call sites ever ask for the same name, and
`const` is never declared twice.

# Why the name cannot be a user's

A generated module also binds whatever the crate exports: a function `foo`
becomes Julia's `foo`. A cache spelled `_TC_fn_rustcall_foo` would therefore
collide with a crate that exports a Rust function of exactly that name — legal
Rust, and the module would then either redefine a `const` or define methods on a
`CrateTargetCache`, taking the whole bindings module down (#253 review).

`#` is what makes that impossible rather than merely unlikely: it cannot appear
in a Rust identifier, and so cannot appear in a name the crate contributes.
Julia is happy to bind it — `var"#TC#fn#rustcall_foo"` — which is also how
`Base.show` spells the symbol, so both emitters write the same characters.
"""
_target_cache_name(kind::Symbol, symbol::AbstractString) = Symbol("#TC#", kind, "#", symbol)

"""
    _target_cache_ref(kind, symbol) -> String

How `_target_cache_name(kind, symbol)` is *spelled* in Julia source:
`var"#TC#fn#rustcall_add"`. The AST emitter splices the `Symbol` and never needs
this; the file emitter writes text and does.

It is the same spelling `Base.show` gives that symbol, so the two emitters'
output stays comparable character for character — which is what
`test/test_crate_bindings.jl` checks them with.
"""
_target_cache_ref(kind::Symbol, symbol::AbstractString) =
    "var\"$(_target_cache_name(kind, symbol))\""

# `const <name> = RustCall.CrateTargetCache()`, for the expression emitter and
# for the source-text one. Two spellings of one declaration, next to each other
# so they cannot drift.
_target_cache_const(kind::Symbol, symbol::AbstractString) =
    Expr(:const, Expr(:(=), _target_cache_name(kind, symbol), @_emitted(:(RustCall.CrateTargetCache()))))

_target_cache_source(kind::Symbol, symbol::AbstractString) =
    "const $(_target_cache_ref(kind, symbol)) = rustcall′RustCall.CrateTargetCache()"

# `import ..name, ..name2, ...` — every helper from the enclosing module. A
# submodule two levels down imports from *its* parent, which imported them
# itself, so the chain needs no knowledge of its depth.
_parent_helper_imports_expr() =
    Expr(:import, (Expr(:., :., :., name) for name in _CRATE_MODULE_HELPERS)...)

_parent_helper_imports_source() =
    "import " * join(("..$(name)" for name in _CRATE_MODULE_HELPERS), ", ")

"""
    _rename_crate_tree(tree; strict) -> ModuleNode

`tree` with every parameter named against what **both** crate emitters make of
its module's items — the expressions `@rust_crate` evaluates and the source
text `write_bindings_to_file` writes, parsed (#526) — so the two agree on every
name, and each is free of every name the other's definitions use.
"""
function _rename_crate_tree(tree::ModuleNode; strict::Symbol = _ffi_strict())
    # Both halves at the emission's strictness: the expression emitter takes no
    # keyword and reads `_ffi_strict()`, so it is scoped here (PR #527 review).
    return _with_emission_strict(strict) do
        _rename_tree_parameters(tree, (fs, ss) -> begin
            colliding = _static_method_collisions(fs, ss)
            text = join(vcat(String[_emit_function_code(f; strict = strict)
                                    for f in fs if !_function_skipped!(f)],
                             String[_emit_struct_code(s; strict = strict, colliding = colliding)
                                    for s in ss]), "\n")
            Expr(:block, _function_wrappers_expr(fs), _struct_wrappers_expr(ss, colliding),
                 Meta.parseall(text))
        end)
    end
end

"""
    _rename_tree_parameters(tree, emit) -> ModuleNode

`tree` with every module's items renamed by `_rename_parameters` against what
`emit(functions, structs)` makes of that module's items (#526).
"""
function _rename_tree_parameters(tree::ModuleNode, emit)
    functions, structs = _rename_parameters(tree.functions, tree.structs, emit)
    return ModuleNode(tree.path, Vector{RustFunctionSignature}(functions),
                      Vector{RustStructInfo}(structs),
                      ModuleNode[_rename_tree_parameters(child, emit) for child in tree.children])
end

"""
    _submodule_exprs(node::ModuleNode) -> Vector{Expr}

The `module <name> ... end` expressions for the children of `node`, each with
the prelude, the helpers imported from the parent, its own items and its own
children. Static-method name collisions (#323) are decided per module, since
that is the scope a bare `name(args...)` definition lives in.
"""
function _submodule_exprs(node::ModuleNode)
    exprs = Expr[]
    for child in node.children
        colliding = _static_method_collisions(child.functions, child.structs)
        func_defs = _function_wrappers_expr(child.functions)
        struct_defs = _struct_wrappers_expr(child.structs, colliding)
        body = quote
            # No prelude: the wrappers reach Base and RustCall through
            # `GlobalRef`s (#528), and the helpers come from the parent.
            $(_parent_helper_imports_expr())
            $(_function_declarations_expr(child))
            $func_defs
            $struct_defs
            $(_submodule_exprs(child)...)
        end
        push!(exprs, Expr(:module, true, Symbol(_julia_module_name(last(child.path))), body))
    end
    return exprs
end

"""
    _function_declarations(node::ModuleNode; accessors) -> Vector{String}

Every function name the emitters define in `node`'s module that is not a type
or a submodule (free functions, static and instance methods, and with
`accessors` the expression emitter's `get_<f>` / `set_<f>!`), read off
`julia_definitions`. Each is declared `function <name> end` before any method,
so it is a new function of this module whatever it is called: a method defined
under a name the module only sees through `using Base` — `fn Int32`,
`fn String` — would otherwise extend Base's constructor (#528).
"""
function _function_declarations(node::ModuleNode; accessors::Bool)
    defs = julia_definitions(node.functions, node.structs; accessors = accessors)
    types = Set(d.name for d in defs if d.scope === :binding)
    names = String[]
    for d in defs
        (d.scope === :binding || (d.scope isa Tuple && first(d.scope) === :prop)) && continue
        d.name in types && continue
        d.name in names || push!(names, d.name)
    end
    return names
end

_function_declarations_expr(node::ModuleNode) =
    Expr(:block, (Expr(:function, Symbol(n)) for n in _function_declarations(node; accessors = true))...)

function _function_declarations_source(node::ModuleNode)
    names = _function_declarations(node; accessors = false)
    isempty(names) && return String[]
    return vcat("# Every function this module defines is its own (#528).",
                ["function $n end" for n in names], "")
end

"""
    _crate_wrapper_exprs(tree::ModuleNode) -> (func_defs, struct_defs, submodules)

The wrappers of a crate as `@rust_crate` binds them: the root's function
wrappers, its struct definitions (with the root's static-method collisions,
#323), and one module expression per Rust module below (#300).
`emit_crate_module` splices them into the generated module;
`boundary_report` runs them in collecting mode (#454), so the surface the
report examines is the surface the module defines.
"""
function _crate_wrapper_exprs(tree::ModuleNode)
    # Every parameter named against the definitions it lands in (#526).
    tree = _rename_crate_tree(tree)
    colliding = _static_method_collisions(tree.functions, tree.structs)
    return (_function_wrappers_expr(tree.functions),
            _struct_wrappers_expr(tree.structs, colliding),
            _submodule_exprs(tree))
end

"""
    _submodule_code(node::ModuleNode; strict) -> Vector{String}

Source-text twin of `_submodule_exprs` for `emit_crate_module_code`.
"""
function _submodule_code(node::ModuleNode; strict::Symbol = _ffi_strict())
    lines = String[]
    for child in node.children
        name = _julia_module_name(last(child.path))
        push!(lines, "# Rust module `$(join(child.path, "::"))` (#300)")
        push!(lines, "module $name")
        push!(lines, "")
        append!(lines, _emitted_aliases_source())
        push!(lines, _parent_helper_imports_source())
        push!(lines, "")
        append!(lines, _function_declarations_source(child))
        for func in child.functions
            _function_skipped!(func) && continue
            push!(lines, _emit_function_code(func; strict = strict))
            push!(lines, "")
        end
        colliding = _static_method_collisions(child.functions, child.structs)
        for s in child.structs
            push!(lines, _emit_struct_code(s; strict = strict, colliding = colliding))
            push!(lines, "")
        end
        append!(lines, _submodule_code(child; strict = strict))
        push!(lines, "end # module $name")
        push!(lines, "")
    end
    return lines
end
