# Test cases converted from examples/struct_examples.jl
using RustCall
using Test

@testset "Struct Examples" begin
    if !RustCall.check_rustc_available()
        @warn "rustc not found, skipping struct examples tests"
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
