# What a `@rust` call costs above a raw `ccall`, and where the time goes (#253).
#
# Run: julia --threads=4 --project=benchmark benchmark/benchmarks_dispatch.jl
#
# #253 asks for a per-call-site pointer cache and lock-free reads on the hot
# path. Before designing either, this measures what is actually there — some of
# the issue's evidence predates #277/#291, which replaced four separate
# per-call lookups with one `resolve_call_target` snapshot. This script is the
# instrument its acceptance criteria need ("within ~2x of a raw `ccall`",
# "scales with thread count"), so it reports a ratio against a raw `ccall` into
# the same library and a scaling factor across threads, not just absolute times.
#
# Five call paths, floor first:
#
#   raw        `ccall` on a pointer resolved once, by hand. The floor: no
#              lookup, no lock, no panic-channel read.
#   generated  the Julia function a `#[julia]` item defines. What most user
#              code calls, and the path `src/julia_functions.jl` emits.
#   typed      `@rust f(a, b)::T`.
#   dynamic    `@rust f(a, b)`, the return type taken from the snapshot.
#   crate      a wrapper of a `@rust_crate` module. A separate code path with a
#              separate cache (`CrateTargetCache`, #253), because a generated
#              crate module is also emitted as *source text* by
#              `write_bindings_to_file` and cannot splice an object into itself.
#
# and then the pieces each of them is made of, so the ratio has an address.

include(joinpath(@__DIR__, "setup.jl"))

using BenchmarkTools
using Printf
using RustCall

if !RustCall.check_rustc_available()
    error("rustc not found. Benchmarks require Rust to be installed.")
end

rust"""
#[julia]
pub fn dispatch_add(a: i32, b: i32) -> i32 {
    a + b
}
"""

# The Rust body is two instructions, so everything measured above the floor is
# dispatch. That is the point: a heavier body would hide exactly what #253 is
# about.
const A = Int32(100)
const B = Int32(200)

const MOD = @__MODULE__
const LIB = RustCall.module_symbol_library(MOD, "rustcall_dispatch_add")
const TARGET = RustCall.resolve_call_target(LIB, "rustcall_dispatch_add")
const PTR = TARGET.func_ptr
const CHANNEL = TARGET.channel

@noinline raw_call(ptr, a, b) = ccall(ptr, Int32, (Int32, Int32), a, b)
@noinline generated_call(a, b) = dispatch_add(a, b)
@noinline typed_call(a, b) = @rust dispatch_add(a, b)::Int32
@noinline dynamic_call(a, b) = @rust dispatch_add(a, b)

@assert raw_call(PTR, A, B) == 300
@assert generated_call(A, B) == 300
@assert typed_call(A, B) == 300
@assert dynamic_call(A, B) == 300

# The `@rust_crate` path, against the same shape of Rust body: `add(a, b)` of
# `test/fixtures/sample_crate`. Its wrapper lives in a generated module, so its
# floor is that module's own `ccall` on a pointer resolved by hand once.
const CRATE_PATH = normpath(joinpath(@__DIR__, "..", "test", "fixtures", "sample_crate"))
const CRATE = @rust_crate CRATE_PATH
const CRATE_MODULE = getfield(CRATE, :module_ref)
const CRATE_ADD = getfield(CRATE_MODULE, :add)
const CRATE_PTR = RustCall._module_binding(CRATE_MODULE, :_get_func_ptr)("rustcall_add")

@noinline crate_raw_call(ptr, a, b) = ccall(ptr, Int32, (Int32, Int32), a, b)
@noinline crate_call(a, b) = CRATE_ADD(a, b)

@assert crate_raw_call(CRATE_PTR, A, B) == 300
@assert crate_call(A, B) == 300

# ---------------------------------------------------------------------------
# Per-call cost
# ---------------------------------------------------------------------------

paths = [
    ("raw ccall", @benchmark raw_call($PTR, $A, $B)),
    ("generated #[julia] fn", @benchmark generated_call($A, $B)),
    ("@rust f(a,b)::Int32", @benchmark typed_call($A, $B)),
    ("@rust f(a,b)", @benchmark dynamic_call($A, $B)),
    ("@rust_crate raw ccall", @benchmark crate_raw_call($CRATE_PTR, $A, $B)),
    ("@rust_crate wrapper", @benchmark crate_call($A, $B)),
]

# The pieces. Each is called the way the call paths call it, so the parts are
# comparable with the whole rather than merely suggestive.
@noinline piece_resolve_lib() = RustCall._resolve_lib(MOD, "")
@noinline piece_symbol_library() = RustCall.module_symbol_library(MOD, "rustcall_dispatch_add")
@noinline piece_resolve_target(lib) = RustCall.resolve_call_target(lib, "rustcall_dispatch_add")
@noinline piece_call_rust_function(ptr, a, b) = RustCall.call_rust_function(ptr, Int32, a, b)
@noinline piece_guard(v, ch) = RustCall.guard_rust_panic_ptr(v, ch, "rustcall_dispatch_add")

# The two pieces the `@rust_crate` wrapper is made of: the generation mirror
# deref (a `StateView`, so it takes `REGISTRY_LOCK`) and the memoized symbol
# lookup. Both used to run on every call; since #253 they run only when the
# artifact epoch has moved.
const CRATE_GEN_VIEW = RustCall._module_binding(CRATE_MODULE, :_LIB_GEN)
const CRATE_SYMBOL = RustCall._module_binding(CRATE_MODULE, :_symbol)
@noinline piece_crate_generation() = CRATE_GEN_VIEW[]
@noinline piece_crate_symbol(handle) = CRATE_SYMBOL(handle, "rustcall_add")
@noinline piece_panic_symbol() = RustCall.ffi_panic_symbol("rustcall_add")

