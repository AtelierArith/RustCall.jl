### A Pluto.jl notebook ###
# v0.20.19

using Markdown
using InteractiveUtils

# ╔═╡ 77e370c4-f780-11f0-a1ec-43091b736353
begin
	using Pkg
	Pkg.activate(dirname(dirname(@__DIR__)))
	using LastCall
end

# ╔═╡ 422f374a-81c7-4096-b02e-5b51299d56b0
begin
	rust"""
	// cargo-deps: ndarray = "0.15"
	
	use ndarray::Array1;

	#[julia]
	fn compute_sum(data: *const f64, len: usize) -> f64 {
	    unsafe {
	        let slice = std::slice::from_raw_parts(data, len);
	        let arr = Array1::from_vec(slice.to_vec());
	        arr.sum()
	    }
	}
	"""
	
	# Call with Julia array
	data = [1.0, 2.0, 3.0, 4.0, 5.0]
	result = compute_sum(pointer(data), length(data))
	println(result)  # => 15.0
end

# ╔═╡ Cell order:
# ╠═77e370c4-f780-11f0-a1ec-43091b736353
# ╠═422f374a-81c7-4096-b02e-5b51299d56b0
