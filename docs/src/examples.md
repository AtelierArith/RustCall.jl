# LastCall.jl Examples

This document provides practical examples of using LastCall.jl.

## Table of Contents

1. [Numerical Computations](#numerical-computations)
2. [String Processing](#string-processing)
3. [Data Structures](#data-structures)
4. [Performance Comparison](#performance-comparison)
5. [Real-world Examples](#real-world-examples)
6. [Best Practices](#best-practices)

## Numerical Computations

### Basic Math Functions

```julia
using LastCall

rust"""
#[no_mangle]
pub extern "C" fn power(x: f64, n: i32) -> f64 {
    let mut result = 1.0;
    for _ in 0..n {
        result *= x;
    }
    result
}
"""

# Usage
result = @rust power(2.0, 10)::Float64  # => 1024.0
```

### Fibonacci Sequence

```julia
rust"""
#[no_mangle]
pub extern "C" fn fibonacci(n: u32) -> u64 {
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

# Usage
fib_10 = @rust fibonacci(UInt32(10))::UInt64  # => 55
fib_20 = @rust fibonacci(UInt32(20))::UInt64  # => 6765
```

### Statistical Calculations

```julia
rust"""
#[no_mangle]
pub extern "C" fn calculate_mean(data: *const f64, len: usize) -> f64 {
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    let sum: f64 = slice.iter().sum();
    sum / len as f64
}

#[no_mangle]
pub extern "C" fn calculate_variance(data: *const f64, len: usize, mean: f64) -> f64 {
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    let sum_sq_diff: f64 = slice.iter()
        .map(|&x| (x - mean) * (x - mean))
        .sum();
    sum_sq_diff / len as f64
}
"""

# Julia wrapper
function compute_statistics(data::Vector{Float64})
    len = length(data)
    ptr = pointer(data)

    mean = @rust calculate_mean(ptr, len)::Float64
    variance = @rust calculate_variance(ptr, len, mean)::Float64

    return (mean=mean, variance=variance, stddev=sqrt(variance))
end

# Usage
data = [1.0, 2.0, 3.0, 4.0, 5.0]
stats = compute_statistics(data)
println("Mean: $(stats.mean), StdDev: $(stats.stddev)")
```

## String Processing

### String Search and Replacement

```julia
rust"""
#[no_mangle]
pub extern "C" fn find_substring(haystack: *const u8, needle: *const u8) -> i32 {
    let haystack_str = unsafe {
        std::ffi::CStr::from_ptr(haystack as *const i8)
            .to_str()
            .unwrap_or("")
    };
    let needle_str = unsafe {
        std::ffi::CStr::from_ptr(needle as *const i8)
            .to_str()
            .unwrap_or("")
    };

    match haystack_str.find(needle_str) {
        Some(pos) => pos as i32,
        None => -1,
    }
}
"""

# Usage
pos = @rust find_substring("hello world", "world")::Int32  # => 6
pos = @rust find_substring("hello world", "xyz")::Int32    # => -1
```

### Word Counting

```julia
rust"""
#[no_mangle]
pub extern "C" fn count_words(text: *const u8) -> u32 {
    let text_str = unsafe {
        std::ffi::CStr::from_ptr(text as *const i8)
            .to_str()
            .unwrap_or("")
    };

    text_str.split_whitespace().count() as u32
}
"""

# Usage
word_count = @rust count_words("The quick brown fox")::UInt32  # => 4
```

### UTF-8 String Processing

```julia
rust"""
#[no_mangle]
pub extern "C" fn count_utf8_chars(s: *const u8) -> u32 {
    let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
    let utf8_str = std::str::from_utf8(c_str.to_bytes()).unwrap_or("");
    utf8_str.chars().count() as u32
}

#[no_mangle]
pub extern "C" fn reverse_utf8_string(s: *const u8, output: *mut u8, len: usize) {
    let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
    let utf8_str = std::str::from_utf8(c_str.to_bytes()).unwrap_or("");
    let reversed: String = utf8_str.chars().rev().collect();

    let output_slice = unsafe { std::slice::from_raw_parts_mut(output, len) };
    let bytes = reversed.as_bytes();
    let copy_len = bytes.len().min(len);
    output_slice[..copy_len].copy_from_slice(&bytes[..copy_len]);
}
"""

# Usage
char_count = @rust count_utf8_chars("こんにちは")::UInt32  # => 5
```

## Data Structures

### Array Operations

```julia
rust"""
#[no_mangle]
pub extern "C" fn sum_array(data: *const i32, len: usize) -> i64 {
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    slice.iter().map(|&x| x as i64).sum()
}

#[no_mangle]
pub extern "C" fn max_element(data: *const i32, len: usize) -> i32 {
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    *slice.iter().max().unwrap_or(&0)
}
"""

# Julia wrapper
function process_array(data::Vector{Int32})
    ptr = pointer(data)
    len = length(data)

    total = @rust sum_array(ptr, len)::Int64
    maximum = @rust max_element(ptr, len)::Int32

    return (sum=total, max=maximum)
end

# Usage
arr = Int32[1, 5, 3, 9, 2]
result = process_array(arr)
println("Sum: $(result.sum), Max: $(result.max)")
```

### In-place Sorting

```julia
rust"""
#[no_mangle]
pub extern "C" fn sort_array(data: *mut i32, len: usize) {
    let slice = unsafe { std::slice::from_raw_parts_mut(data, len) };
    slice.sort();
}
"""

# Julia wrapper
function sort_in_place(arr::Vector{Int32})
    ptr = pointer(arr)
    len = length(arr)
    @rust sort_array(ptr, len)::Cvoid
    return arr
end

# Usage
arr = Int32[5, 2, 8, 1, 9]
sort_in_place(arr)
println(arr)  # => [1, 2, 5, 8, 9]
```

## Performance Comparison

### Julia vs Rust: Numerical Computation

```julia
using LastCall
using BenchmarkTools

# Rust implementation
rust"""
#[no_mangle]
pub extern "C" fn rust_sum_range(n: u64) -> u64 {
    (1..=n).sum()
}
"""

# Julia implementation
function julia_sum_range(n::UInt64)
    sum = UInt64(0)
    for i in 1:n
        sum += i
    end
    return sum
end

# Benchmark
n = UInt64(1_000_000)

println("Julia native:")
@btime julia_sum_range($n)

println("Rust (@rust):")
@btime @rust rust_sum_range($n)::UInt64
```

### String Processing Performance

```julia
rust"""
#[no_mangle]
pub extern "C" fn rust_count_words(text: *const u8) -> u32 {
    let text_str = unsafe {
        std::ffi::CStr::from_ptr(text as *const i8)
            .to_str()
            .unwrap_or("")
    };
    text_str.split_whitespace().count() as u32
}
"""

function julia_count_words(text::String)
    return length(split(text))
end

# Benchmark
text = repeat("The quick brown fox jumps over the lazy dog. ", 1000)

println("Julia native:")
@btime julia_count_words($text)

println("Rust (@rust):")
@btime @rust rust_count_words($text)::UInt32
```

## Real-world Examples

### Cryptographic Hash Calculation

```julia
rust"""
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

#[no_mangle]
pub extern "C" fn calculate_hash(data: *const u8, len: usize) -> u64 {
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    let mut hasher = DefaultHasher::new();
    slice.hash(&mut hasher);
    hasher.finish()
}
"""

# Usage
data = Vector{UInt8}(b"hello world")
ptr = pointer(data)
hash_value = @rust calculate_hash(ptr, length(data))::UInt64
println("Hash: $hash_value")
```

### Image Processing (Simplified)

```julia
rust"""
#[no_mangle]
pub extern "C" fn grayscale_image(
    pixels: *mut u8,
    width: usize,
    height: usize
) {
    let total_pixels = width * height * 3;  // RGB
    let slice = unsafe { std::slice::from_raw_parts_mut(pixels, total_pixels) };

    for i in 0..(width * height) {
        let r = slice[i * 3] as f32;
        let g = slice[i * 3 + 1] as f32;
        let b = slice[i * 3 + 2] as f32;

        let gray = (0.299 * r + 0.587 * g + 0.114 * b) as u8;

        slice[i * 3] = gray;
        slice[i * 3 + 1] = gray;
        slice[i * 3 + 2] = gray;
    }
}
"""

# Julia wrapper
function convert_to_grayscale(image::Array{UInt8, 3})
    height, width, channels = size(image)
    @assert channels == 3 "Expected RGB image"

    # Convert image data to 1D array
    pixels = vec(image)
    ptr = pointer(pixels)

    # Call Rust function
    @rust grayscale_image(ptr, width, height)::Cvoid

    # Reshape back to original shape
    return reshape(pixels, height, width, channels)
end
```

### Network Processing (Simplified)

```julia
rust"""
#[no_mangle]
pub extern "C" fn validate_ip_address(ip: *const u8) -> bool {
    let ip_str = unsafe {
        std::ffi::CStr::from_ptr(ip as *const i8)
            .to_str()
            .unwrap_or("")
    };

    let parts: Vec<&str> = ip_str.split('.').collect();
    if parts.len() != 4 {
        return false;
    }

    for part in parts {
        match part.parse::<u8>() {
            Ok(num) if num <= 255 => continue,
            _ => return false,
        }
    }

    true
}
"""

# Usage
is_valid = @rust validate_ip_address("192.168.1.1")::Bool  # => true
is_valid = @rust validate_ip_address("999.999.999.999")::Bool  # => false
```

### Data Compression (Simplified)

```julia
rust"""
#[no_mangle]
pub extern "C" fn simple_compress(
    input: *const u8,
    input_len: usize,
    output: *mut u8,
    output_capacity: usize
) -> usize {
    let input_slice = unsafe { std::slice::from_raw_parts(input, input_len) };
    let output_slice = unsafe { std::slice::from_raw_parts_mut(output, output_capacity) };

    let mut output_idx = 0;
    let mut i = 0;

    while i < input_len && output_idx + 1 < output_capacity {
        let mut count = 1;
        let current = input_slice[i];

        // Count consecutive identical characters
        while i + count < input_len && input_slice[i + count] == current && count < 255 {
            count += 1;
        }

        if output_idx + 2 <= output_capacity {
            output_slice[output_idx] = count as u8;
            output_slice[output_idx + 1] = current;
            output_idx += 2;
        }

        i += count;
    }

    output_idx
}
"""

# Julia wrapper
function compress_data(data::Vector{UInt8})
    input_len = length(data)
    output_capacity = input_len * 2  # Worst case
    output = Vector{UInt8}(undef, output_capacity)

    input_ptr = pointer(data)
    output_ptr = pointer(output)

    compressed_len = @rust simple_compress(
        input_ptr, input_len,
        output_ptr, output_capacity
    )::UInt

    return output[1:compressed_len]
end

# Usage
data = Vector{UInt8}(b"aaabbbcccddd")
compressed = compress_data(data)
println("Original: $(length(data)) bytes")
println("Compressed: $(length(compressed)) bytes")
```

## Best Practices

### 1. Memory Safety

When working with pointers, ensure Julia memory remains valid:

```julia
function safe_array_operation(arr::Vector{Int32})
    if isempty(arr)
        return 0
    end

    ptr = pointer(arr)
    len = length(arr)

    # Call Rust function
    result = @rust process_array(ptr, len)::Int32

    # Ensure arr remains valid (prevent GC)
    GC.@preserve arr result
end
```

### 2. Error Handling

```julia
rust"""
#[no_mangle]
pub extern "C" fn safe_divide(a: i32, b: i32) -> i32 {
    if b == 0 {
        return -1;  // Error code
    }
    a / b
}
"""

function divide_safely(a::Int32, b::Int32)
    result = @rust safe_divide(a, b)::Int32
    if result == -1
        throw(DomainError(b, "Division by zero"))
    end
    return result
end
```

### 3. Performance Optimization

- Use `GC.@preserve` for large arrays to prevent garbage collection
- Consider `@rust_llvm` for performance-critical code
- Leverage caching to avoid recompilation
- Always specify explicit types

### 4. Debugging

When issues occur:

```julia
# Clear cache
clear_cache()

# Recompile
rust"""
// Your code with fixes
"""
```

## Summary

These examples demonstrate practical usage of LastCall.jl. For more detailed information, see the [Tutorial](@ref "Getting Started/Tutorial") and [API Reference](@ref "Reference/API Reference").
