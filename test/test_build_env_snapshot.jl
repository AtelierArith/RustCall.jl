# #481: one immutable environment snapshot per crate build.
#
# Every entry point — `@rust_crate` (the direct crate, the generated wrapper
# crate, the PyO3 wrapper crate), `write_bindings_to_file`, the PyO3 host path
# and a hot reload — takes ONE `BuildEnvSnapshot` at its start, and derives the
# build record, the checks against a record and every subprocess environment
# from it. The acceptance criteria, one testset each:
#
#   1. no function on a build path reads `ENV` after the snapshot (source level:
#      the functions are found from their signatures, not listed by hand);
#   2. per entry point, an environment changed right after the snapshot — the
#      test seam runs the change at exactly that point, deterministically —
#      reaches neither the library, nor the record, nor the checks;
#   3. an unchanged environment keys exactly as before (the snapshot pieces are
#      the pieces `ENV` gave, and a name recomputed later is the same name);
#   4. an interpreter replaced in place between the check and the build is
#      refused (`_verify_build_interpreter`, and every build path calls it).

using Test
using RustCall
using RustToolChain: cargo

include("source_helpers.jl")

const _BESN_ROOT = dirname(dirname(pathof(RustCall)))
const _BESN_SAMPLE = joinpath(@__DIR__, "fixtures", "sample_crate")
const _BESN_PYO3_ONLY = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3_only")
const _BESN_PYO3_HOST = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3_host")

include(joinpath(@__DIR__, "pyo3_wrapper_helpers.jl"))

_besn_cargo_available() = try
    run(pipeline(`$(cargo()) --version`, devnull))
    true
catch
    false
end

# ---------------------------------------------------------------------------
# Source level
# ---------------------------------------------------------------------------

# Every function definition in `file`: (name, signature, body).
function _besn_definitions(file)
    ast = Meta.parseall(read_source_tree(joinpath(_BESN_ROOT, "src", file)); filename = file)
    out = Tuple{Symbol, Any, Any}[]
    fname(sig) = sig isa Symbol ? sig :
                 sig isa Expr && sig.head === :call ? fname(sig.args[1]) :
                 sig isa Expr && sig.head in (:where, :(::)) ? fname(sig.args[1]) :
                 sig isa Expr && sig.head === :(.) ? sig.args[end].value : nothing
    callsig(sig) = sig isa Expr && sig.head in (:where, :(::)) ? callsig(sig.args[1]) : sig
    function walk(x)
        x isa Expr || return
        # `function f end` declares a function and has no body.
        x.head === :function && length(x.args) < 2 && return
        if x.head === :function || (x.head === :(=) && x.args[1] isa Expr &&
                                    callsig(x.args[1]) isa Expr && callsig(x.args[1]).head === :call)
            sig = callsig(x.args[1])
            name = fname(sig)
            name isa Symbol && push!(out, (name, sig, x.args[2]))
            return
        end
        x.head === :macrocall && return foreach(walk, x.args)
        foreach(walk, x.args)
    end
    walk(ast)
    return out
end

# The values bound to `const _BUILD_RECORD = ...` in a module expression.
function _besn_records_in(ex)
    found = Any[]
    walk(x) = nothing
    function walk(x::Expr)
        if x.head === :const && x.args[1] isa Expr && x.args[1].head === :(=) &&
           x.args[1].args[1] === :_BUILD_RECORD
            push!(found, x.args[1].args[2])
        end
        foreach(walk, x.args)
    end
    walk(ex)
    return found
end

# Build-path pieces handed the build's environment as a table rather than as
# the snapshot (a record's subprocess environment is one): checked in their
# forms that take it.
const _BESN_ENV_TAKING = (:_wrapper_probe_context, :_wrapper_probe_env,
                          :_wrapper_probe_cfg_text, :_cargo_package_metadata)

