"""
    MyExample.jl

An example Julia package demonstrating how to use LastCall.jl to call Rust code from Julia.

This package includes several examples:
- Basic numerical computations
- String processing
- Array operations
"""
module MyExample

using LastCall

# Export example functions
export add_numbers, multiply_numbers, fibonacci
export count_words, reverse_string
export sum_array, max_in_array

# ============================================================================
# Example 1: Basic Numerical Computations
# ============================================================================

rust"""
#[julia]
fn add_numbers(a: i32, b: i32) -> i32 {
    a + b
}

#[julia]
fn multiply_numbers(a: f64, b: f64) -> f64 {
    a * b
}

#[julia]
fn fibonacci(n: u32) -> u64 {
    if n <= 1 {
        return n as u64;
    }

    let mut a = 0u64;
    let mut b = 1u64;

    for _ in 2..=n {
        let temp = a + b;
        a = b;
        b = temp;
    }

    b
}
"""

"""
    add_numbers(a::Int32, b::Int32) -> Int32

Add two integers using Rust.
"""
function add_numbers(a::Int32, b::Int32)::Int32
    return @rust add_numbers(a, b)::Int32
end

"""
    multiply_numbers(a::Float64, b::Float64) -> Float64

Multiply two floating-point numbers using Rust.
"""
function multiply_numbers(a::Float64, b::Float64)::Float64
    return @rust multiply_numbers(a, b)::Float64
end

"""
    fibonacci(n::UInt32) -> UInt64

Calculate the n-th Fibonacci number using Rust.
"""
function fibonacci(n::UInt32)::UInt64
    return @rust fibonacci(n)::UInt64
end

# ============================================================================
# Example 2: String Processing
# ============================================================================

rust"""
#[julia]
fn count_words(text: *const u8) -> u32 {
    let text_str = unsafe {
        std::ffi::CStr::from_ptr(text as *const i8)
            .to_str()
            .unwrap_or("")
    };
    text_str.split_whitespace().count() as u32
}

#[julia]
fn reverse_string(input: *const u8, output: *mut u8, len: usize) {
    let input_str = unsafe {
        std::ffi::CStr::from_ptr(input as *const i8)
            .to_str()
            .unwrap_or("")
    };
    let reversed: String = input_str.chars().rev().collect();
    let reversed_bytes = reversed.as_bytes();

    let output_slice = unsafe { std::slice::from_raw_parts_mut(output, len) };
    let copy_len = reversed_bytes.len().min(len);
    output_slice[..copy_len].copy_from_slice(&reversed_bytes[..copy_len]);
    if copy_len < len {
        output_slice[copy_len] = 0;  // Null terminator
    }
}
"""

"""
    count_words(text::String) -> UInt32

Count the number of words in a string using Rust.
"""
function count_words(text::String)::UInt32
    return @rust count_words(text)::UInt32
end

"""
    reverse_string(text::String) -> String

Reverse a string using Rust.
"""
function reverse_string(text::String)::String
    input_len = length(text)
    output_len = input_len + 1  # +1 for null terminator
    output = Vector{UInt8}(undef, output_len)

    input_ptr = pointer(text)
    output_ptr = pointer(output)

    @rust reverse_string(input_ptr, output_ptr, output_len)::Cvoid

    # Convert back to Julia string
    return unsafe_string(pointer(output))
end

# ============================================================================
# Example 3: Array Operations
# ============================================================================

rust"""
#[julia]
fn sum_array(data: *const i32, len: usize) -> i64 {
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    slice.iter().map(|&x| x as i64).sum()
}

#[julia]
fn max_in_array(data: *const i32, len: usize) -> i32 {
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    *slice.iter().max().unwrap_or(&0)
}
"""

"""
    sum_array(arr::Vector{Int32}) -> Int64

Sum all elements in an array using Rust.
"""
function sum_array(arr::Vector{Int32})::Int64
    if isempty(arr)
        return Int64(0)
    end

    ptr = pointer(arr)
    len = length(arr)

    # Use GC.@preserve to ensure arr stays valid during the call
    return GC.@preserve arr @rust sum_array(ptr, len)::Int64
end

"""
    max_in_array(arr::Vector{Int32}) -> Int32

Find the maximum element in an array using Rust.
"""
function max_in_array(arr::Vector{Int32})::Int32
    if isempty(arr)
        return Int32(0)
    end

    ptr = pointer(arr)
    len = length(arr)

    return GC.@preserve arr @rust max_in_array(ptr, len)::Int32
end

end # module MyExample
