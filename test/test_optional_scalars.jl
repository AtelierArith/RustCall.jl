using Test, RustCall

# `Option<T>` for a primitive `T` is lowered to two C slots — an `i32` presence
# tag and the value — and reconstructed as a Rust `Option<T>` by the shim
# (issue #609). This is deliberately not Rust's native `Option` ABI.

rust"""
#[julia]
pub fn opt_scalar_f64(v: Option<f64>) -> f64 {
    v.unwrap_or(-1.0)
}

#[julia]
pub fn opt_scalar_i32(v: Option<i32>) -> i32 {
    v.unwrap_or(-7)
}

#[julia]
pub fn opt_scalar_u8(v: Option<u8>) -> u8 {
    v.unwrap_or(0)
}

#[julia]
pub fn opt_scalar_bool(v: Option<bool>) -> bool {
    v.unwrap_or(false)
}

#[julia]
pub fn opt_scalar_result(v: Option<u32>) -> Result<u32, String> {
    v.ok_or_else(|| "missing".to_string())
}

#[julia]
pub fn opt_scalar_mixed(a: Option<f64>, xs: &[f64], label: &str) -> String {
    format!("{} {} {}", a.map(|x| x.to_string()).unwrap_or_else(|| "none".to_string()), xs.len(), label)
}

// Regression for a temporary-name collision: `v`'s value temporary and the
// string buffer of `v_value` must not share a name, in either argument order.
#[julia]
pub fn opt_scalar_collision(v: Option<i32>, v_value: &str) -> String {
    format!("{}:{}", v.map(|x| x.to_string()).unwrap_or_else(|| "none".to_string()), v_value)
}

#[julia]
pub fn opt_scalar_collision_reordered(v_value: &str, v: Option<i32>) -> String {
    format!("{}:{}", v.map(|x| x.to_string()).unwrap_or_else(|| "none".to_string()), v_value)
}

#[julia]
pub fn opt_scalar_two(a: Option<i32>, a_value: Option<i32>) -> String {
    format!("{}:{}",
        a.map(|x| x.to_string()).unwrap_or_else(|| "none".to_string()),
        a_value.map(|x| x.to_string()).unwrap_or_else(|| "none".to_string()))
}
"""

@testset "inline optional scalar arguments (#609)" begin
    @test opt_scalar_f64(nothing) == -1.0
    @test opt_scalar_f64(2.5) == 2.5
    @test opt_scalar_f64(2) == 2.0        # converted to Float64
    @test opt_scalar_i32(nothing) == -7
    @test opt_scalar_i32(Int32(3)) == 3
    @test opt_scalar_u8(nothing) == 0x00
    @test opt_scalar_u8(0x05) == 0x05
    @test opt_scalar_bool(nothing) === false
    @test opt_scalar_bool(true) === true

    ok = opt_scalar_result(UInt32(9))
    @test RustCall.is_ok(ok) && RustCall.unwrap(ok) == 9
    missing_value = opt_scalar_result(nothing)
    @test RustCall.is_err(missing_value)
    @test missing_value.value == "missing"

    @test opt_scalar_mixed(nothing, [1.0, 2.0], "x") == "none 2 x"
    @test opt_scalar_mixed(1.5, Float64[], "y") == "1.5 0 y"

    # A string argument named like an optional-scalar temporary.
    @test opt_scalar_collision(Int32(4), "four") == "4:four"
    @test opt_scalar_collision(nothing, "four") == "none:four"
    @test opt_scalar_collision_reordered("four", Int32(4)) == "4:four"
    @test opt_scalar_two(Int32(1), nothing) == "1:none"
    @test opt_scalar_two(nothing, Int32(2)) == "none:2"

    report = RustCall.inline_boundary_report("""
        #[julia]
        pub fn f(v: Option<f64>) -> f64 { v.unwrap_or(0.0) }
        """; io = devnull)
    @test isempty(report.unsupported)
end

@testset "optional scalar argument contract (#609)" begin
    c = RustCall.ffi_argument_contract("Option<f64>"; abi = "option_scalar", slice_element = "f64")
    @test c.known
    @test c.abi === :option_scalar
    @test c.ccall_types == Type[Int32, Float64]
    @test c.surface_type == Union{Nothing, Float64}

    b = RustCall.ffi_argument_contract("Option<bool>"; abi = "option_scalar", slice_element = "bool")
    @test b.ccall_types == Type[Int32, Bool]

    @test_throws ArgumentError RustCall.ffi_argument_contract(
        "Option<String>"; abi = "option_scalar", slice_element = "String")
end

function _write_optional_scalar_crate(path; macro_path)
    mkpath(joinpath(path, "src"))
    macro_dep = "rustcall_julia_macros = { path = \"$(RustCall.escape_toml_string(macro_path))\" }"
    write(joinpath(path, "Cargo.toml"), """
        [package]
        name = "optional_scalar_facade"
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
        pub struct OptionalScalarCounter {
            value: f64,
        }

        #[julia]
        impl OptionalScalarCounter {
            #[julia]
            pub fn new(value: Option<f64>) -> Self {
                Self { value: value.unwrap_or(0.0) }
            }

            #[julia]
            pub fn set(&mut self, value: Option<f64>) -> Result<(), String> {
                match value {
                    Some(v) => { self.value = v; Ok(()) }
                    None => Err("missing value".to_string()),
                }
            }

            #[julia]
            pub fn value(&self) -> f64 {
                self.value
            }
        }

        #[julia]
        pub fn optional_scalar_label(value: Option<i32>, scale: f64) -> String {
            format!("{} x {}", value.map(|v| v as f64 * scale).unwrap_or(0.0), scale)
        }
        """)
    return path
end

@testset "crate optional scalar arguments (#609)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        mktempdir() do root
            crate = _write_optional_scalar_crate(joinpath(root, "facade");
                                                macro_path = RustCall.rustcall_runtime_crate_path())
            bindings = Core.eval(@__MODULE__, :(@rust_crate $crate cache = false))
            counter = Base.invokelatest(bindings.OptionalScalarCounter, 1.5)
            @test Base.invokelatest(bindings.value, counter) == 1.5
            empty = Base.invokelatest(bindings.OptionalScalarCounter, nothing)
            @test Base.invokelatest(bindings.value, empty) == 0.0
            @test RustCall.is_ok(Base.invokelatest(bindings.set, empty, 2.5))
            @test Base.invokelatest(bindings.value, empty) == 2.5
            err = Base.invokelatest(bindings.set, empty, nothing)
            @test RustCall.is_err(err) && err.value == "missing value"
            @test Base.invokelatest(bindings.optional_scalar_label, nothing, 2.0) == "0 x 2"
            @test Base.invokelatest(bindings.optional_scalar_label, Int32(3), 2.0) == "6 x 2"
        end
    end
end