pieces = [
    ("_resolve_lib (per call)", @benchmark piece_resolve_lib()),
    ("module_symbol_library", @benchmark piece_symbol_library()),
    ("resolve_call_target", @benchmark piece_resolve_target($LIB)),
    ("call_rust_function (dyn ret)", @benchmark piece_call_rust_function($PTR, $A, $B)),
    ("guard_rust_panic_ptr", @benchmark piece_guard(Int32(300), $CHANNEL)),
    ("crate _LIB_GEN[] (locked)", @benchmark piece_crate_generation()),
    ("crate _symbol (locked)", @benchmark piece_crate_symbol($(CRATE_GEN_VIEW[].handle))),
    ("ffi_panic_symbol (String)", @benchmark piece_panic_symbol()),
]

# ---------------------------------------------------------------------------
# Thread scaling
# ---------------------------------------------------------------------------
#
# #253's second criterion. `REGISTRY_LOCK` is a single global lock taken on the
# way to every call, so the question is whether N tasks calling Rust get N
# times the throughput. Reported as calls/second against the 1-task figure of
# the same path: a path that scales reads ~N, one that serializes reads ~1.

const CALLS_PER_TASK = 20_000

# `F` as a type parameter, and the loop in a function of its own: the loop body
# must be specialised on the call, or the harness measures its own dynamic
# dispatch instead of the path under test. The total is returned so nothing here
# is dead code the compiler may delete.
@noinline function burn(call::F, n::Int) where {F}
    total = Int32(0)
    for _ in 1:n
        total += call(A, B)
    end
    return total
end

function throughput(call::F, tasks::Int) where {F}
    elapsed = @elapsed begin
        results = map(1:tasks) do _
            Threads.@spawn burn(call, CALLS_PER_TASK)
        end
        foreach(wait, results)
    end
    return tasks * CALLS_PER_TASK / elapsed
end

raw_bound(a, b) = raw_call(PTR, a, b)

nthreads = Threads.nthreads()
task_counts = filter(<=(max(nthreads, 1)), [1, 2, 4])

const SCALING_PATHS = [("raw ccall", raw_bound), ("generated #[julia] fn", generated_call),
                       ("@rust_crate wrapper", crate_call)]

# Every (path, task count) pair is run once and discarded first. Otherwise the
# first timed region of each path pays the compilation of `burn` and of the
# spawn closure, which is what made a 2-task run look forty times faster than a
# 1-task one.
for (_, call) in SCALING_PATHS, t in task_counts
    throughput(call, t)
end

scaling = map(SCALING_PATHS) do (name, call)
    # Best of three: a scaling factor is a ratio of two timings, so a single
    # scheduling hiccup in either shows up doubled.
    (name, [(t, maximum(throughput(call, t) for _ in 1:3)) for t in task_counts])
end

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

floor_ns = minimum(paths[1][2]).time

println("\n", "="^72)
println("@rust dispatch overhead (#253)")
println("="^72)
@printf("\nJulia %s, %d thread(s), %s\n\n", VERSION, nthreads, Sys.MACHINE)

@printf("%-30s %12s %12s %10s\n", "call path", "min (ns)", "median (ns)", "x raw")
println("-"^72)
for (name, result) in paths
    @printf("%-30s %12.1f %12.1f %10.1f\n", name, minimum(result).time,
            median(result).time, minimum(result).time / floor_ns)
end

@printf("\n%-30s %12s %12s %10s\n", "piece", "min (ns)", "median (ns)", "allocs")
println("-"^72)
for (name, result) in pieces
    @printf("%-30s %12.1f %12.1f %10d\n", name, minimum(result).time,
            median(result).time, minimum(result).allocs)
end

if length(task_counts) > 1
    @printf("\n%-30s %10s %14s %10s\n", "thread scaling", "tasks", "Mcalls/s", "x 1 task")
    println("-"^72)
    for (name, points) in scaling
        base = points[1][2]
        for (tasks, rate) in points
            @printf("%-30s %10d %14.2f %10.2f\n", name, tasks, rate / 1e6, rate / base)
        end
    end
else
    println("\nThread scaling skipped: run with --threads=4 to measure #253's second criterion.")
end
# ---------------------------------------------------------------------------
# How the per-call cost grows with the module's library count
# ---------------------------------------------------------------------------
#
# `_resolve_lib` walks **every** `rust"""` block of the calling module and calls
# `ensure_loaded` on each, on every call, and `collect`s the table first because
# a reload may rebind it. So the figures above are the *best* case — one block.
# A module with several blocks pays this again per block, per call.

rust"""
#[julia]
pub fn dispatch_filler_one(a: i32) -> i32 { a }
"""
growth_two = @benchmark piece_resolve_lib()

rust"""
#[julia]
pub fn dispatch_filler_two(a: i32) -> i32 { a }
"""
growth_three = @benchmark piece_resolve_lib()

growth = [(1, pieces[1][2]), (2, growth_two), (3, growth_three)]

@printf("\n%-30s %10s %12s %10s\n", "_resolve_lib vs blocks", "blocks", "min (ns)", "allocs")
println("-"^72)
for (blocks, result) in growth
    @printf("%-30s %10d %12.1f %10d\n", "", blocks, minimum(result).time,
            minimum(result).allocs)
end

println("\n", "="^72)
