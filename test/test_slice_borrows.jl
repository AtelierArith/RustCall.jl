using Test, RustCall

const SLICE570_SOURCE =
    """
//! ```cargo
//! [dependencies]
//! num-complex = "0.4"
//! ```
#[julia]
pub fn slice_sum570(xs: &[f64]) -> f64 { xs.iter().sum() }
#[julia]
pub fn slice_address570(xs: &[f64]) -> usize { xs.as_ptr() as usize }
#[julia]
pub fn slice_shared570(xs: &[f64], ys: &[f64]) -> f64 { xs.iter().sum::<f64>() + ys.iter().sum::<f64>() }
#[julia]
pub fn slice_transform570(xs: &[f64], ys: &mut [f64]) -> Result<(), String> {
    if xs.len() != ys.len() { return Err("length mismatch".into()); }
    for (x,y) in xs.iter().zip(ys) { *y = *x * 2.0; }
    Ok(())
}
#[julia]
pub fn slice_scale570(xs: &mut [f64]) { for x in xs { *x *= 2.0; } }
#[julia]
pub fn slice_err570(xs: &mut [f64]) -> Result<(), String> {
    if !xs.is_empty() { xs[0] = 123.0; }
    Err("changed before Err".into())
}
#[julia]
pub fn slice_panic570(xs: &mut [f64]) {
    if !xs.is_empty() { xs[0] = 456.0; }
    panic!("changed before panic");
}
#[julia]
pub fn slice_callback570(xs: &mut [f64], callback: extern "C" fn() -> i32) -> f64 {
    if !xs.is_empty() { xs[0] += 1.0; }
    callback();
    xs.iter().sum()
}
#[julia]
pub fn slice_byte_alias570(xs: &[f64], ys: &mut [u8]) -> usize { xs.len() + ys.len() }
#[julia]
pub fn slice_string_alias570(xs: &str, ys: &mut [u8]) -> usize { xs.len() + ys.len() }
#[julia]
pub fn slice_complex570(xs: &[num_complex::Complex<f64>], ys: &mut [num_complex::Complex<f64>]) {
    for (x,y) in xs.iter().zip(ys) { *y = num_complex::Complex::new(x.re * 2.0, -x.im); }
}
#[julia]
pub fn slice_complex32_570(xs: &[num_complex::Complex32]) -> f32 { xs.iter().map(|z| z.re).sum() }
#[julia]
pub fn slice_option570(xs: &[f64]) -> Option<f64> { xs.first().copied() }
#[julia]
pub fn slice_text570(xs: &[f64]) -> String { xs.len().to_string() }
#[julia]
pub fn slice_label570(_xs: &[f64]) -> &'static str { "slice" }
#[julia]
pub struct SliceCtor570 { factor: f64 }
#[julia]
impl SliceCtor570 {
    #[julia]
    pub fn from_slice(xs: &[f64]) -> Self { Self { factor: xs.iter().sum() } }
    #[julia]
    pub fn factor(&self) -> f64 { self.factor }
}
#[julia]
pub struct SliceFallibleCtor570 { factor: f64 }
#[julia]
impl SliceFallibleCtor570 {
    #[julia]
    pub fn from_slice(xs: &[f64]) -> Result<Self, i32> { Ok(Self { factor: xs.iter().sum() }) }
    #[julia]
    pub fn factor(&self) -> f64 { self.factor }
}
#[julia]
#[repr(C)]
pub struct SliceOwner570 { factor: f64, padding: f64 }
#[julia]
impl SliceOwner570 {
    #[julia]
    pub fn new(factor: f64) -> Self { Self { factor, padding: 0.0 } }
    #[julia]
    pub fn apply(&self, xs: &mut [f64]) { for x in xs { *x *= self.factor; } }
    #[julia]
    pub fn total(xs: &[f64]) -> f64 { xs.iter().sum() }
    #[julia]
    pub fn text(&self, xs: &[f64]) -> String { xs.len().to_string() }
    #[julia]
    pub fn label(&self, _xs: &[f64]) -> &'static str { "slice" }
    #[julia]
    pub fn checked(&self, xs: &[f64]) -> Result<f64, i32> { Ok(xs.iter().sum::<f64>() * self.factor) }
    #[julia]
    pub fn optional(&self, xs: &[f64]) -> Option<f64> { xs.first().copied() }
    #[julia]
    pub fn duplicate(&self, xs: &[f64]) -> Result<Self, i32> { Ok(Self { factor: self.factor + xs.len() as f64, padding: 0.0 }) }
    #[julia]
    pub fn copy_slice(&self, xs: &[f64]) -> Self { Self { factor: self.factor + xs.len() as f64, padding: 0.0 } }
    #[julia]
    pub fn static_text(xs: &[f64]) -> String { xs.len().to_string() }
}
""" * join((
        "#[julia] pub fn slice_len_$(T)570(xs: &[$T]) -> usize { xs.len() }\n" *
        "#[julia] pub fn slice_first_$(T)570(xs: &[$T]) -> $T { xs.first().copied().unwrap_or(0 as $T) }\n"
        for T in (
            "i8",
            "u8",
            "i16",
            "u16",
            "i32",
            "u32",
            "i64",
            "u64",
            "isize",
            "usize",
            "f32",
            "f64",
        )
    ))

