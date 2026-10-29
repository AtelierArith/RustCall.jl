# Rust compiler (rustc) wrapper: compiles Rust source to a shared library

using RustToolChain: rustc, cargo
using SHA

const RECOVERY_FINGERPRINT_LEN = 12

"""
    RustCompiler

Configuration for the Rust compiler.

# Fields
- `target_triple::String`: Target triple for compilation
- `optimization_level::Int`: Optimization level 0-3
- `emit_debug_info::Bool`: Whether to emit debug info
- `debug_mode::Bool`: Enable debug mode (keep intermediate files, verbose output)
- `debug_dir::Union{String, Nothing}`: Directory to keep debug files (default: nothing = use temp dir)
"""
struct RustCompiler
    target_triple::String
    optimization_level::Int  # 0-3
    emit_debug_info::Bool
    debug_mode::Bool
    debug_dir::Union{String, Nothing}

    function RustCompiler(
        target_triple::String,
        optimization_level::Int,
        emit_debug_info::Bool,
        debug_mode::Bool,
        debug_dir::Union{String, Nothing}
    )
        @assert 0 <= optimization_level <= 3 "Optimization level must be 0-3"
        new(target_triple, optimization_level, emit_debug_info, debug_mode, debug_dir)
    end
end

"""
    RustCompiler(; kwargs...)

Create a RustCompiler with the specified settings.

# Keyword Arguments
- `target_triple::String`: Target triple for compilation (default: auto-detect)
- `optimization_level::Int`: Optimization level 0-3 (default: 2)
- `emit_debug_info::Bool`: Whether to emit debug info (default: false)
- `debug_mode::Bool`: Enable debug mode (default: false)
- `debug_dir::Union{String, Nothing}`: Directory to keep debug files (default: nothing)
"""
function RustCompiler(;
    target_triple::String = get_default_target(),
    optimization_level::Int = 2,
    emit_debug_info::Bool = false,
    debug_mode::Bool = false,
    debug_dir::Union{String, Nothing} = nothing
)
    RustCompiler(target_triple, optimization_level, emit_debug_info, debug_mode, debug_dir)
end

"""
    _unique_source_name(code::String, compiler::RustCompiler) -> String

Generate a unique base filename for a compilation unit. When `debug_dir` is set,
uses a hash of the code to avoid overwriting files from different compilations.
Otherwise returns a fixed name since each compilation uses its own temp directory.
"""
function _unique_source_name(code::String, compiler::RustCompiler)
    if compiler.debug_mode && compiler.debug_dir !== nothing
        # A location in the shared `debug_dir`, so a short name owned by the
        # full content digest (`compile_rust_to_shared_lib` claims it, #504).
        return short_name(stable_content_hash(code); prefix = "rust_", n = RECOVERY_FINGERPRINT_LEN)
    end
    return "rust_code"
end

"""
    get_default_target() -> String

Get the default target triple for the current platform.
"""
function get_default_target()
    if Sys.iswindows()
        return Sys.ARCH == :x86_64 ? "x86_64-pc-windows-msvc" : "i686-pc-windows-msvc"
    elseif Sys.isapple()
        if Sys.ARCH == :aarch64
            return "aarch64-apple-darwin"
        else
            return "x86_64-apple-darwin"
        end
    else  # Linux and others
        if Sys.ARCH == :aarch64
            return "aarch64-unknown-linux-gnu"
        else
            return "x86_64-unknown-linux-gnu"
        end
    end
end

"""
    rustc_command(args) -> Cmd

The `rustc` RustToolChain.jl resolves, run with `args` appended — its **whole**
command, not just the executable. With the artifact toolchain RustToolChain
returns `` `rustc --sysroot <prefix>` `` (Unix) or a `setenv(...)` command
(Windows); keeping only `exec[1]` dropped both, so a build or probe ran a
compiler with no standard library while the `rustc --print cfg` probe, which
used the full command, saw a different one (#460). Every place RustCall runs
`rustc` directly builds its command here, so the compile, the generic-group
check and the cfg probe cannot disagree.

`base` is for tests; it defaults to `rustc()`.
"""
function rustc_command(args::AbstractVector{<:AbstractString}; base::Cmd = rustc())
    return Cmd(Cmd(vcat(base.exec, String.(args)));
               ignorestatus = base.ignorestatus, env = base.env, dir = base.dir)
