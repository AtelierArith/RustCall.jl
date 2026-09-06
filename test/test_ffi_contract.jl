# Tests for the single source of truth of the FFI type contract
# (`src/ffi_contract.jl`, issue #276).
#
# Phase A added the contract next to the five tables that already decided "what
# does this Rust type mean at the C boundary?", and enumerated every point where
# they disagreed with it. Phase B migrated every call site onto the contract and
# deleted those five tables, so the divergence tests became what they were
# always meant to be: the regression tests for #245, #246 and #249.
#
# What is left of the old tables is `rustcall_core`'s `is_ffi_compatible_type` /
# `is_non_ffi_type` (mirrored here as `core_is_ffi_compatible` /
# `core_is_non_ffi`), which stays deliberately — it is the *acceptance gate* on
# the Rust side, deciding whether a wrapper is generated at all, not a mapping.

using Test
using RustCall

# ----------------------------------------------------------------------------
# Fixtures for "by-value aggregates are opt-in" (#245 item 3). A `struct` needs
# module scope, so these live outside the testset that uses them.
# ----------------------------------------------------------------------------

struct Rc245ByValue
    x::Int32
    y::Float64
end

# Same fields, different type: the layout assertion is per type, not per shape.
struct Rc245ByValueTwin
    x::Int32
    y::Float64
end

mutable struct Rc245Mutable
    x::Int32
end

# A parametric aggregate: the parameter changes the layout, so a concrete
# registration must not license a different instantiation — and the family
# itself must not be registrable at all.
struct Rc245Pair{T}
    a::T
    b::T
end

# An abstract family, whose subtypes share nothing but a name.
abstract type Rc245Shape{T} end

struct Rc245Square{T} <: Rc245Shape{T}
    side::T
end

# Stands in for a mirror a wrapper generator emits: the assertion is in the
# supertype, so it survives precompilation without touching any registry.
struct Rc245Mirror <: RustCall.FFIByValue
    is_ok::UInt8
    value::Int32
end

# ----------------------------------------------------------------------------
# The Rust-side acceptance gate, as callable probes
# ----------------------------------------------------------------------------

# Table 1: `deps/rustcall_core/src/types.rs:85` / `:104`. It lives in Rust, so
# it is mirrored here as data. `PRIMITIVES` is `types.rs:12` verbatim.
const CORE_PRIMITIVES = [
    "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128",
    "f32", "f64", "bool", "char", "usize", "isize",
]

const CORE_NON_FFI = ["String", "Vec", "Box", "Rc", "Arc", "HashMap", "HashSet",
                      "BTreeMap", "BTreeSet", "Cow"]

_is_ptr_spelling(s) = startswith(s, "*const ") || startswith(s, "*mut ")

# `last_ident`: the final path segment of a path type, ignoring generic args.
core_last_ident(s::AbstractString) = String(last(split(first(split(s, '<')), "::")))

# `is_ffi_compatible_type`: a path type whose LAST SEGMENT is a primitive (so
# `core::primitive::i32` and `mycrate::i32` both qualify), the empty tuple, or
# *any* raw pointer (`Type::Ptr(_) => true`).
function core_is_ffi_compatible(s::AbstractString)
    s == "()" && return true
    _is_ptr_spelling(s) && return true
    startswith(s, "&") && return false
    return core_last_ident(s) in CORE_PRIMITIVES
end

# `is_non_ffi_type`: the known container list (again by last segment), plus
# every reference.
function core_is_non_ffi(s::AbstractString)
    startswith(s, "&") && return true
    return core_last_ident(s) in CORE_NON_FFI
end

# The union of the spellings any of the retired tables — or the contract — has
# an opinion about.
const ALL_SPELLINGS = vcat(
    CORE_PRIMITIVES,
    ["()", "String", "&str", "str", "*const u8", "*mut i32", "*mut c_void", "Vec<f64>"],
)

