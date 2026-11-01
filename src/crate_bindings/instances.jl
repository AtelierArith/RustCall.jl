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

function _instance_params(params)
    names = String[]
    typed = String[]
    for pair in params
        pair isa Pair || throw(ArgumentError("parameters must be name => Rust type pairs"))
        name = _instance_ident(first(pair))
        name in names && throw(ArgumentError("duplicate parameter $name"))
        ty = String(last(pair))
        isempty(strip(ty)) && throw(ArgumentError("empty parameter type"))
        push!(names, name)
        push!(typed, "$name: $ty")
    end
    return names, typed
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
A method has `name`, `args`,
`return_type`, and `mutable` (`Bool`). The generated constructor calls the
specified associated function on the concrete type and wraps the returned value;
methods forward to `&self` or `&mut self`. These Rust functions and types must
be public and their concrete signatures must match the declarations.

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
    io = IOBuffer()
    println(io, "use rustcall_julia_macros::julia;")
    used = Set{String}()
    for instance in instances
        name = _instance_ident(instance.name)
        name in used && throw(ArgumentError("duplicate wrapper $name"))
        push!(used, name)
        rust_type = String(instance.rust_type)
        isempty(strip(rust_type)) && throw(ArgumentError("empty concrete Rust type"))
        ctor = instance.constructor
        ctor_name = _instance_ident(ctor.name)
        ctor_names, ctor_args = _instance_params(ctor.args)
        println(io, "#[julia]\npub struct $name { inner: $rust_type }")
        println(io, "#[julia]\nimpl $name {")
        constructor_call = hasproperty(ctor, :expression) ? String(ctor.expression) :
            "<$rust_type>::$ctor_name(" * join(ctor_names, ", ") * ")"
        isempty(strip(constructor_call)) && throw(ArgumentError("empty constructor expression"))
        if hasproperty(ctor, :error_type)
            error_type = String(ctor.error_type)
            isempty(strip(error_type)) && throw(ArgumentError("empty constructor error type"))
            println(io, "    #[julia]\n    pub fn $ctor_name(", join(ctor_args, ", "), ") -> Result<Self, $error_type> {")
            println(io, "        ($constructor_call).map(|inner| Self { inner })")
        else
            println(io, "    #[julia]\n    pub fn $ctor_name(", join(ctor_args, ", "), ") -> Self {")
            println(io, "        Self { inner: $constructor_call }")
        end
        println(io, "    }")
        methods_seen = Set([ctor_name])
        for method in instance.methods
            method_name = _instance_ident(method.name)
            method_name in methods_seen && throw(ArgumentError("duplicate method $method_name"))
            push!(methods_seen, method_name)
            names, args = _instance_params(method.args)
            return_type = String(method.return_type)
            isempty(strip(return_type)) && throw(ArgumentError("empty return type"))
            method.mutable isa Bool || throw(ArgumentError("method mutable must be Bool"))
            receiver = method.mutable ? "&mut self" : "&self"
            signature = join([receiver; args], ", ")
            println(io, "    #[julia]\n    pub fn $method_name($signature) -> $return_type {")
            println(io, "        self.inner.$method_name(", join(names, ", "), ")")
            println(io, "    }")
        end
        println(io, "}")
    end
    return String(take!(io))
end
