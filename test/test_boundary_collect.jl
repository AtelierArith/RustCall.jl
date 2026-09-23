using Test
using RustCall

# The boundary report is computed by the wrapper generators themselves (#454):
# `boundary_report` / `inline_boundary_report` run the emitters `rust"""` and
# `@rust_crate` run, in a collecting mode where every argument and return
# position a generator decides is recorded and a refusal is a finding instead
# of a `RustError`. Nothing in `src/boundary_report.jl` re-reads the manifest,
# so a rule added to a generator is in the report by construction — which is
# what the last testset shows, by adding one.

const BC_SAMPLE_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate")

_bc_keys(positions) = [(p.item, p.position) for p in positions]

@testset "no generation rule is duplicated in src/boundary_report.jl (#454)" begin
    source = read(joinpath(dirname(@__DIR__), "src", "boundary_report.jl"), String)
    # The helpers the report of #450 consulted on its own, and the manifest
    # columns it read to decide what generation wraps. None is named here any
    # more: the report runs the generators and prints what they recorded.
    for name in ("ffi_argument_contract", "ffi_return_contract", "ffi_callback_plan",
                 "field_is_accessible", "_ffi_field_return", "CALLBACK_SLOTS",
                 "returns_boxed_struct", "is_generic", "return_kind", "ok_type",
                 "inner_type", "\"attribute\"", "\"vis\"", "\"args\"", "\"methods\"",
                 # The notes of #490 are decided by the generators too.
                 ":pointer", "_boundary_raw_pointer_return!", "_boundary_unguarded_export!",
                 "_boundary_note!", ":none")
        @test !occursin(name, source)
    end
    @test occursin("_collect_boundary", source)
    @test occursin("_inline_wrapper_exprs", source)
    @test occursin("_crate_wrapper_exprs", source)
end

@testset "collecting mode records where generation would refuse, and only there (#454)" begin
    @test !RustCall._boundary_collecting()
    RustCall.inline_boundary_report("#[julia]\npub fn f(v: Vec<u8>) -> i32 { 0 }"; io = devnull)
    @test !RustCall._boundary_collecting()

    manifest = RustCall.extract_manifest("#[julia]\npub fn g(n: i32) -> Vec<u8> { Vec::new() }";
                                         mode = "inline")
    signatures = RustCall.manifest_function_signatures(manifest)
    # Outside the report, generation refuses the return exactly as before.
    @test_throws RustCall.RustError RustCall.emit_julia_function_wrappers(signatures)
    # Inside it, the refusal is recorded against the item and position, and
    # the generator completes so every position of the item is examined.
    collector = RustCall._collect_boundary() do
        RustCall.emit_julia_function_wrappers(signatures)
    end
    @test _bc_keys(collector.positions) == [("g", "argument `n`"), ("g", "return")]
    @test collector.positions[1].reason === nothing
    @test collector.positions[2].reason == "Vec<u8>: not in the FFI contract"
    @test !RustCall._boundary_collecting()

    # A generator's own refusal throws outside collecting mode ...
    @test_throws RustCall.RustError RustCall._boundary_refuse("return", "i32", "", "refused")
    # ... and a position recorded with no item named is an error, so an
    # emitter that forgets `_boundary_item!` fails the report rather than
    # misfiling its findings.
    @test_throws ArgumentError RustCall._collect_boundary() do
        RustCall._boundary_examined!("return", "i32", "", nothing)
    end
    @test !RustCall._boundary_collecting()
    # A report is one run of the generators: collecting does not nest.
    @test_throws ArgumentError RustCall._collect_boundary() do
        RustCall._collect_boundary(() -> nothing)
    end
    @test !RustCall._boundary_collecting()

    # A position decided more than once — the surface symbol and the C slot of
    # a payload, a field's getter and its setter — counts once, and the first
    # refusal recorded for it is the one kept.
    collector = RustCall._collect_boundary() do
        RustCall._boundary_item!("S::x")
        RustCall._boundary_examined!("field getter", "Vec<f64>", "", nothing)
        RustCall._boundary_examined!("field getter", "Vec<f64>", "", "first")
        RustCall._boundary_examined!("field getter", "Vec<f64>", "", "second")
    end
    @test length(collector.positions) == 1
    @test collector.positions[1].reason == "first"

    # Notes (#490) follow the same rules: filed under the named item, one per
    # `(item, position, note)`, an error with no item named, a no-op outside
    # collecting mode.
    @test RustCall._boundary_note!("return", "*mut u8", "n") === nothing
    collector = RustCall._collect_boundary() do
        RustCall._boundary_item!("f")
        RustCall._boundary_note!("return", "*mut u8", "n")
        RustCall._boundary_note!("return", "*mut u8", "n")
    end
    @test collector.notes == [(; item = "f", position = "return", rust_type = "*mut u8", note = "n")]
    @test isempty(collector.positions)
    @test_throws ArgumentError RustCall._collect_boundary() do
        RustCall._boundary_note!("return", "*mut u8", "n")
    end
    @test !RustCall._boundary_collecting()
end

# The notes of #490 come from the generators that make the decisions: the
# `@rust` registry of a loaded block (`_manifest_registry_entries`) notes a
# hand-written export and its raw-pointer return, and the `#[julia]` return
# helper notes a raw pointer — while, outside the report, the registry rows
# are what they always were.
@testset "the generators record the notes of #490" begin
    manifest = RustCall.extract_manifest(raw"""
        #[no_mangle]
        pub extern "C" fn make_buf(n: usize) -> *mut u8 { std::ptr::null_mut() }
        #[julia]
        pub fn jptr(n: i32) -> *const u8 { std::ptr::null() }
        """; mode = "inline")
    signatures = RustCall._registry_signatures(manifest)
    outside = RustCall._manifest_registry_entries(signatures)
    registry = RustCall._collect_boundary() do
        @test RustCall._manifest_registry_entries(signatures) == outside
    end
    @test Set((n.item, n.position) for n in registry.notes) ==
          Set([("make_buf", "entry point"), ("make_buf", "return")])
    wrappers = RustCall._collect_boundary() do
        RustCall.emit_julia_function_wrappers(RustCall.manifest_function_signatures(manifest))
    end
    @test [(n.item, n.position) for n in wrappers.notes] == [("jptr", "return")]
