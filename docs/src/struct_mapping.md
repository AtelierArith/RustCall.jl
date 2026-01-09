# Struct Mapping with #[derive(JuliaStruct)]

LastCall.jl provides automatic struct mapping through the `#[derive(JuliaStruct)]` attribute, which allows you to seamlessly use Rust structs as first-class Julia objects.

## Overview

When you add `#[derive(JuliaStruct)]` to a Rust struct, LastCall.jl automatically:

- Generates Julia bindings for the struct
- Creates field accessors (getters and setters)
- Generates trait implementations (Clone, Debug, etc.) when requested
- Manages memory lifecycle with automatic finalizers

## Basic Usage

### Simple Struct

```julia
using LastCall

rust"""
#[derive(JuliaStruct)]
pub struct Point {
    x: f64,
    y: f64,
}

impl Point {
    pub fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }
    
    pub fn distance(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}
"""

# Create a Point instance
p = Point(3.0, 4.0)

# Access fields directly
println(p.x)  # => 3.0
println(p.y)  # => 4.0

# Modify fields
p.y = 5.0
println(p.y)  # => 5.0

# Call methods
dist = p.distance()
println(dist)  # => 5.830951894845301
```

### With Clone Support

```julia
using LastCall

rust"""
#[derive(JuliaStruct, Clone)]
pub struct Person {
    name: String,
    age: i32,
}

impl Person {
    pub fn new(name: String, age: i32) -> Self {
        Person { name, age }
    }
    
    pub fn get_name(&self) -> String {
        self.name.clone()
    }
}
"""

# Create a person
person = Person("Alice", 30)

# Clone the person
person2 = copy(person)  # Uses Rust's Clone trait

# Both are independent objects
person.age = 31
println(person.age)   # => 31
println(person2.age)  # => 30
```

## Derive Options

The `#[derive(JuliaStruct)]` attribute supports additional derive options:

### Supported Traits

- **`Clone`**: Enables `copy()` function in Julia
- **`Debug`**: (Reserved for future use)
- **`PartialEq`**: (Reserved for future use)
- **`Eq`**: (Reserved for future use)
- **`PartialOrd`**: (Reserved for future use)
- **`Ord`**: (Reserved for future use)
- **`Hash`**: (Reserved for future use)
- **`Default`**: (Reserved for future use)

### Example with Multiple Traits

```julia
rust"""
#[derive(JuliaStruct, Clone)]
pub struct Config {
    host: String,
    port: i32,
    timeout: f64,
}

impl Config {
    pub fn new(host: String, port: i32, timeout: f64) -> Self {
        Config { host, port, timeout }
    }
}
"""

config = Config("localhost", 8080, 30.0)
config2 = copy(config)  # Clone support
```

## Field Access

### Automatic Getters and Setters

When `#[derive(JuliaStruct)]` is present, LastCall.jl automatically generates:

- **Getters**: Access fields using `obj.field_name`
- **Setters**: Modify fields using `obj.field_name = value`

```julia
rust"""
#[derive(JuliaStruct)]
pub struct Rectangle {
    width: f64,
    height: f64,
}

impl Rectangle {
    pub fn new(width: f64, height: f64) -> Self {
        Rectangle { width, height }
    }
    
    pub fn area(&self) -> f64 {
        self.width * self.height
    }
}
"""

rect = Rectangle(10.0, 20.0)

# Get field values
w = rect.width   # => 10.0
h = rect.height  # => 20.0

# Set field values
rect.width = 15.0
rect.height = 25.0

# Calculate area
area = rect.area()  # => 375.0
```

### Field Type Mapping

Field types are automatically mapped from Rust to Julia:

| Rust Type | Julia Type | Notes |
|-----------|------------|-------|
| `i32` | `Int32` | |
| `i64` | `Int64` | |
| `f32` | `Float32` | |
| `f64` | `Float64` | |
| `bool` | `Bool` | |
| `String` | `RustString` | Owned string |
| `&str` | `RustStr` | String slice |

