# Examples

A cookbook of small, complete examples. Each one shows the Rust and the Julia
side together, and all of them except the few marked otherwise are run when
this documentation is built, so the outputs are real.

The examples use `#[julia]`, which lets you write ordinary Rust with ordinary
Rust types. If you have not read the [Tutorial](tutorial.md) yet, start there;
if a piece of Rust syntax is unfamiliar, see
[Rust for Julia Users](rust_primer.md).

```@setup cookbook
using RustCall
```

## Numerical kernels

### A loop

```@example cookbook
rust"""
#[julia]
fn power(x: f64, n: u32) -> f64 {
    let mut result = 1.0;
    for _ in 0..n {
        result *= x;
    }
    result
}
"""

power(2.0, 10)
```

`for _ in 0..n` runs `n` times; `_` is Rust's "I do not need this variable".

### Fibonacci

```@example cookbook
rust"""
#[julia]
fn fibonacci(n: u32) -> u64 {
    if n <= 1 {
        return n as u64;
    }

    let (mut a, mut b) = (0u64, 1u64);
    for _ in 2..=n {
        (a, b) = (b, a + b);
    }
    b
}
"""

Int.(fibonacci.(0:10))
```

`0u64` is a literal with an explicit type, and `n as u64` is an explicit
conversion: Rust never converts between numeric types on its own. The Julia
side broadcasts over the generated function like over any other.

### Statistics over an array

A function can take a Julia array as a *slice* (`&[f64]`), without a copy. To
give several values back, return a `#[julia]` struct and read its fields:

```@example cookbook
rust"""
#[julia]
pub struct Summary {
    pub mean: f64,
    pub variance: f64,
    pub min: f64,
    pub max: f64,
}

impl Summary {
    pub fn new(xs: &[f64]) -> Self {
        let n = xs.len() as f64;
        let mean = xs.iter().sum::<f64>() / n;
        let variance = xs.iter().map(|x| (x - mean) * (x - mean)).sum::<f64>() / n;
        let min = xs.iter().copied().fold(f64::INFINITY, f64::min);
        let max = xs.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        Self { mean, variance, min, max }
    }
}
"""

s = Summary([1.0, 2.0, 3.0, 4.0, 5.0])
(mean = s.mean, std = sqrt(s.variance), min = s.min, max = s.max)
```

`xs.iter()` is an iterator, `.map(|x| …)` applies a closure (Julia's
`x -> …`), and `.sum::<f64>()` names the result type explicitly, which Rust
needs here. `.fold(init, f)` is Julia's `foldl(f, xs; init)`.

## Strings

`&str` is a borrowed UTF-8 string and `String` an owned one. Both are a Julia
`String` on the Julia side.

### Searching

```@example cookbook
rust"""
#[julia]
fn find_substring(haystack: &str, needle: &str) -> Option<usize> {
    haystack.find(needle)
}

#[julia]
fn count_words(text: &str) -> usize {
    text.split_whitespace().count()
}
"""

found   = find_substring("hello world", "world")
missing = find_substring("hello world", "xyz")
RustCall.unwrap(found), RustCall.is_none(missing), count_words("The quick brown fox")
```

`str::find` returns an `Option`: `Some(position)` or `None`, where Julia's
`findfirst` returns a range or `nothing`. The position is a **zero-based byte
offset**, so `6` here is Julia's index `7`.

### Returning a new string

```@example cookbook
rust"""
#[julia]
fn reverse_chars(s: &str) -> String {
    s.chars().rev().collect()
}

#[julia]
fn shout(s: &str) -> String {
    format!("{}!", s.to_uppercase())
}
"""

reverse_chars("こんにちは"), shout("hello")
```

`.chars()` iterates over Unicode characters, not bytes, so the reversal is
correct for non-ASCII text. `.collect()` gathers an iterator into the declared
return type, here a `String`.

### Validating input

```@example cookbook
rust"""
#[julia]
fn is_ipv4(text: &str) -> bool {
    let parts: Vec<&str> = text.split('.').collect();
    parts.len() == 4 && parts.iter().all(|part| part.parse::<u8>().is_ok())
}
"""

is_ipv4("192.168.1.1"), is_ipv4("999.1.1.1"), is_ipv4("1.2.3")
```

