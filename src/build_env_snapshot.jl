# One environment per build (#481).

"""
    BuildEnvSnapshot

One copy of the process environment, taken **once** at the start of a crate
build: `@rust_crate` (the direct crate, the generated wrapper crate, the PyO3
wrapper crate), `write_bindings_to_file`, the PyO3 host path
(`build_pyo3_extension`) and a hot reload. Everything the build derives from the
environment is read from it after that, and nothing on the path reads `ENV`
again:

- the artifact key (`compute_crate_hash`, `_pyo3_wrapper_build_env`,
  `_pyo3_host_build_env`) and the registry name;
- the module's `CrateBuildRecord` (`crate_build_record`) and the checks against
  a record (`_build_record_mismatch`, `_build_env_changes`);
- every subprocess: the Cargo probes and builds run under
  `snapshot_env(snapshot)` (or the record's environment derived from it), and
  every Python interpreter the build asks about is started under it too
  (`snapshot_cmd`), so a `PATH` changed by another task selects no other
  `python3`. A program looked up on `PATH` is looked up on the snapshot's
  (`snapshot_which`).

Before #481 each of those read `ENV` at its own moment, so a task changing
`RUSTFLAGS`, `PYO3_PYTHON` or `PATH` in between could produce a library built
under one environment, keyed and recorded under another, and checked against a
third.

Immutable in effect: the table is copied in at construction, never mutated, and
handed out only as a fresh copy (`snapshot_env`), so a callee that edits the
environment it was given cannot change what the next reader sees.
`test/test_build_env_snapshot.jl` asserts at the source level that no function
on a build path reads `ENV` directly, and per entry point that an environment
changed right after the snapshot reaches neither the library, nor the record,
nor the checks.
"""
struct BuildEnvSnapshot
    vars::Dict{String, String}
    BuildEnvSnapshot(env::AbstractDict) =
        new(Dict{String, String}(String(k) => String(v) for (k, v) in env))
end

"""
    BuildEnvSnapshot() -> BuildEnvSnapshot

The snapshot of `ENV` now. Called once, at the start of a build entry point;
`_after_build_env_snapshot` runs right after it.
"""
function BuildEnvSnapshot()
    snapshot = BuildEnvSnapshot(ENV)
    _after_build_env_snapshot()
    return snapshot
end

Base.get(s::BuildEnvSnapshot, key::AbstractString, default) = get(s.vars, String(key), default)
Base.haskey(s::BuildEnvSnapshot, key::AbstractString) = haskey(s.vars, String(key))

"""
    snapshot_env(s::BuildEnvSnapshot) -> Dict{String, String}

A fresh copy of the snapshot's variables, for a subprocess environment
(`setenv`) or a helper that takes an environment table. Each call returns a new
`Dict`, so editing it (pinning `PYO3_PYTHON`, `CARGO_TARGET_DIR`) is local to
that caller.
"""
snapshot_env(s::BuildEnvSnapshot) = copy(s.vars)

"""
    snapshot_cmd(s::BuildEnvSnapshot, cmd::Cmd) -> Cmd

`cmd` run under the snapshot's environment rather than the process's. A bare
program name is looked up on the snapshot's `PATH` — libuv resolves it from the
child's environment — so the interpreter or tool that runs is the one the
snapshot selects.
"""
snapshot_cmd(s::BuildEnvSnapshot, cmd::Cmd) = setenv(cmd, snapshot_env(s))

"""
    snapshot_which(s::BuildEnvSnapshot, name) -> String

`Sys.which(name)` on the snapshot's `PATH` rather than the process's, spelled
the same way (`Sys.which`'s own search, step for step); `""` when nothing is
found.
"""
function snapshot_which(s::BuildEnvSnapshot, program_name::AbstractString)::String
    program_name = String(program_name)
    isempty(program_name) && return ""
    names = String[]
    base = basename(program_name)
    if Sys.iswindows()
        isempty(splitext(base)[2]) || push!(names, base)
        for ext in (".exe", ".com")
            push!(names, string(base, ext))
        end
    else
        push!(names, base)
    end
    dirs = String[]
    program_dir = dirname(program_name)
    if isempty(program_dir)
        separator = Sys.iswindows() ? ';' : ':'
        dirs = map(abspath, eachsplit(get(s, "PATH", ""), separator))
        Sys.iswindows() && pushfirst!(dirs, pwd())
    else
        push!(dirs, abspath(program_dir))
    end
    for dir in dirs, name in names
        candidate = joinpath(dir, name)
        try
            isfile(candidate) && Sys.isexecutable(candidate) && return candidate
        catch e
            e isa Base.IOError && e.code == Base.UV_EACCES && continue
            rethrow()
        end
    end
    return ""
end

# The test seam of #481: a function stored in the task-local storage of the
# task that takes a snapshot, under this key, runs right after the snapshot is
# taken — where another task changing `ENV` does the most damage — so a test
# can mutate the environment at exactly that point, deterministically. Task
# local, not a module-level hook: nothing another task does can install one.
const _AFTER_BUILD_ENV_SNAPSHOT = :rustcall_after_build_env_snapshot

function _after_build_env_snapshot()
    hook = get(task_local_storage(), _AFTER_BUILD_ENV_SNAPSHOT, nothing)
    hook === nothing || hook()
    return nothing
end