## Generic Structs

Generic structs are also supported:

```julia
rust"""
#[derive(JuliaStruct)]
pub struct Pair<T> {
    first: T,
    second: T,
}

impl<T> Pair<T> {
    pub fn new(first: T, second: T) -> Self {
        Pair { first, second }
    }
}
"""

# Create a Pair with Int32
pair_int = Pair{Int32}(10, 20)
println(pair_int.first)   # => 10
println(pair_int.second)  # => 20

# Create a Pair with Float64
pair_float = Pair{Float64}(3.14, 2.71)
println(pair_float.first)   # => 3.14
println(pair_float.second)  # => 2.71
```

## Memory Management

Structs created with `#[derive(JuliaStruct)]` are automatically managed:

- **Automatic cleanup**: Finalizers call Rust's `Drop` implementation
- **Safe memory**: No manual memory management required
- **Reference counting**: For `Rc` and `Arc` types, reference counting is handled automatically

```julia
rust"""
#[derive(JuliaStruct)]
pub struct Resource {
    id: i32,
    data: Vec<u8>,
}

impl Resource {
    pub fn new(id: i32, data: Vec<u8>) -> Self {
        Resource { id, data }
    }
}

impl Drop for Resource {
    fn drop(&mut self) {
        println!("Dropping resource {}", self.id);
    }
}
"""

# Resource is automatically cleaned up when it goes out of scope
function use_resource()
    res = Resource(1, [1, 2, 3])
    # ... use resource ...
    # Drop is automatically called when res goes out of scope
end

use_resource()  # Prints: "Dropping resource 1"
```

## Method Binding

All `pub fn` methods in `impl` blocks are automatically bound:

```julia
rust"""
#[derive(JuliaStruct)]
pub struct Calculator {
    value: f64,
}

impl Calculator {
    pub fn new(value: f64) -> Self {
        Calculator { value }
    }
    
    pub fn add(&mut self, x: f64) {
        self.value += x;
    }
    
    pub fn multiply(&mut self, x: f64) {
        self.value *= x;
    }
    
    pub fn get_value(&self) -> f64 {
        self.value
    }
    
    pub fn reset(&mut self) {
        self.value = 0.0;
    }
}
"""

calc = Calculator(10.0)
calc.add(5.0)
calc.multiply(2.0)
println(calc.get_value())  # => 30.0
calc.reset()
println(calc.get_value())  # => 0.0
```

## Static Methods

Static methods (methods without `self`) are also supported:

```julia
rust"""
#[derive(JuliaStruct)]
pub struct MathUtils;

impl MathUtils {
    pub fn add(a: f64, b: f64) -> f64 {
        a + b
    }
    
    pub fn multiply(a: f64, b: f64) -> f64 {
        a * b
    }
}
"""

# Call static methods
result1 = MathUtils.add(3.0, 4.0)      # => 7.0
result2 = MathUtils.multiply(3.0, 4.0) # => 12.0
```

## Best Practices

### 1. Always Use `#[derive(JuliaStruct)]`

For structs that you want to use in Julia, always add the attribute:

```rust
#[derive(JuliaStruct)]  // ✅ Good
pub struct MyStruct {
    // ...
}
```

### 2. Use Clone for Expensive Operations

If you need to copy structs frequently, derive `Clone`:

```rust
#[derive(JuliaStruct, Clone)]  // ✅ Good for copyable structs
pub struct Config {
    // ...
}
```

### 3. Keep Structs Simple

Prefer simple field types that map well to Julia:

```rust
#[derive(JuliaStruct)]
pub struct Point {
    x: f64,  // ✅ Good: simple type
    y: f64,
}
```

### 4. Use Methods for Complex Operations

For complex operations, use methods instead of exposing internal state:

