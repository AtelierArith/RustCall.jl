# Component tests loaded by test_regressions.jl.

# ---------------------------------------------------------------------------
# #276 Phase B: the FFI contract is the only type decision. These are the
# regression tests for the three bugs that came out of having five of them.
# ---------------------------------------------------------------------------

# Fixture for "#245: an unregistered struct is not passed by value" — a `struct`
# needs module scope, so it cannot live inside the testset that uses it.
struct Rc245Vec2Julia
    x::Float64
    y::Float64
end

# #245: `rustcall_julia_core` accepts `i128`, `u128` and `char`, and generates a
# wrapper for them — but every Julia table stopped at 13 primitives, so the
# generated `ccall` slot was `Any` (or the `Int64` guess). Same for a `u16`
# struct field, which `src/ffi/structs.jl` read as `Any` while a free function read
# it as `UInt16`.
@testset "#245: every type rustcall_julia_core accepts crosses correctly" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        rust"""
        #[julia]
        pub fn rc245_add_i128(a: i128, b: i128) -> i128 { a + b }
        #[julia]
        pub fn rc245_add_u128(a: u128, b: u128) -> u128 { a + b }
        #[julia]
        pub fn rc245_upper(c: char) -> char { c.to_ascii_uppercase() }
        #[julia]
        pub struct Rc245Small { a: u16, b: i8, c: usize }
        impl Rc245Small {
            pub fn new(a: u16, b: i8, c: usize) -> Self { Self { a, b, c } }
        }
        """

        # 128-bit integers survive the boundary intact, which they cannot do
        # through an `Any` or `Int64` slot.
        #
        # Not on `x86_64-pc-windows-msvc`: MSVC has no native 128-bit integer,
        # so Rust and Julia disagree on how to pass one across `extern "C"`
        # there (rust-lang/rust#54341). The contract row is still right — the C
        # slot is a 128-bit integer — but no amount of Julia-side mapping makes
        # the two ABIs agree, so the round trip is only asserted where they do.
        if Sys.iswindows()
            @test_skip "i128 / u128 do not round-trip through the MSVC C ABI"
        else
            @test rc245_add_i128(Int128(1) << 100, Int128(3)) === (Int128(1) << 100) + 3
            @test rc245_add_u128(UInt128(1) << 120, UInt128(7)) === (UInt128(1) << 120) + 7
        end

        # Rust `char` travels as its C slot, a `UInt32` code point. It is
        # converted, never reinterpreted from Julia's left-aligned UTF-8 `Char`.
        @test rc245_upper('a') === 'A'
        @test rc245_upper('q') === 'Q'
        # The C slot is a `UInt32` code point and the surface value a `Char`;
        # the wrapper converts, and the raw bits of a non-ASCII `Char` are not
        # the code point, which is what made reinterpreting wrong.
        @test RustCall.ffi_ccall_type("char") === UInt32
        @test RustCall.ffi_surface_type("char") === Char
        @test rc245_upper('π') === 'π'
        @test reinterpret(UInt32, 'π') != RustCall.ffi_char_code_point('π')

        # Small integer and platform-sized struct fields read as themselves.
        small = Rc245Small(UInt16(65535), Int8(-3), UInt(9))
        @test small.a === UInt16(65535)
        @test small.b === Int8(-3)
        @test small.c === Csize_t(9)
    end
end

@testset "#245: an unannotated usize return is not the Int64 guess" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        code = "#[no_mangle] pub extern \"C\" fn rc245_usize_len() -> usize { 7 }"
        lib = RustCall._compile_and_load_rust(code, "test_regressions", 0)
        value = RustCall._rust_call_dynamic(lib, "rc245_usize_len")
        @test value === Csize_t(7)
        @test RustCall.get_function_return_type(lib, "rc245_usize_len") === Csize_t
    end
end

# #245: `is_supported_arg_type(::Type{T}) = isbitstype(T)` passed *any* isbits
# Julia struct to Rust by value, assuming its layout matched. Rust's default
# `repr(Rust)` layout is unspecified, so that is a claim only the user can make
# — and it is now one they have to make out loud.
@testset "#245: an unregistered struct is not passed by value" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        rust"""
        #[repr(C)]
        pub struct Rc245Vec2 { pub x: f64, pub y: f64 }

        #[no_mangle]
        pub extern "C" fn rc245_norm2(v: Rc245Vec2) -> f64 { v.x * v.x + v.y * v.y }
        """

        v = Rc245Vec2Julia(3.0, 4.0)
        @test RustCall.ffi_by_value_registered(Rc245Vec2Julia) == false

        err = try
            @rust rc245_norm2(v)::Float64
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        msg = sprint(showerror, err)
        @test occursin("Rc245Vec2Julia", msg)
        @test occursin("register_ffi_struct", msg)
        @test occursin("repr(C)", msg)

        # The opt-in is what makes it work, and it works.
        try
            RustCall.register_ffi_struct(Rc245Vec2Julia)
            @test (@rust rc245_norm2(v)::Float64) == 25.0
        finally
            RustCall.unregister_ffi_struct(Rc245Vec2Julia)
        end
        # ... and withdrawing the assertion closes the door again.
        @test_throws RustCall.RustError (@rust rc245_norm2(v)::Float64)
    end
end

