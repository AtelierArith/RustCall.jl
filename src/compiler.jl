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
        fingerprint = artifact_short_id(stable_content_hash(code), RECOVERY_FINGERPRINT_LEN)
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
    RustTypeProbe

The answer of `probe_rust_expression_type`: the Rust type of an expression as
**rustc** named it, and rustc's own rendered diagnostics.

`rust_type` is `nothing` when the probe could not name one type for the whole
snippet. `conflict` says which of the two reasons it was: empty means the
snippet does not type-check for a reason of its own and `rendered` is the
diagnosis; non-empty lists the types the snippet's several return sites
required, which no single `extern "C"` signature can satisfy.
"""
struct RustTypeProbe
    rust_type::Union{Nothing, String}
    rendered::String
    conflict::Vector{String}

    RustTypeProbe(rust_type, rendered, conflict = String[]) =
        new(rust_type === nothing ? nothing : String(rust_type), String(rendered),
            String[String(c) for c in conflict])
end

"""
    probe_rust_expression_type(snippet, params; compiler) -> RustTypeProbe

Ask rustc what type a Rust snippet evaluates to.

The snippet is compiled — metadata only, no codegen and no linking — as the
body of a function declared to return `()`:

```rust
fn __rustcall_irust_probe(arg1: i64) {
    <snippet>
}
```

so rustc reports the snippet's own type against `()` as `E0308`, with the
primary span labelled ``expected `()`, found `i64` ``. If it compiles cleanly,
the snippet's value really is `()`.

