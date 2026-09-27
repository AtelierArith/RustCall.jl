# Component tests loaded by test_crate_bindings.jl.

@testset "Crate bindings: String / &str functions (#242)" begin
    manifest = RustCall.extract_manifest([joinpath(SAMPLE_CRATE_PATH, "src", "lib.rs")]; mode = "crate")
    sigs = Dict(s.name => s for s in RustCall.manifest_function_signatures(manifest))
    @test sigs["shout"].has_owned_string_helper
    @test sigs["crate_greeting"].has_borrowed_string_helper
    @test sigs["char_count"].arg_types == ["&str"]

    if RustCall.check_rustc_available()
        let bindings = @rust_crate SAMPLE_CRATE_PATH name="SampleCrateStrings"
            @test bindings.shout("hello") == "HELLO"
            @test bindings.join_repeat("a", "b", "-", UInt32(2)) == "a-b-a-b"
            @test bindings.char_count("日本語") == 3
            @test bindings.crate_greeting() == "hello from sample_crate"
            @test RustCall.unwrap(bindings.parse_int(" 7 ")) == Int32(7)
            @test RustCall.is_err(bindings.parse_int("seven"))
            @test RustCall.unwrap(bindings.first_char("é")) == UInt32('é')
            @test RustCall.is_none(bindings.first_char(""))
            @test bindings.identity_str("λ") == "λ"
            for _ in 1:200
                @test bindings.shout("x") == "X"
            end
        end
    end

    # The source-file emitter (write_bindings_to_file) uses the same ABI.
    info = RustCall.scan_crate(SAMPLE_CRATE_PATH)
    code = RustCall.emit_crate_module_code(info, "/tmp/libsample.so")
    # Wrapper, panic channel and the function that releases the returned
    # buffer come from one snapshot of the module's handle: resolving the
    # release function after the call let a hot reload land in between, and the
    # buffer was then freed through the replacement's allocator (#277).
    @test occursin("rustcall′func_ptr, rustcall′panic_channel, rustcall′free_ptr = _call_target(var\"#TC#fn#rustcall_shout\", \"rustcall_shout\", \"shout_free_rust_string\")", code)
    @test occursin("rustcall′RustCall._call_rust_owned_string_ptr(rustcall′func_ptr, rustcall′free_ptr", code)
    @test occursin("rustcall′str′input = rustcall′RustCall.ffi_string_argument(input, \"input\", \"shout\")", code)
    @test occursin("rustcall′Base.GC.@preserve(rustcall′str′input", code)
    @test occursin("rustcall′RustCall._call_rust_borrowed_string_ptr(rustcall′func_ptr", code)
    @test occursin("_call_target(var\"#TC#fn#rustcall_crate_greeting\", \"rustcall_crate_greeting\")", code)
    @test occursin("rustcall′Base.GC.@preserve(rustcall′str′s, rustcall′RustCall.call_rust_function(rustcall′func_ptr, CResult_parse_int, rustcall′Base.pointer(rustcall′str′s), rustcall′Base.sizeof(rustcall′str′s) % rustcall′Base.Csize_t))", code)
    # Nothing to preserve: `GC.@preserve` is omitted entirely rather than
    # emitted with an empty object list, because the call is now nested inside
    # `_guard_panic(...)` and the parenthesized form needs at least one object
    # (#244, #277 Phase B5).
    @test occursin("_guard_panic(rustcall′RustCall.call_rust_function(rustcall′func_ptr, rustcall′Base.Int32, rustcall′Base.Int32(a), rustcall′Base.Int32(b)), rustcall′panic_channel, \"add\")", code)
    # Every generated call reads its wrapper's panic channel, and resolves it
    # BEFORE the call: the channel is a thread-local in the image, so nothing
    # may yield between the two (#244).
    @test occursin("_guard_panic(", code)
    @test occursin("rustcall′func_ptr, rustcall′panic_channel = _call_target(var\"#TC#fn#rustcall_add\", \"rustcall_add\")", code)
    @test occursin("rustcall′RustCall.guard_rust_panic_ptr", code)
    # The resolution precedes the call in the emitted text.
    add_at = findfirst("function add(a, b)", code)
    @test add_at !== nothing
    add_body = code[first(add_at):end]
    add_body = add_body[1:first(findfirst("\nend", add_body))]
    @test findfirst("_call_target(", add_body) < findfirst("rustcall′RustCall.call_rust_function(", add_body)
    # and the emitted module parses
    @test Meta.parse(code) isa Expr
end