function _besn_takes_env(sig)
    found = false
    walk(x) = x isa Expr && (x.head === :(::) && length(x.args) == 2 &&
                             x.args[2] === :AbstractDict ? (found = true) : foreach(walk, x.args))
    walk(sig)
    return found
end

# Does a signature take a `BuildEnvSnapshot` — positionally or as a keyword?
function _besn_takes_snapshot(sig)
    found = false
    function walk(x)
        x isa Expr || return
        if x.head === :(::) && length(x.args) == 2
            t = x.args[2]
            (t === :BuildEnvSnapshot ||
             (t isa Expr && t.head === :curly && :BuildEnvSnapshot in t.args)) && (found = true)
        end
        foreach(walk, x.args)
    end
    walk(sig)
    return found
end

# The entry points: each may take a snapshot of its own, once, and nothing it
# calls may take another.
const _BESN_ENTRIES = Dict(
    "crate_bindings.jl" => (:generate_bindings, :write_bindings_to_file, :emit_crate_module,
                            :emit_crate_module_code, :_warn_if_build_env_changed),
    "hot_reload.jl" => (:_reload_library_once, :HotReloadState, :enable_hot_reload,
                        :enable_hot_reload_for_crate, :_enable_crate_hot_reload),
    "pyo3_host.jl" => (:build_pyo3_extension,),
    "pyo3.jl" => (:scan_report,),
)
# The four builds that must take exactly one.
const _BESN_BUILDS = (:generate_bindings, :write_bindings_to_file, :_reload_library_once,
                      :build_pyo3_extension)

# Helpers that fall back to the live environment when not handed one: a build
# path must hand them its own. `(:kw, name)` a keyword, `(:pos, n)` at least
# `n` positional arguments.
const _BESN_MUST_PASS = Dict{Symbol, Tuple{Symbol, Any}}(
    :artifact_build_env => (:kw, :env),
    :_cargo_config_digest => (:pos, 1),
    :_cargo_config_files => (:pos, 1),
    :_cargo_network_args => (:pos, 1),
    :cargo_offline => (:pos, 1),
    :compute_crate_hash => (:kw, :snapshot),
    :crate_library_name => (:kw, :snapshot),
    :pyo3_link_plan => (:kw, :snapshot),
    :pyo3_feature_candidates => (:kw, :snapshot),
    :build_pyo3_wrapper => (:kw, :snapshot),
    :_pyo3_conservative_plan => (:kw, :snapshot),
    :_pyo3_extension_artifact => (:kw, :snapshot),
    :emit_crate_module => (:kw, (:snapshot, :build_record)),
    :emit_crate_module_code => (:kw, (:snapshot, :build_record)),
    :build_cargo_project => (:kw, :env),
    :build_crate_directly => (:kw, :env),
    :_crate_build_cfg_text => (:kw, :env),
    :_plain_scan_info => (:kw, :env),
    :_wrapper_probe_context => (:pos, 2),
    :_wrapper_probe_cfg_text => (:pos, 2),
    :_wrapper_probe_env => (:pos, 4),
    :_crate_hot_reload_name => (:pos, 3),
    :scan_crate => (:kw, :cargo_env),
    :_crate_rust_edition => (:kw, :env),
    :_package_field => (:kw, :env),
    :_cargo_package_metadata => (:kw, :env),
    :artifact_path_dependency_digest => (:kw, :env),
    :local_path_dependency_dirs => (:kw, :env),
    :_cargo_cfg_text => (:pos, 1),
)

# Positional arities of the snapshot-first methods of `f` — a call on a build
# path must reach one of them, never the convenience form that snapshots `ENV`.
function _besn_snapshot_arities(f)
    arities = Int[]
    for m in methods(f)
        params = Base.unwrap_unionall(m.sig).parameters
        any(p -> p === RustCall.BuildEnvSnapshot, params[2:end]) &&
            push!(arities, length(params) - 1)
    end
    return arities
end

