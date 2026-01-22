# Test cases converted from examples/generic_struct_test.jl
using LastCall
using Test

@testset "Generic Struct Test" begin
    if !check_rustc_available()
        @warn "rustc not found, skipping generic struct tests"
        return
    end

    @testset "Generic Wrapper" begin
        rust"""
        #[julia]
        pub struct Wrapper<T> {
            value: T,
        }

        impl<T> Wrapper<T> {
            pub fn new(value: T) -> Self {
                Self { value }
            }

            pub fn get_value(&self) -> T where T: Copy {
                self.value
            }

            pub fn set_value(&mut self, val: T) {
                self.value = val;
            }
        }
        """

        w = Wrapper{Int32}(Int32(42))
        @test w !== nothing

        val = get_value(w)
        @test val == 42

        set_value(w, Int32(100))
        val2 = get_value(w)
        @test val2 == 100
    end
end