```rust
#[derive(JuliaStruct)]
pub struct BankAccount {
    balance: f64,
}

impl BankAccount {
    pub fn new(balance: f64) -> Self {
        BankAccount { balance }
    }
    
    pub fn withdraw(&mut self, amount: f64) -> Result<f64, String> {
        if amount > self.balance {
            Err("Insufficient funds".to_string())
        } else {
            self.balance -= amount;
            Ok(self.balance)
        }
    }
    
    pub fn get_balance(&self) -> f64 {
        self.balance
    }
}
```

## Limitations

### Current Limitations

1. **Nested structs**: Nested structs are not yet fully supported
2. **Complex generics**: Very complex generic constraints may not work
3. **Lifetime parameters**: Lifetime parameters are not supported
4. **Associated types**: Associated types in traits are not supported

### Workarounds

For nested structs, use pointers or references:

```rust
#[derive(JuliaStruct)]
pub struct Outer {
    inner: *mut Inner,  // Use pointer instead of direct nesting
}

#[derive(JuliaStruct)]
pub struct Inner {
    value: i32,
}
```

## Examples

### Complete Example: 2D Vector

```julia
using LastCall

rust"""
#[derive(JuliaStruct, Clone)]
pub struct Vec2 {
    x: f64,
    y: f64,
}

impl Vec2 {
    pub fn new(x: f64, y: f64) -> Self {
        Vec2 { x, y }
    }
    
    pub fn zero() -> Self {
        Vec2 { x: 0.0, y: 0.0 }
    }
    
    pub fn add(&self, other: &Vec2) -> Vec2 {
        Vec2 {
            x: self.x + other.x,
            y: self.y + other.y,
        }
    }
    
    pub fn scale(&mut self, factor: f64) {
        self.x *= factor;
        self.y *= factor;
    }
    
    pub fn magnitude(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
    
    pub fn normalize(&mut self) {
        let mag = self.magnitude();
        if mag > 0.0 {
            self.scale(1.0 / mag);
        }
    }
}
"""

# Create vectors
v1 = Vec2(3.0, 4.0)
v2 = Vec2(1.0, 2.0)

# Access fields
println("v1: ($(v1.x), $(v1.y))")  # => v1: (3.0, 4.0)

# Modify fields
v1.x = 5.0
println("v1: ($(v1.x), $(v1.y))")  # => v1: (5.0, 4.0)

# Call methods
v3 = v1.add(v2)
println("v3: ($(v3.x), $(v3.y))")  # => v3: (6.0, 6.0)

# Static method
zero = Vec2.zero()
println("zero: ($(zero.x), $(zero.y))")  # => zero: (0.0, 0.0)

# Clone
v4 = copy(v1)
v4.scale(2.0)
println("v1 magnitude: $(v1.magnitude())")  # => v1 magnitude: 6.4031242374328485
println("v4 magnitude: $(v4.magnitude())")  # => v4 magnitude: 12.806248474865697
```

## Troubleshooting

### Struct Not Found

If you get an error that the struct is not found, make sure:

1. The struct is marked with `pub`
2. The struct has `#[derive(JuliaStruct)]`
3. The struct is defined in the `rust""` block

```rust
// ❌ Bad: missing pub
struct MyStruct { ... }

// ✅ Good
#[derive(JuliaStruct)]
pub struct MyStruct { ... }
```

### Field Access Errors

If field access doesn't work:

1. Make sure the struct has `#[derive(JuliaStruct)]`
2. Check that field names match exactly
3. Verify field types are supported

### Clone Not Working

If `copy()` doesn't work:

1. Add `Clone` to the derive list: `#[derive(JuliaStruct, Clone)]`
2. Make sure all fields implement `Clone` in Rust

## See Also

- [Tutorial](@ref "Getting Started/Tutorial"): General tutorial on using LastCall.jl
- [Examples](@ref "Getting Started/Examples"): More examples of LastCall.jl usage
- [API Reference](@ref "Reference/API Reference"): Complete API documentation
- [Generics](@ref "User Guide/Generics"): Using generics with LastCall.jl
