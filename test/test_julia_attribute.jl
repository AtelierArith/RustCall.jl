# Test cases for #[julia] attribute support (Phase 5)
using RustCall
using Test

@testset "Julia Attribute Support" begin

    # Signatures come from the FFI manifest produced by rustcall-extract; Julia
    # never parses Rust source. These tests exercise the manifest round trip.
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping manifest tests"
        return
    end

    @testset "manifest: #[julia] functions" begin
        code1 = """
        #[julia]
        fn add(a: i32, b: i32) -> i32 {
            a + b
        }
        """
        sigs = RustCall.manifest_function_signatures(RustCall.extract_manifest(code1; mode = "inline"))
        @test length(sigs) == 1
        @test sigs[1].name == "add"
        @test sigs[1].symbol == "add"
        @test sigs[1].arg_names == ["a", "b"]
        @test sigs[1].arg_types == ["i32", "i32"]
        @test sigs[1].return_type == "i32"
        @test sigs[1].return_kind == :plain
        @test sigs[1].is_generic == false
        @test sigs[1].exported

        code2 = """
        #[julia]
        pub fn multiply(x: f64, y: f64) -> f64 {
            x * y
        }
        """
        sigs = RustCall.manifest_function_signatures(RustCall.extract_manifest(code2; mode = "inline"))
        @test length(sigs) == 1
        @test sigs[1].name == "multiply"
        @test sigs[1].arg_types == ["f64", "f64"]
        @test sigs[1].return_type == "f64"

        # Void return type
        code3 = """
        #[julia]
        fn do_nothing(a: i32) {
            println!("value: {}", a);
        }
        """
        sigs = RustCall.manifest_function_signatures(RustCall.extract_manifest(code3; mode = "inline"))
        @test length(sigs) == 1
        @test sigs[1].return_type == "()"
        @test sigs[1].return_kind == :unit

        # Multiple functions; plain extern "C" functions are reported but not attributed
        code4 = """
        #[julia]
        fn func1(a: i32) -> i32 { a }

        #[no_mangle]
        pub extern "C" fn not_julia(a: i32) -> i32 { a }

        #[julia]
        fn func2(b: f32) -> f32 { b }
        """
        manifest = RustCall.extract_manifest(code4; mode = "inline")
        sigs = RustCall.manifest_function_signatures(manifest)
        @test [s.name for s in sigs] == ["func1", "func2"]
        all_sigs = RustCall.manifest_function_signatures(manifest; only_attributed = false)
        @test [s.name for s in all_sigs] == ["func1", "not_julia", "func2"]
        plain = all_sigs[2]
        @test plain.attribute == :none
        @test plain.exported

        # No #[julia] functions
        code5 = """
        #[no_mangle]
        pub extern "C" fn regular_fn(a: i32) -> i32 { a }
        """
        @test isempty(RustCall.manifest_function_signatures(RustCall.extract_manifest(code5; mode = "inline")))

        # Const expressions in types (#233) are handled by a real parser
        code6 = """
        #[julia]
        fn foo(x: [u8; { if 1 < 2 { 3 } else { 4 } }], y: i32) {
            let _ = x;
            let _ = y;
        }
        """
        sigs = RustCall.manifest_function_signatures(RustCall.extract_manifest(code6; mode = "inline"))
        @test length(sigs) == 1
        @test sigs[1].arg_names == ["x", "y"]
        @test sigs[1].arg_types[2] == "i32"
        @test startswith(sigs[1].arg_types[1], "[u8;")

        code7 = """
        #[julia]
        fn make_array() -> [u8; { if 1 < 2 { 3 } else { 4 } }] {
            [0; 3]
        }
        """
        sigs = RustCall.manifest_function_signatures(RustCall.extract_manifest(code7; mode = "inline"))
        @test length(sigs) == 1
        @test startswith(sigs[1].return_type, "[u8;")

        # Result / Option returns are reported with their components
        code8 = """
        #[julia]
        fn div(a: f64, b: f64) -> Result<f64, i32> { if b == 0.0 { Err(-1) } else { Ok(a / b) } }
        #[julia]
        fn maybe(a: i32) -> Option<i32> { if a > 0 { Some(a) } else { None } }
        """
        sigs = RustCall.manifest_function_signatures(RustCall.extract_manifest(code8; mode = "inline"))
        @test sigs[1].return_kind == :result
        @test (sigs[1].ok_type, sigs[1].err_type) == ("f64", "i32")
        @test sigs[2].return_kind == :option
        @test sigs[2].inner_type == "i32"

        # `#[julia]` inside a string literal is not an attribute
        code9 = """
        fn f() -> &'static str { "#[julia] fn fake() {}" }
        """
        @test isempty(RustCall.manifest_function_signatures(RustCall.extract_manifest(code9; mode = "inline")))
    end

    @testset "expand_inline: #[julia] transformation" begin
        code1 = "#[julia]\nfn add(a: i32, b: i32) -> i32 { a + b }"
        result1 = RustCall.expand_inline(code1).source
        @test occursin("#[no_mangle]", result1)
        @test occursin("pub extern \"C\" fn add", result1)
        @test !occursin("#[julia]", result1)

        code2 = "#[julia]\npub fn multiply(x: f64) -> f64 { x * 2.0 }"
        result2 = RustCall.expand_inline(code2).source
        @test occursin("#[no_mangle]", result2)
        @test occursin("pub extern \"C\" fn multiply", result2)

        code3 = "#[julia] fn inline_fn(a: i32) -> i32 { a }"
        @test occursin("pub extern \"C\" fn inline_fn", RustCall.expand_inline(code3).source)

        code4 = """
        #[julia]
        fn with_julia(a: i32) -> i32 { a }

        #[no_mangle]
        pub extern "C" fn already_ffi(b: i32) -> i32 { b }
        """
        result4 = RustCall.expand_inline(code4).source
        @test occursin("pub extern \"C\" fn with_julia", result4)
        @test occursin("pub extern \"C\" fn already_ffi", result4)  # unchanged

        # Result-returning #[julia] functions get a C-compatible wrapper struct
        code5 = "#[julia]\nfn d(a: f64) -> Result<f64, i32> { Ok(a) }"
        result5 = RustCall.expand_inline(code5).source
        @test occursin("CResult_d", result5)
        @test occursin("pub extern \"C\" fn d(a: f64) -> CResult_d", result5)

        # Expansion is memoized per source text
        @test RustCall.expand_inline(code1) === RustCall.expand_inline(code1)
    end

    @testset "manifest: schema version guard" begin
        @test RustCall.MANIFEST_SCHEMA_VERSION == 2
        @test RustCall._parse_manifest("schema_version = 2\nmode = \"inline\"\n")["schema_version"] == 2
        # Schema 1 predates the string ABI columns (`abi`, `return_abi`, the
        # helper flags); a consumer must not fall back to the one-word ABI.
        err = try
            RustCall._parse_manifest("schema_version = 1\nmode = \"inline\"\n")
            nothing
        catch e
            e
        end
        @test err isa RustCall.ExtractorError
        @test occursin("schema 1", sprint(showerror, err))
        @test occursin("expects 2", sprint(showerror, err))
        @test_throws RustCall.ExtractorError RustCall._parse_manifest("schema_version = 999\nmode = \"inline\"\n")
        @test_throws RustCall.ExtractorError RustCall._parse_manifest("mode = \"inline\"\n")
        @test_throws RustCall.ExtractorError RustCall._parse_manifest("not = [valid toml")
    end

    @testset "emit_julia_function_wrappers" begin
        sig = RustCall.RustFunctionSignature(
            "add",
            ["a", "b"],
            ["i32", "i32"],
            "i32",
            false,
            String[]
        )

        expr = RustCall.emit_julia_function_wrappers([sig])
        @test expr isa Expr

        # The expression should be a block containing a function definition
        @test expr.head == :block
    end

    if RustCall.check_rustc_available()
        @testset "Integration: Simple Function" begin
            # Test that #[julia] attribute works end-to-end
            rust"""
            #[julia]
            fn julia_add(a: i32, b: i32) -> i32 {
                a + b
            }
            """

            # The wrapper function should be automatically generated
            @test julia_add(10, 20) == 30
            @test julia_add(Int32(5), Int32(7)) == 12
        end

        @testset "Integration: Multiple Types" begin
            rust"""
            #[julia]
            fn julia_multiply_f64(x: f64, y: f64) -> f64 {
                x * y
            }

            #[julia]
            fn julia_negate(b: bool) -> bool {
                !b
            }
            """

            @test julia_multiply_f64(2.5, 4.0) ≈ 10.0
            @test julia_negate(true) == false
            @test julia_negate(false) == true
        end

        @testset "Integration: Mixed Attributes" begin
            # Mix of #[julia] and traditional #[no_mangle]
            rust"""
            #[julia]
            fn julia_style_fn(a: i32) -> i32 {
                a * 2
            }

            #[no_mangle]
            pub extern "C" fn traditional_style_fn(b: i32) -> i32 {
                b * 3
            }
            """

            # #[julia] function should have auto-generated wrapper
            @test julia_style_fn(5) == 10

            # Traditional function needs @rust macro
            @test @rust traditional_style_fn(Int32(5)) == 15
        end

        @testset "Integration: #[julia] struct" begin
            rust"""
            #[julia]
            pub struct JuliaCounter {
                value: i32,
            }

            impl JuliaCounter {
                pub fn new(initial: i32) -> Self {
                    Self { value: initial }
                }

                pub fn increment(&mut self) {
                    self.value += 1;
                }

                pub fn get(&self) -> i32 {
                    self.value
                }
            }
            """

            # Create instance
            c = JuliaCounter(0)
            @test c isa JuliaCounter

            # Call methods
            increment(c)
            increment(c)
            @test get(c) == 2

            # Access field
            @test c.value == 2
        end

        @testset "Integration: Mixed #[julia] fn and struct" begin
            rust"""
            #[julia]
            fn compute_sum(a: f64, b: f64) -> f64 {
                a + b
            }

            #[julia]
            pub struct JuliaPoint2D {
                x: f64,
                y: f64,
            }

            impl JuliaPoint2D {
                pub fn new(x: f64, y: f64) -> Self {
                    Self { x, y }
                }

                pub fn length(&self) -> f64 {
                    (self.x * self.x + self.y * self.y).sqrt()
                }
            }
            """

            # Test function
            @test compute_sum(1.5, 2.5) ≈ 4.0

            # Test struct
            p = JuliaPoint2D(3.0, 4.0)
            @test length(p) ≈ 5.0
            @test p.x ≈ 3.0
            @test p.y ≈ 4.0
        end

        @testset "Integration: #[julia] struct with String fields" begin
            rust"""
            #[julia]
            pub struct JuliaPerson {
                name: String,
                age: i32,
            }

            impl JuliaPerson {
                pub fn new(name: String, age: i32) -> Self {
                    Self { name, age }
                }

                pub fn get_name(&self) -> String {
                    self.name.clone()
                }
            }
            """

            person = JuliaPerson("Alice", Int32(30))
            @test person.age == Int32(30)
            @test person.name == "Alice"
            @test get_name(person) == "Alice"
        end
    end