end

# `@rust_crate` binds a crate through the expression emitters and
# `write_bindings_to_file` through the source-text ones; both flavours decide
# every position through the same helpers, so run in collecting mode they
# record the same positions in the same order.
@testset "the expression and source-text crate emitters examine the same positions (#454)" begin
    _, _, manifest = RustCall._crate_manifest(BC_SAMPLE_CRATE;
                                              cfg_text = RustCall._rustc_cfg_text(),
                                              allow_cargo = false)
    functions = RustCall.manifest_function_signatures(manifest)
    structs = RustCall.manifest_struct_infos(manifest)
    tree = RustCall._module_tree(functions, structs)
    exprs = RustCall._collect_boundary() do
        RustCall._crate_wrapper_exprs(tree)
    end
    source = RustCall._collect_boundary() do
        for f in tree.functions
            f.is_generic || RustCall._emit_function_code(f)
        end
        colliding = RustCall._static_method_collisions(tree.functions, tree.structs)
        for s in tree.structs
            RustCall._emit_struct_code(s; colliding = colliding)
        end
        RustCall._submodule_code(tree)
    end
    @test !isempty(exprs.positions)
    @test exprs.positions == source.positions
    # And what they record is what the report says.
    report = RustCall.boundary_report(BC_SAMPLE_CRATE; io = devnull)
    @test report.checked == length(exprs.positions)
end

# The acceptance test of #454: a refusal generation did not have before is
# added to a generator — as a method of the argument plan, in a child process
# so nothing leaks into this one — and the report lists it, with the report's
# code untouched. The rule uses `_boundary_refuse`, which is how every
# refusal a generator makes on its own is raised: a `RustError` outside the
# report, a finding inside it.
@testset "a refusal added to a generator is in the report without touching it (#454)" begin
    script = raw"""
        using RustCall
        Core.eval(RustCall, quote
            function _string_arg_plan(arg_names::Vector{String}, arg_types::Vector{String},
                                      arg_abis::Vector{String}, escape::typeof(esc); kwargs...)
                plan = invoke(_string_arg_plan,
                              Tuple{Vector{String}, Vector{String}, Vector{String}, Function},
                              arg_names, arg_types, arg_abis, escape; kwargs...)
                for (name, rust_type, abi) in zip(arg_names, arg_types, arg_abis)
                    rust_type == "u8" && _boundary_refuse("argument `$(name)`", rust_type, abi,
                        "synthetic rule (#454): `u8` arguments are refused")
                end
                return plan
            end
        end)
        source = "#[julia]\npub fn f(a: u8, b: i32) -> i32 { 0 }"
        # Generation itself now refuses the block ...
        scope = Module()
        Core.eval(scope, :(using RustCall))
        generated = try
            Core.eval(scope, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
            "generated"
        catch err
            sprint(showerror, err)
        end
        # ... and the report lists the same refusal.
        report = RustCall.inline_boundary_report(source; io = devnull)
        println(occursin("synthetic rule (#454)", generated))
        println(report.checked)
        for u in report.unsupported
            println(u.item, "|", u.position, "|", u.rust_type, "|", u.reason)
        end
        """
    out = withenv("RUSTCALL_SUPPRESS_HELPERS_WARNING" => "1") do
        readchomp(`$(Base.julia_cmd()) --startup-file=no --project=$(pkgdir(RustCall)) -e $script`)
    end
    lines = split(out, '\n')
    @test lines[1] == "true"
    @test lines[2] == "3"
    @test lines[3:end] == ["f|argument `a`|u8|synthetic rule (#454): `u8` arguments are refused"]
end

# Found while deriving the report (#454): `emit_julia_definitions` resolved
# the `Self` spelling of an instance method through the return contract before
# deciding the result was a boxed handle, so `rust"""` refused every
# `fn twin(&self) -> Self` at expansion — while the report of #450 skipped
# the method as "returns a handle". The handle is bound to the generation that
# allocated it, as a constructor's is, and nothing is looked up for it.
@testset "an inline instance method returning Self allocates a handle (#454)" begin
    source = raw"""
        #[julia]
        pub struct Twin454 { pub n: i32 }
        impl Twin454 {
            pub fn new(n: i32) -> Self { Twin454 { n } }
            pub fn doubled(&self) -> Self { Twin454 { n: self.n * 2 } }
        }
        """
    report = RustCall.inline_boundary_report(source; io = devnull)
    @test isempty(report.unsupported)
    # `new`'s argument and the `n` getter; both results are handles.
    @test report.checked == 2
    if RustCall.check_rustc_available()
        scope = Module()
        Core.eval(scope, :(using RustCall))
        Core.eval(scope, Expr(:macrocall, Symbol("@rust_str"), LineNumberNode(1), source))
        a = Core.eval(scope, :(Twin454(Int32(21))))
        b = Core.eval(scope, :(doubled($a)))
        @test Core.eval(scope, :($b isa Twin454))
        @test Core.eval(scope, :($b.n)) == 42
        @test Core.eval(scope, :($a.n)) == 21
    else
        @info "Skipping the Self-returning method call: rustc unavailable"
    end
end
