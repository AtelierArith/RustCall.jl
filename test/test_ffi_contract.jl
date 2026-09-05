# Tests for the single source of truth of the FFI type contract
# (`src/ffi_contract.jl`, issue #276 Phase A).
#
# Two jobs:
#
#  1. test the new table and its API directly;
#  2. **enumerate the disagreements** between the five type tables that exist on
#     `main` and the new one. Phase A migrates no call site, so the divergence
#     tests below assert the *current* (in several cases wrong) behaviour and
#     name the issue each one belongs to. When Phase B moves a call site onto
#     the contract, the corresponding `@test` here is what must be flipped —
#     which makes these the regression tests for #245, #246 and #249.

using Test
using RustCall

# ----------------------------------------------------------------------------
# The five tables, as callable probes
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

# `is_ffi_compatible_type`: a path type whose last segment is a primitive, the
# empty tuple, or *any* raw pointer (`Type::Ptr(_) => true`).
function core_is_ffi_compatible(s::AbstractString)
    s == "()" && return true
    _is_ptr_spelling(s) && return true
    startswith(s, "&") && return false
    head = first(split(s, '<'))
    return head in CORE_PRIMITIVES
end

# `is_non_ffi_type`: the known container list, plus every reference.
function core_is_non_ffi(s::AbstractString)
    startswith(s, "&") && return true
    head = first(split(s, '<'))
    return head in CORE_NON_FFI
end

# Tables 2-5 are Julia functions and can be called directly.
table_conversion(s) = RustCall._rust_type_to_julia_conversion_type(s)      # src/julia_functions.jl:193
table_symbol(s) = RustCall._rust_type_to_julia_type_symbol(s)              # src/julia_functions.jl:220
table_ruststr(s) = RustCall._rust_primitive_to_julia_type(s)               # src/ruststr.jl:519
table_structs(s) = RustCall.rust_to_julia_type_sym(s)                      # src/structs.jl:665

# The union of the spellings any of the five tables (or the contract) has an
# opinion about.
const ALL_SPELLINGS = vcat(
    CORE_PRIMITIVES,
    ["()", "String", "&str", "str", "*const u8", "*mut i32", "*mut c_void", "Vec<f64>"],
)

