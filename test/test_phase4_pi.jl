# Originally derived from the deleted `examples/phase4_pi.jl` (removed in #9); the tests below are the reference.
using RustCall
using Test

@testset "Phase 4: Monte Carlo Pi Example" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc not found, skipping phase4_pi tests"
        return
    end

    @testset "MonteCarloPi" begin
        # The sampler is a seeded linear congruential generator written in the
        # block rather than the `rand` crate (#259). Two reasons: `rand` was
        # the only crate the default suite needed from outside the
        # repository's own dependency closure, and a test that estimates pi
        # from an unseeded thread RNG is not reproducible. The struct keeps
        # what it is here to cover — a `#[julia]` struct with a field the FFI
        # cannot expose, mutated by its methods: `std::num::Wrapping<u64>` is
        # a qualified path, which the FFI contract declines exactly as it
        # declined `rand::rngs::ThreadRng`, so no accessor is generated for it.
        rust"""
        #[julia]
        pub struct MonteCarloPi {
            total_samples: u64,
            inside_circle: u64,
            state: std::num::Wrapping<u64>,
        }

        impl MonteCarloPi {
            pub fn new() -> Self {
                Self {
                    total_samples: 0,
                    inside_circle: 0,
                    // A 64-bit linear congruential generator seeded with a
                    // constant. Not a good RNG; a deterministic one, which is
                    // what a test wants.
                    state: std::num::Wrapping(0x2545F4914F6CDD1Du64),
                }
            }

            fn next_unit(&mut self) -> f64 {
                self.state = self.state * std::num::Wrapping(6364136223846793005u64)
                    + std::num::Wrapping(1442695040888963407u64);
                // The top 53 bits, scaled into [0, 1).
                ((self.state.0 >> 11) as f64) / ((1u64 << 53) as f64)
            }

            pub fn calculate(&mut self, samples: u64) -> f64 {
                for _ in 0..samples {
                    let x: f64 = self.next_unit();
                    let y: f64 = self.next_unit();

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

        # The estimate is in the right neighbourhood: 10_000 samples of a
        # decent sampler land within a few percent of pi.
        @test isapprox(current_estimate, pi; atol = 0.1)

        # Reset test
        reset(calc)
        @test total_samples(calc) == 0
        @test estimate(calc) == 0.0

        # Seeded, so a second instance walks the same sequence. An unseeded
        # thread RNG could not promise this, and a test that cannot be
        # reproduced cannot be debugged (#259).
        again = MonteCarloPi()
        @test calculate(again, UInt64(samples)) == current_estimate
        @test inside_circle(again) == inside
    end
end
