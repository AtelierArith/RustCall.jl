# Build script for LastCall.jl
# This script verifies that the required tools are available and builds Rust helpers

function check_rust_toolchain()
    # Check for rustc
    try
        rustc_version = read(`rustc --version`, String)
        println("Found rustc: ", strip(rustc_version))
    catch e
        error("rustc not found. Please install Rust from https://rustup.rs/")
    end

    # Check for cargo (required for building Rust helpers)
    try
        cargo_version = read(`cargo --version`, String)
        println("Found cargo: ", strip(cargo_version))
    catch
        error("cargo not found. Please install Rust from https://rustup.rs/")
    end
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
"""
function build_rust_helpers()
    deps_dir = @__DIR__
    helpers_dir = joinpath(deps_dir, "rust_helpers")
    cargo_toml = joinpath(helpers_dir, "Cargo.toml")

    if !isfile(cargo_toml)
        error("Cargo.toml not found at: $cargo_toml")
    end

    println("Building Rust helpers library...")
    println("  Directory: $helpers_dir")

    # Build with cargo
    try
        run(`cargo build --release --manifest-path $cargo_toml`)
    catch e
        error("Failed to build Rust helpers library: $e")
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
        error("Built library not found at expected path: $lib_path")
    end

    println("  Built library: $lib_path")
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

# Run checks
check_rust_toolchain()

# Build Rust helpers if not already built
if get_rust_helpers_lib_path() === nothing
    build_rust_helpers()
else
    println("Rust helpers library already built: $(get_rust_helpers_lib_path())")
end

println("LastCall.jl build completed successfully.")