const SLICE570_LIB = Core.eval(
    @__MODULE__,
    Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), SLICE570_SOURCE),
)

@testset "slice manifest defines representation, length and access (#570)" begin
    manifest = RustCall.extract_manifest(SLICE570_SOURCE; mode = "inline")
    sigs = Dict(s.name => s for s in RustCall.manifest_function_signatures(manifest))
    transform = sigs["slice_transform570"]
    @test transform.arg_abis == ["slice", "slice_mut"]
    @test transform.arg_slice_elements == ["f64", "f64"]
    @test transform.arg_slice_lengths == ["usize", "usize"]
    complex = sigs["slice_complex570"]
    @test complex.arg_slice_elements == ["complex64", "complex64"]
    @test sigs["slice_complex32_570"].arg_slice_elements == ["complex32"]
    c = RustCall.ffi_argument_contract(
        "opaque spelling";
        abi = "slice_mut",
        slice_element = "f64",
        slice_length = "usize",
    )
    @test c.known && c.ccall_types == Type[Ptr{Float64}, Csize_t]
    @test c.ownership === :borrowed
    @test_throws ArgumentError RustCall.ffi_argument_contract("&[f64]"; abi = "slice")
    @test_throws ArgumentError RustCall.ffi_argument_contract(
        "&[f64]";
        abi = "slice",
        slice_element = "bool",
        slice_length = "usize",
    )
    @test_throws ArgumentError RustCall.ffi_argument_contract(
        "&[f64]";
        abi = "slice",
        slice_element = "f64",
        slice_length = "u32",
    )
end

