using Test

const PR_BABYSIT_SKILL_PATH = joinpath(@__DIR__, "..", ".claude", "skills", "pr-babysit", "SKILL.md")

@testset "PR babysit skill review and log-search guidance" begin
    # Windows checkouts may expose CRLF even though the committed skill uses LF.
    skill = replace(read(PR_BABYSIT_SKILL_PATH, String), "\r\n" => "\n")

    @test occursin("wait until the requested Codex review for that exact", skill)
    @test occursin("A missing result or a `Running` status is pending", skill)
    @test occursin("If review is pending, its status is", skill)
    @test occursin("end this pass as pending without editing.", skill)

    command = match(r"(?m)^rg -n -e \"([^\"]+)\" /tmp/job\.log \| head$", skill)
    @test command !== nothing

    if command !== nothing
        pattern = command.captures[1]
        diagnostic = Regex(pattern)
        log_lines = [
            "all tests passed",
            "Test Failed: sample case",
            "Error During Test at test/example.jl:1",
            "ERROR: build failed",
            "error[E123]: missing symbol",
        ]
        @test findall(line -> occursin(diagnostic, line), log_lines) == [2, 3, 4, 5]

        # Exercise the exact ripgrep flags when rg is available on this host.
        rg = Sys.which("rg")
        if rg !== nothing
            mktempdir() do dir
                log_path = joinpath(dir, "job.log")
                write(log_path, join(log_lines, "\n") * "\n")
                matches = read(`$rg -n -e $pattern $log_path`, String)
                @test split(chomp(matches), '\n') == [
                    "2:Test Failed: sample case",
                    "3:Error During Test at test/example.jl:1",
                    "4:ERROR: build failed",
                    "5:error[E123]: missing symbol",
                ]
            end
        end
    end
end
