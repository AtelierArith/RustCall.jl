# Error Handling in LastCall.jl

LastCall.jl provides comprehensive error handling with detailed error messages, debugging support, and automatic suggestions.

## Overview

The error handling system includes:
- **Enhanced compilation error display** with line numbers and context
- **Automatic error suggestions** for common issues
- **Debug mode** for detailed logging and intermediate file preservation
- **Improved runtime error messages** with stack traces

## Compilation Errors

### CompilationError

When Rust code fails to compile, a `CompilationError` is thrown with:

- **Formatted rustc output**: Clean, readable error messages with emoji indicators
- **Source code with line numbers**: Shows the problematic code with error lines highlighted
- **Automatic suggestions**: Common fixes for typical errors
- **Command information**: The exact rustc command that was executed

### Example

```julia
using LastCall

try
    rust"""
    #[no_mangle]
    pub extern "C" fn test() -> i32 {
        let x = 42  // Missing semicolon
    }
    """
catch e
    if e isa CompilationError
        println("Compilation failed!")
        println("Error: ", e.message)
        # Error output is automatically formatted
        # Suggestions are automatically extracted
    end
end
```

### Error Formatting

The `format_rustc_error` function processes rustc output to:
- Highlight errors with ❌
- Highlight warnings with ⚠️
- Highlight help messages with 💡
- Show code context with line numbers
- Remove verbose compiler output
- Provide error summaries for multiple errors

## Runtime Errors

### RuntimeError

When a Rust function fails at runtime, a `RuntimeError` is thrown with:

- **Function name**: Which function failed
- **Error message**: What went wrong
- **Stack trace**: Where the error occurred (if available)

### Example

```julia
using LastCall

rust"""
#[no_mangle]
pub extern "C" fn divide(a: i32, b: i32) -> i32 {
    a / b  // Will panic if b == 0
}
"""

try
    @rust divide(10, 0)
catch e
    if e isa RuntimeError
        println("Runtime error in function: ", e.function_name)
        println("Message: ", e.message)
        if !isempty(e.stack_trace)
            println("Stack trace: ", e.stack_trace)
        end
    end
end
```

## Debug Mode

Enable debug mode to get detailed information about compilation:

```julia
using LastCall

# Create compiler with debug mode
compiler = RustCompiler(debug_mode=true, debug_dir="/tmp/lastcall_debug")

# Compile with debug mode
rust"""
#[no_mangle]
pub extern "C" fn test() -> i32 { 42 }
""" compiler=compiler

# Debug mode provides:
# - Detailed logging (@info messages)
# - Intermediate files preserved (Rust source, LLVM IR, etc.)
# - File locations for inspection
# - Optimization level information
```

### Debug Mode Features

- **Intermediate file preservation**: All temporary files are kept for inspection
- **Detailed logging**: Information about compilation steps
- **File locations**: Paths to source files, LLVM IR, and compiled libraries
- **Compiler settings**: Optimization level, debug info, etc.

## Automatic Error Suggestions

The `suggest_fix_for_error` function analyzes errors and provides suggestions:

### Supported Error Patterns

1. **Missing semicolon**: Suggests adding `;`
2. **Mismatched braces**: Counts and reports brace mismatches
3. **Mismatched parentheses**: Suggests checking parentheses
4. **Undefined variables**: Suggests checking spelling
5. **Type mismatches**: Suggests checking argument types
6. **Missing `#[no_mangle]`**: Suggests adding the attribute for FFI functions
7. **Wrong `extern "C"` syntax**: Suggests using capital `C`

### Example

```julia
using LastCall

code = """
pub extern "C" fn test() -> i32 { 42 }
"""

try
    compile_rust_to_shared_lib(code)
catch e
    if e isa CompilationError
        suggestions = suggest_fix_for_error(e.raw_stderr, e.source_code)
        for suggestion in suggestions
            println("💡 ", suggestion)
        end
    end
end
```

## Error Line Number Extraction

The `_extract_error_line_numbers` function extracts line numbers from rustc error output:

```julia
stderr = """
error: expected `;`, found `}`
  --> test.rs:2:5
"""

line_numbers = _extract_error_line_numbers(stderr)
# Returns: [2]
```

This is used to highlight error lines in the source code display.

## Error Message Formatting

### format_rustc_error

Formats rustc stderr output for better readability:

- Removes verbose compiler output
- Highlights important messages (errors, warnings, help)
- Preserves code context (file locations, line numbers)
- Provides summaries for multiple errors/warnings

### Example Output

```
❌ error: expected `;`, found `}`
   --> test.rs:2:5
    |
 1 | fn test() {
 2 | }
    |  ^ expected `;`

💡 help: add `;` here

Summary: 1 errors found
```

## Best Practices

1. **Enable debug mode** when developing new Rust code
2. **Read suggestions** - they often point to the exact fix needed
3. **Check line numbers** - the highlighted lines show where errors occur
4. **Use try-catch** - handle errors gracefully in production code

## API Reference

### Functions

- `format_rustc_error(stderr::String)` - Format rustc error output
- `suggest_fix_for_error(stderr::String, source_code::String)` - Get error suggestions
- `_extract_error_line_numbers(stderr::String)` - Extract error line numbers (for testing)
- `_extract_suggestions(stderr::String)` - Extract help messages (for testing)

### Exception Types

- `CompilationError` - Rust compilation failures
- `RuntimeError` - Rust runtime failures
- `RustError` - General Rust-related errors

## See Also

- `docs/TUTORIAL.md` - General tutorial
- `docs/EXAMPLES.md` - Code examples
- `docs/troubleshooting.md` - Troubleshooting guide
- `test/test_error_handling.jl` - Test suite with examples