@testset "slice empty/nonempty layouts and exact noncopying storage (#570)" begin
    xs = [1.0, 2.0, 3.0]
    @test slice_sum570(xs) == 6.0
    @test slice_sum570(Float64[]) == 0.0
    @test slice_address570(Float64[]) != 0
    @test slice_address570(xs) == UInt(pointer(xs))
    @test slice_shared570(xs, xs) == 12.0
    ys = zeros(3)
    @test RustCall.is_ok(slice_transform570(xs, ys))
    @test ys == [2.0, 4.0, 6.0]
    @test RustCall.is_ok(slice_transform570(Float64[], Float64[]))
    matrix = reshape(collect(1.0:12.0), 3, 4)
    column = view(matrix, :, 2)
    @test slice_address570(column) == UInt(pointer(column))
    slice_scale570(column)
    @test matrix[:, 2] == [8.0, 10.0, 12.0]
    z = ComplexF64[1+2im, 3-4im]
    out = zeros(ComplexF64, 2)
    slice_complex570(z, out)
    @test out == ComplexF64[2-2im, 6+4im]
    @test slice_complex32_570(ComplexF32[1+2im, 3-4im]) == 4.0f0
    for (rust, T) in (
        ("i8", Int8),
        ("u8", UInt8),
        ("i16", Int16),
        ("u16", UInt16),
        ("i32", Int32),
        ("u32", UInt32),
        ("i64", Int64),
        ("u64", UInt64),
        ("isize", Int),
        ("usize", UInt),
        ("f32", Float32),
        ("f64", Float64),
    )
        f = getfield(@__MODULE__, Symbol("slice_len_$(rust)570"))
        @test f(T[1, 2]) == 2
        @test f(T[]) == 0
        first_value = getfield(@__MODULE__, Symbol("slice_first_$(rust)570"))
        @test first_value(T[3, 7]) === T(3)
        @test first_value(T[]) === T(0)
    end
    @test_throws ArgumentError slice_sum570(Float32[1, 2])
    @test_throws ArgumentError slice_sum570(Int[1, 2])
    @test_throws ArgumentError slice_sum570(reshape(xs, 1, 3))
    @test_throws ArgumentError slice_sum570(view(xs, 1:2:3))
    @test_throws ArgumentError slice_sum570(view(xs, 3:-1:1))
    @test_throws ArgumentError slice_sum570(pointer(xs))
    @test_throws ArgumentError RustCall._ffi_slice_byte_count(typemax(Int), 8)
    @test_throws ArgumentError RustCall._ffi_slice_byte_count(-1, 8)
    bytes = zeros(UInt8, 32)
    GC.@preserve bytes begin
        # Julia itself refuses an unsafe_wrap with this alignment, so test
        # the same pointer validation used by the wrapper directly.
        @test_throws ArgumentError RustCall._ffi_slice_span(
            Ptr{Float64}(pointer(bytes) + 1),
            1,
        )
        @test_throws ArgumentError RustCall._ffi_slice_span(Ptr{Float64}(0), 1)
        @test_throws ArgumentError RustCall._ffi_slice_span(
            Ptr{Float64}(typemax(UInt) - 7),
            2,
        )
    end
end

@testset "slice overlap checks cover identical, partial and reinterpreted ranges (#570)" begin
    xs = collect(1.0:8.0)
    original = copy(xs)
    @test_throws ArgumentError slice_transform570(xs, xs)
    @test_throws ArgumentError slice_transform570(view(xs, 1:3), view(xs, 3:5))
    @test_throws ArgumentError slice_transform570(view(xs, 3:5), view(xs, 1:3))
    @test_throws ArgumentError slice_byte_alias570(xs, reinterpret(UInt8, xs))
    @test xs == original
    @test RustCall.is_ok(slice_transform570(view(xs, 1:3), view(xs, 4:6)))
    @test xs[4:6] == original[1:3] .* 2
    @test slice_shared570(view(xs, 1:3), view(xs, 2:4)) == sum(xs[1:3]) + sum(xs[2:4])
    text = "slice alias"
    GC.@preserve text begin
        bytes = unsafe_wrap(Vector{UInt8}, pointer(text), sizeof(text); own = false)
        @test_throws ArgumentError slice_string_alias570(text, bytes)
    end
    @test text == "slice alias"
end

@testset "slice direct writes persist on Err, panic and callback exception (#570)" begin
    xs = [1.0, 2.0]
    r = slice_err570(xs)
    @test RustCall.is_err(r)
    @test r.value == "changed before Err"
    @test xs == [123.0, 2.0]
    @test_throws RustCall.RustPanicError slice_panic570(xs)
    @test xs == [456.0, 2.0]
    @test_throws ErrorException slice_callback570(xs, () -> error("callback rejection"))
    @test xs == [457.0, 2.0]
    untouched = zeros(1)
    @test RustCall.is_err(slice_transform570(xs, untouched))
    @test untouched == zeros(1)
    # Explicit staging keeps its existing success-only copy-back semantics.
    before = copy(xs)
    @test_throws RustCall.RustPanicError RustCall.with_numeric_buffer(
        xs;
        write = true,
    ) do ptr, len
        staged = unsafe_wrap(Vector{Float64}, ptr, Int(len); own = false)
        slice_panic570(staged)
    end
    @test xs == before
end

@testset "slice owners remain rooted under callback GC pressure (#570)" begin
    callback = () -> begin
        for _ = 1:4
            zeros(UInt8, 100_000)
            GC.gc()
        end
        Int32(0)
    end
    # The only owner is the generated wrapper's local, and the Rust function
    # reads again after Julia has forced collection inside the call.
    for _ = 1:8
        @test slice_callback570([1.0, 2.0, 3.0], callback) == 7.0
    end
end