end

"""
    check_rustc_available() -> Bool

Check if rustc is available using RustToolChain.jl.
"""
function check_rustc_available()
    try
        run(pipeline(`$(rustc()) --version`, devnull))
        return true
    catch
        return false
    end
end

"""
    get_rustc_version() -> String

Get the version of rustc using RustToolChain.jl.
"""
function get_rustc_version()
    try
        return strip(read(`$(rustc()) --version`, String))
    catch e
        error("Failed to get rustc version: $e")
    end
end

# Global default compiler instance
const DEFAULT_COMPILER = _state_view(:default_compiler, Ref{RustCompiler}())

"""
    get_default_compiler() -> RustCompiler

Get or create the default RustCompiler instance.
"""
function get_default_compiler()
    return _default_compiler(RustCompiler)
end

function _default_compiler(make_compiler)
    cached = _state_read(DEFAULT_COMPILER) do value
        isassigned(value) ? value[] : nothing
    end
    cached === nothing || return cached
    candidate = make_compiler()
    return _state_read(DEFAULT_COMPILER) do value
        # A concurrent setter or initializer wins over this candidate. Never
        # overwrite a compiler published while its replacement was computed.
        isassigned(value) || (value[] = candidate)
        value[]
    end
end

"""
    set_default_compiler(compiler::RustCompiler)

Set the default RustCompiler instance.
"""
function set_default_compiler(compiler::RustCompiler)
    DEFAULT_COMPILER[] = compiler
end

"""
    get_library_extension() -> String

Get the shared library extension for the current platform.
"""
function get_library_extension()
    if Sys.iswindows()
        return ".dll"
    elseif Sys.isapple()
        return ".dylib"
    else
        return ".so"
    end
end

"""
    compile_rust_to_shared_lib(code::String; compiler=get_default_compiler()) -> String

Compile Rust code to a shared library and return the path.

# Arguments
- `code::String`: Rust source code

# Keyword Arguments
- `compiler::RustCompiler`: Compiler configuration (default: default compiler)

# Returns
- Path to the generated shared library

# Throws
- `CompilationError` if compilation fails
"""
function compile_rust_to_shared_lib(code::String; compiler::RustCompiler = get_default_compiler())
    if compiler.debug_mode && compiler.debug_dir !== nothing
        # The files are kept in `debug_dir`, named by a short name of the
        # code's digest (`_unique_source_name`) that every compilation shares.
        # The name is owned by the full digest — code whose digest shares the
        # prefix is refused rather than overwriting these files — and held
        # under its lock from writing the source until rustc has written the
        # library, so two compilations of one name take turns (#504).
        tmp_dir = compiler.debug_dir
        mkpath(tmp_dir)
        base_name = _unique_source_name(code, compiler)
        # `:clear`: files of this name without a record (from a RustCall that
        # kept none) are RustCall's own debug outputs, which this compilation
        # rewrites anyway; they are removed rather than left to look like its
        # output. Nothing else in `debug_dir` is touched.
        return with_owned_short_name(joinpath(tmp_dir, base_name), stable_content_hash(code);
                                     stem = true, foreign = :clear,
                                     what = "this Rust code") do
            _compile_rust_to_shared_lib(code, compiler, tmp_dir, base_name)
        end
    end
    # A unique temporary directory for this compilation, and a fixed name in it.
    return _compile_rust_to_shared_lib(code, compiler, mktempdir(),
                                       _unique_source_name(code, compiler))
end

