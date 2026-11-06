using Test, RustCall

const GLOB569_LIB = raw"""
use rustcall_julia_macros::julia;
use std::sync::atomic::{AtomicU32, Ordering};
#[julia] pub struct Counter569 { value: i32 }
#[julia] impl Counter569 {
    #[julia] pub fn new(value: i32) -> Self { Self { value } }
    #[julia] pub fn get(&self) -> i32 { self.value }
}
#[julia] pub struct Kounter569 { value: i32 }
#[julia] impl Kounter569 {
    #[julia] pub fn new(value: i32) -> Self { Self { value } }
    #[julia] pub fn get(&self) -> i32 { self.value }
}
#[julia] pub mod nfc_shadow569 {
    use super::*;
    pub struct Kounter569 { pub value: i64 }
    #[julia] pub fn read(value: &Kounter569) -> i32 { value.value as i32 }
}
#[julia] pub mod nfc_alias569 {
    use crate::Kounter569 as Kounter569;
    #[julia] pub fn read(value: &Kounter569) -> i32 { value.value }
    #[julia] pub fn mutate(value: &mut Kounter569) -> i32 { value.value += 1; value.value }
}
#[julia] pub struct Destination569 { value: i32 }
#[julia] impl Destination569 {
    #[julia] pub fn new() -> Self { Self { value: 0 } }
    #[julia] pub fn get(&self) -> i32 { self.value }
}
mod operations;
#[path = "renamed_owner569.rs"] pub mod r#path_owner569;
#[julia] pub mod path_reads569 {
    use super::r#path_owner569::*;
    use super::r#path_owner569::PathOwner569 as r#RenamedPath569;
    #[julia] pub fn renamed_mut(value: &mut RenamedPath569) -> i32 { value.value += 1; value.value }
    #[julia] pub fn glob(value: &PathOwner569) -> i32 { value.value }
    #[julia] pub fn qualified(value: &super::r#path_owner569::PathOwner569) -> i32 { value.value }
}
#[julia] pub mod alias_glob569 {
    use super as parent569;
    use parent569::*;
    #[julia] pub fn read(value: &Counter569) -> i32 { value.value }
    #[julia] pub fn mutate(a: &mut Counter569, b: &Counter569) -> i32 { a.value += b.value; a.value }
}
#[julia] pub mod free_ops569 {
    use super::*;
    #[julia] pub fn sum(a: &Counter569, b: &Counter569) -> i32 { a.value + b.value }
    #[julia] pub fn mutate(a: &mut Counter569, b: &Counter569) -> i32 { a.value += b.value; a.value }
    #[julia] pub fn callback(a: &Counter569, f: extern "C" fn() -> i32) -> i32 { f(); a.value }
}
mod plain569 { pub struct Counter569 { pub value: i32 } }
mod value_items569 {
    pub fn Counter569() -> i32 { 99 }
    pub const Kounter569: i32 = 99;
    pub mod reexport { pub use super::Counter569; }
}
mod type_items569 { pub struct Counter569 { pub value: i64 } }
mod type_aliases569 { pub type Counter569 = super::type_items569::Counter569; }
#[julia] pub mod named_value569 {
    use super::*;
    use crate::value_items569::Counter569;
    #[julia] pub fn read(value: &Counter569) -> i32 { value.value }
}
#[julia] pub mod named_const569 {
    use super::*;
    use crate::value_items569::Kounter569;
    #[julia] pub fn read(value: &Kounter569) -> i32 { value.value }
}
#[julia] pub mod local_value569 {
    use super::*;
    pub fn Counter569() -> i32 { 99 }
    #[julia] pub fn read(value: &Counter569) -> i32 { value.value }
}
#[julia] pub mod value_reexport569 {
    use super::*;
    use crate::value_items569::reexport::Counter569;
    #[julia] pub fn read(value: &Counter569) -> i32 { value.value }
}
#[julia] pub mod named_type569 {
    use super::*;
    use crate::type_items569::Counter569;
    #[julia] pub fn read(value: &Counter569) -> i32 { value.value as i32 }
}
#[julia] pub mod named_alias569 {
    use super::*;
    use crate::type_aliases569::Counter569;
    #[julia] pub fn read(value: &Counter569) -> i32 { value.value as i32 }
}
#[julia] pub mod precedence569 {
    use super::*;
    use super::plain569::*;
    use super::Counter569;
    #[julia] pub fn read(a: &Counter569) -> i32 { a.value }
}
#[julia] pub mod local_shadow569 {
    use super::*;
    pub struct r#Counter569 { pub value: i32 }
    #[julia] pub fn read(a: &Counter569) -> i32 { a.value }
}
#[julia] pub mod external_ops569 {
    use super::*;
    use external_scope569::*;
    static ENTRIES: AtomicU32 = AtomicU32::new(0);
    pub(crate) fn mark_entry() { ENTRIES.fetch_add(1, Ordering::SeqCst); }
    #[julia] pub fn entries() -> u32 { ENTRIES.load(Ordering::SeqCst) }
    #[julia] pub fn read(a: &ForeignCounter569) -> i32 { ENTRIES.fetch_add(1, Ordering::SeqCst); a.value() }
    #[julia] pub fn mutate(a: &mut ForeignCounter569) -> i32 { ENTRIES.fetch_add(1, Ordering::SeqCst); a.add(1); a.value() }
    #[julia] pub fn allocate(value: i32) -> *mut ForeignCounter569 { Box::into_raw(Box::new(ForeignCounter569::new(value))) }
    #[julia] pub fn release(value: *mut ForeignCounter569) { if !value.is_null() { unsafe { drop(Box::from_raw(value)); } } }
}
#[test] fn rust_answer569() {
    let mut destination = Destination569::new();
    assert_eq!(destination.read(&Counter569::new(42)), 42);
    assert_eq!(nfc_shadow569::read(&nfc_shadow569::Kounter569 { value: 42 }), 42);
    assert_eq!(named_type569::read(&type_items569::Counter569 { value: 42 }), 42);
    assert_eq!(named_alias569::read(&type_items569::Counter569 { value: 42 }), 42);
    assert_eq!(std::mem::size_of::<Kounter569>(), 4);
    assert_eq!(std::mem::size_of::<nfc_shadow569::Kounter569>(), 8);
}
"""

