# Rust compiler (rustc) wrapper for LLVM IR generation

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
        fingerprint = bytes2hex(sha256(code))[1:RECOVERY_FINGERPRINT_LEN]
        return "rust_$(fingerprint)"
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
const DEFAULT_COMPILER = Ref{RustCompiler}()

"""
    get_default_compiler() -> RustCompiler

Get or create the default RustCompiler instance.
"""
function get_default_compiler()
    if !isassigned(DEFAULT_COMPILER)
        DEFAULT_COMPILER[] = RustCompiler()
    end
    return DEFAULT_COMPILER[]
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
    compile_rust_to_llvm_ir(code::String; compiler=get_default_compiler()) -> String

Compile Rust code to LLVM IR and return the path to the generated .ll file.

# Arguments
- `code::String`: Rust source code

# Keyword Arguments
- `compiler::RustCompiler`: Compiler configuration (default: default compiler)

# Returns
- Path to the generated LLVM IR file (.ll)

# Throws
- `CompilationError` if compilation fails
"""
function compile_rust_to_llvm_ir(code::String; compiler::RustCompiler = get_default_compiler())
    # Create a unique temporary directory for this compilation
    if compiler.debug_mode && compiler.debug_dir !== nothing
        tmp_dir = compiler.debug_dir
        mkpath(tmp_dir)
    else
        tmp_dir = mktempdir()
    end

    # Use unique filenames in debug_dir to avoid overwriting across compilations
    base_name = _unique_source_name(code, compiler)
    rs_file = joinpath(tmp_dir, "$(base_name).rs")
    ll_file = joinpath(tmp_dir, "$(base_name).ll")
    success_flag = false

    try
        # Write the Rust code to the temporary file
        write(rs_file, code)

        # Build the rustc command using RustToolChain.jl
        rustc_cmd = rustc()
        cmd_args = vcat(
            [string(rustc_cmd.exec[1])],  # Get the actual rustc path from RustToolChain
            [
                "--emit=llvm-ir",
                "--crate-type=cdylib",
                "-C", "opt-level=$(compiler.optimization_level)",
                "-C", "panic=abort",  # Simpler error handling for FFI
                "--target=$(compiler.target_triple)",
                "-o", ll_file,
                rs_file
            ]
        )

        if compiler.emit_debug_info
            push!(cmd_args, "-g")
        end

        # Run rustc and capture stderr
        cmd = Cmd(cmd_args)
        cmd_str = join(cmd_args, " ")

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
                        "ll_file" => ll_file,
                        "error_count" => length(error_lines),
                        "debug_mode" => compiler.debug_mode
                    )

                    # Format and throw compilation error
                    throw(CompilationError(
                        "Failed to compile Rust code to LLVM IR",
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
        if !isfile(ll_file)
            context = Dict{String, Any}(
                "expected_file" => ll_file,
                "tmp_dir" => tmp_dir,
                "debug_mode" => compiler.debug_mode
            )

            throw(CompilationError(
                "LLVM IR file was not generated",
                "Output file does not exist: $ll_file",
                code,
                cmd_str;
                file_path=rs_file,
                context=context
            ))
        end

        # Debug mode: print file locations and additional info
        if compiler.debug_mode
            @info "Debug mode: LLVM IR generated" file=ll_file source=rs_file
            @info "Debug mode: Temporary directory" dir=tmp_dir
            if compiler.emit_debug_info
                @info "Debug mode: Debug info enabled"
            end
        end

        success_flag = true
        return ll_file
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
    # Create a unique temporary directory for this compilation
    if compiler.debug_mode && compiler.debug_dir !== nothing
        tmp_dir = compiler.debug_dir
        mkpath(tmp_dir)
    else
        tmp_dir = mktempdir()
    end

    # Use unique filenames in debug_dir to avoid overwriting across compilations
    base_name = _unique_source_name(code, compiler)
    rs_file = joinpath(tmp_dir, "$(base_name).rs")
    lib_ext = get_library_extension()
    lib_file = joinpath(tmp_dir, "lib$(base_name)$lib_ext")
    success_flag = false

    try
        # Write the Rust code to the temporary file
        write(rs_file, code)

        # Build the rustc command for shared library using RustToolChain.jl
        rustc_cmd = rustc()
        cmd_args = vcat(
            [string(rustc_cmd.exec[1])],  # Get the actual rustc path from RustToolChain
            [
                "--crate-type=cdylib",
                "-C", "opt-level=$(compiler.optimization_level)",
                "-C", "panic=abort",
                "--target=$(compiler.target_triple)",
                "-o", lib_file,
                rs_file
            ]
        )

        if compiler.emit_debug_info
            push!(cmd_args, "-g")
        end

        # Run rustc and capture stderr
        cmd = Cmd(cmd_args)
        cmd_str = join(cmd_args, " ")

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

"""
    compile_with_recovery(code::String, compiler::RustCompiler;
                          retry_count::Int=1) -> String

