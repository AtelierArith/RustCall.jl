# Error handling for Rust FFI

"""
    RustError <: Exception

Exception type for Rust-related errors.

# Fields
- `message::String`: Error message
- `code::Int32`: Optional error code (default: 0)
"""
struct RustError <: Exception
    message::String
    code::Int32

    function RustError(message::String, code::Int32=Int32(0))
        new(message, code)
    end
end

"""
    CompilationError <: Exception

Exception type for Rust compilation errors.

# Fields
- `message::String`: Formatted error message
- `raw_stderr::String`: Raw stderr output from rustc
- `source_code::String`: The Rust source code that failed to compile
- `command::String`: The rustc command that was executed
- `file_path::String`: Source file path (if available)
- `line_number::Int`: Line number where error occurred (if available)
- `context::Dict{String, Any}`: Additional debugging context
"""
struct CompilationError <: Exception
    message::String
    raw_stderr::String
    source_code::String
    command::String
    file_path::String
    line_number::Int
    context::Dict{String, Any}

    function CompilationError(message::String, raw_stderr::String, source_code::String, command::String;
                              file_path::String="", line_number::Int=0, context::Dict{String, Any}=Dict{String, Any}())
        new(message, raw_stderr, source_code, command, file_path, line_number, context)
    end
end

"""
    RuntimeError <: Exception

Exception type for Rust runtime errors.

# Fields
- `message::String`: Error message
- `function_name::String`: Name of the function that failed
- `stack_trace::String`: Optional stack trace (default: "")
- `arguments::Vector{Any}`: Function arguments that caused the error
- `library_name::String`: Name of the library containing the function
- `context::Dict{String, Any}`: Additional debugging context
"""
struct RuntimeError <: Exception
    message::String
    function_name::String
    stack_trace::String
    arguments::Vector{Any}
    library_name::String
    context::Dict{String, Any}

    function RuntimeError(message::String, function_name::String, stack_trace::String="";
                          arguments::Vector{Any}=Any[], library_name::String="", context::Dict{String, Any}=Dict{String, Any}())
        new(message, function_name, stack_trace, arguments, library_name, context)
    end
end

# Phase 3: Cargo build and dependency errors

"""
    CargoBuildError <: Exception

Exception type for Cargo build failures.

# Fields
- `message::String`: Error message
- `stderr::String`: Raw stderr output from cargo
- `project_path::String`: Path to the Cargo project that failed to build
"""
struct CargoBuildError <: Exception
    message::String
    stderr::String
    project_path::String

    function CargoBuildError(message::String, stderr::String, project_path::String)
        new(message, stderr, project_path)
    end
end

"""
    DependencyResolutionError <: Exception

Exception type for dependency resolution failures.

# Fields
- `dependency::String`: Name of the problematic dependency
- `message::String`: Error message describing the resolution failure
"""
struct DependencyResolutionError <: Exception
    dependency::String
    message::String

    function DependencyResolutionError(dependency::String, message::String)
        new(dependency, message)
    end
end

"""
    Base.showerror(io::IO, e::RustError)

Display a RustError in a user-friendly format.
"""
function Base.showerror(io::IO, e::RustError)
    if e.code == 0
        print(io, "RustError: $(e.message)")
    else
        print(io, "RustError: $(e.message) (code: $(e.code))")
    end
end

"""
    Base.showerror(io::IO, e::CompilationError)

Display a CompilationError in a user-friendly format with formatted rustc output.
Enhanced with more context and debugging information.
"""
function Base.showerror(io::IO, e::CompilationError)
    println(io, "CompilationError: Failed to compile Rust code")
    println(io, "")

    # Show file and line information if available
    if !isempty(e.file_path)
        println(io, "File: $(e.file_path)")
        if e.line_number > 0
            println(io, "Line: $(e.line_number)")
        end
        println(io, "")
    end

    # Show command (can be helpful for debugging)
    if !isempty(e.command)
        println(io, "Command: $(e.command)")
        println(io, "")
    end

    # Format and display error output
    println(io, "Error output:")
    println(io, "─" ^ 80)
    formatted = format_rustc_error(e.raw_stderr)
    println(io, formatted)
    println(io, "─" ^ 80)
    println(io, "")

    # Show source code with line numbers for context
    println(io, "Source code:")
    println(io, "─" ^ 80)

    # Try to extract error line numbers from stderr
    error_lines = _extract_error_line_numbers_impl(e.raw_stderr)

    if !isempty(error_lines)
        # Show source with line numbers, highlighting error lines
        source_lines = split(e.source_code, '\n')
        max_line_num = length(source_lines)
        max_digits = length(string(max_line_num))

        for (line_num, line) in enumerate(source_lines)
            line_prefix = lpad(string(line_num), max_digits) * " | "
            if line_num in error_lines
                println(io, ">>> " * line_prefix * line)  # Highlight error lines
            else
                println(io, "    " * line_prefix * line)
            end

            # Limit output to reasonable size
            if line_num > 50 && line_num < max_line_num - 10
                if line_num == 51
                    println(io, "    " * " " ^ max_digits * " | ... ($(max_line_num - 60) lines omitted) ...")
                end
                continue
            end
        end
    else
        # Fallback: show first 500 chars
        source_preview = length(e.source_code) > 500 ? e.source_code[1:500] * "..." : e.source_code
        println(io, source_preview)
    end

    println(io, "─" ^ 80)

    # Show suggestions if available
    suggestions = _extract_suggestions_impl(e.raw_stderr)
    auto_suggestions = suggest_fix_for_error(e.raw_stderr, e.source_code)

    all_suggestions = unique(vcat(suggestions, auto_suggestions))
    if !isempty(all_suggestions)
        println(io, "")
        println(io, "Suggestions:")
        for (i, suggestion) in enumerate(all_suggestions)
            println(io, "  $i. $suggestion")
        end
    end

    # Show additional context if available
    if !isempty(e.context)
        println(io, "")
        println(io, "Debug Information:")
        println(io, "─" ^ 80)
        for (key, value) in e.context
            println(io, "  $key: $value")
        end
        println(io, "─" ^ 80)
    end

    # Show hint for enabling debug mode
    println(io, "")
    println(io, "💡 Tip: Set JULIA_DEBUG=RustCall or enable debug mode for more detailed information.")