const GLOB569_MIXED = raw"""
static PRODUCT_DROPS569: AtomicU32 = AtomicU32::new(0);
#[julia] pub fn product_drops569() -> u32 { PRODUCT_DROPS569.load(Ordering::SeqCst) }
#[julia] pub struct GlobProduct569 { pub value: f64 }
impl Drop for GlobProduct569 { fn drop(&mut self) { PRODUCT_DROPS569.fetch_add(1, Ordering::SeqCst); } }
#[julia] impl GlobProduct569 { #[julia] pub fn product_value569(&self) -> f64 { self.value } }
#[julia] pub mod glob_mixed569 {
    use super::*;
    #[julia] #[rustcall_owned_return(GlobProduct569)]
    pub fn produce(required: &Counter569, optional: Option<&Counter569>, xs: &mut [f64], mode: i32) -> Result<GlobProduct569, String> {
        if !xs.is_empty() { xs[0] += 1.0; }
        let result = GlobProduct569 { value: required.value as f64 + optional.map_or(0.0, |v| v.value as f64) + xs.iter().sum::<f64>() };
        if mode == 1 { return Err("glob mixed rejected".into()); }
        if mode == 2 { panic!("glob mixed panic"); }
        Ok(result)
    }
    #[julia] #[rustcall_owned_return(GlobProduct569)]
    pub fn mutate(required: &Counter569, optional: Option<&mut Counter569>, xs: &[f64]) -> GlobProduct569 {
        if let Some(value) = optional { value.value += 1; }
        GlobProduct569 { value: required.value as f64 + xs.iter().sum::<f64>() }
    }
    #[julia] #[rustcall_owned_return(GlobProduct569)]
    pub fn callback(required: &Counter569, optional: Option<&Counter569>, xs: &mut [f64], cb: extern "C" fn() -> i32) -> GlobProduct569 {
        if !xs.is_empty() { xs[0] += 1.0; }
        cb();
        GlobProduct569 { value: required.value as f64 + optional.map_or(0.0, |v| v.value as f64) + xs.iter().sum::<f64>() }
    }
}
"""

const GLOB569_OPERATIONS = raw"""
use super::*;
use external_scope569::ForeignCounter569;
use crate as root569;
use super as parent569;
use self as here569;
pub use super::Counter569 as OperationCounter569;
#[julia] impl Destination569 {
    #[julia] pub fn read(&mut self, source: &Counter569) -> i32 { self.value = source.value; self.value }
    #[julia] pub fn read_shared(&self, source: &Counter569) -> i32 { self.value + source.value }
    #[julia] pub fn change_source(&self, source: &mut Counter569) -> i32 { source.value += 1; source.value }
    #[julia] pub fn static_read(source: &Counter569) -> i32 { source.value }
    #[julia] #[rustcall_owned_return(GlobProduct569)]
    pub fn static_product(optional: Option<&Counter569>, xs: &[f64]) -> GlobProduct569 { GlobProduct569 { value: optional.map_or(0.0, |v| v.value as f64) + xs.iter().sum::<f64>() } }
    #[julia] pub fn root_alias_read(&self, source: &root569::Counter569) -> i32 { source.value }
    #[julia] pub fn parent_alias_read(&self, source: &parent569::Counter569) -> i32 { source.value }
    #[julia] pub fn self_alias_read(&self, source: &here569::OperationCounter569) -> i32 { source.value }
    #[julia] pub fn read_foreign(&self, source: &ForeignCounter569) -> i32 { super::external_ops569::mark_entry(); source.value() }
}
#[julia] impl Counter569 {
    #[julia] pub fn absorb(&mut self, source: &Counter569) -> i32 { self.value += source.value; self.value }
    #[julia] pub fn shared(&self, source: &Counter569) -> i32 { self.value + source.value }
    #[julia] #[rustcall_owned_return(GlobProduct569)]
    pub fn mixed_product(&self, optional: Option<&Counter569>, xs: &mut [f64]) -> Result<GlobProduct569, String> { glob_mixed569::produce(self, optional, xs, 0) }
}
"""

# This helper-shaped plain Rust type must never be confused with the
# unrelated selected owner imported through a glob. Tests inspect only its
# metadata and emitted pointer boundary; they never call this consumer shim.
const GLOB569_HELPER_SHADOW = raw"""
#[julia] pub mod helpers {
    #[julia] pub fn produce() -> String { "hello".to_owned() }
}
#[julia] pub mod owners {
    #[julia] pub struct helpers__produce_RustCallOwnedString { pub value: i32 }
}
#[julia] pub mod consumer {
    use crate::helpers::helpers__produce_RustCallOwnedString;
    use crate::owners::*;
    #[julia] pub fn helper_len569(value: &helpers__produce_RustCallOwnedString) -> i32 { value.len as i32 }
}
"""

# The attribute is an identity macro only to make this fixture executable.
# Its implementation is outside the extractor's scope proof, so no checked
# argument may be inferred from the attributed body or its descendants.
const GLOB569_REWRITTEN = raw"""
static REWRITTEN_ENTRIES569: AtomicU32 = AtomicU32::new(0);
#[julia] pub fn rewritten_entries569() -> u32 { REWRITTEN_ENTRIES569.load(Ordering::SeqCst) }
#[inject]
#[julia] pub mod rewritten569 {
    use super::*;
    #[julia] pub struct LocalOwner569 { pub value: i32 }
    #[julia] impl LocalOwner569 {
        #[julia] pub fn new(value: i32) -> Self { Self { value } }
        #[julia] pub fn mix569(&self, other: &Self) -> i32 { REWRITTEN_ENTRIES569.fetch_add(1, Ordering::SeqCst); self.value + other.value }
    }
    #[julia] pub fn root_read569(value: &Counter569) -> i32 { REWRITTEN_ENTRIES569.fetch_add(1, Ordering::SeqCst); value.value }
    #[julia] pub fn local_read569(value: &LocalOwner569) -> i32 { REWRITTEN_ENTRIES569.fetch_add(1, Ordering::SeqCst); value.value }
    #[julia] pub mod descendant569 {
        use super::*;
        #[julia] pub fn descendant_read569(value: &crate::Counter569) -> i32 { REWRITTEN_ENTRIES569.fetch_add(1, Ordering::SeqCst); value.value }
    }
}
#[julia] pub mod unaffected569 {
    #[julia] pub fn unaffected_read569(value: &crate::Counter569) -> i32 { value.value }
}
"""

