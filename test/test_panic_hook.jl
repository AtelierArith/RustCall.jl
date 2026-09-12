using Test
using RustCall

# A caught panic is not an incident (#304). The generated wrapper records the
# message in its channel and Julia raises `RustCall.RustPanicError`, but Rust
# runs the panic **hook** before the unwind `catch_unwind` catches, so every
# panic RustCall handles correctly still printed `thread '<unnamed>' panicked
# at ...` to stderr first.
#
# The hook is the only lever — stable Rust has no per-call or thread-scoped way
# to silence one — and a correct hook needs a thread-local depth counter shared
# by every wrapper in the image, because the one installed hook can only see the
# counter it captured. That sharing is why the quiet hook exists exactly where a
# generator writes the whole file (`rustcall_core::codegen::PanicHook`), and why
# a user's hand-written `#[julia]` crate keeps the default hook
# (`docs/src/panics.md`).
#
# Rust writes to file descriptor 2 directly, so `redirect_stderr` to an
# `IOBuffer` cannot see it: every assertion here runs a child process whose
# stderr is a file.

const _PANICKED_AT = "panicked at"

"""
    _run_child(body; threads = 1, env = [])

Run `body` (Julia source) in a child process that uses this checkout, and return
`(exitcode, stdout, stderr)` with stderr captured at the file-descriptor level.
"""
function _run_child(body::AbstractString; threads::Int = 1, env = [])
    dir = mktempdir()
    script = joinpath(dir, "child.jl")
    out_path = joinpath(dir, "out.txt")
    err_path = joinpath(dir, "err.txt")
    write(script, body)
    project = dirname(@__DIR__)
    cmd = `$(Base.julia_cmd()) --project=$(project) --startup-file=no --threads=$(threads) $(script)`
    code = withenv(env...) do
        process = run(pipeline(ignorestatus(cmd); stdout = out_path, stderr = err_path))
        process.exitcode
    end
    return (code, read(out_path, String), read(err_path, String))
end

const _BLOCK = """
using RustCall
rust\"\"\"
#[julia]
pub fn hook_probe_one(n: i32) -> i32 {
    if n < 0 { panic!("hook_probe_one refuses {}", n); }
    n
}

#[julia]
pub fn hook_probe_two(n: i32) -> i32 {
    if n < 0 { panic!("hook_probe_two refuses {}", n); }
    n
}
\"\"\"
"""