end

# Export internal functions for testing (wrappers)
function _extract_error_line_numbers(stderr::String)
    return _extract_error_line_numbers_impl(stderr)
end

function _extract_suggestions(stderr::String)
    return _extract_suggestions_impl(stderr)
end


"""
    _extract_error_line_numbers_impl(stderr::String) -> Vector{Int}

Extract line numbers from rustc error output.
"""
function _extract_error_line_numbers_impl(stderr::String)
    line_numbers = Int[]
    # Pattern: --> file.rs:42:5 or file.rs:42:5
    line_pattern = r":(\d+):\d+"

    for m in eachmatch(line_pattern, stderr)
        line_num = parse(Int, m.captures[1])
        push!(line_numbers, line_num)
    end

    return unique(sort(line_numbers))
end

"""
    _extract_suggestions_impl(stderr::String) -> Vector{String}

Extract helpful suggestions from rustc error output.
"""
function _extract_suggestions_impl(stderr::String)
    suggestions = String[]
    lines = split(stderr, '\n')

    i = 1
    while i <= length(lines)
        line = lines[i]

        # Look for help: messages
        if startswith(lowercase(strip(line)), "help:")
            suggestion = strip(replace(line, r"^help:\s*"i => ""))
            if !isempty(suggestion)
                push!(suggestions, suggestion)
            end
        end

        # Look for common error patterns and provide suggestions
        if occursin(r"expected.*found", lowercase(line))
            if occursin("semicolon", lowercase(line))
                push!(suggestions, "Missing semicolon. Add `;` at the end of the statement.")
            elseif occursin("brace", lowercase(line))
                push!(suggestions, "Mismatched braces. Check that all `{` have matching `}`.")
            elseif occursin("parenthesis", lowercase(line))
                push!(suggestions, "Mismatched parentheses. Check that all `(` have matching `)`.")
            end
        end

        i += 1
    end

    return unique(suggestions)
end

"""
    Base.showerror(io::IO, e::RuntimeError)

Display a RuntimeError in a user-friendly format with enhanced stack trace.
Enhanced with argument information and debugging context.
"""
function Base.showerror(io::IO, e::RuntimeError)
    println(io, "RuntimeError in function '$(e.function_name)': $(e.message)")

    # Show library name if available
    if !isempty(e.library_name)
        println(io, "Library: $(e.library_name)")
    end

    # Show function arguments if available
    if !isempty(e.arguments)
        println(io, "")
        println(io, "Function arguments:")
        println(io, "─" ^ 40)
        for (i, arg) in enumerate(e.arguments)
            arg_str = try
                string(arg)
            catch
                "<unprintable>"
            end
            # Truncate long arguments
            if length(arg_str) > 100
                arg_str = arg_str[1:97] * "..."
            end
            println(io, "  arg[$i]: $arg_str ($(typeof(arg)))")
        end
        println(io, "─" ^ 40)
    end

    if !isempty(e.stack_trace)
        println(io, "")
        println(io, "Stack trace:")
        println(io, "─" ^ 80)

        # Format stack trace for better readability
        stack_lines = split(e.stack_trace, '\n')
        for line in stack_lines
            # Highlight important parts
            if occursin("at ", line) || occursin("in ", line)
                println(io, "  " * line)
            else
                println(io, line)
            end
        end

        println(io, "─" ^ 80)
    end

    # Show additional context if available
    if !isempty(e.context)
        println(io, "")
        println(io, "Debug Information:")
        println(io, "─" ^ 80)
        for (key, value) in e.context
            value_str = try
                string(value)
            catch
                "<unprintable>"
            end
            # Truncate long values
            if length(value_str) > 200
                value_str = value_str[1:197] * "..."
            end
            println(io, "  $key: $value_str")
        end
        println(io, "─" ^ 80)
    end

    if isempty(e.stack_trace) && isempty(e.context)
        println(io, "")
        println(io, "💡 Tip: Enable debug mode for more detailed error information.")
    end
