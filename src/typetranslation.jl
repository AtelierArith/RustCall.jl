# Type translation between Rust and Julia

"""
Mapping from Rust type names (as Symbols) to Julia types.
"""
const RUST_TO_JULIA_TYPE_MAP = Dict{Symbol, Type}(
    # Signed integers
    :i8 => Int8,
    :i16 => Int16,
    :i32 => Int32,
    :i64 => Int64,
    :i128 => Int128,
    :isize => Int,  # Platform-dependent

    # Unsigned integers
    :u8 => UInt8,
    :u16 => UInt16,
    :u32 => UInt32,
    :u64 => UInt64,
    :u128 => UInt128,
    :usize => UInt,  # Platform-dependent

    # Floating point
    :f32 => Float32,
    :f64 => Float64,

    # Boolean
    :bool => Bool,

    # Unit type (void)
    Symbol("()") => Cvoid,

    # C types (for FFI compatibility)
    :c_char => Cchar,
    :c_int => Cint,
    :c_uint => Cuint,
    :c_long => Clong,
    :c_ulong => Culong,
    :c_longlong => Clonglong,
    :c_ulonglong => Culonglong,
    :c_float => Cfloat,
    :c_double => Cdouble,

    # String types (basic support)
    :str => Cstring,  # bare :str symbol maps to Cstring for simple FFI
)

"""
Mapping from Julia types to Rust type names (as Strings).
"""
const JULIA_TO_RUST_TYPE_MAP = Dict{Type, String}(
    # Signed integers
    Int8 => "i8",
    Int16 => "i16",
    Int32 => "i32",
    Int64 => "i64",
    Int128 => "i128",

    # Unsigned integers
    UInt8 => "u8",
    UInt16 => "u16",
    UInt32 => "u32",
    UInt64 => "u64",
    UInt128 => "u128",

    # Floating point
    Float32 => "f32",
    Float64 => "f64",

    # Boolean
    Bool => "bool",

    # Void
    Cvoid => "()",
    Nothing => "()",
)

"""
    rusttype_to_julia(rust_type::Symbol) -> Type

Convert a Rust type name to the corresponding Julia type.

# Examples
```julia
rusttype_to_julia(:i32)  # => Int32
rusttype_to_julia(:f64)  # => Float64
rusttype_to_julia(:bool) # => Bool
```
"""
function rusttype_to_julia(rust_type::Symbol)
    if haskey(RUST_TO_JULIA_TYPE_MAP, rust_type)
        return RUST_TO_JULIA_TYPE_MAP[rust_type]
    end
    error("Unsupported Rust type: $rust_type")
end

"""
    rusttype_to_julia(rust_type::String) -> Type

Convert a Rust type name string to the corresponding Julia type.
Handles pointer types like `*const i32` and `*mut i32`.
Also handles string types like `String` and `&str`.
"""
function rusttype_to_julia(rust_type::String)
    rust_type = strip(rust_type)

    # Handle pointer types
    if startswith(rust_type, "*const ")
        inner_type = rust_type[8:end]
        inner_type_stripped = strip(inner_type)

        # Special handling for string pointers
        if inner_type_stripped == "u8" || inner_type_stripped == "c_char"
            return Cstring
        end

        inner_julia_type = rusttype_to_julia(String(inner_type_stripped))
        return Ptr{inner_julia_type}
    elseif startswith(rust_type, "*mut ")
        inner_type = rust_type[6:end]
        inner_type_stripped = strip(inner_type)

        # Special handling for string pointers
        if inner_type_stripped == "u8" || inner_type_stripped == "c_char"
            return Ptr{UInt8}
        end

        inner_julia_type = rusttype_to_julia(String(inner_type_stripped))
        return Ptr{inner_julia_type}
    end

    # Handle string types
    if rust_type == "String"
        return RustString
    elseif rust_type == "&str"
        return RustStr  # &str is a fat pointer (ptr + len), represented by RustStr
    elseif rust_type == "str"
        return Cstring  # bare str symbol maps to Cstring for simple FFI
    end

    # Handle unit type
    if rust_type == "()"
        return Cvoid
    end

    # Try as a symbol
    return rusttype_to_julia(Symbol(rust_type))
