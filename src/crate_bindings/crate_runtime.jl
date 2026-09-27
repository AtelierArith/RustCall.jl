"""
    CrateBindings

Runtime wrapper returned by `@rust_crate` and [`load_crate_bindings`](@ref).

Property access preserves non-function exports such as types and constants,
while exported functions are routed through a proxy so calls remain
world-age-safe after dynamic loading.
"""
struct CrateBindings
    module_ref::Module
end

struct CrateBindingMember
    bindings::CrateBindings
    name::Symbol
end

# The wrapped value and the bindings it came from. Deliberately `_`-prefixed:
# property access is forwarded wholesale to the wrapped object below, so these
# fields must be reached with `getfield`, and they must not collide with a field
# of the wrapped Rust type. A `#[pyclass] struct Counter { value: i64 }` used to
# be unreadable through the proxy because `:value` was reserved here (#424).
struct CrateBindingObject
    _bindings::CrateBindings
    _value::Any
end

_unwrap_crate_binding_value(value) = value
_unwrap_crate_binding_value(value::CrateBindingObject) = getfield(value, :_value)

_should_proxy_crate_binding(value) = value isa Function

function _wrap_crate_binding_value(bindings::CrateBindings, value)
    if value isa CrateBindings || value isa CrateBindingMember || value isa CrateBindingObject
        return value
    end

    if value isa Module
        return CrateBindings(value)
    end

    if value !== nothing && parentmodule(typeof(value)) === getfield(bindings, :module_ref)
        return CrateBindingObject(bindings, value)
    end

    return value
end

function Base.getproperty(bindings::CrateBindings, name::Symbol)
    if name === :module_ref
        return getfield(bindings, :module_ref)
    end

    module_ref = getfield(bindings, :module_ref)
    if !isdefined(module_ref, name)
        error("module $(nameof(module_ref)) has no binding $name")
    end

    value = Base.invokelatest(getproperty, module_ref, name)
    if _should_proxy_crate_binding(value)
        return CrateBindingMember(bindings, name)
    end

    return _wrap_crate_binding_value(bindings, value)
end

Base.propertynames(bindings::CrateBindings, private::Bool=false) = names(getfield(bindings, :module_ref); all=private)

function (member::CrateBindingMember)(args...)
    bindings = getfield(member, :bindings)
    module_ref = getfield(bindings, :module_ref)
    binding_name = getfield(member, :name)
    callable = Base.invokelatest(getproperty, module_ref, binding_name)
    result = Base.invokelatest(callable, map(_unwrap_crate_binding_value, args)...)
    return _wrap_crate_binding_value(bindings, result)
end

# Every property access forwards to the wrapped object, including one named
# `value` or `bindings`; the proxy's own fields are `_`-prefixed and reached
# with `getfield`.
function Base.getproperty(proxy::CrateBindingObject, name::Symbol)
    value = getfield(proxy, :_value)
    result = Base.invokelatest(getproperty, value, name)
    return _wrap_crate_binding_value(getfield(proxy, :_bindings), result)
end

function Base.setproperty!(proxy::CrateBindingObject, name::Symbol, value)
    target = getfield(proxy, :_value)
    raw_value = _unwrap_crate_binding_value(value)
    result = Base.invokelatest(setproperty!, target, name, raw_value)
    return _wrap_crate_binding_value(getfield(proxy, :_bindings), result)
end

function Base.propertynames(proxy::CrateBindingObject, private::Bool=false)
    Base.invokelatest(propertynames, getfield(proxy, :_value), private)
end

Base.show(io::IO, bindings::CrateBindings) = print(io, "CrateBindings(", nameof(getfield(bindings, :module_ref)), ")")
Base.show(io::IO, member::CrateBindingMember) = print(io, nameof(getfield(getfield(member, :bindings), :module_ref)), ".", getfield(member, :name))

function _show_crate_binding_object(io::IO, proxy::CrateBindingObject)
    value = getfield(proxy, :_value)
    module_name = nameof(getfield(getfield(proxy, :_bindings), :module_ref))
    type_name = nameof(typeof(value))

    print(io, module_name, ".", type_name, "(")
    for (idx, field_name) in enumerate(fieldnames(typeof(value)))
        idx > 1 && print(io, ", ")
        show(io, getfield(value, field_name))
    end
    print(io, ")")
end

Base.show(io::IO, proxy::CrateBindingObject) = _show_crate_binding_object(io, proxy)
Base.show(io::IO, ::MIME"text/plain", proxy::CrateBindingObject) = _show_crate_binding_object(io, proxy)

