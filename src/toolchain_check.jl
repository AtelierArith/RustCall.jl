# A single preflight for the toolchain RustCall resolves (#490): which `rustc`
# and `cargo` RustToolChain hands back, whether that `rustc` is at least the
# floor the extractor's locked dependency graph declares, and whether the
# extractor Julia would run is there and speaks this release's manifest. It
# builds nothing and raises nothing; the build paths keep failing closed on
# their own (`artifact_compiler_identity`, `_parse_manifest`).

"""
    minimum_supported_rustc() -> Union{VersionNumber, Nothing}

The oldest `rustc` RustCall supports: the highest `package.rust-version`
declared by the crates `Pkg.build("RustCall")` compiles (`deps/rustcall_extract`
and `deps/rustcall_helpers`), or `nothing` when none declares one.

`deps/rustcall_extract` declares it, because its committed `Cargo.lock` —
built with `--locked` — pins dependencies whose own `rust-version` sets it
(`test/test_toolchain_check.jl` checks the declaration against that graph).
Cargo refuses an older compiler with this same number before compiling
anything, so the floor has one source.
"""
function minimum_supported_rustc()
    floor = nothing
    for crate in ("rustcall_extract", "rustcall_helpers")
        manifest = joinpath(dirname(@__DIR__), "deps", crate, "Cargo.toml")
        isfile(manifest) || continue
        declared = get(get(TOML.parsefile(manifest), "package", Dict()), "rust-version", nothing)
        declared isa AbstractString || continue
        v = tryparse(VersionNumber, declared)
        v === nothing && continue
        floor = floor === nothing ? v : max(floor, v)
    end
    return floor
end

# `rustc 1.85.0 (4d91de4e4 2025-02-17)` / `cargo 1.85.0 (d73d2caf9 2024-12-31)`:
# the second word is the release, possibly with a `-nightly` / `-beta.N` suffix.
function _toolchain_release(version_output::AbstractString)
    words = split(version_output)
    length(words) >= 2 || return nothing
    return tryparse(VersionNumber, words[2])
end

function _check_tool(getcmd, name::AbstractString)
    command = try
        string(getcmd())
    catch e
        return (; command = "", version = "", release = nothing,
                error = "RustToolChain could not resolve `$(name)`: $(sprint(showerror, e))")
    end
    version = try
        _tool_version(getcmd, name)
    catch e
        return (; command, version = "", release = nothing, error = sprint(showerror, e))
    end
    return (; command, version, release = _toolchain_release(version), error = nothing)
end

function _check_extractor()
    path = try
        extractor_path()::String
    catch e
        return (; path = "", schema = "", identity = "", error = sprint(showerror, e))
    end
    schema = try
        strip(_run_extractor(["schema-version"]))
    catch e
        return (; path, schema = "", identity = "", error = sprint(showerror, e))
    end
    schema == MANIFEST_SCHEMA_VERSION ||
        return (; path, schema = String(schema), identity = "",
                error = _schema_mismatch_message("extractor", schema))
    identity = try
        extractor_source_digest()
    catch e
        return (; path, schema = String(schema), identity = "", error = sprint(showerror, e))
    end
    return (; path, schema = String(schema), identity, error = nothing)
end