@testset "Crate bindings: arguments named like generated locals (#242 review)" begin
    # A Rust argument may be called `func_ptr` / `lib_name` / `c_result` /
    # `c_option`; the generated wrapper must not shadow it with its own local.
    info = RustCall.scan_crate(SAMPLE_CRATE_PATH)
    code = RustCall.emit_crate_module_code(info, "/tmp/libsample.so")

    # The wrapper's own locals are `rustcall′...` (PR #527 review), a name no
    # Rust argument can spell, so an argument called `func_ptr` / `c_result` /
    # `c_option` / `lib_name` keeps its name and meets no local.
    @test occursin("function shadow_str_len(func_ptr, lib_name)", code)
    @test occursin("rustcall′str′func_ptr = rustcall′RustCall.ffi_string_argument(func_ptr, \"func_ptr\", \"shadow_str_len\")", code)
    @test occursin("rustcall′func_ptr, rustcall′panic_channel = _call_target(var\"#TC#fn#rustcall_shadow_str_len\", \"rustcall_shadow_str_len\")", code)
    @test occursin("function shadow_parse_int(func_ptr, c_result)", code)
    @test occursin("rustcall′c_result = rustcall′Base.GC.@preserve(rustcall′str′func_ptr, rustcall′RustCall.call_rust_function(rustcall′func_ptr, CResult_shadow_parse_int,", code)
    @test occursin("function shadow_first_char(func_ptr, c_option)", code)
    @test occursin("rustcall′c_option = rustcall′Base.GC.@preserve(rustcall′str′func_ptr, rustcall′RustCall.call_rust_function(rustcall′func_ptr, COption_shadow_first_char,", code)
    @test occursin("rustcall′RustCall.call_rust_function(rustcall′func_ptr, rustcall′Base.Int32, rustcall′Base.Int32(func_ptr))", code)

    @test Meta.parse(code) isa Expr

    if RustCall.check_rustc_available()
        let bindings = @rust_crate SAMPLE_CRATE_PATH name="SampleCrateShadow"
            @test bindings.shadow_str_len("abc", "de") == 5
            @test RustCall.unwrap(bindings.shadow_parse_int(" 7 ", Int32(-1))) == Int32(7)
            @test RustCall.is_err(bindings.shadow_parse_int("seven", Int32(-1)))
            @test RustCall.unwrap(bindings.shadow_first_char("A", UInt32(0))) == UInt32('A')
            @test RustCall.is_none(bindings.shadow_first_char("", UInt32(0)))
            @test bindings.shadow_double(Int32(21)) == Int32(42)
        end
    end
end