@testset "slice borrowed mode has no temporary proportional to input size (#570)" begin
    small, large = ones(2), ones(100_000)
    for _ = 1:3
        slice_scale570(small)
        slice_scale570(large)
    end
    # Compare the same specialization after warm-up. A hidden input/output
    # temporary would cost at least 800 kB for the large buffer.
    small_bytes = @allocated slice_scale570(small)
    large_bytes = @allocated slice_scale570(large)
    @test large_bytes <= small_bytes + 4096
    @test large_bytes < 16_384
end

@testset "slice methods share the same borrow contract (#570)" begin
    owner = SliceOwner570(3.0)
    xs = [1.0, 2.0]
    apply(owner, xs)
    @test xs == [3.0, 6.0]
    @test total(SliceOwner570, xs) == 9.0
    @test_throws ArgumentError apply(owner, view(xs, 2:-1:1))
    GC.@preserve owner begin
        # The slice starts inside the receiver, beyond its first byte. Only
        # Rust knows the full object extent; refuse before making references.
        interior = unsafe_wrap(
            Vector{Float64},
            Ptr{Float64}(Ptr{UInt8}(owner.ptr) + sizeof(Float64)),
            1;
            own = false,
        )
        @test_throws RustCall.RustPanicError apply(owner, interior)
        @test interior[1] == 0.0
    end
    @test text(owner, xs) == "2"
    @test label(owner, xs) == "slice"
    @test RustCall.unwrap(checked(owner, xs)) == 27.0
    @test RustCall.unwrap(optional(owner, xs)) == 3.0
    @test static_text(SliceOwner570, xs) == "2"
    for copy in (RustCall.unwrap(duplicate(owner, xs)), copy_slice(owner, xs))
        output = [1.0]
        apply(copy, output)
        @test output == [5.0]
        finalize(copy)
    end
    ctor = SliceCtor570(xs)
    fallible = RustCall.unwrap(SliceFallibleCtor570(xs))
    @test factor(ctor) == 9.0
    @test factor(fallible) == 9.0
    @test RustCall.unwrap(slice_option570(xs)) == 3.0
    @test slice_text570(xs) == "2"
    @test slice_label570(xs) == "slice"
    foreach(finalize, (owner, ctor, fallible))
end

@testset "slice crate and persisted bindings share the contract (#570)" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "src"))
        runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
        write(
            joinpath(dir, "Cargo.toml"),
            """
[package]
name = "slice_borrows570"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib"]
[dependencies]
num-complex = "0.4"
rustcall_julia_macros = { path = "$runtime" }
""",
        )
        write(
            joinpath(dir, "src", "lib.rs"),
            replace(
                SLICE570_SOURCE,
                "#[julia]" => "use rustcall_julia_macros::julia;\n#[julia]";
                count = 1,
            ),
        )
        bindings = @rust_crate dir
        output = joinpath(dir, "WrittenSlices.jl")
        RustCall.write_bindings_to_file(
            dir,
            output;
            output_module_name = "WrittenSlices570",
        )
        sandbox = Module(:SliceSandbox570)
        Base.include(sandbox, output)
        written = Base.invokelatest(getfield, sandbox, :WrittenSlices570)
        modules = (getfield(bindings, :module_ref), written)
        call(mod, fn, args...) =
            Base.invokelatest(Base.invokelatest(getfield, mod, fn), args...)
        try
            for mod in modules
                xs, ys = [1.0, 2.0], zeros(2)
                @test RustCall.is_ok(call(mod, :slice_transform570, xs, ys))
                @test ys == [2.0, 4.0]
                @test call(mod, :slice_address570, xs) == UInt(pointer(xs))
                @test_throws ArgumentError call(mod, :slice_transform570, xs, xs)
                @test_throws ArgumentError call(mod, :slice_sum570, Float32[1])
                @test_throws RustCall.RustPanicError call(mod, :slice_panic570, ys)
                @test ys[1] == 456.0
                z = ComplexF64[1+2im]
                out = zeros(ComplexF64, 1)
                call(mod, :slice_complex570, z, out)
                @test out == ComplexF64[2-2im]
                owner = call(mod, :SliceOwner570, 3.0)
                call(mod, :apply, owner, xs)
                @test xs == [3.0, 6.0]
                @test call(mod, :text, owner, xs) == "2"
                @test call(mod, :label, owner, xs) == "slice"
                @test RustCall.unwrap(call(mod, :checked, owner, xs)) == 27.0
                @test RustCall.unwrap(call(mod, :optional, owner, xs)) == 3.0
                @test call(
                    mod,
                    :static_text,
                    Base.invokelatest(getfield, mod, :SliceOwner570),
                    xs,
                ) == "2"
                for copy in (
                    RustCall.unwrap(call(mod, :duplicate, owner, xs)),
                    call(mod, :copy_slice, owner, xs),
                )
                    output = [1.0]
                    call(mod, :apply, copy, output)
                    @test output == [5.0]
                    finalize(copy)
                end
                ctor = call(mod, :SliceCtor570, xs)
                fallible = RustCall.unwrap(call(mod, :SliceFallibleCtor570, xs))
                @test call(mod, :factor, ctor) == 9.0
                @test call(mod, :factor, fallible) == 9.0
                @test RustCall.unwrap(call(mod, :slice_option570, xs)) == 3.0
                @test call(mod, :slice_text570, xs) == "2"
                @test call(mod, :slice_label570, xs) == "slice"
                foreach(finalize, (owner, ctor, fallible))
            end
        finally
            for mod in modules
                RustCall.unload_library(
                    Base.invokelatest(getfield, mod, :_LIB_NAME);
                    close = true,
                )
            end
        end
    end