end

"""
    juliatype_to_rust(julia_type::Type) -> String

Convert a Julia type to the corresponding Rust type name.

# Examples
```julia
juliatype_to_rust(Int32)   # => "i32"
juliatype_to_rust(Float64) # => "f64"
juliatype_to_rust(Bool)    # => "bool"
juliatype_to_rust(String)  # => "*const u8" (for FFI)
juliatype_to_rust(Cstring) # => "*const u8"
```
"""
juliatype_to_rust(::Type{String}) = "*const u8"  # String is passed as *const u8 in FFI
juliatype_to_rust(::Type{Cstring}) = "*const u8"
juliatype_to_rust(::Type{RustString}) = "String"
juliatype_to_rust(::Type{RustStr}) = "&str"  # RustStr represents Rust's &str
juliatype_to_rust(::Type{Int}) = Sys.WORD_SIZE == 64 ? "i64" : "i32"
juliatype_to_rust(::Type{UInt}) = Sys.WORD_SIZE == 64 ? "u64" : "u32"

function juliatype_to_rust(julia_type::Type{<:Ptr})
    # Cstring is an alias of Ptr{UInt8} and is conventionally treated as const.
    if julia_type == Cstring
        return "*const u8"
    end

    inner_type = eltype(julia_type)
    if inner_type == Cvoid
        return "*mut c_void"
    elseif inner_type == UInt8
        return "*mut u8"
    end

    inner_rust_type = juliatype_to_rust(inner_type)
    return "*mut $inner_rust_type"
end

function juliatype_to_rust(julia_type::Type)
    if haskey(JULIA_TO_RUST_TYPE_MAP, julia_type)
        return JULIA_TO_RUST_TYPE_MAP[julia_type]
    end
    error("Unsupported Julia type: $julia_type")
end

"""
    llvm_to_julia_type(llvm_type_str::String) -> Type

Convert an LLVM IR type string to the corresponding Julia type.
"""
function llvm_to_julia_type(llvm_type_str::String)
    llvm_type_str = strip(llvm_type_str)

    # Integer types
    if llvm_type_str == "i1"
        return Bool
    elseif llvm_type_str == "i8"
        return Int8
    elseif llvm_type_str == "i16"
        return Int16
    elseif llvm_type_str == "i32"
        return Int32
    elseif llvm_type_str == "i64"
        return Int64
    elseif llvm_type_str == "i128"
        return Int128
    end

    # Floating point types
    if llvm_type_str == "float"
        return Float32
    elseif llvm_type_str == "double"
        return Float64
    end

    # Void type
    if llvm_type_str == "void"
        return Cvoid
    end

    # Pointer types (LLVM IR syntax: ptr or i32*)
    if llvm_type_str == "ptr" || endswith(llvm_type_str, "*")
        return Ptr{Cvoid}
    end

    error("Unsupported LLVM type: $llvm_type_str")
end

"""
    julia_to_llvm_type(julia_type::Type) -> String

Convert a Julia type to the corresponding LLVM IR type string.
"""
julia_to_llvm_type(::Type{Bool}) = "i1"
julia_to_llvm_type(::Type{<:Union{Int8, UInt8}}) = "i8"
julia_to_llvm_type(::Type{<:Union{Int16, UInt16}}) = "i16"
julia_to_llvm_type(::Type{<:Union{Int32, UInt32}}) = "i32"
julia_to_llvm_type(::Type{<:Union{Int64, UInt64}}) = "i64"
julia_to_llvm_type(::Type{<:Union{Int128, UInt128}}) = "i128"
julia_to_llvm_type(::Type{Float32}) = "float"
julia_to_llvm_type(::Type{Float64}) = "double"
julia_to_llvm_type(::Type{Cvoid}) = "void"  # Cvoid === Nothing
julia_to_llvm_type(::Type{<:Ptr}) = "ptr"

function julia_to_llvm_type(julia_type::Type)
    error("Unsupported Julia type for LLVM: $julia_type")
end
