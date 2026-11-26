# The generator accepts Rust type expressions as *trusted source*, not as Rust
# syntax to parse in Julia. Cargo/rustc validates the resulting concrete types.
const _RUST_INSTANCE_RESERVED = (
    "as", "break", "const", "continue", "crate", "else", "enum", "extern",
    "false", "fn", "for", "if", "impl", "in", "let", "loop", "match",
    "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
    "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
    "async", "await", "dyn", "abstract", "become", "box", "do", "final", "macro",
    "override", "priv", "typeof", "unsized", "virtual", "yield", "try",
)

function _instance_ident(value)
    value isa Union{AbstractString,Symbol} || throw(ArgumentError("expected a Rust identifier"))
    name = String(value)
    chars = collect(name)
    valid_first(c) = isascii(c) && (isletter(c) || c == '_')
    valid_rest(c) = valid_first(c) || ('0' <= c <= '9')
    !isempty(chars) && valid_first(first(chars)) && all(valid_rest, chars) &&
        name != "_" && !(name in _RUST_INSTANCE_RESERVED) ||
        throw(ArgumentError("invalid Rust identifier: $(repr(name))"))
    return name
end

function _instance_fields(spec, allowed, context)
    all(key -> key in allowed, propertynames(spec)) ||
        throw(ArgumentError("unknown $context field"))
end

function _instance_require(spec, fields, context)
    all(key -> hasproperty(spec, key), fields) ||
        throw(ArgumentError("missing required $context field"))
end

function _instance_source(value, context)
    value isa Union{AbstractString, Symbol} || throw(ArgumentError("$context must be Rust source"))
    source = String(value)
    isempty(strip(source)) && throw(ArgumentError("empty $context"))
    return source
end

function _instance_owner_path(value)
    source = strip(_instance_source(value, "owned return type"))
    absolute = startswith(source, "::")
    segments = split(absolute ? source[3:end] : source, "::")
    for (i, segment) in enumerate(segments)
        name = strip(segment)
        if !absolute && i < length(segments)
            i == 1 && name in ("crate", "self") && continue
            name == "super" && all(s -> strip(s) == "super", @view(segments[1:i-1])) && continue
        end
        _instance_ident(name)
    end
    return source
end

function _instance_params(params, wrappers = nothing)
    names = String[]
    typed = String[]
    forwarded = String[]
    for pair in params
        pair isa Pair || throw(ArgumentError("parameters must be name => Rust type or wrapper mapping pairs"))
        name = _instance_ident(first(pair))
        name in names && throw(ArgumentError("duplicate parameter $name"))
        value = last(pair)
        if value isa NamedTuple
            _instance_fields(value, (:wrapper, :mutable), "argument mapping")
            hasproperty(value, :wrapper) || throw(ArgumentError("argument mapping requires wrapper"))
            owner = _instance_ident(value.wrapper)
            wrappers !== nothing && owner in wrappers || throw(ArgumentError("unknown wrapper $owner"))
            mutable = hasproperty(value, :mutable) ? value.mutable : false
            mutable isa Bool || throw(ArgumentError("argument mapping mutable must be Bool"))
            borrow = mutable ? "&mut " : "&"
            ty = borrow * owner
            push!(forwarded, borrow * name * ".inner")
        else
            ty = _instance_source(value, "parameter type")
            push!(forwarded, name)
        end
        push!(names, name)
        push!(typed, "$name: $ty")
    end
    return names, typed, forwarded
end