function _glob569_fixture(root; explicit::Bool = false, generation::Int = 1)
    foreign = joinpath(root, "foreign")
    crate = joinpath(root, "crate")
    attribute = joinpath(root, "scope_attribute")
    mkpath(joinpath(attribute, "src"))
    write(
        joinpath(attribute, "Cargo.toml"),
        """
[package]
name = "scope_attr569"
version = "0.1.0"
edition = "2021"
[lib]
proc-macro = true
""",
    )
    write(
        joinpath(attribute, "src", "lib.rs"),
        """
extern crate proc_macro;
use proc_macro::TokenStream;
#[proc_macro_attribute]
pub fn inject(_attribute: TokenStream, item: TokenStream) -> TokenStream { item }
""",
    )
    mkpath(joinpath(foreign, "src"))
    mkpath(joinpath(crate, "src"))
    write(
        joinpath(foreign, "Cargo.toml"),
        """
[package]
name = "external_scope569"
version = "0.1.0"
edition = "2021"
""",
    )
    write(
        joinpath(foreign, "src", "lib.rs"),
        """
pub struct ForeignCounter569 { value: i32 }
impl ForeignCounter569 {
    pub fn new(value: i32) -> Self { Self { value } }
    pub fn value(&self) -> i32 { self.value }
    pub fn add(&mut self, value: i32) { self.value += value; }
}
""",
    )
    runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
    write(
        joinpath(crate, "Cargo.toml"),
        """
[package]
name = "glob_owners569"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib", "rlib"]
[dependencies]
rustcall_julia_macros = { path = "$runtime" }
external_scope569 = { path = "../foreign" }
scope_attr569 = { path = "../scope_attribute" }
""",
    )
    operations =
        explicit ?
        replace(
            GLOB569_OPERATIONS,
            "use super::*;" => "use super::{Counter569, Destination569, GlobProduct569, glob_mixed569}; use rustcall_julia_macros::julia;",
        ) : GLOB569_OPERATIONS
    write(
        joinpath(crate, "src", "lib.rs"),
        "use scope_attr569::inject;\n" *
        GLOB569_LIB *
        GLOB569_HELPER_SHADOW *
        replace(
            GLOB569_MIXED,
            "PRODUCT_DROPS569.fetch_add(1," => "PRODUCT_DROPS569.fetch_add($generation,",
        ) *
        GLOB569_REWRITTEN *
        "\n#[julia] pub fn generation569() -> i32 { $generation }\n",
    )
    write(joinpath(crate, "src", "operations.rs"), operations)
    write(
        joinpath(crate, "src", "renamed_owner569.rs"),
        raw"""
use rustcall_julia_macros::julia;
#[julia] pub struct r#PathOwner569 { pub value: i32 }
#[julia] impl r#PathOwner569 {
    #[julia] pub fn new(value: i32) -> Self { Self { value } }
    #[julia] pub fn get(&self) -> i32 { self.value }
}
""",
    )
    return crate
end

function _glob569_mixed_checks(call, mixed)
    owner, other = call(:Counter569, Int32(3)), call(:Counter569, Int32(4))
    try
        for optional in (nothing, owner)
            xs = [1.0, 2.0]
            product = RustCall.unwrap(mixed(:produce, owner, optional, xs, Int32(0)))
            try
                @test call(:product_value569, product) ==
                      (optional === nothing ? 7.0 : 10.0)
                @test xs == [2.0, 2.0]
                @test product.alive === owner.alive
                @test product.free_ptr != owner.free_ptr
            finally
                finalize(product)
            end
        end
        @test_throws ArgumentError mixed(:mutate, owner, owner, [1.0])
        product = mixed(:mutate, owner, other, [1.0])
        @test call(:static_read, call(:type_only_Destination569), other) == 5
        @test call(:product_value569, product) == 4.0
        finalize(product)
        receiver_product = RustCall.unwrap(call(:mixed_product, owner, owner, [1.0]))
        @test call(:product_value569, receiver_product) == 8.0
        finalize(receiver_product)
        static_product =
            call(:static_product, call(:type_only_Destination569), nothing, [2.0])
        @test call(:product_value569, static_product) == 2.0
        @test static_product.free_ptr != owner.free_ptr
        finalize(static_product)
        @test_throws ArgumentError mixed(:produce, owner, owner.ptr, [1.0], Int32(0))
        @test_throws ArgumentError mixed(:produce, owner, nothing, Float32[1], Int32(0))
        gone = call(:Counter569, Int32(1))
        finalize(gone)
        @test_throws RustCall.RustError mixed(:produce, owner, gone, [1.0], Int32(0))
        for mode in (Int32(1), Int32(2))
            drops = call(:product_drops569)
            xs = [1.0]
            if mode == 1
                @test mixed(:produce, owner, nothing, xs, mode).value ==
                      "glob mixed rejected"
            else
                @test_throws RustCall.RustPanicError mixed(
                    :produce,
                    owner,
                    nothing,
                    xs,
                    mode,
                )
            end
            @test xs == [2.0]
            @test call(:product_drops569) == drops + 1
        end
        xs = [1.0]
        gc_product = mixed(
            :callback,
            owner,
            call(:Counter569, Int32(5)),
            xs,
            () -> (GC.gc(); Int32(0)),
        )
        @test call(:product_value569, gc_product) == 10.0
        @test xs == [2.0]
        finalize(gc_product)
        drops = call(:product_drops569)
        @test_throws ErrorException mixed(
            :callback,
            owner,
            owner,
            [1.0],
            () -> error("glob mixed callback"),
        )
        @test call(:product_drops569) == drops + 1
        @test isempty(RustCall._callback_frames())
    finally
        foreach(finalize, (owner, other))
    end
end

