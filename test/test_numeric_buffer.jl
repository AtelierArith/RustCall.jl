using Test, RustCall

rust"""
#[julia]
pub fn numeric_first(data: *const f64, len: usize) -> f64 {
    if len == 0 { 0.0 } else { unsafe { *data } }
}
#[julia]
pub fn numeric_sum(data: *const f64, len: usize) -> f64 {
    if len == 0 { return 0.0; }
    unsafe { std::slice::from_raw_parts(data, len) }.iter().sum()
}
#[julia]
pub fn numeric_complex_re(data: *const f64, len: usize) -> f64 {
    if len == 0 { return 0.0; }
    unsafe { std::slice::from_raw_parts(data, len * 2) }.chunks_exact(2).map(|z| z[0]).sum()
}
#[julia]
pub fn numeric_complex_re_f32(data: *const f32, len: usize) -> f32 {
    if len == 0 { return 0.0; }
    unsafe { std::slice::from_raw_parts(data, len * 2) }.chunks_exact(2).map(|z| z[0]).sum()
}
#[julia]
pub fn numeric_panic(data: *mut f64, len: usize) {
    if len > 0 { unsafe { *data = 123.0; } }
    panic!("numeric panic");
}
#[julia]
pub fn numeric_allocate() -> *mut f64 {
    Box::into_raw(vec![2.0_f64, 4.0, 6.0].into_boxed_slice()) as *mut f64
}
#[julia]
pub fn numeric_free(data: *mut f64, len: usize) {
    if !data.is_null() { unsafe { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(data, len))); } }
}
#[julia]
pub fn numeric_scale(data: *mut f64, len: usize) {
    if len == 0 { return; }
    for v in unsafe { std::slice::from_raw_parts_mut(data, len) } { *v *= 2.0; }
}
"""

struct ReverseIterationVector <: AbstractVector{Float64}
    data::Vector{Float64}
end
Base.size(x::ReverseIterationVector) = size(x.data)
Base.getindex(x::ReverseIterationVector, i::Int) = x.data[i]
Base.setindex!(x::ReverseIterationVector, v, i::Int) = (x.data[i] = v)
Base.iterate(x::ReverseIterationVector, i=length(x)) = i == 0 ? nothing : (x[i], i - 1)

@testset "Scoped numeric buffers" begin
    @test_throws ArgumentError RustCall.with_numeric_buffer(identity, Float64[1]; element_type=Float32)
    @test_throws ArgumentError RustCall.with_numeric_buffer(identity, Rational{Int}[1//2])
    @test_throws ArgumentError RustCall.with_numeric_buffer(identity, Int128[1]; element_type=Int128)
    @test RustCall.with_numeric_buffer(Float64[3]; element_type=Float64) do ptr, len
        numeric_first(ptr, len)
    end == 3.0
    reverse_iter = ReverseIterationVector([1.0, 2.0, 3.0])
    RustCall.with_numeric_buffer(reverse_iter; write=true) do ptr, len
        @test numeric_first(ptr, len) == 1.0
        numeric_scale(ptr, len)
    end
    @test reverse_iter.data == [2.0, 4.0, 6.0]
    x = reshape(collect(1.0:12.0), 3, 4)
    view_x = @view x[1:2:3, 2:3]
    @test RustCall.with_numeric_buffer(view_x) do ptr, len
        GC.gc()
        numeric_sum(ptr, len)
    end == sum(view_x)
    RustCall.with_numeric_buffer(view_x; write=true) do ptr, len
        GC.gc()
        numeric_scale(ptr, len)
    end
    @test view_x == [8.0 14.0; 12.0 18.0]
    snapshot = copy(x)
    @test_throws ErrorException RustCall.with_numeric_buffer(view_x; write=true) do ptr, len
        numeric_scale(ptr, len)
        error("reject")
    end
    @test x == snapshot
    @test_throws RustCall.RustPanicError RustCall.with_numeric_buffer(view_x; write=true) do ptr, len
        numeric_panic(ptr, len)
    end
    @test x == snapshot
    @test RustCall.with_numeric_buffer(Float64[]) do ptr, len
        @test ptr != C_NULL
        numeric_sum(ptr, len)
    end == 0.0
    complex_values = ComplexF64[1 + 2im, 3 - 4im]
    @test RustCall.with_numeric_buffer(complex_values) do ptr, len
        numeric_complex_re(Ptr{Float64}(ptr), len)
    end == 4.0
    @test RustCall.with_numeric_buffer(ComplexF32[1+2im, 3-4im]; element_type=ComplexF32) do ptr, len
        numeric_complex_re_f32(Ptr{Float32}(ptr), len)
    end == 4.0f0
    @test_throws ArgumentError RustCall.with_numeric_buffer(identity, BigFloat[1])
end

@testset "Owned numeric buffer" begin
    p = numeric_allocate()
    freed = Ref(false)
    result = RustCall.copy_owned_numeric_buffer(p, 3) do ptr, len
        numeric_free(ptr, UInt(len))
        freed[] = true
    end
    @test result == [2.0, 4.0, 6.0]
    @test freed[]
    calls = Ref(0)
    @test_throws ArgumentError RustCall.copy_owned_numeric_buffer(Ptr{Float64}(C_NULL), 3) do _, _
        calls[] += 1
    end
    @test calls[] == 1
    @test RustCall.copy_owned_numeric_buffer(Ptr{Float64}(C_NULL), 0) do _, _
        nothing
    end == Float64[]
end
