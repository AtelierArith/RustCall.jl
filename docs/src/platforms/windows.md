# Windows Platform Guide

This guide covers Windows-specific setup, configuration, and troubleshooting for RustCall.jl.

## Prerequisites

### Rust Toolchain (optional to install yourself)

RustCall depends on [RustToolChain.jl](https://github.com/AtelierArith/RustToolChain.jl),
which uses the `rustc`/`cargo` on `PATH` when there is one and otherwise
installs an isolated MSVC-target toolchain (`x86_64-pc-windows-msvc`) through
Julia's Artifacts system. A system Rust installation is therefore **optional**.
If you prefer one — for example to pin a toolchain or use it outside Julia:

1. **Download and run rustup-init.exe** from [rustup.rs](https://rustup.rs/)

2. **Choose installation options**:
   - Select "Proceed with installation (default)" for MSVC toolchain
   - Or customize if you need MinGW

3. **Verify installation**:
   ```powershell
   rustc --version
   cargo --version
   ```

A `rustc` on `PATH` takes precedence over the artifact toolchain.

### Visual Studio Build Tools (required for the MSVC target)

RustCall's default target on Windows is MSVC (`x86_64-pc-windows-msvc`;
`RustCall.get_default_target()`), and the artifact toolchain RustToolChain.jl
installs is MSVC-only. Linking for that target needs the MSVC build tools and
a Windows SDK whichever toolchain compiles — RustToolChain.jl does not provide
a linker. Only the MinGW route below avoids them, and it needs the explicit
configuration described there. The MSVC toolchain requires Visual Studio Build Tools:

1. Download [Visual Studio Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/)

2. In the installer, select:
   - "Desktop development with C++"
   - Windows 10/11 SDK
   - MSVC v143 (or latest) build tools

3. Alternatively, install via winget:
   ```powershell
   winget install Microsoft.VisualStudio.2022.BuildTools
   ```

### Julia Installation

1. Download Julia from [julialang.org](https://julialang.org/downloads/)
2. Use the Windows installer (.exe)
3. Ensure "Add Julia to PATH" is checked during installation

## PATH Configuration

### Automatic Configuration (Recommended)

Rustup automatically adds Cargo to your PATH. Verify:

```powershell
# Check Rust tools are accessible
where.exe rustc
where.exe cargo
```

### Manual PATH Configuration

If Rust tools are not found, add to PATH manually:

1. Open "Environment Variables" (search in Start menu)
2. Under "User variables", edit "Path"
3. Add: `%USERPROFILE%\.cargo\bin`

Or via PowerShell (requires restart):

```powershell
[Environment]::SetEnvironmentVariable(
    "Path",
    [Environment]::GetEnvironmentVariable("Path", "User") + ";$env:USERPROFILE\.cargo\bin",
    "User"
)
```

## Toolchain Selection

### MSVC Toolchain (Default, Recommended)

The MSVC (Microsoft Visual C++) toolchain is the default on Windows:

```powershell
# Check current toolchain
rustup show

# Ensure MSVC is default
rustup default stable-x86_64-pc-windows-msvc
```

**Advantages**:
- Native Windows ABI compatibility
- Better integration with Windows libraries
- Required for some Windows-specific crates

**Requirements**:
- Visual Studio Build Tools (or full Visual Studio)
- Windows SDK

### MinGW Toolchain (alternative, configuration-dependent)

MinGW uses GCC instead of MSVC. It is **not** what RustCall selects by itself
and **not** what the artifact toolchain provides, so it takes two explicit
steps — a system toolchain with the GNU target, and RustCall told to compile
for it:

```powershell
# Install a system toolchain with the GNU target (a rustup install on PATH
# takes precedence over the artifact toolchain)
rustup target add x86_64-pc-windows-gnu
```

```julia
using RustCall
RustCall.set_default_compiler(RustCall.RustCompiler(target_triple = "x86_64-pc-windows-gnu"))
```

Without the second step `rust"""` blocks are compiled for the default MSVC
target and need the MSVC build tools regardless of what `rustup` installed.
The MinGW route is not exercised by RustCall's CI (which runs the MSVC target).

**Advantages**:
- Smaller installation (no Visual Studio needed)
- Cross-compilation friendly

**Disadvantages**:
- Potential ABI incompatibility with some libraries
- Less common in Windows ecosystem, and not covered by RustCall's CI

### When to Use Which

| Scenario | Recommended Toolchain |
|----------|----------------------|
| General development | MSVC |
| Linking with Windows DLLs | MSVC |
| Minimal installation | MinGW |
| Cross-compiling from Linux | MinGW |
| CI/CD with limited resources | MinGW |

## Terminal Options

### PowerShell (Recommended)

PowerShell is the recommended terminal for RustCall.jl development:

```powershell
# Run Julia with debug logging
$env:JULIA_DEBUG = "RustCall"
julia --project
```

### Command Prompt (CMD)

Also works, but with different syntax:

```cmd
set JULIA_DEBUG=RustCall
julia --project
```

### Windows Terminal

Modern terminal with better features:
- Multiple tabs
- Better Unicode support
- Customizable

### WSL (Windows Subsystem for Linux)

WSL2 works well but is a separate Linux environment:

```bash
# In WSL2 - uses Linux toolchain, not Windows
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
julia --project
```

!!! warning "WSL vs Native Windows"
    WSL is a Linux environment. Libraries compiled in WSL won't work with native Windows Julia and vice versa. Choose one environment and stick with it.

## Common Issues and Solutions

### Error: "link.exe not found"

**Cause**: Visual Studio Build Tools not installed or not in PATH.

**Solution**:

1. Install Visual Studio Build Tools (see Prerequisites)

2. Or run from Developer Command Prompt:
   - Search "Developer Command Prompt for VS 2022"
   - Run Julia from there

3. Check Build Tools installation:
   ```powershell
   # Should show Visual Studio installation
   & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -products *
   ```

### Error: "Windows SDK not found"

**Cause**: Windows SDK component not installed.

**Solution**:

1. Run Visual Studio Installer
2. Modify your Build Tools installation
3. Ensure "Windows 10 SDK" or "Windows 11 SDK" is checked

### Error: DLL Loading Failures

**Symptoms**:
```
could not load library "..."
The specified module could not be found.
```

**Solutions**:

1. **Check DLL location**: Ensure the compiled library is in the expected path
   ```julia
   # Debug: Check library path
   using RustCall
   lib_path = joinpath(RustCall.CACHE_DIR, "...")
   @info "Library exists?" isfile(lib_path)
   ```

2. **Check dependencies**: Use `dumpbin` to verify dependencies
   ```powershell
   dumpbin /dependents path\to\library.dll
   ```

3. **Add to PATH**: If DLL depends on other DLLs
   ```powershell
   $env:PATH += ";C:\path\to\dlls"
   ```

### Error: Long Path Issues (> 260 characters)

**Cause**: Windows default path limit is 260 characters.

**Solutions**:

1. **Enable long paths** (Windows 10 1607+):
   ```powershell
   # Run as Administrator
   New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
       -Name "LongPathsEnabled" -Value 1 -PropertyType DWORD -Force
   ```

2. **Use shorter paths**: Move project closer to root
   ```powershell
   # Instead of: C:\Users\Username\Documents\Projects\MyProject\...
   # Use: C:\Dev\MyProject\...
   ```

3. **Configure Cargo home**:
   ```powershell
   $env:CARGO_HOME = "C:\cargo"
   ```

### Error: Unicode/Encoding Issues

**Symptoms**: Build errors with non-ASCII characters in paths or source files.

**Solutions**:

1. **Use ASCII-only paths**: Avoid Unicode characters in project paths

2. **Set console encoding**:
   ```powershell
   [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
   chcp 65001
   ```

3. **Configure Git for line endings**:
   ```powershell
   git config --global core.autocrlf true
   ```

### Error: Antivirus Interference

**Symptoms**: Random build failures, slow compilation, "access denied" errors.

**Solutions**:

1. **Add exclusions** for:
   - `%USERPROFILE%\.cargo`
   - `%USERPROFILE%\.julia`
   - Your project directory

2. **Windows Defender exclusions** (PowerShell as Admin):
   ```powershell
   Add-MpPreference -ExclusionPath "$env:USERPROFILE\.cargo"
   Add-MpPreference -ExclusionPath "$env:USERPROFILE\.julia"
   ```

## CI/CD Configuration

### GitHub Actions

RustCall.jl's CI already includes Windows testing:

```yaml
test:
  runs-on: ${{ matrix.os }}
  strategy:
    matrix:
      os: [windows-latest]
  steps:
    - uses: actions/checkout@v6
    - uses: julia-actions/setup-julia@v2
    - uses: julia-actions/julia-buildpkg@v1
    - uses: julia-actions/julia-runtest@v1
      with:
        test_args: '--jobs=2'
```

### Caching for Windows Builds

Add Rust caching to speed up Windows CI:

```yaml
- name: Cache Cargo
  uses: actions/cache@v4
  with:
    path: |
      ~/.cargo/bin/
      ~/.cargo/registry/index/
      ~/.cargo/registry/cache/
      ~/.cargo/git/db/
    key: ${{ runner.os }}-cargo-${{ hashFiles('**/Cargo.lock') }}

- name: Cache Julia artifacts
  uses: julia-actions/cache@v2
```

### Windows-Specific CI Tips

1. **Path separators**: Use `/` in YAML (works on Windows too)
2. **Shell selection**: GitHub Actions uses PowerShell by default on Windows
3. **Line endings**: Configure Git to handle CRLF/LF

## Best Practices

### 1. Use PowerShell

PowerShell provides better scripting and Unicode support than CMD.

### 2. Keep Paths Short

Windows path limits can cause issues. Keep project paths under 100 characters.

### 3. Regular Updates

Keep tools updated to avoid compatibility issues:

```powershell
rustup update
julia -e 'using Pkg; Pkg.update()'
```

### 4. Use Native Tools

Prefer native Windows tools over WSL for Windows-targeted development.

### 5. Configure Antivirus Exclusions

Add development directories to antivirus exclusions for better performance.

## Quick Reference

### Essential Commands

```powershell
# Check Rust installation
rustc --version
cargo --version

# Check toolchain
rustup show

# Update Rust
rustup update

# Clean Cargo cache
cargo clean

# Julia with debug logging
$env:JULIA_DEBUG = "RustCall"; julia --project
```

### Common Paths

| Path | Description |
|------|-------------|
| `%USERPROFILE%\.cargo` | Cargo home directory |
| `%USERPROFILE%\.julia` | Julia depot |
| `%USERPROFILE%\.rustup` | Rustup toolchains |
| `%LOCALAPPDATA%\Temp` | Temporary files |

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `CARGO_HOME` | Override Cargo directory |
| `RUSTUP_HOME` | Override Rustup directory |
| `JULIA_DEBUG` | Enable Julia debug logging |
| `RUST_BACKTRACE` | Enable Rust backtraces |

## See Also

- [Troubleshooting](../troubleshooting.md) - General troubleshooting guide
- [Getting Started](../tutorial.md) - Basic usage tutorial
- [Rust Windows Installation](https://rust-lang.github.io/rustup/installation/windows.html) - Official Rust documentation
