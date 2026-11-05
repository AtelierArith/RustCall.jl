using Test, RustCall

# Keep the safety interceptors in a child process: no intercepted function can
# leak into another test file or into the parent's own library cleanup.
if "--receiver-child" ∉ ARGS
    @testset "finalized inline receiver safety runs in isolation (#574)" begin
        project = dirname(@__DIR__)
        command = `$(Base.julia_cmd()) --startup-file=no --project=$project $(@__FILE__) --receiver-child`
        @test success(pipeline(command; stdout = stdout, stderr = stderr))
    end
else
    source = raw"""
    #[derive(JuliaStruct)]
    pub struct Receiver574 { pub value: i32 }
    impl Receiver574 {
        pub fn new(value: i32) -> Self { Self { value } }
        pub fn plain574(&self) -> i32 { self.value }
        pub fn unit574(&self) {}
        pub fn owned574(&self) -> String { self.value.to_string() }
        pub fn borrowed574(&self) -> &str { "receiver" }
        pub fn copy574(&self) -> Self { Self { value: self.value } }
        pub fn result574(&self) -> Result<i32, String> { Ok(self.value) }
        pub fn option574(&self) -> Option<i32> { Some(self.value) }
        pub fn result_self574(&self) -> Result<Self, String> { Ok(Self { value: self.value }) }
        pub fn result_string574(&self) -> Result<String, i32> { Ok(self.value.to_string()) }
        pub fn option_string574(&self) -> Option<String> { Some(self.value.to_string()) }
        pub fn string_arg574(&self, text: String) -> i32 { self.value + text.len() as i32 }
        pub fn borrowed_arg574(&self, text: &str) -> i32 { self.value + text.len() as i32 }
        pub fn callback_arg574(&self, callback: extern "C" fn() -> i32) -> i32 { self.value + callback() }
        pub fn slice_plain574(&self, xs: &mut [f64]) -> f64 { if !xs.is_empty() { xs[0] += 1.0; } self.value as f64 + xs.iter().sum::<f64>() }
        pub fn mixed_input574(&self, other: Option<&Self>, xs: &mut [f64], cb: extern "C" fn() -> i32) -> f64 { if !xs.is_empty() { xs[0] += 1.0; } cb(); self.value as f64 + other.map_or(0.0, |v| v.value as f64) + xs.iter().sum::<f64>() }
        #[julia] #[rustcall_owned_return(ReceiverProduct574)]
        pub fn mixed_owned574(&self, other: Option<&Self>, xs: &mut [f64]) -> ReceiverProduct574 { if !xs.is_empty() { xs[0] += 1.0; } ReceiverProduct574 { value: self.value + other.map_or(0, |v| v.value) + xs.iter().sum::<f64>() as i32 } }
        #[julia] #[rustcall_owned_return(ReceiverProduct574)]
        pub fn mixed_owned_result574(&self, other: Option<&Self>, xs: &mut [f64]) -> Result<ReceiverProduct574, String> { Ok(self.mixed_owned574(other, xs)) }
        pub fn static_mixed574(other: Option<&Self>, xs: &[f64]) -> f64 { other.map_or(0.0, |v| v.value as f64) + xs.iter().sum::<f64>() }
        #[julia] #[rustcall_owned_return(ReceiverProduct574)]
        pub fn static_mixed_owned574(other: Option<&Self>, xs: &[f64]) -> ReceiverProduct574 { ReceiverProduct574 { value: other.map_or(0, |v| v.value) + xs.iter().sum::<f64>() as i32 } }
        pub fn static_plain574(value: i32) -> i32 { value }
        pub fn static_owned574() -> String { "static".to_owned() }
        pub fn static_borrowed574() -> &'static str { "static" }
        pub fn static_result574() -> Result<i32, String> { Ok(42) }
        pub fn static_option574() -> Option<i32> { Some(42) }
    }
    #[julia] pub struct ReceiverProduct574 { value: i32 }
    #[julia] impl ReceiverProduct574 { pub fn product_value574(&self) -> i32 { self.value } }
    #[julia]
    pub struct PlainReceiver574 { value: i32 }
    impl PlainReceiver574 {
        pub fn new(value: i32) -> Self { Self { value } }
        pub fn plain_no_derive574(&self) -> i32 { self.value }
    }
    #[derive(JuliaStruct)]
    pub struct GenericReceiver574<T> { pub value: T }
    impl<T: Copy> GenericReceiver574<T> {
        pub fn new(value: T) -> Self { Self { value } }
        pub fn generic_read574(&self) -> T { self.value }
    }
    """
    scope = Module(:FinalizedReceiver574)
    Core.eval(scope, :(using RustCall))
    lib = Core.eval(scope, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
    binding(name) = Base.invokelatest(getfield, scope, name)
    call(name, args...) = Base.invokelatest(binding(name), args...)
    owner_type = binding(:Receiver574)
    owner = call(:Receiver574, Int32(7))
    plain_owner = call(:PlainReceiver574, Int32(5))
    generic_type = binding(:GenericReceiver574){Int32}
    generic = Base.invokelatest(generic_type, Int32(11))
    @testset "live receivers, static methods and raw helper controls (#574)" begin
        @test call(:plain574, owner) == 7
        @test call(:plain_no_derive574, plain_owner) == 5
        @test call(:unit574, owner) === nothing
        @test call(:owned574, owner) == "7"
        @test call(:borrowed574, owner) == "receiver"
        copied = call(:copy574, owner)
        @test copied isa owner_type
        @test call(:plain574, copied) == 7
        finalize(copied)
        @test RustCall.unwrap(call(:result574, owner)) == 7
        @test RustCall.unwrap(call(:option574, owner)) == 7
        result_copy = RustCall.unwrap(call(:result_self574, owner))
        @test result_copy isa owner_type
        @test call(:plain574, result_copy) == 7
        finalize(result_copy)
        @test RustCall.unwrap(call(:result_string574, owner)) == "7"
        @test RustCall.unwrap(call(:option_string574, owner)) == "7"
        @test call(:string_arg574, owner, "hi") == 9
        @test call(:borrowed_arg574, owner, "hi") == 9
        @test call(:callback_arg574, owner, () -> Int32(2)) == 9
        slice_values = [1.0, 2.0]
        @test call(:slice_plain574, owner, slice_values) == 11.0
        @test slice_values == [2.0, 2.0]
        @test call(:mixed_input574, owner, nothing, [1.0], () -> (GC.gc(); Int32(0))) == 9.0
        @test call(:mixed_input574, owner, owner, [1.0], () -> Int32(0)) == 16.0
        selected_product = RustCall.resolve_call_target(
            lib,
            "rustcall_Receiver574_mixed_owned574";
            free_symbol = "ReceiverProduct574_free",
        )
        for (product, expected) in (
            (call(:mixed_owned574, owner, nothing, [1.0]), 9),
            (RustCall.unwrap(call(:mixed_owned_result574, owner, owner, [1.0])), 16),
            (call(:static_mixed_owned574, owner_type, nothing, [1.0]), 1),
        )
            @test nameof(typeof(product)) == :ReceiverProduct574
            @test call(:product_value574, product) == expected
            @test product.free_ptr == selected_product.free_ptr
            @test product.alive === owner.alive
            finalize(product)
        end
        @test call(:static_mixed574, owner_type, nothing, [1.0, 2.0]) == 3.0
        @test call(:static_mixed574, owner_type, owner, [1.0, 2.0]) == 10.0
        @test call(:static_plain574, owner_type, Int32(42)) == 42
        @test call(:static_plain574, Int32(43)) == 43
        @test call(:static_owned574, owner_type) == "static"
        @test call(:static_borrowed574, owner_type) == "static"
        @test RustCall.unwrap(call(:static_result574, owner_type)) == 42
        @test RustCall.unwrap(call(:static_option574, owner_type)) == 42
        @test Base.invokelatest(getproperty, owner, :value) == 7
        @test Base.invokelatest(setproperty!, owner, :value, Int32(8)) == 8
        @test call(:generic_read574, generic) == 11
        @test Base.invokelatest(getproperty, generic, :value) == 11
        @test Base.invokelatest(setproperty!, generic, :value, Int32(12)) == 12
        @test RustCall._call_rust_method(
            lib,
            "rustcall_Receiver574_plain574",
            owner.ptr,
            Int32,
        ) == 8
        @test RustCall._call_rust_method(
            lib,
            "rustcall_Receiver574_static_plain574",
            C_NULL,
            Int32,
            Int32(44),
        ) == 44
        @test RustCall._call_rust_method(
            lib,
            "rustcall_Receiver574_static_plain574",
            C_NULL,
            Int32,
            Int32(45);
            is_static = true,
        ) == 45
    end

    @testset "mixed input markers and legacy raw static intent compose (#574)" begin
        values = [1.0, 2.0]
        GC.@preserve owner values begin
            @test RustCall._call_rust_method(
                lib,
                "rustcall_Receiver574_static_mixed574",
                C_NULL,
                Float64,
                owner.ptr,
                pointer(values),
                Csize_t(length(values));
                slice_args = true,
                optional_owner_args = true,
            ) == 11.0
        end
    end

    # Capture a property-method closure before finalization; its call must
    # validate the receiver just like an ordinary function call.
    property_method = Base.invokelatest(getproperty, owner, :plain574)
    finalize(owner)
    finalize(plain_owner)
    finalize(generic)
    @test getfield(owner, :ptr) == C_NULL
    @test getfield(plain_owner, :ptr) == C_NULL
    @test getfield(generic, :ptr) == C_NULL

    @eval RustCall begin
        const RECEIVER574_RESOLUTIONS = Ref(0)
        const RECEIVER574_NATIVE_CALLS = Ref(0)
        function resolve_call_target(lib_name::String, func_name::String; kwargs...)
            RECEIVER574_RESOLUTIONS[] += 1
            error("#574 intercepted target resolution before any native call")
        end
        function call_rust_function(func_ptr::Ptr{Cvoid}, ret_type::Type, args...)
            RECEIVER574_NATIVE_CALLS[] += 1
            error("#574 intercepted native invocation")
        end
    end

    function receiver_error(action)
        error = try
            Base.invokelatest(action)
            nothing
        catch exception
            exception
        end
        @test error isa RustCall.RustError
        @test occursin("freed", sprint(showerror, error))
    end

    @testset "every finalized instance shape refuses before resolution (#574)" begin
        for name in (
            :plain574,
            :unit574,
            :owned574,
            :borrowed574,
            :copy574,
            :result574,
            :option574,
            :result_self574,
            :result_string574,
            :option_string574,
        )
            receiver_error(() -> call(name, owner))
        end
        receiver_error(() -> call(:plain_no_derive574, plain_owner))
        receiver_error(() -> call(:slice_plain574, owner, [1.0]))
        receiver_error(() -> call(:slice_plain574, owner, missing))
        receiver_error(() -> call(:mixed_input574, owner, nothing, [1.0], () -> Int32(0)))
        receiver_error(() -> call(:mixed_input574, owner, nothing, missing, missing))
        receiver_error(() -> call(:mixed_owned574, owner, nothing, [1.0]))
        receiver_error(() -> call(:mixed_owned574, owner, nothing, missing))
        receiver_error(() -> call(:mixed_owned_result574, owner, nothing, [1.0]))
        receiver_error(() -> call(:mixed_owned_result574, owner, nothing, missing))
        receiver_error(() -> call(:string_arg574, owner, "hi"))
        receiver_error(() -> call(:borrowed_arg574, owner, "hi"))
        receiver_error(() -> call(:callback_arg574, owner, () -> Int32(1)))
        # These arguments fail conversion on a live owner. The freed receiver
        # must win before argument bindings or callback-frame installation.
        receiver_error(() -> call(:string_arg574, owner, missing))
        receiver_error(() -> call(:borrowed_arg574, owner, missing))
        receiver_error(() -> call(:callback_arg574, owner, missing))
        receiver_error(() -> Base.invokelatest(property_method))
        receiver_error(() -> Base.invokelatest(getproperty, owner, :value))
        receiver_error(() -> Base.invokelatest(setproperty!, owner, :value, Int32(1)))
        receiver_error(() -> call(:generic_read574, generic))
        receiver_error(() -> Base.invokelatest(getproperty, generic, :value))
        receiver_error(() -> Base.invokelatest(setproperty!, generic, :value, Int32(1)))
        @test isempty(RustCall._callback_frames())
        @test RustCall.RECEIVER574_RESOLUTIONS[] == 0
        @test RustCall.RECEIVER574_NATIVE_CALLS[] == 0
    end
    @testset "explicit instance intent cannot become static (#574)" begin
        receiver_error(
            () -> RustCall._call_rust_method(
                lib,
                "rustcall_Receiver574_plain574",
                C_NULL,
                Int32;
                is_static = false,
            ),
        )
        @test RustCall.RECEIVER574_RESOLUTIONS[] == 0
        @test RustCall.RECEIVER574_NATIVE_CALLS[] == 0
    end
    # Finalized owners own no allocation. The child may exit with the image
    # mapped; no lookup or native call follows interceptor installation.
end
