# Originally derived from the deleted `examples/phase4_ndarray.jl` (removed in #9); the tests below are the reference.
using RustCall
using Test

# The same opt-in gate as `test_ndarray.jl`: this file builds a Cargo project
# against ndarray, which is the heaviest crates.io download in the suite
# (#259).
const RUN_HEAVY_INTEGRATION_TESTS =
    get(ENV, "RUSTCALL_RUN_HEAVY_INTEGRATION_TESTS", "false") == "true"

@testset "Phase 4: ndarray Example" begin
    if !RUN_HEAVY_INTEGRATION_TESTS
        @test_skip "Set RUSTCALL_RUN_HEAVY_INTEGRATION_TESTS=true to run ndarray tests"
        return
    end
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
        return
    end

    @testset "MatrixTool with ndarray" begin
        rust"""
        //! ```cargo
        //! [dependencies]
        //! ndarray = "0.15"
        //! ```

        use ndarray::Array2;

        // Array2 field accessor is skipped automatically (non-Copy type)
        #[julia]
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
