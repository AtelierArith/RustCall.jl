# Component tests loaded by test_regressions.jl.

# #246: a returned Rust `String` is a `(ptr, len, cap)` buffer the caller must
# hand back to the library that allocated it. It was read as a `Cstring` (the
# wrong shape) or as `Any` (no shape at all), and never released.
@testset "#246: a String field is an owned buffer on both wrapper flavours" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        info = only(RustCall.manifest_struct_infos(RustCall.extract_manifest("""
        use rustcall_julia_macros::julia;
        #[julia]
        pub struct Rc246Counter { count: u32, name: String }
        """; mode = "crate")))

        # The manifest, not the spelling, says the getter is lowered.
        @test info.field_abis["name"] == "string"
        c = RustCall._ffi_field_return(info, "name", "String")
        @test RustCall.ffi_owned_string_return(c)
        @test c.ownership === :owned_by_rust
        @test c.free_symbol == "Rc246Counter_free_rust_string"

        # Both crate-path generators check the raw buffer's panic channel before
        # copying it and release it through the contract's symbol. Previously this branch read
        # `call_rust_function(ptr, Any, ...)` and leaked.
        # Both spell Base and RustCall through names no crate item can take
        # (#528); compared here without them.
        unqualified(s) = replace(s, "rustcall′Base." => "", "rustcall′RustCall." => "",
                                 "Base." => "", "RustCall." => "")
        emitted = unqualified(RustCall._emit_struct_code(info))
        @test occursin("_guard_panic(call_rust_function(rustcall′fp, CRustString", emitted)
        @test occursin("_take_owned_string(rustcall′raw, rustcall′freep)", emitted)
        @test occursin("Rc246Counter_free_rust_string", emitted)
        @test !occursin("call_rust_function(func_ptr, Any", emitted)

        generated = unqualified(string(RustCall._generate_property_accessors(info)))
        @test occursin("_guard_panic(call_rust_function(rustcall′fp, CRustString", generated)
        @test occursin("_take_owned_string(rustcall′raw, rustcall′freep)", generated)
        @test occursin("Rc246Counter_free_rust_string", generated)

        # A plain field is unaffected.
        @test info.field_abis["count"] == ""
        @test RustCall.ffi_return_symbol_or_throw("u32", "", "Rc246Counter::count") === :UInt32
    end
end

@testset "#246: a String return is released, not leaked" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        rust"""
        struct Rc246Allocator;
        static RC246_LIVE_BUFFERS: std::sync::atomic::AtomicIsize =
            std::sync::atomic::AtomicIsize::new(0);
        unsafe impl std::alloc::GlobalAlloc for Rc246Allocator {
            unsafe fn alloc(&self, layout: std::alloc::Layout) -> *mut u8 {
                let ptr = std::alloc::GlobalAlloc::alloc(&std::alloc::System, layout);
                if !ptr.is_null() && layout.size() == 65536 {
                    RC246_LIVE_BUFFERS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                }
                ptr
            }
            unsafe fn dealloc(&self, ptr: *mut u8, layout: std::alloc::Layout) {
                if layout.size() == 65536 {
                    RC246_LIVE_BUFFERS.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                }
                std::alloc::GlobalAlloc::dealloc(&std::alloc::System, ptr, layout);
            }
        }
        #[global_allocator]
        static RC246_ALLOCATOR: Rc246Allocator = Rc246Allocator;
        #[julia]
        pub fn rc246_live_buffers() -> isize {
            RC246_LIVE_BUFFERS.load(std::sync::atomic::Ordering::SeqCst)
        }
        #[julia]
        pub struct Rc246Buf { n: usize }
        impl Rc246Buf {
            pub fn new(n: usize) -> Self { Self { n } }
            pub fn make(&self) -> String { "x".repeat(self.n) }
        }
        """
        buf = Rc246Buf(UInt(65536))
        @test length(make(buf)) == 65536
        @test (@rust rc246_live_buffers()) == 0

        # Positive control: bypass Julia's automatic release once, prove the
        # allocator observes the outstanding buffer, then release it through
        # the allocating image's captured helper even if the assertion fails.
        target = RustCall.resolve_call_target(getfield(buf, :lib_name),
            RustCall.ffi_method_symbol("Rc246Buf", "make");
            free_symbol = "Rc246Buf_free_rust_string")
        raw = RustCall.call_rust_function(target.func_ptr, RustCall.CRustString,
                                         getfield(buf, :ptr))
        RustCall.check_rust_panic_ptr(target.channel, "Rc246Buf::make")
        try
            @test (@rust rc246_live_buffers()) == 1
        finally
            RustCall._take_owned_string(raw, target.free_ptr)
        end
        @test (@rust rc246_live_buffers()) == 0

        # 10^4 calls allocate 640 MB of Rust buffers in total. Count their
        # deallocations directly: process-wide RSS also includes Julia's
        # compiler and GC heaps, so it cannot establish Rust buffer ownership.
        total = 0
        for i in 1:10_000
            total += length(make(buf))
            # Keep the temporary Julia copies small in parallel CI workers.
            # GC cannot reclaim an outstanding Rust-owned buffer.
            i % 250 == 0 && GC.gc()
        end
        @test total == 10_000 * 65536
        # This checks Rust deallocation directly, independently of RSS and
        # Julia's GC schedule: no returned Rust buffer may remain allocated.
        @test (@rust rc246_live_buffers()) == 0

        # And the release really is the contract's symbol, resolved inside the
        # allocating library rather than spelled at the call site.
        m = only(mm for mm in RustCall.manifest_struct_infos(RustCall.expand_inline("""
        #[julia]
        pub struct Rc246Buf { n: usize }
        impl Rc246Buf {
            pub fn make(&self) -> String { "x".repeat(self.n) }
        }
        """).manifest)[1].methods if mm.name == "make")
        c = RustCall.ffi_return_contract(m.return_type; abi = m.return_abi, owner = "Rc246Buf")
        @test c.free_symbol == "Rc246Buf_free_rust_string"
        @test c.ownership === :owned_by_rust
    end