function _besn_call_shape(call::Expr)
    positional = 0
    keywords = Symbol[]
    for a in call.args[2:end]
        if a isa Expr && a.head === :parameters
            for p in a.args
                p isa Symbol && push!(keywords, p)
                p isa Expr && p.head === :kw && push!(keywords, p.args[1])
                p isa Expr && p.head === :... && push!(keywords, :...)
            end
        elseif a isa Expr && a.head === :kw
            push!(keywords, a.args[1])
        else
            positional += 1
        end
    end
    return positional, keywords
end

# Every violation in one body.
function _besn_violations(name::Symbol, body; entry::Bool)
    problems = String[]
    snapshots = Ref(0)
    function walk(x, in_setenv::Bool)
        if x === :ENV
            push!(problems, "$(name) reads `ENV`")
            return
        end
        x isa Expr || return
        if x.head === :macrocall && x.args[1] === Symbol("@cmd")
            in_setenv || push!(problems, "$(name) builds a command outside `setenv` / `snapshot_cmd`")
            return
        end
        if x.head === :call
            f = x.args[1]
            if f isa Expr && f.head === :(.) && f.args[1] === :Sys && f.args[2] == QuoteNode(:which)
                push!(problems, "$(name) calls `Sys.which` (use `snapshot_which`)")
            elseif f === :withenv
                push!(problems, "$(name) calls `withenv`")
            elseif f === :BuildEnvSnapshot && length(x.args) == 1
                snapshots[] += 1
                entry || push!(problems, "$(name) takes a snapshot of its own")
            elseif f isa Symbol
                positional, keywords = _besn_call_shape(x)
                rule = get(_BESN_MUST_PASS, f, nothing)
                if rule !== nothing
                    kind, what = rule
                    ok = kind === :kw ? all(w -> w in keywords, what isa Tuple ? what : (what,)) :
                         positional >= what
                    ok || push!(problems, "$(name) calls `$(f)` without its environment")
                end
                if isdefined(RustCall, f) && getfield(RustCall, f) isa Function &&
                   parentmodule(getfield(RustCall, f)) === RustCall
                    arities = _besn_snapshot_arities(getfield(RustCall, f))
                    if !isempty(arities) && !(positional in arities)
                        push!(problems, "$(name) calls `$(f)` without the snapshot")
                    end
                end
            end
            inner = in_setenv || f === :setenv || f === :snapshot_cmd
            foreach(a -> walk(a, inner), x.args)
            return
        end
        foreach(a -> walk(a, in_setenv), x.args)
    end
    walk(body, false)
    return problems, snapshots[]
end

