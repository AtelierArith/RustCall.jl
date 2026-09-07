#!/usr/bin/env python3
"""
main.py - Demo of using sample_crate_pyo3 from Python

Before running, build and install the module:
    pip install maturin
    cd examples/sample_crate_pyo3
    maturin develop --features python

Then run:
    python main.py
"""

import sample_crate_pyo3 as m

print("=" * 60)
print("Testing sample_crate_pyo3 from Python")
print("=" * 60)

# ============================================================================
# Test basic functions (#[pyfunction] next to #[julia])
# ============================================================================

print("\n" + "=" * 60)
print("Testing basic functions (#[pyfunction] bindings)")
print("=" * 60)

# Test add function
result = m.add(2, 3)
print(f"add(2, 3) = {result}")
assert result == 5

# Test fibonacci function
fib10 = m.fibonacci(10)
print(f"fibonacci(10) = {fib10}")
assert fib10 == 55

fib20 = m.fibonacci(20)
print(f"fibonacci(20) = {fib20}")
assert fib20 == 6765

# A String signature: PyO3 sees `fn shout(String) -> String` as written.
shouted = m.shout("hello")
print(f'shout("hello") = {shouted}')
assert shouted == "HELLO"

print("\n✅ Basic functions work!\n")

# ============================================================================
# Test Point class (#[pyclass] + #[pymethods] next to #[julia])
# ============================================================================

print("=" * 60)
print("Testing Point class (#[pyclass] bindings)")
print("=" * 60)

# Create a Point using the constructor
p = m.Point(3.0, 4.0)
print(f"Created Point: p = Point(3.0, 4.0)")

# Access field values (via get_all)
print(f"  p.x = {p.x}")
print(f"  p.y = {p.y}")
assert p.x == 3.0
assert p.y == 4.0

# Test distance_from_origin method
dist = p.distance_from_origin()
print(f"  p.distance_from_origin() = {dist}")
assert dist == 5.0

# Test translate method (mutates the point)
print("\nTesting translate (mutating method):")
p.translate(1.0, 2.0)
print(f"  After p.translate(1.0, 2.0): p = ({p.x}, {p.y})")
assert p.x == 4.0
assert p.y == 6.0

# Test scaled method (returns new Point)
print("\nTesting scaled (returns new Point):")
p2 = p.scaled(2.0)
print(f"  p.scaled(2.0) = ({p2.x}, {p2.y})")
assert p2.x == 8.0
assert p2.y == 12.0

# Test setter (via set_all)
print("\nTesting setters:")
p.x = 10.0
p.y = 20.0
print(f"  After p.x = 10.0, p.y = 20.0: p = ({p.x}, {p.y})")
assert p.x == 10.0
assert p.y == 20.0

print("\n✅ Point class works!\n")

# ============================================================================
# Summary
# ============================================================================

print("=" * 60)
print("All tests passed! 🎉")
print("=" * 60)
print("""
Summary of available Python bindings (PyO3's own attributes, next to #[julia]):

  Functions:
    - add(a: int, b: int) -> int
    - fibonacci(n: int) -> int
    - shout(s: str) -> str

  Point class:
    - Point(x: float, y: float)
    - Point.x (get/set)
    - Point.y (get/set)
    - Point.distance_from_origin() -> float
    - Point.translate(dx: float, dy: float)
    - Point.scaled(factor: float) -> Point
""")
