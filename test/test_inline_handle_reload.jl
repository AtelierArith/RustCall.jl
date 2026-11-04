using RustCall, Test

@testset "inline borrowed handles match the executing image" begin
    # Replace the published image without redefining the caller's Julia
    # handle type. Keep layouts compatible so this regression fails safely
    # on an unfixed runtime rather than performing an invalid memory read.
    source(generation) = """
        #[julia] pub struct ReloadBorrow { value: i32 }
        #[julia] impl ReloadBorrow {
            pub fn new(value: i32) -> Self { Self { value } }
            pub fn read(&self) -> i32 { self.value }
            pub fn sum(&self, other: &Self) -> i32 { self.value + other.value }
            pub fn duplicate(&self) -> Result<Self, i32> { Ok(Self { value: self.value }) }
            pub fn copy_plain(&self) -> Self { Self { value: self.value } }
            pub fn describe(&self) -> String { self.value.to_string() }
            pub fn category(&self) -> &'static str { if self.value > 0 { "positive" } else { "other" } }
            pub fn checked(&self) -> Result<i32, String> { Ok(self.value) }
            pub fn optional(&self) -> Option<i32> { Some(self.value) }
            pub fn inspect(value: &Self) -> i32 { value.value }
        }
        #[julia] pub fn peek_borrow_image(v: &ReloadBorrow) -> i32 { v.value + $generation }
        #[julia] pub fn total(a: &ReloadBorrow, b: &ReloadBorrow) -> i32 { a.value + b.value }
        #[julia] pub fn label(v: &ReloadBorrow) -> String { v.value.to_string() }
        #[julia] pub fn borrowed(v: &ReloadBorrow) -> &'static str {
            if v.value > 0 { "positive" } else { "other" }
        }
        #[julia] pub fn result(v: &ReloadBorrow) -> Result<String, i32> { Ok(v.value.to_string()) }
        #[julia] pub fn option(v: &ReloadBorrow) -> Option<i32> { Some(v.value) }
        """
    scopes = (Module(gensym(:BorrowOld)), Module(gensym(:BorrowNew)))
    libs = String[]
    objects = Any[]
    call(mod, fn, args...) = Base.invokelatest(Base.invokelatest(getfield, mod, fn), args...)
    try
        for (generation, mod) in enumerate(scopes)
            Core.eval(mod, :(using RustCall))
            push!(libs, Core.eval(mod, Expr(:macrocall, Symbol("@rust_str"),
                                            LineNumberNode(1), source(generation))))
        end
        mod = first(scopes)
        old = call(mod, :ReloadBorrow, Int32(4))
        push!(objects, old)
        @test call(mod, :peek_borrow_image, old) == 5
        @test call(mod, :total, old, old) == 8
        @test call(mod, :label, old) == "4"
        @test call(mod, :borrowed, old) == "positive"
        @test RustCall.unwrap(call(mod, :result, old)) == "4"
        @test RustCall.unwrap(call(mod, :option, old)) == 4

        @test RustCall.alias_artifact!(RustCall.inline_rustc_policy(), last(libs), first(libs))
        fresh = call(mod, :ReloadBorrow, Int32(6))
        push!(objects, fresh)
        @test old.alive !== fresh.alive
        @test old.alive[]  # retirement does not invalidate the old allocation
        @test call(mod, :peek_borrow_image, fresh) == 8
        @test call(mod, :total, fresh, fresh) == 12
        @test call(mod, :label, fresh) == "6"
        @test call(mod, :borrowed, fresh) == "positive"
        @test RustCall.unwrap(call(mod, :result, fresh)) == "6"
        @test RustCall.unwrap(call(mod, :option, fresh)) == 6
        @test call(mod, :read, fresh) == 6
        @test call(mod, :sum, fresh, fresh) == 12
        @test call(mod, :describe, fresh) == "6"
        @test call(mod, :category, fresh) == "positive"
        @test RustCall.unwrap(call(mod, :checked, fresh)) == 6
        @test RustCall.unwrap(call(mod, :optional, fresh)) == 6
        @test call(mod, :inspect, Base.invokelatest(getfield, mod, :ReloadBorrow), fresh) == 6
        copy = RustCall.unwrap(call(mod, :duplicate, fresh))
        plain = call(mod, :copy_plain, fresh)
        append!(objects, (copy, plain))
        @test copy.alive === fresh.alive
        @test plain.alive === fresh.alive
        # Test cold and warmed targets: rejection cannot be skipped on a hit.
        for _ in 1:2
            for name in (:peek_borrow_image, :label, :borrowed, :result, :option)
                @test_throws ArgumentError call(mod, name, old)
            end
            for name in (:read, :describe, :category, :checked, :optional, :duplicate, :copy_plain)
                @test_throws ArgumentError call(mod, name, old)
            end
            @test_throws ArgumentError call(mod, :inspect, Base.invokelatest(getfield, mod, :ReloadBorrow), old)
            @test_throws ArgumentError call(mod, :sum, old, old)
            @test_throws ArgumentError call(mod, :total, old, old)
            @test_throws ArgumentError call(mod, :total, old, fresh)
            @test_throws ArgumentError call(mod, :total, fresh.ptr, old)
        end
        # Raw pointers remain the explicit unchecked escape hatch.
        @test call(mod, :total, fresh.ptr, fresh.ptr) == 12
    finally
        foreach(finalize, objects)
        for name in libs
            haskey(RustCall.RUST_LIBRARIES, name) && RustCall.unload_library(name; close = true)
            RustCall.close_retired_handles!(RustCall.retired_handles(name))
        end
    end
end