"""
    RustCall.generate_crate_instances(instances) -> String

Generate Rust source for a finite set of concrete owned `#[julia]` wrapper
structs around generic types. Each entry is a named tuple with fields `name`,
`rust_type`, `constructor`, and `methods`. A constructor has `name` and `args`
(a vector of `name => rust_type` pairs). A fallible constructor additionally
has `error_type` (a Rust type supported by RustCall's Result ABI). An optional
`expression` supplies a trusted Rust expression in the declared arguments;
it must produce the concrete type or, for fallible constructors, its `Result`.
A method has `name`, `args`, `mutable` (`Bool`), and either a legacy
`return_type` or an explicit `return_wrapper` naming a declared wrapper.
An argument value `(wrapper = :Other, mutable = false)` emits `&Other` and
forwards `&arg.inner`; `mutable = true` emits and forwards mutable references.
Wrapper mappings can refer to declarations later in the specification.
Constructors can use the same mapped arguments; these constructors opt into
explicit owned-return proofs and ABI markers. A one-argument mapped constructor
requires its declared owner and rejects raw pointer-adoption shorthand.
`return_wrapper` wraps the native result into that owner; adding `error_type`
wraps the success of a `Result`. It conflicts with `return_type`.
A trusted method `expression` is emitted verbatim in wrapper-variable scope:
`self` is the current wrapper and mapped arguments are wrapper references, so
an explicit expression accesses their `.inner` fields itself. It must produce
the native inner value (or its `Result`), not a generated wrapper. The generated constructor calls the
specified associated function on the concrete type and wraps the returned value;
methods forward to `&self` or `&mut self`. These Rust functions and types must
be public and their concrete signatures must match the declarations.

- `owned_return` optionally names a concrete `#[julia]` owner type by path.
  It emits `#[rustcall_owned_return(Owner)]`. The expression must already
  produce the owner or a `Result<Owner, E>` with a supported error type.

The output is Rust source to place in a facade crate that depends on both the
original crate and `rustcall_julia_macros`, then load with `@rust_crate`.
`rust_type`, argument types and return types are **trusted Rust source**, checked
by `cargo` rather than parsed or sanitized by this function. RustCall's normal
crate binding rules determine which concrete signatures can cross the ABI.
The wrapper owns its value; normal RustCall struct finalization drops it.
The generator adds no synchronization: callers must prevent concurrent access
that violates Rust's aliasing or the underlying type's thread-safety rules.
This API does not infer methods, trait bounds, associated types, conversions,
or lifetimes. Write custom wrappers for those cases.
"""
function generate_crate_instances(instances::AbstractVector)
    # Inventory first: an argument or return can map to a wrapper declared later.
    used = Set{String}()
    for instance in instances
        _instance_require(instance, (:name, :rust_type, :constructor, :methods), "instance")
        name = _instance_ident(instance.name)
        name in used && throw(ArgumentError("duplicate wrapper $name"))
        push!(used, name)
    end
    plans = Any[]
    for instance in instances
        _instance_fields(instance, (:name, :rust_type, :constructor, :methods), "instance")
        name = _instance_ident(instance.name)
        rust_type = _instance_source(instance.rust_type, "concrete Rust type")
        ctor = instance.constructor
        _instance_require(ctor, (:name, :args), "constructor")
        _instance_fields(ctor, (:name, :args, :expression, :error_type), "constructor")
        ctor_name = _instance_ident(ctor.name)
        _, ctor_args, ctor_forwarded = _instance_params(ctor.args, used)
        ctor_mapped = any(arg -> last(arg) isa NamedTuple, ctor.args)
        constructor_call = hasproperty(ctor, :expression) ?
            _instance_source(ctor.expression, "constructor expression") :
            "<$rust_type>::$ctor_name(" * join(ctor_forwarded, ", ") * ")"
        ctor_error = hasproperty(ctor, :error_type) ?
            _instance_source(ctor.error_type, "constructor error type") : nothing
        methods_seen = Set([ctor_name])
        methods = Any[]
        for method in instance.methods
            _instance_require(method, (:name, :args, :mutable), "method")
            _instance_fields(method, (:name, :args, :return_type, :mutable, :return_wrapper,
                                      :error_type, :expression), "method")
            method_name = _instance_ident(method.name)
            method_name in methods_seen && throw(ArgumentError("duplicate method $method_name"))
            push!(methods_seen, method_name)
            _, args, forwarded = _instance_params(method.args, used)
            method.mutable isa Bool || throw(ArgumentError("method mutable must be Bool"))
            mapped_return = hasproperty(method, :return_wrapper)
            has_return = hasproperty(method, :return_type)
            has_error = hasproperty(method, :error_type)
            has_return && (mapped_return || has_error) && throw(ArgumentError(
                "return_type conflicts with return_wrapper/error_type"))
            mapped_return || has_return || throw(ArgumentError("method requires return_type or return_wrapper"))
            has_error && !mapped_return && throw(ArgumentError("error_type requires return_wrapper"))
            owner = mapped_return ? _instance_ident(method.return_wrapper) : nothing
            mapped_return && !(owner in used) && throw(ArgumentError("unknown return wrapper $owner"))
            error = has_error ? _instance_source(method.error_type, "method error type") : nothing
            ret = mapped_return ? (error === nothing ? owner : "Result<$owner, $error>") :
                _instance_source(method.return_type, "return type")
            call = hasproperty(method, :expression) ? _instance_source(method.expression, "method expression") :
                "self.inner.$method_name(" * join(forwarded, ", ") * ")"
            receiver = method.mutable ? "&mut self" : "&self"
            push!(methods, (; name = method_name, args, receiver, ret, owner, error, call))
        end
        push!(plans, (; name, rust_type, ctor_name, ctor_args, constructor_call, ctor_error, ctor_mapped, methods))
    end
    io = IOBuffer()
    println(io, "use rustcall_julia_macros::julia;")
    for plan in plans
        (; name, rust_type, ctor_name, ctor_args, constructor_call, ctor_error, ctor_mapped, methods) = plan
        println(io, "#[julia]\npub struct $name { inner: $rust_type }")
        println(io, "#[julia]\nimpl $name {")
        println(io, "    #[julia]")
        ctor_mapped && println(io, "    #[rustcall_owned_return($name)]")
        if ctor_error !== nothing
            println(io, "    pub fn $ctor_name(", join(ctor_args, ", "), ") -> Result<Self, $ctor_error> {")
            println(io, "        ($constructor_call).map(|inner| Self { inner })")
        else
            println(io, "    pub fn $ctor_name(", join(ctor_args, ", "), ") -> Self {")
            println(io, "        Self { inner: $constructor_call }")
        end
        println(io, "    }")
        for method in methods
            signature = join([method.receiver; method.args], ", ")
            println(io, "    #[julia]")
            method.owner === nothing || println(io, "    #[rustcall_owned_return(", method.owner, ")]")
            println(io, "    pub fn ", method.name, "($signature) -> ", method.ret, " {")
            if method.owner === nothing
                println(io, "        ", method.call)
            elseif method.error === nothing
                println(io, "        ", method.owner, " { inner: ", method.call, " }")
            else
                println(io, "        (", method.call, ").map(|inner| ", method.owner, " { inner })")
            end
            println(io, "    }")
        end
        println(io, "}")
    end
    return String(take!(io))
