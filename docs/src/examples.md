# RustCall.jl Examples

This document provides practical examples of using RustCall.jl.


## Table of Contents

1. [Numerical Computations](#numerical-computations)
2. [String Processing](#string-processing)
3. [Data Structures](#data-structures)
4. [Additional Reference Examples](#additional-reference-examples)
5. [Performance Comparison](#performance-comparison)
6. [Real-world Examples](#real-world-examples)
7. [Best Practices](#best-practices)

## Numerical Computations

### Basic Math Functions

```julia
rust"""
#[julia]
fn power(x: f64, n: i32) -> f64 {
    let mut result = 1.0;
    for _ in 0..n {
        result *= x;
    }
    result
}
"""

# Usage - wrapper auto-generated
result = power(2.0, 10)  # => 1024.0
```

### Fibonacci Sequence

```julia
rust"""
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

# Usage - wrapper auto-generated
fib_10 = fibonacci(UInt32(10))  # => 55
fib_20 = fibonacci(UInt32(20))  # => 6765
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

## Additional Reference Examples

This section collects longer reference examples that previously lived in the top-level README.

### Type Mapping Quick Reference

| Rust Type | Julia Type |
|-----------|------------|
| `i8` | `Int8` |
| `i16` | `Int16` |
| `i32` | `Int32` |
| `i64` | `Int64` |
| `u8` | `UInt8` |
| `u16` | `UInt16` |
| `u32` | `UInt32` |
| `u64` | `UInt64` |
| `f32` | `Float32` |
| `f64` | `Float64` |
| `bool` | `Bool` |
| `usize` | `UInt` |
| `isize` | `Int` |
| `()` | `Cvoid` |
| `*const u8` | `Cstring` / `String` |
| `*mut u8` | `Ptr{UInt8}` |

### Result And Option Types

```julia
using RustCall

# Result type
ok_result = RustCall.RustResult{Int32, String}(true, Int32(42))
RustCall.is_ok(ok_result)        # => true
RustCall.unwrap(ok_result)       # => 42

err_result = RustCall.RustResult{Int32, String}(false, "error")
RustCall.is_err(err_result)      # => true
RustCall.unwrap_or(err_result, Int32(0))  # => 0

# Convert Result to exception
try
    RustCall.result_to_exception(err_result)
catch e
    println(e isa RustCall.RustError)      # => true
end

# Option type
some_opt = RustCall.RustOption{Int32}(true, Int32(42))
RustCall.is_some(some_opt)      # => true
RustCall.unwrap(some_opt)       # => 42

none_opt = RustCall.RustOption{Int32}(false, nothing)
RustCall.is_none(none_opt)      # => true
RustCall.unwrap_or(none_opt, Int32(0))    # => 0
```

### Ownership Types And Collections

```julia
using RustCall

if RustCall.is_rust_helpers_available()
    # RustBox - heap-allocated value (single ownership)
    box = RustCall.RustBox(Int32(42))
    RustCall.is_valid(box)       # => true
    RustCall.drop!(box)
    RustCall.is_dropped(box)     # => true

    # RustRc - reference counting (single-threaded)
    rc1 = RustCall.RustRc(Int32(100))
    rc2 = RustCall.clone(rc1)
    RustCall.drop!(rc1)
    RustCall.is_valid(rc2)       # => true
    RustCall.drop!(rc2)

    # RustArc - atomic reference counting (thread-safe)
    arc1 = RustCall.RustArc(Int32(200))
    arc2 = RustCall.clone(arc1)
    RustCall.drop!(arc1)
    RustCall.is_valid(arc2)      # => true
    RustCall.drop!(arc2)

    # RustVec - growable array backed by Rust-managed memory
    vec = RustCall.create_rust_vec(Int32[1, 2, 3])
    vec[1] = 42
    collect(vec)                 # => Int32[42, 2, 3]

    # Bounds checking and iteration
    try
        vec[0]
    catch e
        println(e isa BoundsError)  # => true
    end

    for x in vec
        println(x)
    end

    julia_vec = Vector(vec)      # or collect(vec)
    println(julia_vec)

    RustCall.drop!(vec)

    # RustSlice - borrowed view into existing memory
    backing = Int32[10, 20, 30]
    slice = RustCall.RustSlice{Int32}(pointer(backing), UInt(length(backing)))
    slice[2]                     # => 20

    for x in slice
        println(x)
    end

    Base.IteratorSize(RustCall.RustVec{Int32}) == Base.HasLength()
    Base.eltype(RustCall.RustVec{Int32}) == Int32
end
```

`RustBox`, `RustRc`, `RustArc`, `RustVec`, and `RustSlice` require the helper library built during package installation. If the helper library is unavailable, run `Pkg.build("RustCall")` to rebuild it.

### Cargo-Backed External Libraries

RustCall can build Cargo dependencies directly from inline Rust code.

```julia
using RustCall

rust"""
// cargo-deps: ndarray = "0.15"

use ndarray::Array1;

#[no_mangle]
pub extern "C" fn compute_sum(data: *const f64, len: usize) -> f64 {
    unsafe {
        let slice = std::slice::from_raw_parts(data, len);
        let arr = Array1::from_vec(slice.to_vec());
        arr.sum()
    }
}
"""

data = [1.0, 2.0, 3.0, 4.0, 5.0]
result = @rust compute_sum(pointer(data), length(data))::Float64
println(result)  # => 15.0
```

Supported dependency declaration styles include:

```rust
// cargo-deps: serde = "1.0", serde_json = "1.0"
```

and:

```rust
//! ```cargo
//! [dependencies]
//! rand = "0.8"
//! ```
```

You can also use structured Cargo dependency declarations:

```julia
using RustCall

rust"""
// cargo-deps: serde = { version = "1.0", features = ["derive"] }

use serde::{Serialize, Deserialize};

#[derive(Serialize, Deserialize)]
pub struct Data {
    value: i32,
}

#[no_mangle]
pub extern "C" fn process_data(val: i32) -> i32 {
    let data = Data { value: val };
    data.value * 2
}
"""

result = @rust process_data(Int32(21))::Int32
```

### Rust Structs As Julia Objects

Rust structs marked with `#[julia]` can be used from Julia as generated wrapper types and functions.

```julia
using RustCall

rust"""
#[julia]
pub struct Person {
    age: u32,
    height: f64,
}

impl Person {
    pub fn new(age: u32, height: f64) -> Self {
        Self { age, height }
    }

    pub fn greet(&self) {
        println!("Hello, I am {} years old.", self.age);
    }

    pub fn have_birthday(&mut self) {
        self.age += 1;
    }

    pub fn get_height(&self) -> f64 {
        self.height
    }
}
"""

person = Person(30, 175.5)
greet(person)
have_birthday(person)
height = get_height(person)
```

Generic structs can also be exposed:

```julia
using RustCall

rust"""
#[julia]
pub struct Point<T> {
    x: T,
    y: T,
}

impl<T> Point<T> {
    pub fn new(x: T, y: T) -> Self {
        Self { x, y }
    }
}

impl Point<f64> {
    pub fn distance(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}
"""

point = Point{Float64}(3.0, 4.0)
dist = distance(point)  # => 5.0
```

Automatic cleanup works through Rust `Drop` integration:

```julia
using RustCall

rust"""
#[julia]
pub struct Resource {
    data: Vec<u8>,
}

impl Resource {
    pub fn new(size: usize) -> Self {
        Self { data: vec![0; size] }
    }
}

impl Drop for Resource {
    fn drop(&mut self) {
        println!("Rust: Dropping Resource");
    }
}
"""

function use_resource()
    res = Resource(1000)
    nothing
end
```

### LLVM IR Integration

The LLVM call path is experimental, but it can be useful for repeated hot paths.

```julia
using RustCall

rust"""
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

info = RustCall.compile_and_register_rust_function("""
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 { a + b }
""", "add")

result = @rust_llvm add(Int32(10), Int32(20))  # => 30
```

Optimization configuration is exposed explicitly:

```julia
using RustCall

rust_code = """
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

wrapped_code = RustCall.wrap_rust_code(rust_code)
compiler = RustCall.get_default_compiler()
ir_path = RustCall.compile_rust_to_llvm_ir(wrapped_code; compiler=compiler)
rust_mod = RustCall.load_llvm_ir(ir_path; source_code=wrapped_code)
llvm_mod = rust_mod.mod

config = RustCall.OptimizationConfig(
    level=3,
    enable_vectorization=true,
    inline_threshold=300,
)

RustCall.optimize_module!(llvm_mod; config=config)
RustCall.optimize_for_speed!(llvm_mod)
RustCall.optimize_for_size!(llvm_mod)
```

### Compilation Caching

Compilation results are cached automatically for repeated Rust snippets.

```julia
using RustCall

rust"""
#[no_mangle]
pub extern "C" fn test() -> i32 { 42 }
"""

rust"""
#[no_mangle]
pub extern "C" fn test() -> i32 { 42 }
"""

RustCall.clear_cache()
RustCall.get_cache_size()
RustCall.list_cached_libraries()
RustCall.cleanup_old_cache(30)
```

## Performance Comparison

### Julia vs Rust: Numerical Computation

If you want to run this example locally, install `BenchmarkTools` first:

```julia
using Pkg
Pkg.add("BenchmarkTools")
```

```julia
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

This example demonstrates using Rust for image processing with visualization using Images.jl.

If you want to run this example locally, install `Images` first:

```julia
using Pkg
Pkg.add("Images")
```

```@example imageprocessing
using RustCall
using Images

# Define Rust grayscale conversion function
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

        // Standard luminance formula (ITU-R BT.601)
        let gray = (0.299 * r + 0.587 * g + 0.114 * b) as u8;

        slice[i * 3] = gray;
        slice[i * 3 + 1] = gray;
        slice[i * 3 + 2] = gray;
    }
}
"""

# Julia wrapper for grayscale conversion
function convert_to_grayscale!(pixels::Vector{UInt8}, width::Int, height::Int)
    ptr = pointer(pixels)
    @rust grayscale_image(ptr, UInt(width), UInt(height))::Cvoid
    return pixels
end

# Create a sample RGB image (gradient with colors)
function create_sample_image(width, height)
    img = zeros(RGB{N0f8}, height, width)
    for y in 1:height, x in 1:width
        r = (x - 1) / (width - 1)    # Red increases left to right
        g = (y - 1) / (height - 1)   # Green increases top to bottom
        b = 0.5                       # Constant blue
        img[y, x] = RGB{N0f8}(r, g, b)
    end
    return img
end

# Convert Julia image to raw RGB bytes (row-major, interleaved RGB)
function image_to_bytes(img)
    h, w = size(img)
    pixels = Vector{UInt8}(undef, h * w * 3)
    idx = 1
    for y in 1:h, x in 1:w
        pixel = img[y, x]
        pixels[idx] = reinterpret(UInt8, red(pixel))
        pixels[idx + 1] = reinterpret(UInt8, green(pixel))
        pixels[idx + 2] = reinterpret(UInt8, blue(pixel))
        idx += 3
    end
    return pixels
end

# Convert raw RGB bytes back to Julia image
function bytes_to_image(pixels, width, height)
    img = zeros(RGB{N0f8}, height, width)
    idx = 1
    for y in 1:height, x in 1:width
        r = reinterpret(N0f8, pixels[idx])
        g = reinterpret(N0f8, pixels[idx + 1])
        b = reinterpret(N0f8, pixels[idx + 2])
        img[y, x] = RGB{N0f8}(r, g, b)
        idx += 3
    end
    return img
end

# Create sample image
width, height = 256, 256
original_img = create_sample_image(width, height)
nothing # hide
```

**Original Image (Color Gradient):**

```@example imageprocessing
original_img
```

Now let's convert it to grayscale using Rust:

```@example imageprocessing
# Process the image with Rust
pixels = image_to_bytes(original_img)
convert_to_grayscale!(pixels, width, height)
grayscale_img = bytes_to_image(pixels, width, height)
nothing # hide
```

**Grayscale Image (Processed by Rust):**

```@example imageprocessing
grayscale_img
```

Let's verify the grayscale conversion worked correctly:

```@example imageprocessing
# Check that R, G, B are equal (grayscale property)
sample_pixel = grayscale_img[128, 128]
println("Sample pixel at (128, 128):")
println("  R = $(red(sample_pixel))")
println("  G = $(green(sample_pixel))")
println("  B = $(blue(sample_pixel))")
println("  Grayscale verified: ", red(sample_pixel) == green(sample_pixel) == blue(sample_pixel))
```

**Side-by-side comparison:**

```@example imageprocessing
# Create a side-by-side comparison image
comparison = [original_img grayscale_img]
```

!!! note "Running this example"
    For `servedocs()`, make sure to run it from the docs environment:
    ```julia
    julia --project=docs -e 'using Pkg; Pkg.instantiate()'
    julia --project=docs -e 'using LiveServer; servedocs()'
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

When working with pointers, ensure Julia memory remains valid using `GC.@preserve`:

```julia
using RustCall

# Define a Rust function that processes an array
rust"""
#[no_mangle]
pub extern "C" fn sum_array(arr: *const i32, len: usize) -> i32 {
    let slice = unsafe { std::slice::from_raw_parts(arr, len) };
    slice.iter().sum()
}
"""

function safe_array_sum(arr::Vector{Int32})
    if isempty(arr)
        return Int32(0)
    end

    ptr = pointer(arr)
    len = length(arr)

    # GC.@preserve ensures arr remains valid during Rust call
    GC.@preserve arr begin
        result = @rust sum_array(ptr, UInt(len))::Int32
    end

    return result
end

# Test the safe function
arr = Int32[1, 2, 3, 4, 5]
result = safe_array_sum(arr)
println("Sum of $arr = $result")  # => Sum of [1, 2, 3, 4, 5] = 15
```

### 2. Error Handling

Use error codes or Result types for safe error handling:

```julia
rust"""
#[no_mangle]
pub extern "C" fn safe_divide(a: i32, b: i32) -> i32 {
    if b == 0 {
        return -1;  // Indicate error
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

# Test successful division
divide_safely(Int32(10), Int32(2))  # => 5

# Test error handling
try
    divide_safely(Int32(10), Int32(0))
catch e
    println("Caught error: $e")  # => DomainError
end
```

### 3. Performance Optimization

Benchmark to compare Julia and Rust performance:

If you want to run this example locally, install `BenchmarkTools` first:

```julia
using Pkg
Pkg.add("BenchmarkTools")
```

```julia
using BenchmarkTools

# Rust implementation for computing sum of squares
rust"""
#[no_mangle]
pub extern "C" fn sum_of_squares_rust(arr: *const f64, len: usize) -> f64 {
    let slice = unsafe { std::slice::from_raw_parts(arr, len) };
    slice.iter().map(|x| x * x).sum()
}
"""

# Julia implementation
function sum_of_squares_julia(arr::Vector{Float64})
    sum(x -> x * x, arr)
end

# Wrapper for Rust
function sum_of_squares_rust_wrapper(arr::Vector{Float64})
    GC.@preserve arr begin
        @rust sum_of_squares_rust(pointer(arr), UInt(length(arr)))::Float64
    end
end

# Benchmark
data = rand(10000)
@btime sum_of_squares_julia($data)
@btime sum_of_squares_rust_wrapper($data)
```

**Performance tips:**
- Use `GC.@preserve` for large arrays to prevent garbage collection during Rust calls
- Consider `@rust_llvm` for performance-critical code with LLVM optimizations
- Leverage caching to avoid recompilation (functions are cached automatically)
- Always specify explicit types in `@rust` macro calls

### 4. Debugging

When issues occur, use these debugging techniques:

```julia
# Check cache status
cache_size = RustCall.get_cache_size()
println("Current cache size: $cache_size libraries")

# List cached libraries
cached = RustCall.list_cached_libraries()
println("Cached libraries: $(length(cached)) items")

# Clear cache if needed
RustCall.clear_cache()
println("Cache cleared")
```

### 5. Type Safety with Generics

Use generics for type-safe, reusable code:

```julia
# Register a generic identity function
code = """
#[no_mangle]
pub extern "C" fn identity<T>(x: T) -> T {
    x
}
"""

RustCall.register_generic_function("identity", code, [:T])

# Call with different types - automatic monomorphization
result_i32 = RustCall.call_generic_function("identity", Int32(42))  # => 42
result_f64 = RustCall.call_generic_function("identity", 3.14)       # => 3.14


println("identity(Int32(42)) = $result_i32")
println("identity(3.14) = $result_f64")
```

## Summary

These examples demonstrate practical usage of RustCall.jl:

- **Memory Safety**: Always use `GC.@preserve` when passing Julia arrays to Rust
- **Error Handling**: Use error codes or Result types instead of panics
- **Performance**: Benchmark and optimize with explicit types
- **Debugging**: Use cache management functions to troubleshoot
- **Generics**: Leverage automatic monomorphization for type-safe code

For more detailed information, see the [Tutorial](tutorial.md) and [API Reference](api.md).