`part.parse::<u8>()` tries to read the text as an 8-bit unsigned integer and
returns a `Result`, so "is a number from 0 to 255" is one expression.
`Vec<&str>` is Rust's growable array; it is used freely *inside* a function,
it just cannot be an argument or return type at the boundary.

## Arrays

### Reading

```@example cookbook
rust"""
#[julia]
fn sum_wide(xs: &[i32]) -> i64 {
    xs.iter().map(|&x| x as i64).sum()
}

#[julia]
fn max_element(xs: &[i32]) -> Option<i32> {
    xs.iter().copied().max()
}
"""

arr = Int32[1, 5, 3, 9, 2]
sum_wide(arr), RustCall.unwrap(max_element(arr)), RustCall.is_none(max_element(Int32[]))
```

The maximum of an empty slice does not exist, and the Rust type says so:
`max()` returns an `Option`. Summing into an `i64` avoids overflowing `i32`.

### Modifying in place

`&mut [T]` is a writable view of the Julia array:

```@example cookbook
rust"""
#[julia]
fn sort_in_place(xs: &mut [i32]) {
    xs.sort();
}

#[julia]
fn normalize(xs: &mut [f64]) -> Result<(), String> {
    let norm = xs.iter().map(|x| x * x).sum::<f64>().sqrt();
    if norm == 0.0 {
        return Err("cannot normalize a zero vector".to_string());
    }
    for x in xs.iter_mut() {
        *x /= norm;
    }
    Ok(())
}
"""

a = Int32[5, 2, 8, 1, 9]
sort_in_place(a)

v = [3.0, 4.0]
normalize(v)
a, v
```

`Result<(), String>` is the type of "nothing to return, but it can fail".
On failure the array is left untouched and Julia gets the message:

```@example cookbook
RustCall.result_to_exception(normalize([3.0, 4.0]))   # Ok: returns nothing
r = normalize(zeros(3))
RustCall.is_err(r), r.value
```

