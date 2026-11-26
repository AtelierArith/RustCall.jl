using Test, RustCall

@testset "Caller-provided pair output (#623)" begin
    mktempdir() do crate
        mkpath(joinpath(crate, "src"))
        runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
        write(joinpath(crate, "Cargo.toml"), """
            [package]
            name = "pair_output"
            version = "0.1.0"
            edition = "2021"
            [lib]
            crate-type = ["cdylib"]
            [dependencies]
            rustcall_julia_macros = { path = "$runtime" }
            """)
        write(joinpath(crate, "src", "lib.rs"), raw"""
            use rustcall_julia_macros::julia;

            #[julia]
            pub fn make_pair_into(x: f64, out: *mut f64) {
                assert!(x.is_finite(), "finite input required");
                let hi = x;
                let lo = x / 8.0;
                unsafe {
                    out.write(hi);
                    out.add(1).write(lo);
                }
            }

            #[julia]
            pub struct PairOwner {
                pub hi: f64,
                pub lo: f64,
            }

            #[julia]
            impl PairOwner {
                #[julia]
                pub fn new() -> Self { Self { hi: 0.0, lo: 0.0 } }
            }

            #[julia]
            pub fn make_pair_in_owner(x: f64, out: &mut PairOwner) {
                out.hi = x;
                out.lo = x / 8.0;
            }
            """)
        bindings = Core.eval(@__MODULE__, :(@rust_crate $crate))
        lib = Base.invokelatest(getfield, getfield(bindings, :module_ref), :_LIB_NAME)
        storage = fill(-999.0, 4)
        function pair!(x)
            GC.@preserve storage Base.invokelatest(bindings.make_pair_into, x, pointer(storage, 2))
            return (storage[2], storage[3])
        end
        try
            @test pair!(1.0) == (1.0, 0.125)
            @test pair!(2.0) == (2.0, 0.25)
            @test_throws RustCall.RustPanicError pair!(Inf)
            @test storage == [-999.0, 2.0, 0.25, -999.0]
            Base.invokelatest() do
                owner = bindings.PairOwner()
                try
                    for x in (1.0, 2.0)
                        bindings.make_pair_in_owner(x, owner)
                        @test (owner.hi, owner.lo) == (x, x / 8.0)
                    end
                finally
                    finalize(owner)
                end
            end
        finally
            RustCall.unload_library(lib; close = true)
        end
    end
end