@testset "quiet panic hook" begin
    @testset "the two symbol names agree with the generator" begin
        # Julia resolves what `rustcall_core::codegen` exports; a rename on
        # either side would show up as a hook that is never installed, which is
        # silent by nature.
        codegen = read(joinpath(dirname(@__DIR__), "deps", "rustcall_core", "src",
                                "codegen.rs"), String)
        for symbol in (RustCall.QUIET_PANIC_INSTALL_SYMBOL,
                       RustCall.QUIET_PANIC_UNINSTALL_SYMBOL)
            @test occursin("\"$(symbol)\"", codegen)
        end
    end

    @testset "the image decides, not the policy" begin
        # `__rustcall_install_panic_hook` exists exactly when RustCall generated the
        # source in full, so the installer is resolved on the handle. A policy flag
        # was tried first and was wrong: every `@rust_crate` module loads with
        # `crate_direct_policy()`, the generated PyO3 wrapper crate included, so
        # the flag excluded the one wrapper flavour that does carry a hook
        # (#388 review).
        @test !any(name -> occursin("quiet_panic_hook", name),
                   string.(fieldnames(RustCall.LoadPolicy)))
        loadpolicy = read(joinpath(dirname(@__DIR__), "src", "loadpolicy.jl"), String)
        @test occursin("Libdl.dlsym(handle, QUIET_PANIC_INSTALL_SYMBOL", loadpolicy)
        # Nothing is installed into, or removed from, a handle that has no such
        # symbol.
        @test RustCall.install_quiet_panic_hook!(C_NULL) === false
        @test RustCall.uninstall_quiet_panic_hook!(C_NULL) === false
    end

    @testset "no user item can be mistaken for the installer" begin
        # Julia calls whatever it finds under the installer's name as
        # `extern "C" fn()`. A wrapper is `rustcall_<stem>`, so
        # `#[julia] fn install_panic_hook` exports `rustcall_install_panic_hook`
        # — which is what the loader used to look up, so loading such a crate
        # would have called a user function through the wrong signature
        # (#388 review). The doubled prefix makes the collision unreachable: every
        # name the scheme derives is `rustcall_<stem>` or `<stem>_<known suffix>`,
        # and `_hook` is not one of the suffixes.
        for symbol in (RustCall.QUIET_PANIC_INSTALL_SYMBOL,
                       RustCall.QUIET_PANIC_UNINSTALL_SYMBOL)
            @test startswith(string(symbol), "__rustcall_")
        end
        expanded = RustCall.expand_inline("""
        #[julia]
        pub fn install_panic_hook(n: i32) -> i32 { n }

        #[julia]
        pub fn uninstall_panic_hook(n: i32) -> i32 { n }
        """)
        exported = [f["symbol"] for f in expanded.manifest["functions"]]
        # The scheme really does want these two names...
        @test "rustcall_install_panic_hook" in exported
        @test "rustcall_uninstall_panic_hook" in exported
        # ...and neither is the name the loader resolves.
        for symbol in (RustCall.QUIET_PANIC_INSTALL_SYMBOL,
                       RustCall.QUIET_PANIC_UNINSTALL_SYMBOL)
            @test !(string(symbol) in exported)
            # Defined exactly once in the file, by the hook and with no arguments.
            @test count("pub extern \"C\" fn $(symbol)()", expanded.source) == 1
        end
    end

    @testset "the prefer-dynamic decision reads flags, not substrings" begin
        # `-C prefer-dynamic=no` asks for the opposite, and the flag arrives in
        # any of four spellings plus the \x1f-separated encoded form.
        for flags in ("-C prefer-dynamic", "-Cprefer-dynamic", "--codegen prefer-dynamic",
                      "--codegen=prefer-dynamic", "-C\x1fprefer-dynamic",
                      "-C opt-level=3 -C prefer-dynamic", "-C prefer-dynamic=yes")
            @test RustCall.prefer_dynamic_flag(flags)
        end
        for flags in ("", "-C opt-level=3", "-C prefer-dynamic=no",
                      "-C prefer-dynamic=off", "-C prefer-dynamic=false",
                      "-C target-cpu=native")
            @test !RustCall.prefer_dynamic_flag(flags)
        end
        # Cargo honours the per-target variable too, and the decision is asked of
        # the environment the artifact was *built* under when one was recorded.
        @test RustCall.prefer_dynamic_build(;
            env = Dict("CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS" => "-C prefer-dynamic"))
        @test RustCall.prefer_dynamic_build("RUSTFLAGS=-C prefer-dynamic\nOTHER=1")
        @test !RustCall.prefer_dynamic_build(; env = Dict("RUSTFLAGS" => "-C prefer-dynamic=no"))
        @test !RustCall.quiet_panic_hooks_enabled("RUSTFLAGS=-C prefer-dynamic")
        @test RustCall.quiet_panic_hooks_enabled(; env = Dict{String, String}())
    end

    if !RustCall.check_rustc_available()
        @info "Skipping the quiet panic hook: no Rust toolchain"
        @test_skip "needs rustc"
    else
        @testset "a panicking #[julia] function prints nothing and still raises" begin
            code, out, err = _run_child("""
            $(_BLOCK)
            println("installs=", RustCall.QUIET_PANIC_HOOK_INSTALLS[])
            try
                hook_probe_one(Int32(-1))
                println("NOT RAISED")
            catch e
                println("kind=", typeof(e))
                println("message=", sprint(showerror, e))
            end
            """)
            @test code == 0
            @test occursin("installs=1", out)
            @test occursin("kind=RustCall.RustPanicError", out)
            # The message survives in full...
            @test occursin("hook_probe_one refuses -1", out)
            # ...and stderr says nothing about it.
            @test !occursin(_PANICKED_AT, err)
        end

        @testset "two wrappers first called from two threads are both quiet" begin
            # Nothing is installed lazily — `load_artifact!` installs once, per
            # image, before any wrapper can run — so there is no first call for
            # a race to lose. This asserts the property that design buys.
            code, out, err = _run_child("""
            $(_BLOCK)
            one = Ref{Any}(:not_raised)
            two = Ref{Any}(:not_raised)
            ready = Threads.Atomic{Int}(0)
            first_task = Threads.@spawn begin
                Threads.atomic_add!(ready, 1)
                while ready[] < 2; end
                try; hook_probe_one(Int32(-3)); catch e; one[] = typeof(e); end
            end
            second_task = Threads.@spawn begin
                Threads.atomic_add!(ready, 1)
                while ready[] < 2; end
                try; hook_probe_two(Int32(-3)); catch e; two[] = typeof(e); end
            end
            wait(first_task); wait(second_task)
            println("one=", one[], " two=", two[])
            """; threads = 2)
            @test code == 0
            @test occursin("one=RustCall.RustPanicError two=RustCall.RustPanicError", out)
            @test !occursin(_PANICKED_AT, err)
        end

        @testset "the escape hatch brings the default hook back" begin
            # `RUSTCALL_PANIC_HOOK=default` is the answer to the one thing the
            # hook costs: a panic inside the artifact but outside any wrapper
            # boundary has no channel to be read from, so its message is gone.
            code, out, err = _run_child("""
            $(_BLOCK)
            println("installs=", RustCall.QUIET_PANIC_HOOK_INSTALLS[])
            try; hook_probe_one(Int32(-1)); catch; end
            """; env = ["RUSTCALL_PANIC_HOOK" => "default"])
            @test code == 0
            @test occursin("installs=0", out)
            @test occursin(_PANICKED_AT, err)
        end

        @testset "a prefer-dynamic build keeps the default hook" begin
            # With `-C prefer-dynamic` the `std` that owns the hook registry is
            # shared between images, so a hook installed from a cdylib can
            # outlive the cdylib and a later panic anywhere would jump into
            # unmapped code. The decision is taken from the build environment,
            # which is part of every artifact's identity.
            code, out, _ = _run_child("""
            using RustCall
            println("prefer_dynamic=", RustCall.prefer_dynamic_build())
            println("enabled=", RustCall.quiet_panic_hooks_enabled())
            """; env = ["RUSTFLAGS" => "-C prefer-dynamic"])
            @test code == 0
            @test occursin("prefer_dynamic=true", out)
            @test occursin("enabled=false", out)

            code, out, _ = _run_child("""
            using RustCall
            println("prefer_dynamic=", RustCall.prefer_dynamic_build())
            println("enabled=", RustCall.quiet_panic_hooks_enabled())
            """; env = ["CARGO_ENCODED_RUSTFLAGS" => "-C\x1fprefer-dynamic"])
            @test code == 0
            @test occursin("prefer_dynamic=true", out)
            @test occursin("enabled=false", out)
        end

        @testset "a close that is not the last reference keeps the hook" begin
            # `close_artifact_handle!` decrements the loader reference count and
            # only the last one unmaps the image. Removing the hook on an earlier
            # decrement un-silences an image that is still mapped and in use —
            # and for good, because the generated installer is `Once`-guarded
            # (#388 review).
            code, out, err = _run_child("""
            using RustCall
            source = \"\"\"
            #[julia]
            pub fn dup_boom(n: i32) -> i32 {
                if n < 0 { panic!("dup_boom refuses {}", n); }
                n
            }
            \"\"\"
            expanded = RustCall.expand_inline(source)
            lib = RustCall.compile_rust_to_shared_lib(RustCall.wrap_rust_code(expanded.source))
            policy = RustCall.inline_rustc_policy()
            first_ref = RustCall.load_artifact!(policy, lib; lib_name = "dup_one")
            second_ref = RustCall.load_artifact!(policy, lib; lib_name = "dup_two")
            println("one_image=", first_ref.handle == second_ref.handle)
            # The wrapper and its channel, resolved on the handle: this load
            # registered no symbol table, and the point is the image, not the
            # registry.
            using Libdl
            wrapper = Libdl.dlsym(first_ref.handle, :rustcall_dup_boom)
            reader = Libdl.dlsym(first_ref.handle, :rustcall_dup_boom_take_panic)
            function panic_message()
                @ccall \$wrapper(Int32(-1)::Int32)::Int32
                len = @ccall \$reader(C_NULL::Ptr{UInt8}, 0::Csize_t)::Csize_t
                buffer = Vector{UInt8}(undef, len)
                taken = @ccall \$reader(buffer::Ptr{UInt8}, len::Csize_t)::Csize_t
                return String(buffer[1:taken])
            end
            RustCall.close_artifact_handle!(first_ref.handle)
            println("removals_after_first=", RustCall.QUIET_PANIC_HOOK_REMOVALS[])
            println("still_records=", panic_message())
            RustCall.close_artifact_handle!(first_ref.handle)
            println("removals_after_last=", RustCall.QUIET_PANIC_HOOK_REMOVALS[])
            """)
            @test code == 0
            @test occursin("one_image=true", out)
            @test occursin("removals_after_first=0", out)
            @test occursin("still_records=dup_boom panicked: dup_boom refuses -1", out)
            @test occursin("removals_after_last=1", out)
            # The image was still mapped across the first close, so it was still
            # quiet.
            @test !occursin(_PANICKED_AT, err)
        end

        @testset "a hook can be installed again after it was removed" begin
            # An image can be reopened while it is still mapped — a `dlopen` of
            # the same path racing the last `dlclose` — and the reopen's own
            # installer call has to be able to restore the hook. A `Once` could
            # not, which left such an image noisy for the rest of the process
            # (#388 review).
            code, out, err = _run_child("""
            using RustCall, Libdl
            $(_BLOCK)
            handle = only(h for (_, (h, _)) in RustCall.RUST_LIBRARIES
                          if Libdl.dlsym(h, :rustcall_hook_probe_one;
                                         throw_error = false) !== nothing)
            println("removed=", RustCall.uninstall_quiet_panic_hook!(handle))
            try; hook_probe_one(Int32(-1)); catch; end   # prints: no hook
            println("reinstalled=", RustCall.install_quiet_panic_hook!(handle))
            try; hook_probe_one(Int32(-2)); catch; end   # must be quiet again
            println("done")
            """)
            @test code == 0
            @test occursin("removed=true", out)
            @test occursin("reinstalled=true", out)
            @test occursin("done", out)
            # Exactly one line, from the window with no hook: the reinstall took.
            @test count("panicked at", err) == 1
            @test occursin("hook_probe_one refuses -1", err)
            @test !occursin("hook_probe_one refuses -2", err)
        end

        @testset "closing an artifact removes its hook before unmapping it" begin
            # The hook is a closure that lives in the image. std's registry must
            # not still point at it when the image is unmapped — under a shared
            # `std` that would be a jump into freed memory on the next panic
            # anywhere in the process. A second library stays loaded and keeps
            # working across the close.
            code, out, err = _run_child("""
            using RustCall
            rust\"\"\"
            #[julia]
            pub fn hook_close_a(n: i32) -> i32 {
                if n < 0 { panic!("hook_close_a refuses {}", n); }
                n
            }
            \"\"\"
            rust\"\"\"
            #[julia]
            pub fn hook_close_b(n: i32) -> i32 {
                if n < 0 { panic!("hook_close_b refuses {}", n); }
                n
            }
            \"\"\"
            println("installs=", RustCall.QUIET_PANIC_HOOK_INSTALLS[])
            # Find A by a symbol only A exports: the registry is keyed by content
            # hash, so its iteration order says nothing about which block is which
            # — and closing the wrong one would leave this test calling into an
            # image it just closed.
            using Libdl
            owner = only(name for (name, (handle, _)) in RustCall.RUST_LIBRARIES
                         if Libdl.dlsym(handle, :rustcall_hook_close_a;
                                        throw_error = false) !== nothing)
            RustCall.unload_library(owner; close = true)
            println("removals=", RustCall.QUIET_PANIC_HOOK_REMOVALS[])
            # The other image is untouched: it still answers, and its own hook
            # still governs its panics.
            println("b(2)=", hook_close_b(Int32(2)))
            try
                hook_close_b(Int32(-1))
                println("NOT RAISED")
            catch e
                println("kind=", typeof(e))
            end
            """)
            @test code == 0
            @test occursin("installs=2", out)
            @test occursin("removals=1", out)
            @test occursin("b(2)=2", out)
            @test occursin("kind=RustCall.RustPanicError", out)
            @test !occursin(_PANICKED_AT, err)
        end
    end
end
