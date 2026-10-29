# `@irust` / `irust"..."` were removed in 0.9.0 (#538), after a release of
# deprecation. What is left of them is the manual's "Migrating from `@irust`"
# section: each block shows the removed form as a comment and its `rust"""`
# replacement. The last testset runs every replacement as written, so one that
# stops compiling or computing its documented value fails here rather than in
# a reader's session.

using Test
using RustCall

# The migration section of the manual, one string per code block.
function _migration_blocks()
    # A Windows checkout may have CRLF line endings.
    text = replace(read(joinpath(dirname(@__DIR__), "docs", "src", "index.md"), String), "\r\n" => "\n")
    start = findfirst("### 3. Migrating from `@irust`", text)
    start === nothing && error("docs/src/index.md has no \"Migrating from `@irust`\" section")
    stop = findnext("\n### ", text, last(start))
    section = text[first(start):(stop === nothing ? lastindex(text) : first(stop))]
    return String[m.captures[1] for m in eachmatch(r"```julia\n(.*?)```"s, section)]
end

# The half of a block after its `# after` line.
function _after_half(block::AbstractString)
    i = findfirst("\n# after\n", block)
    i === nothing && error("a migration block has no `# after` line:\n$(block)")
    return block[(last(i) + 1):end]
end

# `code  # => annotation` -> (code, annotation); `nothing` for any other line.
function _annotated(line::AbstractString)
    i = findfirst("# =>", line)
    i === nothing && return nothing
    return (String(line[1:(first(i) - 1)]), String(line[(last(i) + 1):end]))
end

# `value  :: Type` or `value` after a `# =>` comment.
function _expected(annotation::AbstractString)
    parts = split(annotation, "::")
    value = Core.eval(Main, Meta.parse(strip(parts[1])))
    type = length(parts) > 1 ? Core.eval(Main, Meta.parse(strip(parts[2]))) : nothing
    return value, type
end

@testset "@irust is removed (#538)" begin
    @testset "neither macro is defined or exported" begin
        for name in (Symbol("@irust"), Symbol("@irust_str"))
            @test !isdefined(RustCall, name)
            @test !(name in names(RustCall))
        end
        mod = Module()
        Core.eval(mod, :(using RustCall))
        for ex in (Expr(:macrocall, Symbol("@irust"), LineNumberNode(1), "1i64"),
                   Expr(:macrocall, Symbol("@irust_str"), LineNumberNode(2), "1i64"))
            err = try
                macroexpand(mod, ex)
                nothing
            catch e
                e
            end
            # `macroexpand` wraps the error the way `include` would.
            err isa LoadError && (err = err.error)
            @test err isa UndefVarError
        end
    end

    @testset "nothing of its machinery is left" begin
        @test !any(p -> p().name == "irust", RustCall.ALL_LOAD_POLICIES)
        @test !(:irust_hash in RustCall._VALID_KEY_KINDS)
        @test isempty(filter(n -> occursin("irust", lowercase(string(n))),
                             names(RustCall; all = true)))
    end

    @testset "every replacement in the manual computes its documented value" begin
        blocks = _migration_blocks()
        @test length(blocks) >= 4
        # The removed form is shown, but only as comments: nothing in a block
        # before its `# after` line runs.
        for block in blocks
            before = block[1:(first(findfirst("\n# after\n", block)) - 1)]
            @test occursin("irust", before)
            @test all(l -> isempty(strip(l)) || startswith(l, "#"), split(before, '\n'))
        end
        if !RustCall.check_rustc_available()
            @test_skip "rustc is required to run the migration examples"
        else
            for block in blocks
                after = _after_half(block)
                checks = filter(!isnothing, map(_annotated, split(after, '\n')))
                @test !isempty(checks)
                mod = Module()
                Core.eval(mod, :(using RustCall))
                # Define everything the half defines, then evaluate every
                # annotated line again and compare with its annotation.
                for ex in Meta.parseall(after).args
                    ex isa LineNumberNode && continue
                    Core.eval(mod, ex)
                end
                for (code, annotation) in checks
                    value, type = _expected(annotation)
                    result = Core.eval(mod, Meta.parse(code))
                    @test result == value
                    type === nothing || @test result isa type
                end
            end
        end
    end
end
