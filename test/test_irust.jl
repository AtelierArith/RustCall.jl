# `@irust` has to be usable, and honest about what it cannot do.
#
# One testset per issue:
#
#   #347  an `@irust` with no interpolated variable — and therefore every
#         `irust"..."` — used to die with a `MethodError` before it compiled
#         anything;
#   #349  the snippet used to be wrapped as `return <snippet>;`, so it had to
#         be a single expression: no `let`, no loop, no early `return`;
#   #350  the `$$` escape was documented but not implemented, so a literal `$`
#         (a `macro_rules!` metavariable) could not be written;
#   #346  a panic inside a snippet aborted the process. That one also has a
#         testset in `test_panics.jl`, next to the rest of the panic contract;
#   #348  the return type was guessed with regexes over the Rust source and was
#         wrong for most real snippets; it now comes from rustc.
#
# The last testset pins the *documented* limitations, so the manual and the
# code cannot drift apart.

using Test
using RustCall

const _IRUST_RUSTC_AVAILABLE = RustCall.check_rustc_available()

@testset "@irust" begin

    # ----------------------------------------------------------------------
    # Pure parsing: no compiler needed, so these always run.
    # ----------------------------------------------------------------------
    @testset "interpolation rules (#350)" begin
        @test RustCall._parse_irust_variables("\$x + \$y * 2") == ([:x, :y], "arg1 + arg2 * 2")

        # The same variable twice is one parameter, numbered by first use.
        @test RustCall._parse_irust_variables("\$x * \$x") == ([:x], "arg1 * arg1")
        @test RustCall._parse_irust_variables("\$y + \$x + \$y") == ([:y, :x], "arg1 + arg2 + arg1")

        # `$$` is a literal `$` and consumes no variable. Before #350 the
        # pattern had no case for it, so `$$x` substituted the *second* `$`
        # and emitted `$arg1`.
        @test RustCall._parse_irust_variables("\$\$x") == (Symbol[], "\$x")
        @test RustCall._parse_irust_variables("\$\$") == (Symbol[], "\$")
        @test RustCall._parse_irust_variables("\$\$v:expr and \$x") == ([:x], "\$v:expr and arg1")

        # A `$` that is not a variable reference is left as written.
        @test RustCall._parse_irust_variables("\$ x") == (Symbol[], "\$ x")
        @test RustCall._parse_irust_variables("\$1 + \$x") == ([:x], "\$1 + arg1")
        @test RustCall._parse_irust_variables("no dollars here") == (Symbol[], "no dollars here")

        # `$name` matches an identifier only: `.field` is Rust's.
        @test RustCall._parse_irust_variables("\$obj.field") == ([:obj], "arg1.field")

        # Substitution is textual, so it reaches inside Rust string literals
        # too — documented, and `$$` is the way out of it.
        @test RustCall._parse_irust_variables("\"\$x\".len()") == ([:x], "\"arg1\".len()")
        @test RustCall._parse_irust_variables("\"\$\$x\".len()") == (Symbol[], "\"\$x\".len()")
    end

    # The generated item is a `#[julia]` function whose body is the snippet
    # verbatim — that is what gives it a panic boundary (#346) and lets
    # statements work (#349).
    @testset "the generated item (#346, #349)" begin
        src = RustCall._generate_irust_function("irust_func_test", "let t = arg1 * 2;\nt + 1",
                                                ["i64"], "i64")
        @test occursin("#[julia]", src)
        @test occursin("pub fn irust_func_test(arg1: i64) -> i64", src)
        # The snippet is not rewritten: no `return <snippet>;` wrapping.
        @test occursin("let t = arg1 * 2;\nt + 1", src)
        @test !occursin("return let", src)
        # No hand-written entry point: the boundary comes from the expansion.
        @test !occursin("no_mangle", src)
        @test !occursin("extern \"C\"", src)
    end

    # The type probe reads rustc's `--error-format=json` output as data. The
    # reader itself needs no compiler.
    @testset "rustc diagnostics are read as data (#348)" begin
        @test RustCall.parse_json("{\"a\": [1, 2.5, true, null], \"b\": \"x\\ny\"}") ==
              Dict{String, Any}("a" => Any[1, 2.5, true, nothing], "b" => "x\ny")
        @test RustCall.parse_json("\"\\u00e9\\u0041\"") == "éA"
        @test RustCall.parse_json("[]") == Any[]
        @test RustCall.parse_json("{}") == Dict{String, Any}()
        @test_throws RustCall.JSONParseError RustCall.parse_json("{\"a\": }")
        @test_throws RustCall.JSONParseError RustCall.parse_json("[1, 2")

        line = "{\"\$message_type\":\"diagnostic\",\"message\":\"mismatched types\"," *
               "\"code\":{\"code\":\"E0308\"},\"level\":\"error\"," *
               "\"spans\":[{\"is_primary\":true,\"label\":\"expected `()`, found `i64`\"}]," *
               "\"children\":[],\"rendered\":\"error[E0308]: mismatched types\\n\"}"
        diagnostics = RustCall.rustc_diagnostics("some noise\n" * line * "\n")
        @test length(diagnostics) == 1
        d = only(diagnostics)
        @test RustCall.diagnostic_level(d) == "error"
        @test RustCall.diagnostic_code(d) == "E0308"
        @test RustCall.primary_span_label(d) == "expected `()`, found `i64`"
        @test RustCall._probe_constraint_from_diagnostic(d) == "i64"

        # An unconstrained literal names no type. The constraint stays a
        # symbol here; `_reconcile_probe_types` turns it into a spelling once
        # every return site has been seen.
        unconstrained(found) = Dict{String, Any}(
            "code" => Dict{String, Any}("code" => "E0308"), "level" => "error",
            "spans" => Any[Dict{String, Any}("is_primary" => true,
                                             "label" => "expected `()`, found " * found)])
        @test RustCall._probe_constraint_from_diagnostic(unconstrained("integer")) === :integer
        @test RustCall._probe_constraint_from_diagnostic(unconstrained("floating-point number")) === :float

        # Anything that is not the probe's own `()` mismatch is a real error.
        other = Dict{String, Any}(
            "code" => Dict{String, Any}("code" => "E0599"), "level" => "error",
            "spans" => Any[Dict{String, Any}("is_primary" => true,
                                             "label" => "method not found in `i64`")])
        @test RustCall._probe_constraint_from_diagnostic(other) === nothing
    end

    # A snippet with several return sites produces one diagnostic each, and the
    # probe's `()` return type keeps them from unifying with each other the way
    # they will in the real function. Taking the first is wrong (Codex review of
    # PR #354): `if flag { return 0; } x` with an `i32` `x` would have been
    # built as `-> i64`.
    @testset "every return site is reconciled (#348)" begin
        # A concrete type beats an unconstrained literal.
        @test RustCall._reconcile_probe_types(Any[:integer, "i32"]) == "i32"
        @test RustCall._reconcile_probe_types(Any["i32", :integer]) == "i32"
        @test RustCall._reconcile_probe_types(Any[:float, "f32"]) == "f32"
        @test RustCall._reconcile_probe_types(Any["u8", "u8", :integer]) == "u8"

        # Nothing but variables: Julia's defaults.
        @test RustCall._reconcile_probe_types(Any[:integer]) == "i64"
        @test RustCall._reconcile_probe_types(Any[:integer, :integer]) == "i64"
        @test RustCall._reconcile_probe_types(Any[:float]) == "f64"

        # No single type satisfies every site.
        @test RustCall._reconcile_probe_types(Any["i32", "i64"]) === nothing
        @test RustCall._reconcile_probe_types(Any[:integer, :float]) === nothing
        @test RustCall._reconcile_probe_types(Any[:float, "i32"]) === nothing
        @test RustCall._reconcile_probe_types(Any[:integer, "bool"]) === nothing
        @test RustCall._reconcile_probe_types(Any[]) === nothing

        # A non-scalar concrete type is still one type; the FFI check refuses
        # it later, with a message that names rust\"\"\".
        @test RustCall._reconcile_probe_types(Any["String"]) == "String"
    end

    if !_IRUST_RUSTC_AVAILABLE
        @test_skip "rustc is required to compile @irust snippets"
    else

        # ------------------------------------------------------------------
        # #347: no interpolated variable at all.
        # ------------------------------------------------------------------
        @testset "no interpolated variable (#347)" begin
            @test @irust("40 + 2") == 42
            @test @irust("return 42;") == 42
            @test irust"40 + 2" == 42

            # An integer, a float and a bool each come back with the right
            # Julia type.
            @test @irust("40 + 2") isa Integer
            @test @irust("return 1.5;") === 1.5
            @test @irust("1.5 * 2.0") === 3.0
            @test @irust("1 > 0") === true
            @test @irust("return false;") === false
        end

        @testset "the irust\"\" literal interpolates too (#347)" begin
            # A non-standard string literal is not interpolated by Julia, so
            # `$x` reaches the macro as written — and now means the same thing
            # it means in `@irust("\$x")`.
            x = Int64(21)
            @test irust"$x * 2" == 42
            @test irust"$x + $x" == 42
            y = Int64(2)
            @test irust"$x * $y" == 42
        end

        # ------------------------------------------------------------------
        # #349: statements, loops, early returns, multi-line snippets.
        # ------------------------------------------------------------------
        @testset "statements and blocks (#349)" begin
            x = Int64(7)
            k = Int64(10)
            flag = true

            # a `let` binding, then a value
            @test @irust("let t = \$x * 2; t + 1") == 15

            # a `let` binding, then an explicit return
            @test @irust("let t = \$x * 2; return t + 1;") == 15

            # a `for` loop accumulating
            @test @irust("let mut s = 0i64; for i in 0..\$k { s += i; } return s;") == 45

            # an early `return`
            @test @irust("if \$flag { return 1; } return 0;") == 1

            # a trailing block expression
            @test @irust("{ let t = \$x; t * 3 }") == 21

            # multi-line snippets: newlines were never the problem
            @test @irust("""
                let mut s = 0i64;
                for i in 0..\$k {
                    s += i;
                }
                s
                """) == 45

            # a bare expression and an explicit return both still work
            @test @irust("\$x * 2") == 14
            @test @irust("return \$x * 2;") == 14
        end

        # ------------------------------------------------------------------
        # #350: the escape, in a snippet that needs it.
        # ------------------------------------------------------------------
        @testset "a literal \$ reaches Rust (#350)" begin
            x = Int64(7)
            # `macro_rules!` names its metavariables with `$`, which is only
            # writable through the escape.
            @test @irust("""
                {
                    macro_rules! is_positive { (\$\$v:expr) => { \$\$v > 0 } }
                    is_positive!(\$x)
                }
                """) === true
        end

        # ------------------------------------------------------------------
        # #346: a panic is an exception, not an abort. (`test_panics.jl` has
        # the same contract next to the other compile paths.)
        # ------------------------------------------------------------------
        @testset "a panic is catchable (#346)" begin
            x = Int64(7)
            z = Int64(0)
            @test_throws RustCall.RustPanicError @irust("\$x / \$z")

            err = try
                @irust("panic!(\"irust boom\"); 0i64")
                nothing
            catch e
                e
            end
            @test err isa RustCall.RustPanicError
            @test occursin("irust boom", err.message)

            # The channel is cleared when it is read, so one panic must not
            # poison the snippet or the session: the same snippet panics
            # again, a different one still returns, and we are still here.
            @test_throws RustCall.RustPanicError @irust("\$x / \$z")
            @test @irust("\$x * 2") == 14
            @test 1 + 1 == 2
        end

        # ------------------------------------------------------------------
        # The shapes that already worked keep working.
        # ------------------------------------------------------------------
        @testset "existing shapes" begin
            x = Int64(21)
            a = Int32(10)
            b = Int32(20)
            f = 3.0
            g = 4.0
            u = UInt8(200)
            i32 = Int32(21)

            @test @irust("\$x * 2") == 42
            @test @irust("arg1 * 2", x) == 42
            @test @irust("\$a + \$b") == Int32(30)
            @test @irust("arg1 + arg2", a, b) == Int32(30)
            @test @irust("\$f * \$g") ≈ 12.0
            @test @irust("\$x * \$x") == 441          # the same variable twice
            @test @irust("\$a > \$b") === false        # a Bool result
            @test @irust("\$b > \$a") === true
            @test @irust("\$u / 2") === UInt8(100)     # a UInt8 argument
            @test @irust("\$i32 + 1") === Int32(22)    # an Int32 argument
        end

        # ------------------------------------------------------------------
        # #348: the return type is rustc's, not a regex's. Every row of the
        # table in the issue (and of the follow-up comment) must come back
        # with the right value *and* the right Julia type. The rows marked
        # "was" are the ones the old heuristic got wrong.
        # ------------------------------------------------------------------
        @testset "the return type comes from rustc (#348)" begin
            x = Int64(7)
            f = 3.5
            b = true
            g = Float32(1.5)
            u = UInt64(8)

            @test @irust("\$x > 0") === true                       # bool
            @test @irust("if \$x > 0 { 1 } else { -1 }") === Int64(1)   # was bool
            @test @irust("\$x as f64") === 7.0                     # was i64
            @test @irust("\$b as i64 + 1") === Int64(2)            # was bool
            @test @irust("\$x + \$f as i64") === Int64(10)         # was f64
            @test @irust("\$g * 2.0f32") === Float32(3.0)          # was f64
            @test @irust("\$x / 2") === Int64(3)                   # unchanged
            @test @irust("\$f * 2.0") === 7.0                      # unchanged

            # `->` and `=>` are not comparisons: an inner `fn`, an inner
            # `struct` + `impl`, and a `match` arm all used to be called bool.
            @test @irust("{ fn helper(v: i64) -> i64 { v * v }  helper(\$x) }") === Int64(49)
            @test @irust("""
                {
                    struct P { a: i64 }
                    impl P { fn double(&self) -> i64 { self.a * 2 } }
                    P { a: \$x }.double()
                }
                """) === Int64(14)
            @test @irust("{ match \$x { v if v < 0 => -v, v => v } }") === Int64(7)

            # Methods whose result type is not any argument's type.
            @test @irust("\$u.is_power_of_two()") === true
            @test @irust("\$f.is_finite()") === true
            @test @irust("\$f.to_bits() as i64") === reinterpret(Int64, 3.5)

            # Unsuffixed literals: rustc leaves them free, and the probe pins
            # them to what Julia would use.
            @test @irust("40 + 2") === Int64(42)
            @test @irust("return 42;") === Int64(42)
            @test @irust("return 1.5;") === 1.5

            # A snippet whose value is `()`.
            @test @irust("let _unused = \$x * 2;") === nothing

            # Several return sites, reconciled rather than decided by the
            # first (Codex review of PR #354). The literal `0` reads as an
            # unconstrained integer and the tail as its own type; the concrete
            # one wins, because the literal unifies with it.
            flag = true
            x32 = Int32(21)
            @test @irust("if \$flag { return 0; } \$x32") === Int32(0)
            @test @irust("if \$flag { return 0; } \$x") === Int64(0)
            @test @irust("if \$flag { return 0.0; } \$f") === 0.0

            # Sites that genuinely disagree are refused, by name, instead of
            # being built as one of them and failing in rustc.
            err = try
                @irust("if \$flag { return 1i64; } \$x32")
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("one return type", sprint(showerror, err))
            @test occursin("i64", sprint(showerror, err))
            @test occursin("i32", sprint(showerror, err))
            @test_throws ErrorException @irust("if \$flag { return 1.5; } \$x")

            # The probe is compiled with the flags that decide `#[cfg]`
            # predicates, so it sees the same snippet the build does
            # (`debug_assertions` is on at opt-level 0 and off above it). If
            # the two disagreed, one branch would be probed and the other
            # built, and the generated signature would not compile.
            @test @irust("""
                #[cfg(debug_assertions)] let v = 1i32;
                #[cfg(not(debug_assertions))] let v = 1i64;
                v
                """) == 1

            # A snippet with a genuine error: the message is rustc's own
            # diagnostic about the *snippet*, not about generated source.
            err = try
                @irust("\$x.no_such_method()")
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            msg = sprint(showerror, err)
            @test occursin("E0599", msg)
            @test occursin("no_such_method", msg)
        end

        # ------------------------------------------------------------------
        # The documented limitations. These are `@test_throws`, not wishes:
        # if one of them starts working, the manual is wrong and this fails.
        # ------------------------------------------------------------------
        @testset "documented limitations" begin
            # Scalars only. The error names the type the user passed.
            err = try
                RustCall._compile_and_call_irust("arg1", "a string")
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("Unsupported Julia type for @irust", sprint(showerror, err))
            @test occursin("String", sprint(showerror, err))

            for bad in (Int128(3), [1, 2, 3], 1 + 2im)
                @test_throws ErrorException RustCall._compile_and_call_irust("arg1", bad)
            end

            # A non-scalar *result* is refused with a message that names
            # rust\"\"\" rather than a mangled ccall.
            err = try
                @irust("format!(\"{}\", 1)")
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("rust\"\"\"", sprint(showerror, err))

            # 128-bit integers are refused on the *result* side too, not just
            # as arguments (Codex review of PR #354). The FFI contract knows
            # `i128`/`u128` as by-value types, but they do not round-trip on
            # x86_64-pc-windows-msvc (rust-lang/rust#54341), and the promised
            # scalar set stops at 64 bits.
            @test !("i128" in RustCall.IRUST_SCALAR_RUST_TYPES)
            @test !("u128" in RustCall.IRUST_SCALAR_RUST_TYPES)
            for wide in ("1i128", "1u128")
                err = try
                    RustCall._compile_and_call_irust(wide)
                    nothing
                catch e
                    e
                end
                @test err isa ErrorException
                @test occursin("@irust cannot return", sprint(showerror, err))
            end

            # The two directions read one table, so they cannot drift.
            @test Set(RustCall.IRUST_SCALAR_RUST_TYPES) ==
                  Set(RustCall._julia_to_rust_type(T)
                      for T in keys(RustCall.IRUST_SCALAR_TYPES))
            @test_throws ErrorException RustCall._julia_to_rust_type(Int128)

            # `$obj.field` interpolates `obj` only — the documented rule, and
            # the reason a field access reads oddly.
            @test RustCall._parse_irust_variables("\$obj.field") == ([:obj], "arg1.field")
        end

        # ------------------------------------------------------------------
        # The memo carries what the snippet was built with (#346): a second
        # call must not re-derive the symbol or the return type.
        # ------------------------------------------------------------------
        @testset "the memo is a snapshot" begin
            x = Int64(21)
            keys_before = Set(keys(RustCall.IRUST_FUNCTIONS))
            @test @irust("\$x * 2 + 0") == 42
            fresh = setdiff(Set(keys(RustCall.IRUST_FUNCTIONS)), keys_before)
            @test length(fresh) == 1
            snippet = RustCall.IRUST_FUNCTIONS[only(fresh)]
            @test snippet isa RustCall.IrustSnippet
            # The call goes through the generated wrapper's symbol, which is
            # what carries the panic boundary.
            @test startswith(snippet.symbol, "rustcall_irust_func_")
            @test snippet.return_type === Int64
            @test haskey(RustCall.RUST_LIBRARIES, snippet.lib_name)
            # A cache hit returns the same value through the stored snapshot.
            @test @irust("\$x * 2 + 0") == 42
        end
    end
end
