# Integration tests for Rust helpers library build and load

using RustCall
using Test
using Libdl

"""
    get_library_extension() -> String

Get the shared library extension for the current platform.
"""
function get_library_extension()
    if Sys.iswindows()
        return ".dll"
    elseif Sys.isapple()
        return ".dylib"
    else
        return ".so"
    end
end

@testset "Rust Helpers Library Integration" begin
    @testset "Library Path Detection" begin
        # Use RustCall module functions (not exported)
        lib_path = RustCall.get_rust_helpers_lib_path()

        if lib_path !== nothing
            @test isfile(lib_path)
            @test endswith(lib_path, get_library_extension()) || endswith(lib_path, ".dll")
            println("  Found library at: $lib_path")
        else
            @warn "Rust helpers library not found. Build with: using Pkg; Pkg.build(\"RustCall\")"
        end
    end

    @testset "Library Loading" begin
        if RustCall.is_rust_helpers_available()
            lib = RustCall.get_rust_helpers_lib()
            @test lib !== nothing
            @test lib != C_NULL

            @testset "Function Symbol Verification" begin
                # Test that key functions are available
                required_functions = [
                    :rust_box_new_i32,
                    :rust_box_drop_i32,
                    :rust_rc_new_i32,
                    :rust_rc_clone_i32,
                    :rust_rc_drop_i32,
                    :rust_arc_new_i32,
                    :rust_arc_clone_i32,
                    :rust_arc_drop_i32,
                ]

                for func_name in required_functions
                    func_ptr = Libdl.dlsym(lib, func_name; throw_error=false)
                    @test func_ptr !== nothing
                    @test func_ptr != C_NULL
                end
            end

            @testset "Vec Functions Verification" begin
                vec_functions = [
                    :rust_vec_new_from_array_i32,
                    :rust_vec_new_from_array_i64,
                    :rust_vec_new_from_array_f32,
                    :rust_vec_new_from_array_f64,
                    :rust_vec_drop_i32,
                ]

                for func_name in vec_functions
                    func_ptr = Libdl.dlsym(lib, func_name; throw_error=false)
                    if func_ptr === nothing || func_ptr == C_NULL
                        @warn "Vec function $func_name not found in library"
                    else
                        @test func_ptr !== nothing
                    end
                end
            end
        else
            @test_skip "Rust helpers library not loaded. Skipping integration tests."
            @warn "Build with: using Pkg; Pkg.build(\"RustCall\")"
        end
    end

    @testset "End-to-End Integration" begin
        if RustCall.is_rust_helpers_available()
            @testset "Box Creation and Drop" begin
                box = RustCall.RustBox(Int32(42))
                @test RustCall.is_valid(box)

                # Verify the value was stored correctly (if we had a getter)
                RustCall.drop!(box)
                @test RustCall.is_dropped(box)
            end

            @testset "Rc Clone and Drop" begin
                rc1 = RustCall.RustRc(Int32(100))
                @test RustCall.is_valid(rc1)

                rc2 = RustCall.clone(rc1)
                @test RustCall.is_valid(rc2)
                @test rc1.ptr == rc2.ptr

                RustCall.drop!(rc1)
                @test RustCall.is_valid(rc2)

                RustCall.drop!(rc2)
                @test RustCall.is_dropped(rc2)
            end

            @testset "Arc Clone and Drop" begin
                arc1 = RustCall.RustArc(Int32(200))
                @test RustCall.is_valid(arc1)

                arc2 = RustCall.clone(arc1)
                @test RustCall.is_valid(arc2)

                RustCall.drop!(arc1)
                @test RustCall.is_valid(arc2)

                RustCall.drop!(arc2)
                @test RustCall.is_dropped(arc2)
            end

            @testset "Vec Creation and Conversion" begin
                # Check if Vec functions are available
                vec_functions_available = false
                if RustCall.is_rust_helpers_available()
                    lib = RustCall.get_rust_helpers_lib()
                    fn_ptr = Libdl.dlsym(lib, :rust_vec_new_from_array_i32; throw_error=false)
                    vec_functions_available = (fn_ptr !== nothing && fn_ptr != C_NULL)
                end

                if vec_functions_available
                    julia_vec = Int32[1, 2, 3, 4, 5]
                    rust_vec = RustCall.RustVec(julia_vec)

                    @test length(rust_vec) == 5
                    @test RustCall.is_valid(rust_vec)

                    # Test element access
                    @test rust_vec[1] == 1
                    @test rust_vec[5] == 5

                    # Test conversion back
                    back_to_julia = Vector(rust_vec)
                    @test back_to_julia == julia_vec

                    RustCall.drop!(rust_vec)
                    @test RustCall.is_dropped(rust_vec)
                else
                    @warn "Vec functions not available in Rust helpers library"
                end
            end
        else
            @test_skip "Rust helpers library not available. Skipping end-to-end tests."
        end
    end

    @testset "Error Handling" begin
        # Test that errors are handled gracefully when library is not available
        if !RustCall.is_rust_helpers_available()
            @test_throws ErrorException RustCall.RustBox(Int32(42))
            @test_throws ErrorException RustCall.RustRc(Int32(100))
            @test_throws ErrorException RustCall.RustArc(Int32(200))
        end
    end
end