end

@testset "#[julia] String / &str functions (#242)" begin
    code = """
    #[julia]
    pub fn shout(input: String) -> String { input.to_uppercase() }
    #[julia]
    pub fn join_repeat(a: &str, b: &str, sep: &str, times: u32) -> String {
        let piece = format!("{a}{sep}{b}");
        std::iter::repeat_n(piece, times as usize).collect::<Vec<_>>().join(sep)
    }
    #[julia]
    pub fn char_count(s: &str) -> usize { s.chars().count() }
    #[julia]
    pub fn greeting() -> &'static str { "hello" }
    #[julia]
    pub fn with_nul(s: String) -> String { format!("{s}\\0{s}") }
    """
    sigs = RustCall.manifest_function_signatures(RustCall.expand_inline(code).manifest)
    by_name = Dict(s.name => s for s in sigs)
    @test by_name["shout"].has_owned_string_helper
    @test !by_name["shout"].has_borrowed_string_helper
    @test by_name["greeting"].has_borrowed_string_helper
    @test !by_name["char_count"].has_owned_string_helper
    @test RustCall._uses_string_ffi(by_name["char_count"])
    @test RustCall._uses_string_ffi(by_name["shout"])
    @test by_name["shout"].arg_abis == ["string"]
    @test by_name["join_repeat"].arg_abis == ["str", "str", "str", ""]
    bindings, preserved, call_args = RustCall._string_arg_plan(by_name["join_repeat"], identity)
    @test length(bindings) == 3 && length(preserved) == 3 && length(call_args) == 7

    # A temporary never shadows an argument that happens to use the prefix.
    collide = RustCall.RustFunctionSignature("f", ["s", "__rustcall_str_s"], ["&str", "i32"], "usize",
                                             false, String[]; arg_abis = ["str", ""])
    _, preserved_c, call_args_c = RustCall._string_arg_plan(collide, identity)
    @test preserved_c == [Symbol("__rustcall_str__s")]
    @test call_args_c[end] == :(Int32(__rustcall_str_s))

    if RustCall.check_rustc_available()
        # Struct methods use the same ABI decision: a `&str` return of a method
        # that takes strings is copied into the owned representation.
        rust"""
        #[julia]
        pub struct Greeter { pub name: String }

        impl Greeter {
            pub fn new(name: String) -> Self { Self { name } }
            pub fn shout(&self, suffix: &str) -> String { format!("{}{}", self.name.to_uppercase(), suffix) }
            pub fn echo<'a>(&self, s: &'a str) -> &'a str { s }
            pub fn label(&self) -> &str { "greeter" }
        }
        """
        infos = RustCall.manifest_struct_infos(RustCall.expand_inline("""
        #[julia]
        pub struct Greeter { pub name: String }

        impl Greeter {
            pub fn new(name: String) -> Self { Self { name } }
            pub fn shout(&self, suffix: &str) -> String { format!("{}{}", self.name.to_uppercase(), suffix) }
            pub fn echo<'a>(&self, s: &'a str) -> &'a str { s }
            pub fn label(&self) -> &str { "greeter" }
        }
        """).manifest)
        methods = Dict(m.name => m for m in only(infos).methods)
        @test methods["shout"].return_abi == "string"
        @test methods["echo"].return_abi == "string"   # copied: borrows from an argument
        @test methods["label"].return_abi == "str"
        g = Greeter("ada")
        @test shout(g, "!") == "ADA!"
        @test echo(g, "λ") == "λ"
        @test label(g) == "greeter"

        rust"""
        #[julia]
        pub fn shout(input: String) -> String { input.to_uppercase() }
        #[julia]
        pub fn join_repeat(a: &str, b: &str, sep: &str, times: u32) -> String {
            let piece = format!("{a}{sep}{b}");
            std::iter::repeat_n(piece, times as usize).collect::<Vec<_>>().join(sep)
        }
        #[julia]
        pub fn char_count(s: &str) -> usize { s.chars().count() }
        #[julia]
        pub fn greeting() -> &'static str { "hello" }
        #[julia]
        pub fn with_nul(s: String) -> String { format!("{s}\0{s}") }
        #[julia]
        pub fn parse_num(s: &str) -> Result<i32, i32> { s.trim().parse().map_err(|_| -1) }
        #[julia]
        pub fn first_char(s: String) -> Option<u32> { s.chars().next().map(|c| c as u32) }
        #[julia]
        pub fn identity_str<'a>(s: &'a str) -> &'a str { s }
        """
        # Result / Option functions with string arguments
        @test RustCall.unwrap(parse_num(" 42 ")) == Int32(42)
        @test RustCall.is_err(parse_num("x"))
        @test RustCall.unwrap(first_char("λx")) == UInt32('λ')
        @test RustCall.is_none(first_char(""))
        # Lifetime-qualified &str: the result may borrow from the converted
        # argument, so it comes back as an owned copy (still a String in Julia).
        @test identity_str("kept") == "kept"
        @test identity_str(String(UInt8[0x41, 0xff])) == "A\ufffd"
        # Invalid UTF-8 is replaced, never handed to Rust as an invalid &str
        @test char_count(String(UInt8[0xff, 0x41])) == 2
        @test shout(String(UInt8[0xc3, 0x28])) == "\ufffd("
        @test shout("hello, wörld") == "HELLO, WÖRLD"
        @test shout(SubString("xyz", 2)) == "YZ"
        @test join_repeat("a", "b", "-", UInt32(2)) == "a-b-a-b"
        @test join_repeat("日本", "語", "", 1) == "日本語"
        @test char_count("日本語") == 3
        @test char_count("") == 0
        @test greeting() == "hello"
        # Byte-exact round trip: embedded NUL survives the (ptr, len) ABI.
        @test with_nul("ab") == "ab\0ab"
        # Repeated calls do not leak or corrupt (owned strings are freed).
        for i in 1:1000
            @test shout("x") == "X"
        end
    end
