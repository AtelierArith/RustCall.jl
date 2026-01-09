# Test cases converted from examples/phase4_ndarray.jl
using LastCall
using Test

@testset "Phase 4: ndarray Example" begin
    if !check_rustc_available()
        @warn "rustc not found, skipping phase4_ndarray tests"
        return
    end

    @testset "MatrixTool with ndarray" begin
        rust"""
        //! ```cargo
        //! [dependencies]
        //! ndarray = "0.15"
        //! ```

        use ndarray::Array2;

        pub struct MatrixTool {
            data: Array2<f64>,
        }

        impl MatrixTool {
            pub fn new(rows: usize, cols: usize) -> Self {
                Self {
                    data: Array2::zeros((rows, cols)),
                }
            }

            pub fn set(&mut self, row: usize, col: usize, val: f64) {
                if let Some(v) = self.data.get_mut((row, col)) {
                    *v = val;
                }
            }

            pub fn sum(&self) -> f64 {
                self.data.sum()
            }
        }
        """

        m = MatrixTool(2, 2)
        @test m !== nothing

        set(m, 0, 0, 1.5)
        set(m, 1, 1, 2.5)

        total = sum(m)
        @test total ≈ 4.0
    end
end
