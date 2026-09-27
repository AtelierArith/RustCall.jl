# Component tests loaded by test_crate_bindings.jl.

# The `CrateBindings` proxy forwards property access to the wrapped object; it
# must not reserve a Rust type's own field names. `sample_crate`'s `Counter` has
# a field literally called `value`, which used to come back as the proxy's
# wrapped object instead of the field (#424).
@testset "CrateBindings proxy forwards a field named value (#424)" begin
    RustCall.check_rustc_available() || return
    B = @rust_crate SAMPLE_CRATE_PATH name="SampleCrateProxyFields"

    c = B.Counter(Int32(5))
    @test c.value == 5
    @test B.get(c) == Int32(5)

    c.value = Int32(100)
    @test c.value == 100

    B.increment(c)
    @test c.value == Int32(101)
    @test B.get(c) == Int32(101)
end

@testset "the documented bindings format is the current one (#460 review)" begin
    # The user guide names the marker a freshly written file carries; a
    # MAJOR.MINOR release bump moves the constant and must update it (#489).
    guide = read(joinpath(@__DIR__, "..", "docs", "src", "crate_bindings.md"), String)
    v = RustCall.BINDINGS_FORMAT_VERSION
    @test occursin("(`# Bindings format: $(v)`)", guide)
    @test occursin("RustCall.check_bindings_format(\"$(v)\")", guide)
    @test length(collect(eachmatch(r"`# Bindings format: [\d.]+`", guide))) == 1
    # ...and explains the policy, including that integer files are refused.
    @test occursin("MAJOR.MINOR", guide)
    @test occursin("no longer readable", guide)
end

@testset "the bindings format is the release's MAJOR.MINOR (#489)" begin
    project = RustCall.TOML.parsefile(joinpath(@__DIR__, "..", "Project.toml"))
    release = VersionNumber(project["version"])
    fmt = RustCall.BINDINGS_FORMAT_VERSION
    @test fmt isa String
    @test fmt == "$(release.major).$(release.minor)"
    # One identifier, shared with the manifest schema — not a second copy.
    @test fmt === RustCall.RELEASE_FORMAT_IDENTIFIER === RustCall.MANIFEST_SCHEMA_VERSION
    current = VersionNumber(fmt)
    compatible = RustCall.bindings_format_compatible
    # Same MAJOR.MINOR: accepted, whatever the patch.
    @test compatible(fmt)
    @test compatible("$(current.major).$(current.minor).0")
    @test compatible("$(current.major).$(current.minor).$(release.patch + 3)")
    @test RustCall.check_bindings_format(fmt) == fmt
    # Another minor or major: refused, in both directions.
    for other in ("$(current.major).$(current.minor + 1)",
                  "$(current.major).$(current.minor + 1).0",
                  "$(current.major + 1).$(current.minor)",
                  "$(current.major + 1).0.0")
        @test !compatible(other)
        err = try RustCall.check_bindings_format(other); nothing catch e; e end
        @test err isa RustCall.RustError
        msg = sprint(showerror, err)
        @test occursin(repr(other), msg)
        @test occursin("write_bindings_to_file", msg)
        @test occursin(fmt, msg)
    end
    if current.minor > 0
        @test !compatible("$(current.major).$(current.minor - 1)")
    end
    # The retired integer scheme, as a string or a number, and no marker at all.
    for old in ("13", "12", "1", 13, 7)
        @test !compatible(old)
        err = try RustCall.check_bindings_format(old); nothing catch e; e end
        @test err isa RustCall.RustError
        msg = sprint(showerror, err)
        @test occursin("integer scheme", msg)
        @test occursin("no longer readable", msg)
        @test occursin("write_bindings_to_file", msg)
    end
    err = try RustCall.check_bindings_format(nothing); nothing catch e; e end
    @test err isa RustCall.RustError
    @test occursin("no bindings-format marker", sprint(showerror, err))
    @test occursin("write_bindings_to_file", sprint(showerror, err))
    # Not a version at all.
    for junk in ("", "0.6.x", "v0.6", "0.6.0-DEV", "zero")
        @test !compatible(junk)
    end
    # A module without the declaration — what every integer-format file is —
    # is refused where its `__init__` registers the generation mirror.
    m = Module(:BindingsFormatLegacy489)
    Core.eval(m, :(import RustCall))
    Core.eval(m, :(const _LIB_GEN = RustCall.StateView(:crate_generation, @__MODULE__)))
    err = try
        Core.eval(m, :(RustCall.register_handle_mirror!("bindings_format_legacy_489", _LIB_GEN)))
        nothing
    catch e
        e
    end
    @test err isa RustCall.RustError
    @test occursin("write_bindings_to_file", sprint(showerror, err))
    # With a current declaration the same registration is accepted.
    ok = Module(:BindingsFormatCurrent489)
    Core.eval(ok, :(import RustCall))
    Core.eval(ok, :(const _BINDINGS_FORMAT = RustCall.check_bindings_format($(fmt))))
    Core.eval(ok, :(const _LIB_GEN = RustCall.StateView(:crate_generation, @__MODULE__)))
    @test Core.eval(ok, :(RustCall.register_handle_mirror!("bindings_format_current_489", _LIB_GEN))) === nothing
    # A file older than the `StateView` mirror (format 7 and the like) keeps its
    # generation in a `Ref{CrateGeneration}` and registers that from `__init__`:
    # it gets the same regeneration refusal, not only the #402 diagnostic
    # (#489 review).
    pre = Module(:BindingsFormatPreStateView489)
    Core.eval(pre, :(import RustCall))
    Core.eval(pre, :(const _LIB_NAME = "bindings_format_pre_stateview_489"))
    Core.eval(pre, :(const _LIB_GEN = Ref(RustCall.CrateGeneration())))
    err = try
        Core.eval(pre, :(RustCall.register_handle_mirror!(_LIB_NAME, _LIB_GEN)))
        nothing
    catch e
        e
    end
    @test err isa RustCall.RustError
    msg = sprint(showerror, err)
    @test occursin("write_bindings_to_file", msg)
    @test occursin("no longer readable", msg)
    @test occursin("regenerate it", msg)
end
