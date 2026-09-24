# Windows Development

This page is for contributors running RustCall.jl from a Windows checkout. It
complements the [Windows Platform Guide](platforms/windows.md), which focuses
on installing and using the package.

## Run the test suite from a native Windows shell

Use PowerShell or the **Developer PowerShell for VS 2022**. The latter sets the
MSVC linker and Windows SDK variables needed by Cargo. WSL is a separate Linux
environment; binaries built there cannot be loaded by native Windows Julia.

From the repository root, rebuild the two native products before testing:

```powershell
julia --project deps/build.jl

$extractor = (Resolve-Path .\deps\rustcall_extract\target\release\rustcall-extract.exe).Path
$env:RUSTCALL_EXTRACT = $extractor
& $extractor schema-version       # must match the MAJOR.MINOR of Project.toml

julia --startup-file=no -e 'using Pkg; Pkg.activate("."); Pkg.test()'
```

The extractor is versioned with the manifest schema. For example, a checkout
whose `Project.toml` is `0.7.x` requires `schema-version` to print `0.7`. An
error such as

```text
manifest schema version mismatch: the rustcall-extract binary produced schema "0.6", but this RustCall.jl (v0.7.0) expects "0.7"
```

means that `RUSTCALL_EXTRACT` or the checkout's `deps/rustcall_extract/target`
contains an older binary. Re-run `deps/build.jl`, then verify the command above
before diagnosing the Julia tests themselves.

`Pkg.test()` may also warn that the project dependencies or compat requirements
changed since the manifest was resolved. That warning is separate from the
extractor error; when the project files intentionally changed, resolve the
environment and review the resulting `Manifest.toml` diff before committing it.

## MSVC linker and Windows SDK

RustToolChain.jl can provide Rust, but it does not provide the Windows linker.
The normal Windows target is MSVC, so install **Desktop development with C++**
from Visual Studio Build Tools, including an MSVC toolset and a Windows 10 or
11 SDK. A quick check from the shell used to run Julia is:

```powershell
where.exe rustc
where.exe cargo
where.exe cl.exe
where.exe link.exe
rustc --version
cargo --version
```

`rustc` and `cargo` being found is not sufficient if Cargo cannot invoke the
MSVC linker. Run Julia from Developer PowerShell when an ordinary PowerShell
reports `link.exe not found`, `Windows SDK not found`, or an MSVC link error.

## Application Control and locked build products

Cargo executes generated `build-script-build.exe` files under the Julia
scratchspace, and Julia loads precompiled package DLLs from
`%USERPROFILE%\.julia\compiled`. Some managed Windows installations block
either kind of file with an Application Control policy. The characteristic
diagnostics are:

```text
An Application Control policy has blocked this file. (os error 4551)
```

Documenter may show the same problem while loading a package such as
`Parsers`, for example:

```text
Error opening package file ...\.julia\compiled\v1.13\Parsers\...dll:
An Application Control policy has blocked this file.
```

This is an endpoint policy failure, not a Rust source failure. Ask the machine
administrator to allow the approved Julia/Cargo build locations, or run the
build in an approved development environment. Do not disable endpoint
protection as a general workaround.

Windows also keeps loaded DLLs and sometimes Cargo build outputs open. If a
build reports `LNK1104` for a generated `.exe`, stop leftover Julia/Cargo
processes, retry from a clean test session, and check antivirus or Application
Control logs. Keep the checkout and Cargo/Julia scratch paths short and local;
avoid building from a network share.

A Windows **Bad Image** dialog for a path under
`%USERPROFILE%\.julia\scratchspaces\<RustCall UUID>\cache-v2\cargo` is also
usually an environment or lifecycle problem when the file has a valid `MZ`/`PE`
header. Stop all test workers before clearing or rebuilding the cache: a DLL
that is still mapped cannot be replaced or deleted reliably on Windows. Then
rebuild the affected artifact in a fresh Julia process. If a fresh process can
load the same DLL but the test worker cannot, inspect Application Control and
antivirus logs and avoid reusing the worker or its stale cache.

## PyO3 tests and Python

The PyO3 test suite has two classes of cases:

- `:python_free` cases do not require a Python installation.
- `:link_libpython` cases require a real Python installation and a linkable
  `python3xy.lib` import library on Windows.

The `python.exe` alias under `WindowsApps` only opens the Microsoft Store; it
is not a usable interpreter. Check the interpreter explicitly:

```powershell
where.exe python
python --version
```

For the linkable cases, install Python with its development files and point
RustCall at the intended interpreter when necessary:

```powershell
$env:PYO3_PYTHON = "C:\Python312\python.exe"
$env:RUSTCALL_PYTHON_LIBDIR = "C:\Python312\libs"
```

If there is no linkable Python library, the link-libpython testsets should
report a visible skip. A Cargo failure in a `:python_free` case, or a failure
after a linkable library has been detected, should be investigated normally;
do not mask it by setting a skip variable.
