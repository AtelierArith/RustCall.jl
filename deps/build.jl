# Build script for RustCall.jl
#
# Builds the two native products the package needs and reports where they went:
#
#   * `deps/rust_helpers`     → the ownership helper cdylib (Box / Rc / Arc / Vec)
#   * `deps/rustcall_extract` → `rustcall-extract`, the only component that
#     interprets Rust syntax on behalf of Julia (FFI manifests, inline
#     expansion of `#[julia]` items, generic specialization)
#
# Two things changed in #258:
#
#   * **No `cargo clean`.** Through v0.3.4 every `Pkg.build("RustCall")` wiped
#     both target directories first, so every build event — including the
#     transitive ones Pkg triggers — paid a full Rust compile. Cargo already
#     knows which of its inputs changed, down to the `rustc` version and the
#     profile; a forced clean only throws that knowledge away. A rebuild with
#     unchanged sources is now a fraction of a second.
#   * **Nothing is written into an installed package.** `native_target_dir`
#     (src/native_layout.jl) sends an installed package's build products to a
#     scratch space and leaves a checkout building in `deps/<crate>/target`,
#     where the documented developer commands already put them.

using RustToolChain: rustc, cargo

# The one place that knows where these products live; `src/RustCall.jl`
# includes the same file, so the build and the lookup cannot drift apart.
include(joinpath(@__DIR__, "..", "src", "native_layout.jl"))

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
    build_native_product(kind::Symbol, what::String) -> String

Build `kind` with Cargo and return the path to the product.

The build is incremental: Cargo decides what to redo from its own fingerprint
of the sources, the profile and the `rustc` identity. The target directory
comes from `native_target_dir`, so the same `CARGO_TARGET_DIR` is used on every
build and an installed package's tree is never written to.
"""
function build_native_product(kind::Symbol, what::AbstractString)
    crate_dir = native_crate_dir(kind)
    cargo_toml = joinpath(crate_dir, "Cargo.toml")
    isfile(cargo_toml) || error("Cargo.toml not found at: $cargo_toml")

    target_dir = native_target_dir(kind; create = true)
    println("Building $what...")
    println("  Crate: $crate_dir")
    println("  Target directory: $target_dir")

    build_env = copy(ENV)
    build_env["CARGO_TARGET_DIR"] = target_dir
    # `panic = "unwind"` is pinned in deps/rust_helpers/Cargo.toml; setting it
    # here too means an inherited CARGO_PROFILE_RELEASE_PANIC cannot decide it
    # either (#244). The two agree by construction: the manifest is what
    # `helper_library_policy()` describes.
    build_env["CARGO_PROFILE_RELEASE_PANIC"] = "unwind"

    try
        println("  Running: $(cargo()) build --release --manifest-path $cargo_toml")
        run(setenv(`$(cargo()) build --release --manifest-path $cargo_toml`, build_env))
        println("  ✓ Cargo build completed successfully")
    catch e
        error("""
        Failed to build $what: $e

        Common issues:
        1. Rust toolchain not installed - install from https://rustup.rs/
        2. Cargo.toml has syntax errors
        3. Missing dependencies in Cargo.toml
        4. Insufficient permissions to write to $target_dir

        Try running manually:
            CARGO_TARGET_DIR=$target_dir cargo build --release --manifest-path $cargo_toml
        """)
    end

    path = joinpath(target_dir, "release", native_product_filename(kind))
    if !isfile(path)
        error("""
        Built product not found at expected path: $path

        The build may have succeeded but the file was not created.
        Check the cargo build output for errors.
        """)
    end
    println("  ✓ Built: $path ($(filesize(path)) bytes)")
    return path
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

    if native_is_installed_package()
        println("Installed package: build products go to a scratch space, ",
                "not into $(native_package_root()).")
    else
        println("Checkout at $(native_package_root()): build products stay in deps/.")
    end
    println()

    lib_path = build_native_product(:rust_helpers, "the Rust helpers library")
    println()
    build_native_product(:extractor, "the rustcall-extract CLI")
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