Reading the type out of the compiler instead of guessing it from the source is
the whole point (#348): the guess it replaces called anything containing `->`,
`=>` or a comparison a `bool`, which is most of the ways to write more than one
line of Rust. The diagnostics are read as **data** — `rustc --error-format=json`
objects, through `rustc_diagnostics` — never as rendered text; the `rendered`
field is kept only to show the user.

Two labels name no concrete type: an unconstrained integer literal is reported
as `integer` and an unconstrained float literal as `floating-point number`.
Those are inference variables that unify with any integer / float type, so they
are answered with `i64` and `f64` — Julia's `Int` and `Float64`, and `f64` is
Rust's own default as well.

**Every** return site is read, not the first. A snippet with more than one —
`if flag { return 0; } x` — produces one diagnostic per site, and the probe's
`()` return type keeps them from unifying with each other the way they would in
the real function: the literal `0` reads as `integer` while `x` reads as its own
type. Taking the first would have generated `-> i64` for an `i32` snippet and
failed the build it was meant to make possible (Codex review of PR #354). The
sites are reconciled instead, by `_reconcile_probe_types`.

The probe is compiled with `_cfg_rustc_flags(compiler)` — the same target,
opt-level and panic flags the real build uses — because those decide `#[cfg]`
predicates: `debug_assertions` is on at opt-level 0 and off above it, so a probe
without them can see a different snippet from the one that gets built.

A probe that fails for any *other* reason (a syntax error, an unknown method, a
genuine type error) yields `rust_type === nothing` with an empty `conflict`: the
caller raises and shows `rendered`, because that output is the diagnosis.

The answer is a *lower bound*, and `confirm_rust_return_type` is what turns it
into a decision. A path that already produces `()` raises no diagnostic at all —
it matches the probe's declared return type — so `if flag { return 1i64; }`
reports `i64` and says nothing about the fallthrough that is unit (Codex review
of PR #354). No reading of these diagnostics can recover a constraint rustc
never emitted; asking rustc a second question can.
"""
function probe_rust_expression_type(snippet::AbstractString, params::AbstractString;
                                    compiler::RustCompiler = get_default_compiler())
    ok, diagnostics, text = _run_type_probe(snippet, params, ""; compiler)
    rendered = _rendered_errors(diagnostics)
    # A clean probe means the body really does evaluate to `()`.
    ok && return RustTypeProbe("()", rendered)

    # Only diagnostics with a span are real; "aborting due to N previous
    # errors" is an error-level summary with none.
    errors = [d for d in diagnostics
              if diagnostic_level(d) == "error" && !isempty(diagnostic_spans(d))]
    isempty(errors) && return RustTypeProbe(nothing, isempty(rendered) ? text : rendered)

    constraints = Union{String, Symbol}[]
    for d in errors
        c = _probe_constraint_from_diagnostic(d)
        c === nothing && return RustTypeProbe(nothing, rendered)  # a real error
        push!(constraints, c)
    end
    resolved = _reconcile_probe_types(constraints)
    resolved === nothing &&
        return RustTypeProbe(nothing, rendered, _probe_constraint_names(constraints))
    return RustTypeProbe(resolved, rendered)
end

"""
    confirm_rust_return_type(snippet, params, rust_type; compiler) -> String

`""` when the snippet type-checks as the body of a function returning
`rust_type`; otherwise rustc's rendered diagnostics for **that** question.

The second half of the type probe. `probe_rust_expression_type` learns the type
from the mismatches a `()`-returning function reports, and a path that already
produces `()` reports nothing — so `if flag { return 1i64; }` comes back as
`i64` with no hint that the fallthrough is unit. Declaring the answer and
type-checking again is the only way to see that, and it costs one more
`--emit=metadata` run on a snippet that is about to be compiled anyway.

The payoff is the message as much as the check: a failure here is rustc talking
about **the user's snippet** ("expected `i64`, found `()`"), where the same
failure discovered during the real build talks about generated source the user
never wrote.
"""
function confirm_rust_return_type(snippet::AbstractString, params::AbstractString,
                                  rust_type::AbstractString;
                                  compiler::RustCompiler = get_default_compiler())
    ok, diagnostics, text = _run_type_probe(snippet, params, rust_type; compiler)
    ok && return ""
    rendered = _rendered_errors(diagnostics)
    return isempty(rendered) ? text : rendered
end

# One rustc type-check of `snippet` as the body of `__rustcall_irust_probe`,
# declared to return `rust_type` (`""` meaning `()`), with the flags that decide
# `#[cfg]`. Metadata only: no codegen, no linking.
function _run_type_probe(snippet::AbstractString, params::AbstractString,
                         rust_type::AbstractString;
                         compiler::RustCompiler = get_default_compiler())
    return mktempdir() do dir
        src = joinpath(dir, "probe.rs")
        out = joinpath(dir, "probe.rmeta")
        ret = isempty(rust_type) ? "" : " -> $(rust_type)"
        write(src, string("#![allow(unused)]\nfn __rustcall_irust_probe(", params, ")",
                          ret, " {\n", snippet, "\n}\n"))
        cmd_args = [
            string(rustc().exec[1]),
            "--crate-type=lib",
            "--emit=metadata",
            "--error-format=json",
            # The flags that decide `#[cfg]`: the probe must see the same
            # snippet the build will (`_cfg_rustc_flags`, src/manifest.jl).
            _cfg_rustc_flags(compiler)...,
            "-o", out,
            src,
        ]
        stderr_io = IOBuffer()
        ok = try
            proc = run(pipeline(Cmd(cmd_args), stderr = stderr_io), wait = false)
            wait(proc)
            Base.success(proc)
        catch e
            @debug "The @irust type probe could not run rustc" exception = e
            false
        end
        text = String(take!(stderr_io))
        return (ok, rustc_diagnostics(text), text)
    end
end

# The prefix rustc's E0308 label carries when the mismatch is the probe's own
# `()` return type. Matched with plain string operations on a *diagnostic*
# (`scripts/lint_rust_syntax_regex.sh` is about Rust source, which this is not;
# and it is a field of a JSON object, not rendered text).
const _PROBE_LABEL_PREFIX = "expected `()`, found "

# The two labels that name an inference variable rather than a type, and the
# spellings each of them unifies with.
const _PROBE_INTEGER_TYPES = Set(["i8", "i16", "i32", "i64", "i128", "isize",
                                  "u8", "u16", "u32", "u64", "u128", "usize"])
const _PROBE_FLOAT_TYPES = Set(["f32", "f64"])

"""
    _probe_constraint_from_diagnostic(d) -> Union{String, Symbol, Nothing}

What one return site of the probe requires: the Rust type it names, or
`:integer` / `:float` when rustc reported an unconstrained literal, or `nothing`
when the diagnostic is not the probe's own `()` mismatch at all — in which case
the snippet has a real problem and the caller shows rustc's message.
"""
function _probe_constraint_from_diagnostic(d::AbstractDict)
    diagnostic_code(d) == "E0308" || return nothing
    label = primary_span_label(d)
    startswith(label, _PROBE_LABEL_PREFIX) || return nothing
    rest = strip(SubString(label, ncodeunits(_PROBE_LABEL_PREFIX) + 1))
    rest == "integer" && return :integer
    rest == "floating-point number" && return :float
    (length(rest) > 2 && startswith(rest, '`') && endswith(rest, '`')) &&
        return String(chop(rest; head = 1, tail = 1))
    return nothing
end

"""
    _reconcile_probe_types(constraints) -> Union{String, Nothing}

The one Rust type that satisfies every return site of a probe, or `nothing`
when no single type does.

A concrete type wins over an inference variable, because the variable is a
literal that will unify with it once the real function declares a return type:
`if flag { return 0; } x` with an `i32` `x` is `i32`, not `i64`. Two *different*
concrete types, or an integer variable against a float type (and vice versa),
cannot be reconciled — an `extern "C"` function has one return type, so the
caller refuses rather than picking one and failing the build.

With nothing but variables, Julia's own defaults answer: `i64` for an integer,
`f64` as soon as any site is a float.
"""
function _reconcile_probe_types(constraints)
    concrete = unique(String[c for c in constraints if c isa String])
    length(concrete) > 1 && return nothing
    wants(kind) = any(c -> c === kind, constraints)
    if length(concrete) == 1
        t = only(concrete)
        wants(:integer) && !(t in _PROBE_INTEGER_TYPES) && return nothing
        wants(:float) && !(t in _PROBE_FLOAT_TYPES) && return nothing
        return t
    end
    wants(:integer) && wants(:float) && return nothing
    wants(:float) && return "f64"
    wants(:integer) && return "i64"
    return nothing
end

# The constraints as a user would read them, for the "return sites disagree"
# message. `:integer` / `:float` are rustc's own words for the two variables.
_probe_constraint_names(constraints) =
    unique(String[c isa String ? c :
                  c === :integer ? "an unconstrained integer literal" :
                  "an unconstrained floating-point literal"
                  for c in constraints])

# rustc's own rendering of the error-level diagnostics, for a message a human
# reads. Never parsed.
function _rendered_errors(diagnostics)
    parts = String[]
    for d in diagnostics
        diagnostic_level(d) == "error" || continue
        rendered = get(d, "rendered", "")
        rendered isa String && !isempty(rendered) && push!(parts, rendered)
    end
    return join(parts)
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
        code_fingerprint = artifact_short_id(stable_content_hash(wrapped_code), RECOVERY_FINGERPRINT_LEN)
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
