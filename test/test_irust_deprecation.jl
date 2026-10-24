# `@irust` / `irust"..."` are deprecated (#538).
#
# The macros still work. Each expansion site logs one deprecation warning that
# names the replacement, and the manual's "Migrating from `@irust`" section
# gives a `rust"""` form for every documented snippet. The last testset runs
# that section's code blocks as written, so a pair whose two halves stop
# agreeing, or a migration example that no longer compiles, fails here rather
# than in a reader's session.

using Test
using RustCall
# `Logging` is not a test dependency; its names live in `Base.CoreLogging`.
using Base.CoreLogging: with_logger, NullLogger
const Logging = Base.CoreLogging

const _DEPRECATION_RUSTC_AVAILABLE = RustCall.check_rustc_available()
const _DEPRECATION_PATTERN = r"is deprecated.*#538.*rust\"\"\"\.\.\.\"\"\""

# Expand `ex` in `mod` and return the expansion plus every log record it emitted.
function _expand_logged(mod::Module, ex)
    logger = Test.TestLogger(min_level = Logging.Debug)
    expanded = with_logger(() -> macroexpand(mod, ex), logger)
    return expanded, logger.logs
end

_deprecations(logs) = filter(l -> l.level == Logging.Warn && l.group === :depwarn, logs)

# The migration section of the manual, as `(before/after code block)` strings.
function _migration_blocks()
    text = read(joinpath(dirname(@__DIR__), "docs", "src", "index.md"), String)
    start = findfirst("### 3. Migrating from `@irust`", text)
    start === nothing && error("docs/src/index.md has no \"Migrating from `@irust`\" section")
    stop = findnext("\n### ", text, last(start))
    section = text[first(start):(stop === nothing ? lastindex(text) : first(stop))]
    blocks = String[]
    for m in eachmatch(r"```julia\n(.*?)```"s, section)
        push!(blocks, m.captures[1])
    end
    return blocks
end

# `code  # => annotation` -> (code, true, annotation); (line, false, "") otherwise.
function rpartition_comment(line::AbstractString)
    i = findfirst("# =>", line)
    i === nothing && return (String(line), false, "")
    return (String(line[1:(first(i) - 1)]), true, String(line[(last(i) + 1):end]))
end

# `value  :: Type` or `value` after a `# =>` comment.
function _expected(annotation::AbstractString)
    parts = split(annotation, "::")
    value = Core.eval(Main, Meta.parse(strip(parts[1])))
    type = length(parts) > 1 ? Core.eval(Main, Meta.parse(strip(parts[2]))) : nothing
    return value, type
end

@testset "@irust deprecation (#538)" begin
    @testset "@irust warns once per expansion site, at the caller" begin
        mod = Module()
        Core.eval(mod, :(using RustCall))
        site = LineNumberNode(4242, Symbol("caller_file.jl"))
        ex = Expr(:macrocall, Symbol("@irust"), site, "\$x * 2")
        expanded, logs = _expand_logged(mod, ex)
        warnings = _deprecations(logs)
        @test length(warnings) == 1
        w = only(warnings)
        @test occursin(_DEPRECATION_PATTERN, w.message)
        @test occursin("`@irust`", w.message)
        @test occursin("Migrating from `@irust`", w.message)
        @test w.file == "caller_file.jl"
        @test w.line == 4242
        @test w._module === mod
        # The expansion itself is what it was before the deprecation.
        @test expanded == Expr(:call, GlobalRef(RustCall, :_compile_and_call_irust), "arg1 * 2", :x)

        # The same site again in one session: no second warning (`maxlog = 1`).
        logger = Test.TestLogger(min_level = Logging.Debug)
        with_logger(logger) do
            macroexpand(mod, ex)
            macroexpand(mod, ex)
        end
        @test length(_deprecations(logger.logs)) == 1

        # Another site warns on its own.
        other = Expr(:macrocall, Symbol("@irust"), LineNumberNode(7, Symbol("caller_file.jl")), "1 + 1")
        @test length(_deprecations(last(_expand_logged(mod, other)))) == 1
    end

    @testset "irust\"...\" warns and names its own form" begin
        mod = Module()
        Core.eval(mod, :(using RustCall))
        ex = Expr(:macrocall, Symbol("@irust_str"), LineNumberNode(9, Symbol("lit.jl")), "40 + 2")
        expanded, logs = _expand_logged(mod, ex)
        w = only(_deprecations(logs))
        @test occursin(_DEPRECATION_PATTERN, w.message)
        @test occursin("`irust\"...\"`", w.message)
        @test (w.file, w.line) == ("lit.jl", 9)
        @test expanded == Expr(:call, GlobalRef(RustCall, :_compile_and_call_irust), "40 + 2")
    end

    @testset "--depwarn=error turns the warning into an error" begin
        script = """
            using RustCall
            try
                macroexpand(Main, :(@irust("40 + 2")))
                println("no error")
            catch err
                msg = sprint(showerror, err)
                println(occursin("is deprecated", msg) && occursin("#538", msg) ?
                    "deprecation error" : "other error: " * msg)
            end
            """
        project = dirname(@__DIR__)
        result = read(`$(Base.julia_cmd()) --startup-file=no --depwarn=error --project=$project -e $script`, String)
        @test occursin("deprecation error", result)
    end

    @testset "the deprecated macros still return the same values" begin
        if !_DEPRECATION_RUSTC_AVAILABLE
            @test_skip "rustc is required to compile @irust snippets"
        else
            mod = Module()
            Core.eval(mod, :(using RustCall; x = Int64(21)))
            for (ex, expected) in (
                    (Expr(:macrocall, Symbol("@irust"), LineNumberNode(1), "\$x * 2"), 42),
                    (Expr(:macrocall, Symbol("@irust_str"), LineNumberNode(2), "40 + 2"), 42),
                    (Expr(:macrocall, Symbol("@irust"), LineNumberNode(3), "arg1 + 1", :x), 22))
                expanded, logs = _expand_logged(mod, ex)
                @test length(_deprecations(logs)) == 1
                result = Core.eval(mod, expanded)
                @test result === Int64(expected)
            end
        end
    end

    @testset "every migration pair in the manual agrees" begin
        blocks = _migration_blocks()
        # Each block shows a `# before` and an `# after` half.
        @test length(blocks) >= 4
        @test all(b -> occursin("# before", b) && occursin("# after", b), blocks)
        if !_DEPRECATION_RUSTC_AVAILABLE
            @test_skip "rustc is required to run the migration examples"
        else
            for block in blocks
                mod = Module()
                Core.eval(mod, :(using RustCall))
                checks = Tuple{String, String}[]
                for line in split(block, '\n')
                    code, sep, annotation = rpartition_comment(line)
                    sep && push!(checks, (code, annotation))
                end
                @test !isempty(checks)
                # Define everything the block defines, then evaluate every
                # annotated line again and compare with its annotation. The
                # deprecation warnings of the `# before` half are expected.
                with_logger(NullLogger()) do
                    for ex in Meta.parseall(block).args
                        ex isa LineNumberNode && continue
                        Core.eval(mod, ex)
                    end
                end
                for (code, annotation) in checks
                    value, type = _expected(annotation)
                    result = with_logger(() -> Core.eval(mod, Meta.parse(code)), NullLogger())
                    @test result == value
                    type === nothing || @test result isa type
                end
            end
        end
    end
end