# #245: the fail-closed contract error has to *reach* the caller.
# `_rust_call_dynamic` used to try return-type inference inside a `try` whose
# `catch` swallowed everything but `RustPanicError` — so a `RustError` from the
# type contract was replaced by the unrelated "no return type" message.
# Swallowing a fail-closed error is the fail-open pattern the contract exists
# to remove. (The inference step itself went with the LLVM IR path, #265; the
# guarantee that nothing between the snapshot and the call catches a contract
# error stays.)
@testset "#245: a contract error is not swallowed by return-type inference" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        code = """
        #[repr(C)]
        pub struct Rc245InferVec2 { pub x: f64, pub y: f64 }

        #[no_mangle]
        pub extern "C" fn rc245_infer_norm2(v: Rc245InferVec2) -> f64 { v.x * v.x + v.y * v.y }
        """
        lib = RustCall._compile_and_load_rust(code, "test_regressions", 0)
        v = Rc245Vec2Julia(3.0, 4.0)
        @test RustCall.ffi_by_value_registered(Rc245Vec2Julia) == false

        # Unannotated: the contract's refusal is what must come out, not a
        # generic "no return type" message from a catch that swallowed it.
        err = try
            RustCall._rust_call_dynamic(lib, "rc245_infer_norm2", v)
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        msg = sprint(showerror, err)
        @test occursin("Rc245Vec2Julia", msg)
        @test occursin("register_ffi_struct", msg)
        # ...*not* the generic fallback message the swallowing catch produced.
        @test !occursin("has no return type", msg)

        # Annotated, the same refusal comes through the typed door too.
        @test_throws RustCall.RustError RustCall._rust_call_typed(
            lib, "rc245_infer_norm2", Float64, v)
    end
end

# #245: a `::T` annotation that disagrees with the manifest used to win, and
# the ccall then read the return slot as a `T` it is not — `@rust f(x)::Float64`
# on a `-> i32` returned the 32 bits reinterpreted as a `Float64`. An annotation
# supplies a return type RustCall does not know; it does not override one it
# does.
@testset "#245: a return annotation that contradicts the manifest is an error" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        rust"""
        #[julia]
        pub fn rc245_mismatch(a: i32) -> i32 { a * 2 }
        """

        # The manifest's own answer still works, annotated or not.
        @test rc245_mismatch(Int32(21)) === Int32(42)
        @test (@rust rc245_mismatch(Int32(21))) === Int32(42)
        @test (@rust rc245_mismatch(Int32(21))::Int32) === Int32(42)

        err = try
            @rust rc245_mismatch(Int32(21))::Float64
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        msg = sprint(showerror, err)
        # Both types are named, so the message says what to change.
        @test occursin("Float64", msg)
        @test occursin("Int32", msg)
        @test occursin("rc245_mismatch", msg)
        @test occursin("#245", msg)

        # A same-width lie is refused too: this is not about whether the bits
        # fit, it is about how the return slot is read.
        @test_throws RustCall.RustError (@rust rc245_mismatch(Int32(21))::Float32)
        @test_throws RustCall.RustError (@rust rc245_mismatch(Int32(21))::UInt32)

        # The manifest records the **C slot**; an annotation names the
        # **surface** type. For Rust `char` those differ — the slot is a
        # `UInt32` code point, the surface a `Char` — and `::Char` was a
        # correct call before this check existed. It has to stay one (#245
        # review): agreement is "same ccall return slot", not "same type".
        rust"""
        #[julia]
        pub fn rc245_upper_char(c: char) -> char { c.to_ascii_uppercase() }
        """
        @test rc245_upper_char('a') === 'A'
        @test (@rust rc245_upper_char('a')::Char) === 'A'
        # The slot itself is still accepted — it is the same call, read raw.
        @test (@rust rc245_upper_char('a')::UInt32) === UInt32('A')
        # Unannotated, the `@rust` path uses what the manifest recorded, which
        # is the slot: it yields the code point. That is unchanged by this PR —
        # the generated `#[julia]` wrapper above is the surface-typed door —
        # and it is exactly why `::Char` has to keep working.
        @test (@rust rc245_upper_char('q')) === UInt32('Q')
        # ...and a type that lowers to a *different* slot is not.
        @test_throws RustCall.RustError (@rust rc245_upper_char('a')::Int32)
        @test_throws RustCall.RustError (@rust rc245_upper_char('a')::Float64)

        # The rule, stated directly.
        @test RustCall._return_annotation_agrees(Char, UInt32)
        @test RustCall._return_annotation_agrees(UInt32, UInt32)
        @test RustCall._return_annotation_agrees(Bool, UInt8)
        @test RustCall._return_annotation_agrees(Cvoid, Nothing)
        @test !RustCall._return_annotation_agrees(Int32, UInt32)
        @test !RustCall._return_annotation_agrees(Float64, Int64)

        # Aliases are the same type to `===`, so they never trip the check.
        @test RustCall._check_return_annotation(
            RustCall.resolve_call_target(RustCall.get_current_library(),
                                         "rc245_mismatch"),
            "rc245_mismatch", Int32) === nothing

        # A snapshot that records nothing still accepts any annotation — that
        # is what an annotation is for, and the whole `@rust f(x)::T` surface
        # depends on it.
        blank = RustCall.CallTarget(C_NULL, C_NULL, C_NULL, Ref(true), C_NULL,
                                    "no-such-lib", nothing, nothing, 0)
        @test RustCall._snapshot_return_type(blank) === nothing
        @test RustCall._check_return_annotation(blank, "rc245_unrecorded", Int32) === nothing
        @test RustCall._check_return_annotation(blank, "rc245_unrecorded", Float64) === nothing
    end
end