end

# #246: a Julia `String` is a byte vector and need not be UTF-8, but Rust's
# `&str` is UTF-8 by definition. The generated wrapper builds the `&str` with
# `String::from_utf8_lossy`, which *replaces* an invalid byte with U+FFFD — so
# `f(String([0xff, 0xfe]))` ran the Rust function on data the caller never
# passed and returned a wrong answer with no error anywhere. The check is now
# on the Julia side, before the pointer exists; the Rust `from_utf8_lossy`
# stays as defence in depth, because a `&str` built from invalid bytes is
# undefined behaviour and nothing may reach it.
@testset "#246: invalid UTF-8 in a string argument raises, and names the argument" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        rust"""
        #[julia]
        pub fn rc246_shout(name: &str) -> String { name.to_uppercase() }
        #[julia]
        pub fn rc246_join(head: &str, tail: &str) -> String { format!("{}{}", head, tail) }
        #[julia]
        pub struct Rc246Greeter { prefix: usize }
        impl Rc246Greeter {
            pub fn new(prefix: usize) -> Self { Self { prefix } }
            pub fn greet(&self, who: &str) -> String { format!("{}{}", self.prefix, who) }
        }
        """

        # Valid UTF-8 still crosses, including multi-byte characters — the
        # check must not be a length or an ASCII test.
        @test rc246_shout("world") == "WORLD"
        @test rc246_shout("héllo ✓") == "HÉLLO ✓"
        @test rc246_shout("") == ""
        @test rc246_join("a", "é") == "aé"

        # The acceptance case from the issue.
        err = try
            rc246_shout(String([0xff, 0xfe]))
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        msg = sprint(showerror, err)
        @test occursin("not valid UTF-8", msg)
        @test occursin("`name`", msg)          # the argument, by its Rust name
        @test occursin("rc246_shout", msg)     # and the function it belongs to
        @test occursin("0xff", msg)            # and the byte that is wrong
        @test occursin("#246", msg)

        # It is the *offending* argument that is named, not the first string
        # one — a lone continuation byte after valid text, in position 2.
        err2 = try
            rc246_join("fine", "ok" * String([0x80]))
            nothing
        catch e
            e
        end
        @test err2 isa RustCall.RustError
        msg2 = sprint(showerror, err2)
        @test occursin("`tail`", msg2)
        @test !occursin("`head`", msg2)
        @test occursin("0x80", msg2)

        # A truncated multi-byte sequence is invalid too, and so is one that is
        # merely incomplete at the end.
        @test_throws RustCall.RustError rc246_shout(String(UInt8[0xc3]))
        @test_throws RustCall.RustError rc246_shout("ok" * String(UInt8[0xe2, 0x9c]))

        # Struct methods take the same path (`_string_arg_plan` is shared), and
        # report the method rather than a free function.
        g = Rc246Greeter(UInt(7))
        @test greet(g, "x") == "7x"
        err3 = try
            greet(g, String([0xfe]))
            nothing
        catch e
            e
        end
        @test err3 isa RustCall.RustError
        @test occursin("`who`", sprint(showerror, err3))
        @test occursin("greet", sprint(showerror, err3))

        # A *generic* `#[julia]` function with a fixed string parameter takes a
        # third path: `_call_monomorphized` builds its own argument list from
        # `FunctionInfo.arg_abis` and never goes through `_string_arg_plan`, so
        # it was the one string argument left reaching `from_utf8_lossy`
        # (#246 review).
        rust"""
        #[julia]
        pub fn rc246_tag<T: std::fmt::Display>(label: &str, value: T) -> String {
            format!("{}={}", label, value)
        }
        """
        @test RustCall.is_generic_function("rc246_tag")
        @test RustCall.call_generic_function("rc246_tag", "n", Int32(7)) == "n=7"
        @test RustCall.call_generic_function("rc246_tag", "é", 1.5) == "é=1.5"
        err4 = try
            RustCall.call_generic_function("rc246_tag", String([0xff, 0x41]), Int32(1))
            nothing
        catch e
            e
        end
        @test err4 isa RustCall.RustError
        msg4 = sprint(showerror, err4)
        @test occursin("not valid UTF-8", msg4)
        # A `FunctionInfo` records ABIs, not parameter names, so the position
        # is what the message can name — and it names the right one.
        @test occursin("argument #1", msg4)
        @test occursin("0xff", msg4)
        @test occursin("#246", msg4)
        # The specialization still works afterwards: nothing was left half-done.
        @test RustCall.call_generic_function("rc246_tag", "n", Int32(8)) == "n=8"

        # An argument may legitimately be called `ffi_string_argument`. The
        # generated wrapper binds a parameter of that name, so an *unqualified*
        # call to the helper resolved to the caller's string and raised a
        # `MethodError` before reaching Rust (#246 review). The plan emits a
        # `GlobalRef`, which no parameter can shadow — and which stringifies as
        # `RustCall.ffi_string_argument`, so the source-text emitter is covered
        # by the same line.
        rust"""
        #[julia]
        pub fn rc246_shadow(ffi_string_argument: &str) -> usize {
            ffi_string_argument.len()
        }
        """
        @test rc246_shadow("abcd") == Csize_t(4)
        @test rc246_shadow("héllo") == Csize_t(6)   # bytes, not characters
        err5 = try
            rc246_shadow(String([0xff]))
            nothing
        catch e
            e
        end
        @test err5 isa RustCall.RustError          # not a MethodError
        @test occursin("not valid UTF-8", sprint(showerror, err5))
        @test occursin("`ffi_string_argument`", sprint(showerror, err5))

        # And the same for the source-text emitter, checked on the text.
        let info = RustCall.scan_crate(joinpath(@__DIR__, "fixtures", "sample_crate")),
            code = RustCall.emit_crate_module_code(info, "/tmp/libsample_rc246.so")
            @test occursin("RustCall.ffi_string_argument(", code)
            # No unqualified call is left for a parameter to shadow.
            @test !occursin(r"(?<![.\w])ffi_string_argument\(", code)
        end

        # The message must not advertise a workaround the pipeline does not
        # have: `&[u8]` slice arguments are not lowered by `#[julia]`.
        @test !occursin("slice argument", msg) || occursin("is not lowered", msg)
        @test occursin("isvalid", msg)
        @test occursin("*const u8", msg)

        # The helper itself, so the contract is pinned independently of any
        # particular generated wrapper — in both of its spellings.
        @test RustCall.ffi_string_argument("ok", "a", "f") == "ok"
        @test RustCall.ffi_string_argument(SubString("xyz", 1, 2), "a", "f") == "xy"
        @test RustCall.ffi_string_argument("ok", 2, "f") == "ok"
        @test_throws RustCall.RustError RustCall.ffi_string_argument(
            String([0xff]), "a", "f")
        @test_throws RustCall.RustError RustCall.ffi_string_argument(
            String([0xff]), 2, "f")
        named_msg = sprint(showerror, try
            RustCall.ffi_string_argument(String([0xff]), "a", "f")
        catch e; e end)
        positional_msg = sprint(showerror, try
            RustCall.ffi_string_argument(String([0xff]), 2, "f")
        catch e; e end)
        @test occursin("argument `a` of `f`", named_msg)
        @test occursin("argument #2 of `f`", positional_msg)

        # A rejected call must not have touched Rust at all: the same wrapper
        # keeps working afterwards, and the argument that was fine is unharmed.
        @test rc246_shout("still here") == "STILL HERE"
    end
end