end

"""
    Base.showerror(io::IO, e::CargoBuildError)

Display a CargoBuildError in a user-friendly format.
"""
function Base.showerror(io::IO, e::CargoBuildError)
    println(io, "CargoBuildError: $(e.message)")
    println(io, "")
    println(io, "Project: $(e.project_path)")

    if !isempty(e.stderr)
        println(io, "")
        println(io, "Cargo output:")
        println(io, "─" ^ 80)
        # Reuse format_rustc_error since Cargo output is similar
        formatted = format_rustc_error(e.stderr)
        println(io, formatted)
        println(io, "─" ^ 80)
    end
end

"""
    Base.showerror(io::IO, e::DependencyResolutionError)

Display a DependencyResolutionError in a user-friendly format.
"""
function Base.showerror(io::IO, e::DependencyResolutionError)
    println(io, "DependencyResolutionError: $(e.dependency)")
    println(io, "")
    println(io, e.message)
end


"""
    format_rustc_error(stderr::String) -> String

Format rustc error output to be more readable.
Removes redundant information and highlights important parts.

# Improvements
- Better error line highlighting
- Context-aware formatting
- Suggestion extraction
"""
function format_rustc_error(stderr::String)
    lines = split(stderr, '\n')
    formatted_lines = String[]

    i = 1
    error_count = 0
    warning_count = 0

    while i <= length(lines)
        line = lines[i]

        # Skip empty lines at the beginning
        if isempty(strip(line)) && isempty(formatted_lines)
            i += 1
            continue
        end

        # Highlight error messages (lines starting with "error:")
        if startswith(lowercase(strip(line)), "error:")
            error_count += 1
            push!(formatted_lines, "❌ " * line)
            i += 1
            # Include the next few lines that might be part of the error message
            while i <= length(lines) && (startswith(lines[i], "  ") || isempty(strip(lines[i])))
                push!(formatted_lines, "   " * lines[i])
                i += 1
            end
            continue
        end

        # Highlight warning messages
        if startswith(lowercase(strip(line)), "warning:")
            warning_count += 1
            push!(formatted_lines, "⚠️  " * line)
            i += 1
            continue
        end

        # Highlight help messages with better formatting
        if startswith(lowercase(strip(line)), "help:")
            push!(formatted_lines, "💡 " * line)
            i += 1
            # Include help message continuation
            while i <= length(lines) && (startswith(lines[i], "  ") || isempty(strip(lines[i])))
                push!(formatted_lines, "   " * lines[i])
                i += 1
            end
            continue
        end

        # Include file location lines (lines with --> or ^) with better formatting
        if occursin("-->", line)
            # Extract line number if possible
            push!(formatted_lines, "   " * line)
            i += 1
            # Include code context lines (lines with |)
            while i <= length(lines) && (occursin("|", lines[i]) || occursin("^", lines[i]) ||
                                         startswith(strip(lines[i]), "=") ||
                                         (startswith(lines[i], " ") && !isempty(strip(lines[i]))))
                push!(formatted_lines, "   " * lines[i])
                i += 1
            end
            continue
        end

        # Highlight error location markers (^)
        if occursin("^", line)
            push!(formatted_lines, "   " * line)
            i += 1
            continue
        end

        # Include note messages
        if startswith(lowercase(strip(line)), "note:")
            push!(formatted_lines, "ℹ️  " * line)
            i += 1
            # Include note continuation
            while i <= length(lines) && (startswith(lines[i], "  ") || isempty(strip(lines[i])))
                push!(formatted_lines, "   " * lines[i])
                i += 1
            end
            continue
        end

        # Skip verbose compiler output
        if occursin("Compiling", line) || occursin("Finished", line) || occursin("Running", line) ||
           occursin("Checking", line) || occursin("Documenting", line)
            i += 1
            continue
        end

        # Include other lines (might be important)
        push!(formatted_lines, line)
        i += 1
    end

    # Add summary if multiple errors/warnings
    if error_count > 1 || warning_count > 0
        summary = String[]
        if error_count > 1
            push!(summary, "$error_count errors found")
        end
        if warning_count > 0
            push!(summary, "$warning_count warnings")
        end
        if !isempty(summary)
            push!(formatted_lines, "")
            push!(formatted_lines, "Summary: " * join(summary, ", "))
        end
    end

    return join(formatted_lines, '\n')
