using Test, RustCall

# `Option<&[T]>` / `Option<&mut [T]>` are lowered to an `i32` presence tag
# followed by the same typed pointer and `usize` length a required slice uses;
# the shim rebuilds a call-scoped optional slice (issue #619). `nothing` is
# absence; a real empty array is `Some` with length zero.

const OPTIONAL_SLICE619_SOURCE =
    """
//! ```cargo
//! [dependencies]
//! num-complex = "0.4"
//! ```
#[julia]
pub fn opt_slice_sum619(xs: Option<&[f64]>) -> f64 {
    xs.map_or(-1.0, |v| v.iter().sum())
}

#[julia]
pub fn opt_slice_present619(xs: Option<&[f64]>) -> bool { xs.is_some() }

#[julia]
pub fn opt_slice_len619(xs: Option<&[f64]>) -> usize {
    xs.map_or(usize::MAX, |v| v.len())
}

#[julia]
pub fn opt_slice_fill619(xs: Option<&mut [f64]>, delta: f64) -> usize {
    match xs {
        Some(v) => {
            for x in v.iter_mut() { *x += delta; }
            v.len()
        }
        None => 0,
    }
}

#[julia]
pub fn opt_slice_text619(xs: Option<&[f64]>) -> String {
    xs.map_or_else(|| "none".to_string(), |v| v.len().to_string())
}

#[julia]
pub fn opt_slice_result619(xs: Option<&[f64]>) -> Result<usize, String> {
    xs.map(|v| v.len()).ok_or_else(|| "missing slice".to_string())
}

#[julia]
pub fn opt_slice_option619(xs: Option<&[f64]>) -> Option<f64> {
    xs.and_then(|v| v.first().copied())
}

#[julia]
pub fn opt_slice_write_then_err619(xs: Option<&mut [f64]>) -> Result<(), String> {
    if let Some(v) = xs {
        if !v.is_empty() { v[0] = 99.0; }
    }
    Err("changed before Err".into())
}

#[julia]
pub fn opt_slice_complex619(xs: Option<&[num_complex::Complex<f64>]>) -> f64 {
    xs.map_or(0.0, |v| v.iter().map(|z| z.re + z.im).sum())
}

#[julia]
pub fn opt_slice_complex32_619(xs: Option<&[num_complex::Complex32]>) -> f32 {
    xs.map_or(0.0, |v| v.iter().map(|z| z.re).sum())
}

#[julia]
pub fn opt_slice_mixed619(value: Option<&str>, scale: Option<f64>, xs: Option<&[f64]>) -> String {
    format!("{} {} {}",
        value.unwrap_or("none"),
        scale.map(|s| s.to_string()).unwrap_or_else(|| "none".to_string()),
        xs.map_or(usize::MAX, |v| v.len()))
}

#[julia]
pub fn opt_slice_pair619(a: Option<&[f64]>, b: Option<&mut [f64]>) -> f64 {
    let sum = a.map_or(0.0, |v| v.iter().sum::<f64>());
    if let Some(v) = b { for x in v.iter_mut() { *x += sum; } }
    sum
}

#[julia]
pub struct OptSliceBag619 { values: Vec<f64> }

#[julia]
impl OptSliceBag619 {
    #[julia]
    pub fn new619(values: &[f64]) -> Self { Self { values: values.to_vec() } }

    #[julia]
    pub fn absorb619(&mut self, xs: Option<&[f64]>) -> usize {
        match xs {
            Some(v) => { self.values.extend_from_slice(v); self.values.len() }
            None => self.values.len(),
        }
    }

    #[julia]
    pub fn total619(&self) -> f64 { self.values.iter().sum() }

    #[julia]
    pub fn scale_into619(&self, xs: Option<&mut [f64]>) -> usize {
        match xs {
            Some(v) => {
                for (x, own) in v.iter_mut().zip(self.values.iter()) { *x = *own; }
                v.len()
            }
            None => 0,
        }
    }
}
"""

const OPTIONAL_SLICE619_LIB = Core.eval(
    @__MODULE__,
    Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), OPTIONAL_SLICE619_SOURCE),
)

