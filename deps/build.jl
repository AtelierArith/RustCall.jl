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
function clean_rust_helpers(cargo_toml::String)
    println("  Running: $(cargo()) clean --manifest-path $cargo_toml")
    run(`$(cargo()) clean --manifest-path $cargo_toml`)
    println("  ✓ Cargo clean completed successfully")
end

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

    # Clean first so Pkg.build() always performs a fresh Cargo rebuild.
    try
        clean_rust_helpers(cargo_toml)
    catch e
        error("""
        Failed to clean Rust helpers build artifacts: $e

        Try running manually:
            cd $helpers_dir
            cargo clean
        """)
    end

    # Build with cargo using RustToolChain.jl
    try
        println("  Running: $(cargo()) build --release --manifest-path $cargo_toml")
        # `panic = "unwind"` is pinned in deps/rust_helpers/Cargo.toml; setting
        # it here too means an inherited CARGO_PROFILE_RELEASE_PANIC cannot
        # decide it either (#244). The two agree by construction: the manifest
        # is what `helper_library_policy()` describes.
        build_env = copy(ENV)
        build_env["CARGO_PROFILE_RELEASE_PANIC"] = "unwind"
        run(setenv(`$(cargo()) build --release --manifest-path $cargo_toml`, build_env))
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
    build_rustcall_extract() -> String

Build the `rustcall-extract` CLI (deps/rustcall_extract) and return the path to the
binary. The CLI is the only component that interprets Rust syntax on behalf of
Julia: it produces the FFI manifest, expands `#[julia]` items in inline
`rust\"\"\"` blocks, and instantiates generic functions.
"""
function build_rustcall_extract()
    deps_dir = @__DIR__
    extract_dir = joinpath(deps_dir, "rustcall_extract")
    cargo_toml = joinpath(extract_dir, "Cargo.toml")

    if !isfile(cargo_toml)
        error("Cargo.toml not found at: $cargo_toml")
    end

    println("Building rustcall-extract CLI...")
    println("  Directory: $extract_dir")

    try
        println("  Running: $(cargo()) build --release --manifest-path $cargo_toml")
        # `panic = "unwind"` is pinned in deps/rust_helpers/Cargo.toml; setting
        # it here too means an inherited CARGO_PROFILE_RELEASE_PANIC cannot
        # decide it either (#244). The two agree by construction: the manifest
        # is what `helper_library_policy()` describes.
        build_env = copy(ENV)
        build_env["CARGO_PROFILE_RELEASE_PANIC"] = "unwind"
        run(setenv(`$(cargo()) build --release --manifest-path $cargo_toml`, build_env))
        println("  ✓ Cargo build completed successfully")
    catch e
        error("""
        Failed to build rustcall-extract CLI: $e

        Try running manually:
            cd $extract_dir
            cargo build --release
        """)
    end

    bin_name = Sys.iswindows() ? "rustcall-extract.exe" : "rustcall-extract"
    bin_path = joinpath(extract_dir, "target", "release", bin_name)
    if !isfile(bin_path)
        error("Built binary not found at expected path: $bin_path")
    end

    println("  ✓ Built binary: $bin_path")
    return bin_path
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
    println("RustCall.jl - Rust Helpers Library and Extractor CLI Build")
    println("=" ^ 60)
    println()

    # Check Rust toolchain
    if !check_rust_toolchain()
        error("Rust toolchain check failed. Please install Rust from https://rustup.rs/")
    end
    println()

    existing_lib = get_rust_helpers_lib_path()
    if existing_lib !== nothing
        println("Found existing Rust helpers library: $existing_lib")
        println("Rebuilding from a clean Cargo state...")
        println()
    else
        println("Building Rust helpers library...")
        println()
    end

    # Build the library (always clean + rebuild)
    lib_path = build_rust_helpers()
    println()

    # Build the extractor CLI used by rust"" blocks, @rust_crate and generics
    build_rustcall_extract()
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