The element type must match exactly (`Vector{Int32}` for `&[i32]`); see
[Julia arrays as Rust slices](tutorial_new_features.md#Julia-arrays-as-Rust-slices)
for views, matrices and the aliasing rules.

## Bytes

### A hash function

```@example cookbook
rust"""
#[julia]
fn fnv1a(data: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in data {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}
"""

function fnv1a_julia(data::Vector{UInt8})
    hash = 0xcbf29ce484222325
    for byte in data
        hash = (hash ⊻ byte) * 0x100000001b3
    end
    return hash
end

data = Vector{UInt8}("hello world")
fnv1a(data) == fnv1a_julia(data)
```

Julia's integer arithmetic wraps on overflow silently. Rust makes you say so:
`wrapping_mul` is the wrapping multiplication, and a plain `*` that overflows
is treated as a bug.

### Writing into a buffer the caller owns

A Rust function cannot hand a freshly allocated `Vec<u8>` to Julia directly.
The usual pattern is that Julia allocates the output and Rust fills it and
reports how much it used. Here is run-length encoding:

```@example cookbook
rust"""
#[julia]
fn rle_encode(input: &[u8], output: &mut [u8]) -> Result<usize, String> {
    let mut written = 0;
    let mut i = 0;
    while i < input.len() {
        let byte = input[i];
        let mut run = 1;
        while i + run < input.len() && input[i + run] == byte && run < 255 {
            run += 1;
        }
        if written + 2 > output.len() {
            return Err(format!("output buffer too small ({} bytes)", output.len()));
        }
        output[written] = run as u8;
        output[written + 1] = byte;
        written += 2;
        i += run;
    }
    Ok(written)
}
"""

function rle(data::Vector{UInt8})
    output = zeros(UInt8, 2 * length(data))        # worst case
    n = RustCall.result_to_exception(rle_encode(data, output))
    return resize!(output, n)
end

rle(Vector{UInt8}("aaabbbbcd"))
```

Indexing a slice (`input[i]`) is bounds-checked in Rust as in Julia. An
out-of-range index is a panic, which RustCall turns into a
`RustCall.RustPanicError` rather than a crash.

## Objects that keep state

When Rust needs to own growing data, keep it inside a `#[julia]` struct. Julia
holds a handle; the `Vec` never crosses the boundary.

```@example cookbook
rust"""
#[julia]
pub struct Recorder {
    samples: Vec<f64>,
}

impl Recorder {
    pub fn new() -> Self {
        Self { samples: Vec::new() }
    }

    pub fn record(&mut self, value: f64) {
        self.samples.push(value);
    }

    pub fn record_all(&mut self, values: &[f64]) {
        self.samples.extend_from_slice(values);
    }

    pub fn count(&self) -> usize {
        self.samples.len()
    }

    pub fn average(&self) -> Option<f64> {
        if self.samples.is_empty() {
            None
        } else {
            Some(self.samples.iter().sum::<f64>() / self.samples.len() as f64)
        }
    }

    pub fn copy_into(&self, out: &mut [f64]) -> Result<(), String> {
        if out.len() != self.samples.len() {
            return Err(format!("need a buffer of length {}", self.samples.len()));
        }
        out.copy_from_slice(&self.samples);
        Ok(())
    }
}
"""

rec = Recorder()
record(rec, 1.5)
record_all(rec, [2.5, 3.5, 4.5])

out = zeros(Int(count(rec)))
copy_into(rec, out)
Int(count(rec)), RustCall.unwrap(average(rec)), out
```

`&mut self` methods change the object, `&self` methods only read it. The Rust
value is dropped automatically when the Julia object is garbage collected.
`count` here is a new function in this module, not `Base.count`; see the note
on method names in the [Tutorial](tutorial.md#Objects).

## Errors with structure

Returning `Result<T, String>` gives Julia a message. Parsing and validation
code reads naturally with the `?` operator, which returns early on an error:

```@example cookbook
rust"""
#[julia]
fn parse_endpoint(text: &str) -> Result<u16, String> {
    let (host, port) = text
        .split_once(':')
        .ok_or_else(|| format!("`{}` has no `:port`", text))?;
    if host.is_empty() {
        return Err("empty host".to_string());
    }
    let port: u16 = port
        .parse()
        .map_err(|e| format!("bad port `{}`: {}", port, e))?;
    Ok(port)
}
"""

results = parse_endpoint.(["localhost:8080", "localhost", "localhost:http", ":80"])
[RustCall.is_ok(r) ? Int(RustCall.unwrap(r)) : r.value for r in results]
```

## Image processing

An image is a large, flat buffer of bytes, which is the ideal shape for a
Rust kernel: Julia keeps the image types and the plotting, Rust does the
per-pixel loop in place. This example uses Images.jl for display.

To run it locally, install `Images` first:

```julia
using Pkg
Pkg.add("Images")
```

```@example imageprocessing
using RustCall
using Images

# Rust converts the buffer in place. `&mut [u8]` is the Julia vector's own memory.
rust"""
#[julia]
fn grayscale_image(pixels: &mut [u8]) {
    // Interleaved RGB: three bytes per pixel.
    for rgb in pixels.chunks_exact_mut(3) {
        let r = rgb[0] as f32;
        let g = rgb[1] as f32;
        let b = rgb[2] as f32;

        // Standard luminance formula (ITU-R BT.601)
        let gray = (0.299 * r + 0.587 * g + 0.114 * b) as u8;

        rgb[0] = gray;
        rgb[1] = gray;
        rgb[2] = gray;
    }
}
"""

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
grayscale_image(pixels)
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

## Using crates from crates.io

*Not run in this build: it downloads from the network.*

A block can depend on published crates. Name them in a `// cargo-deps:`
comment and RustCall builds the block with Cargo:

```julia
rust"""
// cargo-deps: regex = "1"

use regex::Regex;

#[julia]
fn count_matches(pattern: &str, text: &str) -> Result<usize, String> {
    let re = Regex::new(pattern).map_err(|e| e.to_string())?;
    Ok(re.find_iter(text).count())
}
"""

RustCall.unwrap(count_matches(raw"\d+", "a1 b22 c333"))   # => 3
```

Dependencies use Cargo's own syntax, so features and several crates work too:

```rust
// cargo-deps: serde = { version = "1.0", features = ["derive"] }, serde_json = "1.0"
```

or, for a longer list, a manifest section in a documentation comment:

```rust
//! ```cargo
//! [dependencies]
//! rand = "0.8"
//! ndarray = "0.15"
//! ```
```

The first build downloads and compiles the dependencies and can take a minute.
After that the compiled library is cached.

## The same thing by hand: `extern "C"` and `@rust`

Everything above can be written without `#[julia]`, in the classic C-ABI
style. You then pass raw pointers and lengths yourself, and the Rust side
rebuilds the slice in `unsafe` code:

```@example cookbook
rust"""
#[no_mangle]
pub extern "C" fn sum_array(data: *const i32, len: usize) -> i64 {
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    slice.iter().map(|&x| x as i64).sum()
}
"""

function sum_by_hand(arr::Vector{Int32})
    GC.@preserve arr begin
        @rust sum_array(pointer(arr), UInt(length(arr)))::Int64
    end
end

sum_by_hand(Int32[1, 5, 3, 9, 2])
```

Compared with `sum_wide` above, you are now responsible for three things that
`#[julia]` did for you:

- **`GC.@preserve`.** `pointer(arr)` is a bare address. Without the
  `GC.@preserve` block Julia may free or move `arr` while Rust is reading it.
- **Exact types.** `UInt(length(arr))` must match `usize`; nothing is
  converted.
- **Panics.** A panic in a hand-written `extern "C"` function aborts the
  Julia process.

Use this style to bind existing C-style Rust, and prefer `#[julia]` for new
code.

## Measuring performance

*Not run in this build.*

```julia
using BenchmarkTools

rust"""
#[julia]
fn sum_of_squares(xs: &[f64]) -> f64 {
    xs.iter().map(|x| x * x).sum()
}
"""

julia_sum_of_squares(xs) = sum(x -> x * x, xs)

data = rand(10_000)
@btime julia_sum_of_squares($data)
@btime sum_of_squares($data)
```

Three things to keep in mind when you read such numbers:

- **Julia is already fast.** For a simple numeric loop, well-typed Julia and
  Rust compile to similar machine code. Expect parity, not a miracle. Rust
  earns its place through libraries you do not want to rewrite, predictable
  memory use, and code whose safety you want the compiler to check.
- **A call has a fixed cost.** Crossing the boundary costs a few nanoseconds
  for a `#[julia]` function. That is negligible for a function that does real
  work and dominant for one that adds two numbers. Move the loop to the Rust
  side and pass the whole array, rather than calling Rust once per element.
- **Annotate `@rust` calls.** `@rust f(x)::T` is a direct call; `@rust f(x)`
  without the annotation is resolved dynamically and is far slower.

The [Performance Guide](performance.md) has measurements and details.

## Ownership types

*Not run in this build: these need the helper library built by
`Pkg.build("RustCall")`.*

RustCall can also hold standalone Rust smart pointers and vectors. Most code
never needs them, since `#[julia]` structs cover the common case, but they are
useful for experimenting with Rust's ownership model from the REPL:

```julia
using RustCall

# RustBox: one owner, freed once.
box = RustCall.RustBox(Int32(42))
RustCall.is_valid(box)       # => true
RustCall.drop!(box)
RustCall.is_dropped(box)     # => true

# RustRc / RustArc: shared ownership by reference counting.
rc1 = RustCall.RustRc(Int32(100))
rc2 = RustCall.clone(rc1)    # a second owner of the same value
RustCall.drop!(rc1)
RustCall.is_valid(rc2)       # => true: the value lives until the last owner goes
RustCall.drop!(rc2)

# RustVec: a growable array whose memory Rust manages.
vec = RustCall.create_rust_vec(Int32[1, 2, 3])
vec[1] = 42
collect(vec)                 # => Int32[42, 2, 3]
RustCall.drop!(vec)
```

`RustArc` is the thread-safe variant of `RustRc`. See
[Types, memory and ownership](reference/ownership.md) for the full API.

## Checklist

- Prefer `#[julia]` functions with `&str`, `String`, `&[T]`, `&mut [T]`,
  `Result` and `Option` in their signatures. They are checked and converted
  for you.
- Pass whole arrays and loop in Rust. Do not call across the boundary per
  element.
- Return `Result` for failures a caller should handle. Leave panics for bugs.
- To return several values, return a `#[julia]` struct. To return a large
  buffer, let Julia allocate it and have Rust fill a `&mut [T]`.
- Keep growing or long-lived Rust data inside a `#[julia]` struct.
- When a block does not compile, read the `help:` lines of the compiler
  message first. [Common first errors](rust_primer.md#Common-first-errors)
  translates the usual ones.

For a project of real size, continue with
[Safe Rust/Julia Integration](integration_guide.md).