@testset "optional slice manifest defines presence, pointer and length (#619)" begin
    manifest = RustCall.extract_manifest(OPTIONAL_SLICE619_SOURCE; mode = "inline")
    sigs = Dict(s.name => s for s in RustCall.manifest_function_signatures(manifest))
    fill = sigs["opt_slice_fill619"]
    @test fill.arg_abis == ["option_slice_mut", ""]
    @test fill.arg_slice_elements == ["f64", ""]
    @test fill.arg_slice_lengths == ["usize", ""]
    sum = sigs["opt_slice_sum619"]
    @test sum.arg_abis == ["option_slice"]
    @test sum.arg_slice_elements == ["f64"]
    @test sum.arg_slice_lengths == ["usize"]
    @test sigs["opt_slice_complex619"].arg_slice_elements == ["complex64"]
    @test sigs["opt_slice_complex32_619"].arg_slice_elements == ["complex32"]
    @test all(isempty(skip_reason) for skip_reason in (s.skip_reason for s in values(sigs)))

    c = RustCall.ffi_argument_contract(
        "Option<&[f64]>";
        abi = "option_slice",
        slice_element = "f64",
        slice_length = "usize",
    )
    @test c.known
    @test c.abi === :ptr_len
    @test c.ccall_types == Type[Int32, Ptr{Float64}, Csize_t]
    @test c.surface_type == Union{Nothing, AbstractVector{Float64}}
    @test c.ownership === :borrowed
    cm = RustCall.ffi_argument_contract(
        "Option<&mut [f64]>";
        abi = "option_slice_mut",
        slice_element = "f64",
        slice_length = "usize",
    )
    @test cm.ccall_types == Type[Int32, Ptr{Float64}, Csize_t]
    @test_throws ArgumentError RustCall.ffi_argument_contract(
        "Option<&[f64]>"; abi = "option_slice", slice_element = "f64")
    @test_throws ArgumentError RustCall.ffi_argument_contract(
        "Option<&[f64]>"; abi = "option_slice", slice_element = "f64", slice_length = "u32")
    @test_throws ArgumentError RustCall.ffi_argument_contract(
        "Option<&[f64]>"; abi = "option_slice", slice_element = "bool", slice_length = "usize")

    fill_sig = fill
    @test RustCall._uses_slice_ffi(fill_sig)
    @test RustCall._uses_slice_ffi(sum)
    @test RustCall._uses_string_ffi(sum)
end

