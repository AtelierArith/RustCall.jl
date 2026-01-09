# Rust compiler (rustc) wrapper for LLVM IR generation

"""
    RustCompiler

Configuration for the Rust compiler.
"""
struct RustCompiler
    target_triple::String
    optimization_level::Int  # 0-3
    emit_debug_info::Bool
end

"""
    RustCompiler(; kwargs...)

Create a RustCompiler with the specified settings.

# Keyword Arguments
- `target_triple::String`: Target triple for compilation (default: auto-detect)
- `optimization_level::Int`: Optimization level 0-3 (default: 2)
- `emit_debug_info::Bool`: Whether to emit debug info (default: false)
"""
function RustCompiler(;
    target_triple::String = get_default_target(),
    optimization_level::Int = 2,
    emit_debug_info::Bool = false
)
    @assert 0 <= optimization_level <= 3 "Optimization level must be 0-3"
    RustCompiler(target_triple, optimization_level, emit_debug_info)
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

Check if rustc is available in the system PATH.
"""
function check_rustc_available()
    try
        run(pipeline(`rustc --version`, devnull))
        return true
    catch
        return false
    end
end

"""
    get_rustc_version() -> String

Get the version of rustc.
"""
function get_rustc_version()
    try
        return strip(read(`rustc --version`, String))
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
"""
function compile_rust_to_llvm_ir(code::String; compiler::RustCompiler = get_default_compiler())
    # Create a unique temporary directory for this compilation
    tmp_dir = mktempdir()
    rs_file = joinpath(tmp_dir, "rust_code.rs")
    ll_file = joinpath(tmp_dir, "rust_code.ll")

    # Write the Rust code to the temporary file
    write(rs_file, code)

    # Build the rustc command
    cmd_args = String[
        "rustc",
        "--emit=llvm-ir",
        "--crate-type=cdylib",
        "-C", "opt-level=$(compiler.optimization_level)",
        "-C", "panic=abort",  # Simpler error handling for FFI
        "--target=$(compiler.target_triple)",
        "-o", ll_file,
        rs_file
    ]

    if compiler.emit_debug_info
        push!(cmd_args, "-g")
    end

    # Run rustc
    cmd = Cmd(cmd_args)
    try
        run(cmd)
    catch e
        # Clean up on error
        rm(tmp_dir, recursive=true, force=true)
        error("Failed to compile Rust code:\n$e\n\nSource code:\n$code")
    end

    # Verify the output file exists
    if !isfile(ll_file)
        rm(tmp_dir, recursive=true, force=true)
        error("LLVM IR file was not generated. Check rustc output.")
    end

    return ll_file
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
"""
function compile_rust_to_shared_lib(code::String; compiler::RustCompiler = get_default_compiler())
    # Create a unique temporary directory for this compilation
    tmp_dir = mktempdir()
    rs_file = joinpath(tmp_dir, "rust_code.rs")
    lib_ext = get_library_extension()
    lib_file = joinpath(tmp_dir, "librust_code$lib_ext")

    # Write the Rust code to the temporary file
    write(rs_file, code)

    # Build the rustc command for shared library
    cmd_args = String[
        "rustc",
        "--crate-type=cdylib",
        "-C", "opt-level=$(compiler.optimization_level)",
        "-C", "panic=abort",
        "--target=$(compiler.target_triple)",
        "-o", lib_file,
        rs_file
    ]

    if compiler.emit_debug_info
        push!(cmd_args, "-g")
    end

    # Run rustc
    cmd = Cmd(cmd_args)
    try
        run(cmd)
    catch e
        rm(tmp_dir, recursive=true, force=true)
        error("Failed to compile Rust code to shared library:\n$e\n\nSource code:\n$code")
    end

    # Verify the output file exists
    if !isfile(lib_file)
        rm(tmp_dir, recursive=true, force=true)
        error("Shared library was not generated. Check rustc output.")
    end

    return lib_file
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
