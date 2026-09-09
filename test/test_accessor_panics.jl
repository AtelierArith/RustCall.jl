using RustCall
using Test

@testset "String field setters use byte pairs (#291)" begin
    scope = Module(gensym(:StringSetter291))
    Core.eval(scope, :(using RustCall))
    source = raw"""
        #[julia] pub struct TextSetter291 { pub text: String }
        #[julia] impl TextSetter291 {
            pub fn new() -> Self { Self { text: String::new() } }
        }
        """
    lib = Core.eval(scope, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
    object = Base.invokelatest(Base.invokelatest(getfield, scope, :TextSetter291))
    info = RustCall.RustStructInfo(
        "TextSetter291", String[], RustCall.RustMethod[], "",
        [("text", "String")], true, Dict{String, Bool}();
        field_abis = Dict("text" => "string"), has_owned_string_helper = true)
    try
        Core.eval(scope, quote
            import RustCall: call_rust_function
            const library = $lib
            function _call_target(name)
                target = RustCall.resolve_call_target(library, name)
                (target.func_ptr, target.channel)
            end
            _guard_panic(value, channel, name) = RustCall.guard_rust_panic_ptr(value, channel, name)
        end)
        for flavour in (:inline, :ast, :source)
            if flavour !== :inline
                body = flavour === :ast ?
                    RustCall._crate_field_write(info, "text", "String", "TextSetter291_set_text", :ptr, :value) :
                    Meta.parse(RustCall._crate_field_write_source(info, "text", "String", "TextSetter291_set_text", "ptr", "value"))
                Core.eval(scope, :(function set_text(ptr, value); $body; end))
            end
            setter(value) = flavour === :inline ?
                Base.invokelatest(setproperty!, object, :text, value) :
                GC.@preserve object Base.invokelatest(Base.invokelatest(getfield, scope, :set_text), getfield(object, :ptr), value)
            for text in ("日本語\0末尾", "", "replacement")
                setter(text)
                @test Base.invokelatest(getproperty, object, :text) == text
            end
            @test_throws RustCall.RustError setter(String(UInt8[0xff]))
            @test Base.invokelatest(getproperty, object, :text) == "replacement"
        end
    finally
        finalize(object)
        RustCall.unload_library(lib; close = true)
        RustCall.close_retired_handles!(RustCall.retired_handles(lib))
    end
end

@testset "both crate field emitters propagate panic channels (#291)" begin
    # The Rust tests exercise panicking Clone/Drop in generated accessors.
    # Here real guarded Rust functions stand in for accessor symbols so every
    # Julia field ABI, including borrowed text, can deterministically panic.
    source = raw"""
        #[julia] pub fn fail_number(_ptr: *const i32) -> i32 { panic!("number accessor"); }
        #[julia] pub fn fail_text(_ptr: *const i32) -> String { panic!("text accessor"); }
        #[julia] pub fn fail_borrowed(_ptr: *const i32) -> &'static str { panic!("borrowed accessor"); }
        #[julia] pub fn fail_set(_ptr: *mut i32, _value: i32) { panic!("setter accessor"); }
        #[julia] pub fn good_number(ptr: *const i32) -> i32 { unsafe { *ptr } }
        """
    lib = RustCall._compile_and_load_rust(source, "accessor_channels_291", 1)
    info = RustCall.RustStructInfo(
        "AccessorProbe", String[], RustCall.RustMethod[], "",
        [("number", "i32"), ("text", "String"), ("borrowed", "&str")],
        true, Dict{String, Bool}();
        field_abis = Dict("text" => "string", "borrowed" => "str"),
        has_owned_string_helper = true, has_borrowed_string_helper = true)
    try
        for flavour in (:ast, :source)
            scope = Module(gensym(:AccessorChannels291))
            Core.eval(scope, quote
                using RustCall
                import RustCall: call_rust_function
                const library = $lib
                function _call_target(name, release = "")
                    # This fixture has only one String producer. The emitter
                    # still has to request and use a release pointer snapshot.
                    free = isempty(release) ? "" : "fail_text_free_rust_string"
                    target = RustCall.resolve_call_target(library, name; free_symbol = free)
                    isempty(release) || @assert target.free_ptr != C_NULL
                    isempty(release) ? (target.func_ptr, target.channel) :
                        (target.func_ptr, target.channel, target.free_ptr)
                end
                _guard_panic(value, channel, name) = RustCall.guard_rust_panic_ptr(value, channel, name)
            end)
            for (field, type, symbol) in (("number", "i32", "rustcall_fail_number"),
                                         ("text", "String", "rustcall_fail_text"),
                                         ("borrowed", "&str", "rustcall_fail_borrowed"),
                                         ("number", "i32", "rustcall_good_number"))
                name = Symbol(symbol)
                body = flavour === :ast ?
                    RustCall._crate_field_read(info, field, type, symbol, :ptr) :
                    Meta.parse(RustCall._crate_field_read_source(info, field, type, symbol, "ptr"))
                Core.eval(scope, :(function $name(ptr); $body; end))
            end
            body = flavour === :ast ?
                RustCall._crate_field_write(info, "number", "i32", "rustcall_fail_set", :ptr, :value) :
                Meta.parse(RustCall._crate_field_write_source(info, "number", "i32", "rustcall_fail_set", "ptr", "value"))
            Core.eval(scope, :(function set_number(ptr, value); $body; end))
            storage = Ref{Int32}(42)
            GC.@preserve storage begin
                ptr = Base.unsafe_convert(Ptr{Int32}, storage)
                for name in (:rustcall_fail_number, :rustcall_fail_text, :rustcall_fail_borrowed)
                    f = Base.invokelatest(getfield, scope, name)
                    for _ in 1:2
                        @test_throws RustCall.RustPanicError Base.invokelatest(f, ptr)
                        target = RustCall.resolve_call_target(lib, String(name))
                        @test RustCall.guard_rust_panic_ptr(nothing, target.channel, String(name)) === nothing
                    end
                end
                @test_throws RustCall.RustPanicError Base.invokelatest(Base.invokelatest(getfield, scope, :set_number), ptr, 7)
                @test Base.invokelatest(Base.invokelatest(getfield, scope, :rustcall_good_number), ptr) == 42
            end
        end
    finally
        RustCall.unload_library(lib; close = true)
        RustCall.close_retired_handles!(RustCall.retired_handles(lib))
    end
end

@testset "legacy generic field propagates panics (#291)" begin
    scope = Module(gensym(:InlineAccessor291))
    Core.eval(scope, :(using RustCall))
    source = raw"""
        #[julia] pub fn accessor_fixture291() -> i32 { 1 }
        #[julia]
        pub fn legacy_field_panic291<T>(_ptr: *const T) -> i32 {
            panic!("legacy generic field panic");
        }
        """
    lib = Core.eval(scope, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
    try
        # No grouped object record: exercise the compatibility fallback, whose
        # primitive-return branch used to bypass the specialization's channel.
        @test_throws RustCall.RustPanicError RustCall._call_generic_field(
            "ungrouped_accessor291", "legacy_field_panic291", Ptr{Cvoid}(C_NULL),
            Int32, (Int32,), Ref(true))
    finally
        RustCall.unload_library(lib; close = true)
        RustCall.close_retired_handles!(RustCall.retired_handles(lib))
    end
end
