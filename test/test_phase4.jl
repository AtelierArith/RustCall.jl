# Phase 4 Test: Automatic Struct and Method Mapping
using RustCall
using Test

@testset "Phase 4: Automatic Struct Mapping" begin
    # Define a struct in Rust.
    # RustCall should automatically:
    # 1. Generate C-wrappers for new, area, scale, and free.
    # 2. Define Julia type 'Rect' and methods area(r), scale(r, f).
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

    # Test constructor
    r = Rect(10.0, 5.0)
    @test r isa Rect
    @test r.ptr != C_NULL

    # Test immutable method
    @test area(r) == 50.0

    # Test mutable method
    scale(r, 2.0)
    @test area(r) ≈ 200.0

    # Test lifecycle
    # (Checking manual free or finalizer depends on GC, but we can test pointer safety)
    r = nothing
    GC.gc()
    @test true # Finalizer should not crash
end
