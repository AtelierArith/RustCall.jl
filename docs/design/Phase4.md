# Phase 4: Rust Structs and Object Mapping

## Goal
Enable Rust structs to be used as first-class objects in Julia. This includes automatic wrapper generation, method mapping, and seamless memory management.

## Key Features

### 1. Struct Mapping
When a `pub struct` is defined in a `rust""` block, RustCall should optionally generate a corresponding Julia type.

### 2. Method Integration
Rust `impl` blocks should be mapped to Julia methods.
- `fn func(self, ...)` -> Consuming method
- `fn func(&self, ...)` -> Immutable method
- `fn func(&mut self, ...)` -> Mutable method
- `fn new(...) -> Self` -> Julia constructor

### 3. Automatic Lifecycle Management
Julia's `finalizer` will be used to call Rust's `Drop` implementation when the Julia object is GC'd. This ensures no memory leaks for heap-allocated Rust objects.

## Proposed Syntax Example

We want to achieve something like this:

```julia
using RustCall

# Define a Rust struct and its methods
rust"""
pub struct Counter {
    count: i32,
}

impl Counter {
    pub fn new(start: i32) -> Self {
        Self { count: start }
    }

    pub fn increment(&mut self) {
        self.count += 1;
    }

    pub fn get(&self) -> i32 {
        self.count
    }
}
"""

# Usage in Julia
c = Counter(10) # Calls Counter::new(10)
increment(c)    # Calls Counter::increment(&mut self)
println(get(c)) # Calls Counter::get(&self) -> 11
# When 'c' goes out of scope, Rust's Drop is called automatically.
```

## Implementation Strategy

### A. Code Generation (Rust Side)
To call Rust methods from Julia's C-FFI, we need to generate "extern C" wrappers for each method:

```rust
// Generated automatically by RustCall
#[no_mangle]
pub extern "C" fn Counter_new(start: i32) -> *mut Counter {
    Box::into_raw(Box::new(Counter::new(start)))
}

#[no_mangle]
pub extern "C" fn Counter_increment(ptr: *mut Counter) {
    let counter = unsafe { &mut *ptr };
    counter.increment();
}

#[no_mangle]
pub extern "C" fn Counter_free(ptr: *mut Counter) {
    if !ptr.is_null() {
        unsafe { Box::from_raw(ptr); } // Drops the data
    }
}
```

### B. Julia Side Mapping
Create a mutable struct in Julia that holds the raw pointer:

```julia
mutable struct Counter
    ptr::Ptr{Cvoid}

    function Counter(start::Int32)
        ptr = @rust Counter_new(start)::Ptr{Cvoid}
        obj = new(ptr)
        finalizer(obj) do x
            @rust Counter_free(x.ptr)
        end
        return obj
    end
end

increment(c::Counter) = @rust Counter_increment(c.ptr)
get_count(c::Counter) = @rust Counter_get(c.ptr)::Int32
```

## Tasks

- [ ] **Task 1: Struct Detection**: Parse `struct` and `impl` definitions from Rust code.
- [ ] **Task 2: Wrapper Generation**: Automatically generate FFI-friendly C-wrappers for Rust methods.
- [ ] **Task 3: Julia Type Emission**: Generate Julia `mutable struct` and method definitions dynamically.
- [ ] **Task 4: Reference Counting (Optional)**: Support `Arc<T>` or `Rc<T>` based sharing.
- [ ] **Task 5: Field Access**: Provide ways to access public fields of the struct.
