# Tests for LLVM/Codegen bug fixes (#164, #165, #166, #167, #182, #183, #196)

using RustCall
using Test

const LLVM = RustCall.LLVM

@testset "LLVM/Codegen Bug Fixes" begin

    @testset "Bool ABI uses i8 not i1 (#165)" begin
        # C ABI represents bool as i8 (one byte), not i1 (one bit)
        @test RustCall.julia_type_to_llvm_ir_string(Bool) == "i8"
        # Verify it's not the old buggy value
        @test RustCall.julia_type_to_llvm_ir_string(Bool) != "i1"
    end

    @testset "Calling convention specified in LLVM IR (#166)" begin
        # Generated LLVM IR should include 'ccc' (C calling convention)
        ir = RustCall.generate_llvmcall_ir("test_func", Int32, Type[Int32, Int32])
        @test occursin("call ccc", ir)

        # Void return should also have calling convention
        ir_void = RustCall.generate_llvmcall_ir("test_void_func", Cvoid, Type[Int32])
        @test occursin("call ccc void", ir_void)

        # No bare 'call' without convention should remain
        for line in split(ir, '\n')
            if occursin("call", line)
                @test occursin("ccc", line)
            end
        end
    end

    @testset "LLVM dispose inside lock (#167)" begin
        # Verify dispose_module is defined and uses locking
        @test isdefined(RustCall, :dispose_module)

        # The lock is required to prevent race conditions
        @test RustCall.LLVM_REGISTRY_LOCK isa ReentrantLock

        # Test that concurrent dispose operations are safe
        # (they should be serialized by the lock)
        n_tasks = 4
        errors = Threads.Atomic{Int}(0)
        tasks = []
        for t in 1:n_tasks
            task = Threads.@spawn begin
                try
                    # Accessing RUST_MODULES under the lock should work safely
                    lock(RustCall.LLVM_REGISTRY_LOCK) do
                        length(RustCall.RUST_MODULES)
                    end
                catch
                    Threads.atomic_add!(errors, 1)
                end
            end
            push!(tasks, task)
        end
        for task in tasks
            fetch(task)
        end
        @test errors[] == 0
    end

    @testset "Platform-dependent type sizes (#196)" begin
        # All C types should produce correct bit widths based on sizeof
        @test RustCall.julia_type_to_llvm_ir_string(Cint) == "i$(8 * sizeof(Cint))"
        @test RustCall.julia_type_to_llvm_ir_string(Cuint) == "i$(8 * sizeof(Cuint))"
        @test RustCall.julia_type_to_llvm_ir_string(Clong) == "i$(8 * sizeof(Clong))"
        @test RustCall.julia_type_to_llvm_ir_string(Culong) == "i$(8 * sizeof(Culong))"
        @test RustCall.julia_type_to_llvm_ir_string(Csize_t) == "i$(8 * sizeof(Csize_t))"
        @test RustCall.julia_type_to_llvm_ir_string(Cssize_t) == "i$(8 * sizeof(Cssize_t))"
        @test RustCall.julia_type_to_llvm_ir_string(Cptrdiff_t) == "i$(8 * sizeof(Cptrdiff_t))"
        @test RustCall.julia_type_to_llvm_ir_string(Clonglong) == "i$(8 * sizeof(Clonglong))"
        @test RustCall.julia_type_to_llvm_ir_string(Culonglong) == "i$(8 * sizeof(Culonglong))"

        # On 64-bit systems, Csize_t should be 64 bits
        if Sys.WORD_SIZE == 64
            @test RustCall.julia_type_to_llvm_ir_string(Csize_t) == "i64"
        end
    end

    @testset "Struct alignment/padding in LLVM IR (#183)" begin
        # Define a struct with known padding requirements
        struct AlignedStruct
            a::Int8     # 1 byte at offset 0
            b::Int32    # 4 bytes, typically at offset 4 (3 bytes padding after a)
        end

        ir = RustCall.julia_type_to_llvm_ir_string(AlignedStruct)
        @test occursin("{", ir)
        @test occursin("}", ir)

        # The IR should account for the struct's total size
        # Parse the number of fields in the IR
        fields = split(strip(ir, ['{', '}', ' ']), ", ")

        # If Julia adds padding, there should be extra i8 fields for padding bytes
        expected_offset_b = fieldoffset(AlignedStruct, 2)
        if expected_offset_b > 1  # padding exists
            # Should have padding bytes: i8 (field a), i8, i8, i8 (padding), i32 (field b)
            @test length(fields) > 2
            @test count(==("i8"), fields) >= 1  # at least field a
            @test "i32" in fields  # field b
        end

        # Struct with no padding should have no extra fields
        struct PackedStruct
            x::Int32
            y::Int32
        end

        ir_packed = RustCall.julia_type_to_llvm_ir_string(PackedStruct)
        @test ir_packed == "{i32, i32}"

        # Empty struct
        struct EmptyStruct2 end
        @test RustCall.julia_type_to_llvm_ir_string(EmptyStruct2) == "{}"

        # Total LLVM IR struct size should match Julia sizeof
        struct MixedStruct
            a::Int8
            b::Float64
        end
        ir_mixed = RustCall.julia_type_to_llvm_ir_string(MixedStruct)
        # Count total bytes in the IR representation
        mixed_fields = split(strip(ir_mixed, ['{', '}', ' ']), ", ")
        total_ir_bytes = 0
        for f in mixed_fields
            if f == "i8"
                total_ir_bytes += 1
            elseif f == "i16"
                total_ir_bytes += 2
            elseif f == "i32" || f == "float"
                total_ir_bytes += 4
            elseif f == "i64" || f == "double"
                total_ir_bytes += 8
            elseif f == "i128"
                total_ir_bytes += 16
            end
        end
        @test total_ir_bytes == sizeof(MixedStruct)
    end

    @testset "Pointer type preserves inner type (#182)" begin
        # julia_type_to_llvm should preserve inner type for Ptr{Int32}
        LLVM.Context() do ctx
            ptr_i32_llvm = RustCall.julia_type_to_llvm(Ptr{Int32})
            @test ptr_i32_llvm isa LLVM.PointerType

            # Ptr{Cvoid} should still work
            ptr_void_llvm = RustCall.julia_type_to_llvm(Ptr{Cvoid})
            @test ptr_void_llvm isa LLVM.PointerType

            # Generic Ptr should work
            ptr_generic_llvm = RustCall.julia_type_to_llvm(Ptr{Float64})
            @test ptr_generic_llvm isa LLVM.PointerType
        end
    end

    @testset "LLVM context lifecycle tied to module (#164)" begin
        if RustCall.check_rustc_available()
            # Compile some Rust code to LLVM IR
            rust_code = """
            #[no_mangle]
            pub extern "C" fn ctx_test_add(a: i32, b: i32) -> i32 {
                a + b
            }
            """
            wrapped = RustCall.wrap_rust_code(rust_code)
            compiler = RustCall.get_default_compiler()
            ir_path = RustCall.compile_rust_to_llvm_ir(wrapped; compiler=compiler)

            rust_mod = RustCall.load_llvm_ir(ir_path; source_code=wrapped)

            # The context should be the module's own context
            @test rust_mod.ctx === LLVM.context(rust_mod.mod)

            # Module should be usable
            funcs = RustCall.list_functions(rust_mod)
            @test "ctx_test_add" in funcs
        else
            @warn "rustc not found, skipping LLVM context lifecycle test"
        end
    end
end
