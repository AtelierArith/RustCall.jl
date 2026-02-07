# Test cases for #[julia] attribute support (Phase 5)
using RustCall
using Test

@testset "Julia Attribute Support" begin

    @testset "parse_julia_functions" begin
        # Test basic function parsing
        code1 = """
        #[julia]
        fn add(a: i32, b: i32) -> i32 {
            a + b
        }
        """
        sigs = RustCall.parse_julia_functions(code1)
        @test length(sigs) == 1
        @test sigs[1].name == "add"
        @test sigs[1].arg_names == ["a", "b"]
        @test sigs[1].arg_types == ["i32", "i32"]
        @test sigs[1].return_type == "i32"
        @test sigs[1].is_generic == false

        # Test pub fn parsing
        code2 = """
        #[julia]
        pub fn multiply(x: f64, y: f64) -> f64 {
            x * y
        }
        """
        sigs = RustCall.parse_julia_functions(code2)
        @test length(sigs) == 1
        @test sigs[1].name == "multiply"
        @test sigs[1].arg_types == ["f64", "f64"]
        @test sigs[1].return_type == "f64"

        # Test void return type
        code3 = """
        #[julia]
        fn do_nothing(a: i32) {
            println!("value: {}", a);
        }
        """
        sigs = RustCall.parse_julia_functions(code3)
        @test length(sigs) == 1
        @test sigs[1].return_type == "()"

        # Test multiple functions
        code4 = """
        #[julia]
        fn func1(a: i32) -> i32 { a }

        #[no_mangle]
        pub extern "C" fn not_julia(a: i32) -> i32 { a }

        #[julia]
        fn func2(b: f32) -> f32 { b }
        """
        sigs = RustCall.parse_julia_functions(code4)
        @test length(sigs) == 2
        @test sigs[1].name == "func1"
        @test sigs[2].name == "func2"

        # Test no #[julia] functions
        code5 = """
        #[no_mangle]
        pub extern "C" fn regular_fn(a: i32) -> i32 { a }
        """
        sigs = RustCall.parse_julia_functions(code5)
        @test length(sigs) == 0
    end

    @testset "transform_julia_attribute" begin
        # Test basic transformation
        code1 = "#[julia]\nfn add(a: i32, b: i32) -> i32 { a + b }"
        result1 = RustCall.transform_julia_attribute(code1)
        @test occursin("#[no_mangle]", result1)
        @test occursin("pub extern \"C\" fn add", result1)
        @test !occursin("#[julia]", result1)

        # Test pub fn transformation
        code2 = "#[julia]\npub fn multiply(x: f64) -> f64 { x * 2.0 }"
        result2 = RustCall.transform_julia_attribute(code2)
        @test occursin("#[no_mangle]", result2)
        @test occursin("pub extern \"C\" fn multiply", result2)

        # Test inline attribute
        code3 = "#[julia] fn inline_fn(a: i32) -> i32 { a }"
        result3 = RustCall.transform_julia_attribute(code3)
        @test occursin("pub extern \"C\" fn inline_fn", result3)

        # Test mixed code (some with #[julia], some without)
        code4 = """
        #[julia]
        fn with_julia(a: i32) -> i32 { a }

        #[no_mangle]
        pub extern "C" fn already_ffi(b: i32) -> i32 { b }
        """
        result4 = RustCall.transform_julia_attribute(code4)
        @test occursin("pub extern \"C\" fn with_julia", result4)
        @test occursin("pub extern \"C\" fn already_ffi", result4)  # unchanged
    end

    @testset "has_julia_attribute" begin
        @test RustCall.has_julia_attribute("#[julia]\nfn test() {}")
        @test RustCall.has_julia_attribute("code\n#[julia]\nfn test() {}")
        @test !RustCall.has_julia_attribute("#[no_mangle]\nfn test() {}")
        @test !RustCall.has_julia_attribute("fn test() {}")
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

    if check_rustc_available()
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
    end
end
