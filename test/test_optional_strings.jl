using Test, RustCall

# `Option<&str>` is lowered to three C slots — an `i32` presence tag and the
# `(ptr, len)` pair a required `&str` uses — and the shim rebuilds a
# call-scoped `Option<&str>` from the bytes (issue #612). `nothing` means
# absence; `""` is a present, empty string.

rust"""
#[julia]
pub fn opt_str_describe(v: Option<&str>) -> String {
    match v {
        Some(text) => format!("some:{text}"),
        None => "none".to_string(),
    }
}

#[julia]
pub fn opt_str_present(v: Option<&str>) -> bool {
    v.is_some()
}

#[julia]
pub fn opt_str_len(v: Option<&str>) -> usize {
    v.map_or(usize::MAX, |text| text.len())
}

#[julia]
pub fn opt_str_result(v: Option<&str>) -> Result<String, String> {
    v.map(|text| text.to_uppercase()).ok_or_else(|| "missing".to_string())
}

#[julia]
pub fn opt_str_mixed(v: Option<&str>, scale: Option<f64>, xs: &[f64]) -> String {
    format!("{} {} {}",
        v.unwrap_or("none"),
        scale.map(|s| s.to_string()).unwrap_or_else(|| "none".to_string()),
        xs.len())
}

#[julia]
pub struct OptStrBag {
    label: String,
}

#[julia]
impl OptStrBag {
    #[julia]
    pub fn new(label: &str) -> Self {
        Self { label: label.to_string() }
    }

    #[julia]
    pub fn update(&mut self, suffix: Option<&str>) -> Result<(), String> {
        match suffix {
            Some(text) => {
                self.label.push_str(text);
                Ok(())
            }
            None => Err("no suffix".to_string()),
        }
    }

    #[julia]
    pub fn label(&self) -> String {
        self.label.clone()
    }
}
"""

@testset "inline optional string arguments (#612)" begin
    @test opt_str_describe(nothing) == "none"
    @test opt_str_describe("abc") == "some:abc"
    @test opt_str_describe("") == "some:"

    # Absence and an empty string are distinct.
    @test opt_str_present(nothing) === false
    @test opt_str_present("") === true
    @test opt_str_len(nothing) == typemax(UInt)
    @test opt_str_len("") == 0
    @test opt_str_len("abcd") == 4

    ok = opt_str_result("abc")
    @test RustCall.is_ok(ok) && RustCall.unwrap(ok) == "ABC"
    missing = opt_str_result(nothing)
    @test RustCall.is_err(missing) && missing.value == "missing"

    @test opt_str_mixed(nothing, nothing, [1.0, 2.0]) == "none none 2"
    @test opt_str_mixed("x", 2.5, Float64[]) == "x 2.5 0"

    bag = OptStrBag("a")
    @test RustCall.is_ok(bag.update("b"))
    @test label(bag) == "ab"
    err = bag.update(nothing)
    @test RustCall.is_err(err) && err.value == "no suffix"
    @test label(bag) == "ab"

    # Only `nothing` and a string are accepted, as for optional scalars.
    @test_throws ArgumentError opt_str_describe(Some("x"))
    @test_throws ArgumentError opt_str_describe(missing)

    report = RustCall.inline_boundary_report("""
        #[julia]
        pub fn f(v: Option<&str>) -> usize { v.map_or(0, |s| s.len()) }
        """; io = devnull)
    @test isempty(report.unsupported)
end

@testset "optional string lifetime refusals (#612)" begin
    # A 'static optional string cannot be rebuilt for the call.
    report = RustCall.inline_boundary_report("""
        #[julia]
        pub fn f(v: Option<&'static str>) -> usize { v.map_or(0, |s| s.len()) }
        """; io = devnull)
    @test !isempty(report.unsupported)

    # A retained optional string is refused like a retained &str.
    report = RustCall.inline_boundary_report("""
        #[julia]
        pub struct Holder<'a> { text: &'a str }

        #[julia]
        pub fn f<'a>(v: Option<&'a str>, holder: Holder<'a>) -> usize {
            v.map_or(0, |s| s.len()) + holder.text.len()
        }
        """; io = devnull)
    @test !isempty(report.unsupported)
end

@testset "optional string argument contract (#612)" begin
    c = RustCall.ffi_argument_contract("Option<&str>"; abi = "option_str")
    @test c.known
    @test c.abi === :option_str
    @test c.ccall_types == Type[Int32, Ptr{UInt8}, Csize_t]
    @test c.surface_type == Union{Nothing, String}
    @test c.ownership === :owned_by_julia

    @test RustCall.ffi_manifest_abi_kind("option_str", :argument) === :option_str
    @test_throws ArgumentError RustCall.ffi_manifest_abi_kind("option_str", :return)
end

function _write_optional_string_crate(path; macro_path)
    mkpath(joinpath(path, "src"))
    macro_dep = "rustcall_julia_macros = { path = \"$(RustCall.escape_toml_string(macro_path))\" }"
    write(joinpath(path, "Cargo.toml"), """
        [package]
        name = "optional_string_facade"
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
        pub struct OptionalStringLabel {
            text: String,
        }

        #[julia]
        impl OptionalStringLabel {
            #[julia]
            pub fn new(text: &str) -> Self {
                Self { text: text.to_string() }
            }

            #[julia]
            pub fn append(&mut self, suffix: Option<&str>) -> Result<(), String> {
                match suffix {
                    Some(s) => { self.text.push_str(s); Ok(()) }
                    None => Err("missing suffix".to_string()),
                }
            }

            #[julia]
            pub fn label_text(&self) -> String {
                self.text.clone()
            }
        }

        #[julia]
        pub fn optional_string_label(value: Option<&str>, scale: Option<f64>) -> String {
            format!("{} x {}",
                value.unwrap_or("none"),
                scale.map(|s| s.to_string()).unwrap_or_else(|| "none".to_string()))
        }
        """)
    return path
end

@testset "crate optional string arguments (#612)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        mktempdir() do root
            crate = _write_optional_string_crate(joinpath(root, "facade");
                                                macro_path = RustCall.rustcall_runtime_crate_path())
            bindings = Core.eval(@__MODULE__, :(@rust_crate $crate cache = false))
            label = Base.invokelatest(bindings.OptionalStringLabel, "a")
            @test Base.invokelatest(bindings.label_text, label) == "a"
            @test RustCall.is_ok(Base.invokelatest(bindings.append, label, "b"))
            @test Base.invokelatest(bindings.label_text, label) == "ab"
            err = Base.invokelatest(bindings.append, label, nothing)
            @test RustCall.is_err(err) && err.value == "missing suffix"
            @test Base.invokelatest(bindings.label_text, label) == "ab"
            @test Base.invokelatest(bindings.optional_string_label, nothing, nothing) == "none x none"
            @test Base.invokelatest(bindings.optional_string_label, "", 2.5) == " x 2.5"
        end
    end
end