end

@testset "#[julia] arguments named like generated locals (#242 review)" begin
    # The wrappers introduce locals (`func_ptr`, `lib_name`, `c_result`,
    # `c_option`); a Rust argument may carry any of those names and must not be
    # shadowed by them.
    @test RustCall._generated_local("func_ptr", ["s"]) === :func_ptr
    @test RustCall._generated_local("func_ptr", ["func_ptr"]) === Symbol("__rustcall_func_ptr")
    @test RustCall._generated_local("c_result", ["c_result", "__rustcall_x"]) ===
          Symbol("__rustcall__c_result")

    if RustCall.check_rustc_available()
        rust"""
        #[julia]
        pub fn shadow_len(func_ptr: &str, lib_name: String) -> usize { func_ptr.len() + lib_name.len() }
        #[julia]
        pub fn shadow_parse(func_ptr: &str, c_result: i32) -> Result<i32, i32> {
            func_ptr.trim().parse().map_err(|_| c_result)
        }
        #[julia]
        pub fn shadow_first(func_ptr: String, c_option: u32) -> Option<u32> {
            func_ptr.chars().next().map(|c| c as u32 + c_option)
        }
        #[julia]
        pub fn shadow_upper(func_ptr: String, lib_name: &str) -> String {
            format!("{}{}", func_ptr.to_uppercase(), lib_name)
        }
        #[julia]
        pub fn shadow_twice(func_ptr: i32) -> i32 { func_ptr * 2 }
        """
        @test shadow_len("abc", "de") == 5
        @test RustCall.unwrap(shadow_parse(" 7 ", Int32(-1))) == Int32(7)
        @test RustCall.is_err(shadow_parse("seven", Int32(-1)))
        @test RustCall.unwrap(shadow_first("A", UInt32(0))) == UInt32('A')
        @test RustCall.is_none(shadow_first("", UInt32(0)))
        @test shadow_upper("ada", "!") == "ADA!"
        @test shadow_twice(Int32(21)) == Int32(42)
    end
