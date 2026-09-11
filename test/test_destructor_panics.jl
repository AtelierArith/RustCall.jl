using RustCall
using Test

include(joinpath(@__DIR__, "pyo3_wrapper_helpers.jl"))

@testset "generated destructor panics are counted without STATE (#291)" begin
    source = raw"""
        #[julia]
        pub struct DropBomb291 { fail: bool }
        impl DropBomb291 {
            pub fn new(fail: bool) -> Self { Self { fail } }
        }
        impl Drop for DropBomb291 {
            fn drop(&mut self) {
                if self.fail { panic!("ordinary destructor panic"); }
            }
        }
        #[julia]
        pub struct GenericDropBomb291<T> { value: T }
        #[julia]
        impl<T> GenericDropBomb291<T> {
            pub fn new(value: T) -> Self { Self { value } }
        }
        impl<T> Drop for GenericDropBomb291<T> {
            fn drop(&mut self) { panic!("generic destructor panic"); }
        }
        """
    # An absent Rust catch boundary aborts a process, so exercise the actual
    # generated FFI entries in a child rather than killing the test worker.
    script = """
        using RustCall, Test
        Core.eval(Main, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), $(repr(source))))
        bomb = Base.invokelatest(DropBomb291, true)
        quiet = Base.invokelatest(DropBomb291, false)
        generic = Base.invokelatest(GenericDropBomb291{Int32}, Int32(1))
        @test getfield(bomb, :free_channel) != C_NULL
        @test getfield(generic, :free_channel) != C_NULL
        before = RustCall.finalizer_failure_count()
        task = lock(RustCall.REGISTRY_LOCK) do
            task = Threads.@spawn finalize(bomb)
            @test timedwait(() -> istaskdone(task), 5.0) == :ok
            task
        end
        fetch(task)
        @test getfield(bomb, :ptr) == C_NULL
        @test RustCall.finalizer_failure_count() == before + 1
        finalize(bomb)
        finalize(quiet)
        @test RustCall.finalizer_failure_count() == before + 1

        # Retire its image before finalizing: the channel, destructor and
        # liveness must all remain those captured by this object's allocator.
        lib = getfield(generic, :lib_name)
        RustCall.unload_library(lib)
        @test getfield(generic, :alive)[]
        finalize(generic)
        @test getfield(generic, :ptr) == C_NULL
        @test RustCall.finalizer_failure_count() == before + 2
        finalize(generic)
        @test RustCall.finalizer_failure_count() == before + 2
        RustCall.close_retired_handles!(RustCall.retired_handles(lib))
        println("destructor panic checks passed")
        """
    project = dirname(@__DIR__)
    result = read(`$(Base.julia_cmd()) --startup-file=no --project=$project --threads=4 -e $script`, String)
    @test occursin("destructor panic checks passed", result)
end

@testset "a real PyO3 destructor panic is counted (#291)" begin
    mktempdir() do root
        mkpath(joinpath(root, "src"))
        manifest = replace(read(joinpath(@__DIR__, "fixtures", "sample_crate_pyo3_only", "Cargo.toml"), String),
                           "sample_crate_pyo3_only" => "pyo3_destructor_291")
        write(joinpath(root, "Cargo.toml"), manifest)
        write(joinpath(root, "src", "lib.rs"), raw"""
            use pyo3::prelude::*;
            #[pyclass]
            pub struct PyDropBomb291 { fail: bool }
            #[pymethods]
            impl PyDropBomb291 {
                #[new]
                pub fn new(fail: bool) -> Self { Self { fail } }
            }
            impl Drop for PyDropBomb291 {
                fn drop(&mut self) {
                    if self.fail { panic!("PyO3 destructor panic"); }
                }
            }
            """)
        wrapper = _link_libpython_wrapper(root)
        if wrapper === nothing
            @test_skip "no linkable Python here"
        else
            script = """
                using RustCall, Test
                crate = $(repr(root))
                bindings = @rust_crate crate
                type_ = Base.invokelatest(getproperty, bindings, :PyDropBomb291)
                bomb = Base.invokelatest(type_, true)
                quiet = Base.invokelatest(type_, false)
                @test getfield(bomb, :free_channel) != C_NULL
                before = RustCall.finalizer_failure_count()
                finalize(bomb)
                @test RustCall.finalizer_failure_count() == before + 1
                @test getfield(bomb, :ptr) == C_NULL
                finalize(quiet)
                finalize(bomb)
                @test RustCall.finalizer_failure_count() == before + 1
                println("PyO3 destructor panic checks passed")
                """
            project = dirname(@__DIR__)
            result = read(`$(Base.julia_cmd()) --startup-file=no --project=$project -e $script`, String)
            @test occursin("PyO3 destructor panic checks passed", result)
        end
    end
end

@testset "both crate emitters capture destructor panic channels (#291)" begin
    mktempdir() do root
        mkpath(joinpath(root, "src"))
        macros = RustCall.escape_toml_string(joinpath(dirname(@__DIR__), "deps", "rustcall_julia_macros"))
        write(joinpath(root, "Cargo.toml"), """
            [package]
            name = "destructor_panic_291"
            version = "0.1.0"
            edition = "2021"
            [lib]
            crate-type = ["cdylib"]
            [dependencies]
            rustcall_julia_macros = { path = "$macros" }
            """)
        write(joinpath(root, "src", "lib.rs"), raw"""
            use rustcall_julia_macros::julia;
            #[julia]
            pub struct CrateDropBomb291 { fail: bool }
            #[julia]
            impl CrateDropBomb291 {
                #[julia]
                pub fn new(fail: bool) -> Self { Self { fail } }
            }
            impl Drop for CrateDropBomb291 {
                fn drop(&mut self) {
                    if self.fail { panic!("crate destructor panic"); }
                }
            }
            """)
        output = joinpath(root, "Bindings.jl")
        script = """
            using RustCall, Test
            crate = $(repr(root))
            bindings = @rust_crate crate
            ast_module = getfield(bindings, :module_ref)
            RustCall.write_bindings_to_file(crate, $(repr(output)); output_module_name = "DropSource291")
            Base.include(Main, $(repr(output)))
            source_module = getfield(Main, :DropSource291)
            for module_ in (ast_module, source_module)
                type_ = Base.invokelatest(getfield, module_, :CrateDropBomb291)
                bomb = Base.invokelatest(type_, true)
                quiet = Base.invokelatest(type_, false)
                @test getfield(bomb, :free_channel) != C_NULL
                before = RustCall.finalizer_failure_count()
                task = lock(RustCall.REGISTRY_LOCK) do
                    task = Threads.@spawn finalize(bomb)
                    @test timedwait(() -> istaskdone(task), 5.0) == :ok
                    task
                end
                fetch(task)
                @test getfield(bomb, :ptr) == C_NULL
                @test RustCall.finalizer_failure_count() == before + 1
                finalize(bomb)
                finalize(quiet)
                @test RustCall.finalizer_failure_count() == before + 1
            end
            println("crate destructor panic checks passed")
            """
        project = dirname(@__DIR__)
        result = read(`$(Base.julia_cmd()) --startup-file=no --project=$project --threads=4 -e $script`, String)
        @test occursin("crate destructor panic checks passed", result)
        # The child has exited before deleting its Cargo tree, including on
        # Windows where a mapped DLL would prevent cleanup in this process.
    end
end