"""
    _instantiate_runtime_bindings(bindings_expr; target_module, visible) -> Module

Evaluate the generated module expression and return the module.

Where it is evaluated decides whether the caller can be precompiled (#339):

- `target_module === nothing` — the run-time API, `load_crate_bindings` called
  from a function with no expanding module: a fresh anonymous `Module` under
  `Main`, as before. Nothing rooted in `Main` can be part of a package's
  precompile image, and nothing that calls this way is being precompiled.
- `target_module` given (the `@rust_crate` macro passes `__module__`):
  `visible = true` defines the module directly as `target_module.<name>` —
  the `submodule=` form, for `using .Name: ...`. Otherwise, **while the caller
  is being precompiled** (`Base.generating_output()`), it goes into a hidden
  child namespace `target_module.var"##RustCallCrateRuntime#N"`, unique per
  call, so it belongs to the module tree Julia is serializing and nothing the
  caller did not name appears in its namespace (the #222 contract). Outside
  precompilation the anonymous `Main`-rooted module is used exactly as
  before: a child module defined in the caller can never be removed, and a
  run-time `@rust_crate` may be evaluated any number of times.

Only `submodule=` makes it visible, never `name=`, and that separation is not
cosmetic: `const B = @rust_crate path name="B"` is a documented form, and
defining a module `B` in the caller and *then* binding the returned value to
the same constant produced a package whose precompile image segfaults on load
(#339 review). `name=` therefore keeps naming the module without defining
anything the caller did not ask for.
"""
function _instantiate_runtime_bindings(bindings_expr::Expr;
                                       target_module::Union{Module, Nothing} = nothing,
                                       visible::Bool = false)
    # The caller-owned namespace exists for one reason: a module rooted in
    # `Main` cannot be part of a precompile image. Outside precompilation that
    # reason is absent, and a hidden child module defined in the caller on
    # every call can never be removed again — a function-scope `@rust_crate`
    # called in a loop, or a REPL evaluated repeatedly, would grow the caller's
    # binding table for the life of the session. So the anonymous module is
    # kept for run-time calls, and only a caller that is *being precompiled*
    # (`Base.generating_output()`) gets the child namespace (#339 review).
    # `submodule=` is a name the caller asked for, and is defined either way.
    if target_module === nothing || (!visible && !Base.generating_output())
        runtime_namespace = Module(gensym(:RustCallCrateRuntime))
        return Base.invokelatest(Core.eval, runtime_namespace, bindings_expr)
    end
    visible && return Base.invokelatest(Core.eval, target_module, bindings_expr)
    namespace_expr = Expr(:module, true, gensym(:RustCallCrateRuntime), Expr(:block))
    runtime_namespace = Base.invokelatest(Core.eval, target_module, namespace_expr)
    return Base.invokelatest(Core.eval, runtime_namespace, bindings_expr)
end

"""
    load_crate_bindings(crate_path::String; output_module_name=nothing, submodule_name=nothing, build_release=true, cache_enabled=true, target_module=nothing) -> CrateBindings

Generate, load, and return explicit bindings for a Rust crate.

Use the returned [`CrateBindings`](@ref) value directly:

```julia
const MyCrate = load_crate_bindings("/path/to/my_crate")
MyCrate.add(Int32(1), Int32(2))
p = MyCrate.Point(3.0, 4.0)
p isa MyCrate.Point
```

`target_module` is where the generated module is defined. The `@rust_crate`
macro passes the module that expands it, which is what lets a package that
uses the macro at top level be precompiled (#339); called without it, the
module lives in an anonymous namespace under `Main` and the caller cannot be
precompiled.

`output_module_name` names the generated module; it defines nothing in
`target_module`, so the bindings are reached through the returned value.
`submodule_name` is what defines it there — `target_module.Name`, so
`using .Name: f` works — and it also names it, so the two are not given
together.
"""
function load_crate_bindings(crate_path::String;
    output_module_name::Union{String, Nothing} = nothing,
    submodule_name::Union{String, Nothing} = nothing,
    build_release::Bool = true,
    cache_enabled::Bool = true,
    features::Vector{String} = String[],
    default_features::Bool = true,
    pyo3_host::Bool = false,
    target_module::Union{Module, Nothing} = nothing,
)
    if submodule_name !== nothing && output_module_name !== nothing &&
       submodule_name != output_module_name
        throw(ArgumentError(
            "load_crate_bindings: `submodule_name` ($(repr(submodule_name))) and " *
            "`output_module_name` ($(repr(output_module_name))) name the same module " *
            "and must agree; pass only `submodule_name` to define it in the caller"))
    end
    module_name = submodule_name === nothing ? output_module_name : submodule_name

    bindings_expr = generate_bindings(
        crate_path;
        output_module_name = module_name,
        build_release = build_release,
        cache_enabled = cache_enabled,
        features = features,
        default_features = default_features,
        pyo3_host = pyo3_host,
    )

    crate_module = _instantiate_runtime_bindings(
        bindings_expr;
        target_module = target_module,
        visible = submodule_name !== nothing,
    )
    return CrateBindings(crate_module)