end

@testset "#[julia] arguments named like generated Rust identifiers (#242 review)" begin
    # The Rust wrapper introduces `<arg>_ptr` / `<arg>_len` / `<arg>_bytes` /
    # `<arg>_cow` (and `ptr` / `self_obj` for methods); user arguments with
    # those names must keep their values.
    code = """
    #[julia]
    pub fn f(s: String, s_ptr: usize) -> usize { s.len() + s_ptr }
    """
    expanded = RustCall.expand_inline(code)
    @test occursin("s_ptr_: *const u8", expanded.source)
    sig = only(RustCall.manifest_function_signatures(expanded.manifest))
    @test sig.arg_names == ["s", "s_ptr"]
    @test sig.arg_abis == ["string", ""]

    if RustCall.check_rustc_available()
        rust"""
        #[julia]
        pub fn collide_owned(s: String, s_ptr: usize) -> usize { s.len() + s_ptr }
        #[julia]
        pub fn collide_borrowed(s: &str, s_bytes: i32, s_cow: i32, s_len: i32) -> i32 {
            s.len() as i32 + s_bytes * 10 + s_cow * 100 + s_len * 1000
        }
        #[julia]
        pub fn collide_ret(s_ptr: u8, s: String) -> String { format!("{s}{s_ptr}") }

        #[julia]
        pub struct Holder { pub n: u32 }
        impl Holder {
            pub fn new(n: u32) -> Self { Self { n } }
            pub fn m(&self, ptr: u32, self_obj: u32, s: &str, s_bytes: u32) -> u32 {
                self.n + ptr + self_obj + s.len() as u32 + s_bytes
            }
        }
        """
        @test collide_owned("abc", UInt(4)) == 7
        @test collide_borrowed("ab", Int32(1), Int32(2), Int32(3)) == 3212
        @test collide_ret(UInt8(7), "v") == "v7"
        h = Holder(UInt32(1))
        @test m(h, UInt32(2), UInt32(3), "abcd", UInt32(5)) == 15
    end