@testset "inline optional slice arguments (#619)" begin
    # Absence and emptiness are distinct.
    @test opt_slice_sum619(nothing) == -1.0
    @test opt_slice_sum619(Float64[]) == 0.0
    @test opt_slice_sum619([1.0, 2.0, 3.0]) == 6.0
    @test opt_slice_present619(nothing) === false
    @test opt_slice_present619(Float64[]) === true
    @test opt_slice_len619(nothing) == typemax(UInt)
    @test opt_slice_len619(Float64[]) == 0
    @test opt_slice_len619([1.0, 2.0]) == 2

    # A mutable optional slice writes the caller's storage.
    xs = [1.0, 2.0]
    @test opt_slice_fill619(nothing, 5.0) == 0
    @test xs == [1.0, 2.0]
    @test opt_slice_fill619(xs, 2.5) == 2
    @test xs == [3.5, 4.5]
    @test opt_slice_fill619(Float64[], 9.0) == 0

    # String, Result and Option returns keep working next to the new ABI.
    @test opt_slice_text619(nothing) == "none"
    @test opt_slice_text619([1.0]) == "1"
    @test RustCall.unwrap(opt_slice_result619([1.0, 2.0])) == 2
    missing = opt_slice_result619(nothing)
    @test RustCall.is_err(missing) && missing.value == "missing slice"
    @test RustCall.unwrap(opt_slice_option619([7.0])) == 7.0
    @test opt_slice_option619(nothing).value === nothing

    # A returned Err still leaves the direct write visible, as for required
    # mutable slices.
    err_xs = [1.0]
    @test RustCall.is_err(opt_slice_write_then_err619(err_xs))
    @test err_xs == [99.0]

    # The whole required-slice element vocabulary is available.
    @test opt_slice_complex619(nothing) == 0.0
    @test opt_slice_complex619(ComplexF64[1 + 2im, 3 + 4im]) == 10.0
    @test opt_slice_complex32_619(nothing) == 0.0f0
    @test opt_slice_complex32_619(ComplexF32[1 + 2im]) == 1.0f0

    # Optional slices compose with the other optional argument forms.
    @test opt_slice_mixed619(nothing, nothing, nothing) == "none none $(typemax(UInt))"
    @test opt_slice_mixed619("x", 2.5, [1.0]) == "x 2.5 1"

    # Overlap checks include optional slices (shared/shared may alias).
    shared = [1.0, 2.0]
    @test opt_slice_pair619(shared, nothing) == 3.0
    @test opt_slice_pair619(nothing, shared) == 0.0
    @test_throws ArgumentError opt_slice_pair619(shared, shared)
    # Two empty borrows of the same array carry no bytes and may alias.
    empty = Float64[]
    @test opt_slice_pair619(empty, empty) == 0.0

    # Only `nothing` and a contiguous vector of the exact element type are
    # accepted, before Rust is entered.
    @test_throws ArgumentError opt_slice_sum619(Some([1.0]))
    @test_throws ArgumentError opt_slice_sum619(missing)
    @test_throws ArgumentError opt_slice_sum619(Float32[1, 2])
    @test_throws ArgumentError opt_slice_sum619(Int[1, 2])
    @test_throws ArgumentError opt_slice_sum619(reshape([1.0, 2.0], 1, 2))
    @test_throws ArgumentError opt_slice_sum619(view([1.0, 2.0, 3.0], 1:2:3))
    @test_throws ArgumentError opt_slice_fill619(pointer(xs), 1.0)

    # Struct methods take the same lowering.
    bag = OptSliceBag619([1.0, 2.0])
    @test absorb619(bag, nothing) == 2
    @test absorb619(bag, [3.0]) == 3
    @test total619(bag) == 6.0
    out = zeros(3)
    @test scale_into619(bag, nothing) == 0
    @test out == zeros(3)
    @test scale_into619(bag, out) == 3
    @test out == [1.0, 2.0, 3.0]

    report = RustCall.inline_boundary_report(OPTIONAL_SLICE619_SOURCE; io = devnull)
    @test isempty(report.unsupported)
end