end

"""
    suggest_fix_for_error(stderr::String, source_code::String) -> Vector{String}

Analyze compilation error and suggest potential fixes.

# Returns
- Vector of suggested fixes (strings)
"""
function suggest_fix_for_error(stderr::String, source_code::String)
    suggestions = String[]

    stderr_lower = lowercase(stderr)
    source_lower = lowercase(source_code)

    # Common error patterns and fixes
    if occursin("expected `;`, found", stderr_lower)
        push!(suggestions, "Missing semicolon. Add `;` at the end of the statement.")
    end

    if occursin("expected `}`, found", stderr_lower) || occursin("unclosed delimiter", stderr_lower)
        push!(suggestions, "Mismatched braces. Check that all opening `{` have matching closing `}`.")
        # Count braces
        open_braces = count(c -> c == '{', source_code)
        close_braces = count(c -> c == '}', source_code)
        if open_braces > close_braces
            push!(suggestions, "Found $(open_braces - close_braces) more opening brace(s) than closing brace(s).")
        elseif close_braces > open_braces
            push!(suggestions, "Found $(close_braces - open_braces) more closing brace(s) than opening brace(s).")
        end
    end

    if occursin("expected `)`, found", stderr_lower)
        push!(suggestions, "Mismatched parentheses. Check that all opening `(` have matching closing `)`.")
    end

    if occursin("cannot find", stderr_lower) && occursin("in this scope", stderr_lower)
        push!(suggestions, "Undefined variable or function. Check spelling and ensure it's defined before use.")
    end

    if occursin("mismatched types", stderr_lower)
        push!(suggestions, "Type mismatch. Check that argument types match the function signature.")
    end

    if occursin("expected one of", stderr_lower)
        push!(suggestions, "Syntax error. Check the Rust syntax for the construct you're using.")
    end

    if occursin("unused variable", stderr_lower)
        push!(suggestions, "Unused variable. Either use it or prefix with `_` to indicate it's intentionally unused.")
    end

    if occursin("cannot borrow", stderr_lower)
        push!(suggestions, "Borrow checker error. This is a Rust ownership issue. Consider using references or cloning.")
    end

    # Check for common FFI issues
    if occursin("extern", source_lower) && !occursin("#[no_mangle]", source_lower)
        push!(suggestions, "Missing `#[no_mangle]` attribute. Add it before `pub extern \"C\"` for FFI functions.")
    end

    if occursin("pub extern \"c\"", source_lower) && !occursin("pub extern \"C\"", source_code)
        push!(suggestions, "Use `extern \"C\"` (capital C) for C-compatible FFI functions.")
    end

    return unique(suggestions)
end

"""
    result_to_exception(result::RustResult{T, E}) where {T, E}

Convert a RustResult to either return the Ok value or throw a RustError.

# Arguments
- `result::RustResult{T, E}`: The Rust result to convert

# Returns
- The Ok value of type `T` if the result is Ok

# Throws
- `RustError` if the result is Err

# Example
```julia
result = RustResult{Int32, String}(false, "division by zero")
try
    value = result_to_exception(result)
catch e
    @assert e isa RustError
    println(e.message)  # => "division by zero"
end
```
"""
function result_to_exception(result::RustResult{T, E}) where {T, E}
    if result.is_ok
        return result.value::T
    else
        error_value = result.value::E
        error_msg = string(error_value)
        throw(RustError(error_msg, Int32(0)))
    end
end

"""
    result_to_exception(result::RustResult{T, E}, code::Int32) where {T, E}

Convert a RustResult to either return the Ok value or throw a RustError with a specific error code.

# Arguments
- `result::RustResult{T, E}`: The Rust result to convert
- `code::Int32`: Error code to use if the result is Err

# Returns
- The Ok value of type `T` if the result is Ok

# Throws
- `RustError` with the specified code if the result is Err
"""
function result_to_exception(result::RustResult{T, E}, code::Int32) where {T, E}
    if result.is_ok
        return result.value::T
    else
        error_value = result.value::E
        error_msg = string(error_value)
        throw(RustError(error_msg, code))
    end
end

"""
    unwrap_or_throw(result::RustResult{T, E}) where {T, E}

Alias for `result_to_exception` that throws a RustError on Err.

This is a convenience function that provides a more Rust-like naming convention.
"""
unwrap_or_throw(result::RustResult{T, E}) where {T, E} = result_to_exception(result)

"""
    unwrap_or_throw(result::RustResult{T, E}, code::Int32) where {T, E}

Alias for `result_to_exception` with error code.
"""
unwrap_or_throw(result::RustResult{T, E}, code::Int32) where {T, E} = result_to_exception(result, code)