end

@testset "#[julia] parenthesized types and #[julia_pyo3] string ABI (#242 review)" begin
    # `(String)` and `&(str)` are Type::Paren to syn; they name the same types.
    code = """
    #[julia]
    pub fn consume(s: (String)) -> usize { s.len() }
    #[julia]
    pub fn paren_ref(s: &(str)) -> (usize) { s.chars().count() }
    #[julia]
    pub fn paren_ret(s: String) -> (String) { s.to_uppercase() }
    """
    sigs = Dict(s.name => s for s in RustCall.manifest_function_signatures(RustCall.expand_inline(code).manifest))
    @test sigs["consume"].arg_abis == ["string"]
    @test sigs["consume"].arg_types == ["String"]
    @test sigs["paren_ref"].arg_abis == ["str"]
    @test sigs["paren_ref"].return_type == "usize"
    @test sigs["paren_ret"].has_owned_string_helper
    @test sigs["paren_ret"].return_type == "String"

    if RustCall.check_rustc_available()
        rust"""
        #![allow(unused_parens)]
        #[julia]
        pub fn consume(s: (String)) -> usize { s.len() }
        #[julia]
        pub fn paren_ref(s: &(str)) -> (usize) { s.chars().count() }
        #[julia]
        pub fn paren_ret(s: String) -> (String) { s.to_uppercase() }
        """
        @test consume("abc") == 3
        @test paren_ref("日本語") == 3
        @test paren_ret("abc") == "ABC"
    end

    # `#[julia_pyo3]` free functions are exported as written (no string
    # conversion, pending #275): the crate manifest reports an empty ABI so
    # the Julia wrapper does not pass (ptr, len) to a function taking `String`.
    pyo3 = RustCall.extract_manifest("""
    #[julia_pyo3]
    pub fn py_len(s: String) -> usize { s.len() }
    #[julia_pyo3]
    pub fn py_plain(x: i32) -> i32 { x }
    """; mode = "crate")
    py = Dict(s.name => s for s in RustCall.manifest_function_signatures(pyo3))
    @test py["py_len"].arg_types == ["String"]
    @test py["py_len"].arg_abis == [""]
    @test !py["py_len"].has_owned_string_helper
    @test !RustCall._uses_string_ffi(py["py_len"])
    @test py["py_plain"].arg_abis == [""]
end
