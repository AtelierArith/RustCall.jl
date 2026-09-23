# Originally derived from the deleted `examples/struct_examples.jl` (removed in #9); the tests below are the reference.
using RustCall
using Test

@testset "Struct Examples" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping struct examples tests"
        return
    end

    @testset "Person Struct" begin
        rust"""
        #[julia]
        pub struct Person {
            age: u32,
            height: f64,
        }

        impl Person {
            pub fn new(age: u32, height: f64) -> Self {
                Self { age, height }
            }

            pub fn greet(&self) {
                // Test that method can be called
            }

            pub fn have_birthday(&mut self) {
                self.age += 1;
            }

            pub fn grow(&mut self, amount: f64) {
                self.height += amount;
            }

            pub fn get_details(&self) -> f64 {
                self.height
            }
        }
        """

        p = Person(30, 175.5)
        @test p !== nothing

        greet(p)  # Should not throw
        have_birthday(p)
        greet(p)  # Should not throw

        grow(p, 2.5)
        height = get_details(p)
        @test height ≈ 178.0
    end

    # Restored from the deleted test/test_phase4.jl (#488): the Person and
    # JuliaCounter testsets cover the same shape, but not these assertions —
    # a fresh #[julia] object's type and non-null handle, an immutable method
    # read before any mutation, a `&mut self` method that rewrites two f64
    # fields, and collection of the object without a finalizer failure.
    @testset "Rect Struct (from test_phase4.jl)" begin
        rust"""
        #[julia]
        pub struct Rect {
            w: f64,
            h: f64,
        }

        impl Rect {
            pub fn new(w: f64, h: f64) -> Self {
                Self { w, h }
            }

            pub fn area(&self) -> f64 {
                self.w * self.h
            }

            pub fn scale(&mut self, factor: f64) {
                self.w *= factor;
                self.h *= factor;
            }
        }
        """

        r = Rect(10.0, 5.0)
        @test r isa Rect
        @test getfield(r, :ptr) != C_NULL

        @test area(r) == 50.0

        scale(r, 2.0)
        @test area(r) ≈ 200.0

        # Collect an object that is no longer reachable. It is created inside
        # a function so no frame of the testset keeps it rooted.
        failures_before = RustCall.finalizer_failure_count()
        (() -> (area(Rect(1.0, 2.0)); nothing))()
        r = nothing
        for _ in 1:3
            GC.gc(true)
        end
        @test RustCall.finalizer_failure_count() == failures_before
    end

    @testset "derive(JuliaStruct) String fields" begin
        rust"""
        #[derive(JuliaStruct)]
        pub struct Label {
            name: String,
        }

        impl Label {
            pub fn new(name: String) -> Self {
                Self { name }
            }

            pub fn get_name(&self) -> String {
                self.name.clone()
            }
        }
        """

        label = Label("Alice")
        @test label.name == "Alice"
        @test get_name(label) == "Alice"
    end
end
