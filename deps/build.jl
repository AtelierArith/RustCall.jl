# Build script for LastCall.jl
# This script verifies that the required tools are available

function check_rust_toolchain()
    # Check for rustc
    try
        rustc_version = read(`rustc --version`, String)
        println("Found rustc: ", strip(rustc_version))
    catch e
        error("rustc not found. Please install Rust from https://rustup.rs/")
    end

    # Check for cargo (optional but recommended)
    try
        cargo_version = read(`cargo --version`, String)
        println("Found cargo: ", strip(cargo_version))
    catch
        @warn "cargo not found. Some features may be limited."
    end
end

# Run checks
check_rust_toolchain()
println("LastCall.jl build completed successfully.")
