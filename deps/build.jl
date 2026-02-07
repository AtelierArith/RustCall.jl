# Build script for RustCall.jl
# This script verifies that the required tools are available and builds Rust helpers

using RustToolChain: rustc, cargo

"""
    check_rust_toolchain() -> Bool

Check if Rust toolchain (rustc and cargo) is available using RustToolChain.jl.
Returns true if both are available, false otherwise.
"""
function check_rust_toolchain()
    # Check for rustc
    rustc_available = false
    try
        rustc_version = read(`$(rustc()) --version`, String)
        println("✓ Found rustc: ", strip(rustc_version))
        rustc_available = true
    catch e
        println("✗ rustc not found. RustToolChain.jl should provide rustc.")
        return false
    end

    # Check for cargo (required for building Rust helpers)
    cargo_available = false
    try
        cargo_version = read(`$(cargo()) --version`, String)
        println("✓ Found cargo: ", strip(cargo_version))
        cargo_available = true
    catch
        println("✗ cargo not found. RustToolChain.jl should provide cargo.")
        return false
    end

    return rustc_available && cargo_available
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
    build_rust_helpers() -> String

Build the Rust helpers library and return the path to the compiled library.
Throws an error if the build fails.
"""
function build_rust_helpers()
    deps_dir = @__DIR__
    helpers_dir = joinpath(deps_dir, "rust_helpers")
    cargo_toml = joinpath(helpers_dir, "Cargo.toml")

    if !isfile(cargo_toml)
        error("Cargo.toml not found at: $cargo_toml")
    end

    if !isdir(helpers_dir)
        error("Rust helpers directory not found at: $helpers_dir")
    end

    println("Building Rust helpers library...")
    println("  Directory: $helpers_dir")
    println("  Cargo.toml: $cargo_toml")

    # Build with cargo using RustToolChain.jl
    try
        println("  Running: $(cargo()) build --release --manifest-path $cargo_toml")
        run(`$(cargo()) build --release --manifest-path $cargo_toml`)
        println("  ✓ Cargo build completed successfully")
    catch e
        error("""
        Failed to build Rust helpers library: $e

        Common issues:
        1. Rust toolchain not installed - install from https://rustup.rs/
        2. Cargo.toml has syntax errors
        3. Missing dependencies in Cargo.toml
        4. Insufficient permissions to write to target directory

        Try running manually:
            cd $helpers_dir
            cargo build --release
        """)
    end

    # Find the compiled library
    # Cargo builds to target/release/ on Unix and target/release/ on Windows
    lib_ext = get_library_extension()
    target_dir = joinpath(helpers_dir, "target", "release")

    # Library name is "rust_helpers" (from Cargo.toml) with platform extension
    if Sys.iswindows()
        lib_name = "rust_helpers.dll"
    else
        lib_name = "librust_helpers$(lib_ext)"
    end

    lib_path = joinpath(target_dir, lib_name)

    if !isfile(lib_path)
        error("""
        Built library not found at expected path: $lib_path

        The build may have succeeded but the library was not created.
        Check the cargo build output for errors.

        Expected location: $target_dir
        Library name: $lib_name
        """)
    end

    # Verify library is readable
    try
        stat(lib_path)
    catch e
        error("Built library exists but cannot be accessed: $lib_path ($e)")
    end

    println("  ✓ Built library: $lib_path")
    println("  ✓ Library size: $(filesize(lib_path)) bytes")
    return lib_path
end

"""
    get_rust_helpers_lib_path() -> Union{String, Nothing}

Get the path to the Rust helpers library if it exists (either built or in a standard location).
"""
function get_rust_helpers_lib_path()
    deps_dir = @__DIR__
    helpers_dir = joinpath(deps_dir, "rust_helpers")
    lib_ext = get_library_extension()
    target_dir = joinpath(helpers_dir, "target", "release")

    # Library name
    if Sys.iswindows()
        lib_name = "rust_helpers.dll"
    else
        lib_name = "librust_helpers$(lib_ext)"
    end

    lib_path = joinpath(target_dir, lib_name)

    if isfile(lib_path)
        return lib_path
    end

    return nothing
end

# Main build process
function main()
    println("=" ^ 60)
    println("RustCall.jl - Rust Helpers Library Build")
    println("=" ^ 60)
    println()

    # Check Rust toolchain
    if !check_rust_toolchain()
        error("Rust toolchain check failed. Please install Rust from https://rustup.rs/")
    end
    println()

    # Check if library already exists
    existing_lib = get_rust_helpers_lib_path()
    if existing_lib !== nothing
        println("✓ Rust helpers library already built: $existing_lib")
        println("  To rebuild, delete the library and run this script again.")
        println()
        return existing_lib
    end

    # Build the library
    println("Building Rust helpers library...")
    println()
    lib_path = build_rust_helpers()
    println()
    println("=" ^ 60)
    println("✓ RustCall.jl build completed successfully!")
    println("=" ^ 60)
    return lib_path
end

# Run the build process
# Pkg.build includes this file, so we always run main() when included
# This ensures the Rust helpers library is built when Pkg.build("RustCall") is called
main()