function _glob569_checks(mod; path_owner_name::Symbol)
    call(name, args...) = Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
    sub(name) = Base.invokelatest(getfield, mod, name)
    subcall(module_name, fn, args...) =
        Base.invokelatest(Base.invokelatest(getfield, sub(module_name), fn), args...)
    a, b = call(:Counter569, Int32(3)), call(:Counter569, Int32(4))
    destination = call(:Destination569)
    destination_type = typeof(destination)
    try
        path_owner = call(path_owner_name, Int32(57))
        try
            @test subcall(:path_reads569, :glob, path_owner) == 57
            @test subcall(:path_reads569, :qualified, path_owner) == 57
            @test subcall(:path_reads569, :renamed_mut, path_owner) == 58
            @test_throws ArgumentError subcall(:path_reads569, :glob, a)
        finally
            finalize(path_owner)
        end
        nfc_owner = call(:Kounter569, Int32(41))
        try
            @test subcall(:nfc_alias569, :read, nfc_owner) == 41
            @test subcall(:nfc_alias569, :mutate, nfc_owner) == 42
            @test_throws ArgumentError subcall(:nfc_alias569, :read, a)
        finally
            finalize(nfc_owner)
        end
        for module_name in (:named_value569, :local_value569, :value_reexport569)
            @test subcall(module_name, :read, a) == 3
            @test_throws ArgumentError subcall(module_name, :read, destination)
        end
        named_const_owner = call(:Kounter569, Int32(42))
        try
            @test subcall(:named_const569, :read, named_const_owner) == 42
        finally
            finalize(named_const_owner)
        end
        @test subcall(:unaffected569, :unaffected_read569, a) == 3
        rewritten = sub(:rewritten569)
        local_owner = Base.invokelatest(
            Base.invokelatest(getfield, rewritten, :LocalOwner569),
            Int32(2),
        )
        rewritten_call(name, args...) =
            Base.invokelatest(Base.invokelatest(getfield, rewritten, name), args...)
        descendant = Base.invokelatest(getfield, rewritten, :descendant569)
        descendant_read = Base.invokelatest(getfield, descendant, :descendant_read569)
        try
            @test call(:rewritten_entries569) == 0
            for action in (
                () -> rewritten_call(:root_read569, a),
                () -> rewritten_call(:local_read569, local_owner),
                () -> rewritten_call(:mix569, local_owner, local_owner),
                () -> Base.invokelatest(descendant_read, a),
            )
                error = try
                    action()
                    nothing
                catch exception
                    exception
                end
                @test error isa RustCall.RustError
                @test occursin("borrowed-owner", sprint(showerror, error))
            end
            @test call(:rewritten_entries569) == 0
        finally
            finalize(local_owner)
        end
        @test call(:read, destination, a) == 3
        @test call(:read_shared, destination, a) == 6
        for name in (:root_alias_read, :parent_alias_read, :self_alias_read)
            @test call(name, destination, a) == 3
            @test_throws ArgumentError call(name, destination, destination)
        end
        @test subcall(:alias_glob569, :read, a) == 3
        @test_throws ArgumentError subcall(:alias_glob569, :mutate, a, a)
        alias_a, alias_b = call(:Counter569, Int32(1)), call(:Counter569, Int32(2))
        try
            @test subcall(:alias_glob569, :mutate, alias_a, alias_b) == 3
        finally
            foreach(finalize, (alias_a, alias_b))
        end
        @test call(:change_source, destination, a) == 4
        @test call(:static_read, destination_type, a) == 4
        @test call(:shared, a, a) == 8
        @test_throws ArgumentError call(:absorb, a, a)
        @test call(:absorb, a, b) == 8
        @test subcall(:free_ops569, :sum, a, a) == 16
        @test_throws ArgumentError subcall(:free_ops569, :mutate, a, a)
        @test subcall(:free_ops569, :mutate, a, b) == 12
        @test subcall(:precedence569, :read, a) == 12
        @test_throws ArgumentError call(:read, destination, destination)
        @test_throws ArgumentError subcall(:free_ops569, :sum, destination, a)
        gone = call(:Counter569, Int32(1))
        finalize(gone)
        @test_throws RustCall.RustError call(:read, destination, gone)
        for name in (:root_alias_read, :parent_alias_read, :self_alias_read)
            @test_throws RustCall.RustError call(name, destination, gone)
        end
        @test_throws RustCall.RustError subcall(:alias_glob569, :read, gone)
        @test_throws RustCall.RustError subcall(:free_ops569, :sum, a, gone)
        @test subcall(:free_ops569, :sum, a.ptr, b.ptr) == 16  # explicit unsafe pointer control
        @test subcall(
            :free_ops569,
            :callback,
            call(:Counter569, Int32(42)),
            () -> (GC.gc(); Int32(0)),
        ) == 42
        external = sub(:external_ops569)
        external_call(name, args...) =
            Base.invokelatest(Base.invokelatest(getfield, external, name), args...)
        before = external_call(:entries)
        for value in (a, destination, Int32(1), nothing, missing)
            for fn in (:read, :mutate, :method)
                err = try
                    fn == :method ? call(:read_foreign, destination, value) :
                    external_call(fn, value)
                    nothing
                catch e
                    e
                end
                @test err isa RustCall.RustError
                message = sprint(showerror, err)
                @test occursin("explicit import or qualified", message)
                @test !occursin("register_ffi_struct", message)
                @test !occursin("by value", message)
            end
        end
        @test external_call(:entries) == before
        # No layout assertion or guessed Julia representation: Rust allocates
        # its own external value and the caller explicitly assumes the pointer contract.
        pointer = external_call(:allocate, Int32(7))
        try
            @test pointer isa Ptr{Cvoid}
            @test external_call(:read, pointer) == 7
            @test external_call(:mutate, pointer) == 8
            @test call(:read_foreign, destination, pointer) == 8
        finally
            external_call(:release, pointer)
        end
        @test external_call(:entries) == before + 3
        mixed_module = sub(:glob_mixed569)
        mixed(name, args...) =
            Base.invokelatest(Base.invokelatest(getfield, mixed_module, name), args...)
        typed_call(name, args...) =
            name === :type_only_Destination569 ? sub(:Destination569) : call(name, args...)
        @testset "glob-resolved optional owners and slices select owned results" begin
            _glob569_mixed_checks(typed_call, mixed)
        end
    finally
        foreach(finalize, (a, b, destination))
    end
end

