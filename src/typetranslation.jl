# Type translation between Rust and Julia

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
    rusttype_to_julia(rust_type) -> Type

The Julia type a Rust type spelling maps to, as a `Symbol` or a `String`.

A thin shim over the FFI contract (`src/ffi_contract.jl`), which is the single
source of truth since #276: this had its own 26-row table, and the two
disagreed. Raises for a spelling the contract does not cover, rather than
guessing.

Two spellings changed meaning with the migration, deliberately (#246):

| spelling     | was       | is        |
| ------------ | --------- | --------- |
| `"str"`      | `Cstring` | `RustStr` |
| `"*const u8"`| `Cstring` | `Ptr{UInt8}` |

A Rust `str` is an unsized UTF-8 slice reached through a `(ptr, len)` fat
pointer and a `*const u8` is a plain byte pointer; neither is the
NUL-terminated `Cstring` the old table claimed. Use
[`ffi_argument_contract`](@ref) / [`ffi_return_contract`](@ref) when you need
the calling convention rather than just the Julia type.

# Examples
```julia
rusttype_to_julia(:i32)          # => Int32
rusttype_to_julia("*const i32")  # => Ptr{Int32}
rusttype_to_julia("String")      # => RustString
```
"""
rusttype_to_julia(rust_type::Symbol) = rusttype_to_julia(String(rust_type))

function rusttype_to_julia(rust_type::AbstractString)
    T = ffi_surface_type(rust_type)
    T === nothing && error(
        "Unsupported Rust type: $(rust_type). " *
        "$(ffi_describe(rust_type)); see `RustCall.FFI_TYPE_TABLE` for the " *
        "spellings the FFI contract covers (#276).")
    return T
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