end

@testset "slice lifetimes refuse retention and unsupported representations (#570)" begin
    for source in (
        "#[julia] pub fn retained(xs: &'static [f64]) -> usize { xs.len() }",
        "#[julia] pub fn retained<'a: 'static>(xs: &'a [f64]) -> usize { xs.len() }",
        "#[julia] pub fn retained<'a>(xs: &'a [f64]) -> &'a f64 { &xs[0] }",
        "#[julia] pub fn retained(xs: &[f64]) -> &f64 { &xs[0] }",
        "#[julia] pub fn retained(xs: &[bool]) -> usize { xs.len() }",
        "#[julia] pub fn retained(xs: &[char]) -> usize { xs.len() }",
        "#[julia] pub fn retained<T>(xs: &[T]) -> usize { xs.len() }",
    )
        manifest = RustCall.extract_manifest(source; mode = "inline")
        sig = only(RustCall.manifest_function_signatures(manifest))
        @test RustCall._rust_refuses(sig.skip_reason)
        report = RustCall.inline_boundary_report(source; io = devnull)
        @test any(
            x -> x.item == "retained" && x.position == "entry point",
            report.unsupported,
        )
    end
end

@testset "slice producer requirements exclude symbols with no emitted wrapper (#570)" begin
    scalar = RustCall.RustFunctionSignature(
        "scalar",
        ["x"],
        ["f64"],
        "f64",
        false,
        String[];
        symbol = "rustcall_Generic570_new",
    )
    slice(name; generic = false, reason = "") = RustCall.RustFunctionSignature(
        name,
        ["xs"],
        ["&[f64]"],
        "usize",
        generic,
        generic ? ["T"] : String[];
        symbol = "rustcall_$name",
        skip_reason = reason,
        arg_abis = ["slice"],
        arg_slice_elements = ["f64"],
        arg_slice_lengths = ["usize"],
    )
    method = RustCall.RustMethod(
        "new",
        true,
        false,
        ["xs"],
        ["&[f64]"],
        "Self";
        symbol = "rustcall_Generic570_new",
        arg_abis = ["slice"],
        arg_slice_elements = ["f64"],
        arg_slice_lengths = ["usize"],
    )
    generic_owner = RustCall.RustStructInfo(
        "Generic570",
        ["T"],
        [method],
        "",
        Tuple{String,String}[],
        true,
        Dict{String,Bool}(),
    )
    info = RustCall.CrateInfo(
        "filter570",
        "",
        "0.1.0",
        RustCall.DependencySpec[],
        [
            scalar,
            slice("allowed"),
            slice("generic"; generic = true),
            slice("refused"; reason = "slice_signature"),
        ],
        [generic_owner],
        String[],
    )
    @test RustCall._slice_arg_symbols(info) == ("rustcall_allowed",)
end