@testset "optional slice refusals (#619)" begin
    for source in (
        "#[julia] pub fn retained(xs: Option<&[bool]>) -> usize { xs.map_or(0, |v| v.len()) }",
        "#[julia] pub fn retained(xs: Option<&[char]>) -> usize { xs.map_or(0, |v| v.len()) }",
        "#[julia] pub fn retained(xs: Option<&[Vec<f64>]>) -> usize { xs.map_or(0, |v| v.len()) }",
        "#[julia] pub fn retained(xs: Option<&'static [f64]>) -> usize { xs.map_or(0, |v| v.len()) }",
        "#[julia] pub fn retained<'a: 'static>(xs: Option<&'a [f64]>) -> usize { xs.map_or(0, |v| v.len()) }",
        "#[julia] pub fn retained<'a>(xs: Option<&'a [f64]>) -> &'a [f64] { xs.unwrap_or(&[]) }",
        "#[julia] pub fn retained(xs: Option<Vec<f64>>) -> usize { xs.map_or(0, |v| v.len()) }",
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
    # An arbitrary struct element is refused too.
    source = """
        #[julia]
        pub struct NotAnElement619 { pub value: f64 }

        #[julia]
        pub fn retained(xs: Option<&[NotAnElement619]>) -> usize {
            xs.map_or(0, |v| v.len())
        }
        """
    manifest = RustCall.extract_manifest(source; mode = "inline")
    retained = only(filter(s -> s.name == "retained",
                           RustCall.manifest_function_signatures(manifest)))
    @test RustCall._rust_refuses(retained.skip_reason)
    # Generic optional slices are refused at the generic signature, not
    # treated as an unsupported optional owner.
    generic = RustCall.extract_manifest(
        "#[julia] pub fn retained<T>(xs: Option<&[T]>) -> usize { xs.map_or(0, |v| v.len()) }";
        mode = "inline",
    )
    sig = only(RustCall.manifest_function_signatures(generic))
    @test startswith(sig.skip_reason, "slice_signature")
end

function _write_optional_slice_crate(path; macro_path)
    mkpath(joinpath(path, "src"))
    macro_dep = "rustcall_julia_macros = { path = \"$(RustCall.escape_toml_string(macro_path))\" }"
    write(joinpath(path, "Cargo.toml"), """
        [package]
        name = "optional_slice_facade"
        version = "0.1.0"
        edition = "2021"

        [lib]
        crate-type = ["cdylib"]

        [dependencies]
        $macro_dep
        """)
    write(joinpath(path, "src", "lib.rs"), """
        use rustcall_julia_macros::julia;

        #[julia]
        pub fn crate_slice_sum619(xs: Option<&[f64]>) -> f64 {
            xs.map_or(-1.0, |v| v.iter().sum())
        }

        #[julia]
        pub fn crate_slice_fill619(xs: Option<&mut [f64]>, delta: f64) -> usize {
            match xs {
                Some(v) => {
                    for x in v.iter_mut() { *x += delta; }
                    v.len()
                }
                None => 0,
            }
        }

        #[julia]
        pub struct CrateSliceBag619 { value: f64 }

        #[julia]
        impl CrateSliceBag619 {
            #[julia]
            pub fn from_slice619(value: f64, xs: Option<&[f64]>) -> Self {
                Self { value: value + xs.map_or(0.0, |v| v.iter().sum::<f64>()) }
            }

            #[julia]
            pub fn value619(&self) -> f64 { self.value }

            #[julia]
            pub fn add_into619(&self, xs: Option<&mut [f64]>) -> usize {
                match xs {
                    Some(v) => {
                        for x in v.iter_mut() { *x += self.value; }
                        v.len()
                    }
                    None => 0,
                }
            }
        }
        """)
    return path
end

@testset "crate optional slice arguments (#619)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        mktempdir() do root
            crate = _write_optional_slice_crate(joinpath(root, "facade");
                                                macro_path = RustCall.rustcall_runtime_crate_path())
            info = RustCall.scan_crate(crate)
            symbols = RustCall._slice_arg_symbols(info)
            @test !isempty(symbols)
            @test "rustcall_crate_slice_sum619" in symbols
            @test "rustcall_crate_slice_fill619" in symbols
            @test "rustcall_CrateSliceBag619_from_slice619" in symbols
            @test "rustcall_CrateSliceBag619_add_into619" in symbols
            proxy = Core.eval(@__MODULE__, :(@rust_crate $crate cache = false))
            bindings = Base.invokelatest(getfield, proxy, :module_ref)
            call(name::Symbol, args...) = Base.invokelatest(
                Base.invokelatest(getfield, bindings, name), args...)
            try
                lib = Base.invokelatest(getfield, bindings, :_LIB_NAME)
                for symbol in symbols
                    target = RustCall.resolve_call_target(lib, symbol)
                    @test RustCall.Libdl.dlsym(
                        target.handle,
                        symbol * "_slice_ptr_len_v1",
                    ) != C_NULL
                end
                @test call(:crate_slice_sum619, nothing) == -1.0
                @test call(:crate_slice_sum619, Float64[]) == 0.0
                @test call(:crate_slice_sum619, [1.0, 2.0]) == 3.0
                xs = [1.0, 2.0]
                @test call(:crate_slice_fill619, nothing, 1.0) == 0
                @test call(:crate_slice_fill619, xs, 2.0) == 2
                @test xs == [3.0, 4.0]
                bag = call(:CrateSliceBag619, 10.0, nothing)
                @test call(:value619, bag) == 10.0
                from_absent = call(:CrateSliceBag619, 1.0, nothing)
                from_some = call(:CrateSliceBag619, 1.0, [2.0, 3.0])
                @test call(:value619, from_absent) == 1.0
                @test call(:value619, from_some) == 6.0
                out = zeros(3)
                @test call(:add_into619, bag, out) == 3
                @test out == fill(10.0, 3)
                @test call(:add_into619, bag, nothing) == 0
                @test_throws ArgumentError call(:crate_slice_sum619, Float32[1, 2])
            finally
                lib = Base.invokelatest(getfield, bindings, :_LIB_NAME)
                haskey(RustCall.RUST_LIBRARIES, lib) &&
                    RustCall.unload_library(lib; close = true)
            end
        end
    end
end