@testset "FFI contract (#276 Phase A)" begin

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
        @test RustCall.ffi_return_contract("*mut Point").ownership === :borrowed
        @test RustCall.ffi_lookup("*const  u8").ccall_type === Ptr{UInt8}
    end

    @testset "strings: the ABI depends on direction" begin
        ret = RustCall.ffi_return_contract("String")
        @test ret.abi === :ptr_len_cap
        @test ret.ccall_types == Type[Ptr{UInt8}, Csize_t, Csize_t]
        @test ret.ownership === :owned_by_rust      # Julia must free it (#246)
        @test ret.surface_type === RustCall.RustString

        arg = RustCall.ffi_argument_contract("String")
        @test arg.abi === :ptr_len
        @test arg.ccall_types == Type[Ptr{UInt8}, Csize_t]
        @test arg.ownership === :owned_by_julia
        @test arg.surface_type === String

        sref = RustCall.ffi_return_contract("&str")
        @test sref.abi === :ptr_len
        @test sref.ccall_types == Type[Ptr{UInt8}, Csize_t]
        @test sref.ownership === :borrowed
        @test RustCall.ffi_argument_contract("&str").ccall_types == Type[Ptr{UInt8}, Csize_t]
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
        c = RustCall.ffi_return_contract("MyAlias"; abi = "string")
        @test c.known
        @test c.abi === :ptr_len_cap
        @test c.ownership === :owned_by_rust
        @test RustCall.ffi_argument_contract("Cow<'a, str>"; abi = "str").ccall_types ==
              Type[Ptr{UInt8}, Csize_t]
        # And it agrees with the spelling when both are present.
        @test RustCall.ffi_return_contract("String"; abi = "string").abi ===
              RustCall.ffi_return_contract("String").abi
        @test RustCall.ffi_argument_contract("&str"; abi = "str").abi ===
              RustCall.ffi_argument_contract("&str").abi
    end

    @testset "ffi_slots" begin
        @test RustCall.ffi_slots(:ptr_len) == Type[Ptr{UInt8}, Csize_t]
        @test RustCall.ffi_slots(:ptr_len_cap) == Type[Ptr{UInt8}, Csize_t, Csize_t]
        @test isempty(RustCall.ffi_slots(:void))
        @test_throws ArgumentError RustCall.ffi_slots(:by_value)
    end

    # ========================================================================
    # Divergences between the five existing tables and the contract.
    #
    # Every `@test` below asserts what `main` does TODAY. None of them is a
    # statement about what the code should do.
    # ========================================================================

    @testset "divergence: no table covers every spelling" begin
        # A quick census, so a table gaining an entry shows up as a failure here
        # rather than silently.
        covered = Dict(
            "julia_functions/conversion" => count(s -> table_conversion(s) !== nothing, ALL_SPELLINGS),
            "julia_functions/symbol" => count(s -> table_symbol(s) !== nothing, ALL_SPELLINGS),
            "ruststr/primitive" => count(s -> table_ruststr(s) !== nothing, ALL_SPELLINGS),
            "structs/type_sym" => count(s -> table_structs(s) !== :Any, ALL_SPELLINGS),
            "ffi_contract" => count(RustCall.ffi_known, ALL_SPELLINGS),
        )
        @test covered["julia_functions/conversion"] == 13
        @test covered["julia_functions/symbol"] == 14
        @test covered["ruststr/primitive"] == 14
        @test covered["structs/type_sym"] == 10
        # The contract covers everything except the genuinely unsupported
        # aggregate, which it refuses on purpose.
        @test covered["ffi_contract"] == length(ALL_SPELLINGS) - 1
    end

    @testset "divergence: i128 / u128 / char (#245 item 2)" begin
        # `rustcall_core` accepts these — a wrapper or accessor IS generated…
        for s in ("i128", "u128", "char")
            @test core_is_ffi_compatible(s)
            # …but every Julia table mistranslates them.
            @test table_conversion(s) === nothing
            @test table_symbol(s) === nothing
            @test table_ruststr(s) === nothing
            @test table_structs(s) === :Any        # fail-open: `Any` in a ccall
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
        # `rust_to_julia_type_sym` knows 8 primitives. A `#[julia]` struct field
        # of type `u16` therefore becomes `:Any` in generated accessor code,
        # while the same type in a free function becomes `:UInt16`.
        for s in ("i8", "i16", "u8", "u16", "i128", "u128", "usize", "isize", "char")
            @test table_structs(s) === :Any
            @test table_symbol(s) !== :Any
        end
        @test table_symbol("u16") === :UInt16
        @test RustCall.ffi_julia_symbol("u16") === :UInt16
    end

    @testset "divergence: usize / isize spelling (#245 item 2)" begin
        # Two tables spell the platform-sized integers with the C aliases and
        # one with the fixed-width names. Same type on every supported
        # platform, different spelling in generated code — and a real
        # divergence on any target where `Csize_t !== UInt64`.
        @test table_conversion("usize") === :Csize_t
        @test table_symbol("usize") === :Csize_t
        @test table_ruststr("usize") === UInt64
        @test table_structs("usize") === :Any
        @test RustCall.ffi_julia_symbol("usize") === :Csize_t
        # Today these coincide; the test records the assumption.
        @test Csize_t === UInt64
        @test Cssize_t === Int64
    end

    @testset "divergence: the unit type" begin
        # `_rust_type_to_julia_conversion_type` has no `()` entry (it is an
        # argument-conversion table), the other three do. A caller that uses the
        # conversion table for a return position gets `nothing` and falls
        # through to the guess path.
        @test table_conversion("()") === nothing
        @test table_symbol("()") === :Cvoid
        @test table_ruststr("()") === Cvoid
        @test table_structs("()") === :Cvoid
        @test RustCall.ffi_julia_symbol("()") === :Cvoid
    end

    @testset "divergence: String / &str (#246)" begin
        # Only `src/structs.jl` maps the string types at all.
        @test table_structs("String") === :RustString
        @test table_structs("&str") === :RustStr
        @test table_conversion("String") === nothing
        @test table_symbol("String") === nothing
        @test table_ruststr("String") === nothing
        @test table_conversion("&str") === nothing
        @test table_symbol("&str") === nothing
        @test table_ruststr("&str") === nothing
        # `rustcall_core` classifies both as *non*-FFI…
        @test core_is_non_ffi("String")
        @test core_is_non_ffi("&str")
        @test core_is_ffi_compatible("String") == false
        # …yet `rusttype_to_julia`, the sixth table, happily produces a type,
        # and `bare str` becomes a `Cstring` — the NUL-terminated pointer that
        # #246 identifies as the wrong shape for a Rust `String`.
        @test RustCall.rusttype_to_julia("String") === RustCall.RustString
        @test RustCall.rusttype_to_julia("str") === Cstring
        @test table_structs("str") === :Any
        # The contract says what neither of them says: the shape and the owner.
        @test RustCall.ffi_return_contract("String").abi === :ptr_len_cap
        @test RustCall.ffi_return_contract("String").ownership === :owned_by_rust
        @test RustCall.ffi_return_contract("&str").ownership === :borrowed
    end

    @testset "divergence: raw pointers (#245 item 2)" begin
        # `rustcall_core` accepts every raw pointer wholesale; no Julia table
        # has a pointer entry, so the pointer lands on the `:Any` / `nothing`
        # path in each of them.
        for s in ("*const u8", "*mut i32", "*mut c_void")
            @test core_is_ffi_compatible(s)
            @test table_conversion(s) === nothing
            @test table_symbol(s) === nothing
            @test table_ruststr(s) === nothing
            @test table_structs(s) === :Any
            @test RustCall.ffi_known(s)
        end
    end

    @testset "divergence: fail-open vs fail-closed (#245 item 1)" begin
        # `rust_to_julia_type_sym` answers `:Any` for anything it does not know,
        # which is indistinguishable from a real answer at the call site.
        @test table_structs("Vec<f64>") === :Any
        @test table_structs("CompletelyMadeUp") === :Any
        # The contract answers `nothing`, which a caller cannot mistake for one.
        @test RustCall.ffi_julia_symbol("Vec<f64>") === nothing
        @test RustCall.ffi_return_contract("CompletelyMadeUp").known == false
    end

    @testset "divergence: the return-type guess (#245 item 1)" begin
        # `call_rust_function_infer` (src/codegen.jl:304) derives the RETURN
        # type from the FIRST ARGUMENT, defaulting to `Int64`. Read out of the
        # code the `@generated` body emits, so the guess is visible without
        # calling into a library.
        function guessed_return(argtype)
            ci = Base.code_lowered(RustCall.call_rust_function_infer, (Ptr{Cvoid}, argtype))[1]
            # `:(Core.tuple(_2, <ret_type>))`
            return ci.code[2].args[end]
        end
        @test guessed_return(Float64) === Float64   # `fn f(x: f64) -> i32` read as Float64
        @test guessed_return(Int32) === Int32
        @test guessed_return(Bool) === Bool
        @test guessed_return(Ptr{Cvoid}) === Int64  # the silent default
        @test guessed_return(String) === Cstring    # the ABI-broken path of #246
        # The contract has no such path: an unknown return type has no type.
        @test RustCall.ffi_return_contract("i32").ccall_types == Type[Int32]
        @test RustCall.ffi_return_contract("").known == false
    end

    @testset "divergence: ownership is unrepresented (#246, #249)" begin
        # None of the five tables carries an ownership column at all: each maps
        # a spelling to a bare Julia type, so nothing in the pipeline records
        # who frees a returned buffer. That absence is why `String` returns leak
        # (#246) and why the drop symbol is chosen from the Julia-side type tag
        # rather than from the allocating library (#249).
        @test table_structs("String") === :RustString   # a type, no owner
        @test RustCall.ffi_return_contract("String").ownership === :owned_by_rust
        @test RustCall.ffi_argument_contract("String").ownership === :owned_by_julia
        # The free symbol is per-function (`<fn>_free_rust_string`), so the
        # type-keyed table cannot name it yet; the field exists for Phase B.
        @test RustCall.ffi_return_contract("String").free_symbol === nothing
        # Scalars own nothing, which must stay distinguishable from "unknown".
        @test RustCall.ffi_return_contract("i64").ownership === :none
        @test RustCall.ffi_return_contract("Vec<f64>").ownership === :unknown
    end

    @testset "no existing table was changed" begin
        # Phase A is additive. If any of these change, a call site was migrated
        # and the divergence tests above must be revisited.
        @test length(RustCall.RUST_TO_JULIA_TYPE_MAP) == 26
        @test table_symbol("i32") === :Int32
        @test table_conversion("i32") === :Int32
        @test table_ruststr("i32") === Int32
        @test table_structs("i32") === :Int32
    end
end