@testset "Crate bindings: struct methods with String / &str (#242 review)" begin
    manifest = RustCall.extract_manifest([joinpath(SAMPLE_CRATE_PATH, "src", "lib.rs")]; mode = "crate")
    labeler = only(filter(s -> s.name == "Labeler", RustCall.manifest_struct_infos(manifest)))
    methods = Dict(m.name => m for m in labeler.methods)
    @test methods["label"].arg_abis == ["str"]
    @test methods["label"].return_abi == "string"
    @test methods["byte_len"].arg_abis == ["string"]
    @test methods["byte_len"].return_abi == ""
    @test methods["kind"].return_abi == "str"
    @test methods["echo"].return_abi == "string"   # may borrow from the argument: copied
    @test methods["shout"].is_static && methods["shout"].return_abi == "string"

    # The source emitter passes (ptr, len) pairs and reads the per-method buffers
    info = RustCall.scan_crate(SAMPLE_CRATE_PATH)
    code = RustCall.emit_crate_module_code(info, "/tmp/libsample.so")
    @test occursin("rustcall′str′name = rustcall′RustCall.ffi_string_argument(name, \"name\", \"label\")", code)
    # `self` is in the preserve list of every instance method: a borrowed
    # `&str` points into the Rust object, which a temporary's finalizer could
    # otherwise free mid-call.
    @test occursin("rustcall′Base.GC.@preserve(rustcall′self, rustcall′str′name, rustcall′RustCall._call_rust_owned_string_ptr(rustcall′func_ptr, rustcall′free_ptr, rustcall′Base.getfield(rustcall′self, :ptr), rustcall′Base.pointer(rustcall′str′name), rustcall′Base.sizeof(rustcall′str′name) % rustcall′Base.Csize_t)", code)
    @test occursin("rustcall′Base.GC.@preserve(rustcall′self, rustcall′RustCall._call_rust_borrowed_string_ptr(rustcall′func_ptr, rustcall′Base.getfield(rustcall′self, :ptr))", code)
    # Each owned-`String` method snapshots its release function together with
    # the wrapper it calls, so the buffer cannot outlive the generation that
    # allocated it (#277).
    @test occursin("rustcall′func_ptr, rustcall′panic_channel, rustcall′free_ptr = _call_target(var\"#TC#m#rustcall_Labeler_label\", \"rustcall_Labeler_label\", \"Labeler_label_free_rust_string\")", code)
    @test occursin("rustcall′func_ptr, rustcall′panic_channel, rustcall′free_ptr = _call_target(var\"#TC#m#rustcall_Labeler_shout\", \"rustcall_Labeler_shout\", \"Labeler_shout_free_rust_string\")", code)
    @test occursin("rustcall′Base.GC.@preserve(rustcall′str′s, rustcall′RustCall._call_rust_owned_string_ptr(rustcall′func_ptr, rustcall′free_ptr, rustcall′Base.pointer(rustcall′str′s), rustcall′Base.sizeof(rustcall′str′s) % rustcall′Base.Csize_t)", code)
    @test occursin("rustcall′Base.GC.@preserve(rustcall′self, rustcall′str′s, rustcall′RustCall.call_rust_function(rustcall′func_ptr, rustcall′Base.Csize_t, rustcall′Base.getfield(rustcall′self, :ptr), rustcall′Base.pointer(rustcall′str′s), rustcall′Base.sizeof(rustcall′str′s) % rustcall′Base.Csize_t)", code)
    @test occursin("rustcall′Base.GC.@preserve(rustcall′self, rustcall′RustCall.call_rust_function(rustcall′func_ptr, rustcall′Base.Float64, rustcall′Base.getfield(rustcall′self, :ptr))", code)
    # The in-memory wrapper preserves `self` too
    labeler_info = only(filter(s -> s.name == "Labeler", info.julia_structs))
    kind_method = only(filter(m -> m.name == "kind", labeler_info.methods))
    kind_expr = string(RustCall._generate_crate_method_wrapper(labeler_info, kind_method))
    @test occursin("Base.GC.@preserve(rustcall′self, RustCall._call_rust_borrowed_string_ptr(rustcall′func_ptr, Base.getfield(rustcall′self, :ptr))", kind_expr)
    label_method = only(filter(m -> m.name == "label", labeler_info.methods))
    @test occursin("Base.GC.@preserve(rustcall′self, rustcall′str′name, RustCall._call_rust_owned_string_ptr", string(RustCall._generate_crate_method_wrapper(labeler_info, label_method)))
    # Constructors still return the boxed struct
    # A boxed-struct result is bound to the generation that allocated it: the
    # destructor, its panic channel and the flag come from the constructor's
    # own snapshot (#277, #291).
    @test occursin("Labeler(rustcall′RustCall.call_rust_function(rustcall′func_ptr, rustcall′Base.Ptr{rustcall′Base.Cvoid}, rustcall′Base.UInt32(count)), rustcall′free_ptr, rustcall′alive, rustcall′free_panic_channel)", code)
    @test occursin("Point(rustcall′RustCall.call_rust_function(rustcall′func_ptr, rustcall′Base.Ptr{rustcall′Base.Cvoid}, rustcall′Base.Float64(x), rustcall′Base.Float64(y)), rustcall′free_ptr, rustcall′alive, rustcall′free_panic_channel)", code)
    @test occursin("rustcall′func_ptr, rustcall′panic_channel, rustcall′free_ptr, rustcall′alive, rustcall′free_panic_channel = _ctor_target", code)
    @test occursin("_ctor_target(var\"#TC#m#rustcall_Point_new\", \"rustcall_Point_new\", \"Point_free\")", code)
    @test Meta.parse(code) isa Expr

    if RustCall.check_rustc_available()
        # The module is evaluated in this world; go through invokelatest for
        # the struct wrappers (their outer constructors are newer methods).
        let bindings = @rust_crate SAMPLE_CRATE_PATH name="SampleCrateLabeler"
            call(f, args...) = Base.invokelatest(f, args...)
            l = call(bindings.Labeler, UInt32(0))
            @test call(bindings.label, l, "x") == "x#1"
            @test call(bindings.label, l, "日本") == "日本#2"
            @test call(getproperty, l, :count) == 2
            @test call(bindings.byte_len, l, "abc") == 3
            @test call(bindings.byte_len, l, "日本語") == 9
            @test call(bindings.byte_len, l, SubString("xabc", 2)) == 3
            @test call(bindings.kind, l) == "labeler"
            @test call(bindings.echo, l, "λ") == "λ"
            @test call(bindings.shout, "hi") == "HI"
            for _ in 1:200
                @test call(bindings.label, l, "y") isa String
            end
            # A borrowed `&str` of a temporary: the wrapper object must stay
            # alive until the bytes are copied, even under GC pressure.
            for i in 1:300
                @test call(bindings.kind, call(bindings.Labeler, UInt32(i))) == "labeler"
                @test call(bindings.echo, call(bindings.Labeler, UInt32(i)), "tmp$i") == "tmp$i"
                i % 25 == 0 && GC.gc()
            end
            # Non-string methods and constructors are unchanged
            p = call(bindings.Point, 3.0, 4.0)
            @test call(bindings.distance_from_origin, p) == 5.0
            c = call(bindings.Counter, Int32(1))
            call(bindings.add, c, Int32(4))
            @test call(bindings.get, c) == Int32(5)
        end
    end
end