"""
    check_toolchain(; io = stdout) -> NamedTuple

Report the toolchain RustCall would build with, **without building anything**
(#490): the `rustc` and `cargo` RustToolChain resolves — the very commands every
build runs — with their versions, the minimum supported `rustc`
(`minimum_supported_rustc`), and the `rustcall-extract` binary Julia would
run, with the manifest schema it speaks. Raises nothing: every problem is
listed instead, so this is the first thing to run when a build fails deep
inside Cargo or `rustc`.

Prints a summary to `io` (pass `devnull` to silence it) and returns
`(; ok, rustc, cargo, minimum_rustc, rustc_supported, compiler_identity,
extractor, problems)`:

* `rustc`, `cargo` — `(; command, version, release, error)`: the resolved
  command, its `--version` line, the parsed release (`nothing` when it cannot
  be read), and why it could not be run (`nothing` when it could);
* `minimum_rustc` — the floor, or `nothing` when no crate declares one;
* `rustc_supported` — `true` / `false` against the floor (a pre-release such as
  `1.85.0-nightly` counts as its release), `nothing` when either side is
  unknown;
* `compiler_identity` — `artifact_compiler_identity()`, the string every cache
  key folds in, or `nothing` when it cannot be computed;
* `extractor` — `(; path, schema, identity, error)`: the binary, the schema it
  reports (this release expects `MANIFEST_SCHEMA_VERSION`), its identity
  (`extractor_source_digest`), and what is wrong with it;
* `problems` — one line per problem; `ok` is `isempty(problems)`.

```julia
julia> RustCall.check_toolchain();
RustCall toolchain check: ok
  rustc: rustc 1.98.1 (48a229cea 2026-09-01) (minimum supported: 1.85.0)
  cargo: cargo 1.98.1 (797e8a9bc 2026-08-05)
  extractor: .../rustcall-extract (schema 0.6)
```
"""
check_toolchain(; io::IO = stdout) = _check_toolchain(io, rustc, cargo)

# `rustc_cmd` / `cargo_cmd` are the RustToolChain getters every build uses;
# the tests hand in stand-ins to reach the unsupported and unavailable paths.
function _check_toolchain(io::IO, rustc_cmd, cargo_cmd)
    problems = String[]
    rustc_info = _check_tool(rustc_cmd, "rustc")
    cargo_info = _check_tool(cargo_cmd, "cargo")
    rustc_info.error === nothing || push!(problems, "rustc: " * rustc_info.error)
    cargo_info.error === nothing || push!(problems, "cargo: " * cargo_info.error)

    minimum_rustc = minimum_supported_rustc()
    release = rustc_info.release
    rustc_supported = if release === nothing || minimum_rustc === nothing
        nothing
    else
        VersionNumber(release.major, release.minor, release.patch) >= minimum_rustc
    end
    if rustc_info.error === nothing && release === nothing
        push!(problems, "rustc: cannot read a release from `$(rustc_info.version)`")
    end
    rustc_supported === false && push!(problems,
        "rustc: $(release) is older than the minimum supported $(minimum_rustc); " *
        "update Rust (`rustup update`), or put a newer `rustc` on PATH")

    compiler_identity = try
        artifact_compiler_identity()
    catch
        # Already listed per tool above; the identity is only as good as they
        # are, and this function raises nothing.
        nothing
    end

    extractor = _check_extractor()
    extractor.error === nothing || push!(problems, "extractor: " * extractor.error)

    ok = isempty(problems)
    _print_toolchain_check(io, ok, rustc_info, cargo_info, minimum_rustc, extractor, problems)
    return (; ok, rustc = rustc_info, cargo = cargo_info, minimum_rustc, rustc_supported,
            compiler_identity, extractor, problems)
end

function _print_toolchain_check(io::IO, ok, rustc_info, cargo_info, minimum_rustc,
                                extractor, problems)
    println(io, "RustCall toolchain check: ", ok ? "ok" : "$(length(problems)) problem(s)")
    floor = minimum_rustc === nothing ? "none declared" : string(minimum_rustc)
    println(io, "  rustc: ", isempty(rustc_info.version) ? "unavailable" : rustc_info.version,
            " (minimum supported: ", floor, ")")
    println(io, "  cargo: ", isempty(cargo_info.version) ? "unavailable" : cargo_info.version)
    println(io, "  extractor: ", isempty(extractor.path) ? "not found" : extractor.path,
            isempty(extractor.schema) ? "" : " (schema $(extractor.schema))")
    for p in problems
        println(io, "  problem: ", p)
    end
    return nothing
end