function _compile_rust_to_shared_lib(code::String, compiler::RustCompiler,
                                     tmp_dir::String, base_name::String)
    rs_file = joinpath(tmp_dir, "$(base_name).rs")
    lib_ext = get_library_extension()
    lib_file = joinpath(tmp_dir, "lib$(base_name)$lib_ext")
    success_flag = false

    try
        # Write the Rust code to the temporary file
        write(rs_file, code)

        # Build the rustc command for shared library using RustToolChain.jl
        # The arguments only; `rustc_command` prepends RustToolChain's whole
        # command (sysroot / environment included, #460).
        cmd_args = String[
            "--crate-type=cdylib",
            "-C", "opt-level=$(compiler.optimization_level)",
            # Unwinding is what makes the generated `catch_unwind`
            # boundary able to catch anything at all: an aborting profile
            # terminates the process before any boundary runs, so a Rust
            # bug would still take the Julia session with it (#244).
            # Pinned by the policy, not left to rustc's default, so this
            # cannot drift from what the Cargo path does.
            rustc_panic_flags(inline_rustc_policy())...,
            "--target=$(compiler.target_triple)",
            "-o", lib_file,
            rs_file
        ]

        if compiler.emit_debug_info
            push!(cmd_args, "-g")
        end

        # Run rustc and capture stderr
        cmd = rustc_command(cmd_args)
        cmd_str = join(cmd.exec, " ")

        try
            # Capture stderr for better error messages
            stderr_io = IOBuffer()
            try
                proc = run(pipeline(cmd, stderr=stderr_io), wait=false)
                wait(proc)

                if !Base.success(proc)
                    stderr_str = String(take!(stderr_io))

                    if compiler.debug_mode
                        @warn "Debug mode: keeping intermediate files in $tmp_dir"
                        @info "Debug mode: You can inspect the files to debug the compilation error"
                        @info "Debug mode: Source file" file=rs_file
                        @info "Debug mode: Command" cmd=cmd_str
                    end

                    # Extract error line numbers and file path
                    error_lines = RustCall._extract_error_line_numbers_impl(stderr_str)
                    line_num = isempty(error_lines) ? 0 : error_lines[1]

                    # Build context dictionary
                    context = Dict{String, Any}(
                        "tmp_dir" => tmp_dir,
                        "rs_file" => rs_file,
                        "lib_file" => lib_file,
                        "error_count" => length(error_lines),
                        "debug_mode" => compiler.debug_mode
                    )

                    # Format and throw compilation error
                    throw(CompilationError(
                        "Failed to compile Rust code to shared library",
                        stderr_str,
                        code,
                        cmd_str;
                        file_path=rs_file,
                        line_number=line_num,
                        context=context
                    ))
                end
            finally
                close(stderr_io)
            end
        catch e
            if isa(e, CompilationError)
                rethrow(e)
            end

            if compiler.debug_mode
                @warn "Debug mode: keeping intermediate files in $tmp_dir"
            end

            # Fallback error
            throw(CompilationError(
                "Unexpected error during compilation: $e",
                "",
                code,
                cmd_str
            ))
        end

        # Verify the output file exists
        if !isfile(lib_file)
            context = Dict{String, Any}(
                "expected_file" => lib_file,
                "tmp_dir" => tmp_dir,
                "debug_mode" => compiler.debug_mode
            )

            throw(CompilationError(
                "Shared library was not generated",
                "Output file does not exist: $lib_file",
                code,
                cmd_str;
                file_path=rs_file,
                context=context
            ))
        end

        # Debug mode: print file locations and additional info
        if compiler.debug_mode
            @info "Debug mode: Shared library generated" file=lib_file source=rs_file
            @info "Debug mode: Temporary directory" dir=tmp_dir
            if compiler.emit_debug_info
                @info "Debug mode: Debug info enabled"
            end
            @info "Debug mode: Optimization level" level=compiler.optimization_level
        end

        success_flag = true
        return lib_file
    finally
        # Clean up temp directory on error paths, unless debug mode retains files
        if !success_flag && !compiler.debug_mode && isdir(tmp_dir)
            try
                rm(tmp_dir, recursive=true, force=true)
            catch
                # Best-effort cleanup; ignore errors (e.g., locked files on Windows)
            end
        end
    end
end

"""
    wrap_rust_code(code::String) -> String

Wrap Rust code to ensure it has the necessary FFI exports.
This adds common imports and ensures extern "C" functions are properly exposed.
"""
function wrap_rust_code(code::String)
    # Check if the code already has the necessary attributes
    needs_wrapper = !occursin("#![crate_type", code) && !occursin("extern crate", code)

    if needs_wrapper
        return """
        #![allow(unused)]

        $code
        """
    end

    return code
end

