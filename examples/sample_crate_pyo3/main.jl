# main.jl - Demo of using sample_crate_pyo3 from Julia with RustCall.jl
#
# Run with: julia --project=../.. main.jl

using RustCall

# ============================================================================
# Build and load the crate using @rust_crate
# ============================================================================

println("=" ^ 60)
println("Loading sample_crate_pyo3 with @rust_crate...")
println("=" ^ 60)

crate_path = @__DIR__
@rust_crate crate_path

println("\n✅ Crate loaded as module: SampleCratePyo3\n")

# ============================================================================
# Test basic functions (Julia-only bindings via #[julia])
# ============================================================================

println("=" ^ 60)
println("Testing basic functions (#[julia_pyo3] bindings)")
println("=" ^ 60)

# Test add function
result = SampleCratePyo3.add(2, 3)
println("add(2, 3) = $result")
@assert result == 5

# Test fibonacci function
fib10 = SampleCratePyo3.fibonacci(10)
println("fibonacci(10) = $fib10")
@assert fib10 == 55

fib20 = SampleCratePyo3.fibonacci(20)
println("fibonacci(20) = $fib20")
@assert fib20 == 6765

println("\n✅ Basic functions work!\n")

# ============================================================================
# Test Point struct (unified bindings via #[julia_pyo3])
# ============================================================================

println("=" ^ 60)
println("Testing Point struct (#[julia_pyo3] bindings)")
println("=" ^ 60)

# Create a Point using the constructor
p = SampleCratePyo3.Point(3.0, 4.0)
println("Created Point: p = Point(3.0, 4.0)")

# Access field values
println("  p.x = $(p.x)")
println("  p.y = $(p.y)")
@assert p.x == 3.0
@assert p.y == 4.0

# Test distance_from_origin method
dist = SampleCratePyo3.distance_from_origin(p)
println("  distance_from_origin(p) = $dist")
@assert dist == 5.0

# Test translate method (mutates the point)
println("\nTesting translate (mutating method):")
SampleCratePyo3.translate(p, 1.0, 2.0)
println("  After translate(1.0, 2.0): p = ($(p.x), $(p.y))")
@assert p.x == 4.0
@assert p.y == 6.0

# Test scaled method (returns new Point)
println("\nTesting scaled (returns new Point):")
p2 = SampleCratePyo3.scaled(p, 2.0)
println("  p.scaled(2.0) = ($(p2.x), $(p2.y))")
@assert p2.x == 8.0
@assert p2.y == 12.0

# Test setter
println("\nTesting setters:")
p.x = 10.0
p.y = 20.0
println("  After p.x = 10.0, p.y = 20.0: p = ($(p.x), $(p.y))")
@assert p.x == 10.0
@assert p.y == 20.0

println("\n✅ Point struct works!\n")

# ============================================================================
# Summary
# ============================================================================

println("=" ^ 60)
println("All tests passed! 🎉")
println("=" ^ 60)
println("""
Summary of available bindings (all from #[julia_pyo3]):

  Functions:
    - add(a, b) -> Int32
    - fibonacci(n) -> UInt64

  Point struct:
    - Point(x::Float64, y::Float64) -> Point
    - p.x, p.y (get/set)
    - distance_from_origin(p::Point) -> Float64
    - translate(p::Point, dx, dy)
    - scaled(p::Point, factor) -> Point
""")
