using Pyo3HostImport
using Test
import PythonCall

# Both crates here are PyO3-only: no RustCall attribute anywhere, no `pub`, just
# `#[pyfunction]`, `#[pyclass]`, `#[pymethods]` and `#[pymodule]`. The example
# binds each through RustCall's Python-host path (#424), through a different
# front door.
@testset "Pyo3HostImport.jl" begin
    @testset "front door 1: @rust_crate pyo3_host=true" begin
        @test Pyo3HostImport.MacroBindings isa Module
        @test parentmodule(Pyo3HostImport.MacroBindings) === Pyo3HostImport
        @test nameof(Pyo3HostImport.MacroBindings) === :MacroBindings

        @test scale(Int32(3), Int32(4)) == 12
        @test scale(Int32(-2), Int32(5)) == -10

        # The macro-compatible constructor: one scalar argument.
        a = Accumulator(Int64(10))
        @test a isa Accumulator
        @test total(a) == 10
        @test add(a, Int64(5)) == 15      # mutates in place
        @test total(a) == 15
    end

    @testset "front door 2: RustCall.pyo3_host_import" begin
        # `Sized` is our own type over the Python class; the crate is built and
        # imported on the first call.
        s = Sized(Dict("a" => 1, "b" => 2, "c" => 3))
        @test s isa Sized
        @test item_count(s) == 3

        # A Julia vector is converted by PythonCall; the Python `#[new]` sees a
        # list and measures its length.
        @test item_count(Sized([10, 20, 30, 40])) == 4

        # A Python object passes through unchanged.
        @test item_count(Sized(PythonCall.pybuiltins.list(Tuple(1:5)))) == 5
    end
end
