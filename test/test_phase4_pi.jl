# Test cases converted from examples/phase4_pi.jl
using RustCall
using Test

@testset "Phase 4: Monte Carlo Pi Example" begin
    if !check_rustc_available()
        @warn "rustc not found, skipping phase4_pi tests"
        return
    end

    @testset "MonteCarloPi" begin
        rust"""
        //! ```cargo
        //! [dependencies]
        //! rand = "0.8"
        //! ```

        use rand::Rng;

        #[julia]
        pub struct MonteCarloPi {
            total_samples: u64,
            inside_circle: u64,
            rng: rand::rngs::ThreadRng,
        }

        impl MonteCarloPi {
            pub fn new() -> Self {
                Self {
                    total_samples: 0,
                    inside_circle: 0,
                    rng: rand::thread_rng(),
                }
            }

            pub fn calculate(&mut self, samples: u64) -> f64 {
                for _ in 0..samples {
                    let x: f64 = self.rng.gen_range(0.0..1.0);
                    let y: f64 = self.rng.gen_range(0.0..1.0);

                    let distance_squared = x * x + y * y;
                    if distance_squared <= 1.0 {
                        self.inside_circle += 1;
                    }
                    self.total_samples += 1;
                }

                self.estimate()
            }

            pub fn estimate(&self) -> f64 {
                if self.total_samples == 0 {
                    return 0.0;
                }
                4.0 * (self.inside_circle as f64) / (self.total_samples as f64)
            }

            pub fn total_samples(&self) -> u64 {
                self.total_samples
            }

            pub fn inside_circle(&self) -> u64 {
                self.inside_circle
            }

            pub fn reset(&mut self) {
                self.total_samples = 0;
                self.inside_circle = 0;
            }
        }
        """

        calc = MonteCarloPi()
        @test calc !== nothing
        @test total_samples(calc) == 0
        @test estimate(calc) == 0.0

        # Run a small simulation
        samples = 10_000
        current_estimate = calculate(calc, UInt64(samples))

        total = total_samples(calc)
        inside = inside_circle(calc)

        @test total == samples
        @test inside <= total
        @test current_estimate >= 0.0
        @test current_estimate <= 4.0

        # Reset test
        reset(calc)
        @test total_samples(calc) == 0
        @test estimate(calc) == 0.0
    end
end
