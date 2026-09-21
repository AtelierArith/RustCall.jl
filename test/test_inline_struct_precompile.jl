using Test
using RustCall

# An inline `#[julia]` struct's constructor and static methods must find their
# own module's library, exactly as a free `#[julia]` function does (#443):
#
# * as the first Rust call of a fresh process that loads a precompiled package,
#   when nothing has restored that module's recorded blocks yet;
# * when another module has compiled a block defining the same struct since,
#   so the session's "current library" belongs to someone else.
#
# Both are only visible in a child process loading a precompiled package: an
# `include` runs the block, which sets the session's current library and
# restores nothing.

@testset "inline struct constructors and static methods resolve their own module (#443)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        mktempdir() do root
            source(value) = """
                #[julia]
                pub struct Counter443 { n: i64 }
                impl Counter443 {
                    pub fn new() -> Self { Counter443 { n: $value } }
                    pub fn get(&self) -> i64 { self.n }
                    pub fn origin() -> i64 { $value }
                    pub fn label() -> String { format!("counter-{}", $value) }
                    pub fn checked(k: i64) -> Result<i64, String> {
                        if k < 0 { Err(format!("negative {}", k)) } else { Ok(k + $value) }
                    }
                }
                """
            for (name, uuid, value) in (("InlineCtor443A", "0c8f5c3e-3c2a-4a55-9d0e-4f1a3b6c7d01", 1),
                                        ("InlineCtor443B", "0c8f5c3e-3c2a-4a55-9d0e-4f1a3b6c7d02", 2))
                package = joinpath(root, name)
                mkpath(joinpath(package, "src"))
                write(joinpath(package, "Project.toml"), """
                    name = "$name"
                    uuid = "$uuid"
                    version = "0.1.0"
                    [deps]
                    RustCall = "$(Base.PkgId(RustCall).uuid)"
                    """)
                write(joinpath(package, "src", "$name.jl"),
                      "module $name\nusing RustCall\nrust\"\"\"\n$(source(value))\"\"\"\nend\n")
            end

            sep = Sys.iswindows() ? ";" : ":"
            fresh(script) = withenv("JULIA_LOAD_PATH" => join((pkgdir(RustCall), root, "@stdlib"), sep),
                                    "RUSTCALL_CACHE_DIR" => joinpath(root, "rust-cache"),
                                    "RUSTCALL_SUPPRESS_HELPERS_WARNING" => "1") do
                readchomp(`$(Base.julia_cmd()) --startup-file=no -e $script`)
            end

            # Precompile both packages (and build their libraries) first.
            @test fresh("using InlineCtor443A, InlineCtor443B; print(\"ok\")") == "ok"

            # The first Rust call of the process is a constructor.
            @test fresh("""
                using InlineCtor443A
                c = InlineCtor443A.Counter443()
                print(InlineCtor443A.get(c))
                """) == "1"

            # ... or a static method, of each return lowering.
            @test fresh("using InlineCtor443A; print(InlineCtor443A.origin(InlineCtor443A.Counter443))") == "1"
            @test fresh("using InlineCtor443A; print(InlineCtor443A.label(InlineCtor443A.Counter443))") == "counter-1"
            @test fresh("""
                using InlineCtor443A, RustCall
                print(RustCall.unwrap(InlineCtor443A.checked(InlineCtor443A.Counter443, 10)))
                """) == "11"

            # Two modules define the same struct; whichever was touched last,
            # each module's constructor and static methods reach its own image.
            @test fresh("""
                using InlineCtor443A, InlineCtor443B, RustCall
                A, B = InlineCtor443A, InlineCtor443B
                b = B.Counter443()
                a = A.Counter443()
                print(join((A.get(a), B.get(b),
                            A.origin(A.Counter443), B.origin(B.Counter443),
                            A.label(A.Counter443), B.label(B.Counter443),
                            RustCall.unwrap(A.checked(A.Counter443, 0)),
                            RustCall.unwrap(B.checked(B.Counter443, 0))), " "))
                """) == "1 2 1 2 counter-1 counter-2 1 2"
        end
    end
end
