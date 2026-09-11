# Cost of always asking Cargo for current cfg (#291).
# Run: julia --project benchmark/benchmarks_cfg_probe.jl
# An isolated, dependency-free crate: not a prediction for large workspaces.
include(joinpath(@__DIR__, "setup.jl"))

using RustCall, Statistics

mktempdir() do root
    mkpath(joinpath(root, "src"))
    write(joinpath(root, "Cargo.toml"), """
        [package]
        name = "cfg_probe_cost291"
        version = "0.1.0"
        edition = "2021"
        """)
    write(joinpath(root, "src", "lib.rs"), "pub fn value() -> i32 { 1 }\n")
    write(joinpath(root, "build.rs"), raw"""
        fn main() {
            println!("cargo:rerun-if-changed=cfg.flag");
            let flag = std::fs::read_to_string("cfg.flag").unwrap();
            println!("cargo:rustc-cfg={}", flag.trim());
        }
        """)
    write(joinpath(root, "cfg.flag"), "first_cfg")
    cold = @elapsed result = RustCall._crate_build_cfg_text(root)
    @assert occursin("first_cfg", result)
    times = [@elapsed(RustCall._crate_build_cfg_text(root)) for _ in 1:10]
    write(joinpath(root, "cfg.flag"), "second_cfg")
    changed = @elapsed result = RustCall._crate_build_cfg_text(root)
    @assert occursin("second_cfg", result) && !occursin("first_cfg", result)
    println((cold_seconds=cold, warm_median_seconds=median(times),
             warm_min_seconds=minimum(times), warm_max_seconds=maximum(times),
             changed_seconds=changed, warm_samples=length(times)))
end
