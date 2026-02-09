# Tests for type system, memory management, and safety fixes
# Issues: #174, #175, #176, #178, #181, #191, #193, #202

using RustCall
using Test

@testset "Types/Memory/Safety Fixes" begin

    # #202: julia_string_to_rust uses ncodeunits instead of sizeof
    @testset "julia_string_to_rust uses ncodeunits (#202)" begin
        # For Julia String, sizeof(s) == ncodeunits(s) for all valid strings.
        # Test with ASCII strings
        rs = RustCall.julia_string_to_rust("hello")
        @test rs isa RustCall.RustStr
        @test rs.len == UInt(5)
        @test rs.len == UInt(ncodeunits("hello"))

        # Test with multi-byte UTF-8 strings
        rs_utf8 = RustCall.julia_string_to_rust("日本語")
        @test rs_utf8.len == UInt(ncodeunits("日本語"))
        @test rs_utf8.len == UInt(9)  # 3 chars × 3 bytes each

        # Test with emoji (4-byte UTF-8)
        rs_emoji = RustCall.julia_string_to_rust("🦀")
        @test rs_emoji.len == UInt(ncodeunits("🦀"))
        @test rs_emoji.len == UInt(4)

        # Test empty string
        rs_empty = RustCall.julia_string_to_rust("")
        @test rs_empty.ptr == C_NULL
        @test rs_empty.len == UInt(0)

        # Verify sizeof and ncodeunits are equivalent for String
        for s in ["hello", "日本語", "🦀", "mixed αβγ 123", ""]
            @test sizeof(s) == ncodeunits(s)
        end
    end

    # #193: Integer overflow in result_to_exception
    @testset "result_to_exception validates Int32 range (#193)" begin
        # Value within Int32 range should use the value as error code
        int_err = RustCall.RustResult{String, Int32}(false, Int32(42))
        try
            RustCall.result_to_exception(int_err)
            @test false  # should not reach here
        catch e
            @test e isa RustCall.RustError
            @test e.code == Int32(42)
            @test e.original_error == Int32(42)
        end

        # Int64 value within Int32 range should still work
        int64_err = RustCall.RustResult{String, Int64}(false, Int64(100))
        try
            RustCall.result_to_exception(int64_err)
            @test false
        catch e
            @test e isa RustCall.RustError
            @test e.code == Int32(100)
            @test e.original_error == Int64(100)
        end

        # Int64 value exceeding Int32 range should fallback to -1
        big_err = RustCall.RustResult{String, Int64}(false, Int64(3_000_000_000))
        try
            RustCall.result_to_exception(big_err)
            @test false
        catch e
            @test e isa RustCall.RustError
            @test e.code == Int32(-1)  # Fallback code for overflow
            @test e.original_error == Int64(3_000_000_000)
        end

        # Negative Int64 value exceeding Int32 range
        neg_big_err = RustCall.RustResult{String, Int64}(false, Int64(-3_000_000_000))
        try
            RustCall.result_to_exception(neg_big_err)
            @test false
        catch e
            @test e isa RustCall.RustError
            @test e.code == Int32(-1)
            @test e.original_error == Int64(-3_000_000_000)
        end

        # Boundary values that fit
        min_err = RustCall.RustResult{String, Int64}(false, Int64(typemin(Int32)))
        try
            RustCall.result_to_exception(min_err)
            @test false
        catch e
            @test e.code == typemin(Int32)
        end

        max_err = RustCall.RustResult{String, Int64}(false, Int64(typemax(Int32)))
        try
            RustCall.result_to_exception(max_err)
            @test false
        catch e
            @test e.code == typemax(Int32)
        end

        # Ok result should still return value normally
        ok_result = RustCall.RustResult{Int32, Int64}(true, Int32(99))
        @test RustCall.result_to_exception(ok_result) == Int32(99)
    end

    # #191: RustResult/RustOption FFI compatibility documentation
    @testset "RustResult/RustOption FFI types exist (#191)" begin
        # Verify C-compatible FFI types exist alongside Julia types
        @test isdefined(RustCall, :CRustResult)
        @test isdefined(RustCall, :CRustOption)
        @test isdefined(RustCall, :RustResult)
        @test isdefined(RustCall, :RustOption)

        # CRustResult should have C-compatible fields
        cr = RustCall.CRustResult(UInt8(1), Ptr{Cvoid}(0))
        @test cr.is_ok == UInt8(1)
        @test cr.value == Ptr{Cvoid}(0)

        # CRustOption should have C-compatible fields
        co = RustCall.CRustOption(UInt8(1), Ptr{Cvoid}(0))
        @test co.is_some == UInt8(1)
        @test co.value == Ptr{Cvoid}(0)

        # RustResult and RustOption still work with Union types (Julia-side)
        ok = RustCall.RustResult{Int32, String}(true, Int32(5))
        @test RustCall.unwrap(ok) == Int32(5)

        some = RustCall.RustOption{Int32}(true, Int32(10))
        @test RustCall.unwrap(some) == Int32(10)
    end

    # #181: Finalizer race condition - ownership types have drop_lock
    @testset "Ownership types have drop_lock for synchronization (#181)" begin
        # RustBox has drop_lock
        box = RustCall.RustBox{Int32}(Ptr{Cvoid}(UInt(0x1000)))
        @test hasproperty(box, :drop_lock)
        @test box.drop_lock isa ReentrantLock
        box.dropped = true  # prevent finalizer from running

        # RustRc has drop_lock
        rc = RustCall.RustRc{Int32}(Ptr{Cvoid}(UInt(0x2000)))
        @test hasproperty(rc, :drop_lock)
        @test rc.drop_lock isa ReentrantLock
        rc.dropped = true

        # RustArc has drop_lock
        arc = RustCall.RustArc{Int32}(Ptr{Cvoid}(UInt(0x3000)))
        @test hasproperty(arc, :drop_lock)
        @test arc.drop_lock isa ReentrantLock
        arc.dropped = true

        # RustVec has drop_lock
        vec = RustCall.RustVec{Int32}(Ptr{Cvoid}(UInt(0x4000)), UInt(5), UInt(10))
        @test hasproperty(vec, :drop_lock)
        @test vec.drop_lock isa ReentrantLock
        vec.dropped = true

        # Each object gets its own lock instance
        box2 = RustCall.RustBox{Int32}(Ptr{Cvoid}(UInt(0x5000)))
        @test box.drop_lock !== box2.drop_lock
        box2.dropped = true
    end

    # #175: GC.@preserve in RustVec getindex/setindex!
    @testset "RustVec operations use GC.@preserve (#175)" begin
        # Create a real data buffer for testing
        data = Int32[10, 20, 30, 40, 50]
        GC.@preserve data begin
            ptr = Ptr{Cvoid}(pointer(data))
            vec = RustCall.RustVec{Int32}(ptr, UInt(5), UInt(5))

            # getindex should work (now protected by GC.@preserve internally)
            @test vec[1] == 10
            @test vec[3] == 30
            @test vec[5] == 50

            # setindex! should work (now protected by GC.@preserve internally)
            vec[2] = Int32(99)
            @test vec[2] == 99
            @test data[2] == 99  # Verify write-through

            # Bounds checking still works
            @test_throws BoundsError vec[0]
            @test_throws BoundsError vec[6]

            vec.dropped = true
        end
    end

    # #178: IOBuffer resource leak in compiler error paths
    @testset "IOBuffer properly closed in compiler error paths (#178)" begin
        if RustCall.check_rustc_available()
            # Invalid code should throw CompilationError but not leak IOBuffer
            invalid_code = """
            #[no_mangle]
            pub extern "C" fn bad_syntax( -> i32 { 42 }
            """
            compiler = RustCall.RustCompiler(debug_mode=false)

            # compile_rust_to_llvm_ir error path
            @test_throws RustCall.CompilationError RustCall.compile_rust_to_llvm_ir(invalid_code; compiler=compiler)

            # compile_rust_to_shared_lib error path
            @test_throws RustCall.CompilationError RustCall.compile_rust_to_shared_lib(invalid_code; compiler=compiler)

            # Valid code should still compile (IOBuffer closed on success path too)
            valid_code = """
            #[no_mangle]
            pub extern "C" fn iobuf_test() -> i32 { 42 }
            """
            lib_path = RustCall.compile_rust_to_shared_lib(valid_code; compiler=compiler)
            @test isfile(lib_path)
            rm(dirname(lib_path), recursive=true, force=true)
        else
            @warn "rustc not found, skipping IOBuffer leak test"
        end
    end

    # #176: Deferred drop queue has configurable limit
    @testset "Deferred drop queue has configurable max size (#176)" begin
        # MAX_DEFERRED_DROPS exists and has a default
        @test isdefined(RustCall, :MAX_DEFERRED_DROPS)
        @test RustCall.get_max_deferred_drops() > 0
        @test RustCall.get_max_deferred_drops() == 1000  # default

        # set_max_deferred_drops works
        old_max = RustCall.get_max_deferred_drops()
        RustCall.set_max_deferred_drops(500)
        @test RustCall.get_max_deferred_drops() == 500

        # Must be positive
        @test_throws ErrorException RustCall.set_max_deferred_drops(0)
        @test_throws ErrorException RustCall.set_max_deferred_drops(-1)

        # Restore original
        RustCall.set_max_deferred_drops(old_max)
        @test RustCall.get_max_deferred_drops() == old_max
    end

    # #174: Generic drop!() in types.jl is properly documented as fallback
    @testset "drop!() delegates to memory.jl methods (#174)" begin
        # When Rust helpers are NOT available, drop! should mark as dropped
        # (ptr may not be nulled because it's recorded in DEFERRED_DROPS)
        if !RustCall.is_rust_helpers_available()
            box = RustCall.RustBox{Int32}(Ptr{Cvoid}(UInt(0xABCD)))
            @test !box.dropped
            RustCall.drop!(box)
            @test box.dropped
            # ptr is deferred for later cleanup, not necessarily nulled
        end

        # The type-specific drop! methods in memory.jl should exist
        @test hasmethod(RustCall.drop!, Tuple{RustCall.RustBox{Int32}})
        @test hasmethod(RustCall.drop!, Tuple{RustCall.RustRc{Int32}})
        @test hasmethod(RustCall.drop!, Tuple{RustCall.RustArc{Int32}})
        @test hasmethod(RustCall.drop!, Tuple{RustCall.RustVec{Int32}})

        # drop_rust_box, drop_rust_rc, drop_rust_arc, drop_rust_vec should exist
        @test isdefined(RustCall, :drop_rust_box)
        @test isdefined(RustCall, :drop_rust_rc)
        @test isdefined(RustCall, :drop_rust_arc)
        @test isdefined(RustCall, :drop_rust_vec)

        # Clean up deferred drops from this test
        lock(RustCall.DEFERRED_DROPS_LOCK) do
            filter!(d -> d.ptr != Ptr{Cvoid}(UInt(0xABCD)), RustCall.DEFERRED_DROPS)
        end
    end
end