Compile Rust code with error recovery support.
If compilation fails, attempts to retry with different compiler settings.

# Arguments
- `code::String`: Rust source code
- `compiler::RustCompiler`: Compiler configuration

# Keyword Arguments
- `retry_count::Int`: Number of retry attempts (default: 1)

# Returns
- Path to the generated shared library

# Throws
- `CompilationError` if all recovery attempts fail

# Note
Cache recovery should be handled by the caller (e.g., in `ruststr.jl`).
This function only handles retry with different compiler settings.
"""
function compile_with_recovery(
    code::String,
    compiler::RustCompiler;
    retry_count::Int = 1
)
    wrapped_code = wrap_rust_code(code)

    # Try normal compilation first
    try
        return compile_rust_to_shared_lib(wrapped_code; compiler=compiler)
    catch e
        if !isa(e, CompilationError)
            rethrow(e)
        end

        # Attempt recovery
        code_fingerprint = bytes2hex(sha256(wrapped_code))[1:RECOVERY_FINGERPRINT_LEN]
        if compiler.debug_mode
            @warn "Compilation failed, attempting recovery..." code_id=code_fingerprint code_len=ncodeunits(wrapped_code) opt_level=compiler.optimization_level emit_debug_info=compiler.emit_debug_info target=compiler.target_triple
        else
            @debug "Compilation failed, attempting recovery..." code_id=code_fingerprint code_len=ncodeunits(wrapped_code) opt_level=compiler.optimization_level emit_debug_info=compiler.emit_debug_info target=compiler.target_triple
        end

        # Recovery attempt 1: Retry with lower optimization level
        if retry_count > 0 && compiler.optimization_level > 0
            if compiler.debug_mode
                @info "Recovery: Retrying with lower optimization level" code_id=code_fingerprint
            else
                @debug "Recovery: Retrying with lower optimization level" code_id=code_fingerprint
            end
            retry_compiler = RustCompiler(
                compiler.target_triple,
                compiler.optimization_level - 1,
                compiler.emit_debug_info,
                compiler.debug_mode,
                compiler.debug_dir
            )
            try
                return compile_rust_to_shared_lib(wrapped_code; compiler=retry_compiler)
            catch retry_e
                @debug "Retry with lower optimization failed: $retry_e"
            end
        end

        # Recovery attempt 2: Retry with debug info enabled
        if retry_count > 0 && !compiler.emit_debug_info
            if compiler.debug_mode
                @info "Recovery: Retrying with debug info enabled" code_id=code_fingerprint
            else
                @debug "Recovery: Retrying with debug info enabled" code_id=code_fingerprint
            end
            retry_compiler = RustCompiler(
                compiler.target_triple,
                compiler.optimization_level,
                true,  # Enable debug info
                compiler.debug_mode,
                compiler.debug_dir
            )
            try
                return compile_rust_to_shared_lib(wrapped_code; compiler=retry_compiler)
            catch retry_e
                @debug "Retry with debug info failed: $retry_e"
            end
        end

        # All recovery attempts failed, rethrow original error
        if compiler.debug_mode
            @error "All recovery attempts failed" code_id=code_fingerprint
        else
            @debug "All recovery attempts failed" code_id=code_fingerprint
        end
        rethrow(e)
    end
end