end

"""
    RustCall.generate_crate_functions(functions; header = true) -> String

Generate Rust source for concrete `#[julia]` free functions, typically
instantiations of a dependency's generic functions. Each entry is a named tuple
with required fields `name`, `args`, `return_type` and `expression`.

- `name` is the Rust function name of the generated wrapper (and its Julia
  binding).
- `args` is a vector of `name => rust_type` pairs, as for a method's
  arguments. The names are the parameters the `expression` sees.
- `return_type` is the concrete Rust return type.
- `expression` is trusted Rust source evaluated in the declared parameters'
  scope. It must produce `return_type`, for example
  `"specials::gamma::<f64>(x)"` or `"sample::twice::<f64>(x)"`.

The output is Rust source to place in a facade crate that depends on both the
original crate and `rustcall_julia_macros`, then load with `@rust_crate`.
`header = false` omits the `use rustcall_julia_macros::julia;` line, for a file
that already has it (for example when composing this output with
`generate_crate_instances`):

```julia
functions = [(
    name = "gamma_f64",
    args = ["x" => "f64"],
    return_type = "f64",
    expression = "specials::gamma::<f64>(x)",
)]
write("specials_facade/src/lib.rs", RustCall.generate_crate_functions(functions))
```

`args` types, `return_type` and `expression` are **trusted Rust source**,
checked by `cargo` rather than parsed or sanitized here. RustCall's normal
crate binding rules decide which concrete signatures can cross the ABI. This
API does not infer instantiations from the crate: every function is declared
explicitly.
"""
function generate_crate_functions(functions::AbstractVector; header::Bool = true)
    used = Set{String}()
    plans = Any[]
    for spec in functions
        _instance_require(spec, (:name, :args, :return_type, :expression), "function")
        _instance_fields(spec, (:name, :args, :return_type, :expression, :owned_return), "function")
        name = _instance_ident(spec.name)
        name in used && throw(ArgumentError("duplicate function $name"))
        push!(used, name)
        _, args, _ = _instance_params(spec.args)
        return_type = _instance_source(spec.return_type, "return type")
        expression = _instance_source(spec.expression, "function expression")
        owner = hasproperty(spec, :owned_return) ? _instance_owner_path(spec.owned_return) : nothing
        push!(plans, (; name, args, return_type, expression, owner))
    end
    io = IOBuffer()
    header && println(io, "use rustcall_julia_macros::julia;")
    for plan in plans
        header && println(io)
        println(io, "#[julia]")
        plan.owner === nothing || println(io, "#[rustcall_owned_return(", plan.owner, ")]")
        println(io, "pub fn ", plan.name, "(", join(plan.args, ", "), ") -> ", plan.return_type, " {")
        println(io, "    ", plan.expression)
        println(io, "}")
    end
    return String(take!(io))
end
