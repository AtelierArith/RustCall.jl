# Shared by the PyO3 wrapper test files. A link-plan mode is not enough to
# decide whether a wrapper can be built: the interpreter directory may exist
# while its development package (and therefore the linkable library) does not.
function _linkable_python_library(dir::AbstractString)
    isempty(dir) && return false
    isdir(dir) || return false
    names = readdir(dir)
    if Sys.islinux()
        return any(name -> startswith(name, "libpython") && endswith(name, ".so"), names)
    elseif Sys.isapple()
        return any(name -> startswith(name, "libpython") && endswith(name, ".dylib"), names) ||
               isdir(joinpath(dir, "Python3.framework"))
    elseif Sys.iswindows()
        return any(name -> startswith(name, "python3") && endswith(name, ".lib"), names)
    end
    return false
end

function _link_libpython_wrapper(crate; features::Vector{String} = String[],
                                 default_features::Bool = true,
                                 cache_enabled::Bool = true,
                                 build_wrapper = RustCall.build_pyo3_wrapper)
    RustCall.check_rustc_available() || return nothing
    plan = RustCall.pyo3_link_plan(crate; features = features,
                                   default_features = default_features)
    if plan.mode !== :link_libpython
        @info "skipping the :link_libpython wrapper testset" reason = plan.reason
        return nothing
    end
    if !_linkable_python_library(plan.rpath)
        reason = isempty(plan.rpath) ?
            "the link plan has no interpreter library directory" :
            "no linkable Python library in $(plan.rpath)"
        @info "skipping the :link_libpython wrapper testset" reason
        return nothing
    end
    info = RustCall.scan_crate(crate)
    # Deliberately outside a try/catch: once the prerequisite is present, a
    # wrapper-generation, Cargo, compiler, or loading regression is a failure.
    return build_wrapper(info; features = features,
                         default_features = default_features,
                         cache_enabled = cache_enabled)
end

# The version of the Python a wrapper links, as the interpreter
# `python_link_source` names reports it; `nothing` when it names none or the
# interpreter cannot be asked (#548).
function _linked_python_version()
    exe = RustCall.python_link_source()[2]
    isempty(exe) && return nothing
    out = try
        read(`$exe -c "import platform; print(platform.python_version())"`, String)
    catch
        return nothing
    end
    m = match(r"^(\d+)\.(\d+)\.(\d+)", strip(out))
    return m === nothing ? nothing : VersionNumber(parse.(Int, m.captures)...)
end

# Whether a wrapper call on a Julia task's stack is expected to release a
# Python-owned object (#542, #548). Before 3.14 CPython's limit is a call
# count, not an address, so a task stack is no different. From 3.14 on it is
# an address range the wrapper re-fits to the task, which needs CPython's
# `PyUnstable_ThreadState_SetStackProtection` (3.14.1+) and is implemented for
# Linux and macOS only. An unknown version is held to the fix.
function _task_stack_fit_applies(version; windows::Bool = Sys.iswindows())
    version === nothing && return true
    version < v"3.14" && return true
    windows && return false
    return version >= v"3.14.1"
end
