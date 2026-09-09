using RustCall, Test

function _generic_reload_stress291()
    mktempdir() do root
        dependency = joinpath(root, "dependency")
        mkpath(joinpath(dependency, "src"))
        write(joinpath(dependency, "Cargo.toml"), """
            [package]
            name = "reload_generic_dep291"
            version = "0.1.0"
            edition = "2021"
            [lib]
            crate-type = ["rlib", "cdylib"]
            """)
        path = joinpath(dependency, "src", "lib.rs")
        write_generation(n) = write(path, "#[no_mangle] pub extern \"C\" fn marker() -> i32 { $n }\n")
        write_generation(1)
        source = """
            // cargo-deps: reload_generic_dep291={path="$(RustCall.escape_toml_string(dependency))"}
            use std::sync::atomic::{AtomicUsize, Ordering};
            static DROPS291: AtomicUsize = AtomicUsize::new(0);
            #[julia] pub struct ReloadBox291<T> { pub value: T, pub born: i32 }
            #[julia] impl<T: Copy> ReloadBox291<T> {
                pub fn new(value: T) -> Self { Self { value, born: reload_generic_dep291::marker() } }
                pub fn stamp(&self) -> i32 { reload_generic_dep291::marker() }
                pub fn drop_count(&self) -> usize { DROPS291.load(Ordering::SeqCst) }
                pub fn boom(&self) -> i32 { panic!("reload generation {}", reload_generic_dep291::marker()); }
            }
            impl<T> Drop for ReloadBox291<T> {
                fn drop(&mut self) { DROPS291.fetch_add(1, Ordering::SeqCst); }
            }
            """
        previous = Set(keys(RustCall.RUST_LIBRARIES))
        names = Set{String}()
        objects = Any[]
        readers = Task[]
        stop = Threads.Atomic{Bool}(false)
        calls = Threads.Atomic{Int}(0)
        before = RustCall.finalizer_failure_count()
        withenv("RUSTCALL_CACHE_DIR" => joinpath(root, "cache")) do
            try
                built = RustCall.rebuild_crate(dependency)
                name = "actual_generic_reload291_$(basename(root))"
                RustCall.load_artifact!(RustCall.hot_reload_policy(), built; lib_name = name)
                push!(names, name)
                state = RustCall.HotReloadState(dependency, built, name, [path], Dict{String, Float64}(), nothing, true, nothing)
                scope = Module(gensym(:GenericReload291))
                Core.eval(scope, :(using RustCall))
                inline_lib = Core.eval(scope, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
                push!(names, inline_lib)
                type_ = Core.eval(scope, :(ReloadBox291{Int32}))
                stamp = Base.invokelatest(getfield, scope, :stamp)
                drops = Base.invokelatest(getfield, scope, :drop_count)
                boom = Base.invokelatest(getfield, scope, :boom)
                old = Base.invokelatest(type_, Int32(7))
                push!(objects, old)
                push!(names, getfield(old, :lib_name))
                @test Base.invokelatest(stamp, old) == 1
                for _ in 1:2
                    push!(readers, Threads.@spawn begin
                        valid = true
                        iterations = 0
                        while !stop[]
                            valid &= Base.invokelatest(stamp, old) == 1
                            iterations += 1
                            if iterations % 128 == 1
                                err = try Base.invokelatest(boom, old); nothing catch error; error end
                                valid &= err isa RustCall.RustPanicError && occursin("generation 1", sprint(showerror, err))
                            end
                            Threads.atomic_add!(calls, 1)
                            sleep(0.01)
                        end
                        valid
                    end)
                end
                for generation in 2:3
                    prior_calls = calls[]
                    write_generation(generation)
                    @test RustCall.reload_library(state)
                    @test isempty(state.last_failure)
                    target = RustCall.resolve_call_target(name, "marker")
                    @test RustCall.call_rust_function(target.func_ptr, Int32) == generation
                    current = Base.invokelatest(type_, Int32(generation))
                    push!(objects, current)
                    push!(names, getfield(current, :lib_name))
                    @test Base.invokelatest(stamp, current) == generation
                    @test Base.invokelatest(getproperty, current, :born) == generation
                    @test getfield(current, :lib_name) != getfield(old, :lib_name)
                    temporary = Base.invokelatest(type_, Int32(0))
                    push!(objects, temporary)
                    count = Base.invokelatest(drops, current)
                    finalize(temporary)
                    @test Base.invokelatest(drops, current) == count + 1
                    @test calls[] > prior_calls
                    if generation == 2
                        RustCall.unload_library(getfield(old, :lib_name))
                        @test getfield(old, :alive)[]
                    end
                end
            finally
                stop[] = true
                results = fetch.(readers)
                @test all(results)
                @test calls[] > 0
                foreach(finalize, objects)
                @test RustCall.finalizer_failure_count() == before
                union!(names, setdiff(Set(keys(RustCall.RUST_LIBRARIES)), previous))
                for name in names
                    haskey(RustCall.RUST_LIBRARIES, name) && RustCall.unload_library(name; close = true)
                    RustCall.close_retired_handles!(RustCall.retired_handles(name))
                end
            end
        end
    end
end

@testset "generic objects overlap actual Cargo reloads (#291)" begin
    if Threads.nthreads() < 2
        @test_skip "concurrent reload stress requires multiple threads"
    else
        _generic_reload_stress291()
    end
end