@testset "One environment snapshot per build (#481)" begin

    @testset "no function on a build path reads ENV after the snapshot (source level)" begin
        files = ("crate_bindings.jl", "pyo3.jl", "pyo3_host.jl", "hot_reload.jl")
        checked = Symbol[]
        problems = String[]
        seen_entries = Dict{Symbol, Int}()
        for file in files
            entries = get(_BESN_ENTRIES, file, ())
            for (name, sig, body) in _besn_definitions(file)
                is_entry = name in entries
                (is_entry || _besn_takes_snapshot(sig) ||
                 (name in _BESN_ENV_TAKING && _besn_takes_env(sig))) || continue
                push!(checked, name)
                found, snapshots = _besn_violations(name, body; entry = is_entry)
                append!(problems, found)
                is_entry && (seen_entries[name] = get(seen_entries, name, 0) + snapshots)
            end
        end
        foreach(println, problems)
        @test isempty(problems)
        # The scan found the build path, not an empty set: the pieces the issue
        # names are all among the checked functions.
        for piece in (:generate_bindings, :write_bindings_to_file, :_reload_library_once,
                      :build_pyo3_extension, :build_pyo3_wrapper, :_pyo3_wrapper_build_env,
                      :_build_pyo3_wrapper_project, :_wrapper_probe_context,
                      :_record_build_subprocess_env, :_build_record_mismatch,
                      :_build_env_changes, :crate_build_record, :_recorded_build_env,
                      :_pyo3_build_interpreter, :python_link_source, :compute_crate_hash,
                      :_pyo3_host_build_env, :_build_pyo3_extension_library,
                      :_resolved_pyo3_dependency, :_cargo_resolved_features)
            @test (piece, piece in checked) == (piece, true)
        end
        # Each build takes exactly one snapshot.
        for build in _BESN_BUILDS
            @test get(seen_entries, build, 0) == 1
        end
    end

    @testset "every build path re-asks its interpreter before publishing (source level)" begin
        calls(file, name) = begin
            n = 0
            for (fn, _, body) in _besn_definitions(file)
                fn === name || continue
                walk(x) = x isa Expr && (x.head === :call && x.args[1] === :_verify_build_interpreter ?
                                         (n += 1) : foreach(walk, x.args))
                walk(body)
            end
            n
        end
        @test calls("crate_bindings.jl", :generate_bindings) == 2        # direct, wrapper crate
        @test calls("crate_bindings.jl", :write_bindings_to_file) == 2   # direct, wrapper crate
        @test calls("hot_reload.jl", :_reload_library_once) == 1
        @test calls("pyo3.jl", :_build_pyo3_wrapper_project) == 1
        @test calls("pyo3_host.jl", :build_pyo3_extension) == 1
    end

    @testset "the snapshot is a copy, and hands out copies" begin
        withenv("RUSTCALL_BESN_481" => "before") do
            s = RustCall.BuildEnvSnapshot()
            ENV["RUSTCALL_BESN_481"] = "after"
            @test get(s, "RUSTCALL_BESN_481", nothing) == "before"
            env = RustCall.snapshot_env(s)
            env["RUSTCALL_BESN_481"] = "edited"
            @test get(s, "RUSTCALL_BESN_481", nothing) == "before"
            @test RustCall.snapshot_env(s)["RUSTCALL_BESN_481"] == "before"
            source = Dict("A" => "1")
            t = RustCall.BuildEnvSnapshot(source)
            source["A"] = "2"
            @test get(t, "A", nothing) == "1"
            @test RustCall.snapshot_env(t) == Dict("A" => "1")
        end
    end

    @testset "PATH lookups and interpreters use the snapshot's PATH" begin
        if Sys.iswindows()
            @test_skip "shell-script interpreters are a Unix fixture"
        else
            mktempdir() do dir
                fake = joinpath(dir, "python3-config")
                write(fake, "#!/bin/sh\necho -L$(dir)\n")
                chmod(fake, 0o755)
                python = joinpath(dir, "python3")
                write(python, "#!/bin/sh\necho /besn/fake/python3\n")
                chmod(python, 0o755)
                s = withenv("PATH" => dir * ":" * get(ENV, "PATH", "")) do
                    RustCall.BuildEnvSnapshot()
                end
                # The process PATH does not have `dir`; the snapshot's does.
                @test RustCall.snapshot_which(s, "python3-config") == fake
                @test RustCall.snapshot_which(RustCall.BuildEnvSnapshot(), "python3-config") !=
                      fake
                @test RustCall._python_executable(s, "python3") == "/besn/fake/python3"
                @test last(RustCall._python_config_selections(s)[1]) == fake
                @test RustCall.snapshot_which(s, "rustcall-besn-no-such-tool") == ""
            end
        end
    end

    @testset "an unchanged environment keys as before" begin
        s = RustCall.BuildEnvSnapshot()
        # The pieces the key is made of, read from the snapshot, are the pieces
        # `ENV` gives — so the key an unchanged environment produces is the key
        # it produced before #481.
        @test RustCall.artifact_build_env(; env = RustCall.snapshot_env(s)) ==
              RustCall.artifact_build_env()
        @test RustCall._cargo_config_digest(RustCall.snapshot_env(s); dir = _BESN_SAMPLE) ==
              RustCall._cargo_config_digest(ENV; dir = _BESN_SAMPLE)
        @test RustCall._plain_crate_build_env(s) == RustCall._plain_crate_build_env()
        @test RustCall._recorded_build_env(s) == RustCall._recorded_build_env()
        info = RustCall.scan_crate(_BESN_SAMPLE)
        build_env = RustCall._plain_crate_build_env(s)
        @test RustCall.compute_crate_hash(info; build_env = build_env, snapshot = s) ==
              RustCall.compute_crate_hash(info; build_env = RustCall._plain_crate_build_env())
        record = RustCall.crate_build_record(_BESN_SAMPLE, ""; snapshot = s)
        @test RustCall._plain_crate_build_env(record) == build_env
        @test isempty(RustCall._build_record_mismatch(record, RustCall.BuildEnvSnapshot()))
        # And a name computed twice is one name.
        @test RustCall.crate_library_name(info; build_env = build_env, snapshot = s) ==
              RustCall.crate_library_name(info; build_env = RustCall._plain_crate_build_env(),
                                          snapshot = RustCall.BuildEnvSnapshot())
    end

    @testset "an interpreter replaced in place is refused" begin
        if Sys.iswindows()
            @test_skip "shell-script interpreters are a Unix fixture"
        else
            mktempdir() do dir
                python = joinpath(dir, "python3")
                write(python, "#!/bin/sh\necho CPython-one\n")
                chmod(python, 0o755)
                s = RustCall.BuildEnvSnapshot()
                fingerprint = RustCall._python_interpreter_fingerprint(s, python)
                @test fingerprint == "CPython-one"
                @test RustCall._verify_build_interpreter(s, python, fingerprint, "besn") === nothing
                # Replaced in place: same path, another Python.
                write(python, "#!/bin/sh\necho CPython-two\n")
                err = try
                    RustCall._verify_build_interpreter(s, python, fingerprint, "besn")
                    nothing
                catch e
                    e
                end
                @test err isa RustCall.RustError
                @test err !== nothing && occursin("changed while", sprint(showerror, err))
                # Through a record, as a plain build and a hot reload check it.
                record = RustCall.CrateBuildRecord(dir, "besn_lib", true, (), true, :direct,
                    ("<pyo3 build interpreter>" => python,
                     "<pyo3 build fingerprint>" => fingerprint), "", "", false)
                @test_throws RustCall.RustError RustCall._verify_build_interpreter(record, s)
                # Nothing consulted, nothing checked.
                @test RustCall._verify_build_interpreter(s, "", "", "besn") === nothing
                @test RustCall._verify_build_interpreter(s, python, "", "besn") === nothing
            end
        end
    end

    # -----------------------------------------------------------------------
    # Behaviour, per entry point
    # -----------------------------------------------------------------------

    if !_besn_cargo_available() || !RustCall.check_rustc_available()
        @test_skip "Cargo/rustc not available, skipping the per-entry-point builds of #481"
        return
    end

    # A `PATH` entry whose `python3` / `python` answer as another interpreter,
    # so a build that consulted the live `PATH` after the snapshot records it.
    fake_bin = mktempdir()
    if !Sys.iswindows()
        for exe in ("python3", "python")
            write(joinpath(fake_bin, exe), "#!/bin/sh\necho /besn/fake/python3\n")
            chmod(joinpath(fake_bin, exe), 0o755)
        end
    end
    sep = Sys.iswindows() ? ";" : ":"
    # What another task does to `ENV` right after the snapshot: a `RUSTFLAGS`
    # no compiler accepts — any Cargo or rustc run that saw it fails — and a
    # `PATH` that finds another Python first.
    mutation() = ("RUSTFLAGS" => "--rustcall-481-not-a-flag",
                  "PATH" => fake_bin * sep * get(ENV, "PATH", ""))

    # Run `f` with `changes` applied to `ENV` at the first snapshot it takes —
    # through the task-local seam, so exactly there — and `ENV` restored after.
    function with_mutation_after_snapshot(f, changes)
        saved = Dict(k => get(ENV, k, nothing) for (k, _) in changes)
        fired = Ref(false)
        hook = stage -> begin
            (fired[] || stage !== :snapshot) && return
            fired[] = true
            for (k, v) in changes
                v === nothing ? delete!(ENV, k) : (ENV[k] = v)
            end
        end
        # Every subprocess writes its stderr here, including the probes that
        # swallow a failure by design: a Cargo or rustc run that saw the
        # changed `RUSTFLAGS` names the flag in its error, even when the build
        # goes on without its answer.
        log = tempname()
        try
            result = open(log, "w") do io
                redirect_stderr(io) do
                    task_local_storage(f, RustCall._AFTER_BUILD_ENV_SNAPSHOT, hook)
                end
            end
            @test fired[]
            leaked = read(log, String)
            @test !occursin("rustcall-481-not-a-flag", leaked)
            occursin("rustcall-481-not-a-flag", leaked) && print(leaked)
            return result
        finally
            for (k, v) in saved
                v === nothing ? delete!(ENV, k) : (ENV[k] = v)
            end
            rm(log; force = true)
        end
    end

    record_env(record) = Dict{String, String}(record.build_env)
    not_fake(record) = get(record_env(record), "<pyo3 build interpreter>", "") != "/besn/fake/python3"

    function besn_crate(dir; package, cdylib = true, value = 481)
        mkpath(joinpath(dir, "src"))
        runtime = RustCall.rustcall_runtime_crate_path()
        write(joinpath(dir, "Cargo.toml"), """
            [package]
            name = "$(package)"
            version = "0.1.0"
            edition = "2021"

            [lib]
            crate-type = ["$(cdylib ? "cdylib" : "rlib")"]

            [dependencies]
            rustcall_julia_macros = { path = "$(RustCall.escape_toml_string(runtime))" }
            """)
        write(joinpath(dir, "src", "lib.rs"), """
            use rustcall_julia_macros::julia;

            #[julia]
            pub fn besn_value() -> i32 { $(value) }
            """)
        return String(dir)
    end

    function load_module(ex, name)
        host = Module(name)
        Core.eval(host, :(import RustCall))
        return Core.eval(host, ex)
    end

    @testset "@rust_crate: the direct crate and the generated wrapper crate" begin
        mktempdir() do dir
            for (cdylib, package) in ((true, "besn_direct_481"), (false, "besn_wrapper_481"))
                crate = besn_crate(joinpath(dir, package); package, cdylib)
                ex = with_mutation_after_snapshot(mutation()) do
                    RustCall.generate_bindings(crate; cache_enabled = false)
                end
                # Loads under the restored environment: its `__init__` compares
                # the record with it, strictly.
                m = load_module(ex, Symbol(package, "_host"))
                record = Base.invokelatest(getglobal, m, :_BUILD_RECORD)
                try
                    # The library: built at all (the flag would have failed any
                    # Cargo run that saw it), and the build it describes.
                    @test Base.invokelatest(Base.invokelatest(getglobal, m, :besn_value)) == 481
                    # The record and the check agree with the environment the
                    # build started under.
                    @test isempty(RustCall._build_record_mismatch(record, RustCall.BuildEnvSnapshot()))
                    @test !haskey(record_env(record), "RUSTFLAGS") ||
                          record_env(record)["RUSTFLAGS"] != "present:--rustcall-481-not-a-flag"
                    Sys.iswindows() || @test not_fake(record)
                    # The key: the name recomputed now is the module's name.
                    @test RustCall._crate_hot_reload_name(crate) == record.lib_name
                    @test record.kind === (cdylib ? :direct : :wrapper)
                finally
                    RustCall.unload_library(record.lib_name; close = true)
                end
            end
        end
    end

    @testset "write_bindings_to_file" begin
        mktempdir() do dir
            crate = besn_crate(joinpath(dir, "crate"); package = "besn_written_481")
            out = joinpath(dir, "bindings.jl")
            with_mutation_after_snapshot(mutation()) do
                RustCall.write_bindings_to_file(crate, out; output_module_name = "BesnWritten481")
            end
            host = Module(:BesnWrittenHost481)
            Core.eval(host, :(using RustCall))
            Base.include(host, out)   # the strict `__init__` check passes
            m = Base.invokelatest(getglobal, host, :BesnWritten481)
            record = Base.invokelatest(getglobal, m, :_BUILD_RECORD)
            try
                @test Base.invokelatest(Base.invokelatest(getglobal, m, :besn_value)) == 481
                @test isempty(RustCall._build_record_mismatch(record, RustCall.BuildEnvSnapshot()))
                Sys.iswindows() || @test not_fake(record)
            finally
                RustCall.unload_library(record.lib_name; close = true)
            end
        end
    end

    @testset "hot reload" begin
        mktempdir() do dir
            crate = besn_crate(joinpath(dir, "crate"); package = "besn_reload_481")
            m = load_module(RustCall.generate_bindings(crate; cache_enabled = false),
                            :BesnReloadHost481)
            name = Base.invokelatest(getglobal, m, :_LIB_NAME)
            try
                state = RustCall.enable_hot_reload_for_crate(m; poll = true, interval = 60.0)
                write(joinpath(crate, "src", "lib.rs"), """
                    use rustcall_julia_macros::julia;

                    #[julia]
                    pub fn besn_value() -> i32 { 482 }
                    """)
                # The reload's snapshot is taken, then `ENV` moves: its check,
                # its probe and its build all still see the snapshot.
                ok = with_mutation_after_snapshot(mutation()) do
                    RustCall.trigger_reload(name)
                end
                @test ok == true
                @test isempty(state.last_failure)
                @test Base.invokelatest(Base.invokelatest(getglobal, m, :besn_value)) == 482
            finally
                RustCall.is_hot_reload_enabled(name) && RustCall.disable_hot_reload(name)
                delete!(RustCall.HOT_RELOAD_REGISTRY, name)
                RustCall.unload_library(name; close = true)
            end
        end
    end

    @testset "@rust_crate: the PyO3 wrapper crate" begin
        plan = RustCall.pyo3_link_plan(_BESN_PYO3_ONLY)
        if plan.mode !== :link_libpython || !_linkable_python_library(plan.rpath)
            @test_skip "no linkable Python here: the PyO3 wrapper crate cannot be built"
        else
            ex = with_mutation_after_snapshot(mutation()) do
                RustCall.generate_bindings(_BESN_PYO3_ONLY; cache_enabled = false)
            end
            m = load_module(ex, :BesnPyO3Host481)
            record = Base.invokelatest(getglobal, m, :_BUILD_RECORD)
            try
                @test record.kind === :pyo3_wrapper
                @test record.python
                @test isempty(RustCall._build_record_mismatch(record, RustCall.BuildEnvSnapshot()))
                recorded = record_env(record)
                @test get(recorded, "<python selection>", "") != "/besn/fake/python3"
                @test get(recorded, "<python resolved>", "") != "/besn/fake/python3"
                # The name is the key of the plan the snapshot decided: the
                # same wrapper, planned again now, has the same name.
                info = RustCall.scan_crate(_BESN_PYO3_ONLY)
                again = RustCall.build_pyo3_wrapper(info; cache_enabled = true)
                @test again.lib_name == record.lib_name
            finally
                RustCall.unload_library(record.lib_name; close = true)
            end
        end
    end

    # #485 review: an interpreter replaced in place after the build verified
    # it, but before the module is emitted, must not reach the record — the
    # record describes the plan the key and the library came from, so the
    # load-time check then *refuses* the wrapper under the new interpreter.
    @testset "the PyO3 wrapper's record is the verified plan's, not a later probe" begin
        plan = RustCall.pyo3_link_plan(_BESN_PYO3_ONLY)
        if Sys.iswindows()
            @test_skip "shell-script interpreters are a Unix fixture"
        elseif plan.mode !== :link_libpython || !_linkable_python_library(plan.rpath) ||
               isempty(plan.interpreter)
            @test_skip "no linkable Python here: the PyO3 wrapper crate cannot be built"
        else
            fingerprint(record) = Dict{String, String}(record.build_env)["<python fingerprint>"]
            for (label, build) in (
                    ("generate_bindings", () -> begin
                        ex = RustCall.generate_bindings(_BESN_PYO3_ONLY; cache_enabled = false)
                        only(filter(!isnothing, _besn_records_in(ex)))
                    end),
                    ("write_bindings_to_file", () -> begin
                        out = joinpath(mktempdir(), "bindings.jl")
                        RustCall.write_bindings_to_file(_BESN_PYO3_ONLY, out;
                                                        output_module_name = "BesnSwap485")
                        line = only(filter(l -> startswith(l, "const _BUILD_RECORD = "),
                                           split(read(out, String), '\n')))
                        m = Module(:BesnSwapRecord485)
                        # The file names RustCall through its alias (#528).
                        Core.eval(m, Meta.parse("import RustCall as rustcall′RustCall"))
                        Core.eval(m, Meta.parse(chopprefix(line, "const _BUILD_RECORD = ")))
                    end))
                mktempdir() do dir
                    # An interpreter the build pins by path, which the test can
                    # replace in place: first the real one, then another Python.
                    python = joinpath(dir, "python3")
                    write(python, "#!/bin/sh\nexec $(repr(plan.interpreter)) \"\$@\"\n")
                    chmod(python, 0o755)
                    before = RustCall._python_interpreter_fingerprint(python)
                    @test !isempty(before)
                    swapped = Ref(false)
                    hook = stage -> begin
                        (stage === :verified && !swapped[]) || return
                        swapped[] = true
                        write(python, "#!/bin/sh\necho CPython-replaced-485\n")
                    end
                    record = withenv("PYO3_PYTHON" => python) do
                        task_local_storage(build, RustCall._AFTER_BUILD_ENV_SNAPSHOT, hook)
                    end
                    @test (label, swapped[]) == (label, true)
                    @test record.kind === :pyo3_wrapper && record.python
                    # The record names the interpreter the library was built
                    # for ...
                    @test (label, fingerprint(record)) == (label, before)
                    # ... so under the replaced one the check refuses it.
                    changed = withenv("PYO3_PYTHON" => python) do
                        RustCall._build_record_mismatch(record, RustCall.BuildEnvSnapshot())
                    end
                    @test (label, "<python fingerprint>" in changed) == (label, true)
                end
            end
        end
    end

    @testset "the PyO3 host path" begin
        python = something(Sys.which("python3"), Sys.which("python"), "")
        if isempty(python) || isempty(RustCall._pyo3_extension_interpreter_probe(python)[1])
            @test_skip "no Python interpreter to build the host extension for"
        else
            artifact = with_mutation_after_snapshot(mutation()) do
                RustCall.build_pyo3_extension(_BESN_PYO3_HOST; python = python,
                                              cache_enabled = false)
            end
            @test isfile(artifact.lib_path)
            @test artifact.fingerprint == RustCall._python_interpreter_fingerprint(python)
            info = RustCall.scan_crate(_BESN_PYO3_HOST)
            again = RustCall._pyo3_extension_artifact(RustCall.get_cache_dir(), info,
                artifact.module_name, python, artifact.ext_suffix, artifact.fingerprint)
            @test again.key == artifact.key
        end
    end
end