@testset "scoped glob owner metadata and the multi-file MWE (#569)" begin
    mktempdir() do root
        crate = _glob569_fixture(root)
        run(
            Cmd(
                `$(RustCall.cargo()) test --manifest-path $(joinpath(crate, "Cargo.toml"))`;
                dir = crate,
            ),
        )
        info = RustCall.scan_crate(crate)
        counter = only(s for s in info.julia_structs if s.name == "Counter569")
        path_owner = only(
            s for s in info.julia_structs if RustCall.rust_name(s.name) == "PathOwner569"
        )
        for name in ("glob", "qualified")
            path_reader = only(
                f for f in info.julia_functions if
                f.name == name && f.module_path == ["path_reads569"]
            )
            @test path_reader.arg_abis == ["handle"]
            @test only(path_reader.arg_handles).ffi_name == path_owner.ffi_name
            @test path_reader.arg_borrow_reasons == [""]
        end
        destination = only(s for s in info.julia_structs if s.name == "Destination569")
        for (name, abi) in (
            ("read", "handle"),
            ("read_shared", "handle"),
            ("change_source", "handle_mut"),
            ("static_read", "handle"),
        )
            method = only(m for m in destination.methods if m.name == name)
            @test method.arg_abis == [abi]
            @test only(method.arg_handles).ffi_name == counter.ffi_name
            @test method.arg_borrow_reasons == [""]
        end
        for module_name in
            ("named_value569", "local_value569", "value_reexport569", "named_const569")
            value_reader = only(
                f for f in info.julia_functions if
                f.name == "read" && f.module_path == [module_name]
            )
            @test value_reader.arg_abis == ["handle"]
            expected = module_name == "named_const569" ? "Kounter569" : "Counter569"
            @test only(value_reader.arg_handles).name == expected
        end
        for module_name in ("named_type569", "named_alias569")
            type_reader = only(
                f for f in info.julia_functions if
                f.name == "read" && f.module_path == [module_name]
            )
            @test !RustCall._is_handle_abi(only(type_reader.arg_abis))
            @test only(type_reader.arg_handles) === nothing
        end
        nfc_owner = only(s for s in info.julia_structs if s.name == "Kounter569")
        for (name, abi) in (("read", "handle"), ("mutate", "handle_mut"))
            nfc_reader = only(
                f for f in info.julia_functions if
                f.name == name && f.module_path == ["nfc_alias569"]
            )
            @test nfc_reader.arg_abis == [abi]
            @test only(nfc_reader.arg_handles).ffi_name == nfc_owner.ffi_name
        end
        nfc_plain = only(
            f for f in info.julia_functions if
            f.name == "read" && f.module_path == ["nfc_shadow569"]
        )
        @test !RustCall._is_handle_abi(only(nfc_plain.arg_abis))
        @test only(nfc_plain.arg_handles) === nothing
        plain = only(
            f for f in info.julia_functions if
            f.name == "read" && f.module_path == ["local_shadow569"]
        )
        @test !RustCall._is_handle_abi(only(plain.arg_abis))
        @test only(plain.arg_handles) === nothing
        unresolved = only(
            f for f in info.julia_functions if
            f.name == "read" && f.module_path == ["external_ops569"]
        )
        @test unresolved.arg_abis == ["borrow_unresolved"]
        @test !isempty(only(unresolved.arg_borrow_reasons))
        for name in ("root_read569", "local_read569", "descendant_read569")
            rewritten_reader = only(f for f in info.julia_functions if f.name == name)
            @test rewritten_reader.arg_abis == ["borrow_unresolved"]
            @test only(rewritten_reader.arg_handles) === nothing
        end
        local_owner = only(s for s in info.julia_structs if s.name == "LocalOwner569")
        self_borrow = only(m for m in local_owner.methods if m.name == "mix569")
        @test self_borrow.arg_abis == ["borrow_unresolved"]
        @test only(self_borrow.arg_handles) === nothing
        mixed_producer = only(
            f for f in info.julia_functions if
            f.name == "produce" && f.module_path == ["glob_mixed569"]
        )
        @test mixed_producer.arg_abis == ["handle", "handle_optional", "slice_mut", ""]
        @test mixed_producer.arg_borrow_reasons == fill("", 4)
        @test mixed_producer.arg_slice_elements == ["", "", "f64", ""]
        @test mixed_producer.return_handle.name == "GlobProduct569"
        helper_consumer = only(f for f in info.julia_functions if f.name == "helper_len569")
        @test helper_consumer.arg_abis == [""]
        @test only(helper_consumer.arg_handles) === nothing
        @test helper_consumer.arg_borrow_reasons == [""]
        report = RustCall.boundary_report(crate; io = devnull)
        findings = filter(
            f -> f.item in ("external_ops569::read", "external_ops569::mutate"),
            report.unsupported,
        )
        helper_finding =
            only(f for f in report.unsupported if f.item == "consumer::helper_len569")
        @test occursin("not in the FFI contract", helper_finding.reason) &&
              !occursin("borrowed-owner", helper_finding.reason)
        @test length(findings) == 2
        @test all(f -> occursin("explicit import or qualified", f.reason), findings)
        binding = @rust_crate crate
        direct = getfield(binding, :module_ref)
        output = joinpath(root, "WrittenGlob569.jl")
        RustCall.write_bindings_to_file(
            crate,
            output;
            output_module_name = "WrittenGlob569",
        )
        sandbox = Module(:WrittenGlobSandbox569)
        Base.include(sandbox, output)
        written = Base.invokelatest(getfield, sandbox, :WrittenGlob569)
        for mod in (direct, written)
            lib = Base.invokelatest(getfield, mod, :_LIB_NAME)
            target = RustCall.resolve_call_target(lib, mixed_producer.symbol)
            for suffix in (
                "_slice_ptr_len_v1",
                "_optional_owner_ptr_v1",
                "_owned_return_v1",
                "_boxed_result_v1",
            )
                @test RustCall.Libdl.dlsym(target.handle, mixed_producer.symbol * suffix) !=
                      C_NULL
            end
        end
        # Inspect both real emitted surfaces without invoking the shim. Its
        # pointer type is a generated plain buffer, never the selected owner.
        for mod in (direct, written)
            consumer_module = Base.invokelatest(getfield, mod, :consumer)
            consumer_function = Base.invokelatest(getfield, consumer_module, :helper_len569)
            lowered = sprint(show, Base.code_lowered(consumer_function, Tuple{Any}))
            @test !occursin("check_not_freed", lowered)
        end
        try
            @testset "direct" begin
                _glob569_checks(
                    direct;
                    path_owner_name = Symbol(RustCall.julia_struct_name(path_owner)),
                )
            end
            @testset "persisted" begin
                _glob569_checks(
                    written;
                    path_owner_name = Symbol(RustCall.julia_struct_name(path_owner)),
                )
            end
            @testset "captured producing image" begin
                call(mod, name, args...) =
                    Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
                old = [call(mod, :Counter569, Int32(7)) for mod in (direct, written)]
                mixed(mod, owner) = begin
                    scope = Base.invokelatest(getfield, mod, :glob_mixed569)
                    RustCall.unwrap(
                        Base.invokelatest(
                            Base.invokelatest(getfield, scope, :produce),
                            owner,
                            nothing,
                            [1.0],
                            Int32(0),
                        ),
                    )
                end
                old_products =
                    [mixed(mod, owner) for (mod, owner) in zip((direct, written), old)]
                count(target) = RustCall.call_rust_function(target.func_ptr, UInt32)
                old_counters = [
                    RustCall.resolve_call_target(
                        Base.invokelatest(getfield, mod, :_LIB_NAME),
                        "rustcall_product_drops569";
                        fallback = false,
                    ) for mod in (direct, written)
                ]
                before_old = count.(old_counters)
                new_products = Any[]
                replacement_crate =
                    _glob569_fixture(joinpath(root, "replacement"); generation = 2)
                replacement_binding = @rust_crate replacement_crate
                replacement = getfield(replacement_binding, :module_ref)
                replacement_lib = Base.invokelatest(getfield, replacement, :_LIB_NAME)
                fresh = Any[]
                try
                    targets = unique([
                        Base.invokelatest(getfield, mod, :_LIB_NAME) for
                        mod in (direct, written)
                    ])
                    for target in targets
                        @test RustCall.alias_artifact!(
                            RustCall.crate_direct_policy(),
                            replacement_lib,
                            target,
                        )
                    end
                    new_counter = RustCall.resolve_call_target(
                        replacement_lib,
                        "rustcall_product_drops569";
                        fallback = false,
                    )
                    before_new = count(new_counter)
                    for (index, (mod, previous)) in enumerate(zip((direct, written), old))
                        current = call(mod, :Counter569, Int32(9))
                        receiver = call(mod, :Destination569)
                        append!(fresh, (current, receiver))
                        product = mixed(mod, current)
                        push!(new_products, product)
                        @test product.alive !== old_products[index].alive
                        @test product.free_ptr != old_products[index].free_ptr
                        @test call(mod, :product_value569, product) == 11.0
                        @test previous.alive !== current.alive
                        @test previous.alive[]
                        @test call(mod, :read, receiver, current) == 9
                        @test_throws ArgumentError call(mod, :read, receiver, previous)
                        @test_throws ArgumentError call(
                            mod,
                            :change_source,
                            receiver,
                            previous,
                        )
                        free = Base.invokelatest(getfield, mod, :free_ops569)
                        sumfn = Base.invokelatest(getfield, free, :sum)
                        @test Base.invokelatest(sumfn, current, current) == 18
                        @test_throws ArgumentError Base.invokelatest(
                            sumfn,
                            previous,
                            current,
                        )
                        @test_throws ArgumentError Base.invokelatest(
                            sumfn,
                            previous,
                            previous,
                        )
                    end
                    foreach(finalize, old_products)
                    @test all(
                        count(target) >= baseline + 1 for
                        (target, baseline) in zip(old_counters, before_old)
                    )
                    @test count(new_counter) == before_new
                    after_old = count.(old_counters)
                    foreach(finalize, new_products)
                    @test count(new_counter) == before_new + 2 * length(new_products)
                    @test count.(old_counters) == after_old
                finally
                    foreach(finalize, old_products)
                    foreach(finalize, new_products)
                    foreach(finalize, old)
                    foreach(finalize, fresh)
                    haskey(RustCall.RUST_LIBRARIES, replacement_lib) &&
                        RustCall.unload_library(replacement_lib; close = true)
                end
            end
        finally
            for mod in (direct, written)
                lib = Base.invokelatest(getfield, mod, :_LIB_NAME)
                haskey(RustCall.RUST_LIBRARIES, lib) &&
                    RustCall.unload_library(lib; close = true)
            end
        end
    end