@testset "FFI contract (#276)" begin

    @testset "table shape" begin
        for (spelling, entry) in RustCall.FFI_TYPE_TABLE
            @test entry.rust == spelling
            @test entry.abi in RustCall.FFI_ABI_KINDS
            @test entry.ownership in RustCall.FFI_OWNERSHIP_KINDS
            @test isconcretetype(entry.ccall_type) || entry.ccall_type === Cvoid
        end
        # Every primitive `rustcall_core` accepts must be in the contract —
        # this is acceptance criterion 3 of #276 for the primitive subset.
        for p in CORE_PRIMITIVES
            @test RustCall.ffi_known(p)
        end
        @test RustCall.ffi_known("()")
    end

    @testset "scalars" begin
        @test RustCall.ffi_ccall_type("i32") === Int32
        @test RustCall.ffi_surface_type("u64") === UInt64
        @test RustCall.ffi_julia_symbol("usize") === :Csize_t
        @test RustCall.ffi_ccall_type("usize") === Csize_t
        @test RustCall.ffi_julia_symbol("isize") === :Cssize_t
        @test RustCall.ffi_julia_symbol("()") === :Cvoid
        @test RustCall.ffi_ownership("f64") === :none
        # 128-bit integers: known to `rustcall_core`, unknown to every Julia
        # table on `main`.
        @test RustCall.ffi_ccall_type("i128") === Int128
        @test RustCall.ffi_ccall_type("u128") === UInt128
        # Rust `char` is a code point in 4 bytes; Julia `Char` stores UTF-8 code
        # units left-aligned, so the C slot is `UInt32` and the surface value
        # must be converted, never reinterpreted.
        @test RustCall.ffi_ccall_type("char") === UInt32
        @test RustCall.ffi_surface_type("char") === Char
    end

    @testset "unknown types fail closed" begin
        @test RustCall.ffi_lookup("Vec<f64>") === nothing
        @test RustCall.ffi_lookup("HashMap<String, i32>") === nothing
        @test RustCall.ffi_known("MyStruct") == false
        @test RustCall.ffi_ccall_type("Vec<f64>") === nothing
        @test RustCall.ffi_julia_symbol("Vec<f64>") === nothing
        @test RustCall.ffi_ownership("Vec<f64>") === :unknown

        c = RustCall.ffi_return_contract("Vec<f64>")
        @test c.known == false
        @test c.abi === :unknown
        @test isempty(c.ccall_types)
        @test c.aggregate_type === nothing
        @test isempty(c.layout)
        @test c.ownership === :unknown
        @test occursin("not in the FFI contract", RustCall.ffi_describe("Vec<f64>"))
    end

    @testset "raw pointers" begin
        @test RustCall.ffi_ccall_type("*const u8") === Ptr{UInt8}
        @test RustCall.ffi_ccall_type("*mut i32") === Ptr{Int32}
        # Opaque pointee: the contract accepts the pointer (matching
        # `Type::Ptr(_) => true`) but degrades the pointee to `Cvoid`.
        @test RustCall.ffi_ccall_type("*mut Point") === Ptr{Cvoid}
        @test RustCall.ffi_return_contract("*mut Point").abi === :pointer
        @test RustCall.ffi_lookup("*const  u8").ccall_type === Ptr{UInt8}
    end

    @testset "raw-pointer ownership is not derivable from the spelling" begin
        # A generated constructor returns `Box::into_raw`
        # (deps/rustcall_core/src/codegen.rs:386-392) — Julia owns that
        # allocation and must free it. Another `*mut T` may point into memory
        # Rust keeps. Nothing in the spelling separates the two, so the default
        # is `:unknown`, never `:borrowed` (whose documented lifetime is only
        # the duration of the call).
        @test RustCall.ffi_return_contract("*mut Point").ownership === :unknown
        @test RustCall.ffi_return_contract("*const u8").ownership === :unknown
        @test RustCall.ffi_argument_contract("*mut Point").ownership === :unknown
        @test RustCall.ffi_ownership("*mut Point") === :unknown

        # A consumer that has the metadata states it.
        ctor = RustCall.ffi_return_contract("*mut Point";
                                            ownership = :transferred_to_julia,
                                            free_symbol = "Point_free")
        @test ctor.ownership === :transferred_to_julia
        @test ctor.free_symbol == "Point_free"
        @test ctor.abi === :pointer
        @test ctor.ccall_types == Type[Ptr{Cvoid}]
        @test ctor.known

        borrowed = RustCall.ffi_return_contract("*const u8"; ownership = :borrowed)
        @test borrowed.ownership === :borrowed
        @test borrowed.free_symbol === nothing

        # Validation: an owned value with no way to release it is refused.
        @test_throws ArgumentError RustCall.ffi_return_contract(
            "*mut Point"; ownership = :transferred_to_julia)
        @test_throws ArgumentError RustCall.ffi_return_contract(
            "*mut Point"; ownership = :owned_by_rust)
        @test_throws ArgumentError RustCall.ffi_return_contract(
            "*mut Point"; ownership = :not_a_tag, free_symbol = "Point_free")
        # `owner` supplies only the STRING release convention
        # (`<owner>_free_rust_string`, deps/rustcall_core/src/codegen.rs:633),
        # which is wrong for a pointer — the crate exports e.g. `Point_free`.
        # So it does not satisfy the requirement here.
        @test_throws ArgumentError RustCall.ffi_return_contract(
            "*mut Point"; ownership = :transferred_to_julia, owner = "Point")
        @test_throws ArgumentError RustCall.ffi_return_contract(
            "*mut Point"; ownership = :owned_by_rust, owner = "Point")
        # …but an explicit symbol does.
        @test RustCall.ffi_return_contract("*mut Point"; ownership = :transferred_to_julia,
                                           free_symbol = "Point_free").free_symbol ==
              "Point_free"
        # Tags that imply no release need no symbol.
        @test RustCall.ffi_return_contract("*mut Point"; ownership = :none).ownership === :none
    end

    @testset "strings: only the manifest says whether lowering happened" begin
        # On `main` the lowering is NOT uniform: `transform_simple_function`
        # (deps/rustcall_core/src/codegen.rs:53-58) only marks a free
        # `#[julia] fn ... -> String` signature `extern "C"` and
        # `generate_method_wrapper_crate` (:378, :414, :443) forwards the
        # original types; only `inline_method_wrapper` (:774-863) lowers to
        # `(ptr, len)` / `CRustString`. So a bare spelling must fail closed.
        for s in ("String", "&str", "str")
            @test RustCall.ffi_argument_contract(s).known == false
            @test RustCall.ffi_argument_contract(s).abi === :unknown
            @test RustCall.ffi_return_contract(s).known == false
            @test RustCall.ffi_return_contract(s).abi === :unknown
            @test RustCall.ffi_return_contract(s).ownership === :unknown
            @test isempty(RustCall.ffi_return_contract(s).ccall_types)
            @test RustCall.ffi_return_ccall_type(s) === nothing
            # Not even a single-slot answer, since there is no single slot.
            @test RustCall.ffi_ccall_type(s) === nothing
            # The Julia-visible type is still well defined; only the calling
            # convention is not.
            @test RustCall.ffi_surface_type(s) !== nothing
            @test RustCall.ffi_known(s)
        end

        # With the manifest column, the lowered form appears. A `ccall` has
        # exactly one return type, and the wrapper returns one `#[repr(C)]`
        # aggregate (`<fn>_RustCallOwnedString { ptr, len, cap }`,
        # codegen.rs:837-863), received as `CRustString`
        # (src/structs.jl:511-528) — so the return contract carries the
        # aggregate, not the word list.
        ret = RustCall.ffi_return_contract("String"; abi = "string")
        @test ret.known
        @test ret.abi === :ptr_len_cap
        @test ret.ccall_types == Type[RustCall.CRustString]
        @test ret.aggregate_type === RustCall.CRustString
        @test ret.layout == Type[Ptr{UInt8}, Csize_t, Csize_t]
        @test fieldtypes(RustCall.CRustString) == (Ptr{UInt8}, UInt, UInt)
        # Derived-but-unnameable: the ABI says the buffer is owned, but no owner
        # was given, so there is no symbol to free it with. The contract reports
        # `:unknown` rather than an unfreeable `:owned_by_rust` (#246, #249).
        @test ret.ownership === :unknown
        @test ret.free_symbol === nothing
        # Name the owner and it becomes owned, with the symbol.
        owned = RustCall.ffi_return_contract("String"; abi = "string", owner = "shout")
        @test owned.ownership === :owned_by_rust    # Julia must free it (#246)
        @test owned.free_symbol == "shout_free_rust_string"
        @test ret.surface_type === RustCall.RustString
        @test RustCall.ffi_return_ccall_type("String"; abi = "string") ===
              RustCall.CRustString

        # Arguments are the other half: the wrapper takes the words as separate
        # parameters, so the argument contract expands them and has no
        # aggregate.
        arg = RustCall.ffi_argument_contract("String"; abi = "string")
        @test arg.abi === :ptr_len
        @test arg.ccall_types == Type[Ptr{UInt8}, Csize_t]
        @test arg.aggregate_type === nothing
        @test arg.layout == Type[Ptr{UInt8}, Csize_t]
        @test arg.ownership === :owned_by_julia
        @test arg.surface_type === String

        sref = RustCall.ffi_return_contract("&str"; abi = "str")
        @test sref.abi === :ptr_len
        @test sref.ccall_types == Type[RustCall.CRustStr]      # one return type
        @test sref.aggregate_type === RustCall.CRustStr
        @test sref.layout == Type[Ptr{UInt8}, Csize_t]
        @test fieldtypes(RustCall.CRustStr) == (Ptr{UInt8}, UInt)
        @test sref.ownership === :borrowed
        @test RustCall.ffi_return_ccall_type("&str"; abi = "str") === RustCall.CRustStr
        @test RustCall.ffi_argument_contract("&str"; abi = "str").ccall_types ==
              Type[Ptr{UInt8}, Csize_t]
        @test RustCall.ffi_argument_contract("&str"; abi = "str").aggregate_type === nothing

        # The free symbol is per-owner, so it appears only when the caller names
        # the owner (`deps/rustcall_core/src/codegen.rs:633`).
        @test RustCall.ffi_free_symbol("shout") == "shout_free_rust_string"
        @test RustCall.ffi_return_contract("String"; abi = "string",
                                           owner = "shout").free_symbol ==
              "shout_free_rust_string"
        @test RustCall.ffi_return_contract("String"; abi = "string").free_symbol === nothing
        # Only an `:owned_by_rust` value has one.
        @test RustCall.ffi_return_contract("&str"; abi = "str",
                                           owner = "peek").free_symbol === nothing
        @test RustCall.ffi_return_contract("i32"; owner = "add").free_symbol === nothing

        # Single-word positions carry no aggregate and no layout at all.
        @test RustCall.ffi_return_contract("i32").aggregate_type === nothing
        @test isempty(RustCall.ffi_return_contract("i32").layout)
        @test RustCall.ffi_return_ccall_type("i32") === Int32
        @test RustCall.ffi_return_ccall_type("()") === Cvoid
        @test RustCall.ffi_return_ccall_type("Vec<f64>") === nothing
    end

    @testset "qualified primitive spellings" begin
        # `type_to_string` keeps the qualified spelling in the manifest and
        # `is_ffi_compatible_type` accepts it, so the contract must resolve it
        # or a fail-closed migration would reject a wrapper the extractor
        # deliberately generated.
        @test RustCall.ffi_normalize_spelling("core::primitive::i32") == "i32"
        @test RustCall.ffi_normalize_spelling("std::primitive::u8") == "u8"
        @test RustCall.ffi_ccall_type("core::primitive::i32") === Int32
        @test RustCall.ffi_ccall_type("std::primitive::u8") === UInt8
        @test RustCall.ffi_julia_symbol("core::primitive::usize") === :Csize_t
        @test RustCall.ffi_return_contract("std::primitive::f64").ccall_types == Type[Float64]
        @test RustCall.ffi_ccall_type("*mut core::primitive::i32") === Ptr{Int32}
        @test RustCall.ffi_ccall_type("  core::primitive::bool  ") === Bool

        # Rooted paths: `type_to_string` preserves the leading `::`.
        @test RustCall.ffi_normalize_spelling("::core::primitive::i32") == "i32"
        @test RustCall.ffi_normalize_spelling("::std::primitive::u8") == "u8"
        @test RustCall.ffi_ccall_type("::core::primitive::i32") === Int32
        @test RustCall.ffi_ccall_type("::std::primitive::u8") === UInt8
        @test RustCall.ffi_ccall_type("*mut ::core::primitive::f64") === Ptr{Float64}
        @test RustCall.ffi_return_contract("::std::primitive::bool").ccall_types ==
              Type[Bool]
        # …and the rooted form of an arbitrary crate path still fails closed.
        @test RustCall.ffi_lookup("::mycrate::i32") === nothing
        @test RustCall.ffi_normalize_spelling("::mycrate::i32") == "::mycrate::i32"
        @test RustCall.ffi_lookup("::core::primitive::Widget") === nothing

        # Negative: only those two prefixes. `rustcall_core` is laxer — it
        # matches on the last path segment alone, so it also accepts
        # `mycrate::i32`, where `i32` may be a user alias with a different
        # layout. The contract refuses to infer from an unqualified last
        # segment and fails closed instead; see FFI_PRIMITIVE_PATH_PREFIXES.
        @test core_is_ffi_compatible("mycrate::i32")     # `rustcall_core` says yes
        @test RustCall.ffi_normalize_spelling("mycrate::i32") == "mycrate::i32"
        @test RustCall.ffi_lookup("mycrate::i32") === nothing
        @test RustCall.ffi_lookup("core::primitive::i32::Foo") === nothing
        @test RustCall.ffi_normalize_spelling("core::primitive::foo::bar") ==
              "core::primitive::foo::bar"
        # A qualified spelling of a non-primitive is still not a primitive.
        @test RustCall.ffi_lookup("core::primitive::Widget") === nothing
    end

    @testset "julia_expr is a Julia AST, not a printed name" begin
        # `Symbol("Ptr{Int32}")` would splice into generated code as
        # `var"Ptr{Int32}"` — an undefined binding. Parametric types must be
        # `Expr(:curly, ...)`.
        @test RustCall.ffi_julia_symbol("*const *mut i32") == :(Ptr{Ptr{Int32}})
        @test RustCall.ffi_julia_symbol("*const u8") == :(Ptr{UInt8})
        @test RustCall.ffi_julia_symbol("*mut Point") == :(Ptr{Cvoid})
        @test RustCall.ffi_julia_symbol("*mut *const *mut f64") ==
              :(Ptr{Ptr{Ptr{Float64}}})
        @test RustCall.ffi_julia_symbol("*const *mut i32") isa Expr
        @test RustCall.ffi_julia_type("*const *mut i32") === Ptr{Ptr{Int32}}
        @test RustCall.ffi_julia_type("*mut *const *mut f64") === Ptr{Ptr{Ptr{Float64}}}
        @test RustCall.ffi_julia_type("Vec<f64>") === nothing

        # Plain names stay plain `Symbol`s.
        for s in ("i32", "usize", "()", "String", "char")
            @test RustCall.ffi_julia_symbol(s) isa Symbol
        end
        @test RustCall.ffi_julia_symbol("i32") === :Int32
        @test RustCall.ffi_julia_symbol("()") === :Cvoid

        # Every spelling the contract knows must render to something that
        # evaluates, in RustCall, to exactly its surface type.
        for s in vcat(ALL_SPELLINGS, ["*const *mut i32", "core::primitive::u8"])
            e = RustCall.ffi_julia_symbol(s)
            e === nothing && continue
            @test Core.eval(RustCall, e) === RustCall.ffi_julia_type(s)
            @test Core.eval(RustCall, e) === RustCall.ffi_surface_type(s)
        end

        # And the renderer itself.
        @test RustCall.ffi_type_expr(Int32) === :Int32
        @test RustCall.ffi_type_expr(Cvoid) === :Cvoid       # not :Nothing
        @test RustCall.ffi_type_expr(Ptr{Cvoid}) == :(Ptr{Cvoid})
        @test RustCall.ffi_type_expr(Ptr{Ptr{UInt8}}) == :(Ptr{Ptr{UInt8}})
    end

    @testset "nested raw pointers" begin
        @test RustCall.ffi_ccall_type("*const *mut i32") === Ptr{Ptr{Int32}}
        @test RustCall.ffi_ccall_type("*mut *mut u8") === Ptr{Ptr{UInt8}}
        @test RustCall.ffi_ccall_type("*mut *const *mut f64") === Ptr{Ptr{Ptr{Float64}}}
        @test RustCall.ffi_surface_type("*const *mut i32") === Ptr{Ptr{Int32}}
        @test RustCall.ffi_return_contract("*const *mut i32").ccall_types ==
              Type[Ptr{Ptr{Int32}}]
        @test RustCall.ffi_return_contract("*const *mut i32").abi === :pointer
        # An opaque pointee still degrades, at whatever depth it appears.
        @test RustCall.ffi_ccall_type("*mut *const Widget") === Ptr{Ptr{Cvoid}}
        # A multi-word pointee has no single-word C form, so it degrades too.
        @test RustCall.ffi_ccall_type("*const String") === Ptr{Cvoid}
    end

    @testset "void and scalar positions" begin
        @test RustCall.ffi_return_contract("()").abi === :void
        @test isempty(RustCall.ffi_return_contract("()").ccall_types)
        @test RustCall.ffi_argument_contract("f32").ccall_types == Type[Float32]
        @test RustCall.ffi_argument_contract("f32").ownership === :none
    end

    @testset "manifest abi column (#270 / PR #274)" begin
        # `""` defers to the Rust spelling.
        @test RustCall.ffi_manifest_abi_kind("", :argument) === nothing
        @test RustCall.ffi_manifest_abi_kind("", :return) === nothing
        @test RustCall.ffi_manifest_abi_kind("string", :argument) === :ptr_len
        @test RustCall.ffi_manifest_abi_kind("string", :return) === :ptr_len_cap
        @test RustCall.ffi_manifest_abi_kind("str", :argument) === :ptr_len
        @test RustCall.ffi_manifest_abi_kind("str", :return) === :ptr_len
        @test_throws ArgumentError RustCall.ffi_manifest_abi_kind("bytes", :return)
        @test_throws ArgumentError RustCall.ffi_manifest_abi_kind("", :sideways)

        # The column overrides the spelling, which is what makes the manifest
        # normative: an alias the table has never heard of still gets the right
        # ABI once the extractor labels it.
        c = RustCall.ffi_return_contract("MyAlias"; abi = "string", owner = "MyAlias")
        @test c.known
        @test c.abi === :ptr_len_cap
        @test c.ownership === :owned_by_rust
        # …including the aggregate shape of the return.
        @test c.ccall_types == Type[RustCall.CRustString]
        @test c.aggregate_type === RustCall.CRustString
        @test c.layout == Type[Ptr{UInt8}, Csize_t, Csize_t]
        @test RustCall.ffi_return_contract("MyAlias"; abi = "str").aggregate_type ===
              RustCall.CRustStr
        @test RustCall.ffi_argument_contract("Cow<'a, str>"; abi = "str").ccall_types ==
              Type[Ptr{UInt8}, Csize_t]
        # And it is the ONLY authority for the string spellings: without it
        # they are unknown, with it they lower (see the strings testset).
        @test RustCall.ffi_return_contract("String").abi === :unknown
        @test RustCall.ffi_return_contract("String"; abi = "string").abi === :ptr_len_cap
        @test RustCall.ffi_argument_contract("&str").abi === :unknown
        @test RustCall.ffi_argument_contract("&str"; abi = "str").abi === :ptr_len
    end

    @testset "ffi_slots" begin
        @test RustCall.ffi_slots(:ptr_len) == Type[Ptr{UInt8}, Csize_t]
        @test RustCall.ffi_slots(:ptr_len_cap) == Type[Ptr{UInt8}, Csize_t, Csize_t]
        @test isempty(RustCall.ffi_slots(:void))
        @test_throws ArgumentError RustCall.ffi_slots(:by_value)
    end

    @testset "ffi_aggregate_type" begin
        @test RustCall.ffi_aggregate_type(:ptr_len) === RustCall.CRustStr
        @test RustCall.ffi_aggregate_type(:ptr_len_cap) === RustCall.CRustString
        @test RustCall.ffi_aggregate_type(:by_value) === nothing
        @test RustCall.ffi_aggregate_type(:pointer) === nothing
        @test RustCall.ffi_aggregate_type(:void) === nothing
        @test RustCall.ffi_aggregate_type(:unknown) === nothing
        # The aggregates must match the word list they stand for.
        @test collect(fieldtypes(RustCall.CRustStr)) ==
              [Ptr{UInt8}, UInt] == [Ptr{UInt8}, Csize_t]
        @test length(fieldtypes(RustCall.CRustString)) == length(RustCall.ffi_slots(:ptr_len_cap))
    end

    # ========================================================================
    # Divergences between the five existing tables and the contract.
    #
    # Every `@test` below asserts what `main` does TODAY. None of them is a
    # statement about what the code should do.
    # ========================================================================

    @testset "one table covers every spelling" begin
        # There used to be five of these counts, one per table, and they all
        # disagreed. One is left: the contract covers everything except the
        # genuinely unsupported aggregate, which it refuses on purpose.
        covered = Dict(
            "ffi_contract" => count(RustCall.ffi_known, ALL_SPELLINGS),
        )
        @test covered["ffi_contract"] == length(ALL_SPELLINGS) - 1
    end

    @testset "divergence: i128 / u128 / char (#245 item 2)" begin
        # `rustcall_core` accepts these — a wrapper or accessor IS generated…
        for s in ("i128", "u128", "char")
            @test core_is_ffi_compatible(s)
            # …but every Julia table mistranslates them.
            # The contract knows all three.
            @test RustCall.ffi_known(s)
        end
        @test RustCall.ffi_surface_type("i128") === Int128
        @test RustCall.ffi_surface_type("u128") === UInt128
        # For `char` the disagreement is not just "missing": mapping Rust `char`
        # onto Julia `Char` bit-for-bit would be wrong, so the contract splits
        # the C slot (`UInt32`) from the surface type (`Char`).
        @test RustCall.ffi_ccall_type("char") !== RustCall.ffi_surface_type("char")
    end

    @testset "divergence: small integers missing from src/structs.jl (#245 item 2)" begin
        # `rust_to_julia_type_sym` knew 8 primitives, so a `#[julia]` struct field
        # of type `u16` became `:Any` in generated accessor code while the same
        # type in a free function became `:UInt16`. One table, one answer now.
        for s in ("i8", "i16", "u8", "u16", "i128", "u128", "usize", "isize", "char")
            @test RustCall.ffi_julia_symbol(s) !== nothing
            # A struct field accessor resolves the same concrete type a free
            # function does — `src/structs.jl` no longer has a table of its own.
            @test RustCall.ffi_return_type_or_throw(s, "", "S::f -> $s") !== Any
        end
        @test RustCall.ffi_julia_symbol("u16") === :UInt16
        @test RustCall.ffi_return_type_or_throw("u16", "", "S::f -> u16") === UInt16
    end

    @testset "divergence: usize / isize spelling (#245 item 2)" begin
        # Two tables spell the platform-sized integers with the C aliases and
        # one with the fixed-width names. Same type on every supported
        # platform, different spelling in generated code — and a real
        # divergence on any target where `Csize_t !== UInt64`.
        @test RustCall.ffi_julia_symbol("usize") === :Csize_t
        # Today these coincide; the test records the assumption.
        @test Csize_t === UInt64
        @test Cssize_t === Int64
    end

    @testset "the unit type resolves in both directions" begin
        # The argument-conversion table had no `()` entry, so a caller that
        # reached for it in return position got `nothing` and fell through to
        # the guess path. The contract answers in both directions (#276 B2).
        @test RustCall.ffi_argument_contract("()").known
        @test RustCall.ffi_argument_contract("()").abi === :void
        @test RustCall.ffi_return_contract("()").abi === :void
        @test RustCall.ffi_return_ccall_type("()") === Cvoid
        @test RustCall.ffi_julia_symbol("()") === :Cvoid
    end

    @testset "divergence: String / &str (#246)" begin
        # `rustcall_core` classifies both as *non*-FFI…
        @test core_is_non_ffi("String")
        @test core_is_non_ffi("&str")
        @test core_is_ffi_compatible("String") == false
        # …yet `rusttype_to_julia`, the sixth table, happily produced a type,
        # and `bare str` became a `Cstring` — the NUL-terminated pointer that
        # #246 identifies as the wrong shape for a Rust string. It is a shim
        # over the contract now, so both answer the same thing.
        @test RustCall.rusttype_to_julia("String") === RustCall.RustString
        @test RustCall.rusttype_to_julia("str") === RustCall.RustStr
        @test RustCall.rusttype_to_julia("str") === RustCall.ffi_surface_type("str")
        @test RustCall.rusttype_to_julia("*const u8") === Ptr{UInt8}
        # The contract says what neither of them says: the shape and the owner
        # — but only once the manifest says the wrapper lowered the string, so a
        # bare spelling still fails closed.
        @test RustCall.ffi_return_contract("String").known == false
        @test RustCall.ffi_return_contract("String"; abi = "string").abi === :ptr_len_cap
        @test RustCall.ffi_return_contract("String"; abi = "string",
                                           owner = "shout").ownership === :owned_by_rust
        @test RustCall.ffi_return_contract("&str"; abi = "str").ownership === :borrowed

        # All four generators — the inline and crate `Expr` flavours and their
        # two source-text counterparts — take the SAME branch, because they all
        # ask these two predicates rather than comparing `return_abi` strings,
        # reading `has_owned_string_helper`, or matching the Rust spelling.
        owned = RustCall.ffi_return_contract("String"; abi = "string", owner = "shout")
        borrowed = RustCall.ffi_return_contract("&str"; abi = "str", owner = "shout")
        @test RustCall.ffi_owned_string_return(owned)
        @test !RustCall.ffi_borrowed_string_return(owned)
        @test RustCall.ffi_borrowed_string_return(borrowed)
        @test !RustCall.ffi_owned_string_return(borrowed)
        @test owned.aggregate_type === RustCall.CRustString
        @test borrowed.aggregate_type === RustCall.CRustStr
        # A non-string return takes neither.
        plain = RustCall.ffi_return_contract("i32")
        @test !RustCall.ffi_owned_string_return(plain)
        @test !RustCall.ffi_borrowed_string_return(plain)
        # `Cstring` is gone from the string path: there is no `julia_to_c_type`
        # lowering of `RustString` / `RustStr` to a NUL-terminated pointer left.
        @test RustCall.julia_to_c_type(RustCall.RustString) !== Cstring
        @test RustCall.julia_to_c_type(RustCall.RustStr) !== Cstring
    end

    @testset "divergence: raw pointers (#245 item 2)" begin
        # `rustcall_core` accepts every raw pointer wholesale; no Julia table
        # has a pointer entry, so the pointer lands on the `:Any` / `nothing`
        # path in each of them.
        for s in ("*const u8", "*mut i32", "*mut c_void")
            @test core_is_ffi_compatible(s)
            @test RustCall.ffi_known(s)
        end
    end

    @testset "fail-closed, naming the signature (#245 item 1)" begin
        # `rust_to_julia_type_sym` used to answer `:Any` for anything it did not
        # know, which is indistinguishable from a real answer at the call site.
        # The contract answers `nothing`, and the generators raise.
        @test RustCall.ffi_julia_symbol("Vec<f64>") === nothing
        @test RustCall.ffi_return_contract("CompletelyMadeUp").known == false
        for s in ("Vec<f64>", "CompletelyMadeUp")
            ctx = "S::f() -> $s"
            err = try
                RustCall.ffi_return_type_or_throw(s, "", ctx; strict = :error)
                nothing
            catch e
                e
            end
            @test err isa RustCall.RustError
            @test occursin(ctx, sprint(showerror, err))
        end
    end

    @testset "one return decision: ffi_return_symbol_or_throw (#276 AC 2)" begin
        # Every return site — the `Expr` generators and the source-text
        # emitters alike — goes through this one function, so the two copies
        # cannot drift apart again.
        @test RustCall.ffi_return_symbol_or_throw("i32", "", "f() -> i32") === :Int32
        @test RustCall.ffi_return_symbol_or_throw("usize", "", "f() -> usize") === :Csize_t
        @test RustCall.ffi_return_symbol_or_throw("()", "", "f()") === :Cvoid
        @test RustCall.ffi_return_symbol_or_throw("i128", "", "f() -> i128") === :Int128
        @test RustCall.ffi_return_symbol_or_throw("*mut i32", "", "f()") == :(Ptr{Int32})
        # A return site gets the SURFACE spelling; `call_rust_function` lowers
        # it to the C slot and converts back, so the conversion lives in one
        # place. Rust `char` is where slot and surface differ.
        @test RustCall.ffi_return_symbol_or_throw("char", "", "f() -> char") === :Char
        @test RustCall.ffi_return_type_or_throw("char", "", "f() -> char") === Char
        @test RustCall.ccall_return_type(Char) === UInt32

        ctx = "mycrate::f(i32) -> Vec<f64>"
        # `:error` names the signature and the contract's verdict.
        err = try
            RustCall.ffi_return_symbol_or_throw("Vec<f64>", "", ctx; strict = :error)
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        @test occursin(ctx, sprint(showerror, err))
        @test occursin("not in the FFI contract", sprint(showerror, err))
        # `:warn` / `:none` fall back to the pre-#276 `Any`.
        @test RustCall.ffi_return_symbol_or_throw("Vec<f64>", "", ctx; strict = :none) === :Any
        @test_throws ArgumentError RustCall.ffi_return_symbol_or_throw(
            "Vec<f64>", "", ctx; strict = :nonsense)

        # A multi-word return has no single symbol: it carries an owner and a
        # free symbol, so callers must take `ffi_return_contract` instead.
        @test RustCall.ffi_return_symbol_or_throw("String", "string", ctx;
                                                  strict = :none) === :Any

        @test RustCall.FFI_STRICT[] in (:error, :warn, :none)
        @test RustCall.ffi_signature_context("f", ["i32", "String"], "u8") ==
              "f(i32, String) -> u8"
        @test RustCall.ffi_signature_context("m", ["i32"], ""; owner = "P") ==
              "P::m(i32) -> ()"
    end

    @testset "char converts in both directions, in one place (#245)" begin
        # Julia stores a `Char` as left-aligned UTF-8 code units, so its bit
        # pattern is not the code point: reinterpreting either way hands the
        # other side a different character.
        @test RustCall.ffi_char_code_point('A') === UInt32(0x41)
        @test RustCall.ffi_char_code_point('π') === UInt32(0x3c0)
        @test RustCall.ffi_char_code_point(0x41) === UInt32(0x41)
        @test RustCall.ffi_char_from_code_point(UInt32(0x3c0)) === 'π'
        @test RustCall.ffi_char_from_code_point(0x41) === 'A'
        # Round trip, including a non-BMP scalar.
        for c in ('a', 'π', '☃', '𝄞')
            @test RustCall.ffi_char_from_code_point(RustCall.ffi_char_code_point(c)) === c
            # …and the raw bits really are not the code point, which is the bug.
            c > '\x7f' && @test reinterpret(UInt32, c) != RustCall.ffi_char_code_point(c)
        end

        # A Rust `char` is always a Unicode scalar value; a slot that is not one
        # is refused rather than turned into an invalid `Char`.
        for bad in (0x110000, 0xd800, 0xdfff, 0xffffffff)
            @test_throws RustCall.RustError RustCall.ffi_char_from_code_point(bad)
        end
        @test_throws RustCall.RustError RustCall.ffi_char_code_point(0xd800)

        # One place: `ccall_return_type` / `convert_return` and their argument
        # counterparts, so no generated call site carries the conversion.
        @test RustCall.ccall_return_type(Char) === UInt32
        @test RustCall.convert_return(Char, UInt32(0x3c0)) === 'π'
        @test RustCall.ccall_arg_type(Char) === UInt32
        @test RustCall.convert_arg(Char, 'π') === UInt32(0x3c0)
        @test RustCall.is_supported_return_type(Char)
        @test RustCall.is_supported_arg_type(Char)

        # `ffi_slot_convert` is the run-time counterpart the generic path uses.
        @test RustCall.ffi_slot_convert(UInt32, 'π') === UInt32(0x3c0)
        @test RustCall.ffi_slot_convert(Int32, 7) === Int32(7)
        @test RustCall.ffi_slot_convert(Any, "x") == "x"
    end

    @testset "the return-type guess is gone (#245 item 1)" begin
        # `call_rust_function_infer` derived the RETURN type from the FIRST
        # ARGUMENT — `Float64` for `fn f(x: f64) -> i32`, `Cstring` for a string
        # argument (the ABI-broken path of #246), and `Int64` for everything
        # else. None of that is derivable from an argument, and reading a return
        # slot at the wrong width is undefined behaviour, not a fallback. It now
        # deprecation-warns and raises.
        for arg in (1.0, Int32(1), true, C_NULL, "s")
            @test_throws RustCall.RustError RustCall.call_rust_function_infer(C_NULL, arg)
        end
        @test_throws RustCall.RustError RustCall.call_rust_function_infer(C_NULL)
        err = try
            RustCall.call_rust_function_infer(C_NULL, 1.0)
            nothing
        catch e
            e
        end
        @test occursin("Annotate the call site", sprint(showerror, err))

        # The contract has no such path: an unknown return type has no type.
        @test RustCall.ffi_return_contract("i32").ccall_types == Type[Int32]
        @test RustCall.ffi_return_contract("").known == false
        # And `FFI_STRICT` now fails closed by default.
        @test RustCall.FFI_STRICT[] === :error
        @test_throws RustCall.RustError RustCall.ffi_return_symbol_or_throw(
            "Vec<f64>", "", "f() -> Vec<f64>")
    end


    @testset "by-value aggregates are opt-in (#245 item 3)" begin
        # `is_supported_arg_type(::Type{T}) = isbitstype(T)` and
        # `ccall_arg_type(::Type{T}) = T` accepted *any* isbits Julia struct as
        # a by-value argument, on the assumption that its layout matches the
        # Rust side's. Rust's default `repr(Rust)` layout is unspecified, so the
        # assumption holds only until a rustc upgrade reorders the fields — and
        # then it is silent corruption, not an error.

        # Scalars, pointers and singletons are not aggregates: their ABI is
        # their width, and there is no field order to get wrong.
        for T in (Int8, Int64, UInt128, Float32, Float64, Bool, Char,
                  Ptr{Cvoid}, Ptr{Float64}, Cstring, Csize_t)
            @test RustCall.ffi_is_aggregate(T) == false
            @test RustCall.ffi_by_value_allowed(T)
        end

        # RustCall's own `#[repr(C)]` mirrors carry the assertion already.
        for T in (RustCall.CRustString, RustCall.CRustStr, RustCall.CRustVec,
                  RustCall.CRustSlice, RustCall.CRustResult, RustCall.CRustOption)
            @test RustCall.ffi_is_aggregate(T)
            @test RustCall.ffi_by_value_registered(T)
        end
        # RustCall asserts the widening form for its own wrappers, which is
        # the deliberate case: `RustPtr{T}` is one pointer whatever `T` is.
        @test RustCall.ffi_by_value_layout(RustCall.CRustString) === :repr_c
        @test RustCall.ffi_by_value_layout(Rc245ByValue) === :unknown
        @test RustCall.ffi_by_value_registered(RustCall.RustPtr{Int32})
        @test RustCall.ffi_by_value_registered(RustCall.RustSlice{Float64})
        @test RustCall.ffi_by_value_registered(RustCall.CResultType{Int32, Int32})
        @test RustCall.ffi_by_value_registered(RustCall.COptionType{Float64})

        # The mirrors the wrapper generators emit carry the assertion in their
        # *supertype*, which needs no call at all. A user's own struct carries
        # it as a `ffi_by_value_layout` method, defined in the module that owns
        # the type — both are precompiled, which a mutated global would not be.
        @test isabstracttype(RustCall.FFIByValue)
        @test RustCall.ffi_by_value_allowed(Rc245Mirror)
        @test RustCall.ffi_by_value_registered(Rc245Mirror) == false
        @test RustCall.ffi_check_by_value(Rc245Mirror, Any[]) === nothing
        @test isbitstype(Rc245Mirror)   # a supertype does not change the layout

        # An arbitrary user struct is not allowed until someone says so.
        @test RustCall.ffi_is_aggregate(Rc245ByValue)
        @test RustCall.ffi_by_value_registered(Rc245ByValue) == false
        @test RustCall.ffi_by_value_allowed(Rc245ByValue) == false
        # Tuples are aggregates too — a tuple's parameters *are* its layout, so
        # registering one tuple type must not license another.
        @test RustCall.ffi_is_aggregate(Tuple{Int32, Float64})
        @test RustCall.ffi_by_value_allowed(Tuple{Int32, Float64}) == false

        # The macro form defines the method in the **calling** module, which is
        # what makes it precompile-safe for a type Julia owns — a `Tuple`,
        # whose `parentmodule` is `Core` and where the function form has no
        # home but RustCall (#245 review).
        try
            @test (@register_ffi_struct Rc245ByValueTwin) === Rc245ByValueTwin
            @test RustCall.ffi_by_value_allowed(Rc245ByValueTwin)
            @test RustCall._ffi_layout_method(Rc245ByValueTwin).module === @__MODULE__
            @test RustCall._ffi_layout_method(Rc245ByValueTwin).module !== RustCall
        finally
            @test RustCall.unregister_ffi_struct(Rc245ByValueTwin)
        end
        @test RustCall.ffi_by_value_allowed(Rc245ByValueTwin) == false

        try
            @test (@register_ffi_struct Tuple{Int8, Int8}) === Tuple{Int8, Int8}
            @test RustCall.ffi_by_value_allowed(Tuple{Int8, Int8})
            @test RustCall.ffi_by_value_allowed(Tuple{Int8, Int16}) == false
            # The function form would have put it in RustCall; the macro does
            # not, which is the whole point.
            @test RustCall._ffi_layout_method(Tuple{Int8, Int8}).module === @__MODULE__
        finally
            @test RustCall.unregister_ffi_struct(Tuple{Int8, Int8})
        end
        @test RustCall.ffi_by_value_allowed(Tuple{Int8, Int8}) == false

        # It refuses exactly what the function refuses, and says so as the
        # macro rather than as the function.
        macro_err = try
            @eval @register_ffi_struct $Rc245Pair
            nothing
        catch e
            e
        end
        @test macro_err isa ArgumentError ||
              (macro_err isa LoadError && macro_err.error isa ArgumentError)
        @test occursin("@register_ffi_struct", sprint(showerror, macro_err))
        @test_throws Exception (@eval @register_ffi_struct $Rc245Shape)
        @test_throws Exception (@eval @register_ffi_struct $Rc245Mutable)
        @test RustCall.ffi_by_value_allowed(Rc245Pair{Float64}) == false

        # The error names the type, its fields and the opt-in call to make.
        err = try
            RustCall.ffi_check_by_value(Int32, Any[Rc245ByValue])
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        msg = sprint(showerror, err)
        @test occursin("Rc245ByValue", msg)
        @test occursin("argument 1", msg)
        @test occursin("repr(C)", msg)
        @test occursin("RustCall.register_ffi_struct(", msg)
        @test occursin("RustStructInfo", msg)   # the generated-wrapper alternative
        @test occursin("x::Int32", msg)         # the fields it would have matched
        @test occursin("y::Float64", msg)

        # Registration is **concrete types only** (#245 review). Instantiations
        # of a parametric struct do not share a layout — a type parameter
        # changes field sizes, alignment and even ABI register classes — and
        # subtypes of an abstract family share even less, so a family-wide
        # assertion would license values nobody ever matched against a Rust
        # struct. That is the fail-open behaviour the opt-in exists to remove.
        for family in (Rc245Pair, Rc245Shape)
            err_family = try
                RustCall.register_ffi_struct(family)
                nothing
            catch e
                e
            end
            @test err_family isa ArgumentError
            @test occursin("register_ffi_struct($family)", sprint(showerror, err_family))
        end
        @test occursin("UnionAll", sprint(showerror, try
            RustCall.register_ffi_struct(Rc245Pair); catch e; e end))
        # An abstract *instantiation* is refused for the same reason.
        @test_throws ArgumentError RustCall.register_ffi_struct(Rc245Shape{Float64})
        @test RustCall.ffi_by_value_allowed(Rc245Square{Float64}) == false

        # The concrete registration is accepted, and says nothing about a
        # sibling instantiation.
        try
            RustCall.register_ffi_struct(Rc245Pair{Float64})
            @test RustCall.ffi_by_value_allowed(Rc245Pair{Float64})
            @test RustCall.ffi_by_value_allowed(Rc245Pair{Int8}) == false
            @test RustCall.ffi_by_value_allowed(Rc245Pair{Float32}) == false
            @test_throws RustCall.RustError RustCall.ffi_check_by_value(
                Int32, Any[Rc245Pair{Int8}])
            # Registering it again is idempotent: one method, one withdrawal.
            @test RustCall.register_ffi_struct(Rc245Pair{Float64}) === Rc245Pair{Float64}
        finally
            @test RustCall.unregister_ffi_struct(Rc245Pair{Float64})
        end
        @test RustCall.ffi_by_value_allowed(Rc245Pair{Float64}) == false
        # A withdrawal takes effect in the world that made it, not one later:
        # being stale-*true* here would be fail-open.
        @test RustCall.unregister_ffi_struct(Rc245Pair{Float64}) == false

        # RustCall's own covering assertions (`::Type{<:RustPtr}`) are the
        # package's claim about its own mirrors, not something
        # `register_ffi_struct` can produce — and not something
        # `unregister_ffi_struct` can delete by accident either, because it
        # only ever deletes the exact `Type{T}` method.
        @test RustCall.unregister_ffi_struct(RustCall.RustPtr{Int32}) == false
        @test RustCall.ffi_by_value_registered(RustCall.RustPtr{Int32})

        # A tuple is never widened: its parameters *are* its layout.
        try
            RustCall.register_ffi_struct(Tuple{Int32, Float64})
            @test RustCall.ffi_by_value_allowed(Tuple{Int32, Float64})
            @test RustCall.ffi_by_value_allowed(Tuple{Int32, Float32}) == false
            @test RustCall.ffi_by_value_allowed(Tuple{Int32}) == false
        finally
            @test RustCall.unregister_ffi_struct(Tuple{Int32, Float64})
        end

        # Return position is reported as such.
        ret_err = try
            RustCall.ffi_check_by_value(Rc245ByValue, Any[])
            nothing
        catch e
            e
        end
        @test ret_err isa RustCall.RustError
        @test occursin("the return type", sprint(showerror, ret_err))

        # `call_rust_function` is the runtime door every `@rust` call goes
        # through, and it refuses before a `ccall` is built — the pointer is
        # never dereferenced, so a null one is safe here. Both directions:
        # the aggregate as an argument, and as the return type.
        @test_throws RustCall.RustError RustCall.call_rust_function(
            C_NULL, Int32, Rc245ByValue(Int32(1), 2.0))
        @test_throws RustCall.RustError RustCall.call_rust_function(
            C_NULL, Rc245ByValue, Int32(1))
        @test_throws RustCall.RustError RustCall.call_rust_function(
            C_NULL, Int32, Type[Rc245ByValue], Rc245ByValue(Int32(1), 2.0))
        @test_throws RustCall.RustError RustCall.call_rust_function(
            C_NULL, Int32, Tuple{Rc245ByValue}, Rc245ByValue(Int32(1), 2.0))

        # Opting in makes exactly that type acceptable, and withdrawing the
        # assertion puts it back.
        try
            @test RustCall.register_ffi_struct(Rc245ByValue) === Rc245ByValue
            @test RustCall.ffi_by_value_registered(Rc245ByValue)
            @test RustCall.ffi_by_value_allowed(Rc245ByValue)
            @test RustCall.ffi_check_by_value(Int32, Any[Rc245ByValue]) === nothing
            # A different struct with the same fields is still refused: the
            # assertion is per type, not per shape.
            @test RustCall.ffi_by_value_allowed(Rc245ByValueTwin) == false
        finally
            @test RustCall.unregister_ffi_struct(Rc245ByValue)
        end
        @test RustCall.ffi_by_value_allowed(Rc245ByValue) == false
        @test RustCall.unregister_ffi_struct(Rc245ByValue) == false

        # The keyword exists so the call site states what it claims; there is
        # no layout to assert without `#[repr(C)]`, and a mutable struct is a
        # Julia heap object that cannot be copied into a register pair at all.
        @test_throws ArgumentError RustCall.register_ffi_struct(Rc245ByValue; repr_c = false)
        @test_throws ArgumentError RustCall.register_ffi_struct(Rc245Mutable)
        @test RustCall.ffi_by_value_allowed(Rc245ByValue) == false
    end

    @testset "a generated mirror survives precompilation (#245 review)" begin
        # A `register_ffi_struct` call in a generated `@rust_crate` module — or
        # in a `#[julia]` wrapper expanded inside a downstream package — mutates
        # a global that lives in *RustCall*. Julia does not replay a
        # dependency's global mutations when a package is loaded from its
        # precompile cache, so such a registration would hold in the session
        # that compiled the package and be gone in every later one: every
        # `Result`-returning wrapper would then fail in `call_rust_function`
        # before reaching Rust. `<: FFIByValue` is a property of the type, so
        # there is nothing to replay.

        # 1. The generators emit the supertype, and no registration call.
        res = string(RustCall.generate_c_result_struct_type("probe", :Int32, :Int32))
        opt = string(RustCall.generate_c_option_struct_type("probe", :Float64))
        for src in (res, opt)
            @test occursin("FFIByValue", src)
            @test !occursin("register_ffi_struct", src)
        end

        # 2. And so does the source-text emitter used for written-out bindings.
        sig = RustCall.RustFunctionSignature(
            "probe", ["a"], ["i32"], "Result<i32, i32>", false, String[];
            symbol = "rustcall_probe", return_kind = :result,
            ok_type = "i32", err_type = "i32")
        emitted = RustCall._emit_result_function_code(sig, "a", "Int32(a)")
        @test occursin("struct CResult_probe <: FFIByValue", emitted)
        @test !occursin("register_ffi_struct", emitted)

        # 3. The real thing: a package that both defines such a mirror **and**
        #    registers a struct of its own at top level, loaded in a *fresh*
        #    process from its precompile cache. Neither assertion may depend on
        #    the session that compiled the package.
        depot = mktempdir()
        pkgdir_ = joinpath(depot, "Rc245Mirror245", "src")
        mkpath(pkgdir_)
        write(joinpath(depot, "Rc245Mirror245", "Project.toml"), """
        name = "Rc245Mirror245"
        uuid = "4a1d5f2e-9b3c-4c7a-8d6e-1f2a3b4c5d6e"
        version = "0.1.0"

        [deps]
        RustCall = "$(Base.PkgId(RustCall).uuid)"
        """)
        write(joinpath(pkgdir_, "Rc245Mirror245.jl"), """
        module Rc245Mirror245
        import RustCall

        # A mirror the wrapper generators would have emitted.
        struct CResult_probe <: RustCall.FFIByValue
            is_ok::UInt8
            ok_value::Int32
            err_value::Int32
        end

        # ...and a user's own struct, registered the documented way: at top
        # level, next to the struct it is about.
        struct Pt
            x::Float64
            y::Float64
        end
        RustCall.register_ffi_struct(Pt)

        struct Pair2{T}
            a::T
            b::T
        end
        RustCall.register_ffi_struct(Pair2{Float64})

        # A type Julia owns: `parentmodule(Tuple{...})` is `Core`, so the
        # function form would define the method in RustCall — a cross-module
        # mutation of a dependency, which is not replayed from this package's
        # cache. The macro expands here and defines it here.
        RustCall.@register_ffi_struct Tuple{Int32, Float64}

        # ...and the macro is the right answer for an ordinary struct too.
        struct Macro3
            a::Int32
            b::Int32
            c::Int32
        end
        RustCall.@register_ffi_struct Macro3
        end
        """)
        try
            script = """
            using Rc245Mirror245, RustCall
            M = Rc245Mirror245
            print(RustCall.ffi_by_value_allowed(M.CResult_probe), " ",
                  RustCall.ffi_by_value_registered(M.CResult_probe), " ",
                  isbitstype(M.CResult_probe), " ",
                  RustCall.ffi_by_value_allowed(M.Pt), " ",
                  RustCall.ffi_by_value_allowed(M.Pair2{Float64}), " ",
                  RustCall.ffi_by_value_allowed(M.Pair2{Int8}), " ",
                  RustCall.ffi_by_value_allowed(Tuple{Int32, Float64}), " ",
                  RustCall.ffi_by_value_allowed(Tuple{Int32, Float32}), " ",
                  RustCall.ffi_by_value_allowed(M.Macro3))
            """
            project = pkgdir(RustCall)
            out = withenv("JULIA_LOAD_PATH" => string(project, Sys.iswindows() ? ";" : ":", depot,
                                                      Sys.iswindows() ? ";" : ":", "@stdlib")) do
                readchomp(`$(Base.julia_cmd()) --startup-file=no -e $script`)
            end
            # The mirror: allowed, *not* registered (its assertion is the
            # supertype), and still isbits — a supertype does not change the
            # layout. The user's struct: allowed, because
            # `register_ffi_struct` defined a `ffi_by_value_layout` method in
            # `Rc245Mirror245`, which its precompile cache carries. The
            # concrete parametric registration still licenses only itself. And
            # the macro's two — a `Tuple`, which the function form could only
            # have registered *in RustCall*, and an ordinary struct — come back
            # as well, still without licensing a sibling tuple.
            @test out == "true false true true true false true false true"
        finally
            rm(depot; recursive = true, force = true)
        end
    end

    @testset "ownership: the contract names the symbol generated code calls" begin
        # None of the five tables carried an ownership column at all, so nothing
        # in the pipeline recorded who frees a returned buffer: that is why
        # `String` returns leaked (#246) and why the drop symbol was chosen from
        # the Julia-side type tag rather than from the allocating library
        # (#249). The `owner`-derived `free_symbol` is now exactly the symbol
        # the generated wrapper passes to `_call_rust_owned_string`.
        @test RustCall.ffi_return_contract("String"; abi = "string",
                                           owner = "shout").free_symbol ==
              "shout_free_rust_string"
        @test RustCall.ffi_return_contract("String"; abi = "string",
                                           owner = "Point").free_symbol ==
              "Point_free_rust_string"
        @test RustCall.ffi_return_contract("String"; abi = "string",
                                           owner = "shout").ownership === :owned_by_rust
        @test RustCall.ffi_argument_contract("String"; abi = "string").ownership ===
              :owned_by_julia
        # The free symbol is per-function (`<fn>_free_rust_string`), so the
        # type-keyed table cannot name it unless the caller supplies the owner.
        @test RustCall.ffi_return_contract("String"; abi = "string").free_symbol === nothing
        # Scalars own nothing, which must stay distinguishable from "unknown".
        @test RustCall.ffi_return_contract("i64").ownership === :none
        @test RustCall.ffi_return_contract("Vec<f64>").ownership === :unknown
    end

    @testset "invariant: an owned position always names its free symbol" begin
        # A contract tagged :owned_by_rust / :transferred_to_julia must carry a
        # free_symbol — an owned value with no way to release it is the shape of
        # #246 and #249, so the contract reports :unknown (derived) or raises
        # (asserted) instead.
        cases = Any[]
        for s in ALL_SPELLINGS, dir in (:argument, :return), abi in ("", "string", "str")
            push!(cases, dir === :argument ?
                  RustCall.ffi_argument_contract(s; abi = abi) :
                  RustCall.ffi_return_contract(s; abi = abi))
            dir === :return || continue
            push!(cases, RustCall.ffi_return_contract(s; abi = abi, owner = "Owner"))
        end
        @test !isempty(cases)
        for c in cases
            if c.ownership in RustCall.FFI_OWNERSHIP_NEEDS_FREE
                @test c.free_symbol !== nothing
            end
        end
        # And the sweep really does exercise the owned branch.
        @test any(c -> c.ownership === :owned_by_rust, cases)
    end

    @testset "ownership tags: both owned tags release through free_symbol" begin
        # `:transferred_to_julia` does NOT mean "Julia frees it with its own
        # allocator": a `Box::into_raw` handle must be released by calling the
        # Rust export, so the Rust destructor runs on the allocating allocator
        # (#249). The two owned tags differ in WHEN, not HOW:
        #   :owned_by_rust        — released within the call (the wrapper copies,
        #                           then frees; src/structs.jl:511-523)
        #   :transferred_to_julia — the handle outlives the call and Julia frees
        #                           it later, from a finalizer
        @test :owned_by_rust in RustCall.FFI_OWNERSHIP_NEEDS_FREE
        @test :transferred_to_julia in RustCall.FFI_OWNERSHIP_NEEDS_FREE
        @test !(:borrowed in RustCall.FFI_OWNERSHIP_NEEDS_FREE)
        @test !(:owned_by_julia in RustCall.FFI_OWNERSHIP_NEEDS_FREE)
        @test !(:none in RustCall.FFI_OWNERSHIP_NEEDS_FREE)
        for tag in RustCall.FFI_OWNERSHIP_NEEDS_FREE
            @test tag in RustCall.FFI_OWNERSHIP_KINDS
            # Both require the symbol, and both keep it.
            @test_throws ArgumentError RustCall.ffi_return_contract("*mut Point";
                                                                    ownership = tag)
            c = RustCall.ffi_return_contract("*mut Point"; ownership = tag,
                                             free_symbol = "Point_free")
            @test c.ownership === tag
            @test c.free_symbol == "Point_free"
        end
    end

end