end

# ============================================================================
# @rust_crate Macro
# ============================================================================

"""
    @rust_crate(path)
    @rust_crate(path, options...)

Generate and load bindings for an external Rust crate.

# Arguments
- `path`: Path to the Rust crate (string literal)

# Options
- `name="ModuleName"`: name the generated module. It defines nothing in the
  calling module; the bindings are reached through the returned value.
- `submodule="ModuleName"`: define the generated module under that name **in
  the calling module**, so that `using .ModuleName: f, T` works — the shape a
  package uses. Do not assign the result to the same name.
- `release=true/false`: Build in release mode (default: true)
- `cache=true/false`: Enable caching (default: true)
- `pyo3_host=false/true`: bind a PyO3 crate through a live Python interpreter
  instead of the generated C-ABI wrapper (#424). The crate is built as the
  Python extension it already is and its imported module is called, so a private
  `#[pyfunction]` (E0603 to the wrapper path), a `Python<'_>` signature, numpy
  arrays and Python callables are all reachable. Requires PythonCall
  (`using PythonCall`); a `PyResult{T}` becomes `RustResult{T, String}` carrying
  the interpreter's own message.

# Where the module lives

The generated module is evaluated inside the module that expands the macro, so
a package that uses `@rust_crate` at top level can be precompiled (#339): the
crate is built and the bindings generated when the package is precompiled, and
the module's `__init__` opens the library — RustCall's cache copy — in the
session that loads the package. If that copy has been rebuilt or removed
(`RustCall.clear_cache()`), the package's precompile cache is stale and Julia
re-precompiles it, building the crate again.

Without `submodule=` the module has a hidden, per-call name inside the caller,
so repeated calls never collide and nothing the caller did not name appears in
its namespace. With `submodule="X"`, a second `@rust_crate ... submodule="X"`
in the same module replaces `X` (Julia warns `replacing module X`); bindings
obtained earlier keep the module they hold. `submodule="X"` defines `X`, so do
not also write `const X = @rust_crate ... submodule="X"` — binding the returned
value over the module it just defined is what `name=` deliberately avoids.

# Example
```julia
# Basic usage
const MyCrate = @rust_crate "/path/to/my_crate"

# With options
const MyBindings = @rust_crate "/path/to/my_crate" name="MyBindings" release=true

# After loading, use the returned bindings value directly
MyCrate.add(Int32(1), Int32(2))
p = MyCrate.Point(3.0, 4.0)
MyCrate.distance(p)

# In a package: define the module here and re-export from it
module MyPkg
using RustCall
@rust_crate joinpath(@__DIR__, "..", "deps", "my_crate") submodule="Bindings"
using .Bindings: add, Point
export add, Point
end
```
"""
macro rust_crate(path, options...)
    module_name = nothing
    submodule_name = nothing
    release = true
    cache = true
    features = :(String[])
    default_features = true
    pyo3_host = false

    for opt in options
        if isa(opt, Expr) && opt.head == :(=)
            key = opt.args[1]
            value = opt.args[2]

            if key == :name
                module_name = value
            elseif key == :submodule
                submodule_name = value
            elseif key == :release
                release = value
            elseif key == :cache
                cache = value
            elseif key == :features
                features = value
            elseif key == :default_features
                default_features = value
            elseif key == :pyo3_host
                pyo3_host = value
            end
        end
    end

    # `__module__` is the module the macro expands in. The generated module is
    # placed inside it — hidden unless `submodule=` names it — which is what a
    # package precompiling this call site needs (#339).
    quote
        load_crate_bindings(
            $(esc(path));
            output_module_name = $module_name,
            submodule_name = $submodule_name,
            build_release = $release,
            cache_enabled = $cache,
            features = String[$(esc(features))...],
            default_features = $(esc(default_features)),
            pyo3_host = $(esc(pyo3_host)),
            target_module = $__module__,
        )
    end
end