end

@testset "explicit imports preserve the glob-control contract (#569)" begin
    mktempdir() do root
        crate = _glob569_fixture(root; explicit = true)
        path_owner = only(
            s for s in RustCall.scan_crate(crate).julia_structs if
            RustCall.rust_name(s.name) == "PathOwner569"
        )
        binding = @rust_crate crate
        mod = getfield(binding, :module_ref)
        try
            _glob569_checks(
                mod;
                path_owner_name = Symbol(RustCall.julia_struct_name(path_owner)),
            )
        finally
            RustCall.unload_library(
                Base.invokelatest(getfield, mod, :_LIB_NAME);
                close = true,
            )
        end
    end
end

@testset "inline unresolved scoped borrows stop before FFI (#569)" begin
    mktempdir() do root
        _glob569_fixture(root)
        dependency = RustCall.escape_toml_string(joinpath(root, "foreign"))
        source = """
        //! ```cargo
        //! [dependencies]
        //! external_scope569 = { path = "$dependency" }
        //! ```
        use external_scope569::*;
        use std::sync::atomic::{AtomicU32, Ordering};
        static ENTRIES569: AtomicU32 = AtomicU32::new(0);
        #[julia] pub struct Inline569 { value: i32 }
        #[julia] impl Inline569 { pub fn new(value:i32)->Self {Self {value}} }
        #[julia] pub fn entries569()->u32 { ENTRIES569.load(Ordering::SeqCst) }
        #[julia] pub fn read569(a:&ForeignCounter569)->i32 { ENTRIES569.fetch_add(1,Ordering::SeqCst);a.value() }
        #[julia] pub fn callback569(a:&ForeignCounter569,f:extern "C" fn()->i32)->i32 {ENTRIES569.fetch_add(1,Ordering::SeqCst);f();a.value()}
        #[julia] pub fn allocate569(value:i32)->*mut ForeignCounter569 {Box::into_raw(Box::new(ForeignCounter569::new(value)))}
        #[julia] pub fn release569(value:*mut ForeignCounter569) {if !value.is_null(){unsafe{drop(Box::from_raw(value));}}}
        """
        mod = Module(gensym(:InlineGlob569))
        Core.eval(mod, :(using RustCall))
        lib =
            Core.eval(mod, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
        call(name, args...) =
            Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
        owner = call(:Inline569, Int32(1))
        try
            for value in (owner, Int32(1), nothing, missing)
                @test_throws RustCall.RustError call(:read569, value)
                @test_throws RustCall.RustError call(:callback569, value, () -> Int32(0))
                @test isempty(RustCall._callback_frames())
            end
            @test call(:entries569) == 0
            pointer = call(:allocate569, Int32(42))
            try
                @test call(:read569, pointer) == 42
                @test call(:callback569, pointer, () -> (GC.gc(); Int32(0))) == 42
            finally
                call(:release569, pointer)
            end
            @test call(:entries569) == 2
        finally
            finalize(owner)
            RustCall.unload_library(lib; close = true)
        end
    end
end

@testset "borrow-reason metadata is optional and aligned (#569)" begin
    signature = RustCall.RustFunctionSignature(
        "plain569",
        ["value"],
        ["i32"],
        "i32",
        false,
        String[],
    )
    @test signature.arg_borrow_reasons == [""]
    @test_throws ArgumentError RustCall.RustFunctionSignature(
        "bad569",
        ["value"],
        ["i32"],
        "i32",
        false,
        String[];
        arg_borrow_reasons = String[],
    )
    method = RustCall.RustMethod("plain569", true, false, ["value"], ["i32"], "i32")
    @test method.arg_borrow_reasons == [""]
    @test_throws ArgumentError RustCall.RustMethod(
        "bad569",
        true,
        false,
        ["value"],
        ["i32"],
        "i32";
        arg_borrow_reasons = String[],
    )
    argument = Dict{String,Any}(
        "name" => "value",
        "type" => "&Foreign",
        "abi" => "borrow_unresolved",
        "borrow_reason" => "external glob is opaque",
    )
    manifest = Dict{String,Any}(
        "functions" => [
            Dict{String,Any}(
                "name" => "unknown569",
                "attribute" => "julia",
                "args" => [argument],
                "return_type" => "i32",
            ),
        ],
    )
    decoded = only(RustCall.manifest_function_signatures(manifest))
    @test decoded.arg_borrow_reasons == ["external glob is opaque"]
    delete!(argument, "borrow_reason")
    @test only(RustCall.manifest_function_signatures(manifest)).arg_borrow_reasons == [""]
    pointer = Ptr{Cvoid}(UInt(1))
    @test RustCall.ffi_unresolved_borrow_argument(pointer, "unresolved") === pointer
    @test_throws RustCall.RustError RustCall.ffi_unresolved_borrow_argument(
        Ptr{UInt8}(UInt(1)),
        "unresolved",
    )
end

@testset "inline JuliaStruct-derived owners use checked borrows (#569)" begin
    source = raw"""
    #[derive(JuliaStruct)]
    pub struct DerivedOwner569 { value: i32 }
    impl DerivedOwner569 {
        pub fn new(value: i32) -> Self { Self { value } }
        pub fn get(&self) -> i32 { self.value }
    }
    #[julia] pub fn derived_read569(value: &DerivedOwner569) -> i32 { value.value }
    #[julia] pub fn derived_mutate569(value: &mut DerivedOwner569) -> i32 { value.value += 1; value.value }
    #[julia] pub fn derived_sum569(a: &DerivedOwner569, b: &DerivedOwner569) -> i32 { a.value + b.value }
    #[julia] pub fn derived_add569(a: &mut DerivedOwner569, b: &DerivedOwner569) -> i32 { a.value += b.value; a.value }
    """
    signatures = Dict(
        s.name => s for s in
        RustCall.manifest_function_signatures(RustCall.expand_inline(source).manifest)
    )
    @test signatures["derived_read569"].arg_abis == ["handle"]
    @test signatures["derived_mutate569"].arg_abis == ["handle_mut"]
    @test signatures["derived_add569"].arg_abis == ["handle_mut", "handle"]
    @test all(
        h -> h !== nothing && h.name == "DerivedOwner569",
        signatures["derived_add569"].arg_handles,
    )
    mod = Module(gensym(:DerivedGlob569))
    Core.eval(mod, :(using RustCall))
    lib = Core.eval(mod, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
    call(name, args...) = Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
    owner, other, gone = (call(:DerivedOwner569, Int32(n)) for n in (42, 2, 1))
    try
        @test call(:get, owner) == 42
        @test call(:derived_read569, owner) == 42
        @test call(:derived_mutate569, owner) == 43
        @test call(:derived_sum569, owner, owner) == 86
        @test_throws ArgumentError call(:derived_add569, owner, owner)
        @test call(:derived_add569, owner, other) == 45
        @test_throws ArgumentError call(:derived_read569, Int32(1))
        finalize(gone)
        @test_throws RustCall.RustError call(:derived_read569, gone)
        @test_throws RustCall.RustError call(:derived_mutate569, gone)
    finally
        foreach(finalize, (owner, other, gone))
        RustCall.unload_library(lib; close = true)
    end
end

@testset "inline anchored module aliases preserve checked owners (#569)" begin
    source = raw"""
    use crate as root569;
    use self as here569;
    #[julia] pub struct AliasOwner569 { pub value: i32 }
    #[julia] impl AliasOwner569 { pub fn new(value: i32) -> Self { Self { value } } }
    #[julia] pub fn root_read569(value: &root569::AliasOwner569) -> i32 { value.value }
    #[julia] pub fn self_read569(value: &here569::AliasOwner569) -> i32 { value.value }
    #[julia] pub mod alias_scope569 {
        use super as parent569;
        use self::parent569::*;
        #[julia] pub fn parent_read569(value: &parent569::AliasOwner569) -> i32 { value.value }
        #[julia] pub fn glob_read569(value: &AliasOwner569) -> i32 { value.value }
        #[julia] pub fn alias_mutate569(a: &mut AliasOwner569, b: &AliasOwner569) -> i32 { a.value += b.value; a.value }
    }
    """
    signatures = Dict(
        s.name => s for s in
        RustCall.manifest_function_signatures(RustCall.expand_inline(source).manifest)
    )
    for name in ("root_read569", "self_read569", "parent_read569", "glob_read569")
        @test signatures[name].arg_abis == ["handle"]
        @test only(signatures[name].arg_handles).name == "AliasOwner569"
    end
    @test signatures["alias_mutate569"].arg_abis == ["handle_mut", "handle"]
    mod = Module(gensym(:AnchoredAlias569))
    Core.eval(mod, :(using RustCall))
    lib = Core.eval(mod, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
    call(name, args...) = Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
    owner, other, gone = (call(:AliasOwner569, Int32(n)) for n in (42, 2, 1))
    try
        for name in (:root_read569, :self_read569, :parent_read569, :glob_read569)
            @test call(name, owner) == 42
            @test_throws ArgumentError call(name, Int32(1))
        end
        @test_throws ArgumentError call(:alias_mutate569, owner, owner)
        @test call(:alias_mutate569, owner, other) == 44
        finalize(gone)
        for name in (:root_read569, :self_read569, :parent_read569, :glob_read569)
            @test_throws RustCall.RustError call(name, gone)
        end
        @test_throws RustCall.RustError call(:alias_mutate569, gone, other)
    finally
        foreach(finalize, (owner, other, gone))
        RustCall.unload_library(lib; close = true)
    end
end

@testset "inline type lookup ignores value-only namespace shadows (#569)" begin
    source = raw"""
    #[julia] pub struct NamespaceOwner569 { pub value: i32 }
    #[julia] impl NamespaceOwner569 { pub fn new(value: i32) -> Self { Self { value } } }
    mod functions569 { pub fn NamespaceOwner569() -> i32 { 99 } }
    mod constants569 { pub const NamespaceOwner569: i32 = 99; }
    mod reexports569 { pub use crate::functions569::NamespaceOwner569; }
    mod types569 { pub struct NamespaceOwner569 { pub value: i64 } }
    mod aliases569 { pub type NamespaceOwner569 = super::types569::NamespaceOwner569; }
    #[julia] pub mod named_function569 {
        use super::*;
        use crate::functions569::NamespaceOwner569;
        #[julia] pub fn read_function569(value: &NamespaceOwner569) -> i32 { value.value }
    }
    #[julia] pub mod named_constant569 {
        use super::*;
        use crate::constants569::NamespaceOwner569;
        #[julia] pub fn read_constant569(value: &NamespaceOwner569) -> i32 { value.value }
    }
    #[julia] pub mod local_function569 {
        use super::*;
        pub fn NamespaceOwner569() -> i32 { 99 }
        #[julia] pub fn read_local569(value: &NamespaceOwner569) -> i32 { value.value }
    }
    #[julia] pub mod function_reexport569 {
        use super::*;
        use crate::reexports569::NamespaceOwner569;
        #[julia] pub fn read_reexport569(value: &NamespaceOwner569) -> i32 { value.value }
    }
    #[julia] pub mod named_plain_type569 {
        use super::*;
        use crate::types569::NamespaceOwner569;
        #[julia] pub fn read_plain_type569(value: &NamespaceOwner569) -> i32 { value.value as i32 }
    }
    #[julia] pub mod named_type_alias569 {
        use super::*;
        use crate::aliases569::NamespaceOwner569;
        #[julia] pub fn read_type_alias569(value: &NamespaceOwner569) -> i32 { value.value as i32 }
    }
    """
    signatures = Dict(
        s.name => s for s in
        RustCall.manifest_function_signatures(RustCall.expand_inline(source).manifest)
    )
    readers = (:read_function569, :read_constant569, :read_local569, :read_reexport569)
    for name in readers
        @test signatures[String(name)].arg_abis == ["handle"]
        @test only(signatures[String(name)].arg_handles).name == "NamespaceOwner569"
    end
    for name in ("read_plain_type569", "read_type_alias569")
        @test !RustCall._is_handle_abi(only(signatures[name].arg_abis))
        @test only(signatures[name].arg_handles) === nothing
    end
    mod = Module(gensym(:Namespace569))
    Core.eval(mod, :(using RustCall))
    lib = Core.eval(mod, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
    call(name, args...) = Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
    owner = call(:NamespaceOwner569, Int32(42))
    try
        for name in readers
            @test call(name, owner) == 42
            @test_throws ArgumentError call(name, Int32(1))
        end
        finalize(owner)
        for name in readers
            @test_throws RustCall.RustError call(name, owner)
        end
    finally
        finalize(owner)
        RustCall.unload_library(lib; close = true)
    end
end

@testset "public generated helper types cannot become unrelated owners (#569)" begin
    signatures = RustCall.manifest_function_signatures(
        RustCall.expand_inline(GLOB569_HELPER_SHADOW).manifest,
    )
    consumer = only(s for s in signatures if s.name == "helper_len569")
    @test consumer.arg_abis == [""]
    @test only(consumer.arg_handles) === nothing
    @test consumer.arg_borrow_reasons == [""]
    wrapper = RustCall._generate_single_wrapper(consumer)
    @test !occursin("check_not_freed", sprint(show, wrapper))
    report = RustCall.inline_boundary_report(GLOB569_HELPER_SHADOW; io = devnull)
    finding = only(f for f in report.unsupported if occursin("helper_len569", f.item))
    @test occursin("not in the FFI contract", finding.reason) &&
          !occursin("borrowed-owner", finding.reason)
end

@testset "attributed module bodies and descendants cannot prove owner borrows (#569)" begin
    mktempdir() do root
        _glob569_fixture(root)
        dependency = RustCall.escape_toml_string(joinpath(root, "scope_attribute"))
        source =
            """
   //! ```cargo
   //! [dependencies]
   //! scope_attr569 = { path = "$dependency" }
   //! ```
   use scope_attr569::inject;
   use std::sync::atomic::{AtomicU32, Ordering};
   #[julia] pub struct Counter569 { pub value: i32 }
   #[julia] impl Counter569 { pub fn new(value: i32) -> Self { Self { value } } }
   """ *
            GLOB569_MIXED *
            GLOB569_REWRITTEN
        manifest = RustCall.expand_inline(source).manifest
        signatures =
            Dict(s.name => s for s in RustCall.manifest_function_signatures(manifest))
        for name in ("root_read569", "local_read569", "descendant_read569")
            @test signatures[name].arg_abis == ["borrow_unresolved"]
            @test only(signatures[name].arg_handles) === nothing
        end
        local_info = only(
            s for
            s in RustCall.manifest_struct_infos(manifest) if s.name == "LocalOwner569"
        )
        self_borrow = only(m for m in local_info.methods if m.name == "mix569")
        @test self_borrow.arg_abis == ["borrow_unresolved"]
        @test only(self_borrow.arg_handles) === nothing
        @test signatures["unaffected_read569"].arg_abis == ["handle"]
        mod = Module(gensym(:Rewritten569))
        Core.eval(mod, :(using RustCall))
        lib =
            Core.eval(mod, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
        call(name, args...) =
            Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
        owner = call(:Counter569, Int32(42))
        local_owner = call(:LocalOwner569, Int32(2))
        try
            @test call(:unaffected_read569, owner) == 42
            @test call(:rewritten_entries569) == 0
            for (name, arguments) in (
                (:root_read569, (owner,)),
                (:local_read569, (local_owner,)),
                (:descendant_read569, (owner,)),
                (:mix569, (local_owner, local_owner)),
            )
                error = try
                    call(name, arguments...)
                    nothing
                catch exception
                    exception
                end
                @test error isa RustCall.RustError
                @test occursin("borrowed-owner", sprint(showerror, error))
            end
            @test call(:rewritten_entries569) == 0
        finally
            foreach(finalize, (owner, local_owner))
            RustCall.unload_library(lib; close = true)
        end
    end
end

@testset "inline glob-resolved optional and slice inputs select owned products (#569)" begin
    source =
        raw"""
use std::sync::atomic::{AtomicU32, Ordering};
#[julia] pub struct Counter569 { pub value: i32 }
#[julia] impl Counter569 {
    pub fn new(value: i32) -> Self { Self { value } }
    #[julia] #[rustcall_owned_return(GlobProduct569)]
    pub fn mixed_product(&self, optional: Option<&Counter569>, xs: &mut [f64]) -> Result<GlobProduct569, String> { glob_mixed569::produce(self, optional, xs, 0) }
}
#[julia] pub struct Destination569 { value: i32 }
#[julia] impl Destination569 {
    pub fn static_read(value: &Counter569) -> i32 { value.value }
    #[julia] #[rustcall_owned_return(GlobProduct569)]
    pub fn static_product(optional: Option<&Counter569>, xs: &[f64]) -> GlobProduct569 { GlobProduct569 { value: optional.map_or(0.0, |v| v.value as f64) + xs.iter().sum::<f64>() } }
}
""" * GLOB569_MIXED
    mod = Module(gensym(:GlobMixed569))
    Core.eval(mod, :(using RustCall))
    lib = Core.eval(mod, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
    call(name, args...) =
        name === :type_only_Destination569 ?
        Base.invokelatest(getfield, mod, :Destination569) :
        Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
    mixed(name, args...) =
        Base.invokelatest(Base.invokelatest(getfield, mod, name), args...)
    try
        _glob569_mixed_checks(call, mixed)
    finally
        RustCall.unload_library(lib; close = true)
    end
end

@testset "rewritten optional owned consumers remain metadata refusals (#569)" begin
    refused = raw"""
    #[inject]
    #[julia] pub mod owned_opaque569 {
        use super::*;
        #[julia] #[rustcall_owned_return(GlobProduct569)]
        pub fn refused_product569(optional: Option<&Counter569>, xs: &mut [f64]) -> Result<GlobProduct569, String> { Ok(GlobProduct569 { value: optional.map_or(0.0, |v| v.value as f64) + xs.iter().sum::<f64>() }) }
    }
    """
    prefix = raw"""
    #[julia] pub struct Counter569 { pub value: i32 }
    #[julia] pub struct GlobProduct569 { pub value: f64 }
    """
    manifest = RustCall.extract_manifest(prefix * refused; mode = "inline")
    signature = only(
        f for f in RustCall.manifest_function_signatures(manifest) if
        f.name == "refused_product569"
    )
    @test startswith(signature.skip_reason, "owned_return:")
    @test signature.arg_abis == ["optional_borrow", "slice_mut"]
    @test !isempty(first(signature.arg_borrow_reasons))
    @test_throws RustCall.RustError RustCall._string_arg_plan(signature, identity)
    mktempdir() do root
        crate = _glob569_fixture(root)
        open(joinpath(crate, "src", "lib.rs"), "a") do io
            write(io, refused)
        end
        info = RustCall.scan_crate(crate)
        consumer = only(f for f in info.julia_functions if f.name == "refused_product569")
        @test startswith(consumer.skip_reason, "owned_return:")
        @test consumer.arg_abis == ["optional_borrow", "slice_mut"]
        @test !isempty(first(consumer.arg_borrow_reasons))
        report = RustCall.boundary_report(crate; io = devnull)
        @test any(
            f -> occursin("refused_product569", f.item) && occursin("owned", f.reason),
            report.unsupported,
        )
    end
end
