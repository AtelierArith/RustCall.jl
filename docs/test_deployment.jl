module DocumentationDeploymentTests

using Documenter
using Test
include("deployment.jl")

@testset "documentation deployment preflight" begin
    # Check Documenter's real decision without deploying or making HTTP calls.
    # Synthetic push events cover both development and release deployments.
    withenv("GITHUB_ACTOR" => "documentation-test",
            "GITHUB_TOKEN" => "test-only-not-a-real-token",
            "DOCUMENTER_KEY" => nothing) do
        for lang in ("en", "ja")
            options = documentation_deployment(lang)
            for (ref, subdir) in (("refs/heads/main", "dev"),
                                  ("refs/tags/v0.10.0", "v0.10.0"))
                config = Documenter.GitHubActions("AtelierArith/RustCall.jl", "push", ref)
                decision = Documenter.deploy_folder(config; options..., devurl = "dev")
                @test decision.all_ok
                @test joinpath(options.dirname, decision.subfolder) == joinpath(lang, subdir)
                @test options.target == joinpath("build", lang)
                @test decision.branch == "gh-pages"
            end
        end
    end
    @test_throws ArgumentError documentation_deployment("fr")
end

end
