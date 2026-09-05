# A Rust panic is a catchable Julia exception, on every compile path (#244).
#
# The acceptance criteria of the issue, one testset each:
#
#   1. a `#[julia]` function that panics raises a catchable Julia exception
#      carrying the panic message, and the Julia process survives;
#   2. the behaviour is identical regardless of which compile path produced the
#      library — direct `rustc`, Cargo, and a `@rust_crate` crate;
#   3. `@test_throws RustCall.RustPanicError @rust panicky()`.
#
# Every testset also asserts that the *next* call still works: the channel is
# cleared when it is read, so one panic must not poison the library.

using Test
using RustCall

const _PANIC_RUSTC_AVAILABLE = RustCall.check_rustc_available()

@testset "Rust panics become RustPanicError (#244)" begin

    if !_PANIC_RUSTC_AVAILABLE
        @test_skip "rustc is required to compile a panicking function"
    else

        # ------------------------------------------------------------------
        # Path 1: direct rustc (`rust\"\"\"` with no dependencies).
        # ------------------------------------------------------------------
        rust"""
        #[julia]
        fn panic_rustc(a: i32) -> i32 {
            if a < 0 { panic!("panic_rustc refuses {}", a); }
            a * 2
        }

        #[julia]
        fn panic_rustc_assert(n: i32) -> i32 {
            assert!(n > 0, "n must be positive, got {}", n);
            n
        }

        #[julia]
        fn panic_rustc_unwrap(present: bool) -> i32 {
            let v: Option<i32> = if present { Some(7) } else { None };
            v.unwrap()
        }

        #[julia]
        fn panic_rustc_index(i: usize) -> i32 {
            let values = vec![10i32, 20, 30];
            values[i]
        }

        #[julia]
        fn panic_rustc_string(a: i32) -> String {
            if a < 0 { panic!("panic_rustc_string refuses {}", a); }
            format!("value {}", a)
        }

        #[julia]
        fn panic_rustc_result(a: i32) -> Result<i32, i32> {
            if a < 0 { panic!("panic_rustc_result refuses {}", a); }
            Ok(a)
        }

        #[julia]
        fn panic_rustc_option(a: i32) -> Option<i32> {
            if a < 0 { panic!("panic_rustc_option refuses {}", a); }
            Some(a)
        }
        """

        @testset "direct rustc: every panic class" begin
            # The happy path is unaffected.
            @test panic_rustc(Int32(21)) == Int32(42)

            @test_throws RustCall.RustPanicError panic_rustc(Int32(-1))
            @test_throws RustCall.RustPanicError panic_rustc_assert(Int32(-2))
            @test_throws RustCall.RustPanicError panic_rustc_unwrap(false)
            @test_throws RustCall.RustPanicError panic_rustc_index(UInt(9))
            @test_throws RustCall.RustPanicError panic_rustc_string(Int32(-1))
            @test_throws RustCall.RustPanicError panic_rustc_result(Int32(-1))
            @test_throws RustCall.RustPanicError panic_rustc_option(Int32(-1))

            # The message carries the panic text and names the function.
            err = try
                panic_rustc(Int32(-5))
                nothing
            catch e
                e
            end
            @test err isa RustCall.RustPanicError
            @test occursin("panic_rustc refuses -5", err.message)
            @test err.func_name == "panic_rustc"
            @test occursin("panic_rustc refuses -5", sprint(showerror, err))

            # Rust's own wording survives for the built-in panics.
            err = try
                panic_rustc_unwrap(false)
                nothing
            catch e
                e
            end
            @test occursin("unwrap()", err.message)
            err = try
                panic_rustc_index(UInt(9))
                nothing
            catch e
                e
            end
            @test occursin("index out of bounds", err.message)

            # ...and the library is still usable: the channel was cleared, so a
            # later successful call does not inherit the pending message.
            @test panic_rustc(Int32(4)) == Int32(8)
            @test panic_rustc_string(Int32(4)) == "value 4"
            @test panic_rustc_result(Int32(4)) == RustCall.RustResult{Int32, Int32}(true, Int32(4))
            @test panic_rustc_assert(Int32(3)) == Int32(3)
        end

        @testset "@rust reaches the same boundary" begin
            # The acceptance criterion, verbatim.
            @test_throws RustCall.RustPanicError @rust panic_rustc(Int32(-1))
            @test (@rust panic_rustc(Int32(6))) == Int32(12)
            # ...and with an explicit return type, which takes the other call
            # path (`_rust_call_typed` rather than `_rust_call_dynamic`).
            @test_throws RustCall.RustPanicError @rust panic_rustc(Int32(-1))::Int32
            @test (@rust panic_rustc(Int32(6))::Int32) == Int32(12)
        end

        @testset "a panic does not leak into another function" begin
            @test_throws RustCall.RustPanicError panic_rustc(Int32(-1))
            # A *different* wrapper has its own channel, so it is unaffected.
            @test panic_rustc_assert(Int32(1)) == Int32(1)
        end

        # ------------------------------------------------------------------
        # Path 2: Cargo (`// cargo-deps:`). Same source shape, same outcome —
        # criterion (2), "identical regardless of which compile path".
        # ------------------------------------------------------------------
        cargo_available = try
            success(run(pipeline(`cargo --version`, devnull, devnull); wait = true))
        catch
            false
        end

        if !cargo_available
            @test_skip "cargo is required for the Cargo-path panic test"
        else
            rust"""
            // cargo-deps: libc="0.2"

            #[julia]
            fn panic_cargo(a: i32) -> i32 {
                if a < 0 { panic!("panic_cargo refuses {}", a); }
                a * 2
            }

            #[julia]
            fn panic_cargo_string(a: i32) -> String {
                if a < 0 { panic!("panic_cargo_string refuses {}", a); }
                format!("value {}", a)
            }
            """

            @testset "Cargo path: identical behaviour" begin
                @test panic_cargo(Int32(21)) == Int32(42)
                @test_throws RustCall.RustPanicError panic_cargo(Int32(-1))
                err = try
                    panic_cargo(Int32(-7))
                    nothing
                catch e
                    e
                end
                @test err isa RustCall.RustPanicError
                @test occursin("panic_cargo refuses -7", err.message)
                @test err.func_name == "panic_cargo"
                @test panic_cargo(Int32(5)) == Int32(10)

                @test_throws RustCall.RustPanicError panic_cargo_string(Int32(-1))
                @test panic_cargo_string(Int32(2)) == "value 2"
            end

            @testset "the two compile paths agree" begin
                # Same panic, same exception type, same message shape.
                rustc_err = try
                    panic_rustc(Int32(-3))
                catch e
                    e
                end
                cargo_err = try
                    panic_cargo(Int32(-3))
                catch e
                    e
                end
                @test typeof(rustc_err) === typeof(cargo_err) === RustCall.RustPanicError
                @test occursin("refuses -3", rustc_err.message)
                @test occursin("refuses -3", cargo_err.message)
                # ...and the policies say so, which is what keeps them together.
                @test RustCall.inline_rustc_policy().panic_strategy ===
                      RustCall.inline_cargo_policy().panic_strategy === :unwind
                @test RustCall.inline_rustc_policy().boundary_catches_panics
                @test RustCall.inline_cargo_policy().boundary_catches_panics
            end
        end

        # ------------------------------------------------------------------
        # The process survived all of it — the point of the whole issue.
        # ------------------------------------------------------------------
        @testset "the session is intact" begin
            @test panic_rustc(Int32(1)) == Int32(2)
            @test 1 + 1 == 2
        end
    end
end
