# MyExample.jl

An example Julia package demonstrating how to use [RustCall.jl](https://github.com/atelierarith/RustCall.jl) to call Rust code from Julia.

## Installation

This package depends on RustCall.jl. To use this example package:

```julia
using Pkg

# Activate this package's environment
Pkg.activate("examples/MyExample.jl")

# Add RustCall.jl as a dev dependency (since it's not yet registered)
Pkg.develop(path="../../")  # Path relative to this package

# Instantiate dependencies
Pkg.instantiate()
```

**Note**: Since RustCall.jl is not yet registered in the Julia package registry, you need to add it as a dev dependency using `Pkg.develop()`. The path `../../` assumes you're running from the `examples/MyExample.jl` directory and points to the root of the RustCall.jl repository.

## Usage

```julia
using MyExample

# Basic numerical computations
result = add_numbers(Int32(10), Int32(20))  # => 30
product = multiply_numbers(3.0, 4.0)         # => 12.0
fib_10 = fibonacci(UInt32(10))              # => 55

# String processing
word_count = count_words("The quick brown fox")  # => 4
reversed = reverse_string("hello")               # => "olleh"

# Array operations
arr = Int32[1, 2, 3, 4, 5]
total = sum_array(arr)      # => 15
maximum = max_in_array(arr) # => 5
```

## Examples Included

### 1. Basic Numerical Computations
- `add_numbers`: Add two integers
- `multiply_numbers`: Multiply two floating-point numbers
- `fibonacci`: Calculate Fibonacci numbers

### 2. String Processing
- `count_words`: Count words in a string
- `reverse_string`: Reverse a string

### 3. Array Operations
- `sum_array`: Sum all elements in an array
- `max_in_array`: Find the maximum element in an array

## How It Works

This package uses RustCall.jl's `rust""` string literal to define Rust functions and the `@rust` macro to call them from Julia. The Rust code is compiled to a shared library and loaded dynamically.

For more information about RustCall.jl, see the [documentation](https://atelierarith.github.io/RustCall.jl/).
