# How RustCall Calls Rust

This page describes the internal structure of RustCall.jl: what happens between
a `rust"""` block in a Julia file and a machine-level call into Rust code. It
is written for contributors and for readers who want to know how the package
works. It is not a usage guide; for that, start at the [Tutorial](tutorial.md).

The examples on this page are run when the documentation is built, and they
call internal functions. Those functions are not public API and may change
between releases.

## The mechanism in one paragraph

RustCall does not embed a Rust interpreter and does not talk to LLVM. It
**compiles Rust to an ordinary shared library and calls it through the C ABI
with `ccall`**. Everything else in the package exists to make that safe and
automatic:

1. A Rust-side tool parses the user's Rust source, generates a C-ABI wrapper
   function for every `#[julia]` item, and writes a machine-readable
   description (the *manifest*) of each wrapper's signature.
2. Julia compiles the expanded Rust with `rustc` or `cargo` into a `cdylib`
   (`.so` / `.dylib` / `.dll`).
3. Julia opens the library with `dlopen`, and generates a Julia function for
   every manifest entry.
4. A call resolves the wrapper's address with `dlsym`, performs a `ccall`, and
   then checks whether the Rust side reported a panic.

```
 rust"""…"""
     │
     │  macro-expansion time
     ▼
 rustcall-extract expand ──► expanded Rust source ─────────────┐
     │                                                         │
     └──► manifest (TOML) ──► Julia wrapper definitions        │
                                                               │
     ┌──────────────────────── run time ◄──────────────────────┘
     ▼
 rustc / cargo ──► libxxx.so ──► dlopen ──► handle + symbols registered in STATE

 add(1, 2)
     │  a call
     ▼
 CallTarget (function pointer, panic channel, …)
     ──► ccall(function pointer, …)
     ──► ccall(panic channel)   # did Rust panic?
```

## The whole thing by hand

The pipeline can be driven step by step from the REPL. This is the clearest way
to see that nothing more than `rustc`, `dlopen` and `ccall` is involved.

**Step 1: expand.** `expand_inline` runs the extractor on a source string and
returns the expanded Rust source and the manifest:

```@example internals
using RustCall, Libdl

code = """
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

expanded = RustCall.expand_inline(code)
f = only(expanded.manifest["functions"])
f["name"], f["symbol"], f["return_type"], [(a["name"], a["rust_type"]) for a in f["args"]]
```

The user wrote `add`; the exported C symbol is `rustcall_add`. The expanded
source is much longer than the input, because it now contains the wrapper:

```@example internals
count(==('\n'), code), count(==('\n'), expanded.source)
```

**Step 2: compile.** `compile_rust_to_shared_lib` writes the source to a
temporary directory and runs
`rustc --crate-type=cdylib -C opt-level=2 -C panic=unwind --target=<triple>`:

```@example internals
path = RustCall.compile_rust_to_shared_lib(RustCall.wrap_rust_code(expanded.source))
basename(path)
```

**Step 3: load and call.** Plain `Libdl` and `ccall` are enough:

```@example internals
handle = Libdl.dlopen(path, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
fptr   = Libdl.dlsym(handle, :rustcall_add)
ccall(fptr, Int32, (Int32, Int32), 10, 20)
```

**Step 4: ask whether Rust panicked.** Every generated wrapper has a companion
`<symbol>_take_panic` function that reports a caught panic. Zero means none:

```@example internals
channel = Libdl.dlsym(handle, :rustcall_add_take_panic)
ccall(channel, Csize_t, (Ptr{UInt8}, Csize_t), C_NULL, 0)
```

That is the entire calling mechanism. The rest of this page explains what the
package adds around these four steps, and why.

!!! warning "Do not do this in `src/`"
    Inside the package, `Libdl.dlopen` / `dlclose` may be called only from
    `src/loading/loadpolicy.jl`, and `scripts/lint_load_path.sh` fails CI
    otherwise. The reason is in [Loading and lifetime](#Loading-and-lifetime).

## The components

### Rust side (`deps/`)

RustCall never parses Rust syntax in Julia (a regex over Rust source in `src/`
fails CI, `scripts/lint_rust_syntax_regex.sh`). All parsing and all Rust code
generation happen in Rust, with the [`syn`](https://docs.rs/syn) parser.

| Crate | Kind | Role |
|-------|------|------|
| `rustcall_julia_core` | library | The core. The manifest data model (`manifest.rs`), item extraction (`extract.rs`), wrapper code generation (`codegen.rs`), inline expansion (`expand.rs`), generic instantiation (`specialize.rs`), and the rules for what is refused (`refusal.rs`). |
| `rustcall_extract` | executable | The `rustcall-extract` command-line tool Julia runs as a subprocess. Subcommands: `expand`, `manifest`, `wrap`, `specialize`, `specialize-many`, `schema-version`. A thin front end over the core. |
| `rustcall_julia_macros_impl` | proc-macro | The `#[julia]` attribute for use inside a real crate. A thin wrapper over the same `codegen`. |
| `rustcall_julia_macros` | library | What a user's crate depends on. Re-exports the attribute and holds the small run-time state a proc macro cannot emit by itself (the quiet-panic hook). |
| `rustcall_helpers` | `cdylib` | Pre-built helper functions behind the ownership types `RustBox`, `RustRc`, `RustArc`, `RustVec`. |

`Pkg.build("RustCall")` (`deps/build.jl`) compiles `rustcall_extract` and
`rustcall_helpers`. Where the two binaries are placed and found again is
decided in one file, `src/native_layout.jl`, which both the build script and
the package include.

There are **two flavours of the same wrapper generator**:

- *Inline flavour.* For a `rust"""` block, the extractor's `expand` subcommand
  rewrites the source text ahead of compilation. No proc macro is involved,
  and the block needs no dependency.
- *Proc-macro flavour.* For a crate, `#[julia]` is a real attribute macro that
  runs inside `cargo build`.

Both call `rustcall_julia_core::codegen`, so a function gets the same wrapper,
the same symbol name and the same manifest entry either way.

### Julia side (`src/`)

All files define bindings in the single module `RustCall`; the directories are
organizational. The include order in `src/RustCall.jl` is the dependency order.

| Directory | Responsibility | Entry points worth knowing |
|-----------|----------------|----------------------------|
| `macros/` | The user-facing macros and the manifest reader | `@rust_str` (`ruststr.jl`), `@rust` (`rustmacro.jl`), `expand_inline` / `_run_extractor` (`manifest.jl`), wrapper emission (`julia_functions.jl`), generics (`generics.jl`) |
| `build/` | Running `rustc` and Cargo | `compile_rust_to_shared_lib` (`compiler.jl`), `create_cargo_project` / `build_cargo_project` (`cargoproject.jl`, `cargobuild.jl`), `// cargo-deps:` parsing (`dependencies.jl`) |
| `artifacts/` | What a compiled library *is* and where it is cached | `ArtifactId` / `artifact_key` (`artifact_id.jl`), the disk cache (`cache.jl`) |
| `loading/` | Opening, registering, replacing and retiring libraries | `load_artifact!` and `LoadPolicy` (`loadpolicy.jl`), `hot_reload.jl` |
| `ffi/` | The type contract and the call itself | `ffi_contract.jl`, `call_rust_function` / `guard_rust_panic_ptr` (`codegen.jl`), struct types and finalizers (`structs.jl`), ownership types (`types.jl`, `memory.jl`) |
| `crate_bindings/` | `@rust_crate` | `scan_crate`, `generate_bindings`, the two module emitters |
| `pyo3/` | Crates that are also Python extensions | see [PyO3 Crates](pyo3.md) |

## Life of a `rust"""` block

The work is split between two moments, and the split matters.

### At macro-expansion time

`@rust_str` (`src/macros/ruststr.jl`) runs when Julia *parses and lowers* the
file, before any of it executes:

1. **Snapshot the configuration.** `_cfg_snapshot` records the output of
   `rustc --print cfg` (target architecture, OS, pointer width, …) together
   with the default compiler settings. `#[cfg(...)]`-disabled items must be
   dropped identically now and later, so the snapshot travels into the
   generated code.
2. **Run the extractor.** `expand_inline` writes the block to a temporary file
   and runs `rustcall-extract expand --manifest <file> --cfg-file <file>
   block.rs`. Standard output is the expanded Rust source. The manifest is
   TOML, parsed with Julia's `TOML` and checked against
   `MANIFEST_SCHEMA_VERSION`. Results are memoized per `(source, cfg)`.
3. **Convert the manifest to Julia data.** `manifest_function_signatures` and
   `manifest_struct_infos` produce `RustFunctionSignature`, `RustStructInfo`
   and `RustMethod` values.
4. **Emit Julia definitions.** `_inline_wrapper_exprs` turns those into
   expressions: one Julia function per `#[julia]` function, and a
   `mutable struct` plus constructor, methods and property accessors per
   `#[julia]` struct.

The macro returns a block equivalent to:

```julia
lib_name = RustCall._compile_and_load_rust(code, file, line; cfg_text, compiler_target, compiler_level, cargo_env)
RustCall._record_module_block!(@__MODULE__, lib_name, RustBlockSnapshot(...), ["rustcall_add"])
function add(a, b) ... end        # the generated wrappers
lib_name
```

So the **Julia functions exist as soon as the macro is expanded**, and are part
of the caller's precompiled image. The **library is produced when the block
executes**.

### At run time

`_compile_and_load_rust` (`src/macros/ruststr.jl`) does the following for a
block without dependencies:

1. Expand again (a memo hit) and compute the block's identity:
   `_rustc_block_identity` → `generate_cache_key` → `artifact_key(ArtifactId)`.
2. Derive the in-memory library name `rust_<16 hex digits>` from that key.
3. If a library of that name is already loaded, only re-register its metadata
   and return.
4. Otherwise look in the disk cache (`get_cached_library`). On a hit, load the
   cached file.
5. Otherwise run `rustc` (`compile_rust_to_shared_lib`), save the result to the
   cache, and load it.

Loading always goes through `_register_manifest` → `load_artifact!`, which
opens the file and publishes the handle *together with* the name-to-symbol
table and the return types the manifest recorded.

A block that starts with `// cargo-deps:` (or a `` //! ```cargo `` section)
takes `_compile_and_load_rust_with_cargo` instead: RustCall generates a
temporary Cargo project (`create_cargo_project`), resolves or replays a
persisted `Cargo.lock` for that dependency set, builds with `cargo build
--release --locked`, and caches and loads the product the same way. Its library
name is `rust_cargo_<16 hex digits>`.

### Artifact identity

Whether a compiled library can be reused is decided by one value. `ArtifactId`
(`src/artifacts/artifact_id.jl`) is an exhaustive record of everything that
shapes the binary: the expanded source, the target triple and optimization
level, the cfg text, the dependency set and resolved lockfile, the tracked
build environment, the identity of the `rustc` / `cargo` that will run, and a
*toolchain fingerprint* covering the extractor and the code-generation crates.
`artifact_key` is its SHA-256.

That one digest is the disk cache file name, the lookup key, and (truncated by
`artifact_short_id`, the only truncation allowed) the human-readable library
name. Key material is never assembled anywhere else;
`scripts/lint_artifact_identity.sh` enforces it. The cache lives in a
[Scratch.jl](https://github.com/JuliaPackaging/Scratch.jl) space:

```@example internals
RustCall.get_cache_dir()
```

with one `<key>.so` (plus a checksum) per `rustc`-built block, `metadata/`
beside it, and `cargo/` for Cargo-built products.

### Per-module records and precompilation

`_record_module_block!` stores, for the calling module, which library each
block produced and which symbols it exports
(`src/loading/module_state.jl`). This has two purposes:

- A generated wrapper resolves its symbol through *its own module's* library,
  so two modules that each define a Rust function `add` do not capture each
  other's calls.
- When a package containing a `rust"""` block is **precompiled**, the loaded
  library handle cannot be saved, but the immutable `RustBlockSnapshot`
  (source, cfg text, compiler settings) is. In a fresh process, the first call
  from that module goes through `_resolve_lib` → `ensure_loaded`, which
  rebuilds or reloads each recorded block from the cache.

## What the extractor generates

For `#[julia] fn add(a: i32, b: i32) -> i32`, the inline expansion keeps the
user's function untouched and adds three things next to it. Abbreviated from
the real output (print `expanded.source` above to see all of it):

```rust
fn add(a: i32, b: i32) -> i32 {          // 1. the user's function, as written
    a + b
}

thread_local! {                           // 2. the panic channel: a per-thread slot
    static __RUSTCALL_PANIC_RUSTCALL_ADD: RefCell<Option<String>> = RefCell::new(None);
}
#[no_mangle]
pub extern "C" fn rustcall_add_take_panic(out: *mut u8, cap: usize) -> usize {
    /* report the stored message's length, or copy it into `out` and clear the slot */
}

#[no_mangle]                              // 3. the C-ABI wrapper
pub extern "C" fn rustcall_add(a: i32, b: i32) -> MaybeUninit<i32> {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match std::panic::catch_unwind(AssertUnwindSafe(|| MaybeUninit::new(add(a, b)))) {
        Ok(value) => value,
        Err(payload) => {
            /* store "add panicked: <message>" in the thread-local slot */
            MaybeUninit::zeroed()
        }
    }
}
```

Points that matter for the Julia side:

- **The attribute is additive.** `add` stays an ordinary Rust function that
  other Rust code and `#[test]`s can call. The exported symbol is a separate
  function with a derived name.
- **Symbol names are derived in one place**, `codegen::symbol_stem`: `add` at
  the crate root becomes `rustcall_add`; inside `mod a` it becomes
  `rustcall_a__add`. The manifest carries the result in `symbol` and
  `ffi_name`, and Julia never reconstructs a symbol name on its own.
- **A panic never crosses the boundary.** Unwinding out of an `extern "C"`
  function is not allowed, so the wrapper catches the panic, stores its message
  in a thread-local, and returns a placeholder. `MaybeUninit<T>` has the same
  ABI as `T` and makes an all-zero placeholder legal for every `T`.
- **Everything is compiled with `panic = "unwind"`**, pinned on the `rustc`
  command line and in generated Cargo profiles, because `catch_unwind` cannot
  catch a panic that aborts.

At the end of the file the expansion adds crate-wide support items, including
`__rustcall_install_panic_hook`. The loader calls it right after `dlopen` so
that a panic caught at a boundary does not also print Rust's default
"thread panicked" message to stderr.

### The manifest

The manifest is the contract between the two languages. One entry of the
example above:

```@example internals
filter(kv -> first(kv) in ("name", "symbol", "attribute", "exported", "return_type",
                           "return_kind", "is_generic", "module_path", "skip_reason"), f)
```

`attribute` distinguishes a `#[julia]` item from a hand-written
`#[no_mangle] extern "C"` export, which is listed too (`attribute = "none"`)
so that `@rust` can find it and knows its return type. `return_kind` says how
the return value is lowered (`plain`, `unit`, `result`, `option`, …). A non-empty `skip_reason` means the Rust
code generator refused the item (an `unsafe fn`, a generic method, …); Julia
then emits no wrapper for it.

Because the Julia wrappers are generated *from the manifest* and the Rust
wrappers are generated *by the tool that wrote the manifest*, the two sides
cannot disagree about a signature. The schema identifier is the package's
`MAJOR.MINOR`, and a manifest from another minor version is refused.

## What Julia generates

For the same function, the generated Julia wrapper is (hygiene renaming
removed):

```julia
function add(a, b)
    target = RustCall.cached_call_target(CACHE, @__MODULE__, "rustcall_add")
    RustCall.guard_rust_panic_ptr(
        RustCall.call_rust_function(target.func_ptr, Int32, Base.Int32(a), Base.Int32(b)),
        target.channel, "add")
end
```

where `CACHE` is a `CallTargetCache` object spliced into this method's body.
You can print the real thing with
`@macroexpand rust"""…"""`. Three functions do the work.

### `cached_call_target` / `resolve_call_target`: where is the function?

`resolve_call_target` (`src/macros/ruststr.jl`) returns a `CallTarget`:

```@example internals
module Demo
using RustCall
lib = rust"""
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""
end

target = RustCall.resolve_call_target(Demo.lib, "rustcall_add")
(lib = target.lib_name, generation = target.generation, alive = target.alive[],
 return_type = target.return_type, has_channel = target.channel != C_NULL)
```

A `CallTarget` is a **snapshot of one generation of one library**: the function
pointer, the panic-channel pointer, an optional release-function pointer, the
`dlopen` handle, the library's liveness flag and the recorded return type. All
of it is captured in a single critical section of the registry lock. Symbols
not yet looked up are resolved with `dlsym` on the captured handle, outside the
lock, and memoized per image.

It has to be a snapshot because a library can be replaced while the program
runs (hot reload, re-evaluating a block). If the function pointer and the
panic channel were looked up separately, a reload between the two lookups could
pair a call into the old image with the new image's channel. Four functions are
allowed to build such a snapshot, and `scripts/lint_generation_snapshot.sh`
rejects any other piecemeal resolution.

Resolving costs microseconds and takes a lock; the `ccall` behind it costs
nanoseconds. So each call site keeps its last snapshot in its `CallTargetCache`
and reuses it while two things hold:

```@example internals
RustCall.artifact_epoch()
```

- `ARTIFACT_EPOCH`, a counter incremented by *every* write to the package's
  state, still has the value sampled before the snapshot was resolved; and
- `SESSION_TOKEN`, an object allocated anew in every process, is identical. A
  cache object can be serialized into a precompile image with pointers from
  the process that wrote it; the token makes such an entry invalid elsewhere.

The fast path is one atomic load and two comparisons, with no lock.

### `call_rust_function`: the `ccall`

`call_rust_function` (`src/ffi/codegen.jl`) is a `@generated` function. For a
concrete return type and argument-type tuple it builds one literal
`ccall(func_ptr, R, (A1, A2, …), convert_arg(A1, x1), …)` expression, so after
specialization the call is as direct as a hand-written `ccall`:

```@example internals
RustCall.call_rust_function(target.func_ptr, Int32, Int32(1), Int32(2))
```

Before it, `ffi_check_by_value_signature` refuses to pass a Julia struct by
value unless its layout was asserted with `@register_ffi_struct`.

### `guard_rust_panic_ptr`: did Rust panic?

Immediately after the wrapper returns, `guard_rust_panic_ptr` calls the
`*_take_panic` function. A non-zero answer means the returned value is a
placeholder: the message is fetched and a `RustPanicError` is thrown.

The channel is a *thread-local* in the Rust library, and a Julia task can move
to another OS thread at any yield point. Therefore **nothing that can yield
(a lock, logging, I/O) may sit the wrapper `ccall` and the channel `ccall`**. That is why the channel
pointer is part of the snapshot resolved *before* the call.

## `@rust`: calling a symbol by name

`@rust f(args...)::T` (`src/macros/rustmacro.jl`) expands to

```julia
RustCall._rust_call_typed_cached(CACHE, @__MODULE__, "", "f", T, args...)
```

and `@rust f(args...)` to `_rust_call_dynamic_cached(...)`. Both use the same
`CallTarget` machinery. The differences from a generated wrapper:

- The name is resolved at run time through `resolve_rust_call`: the calling
  module's own blocks first (functions and generics), then every other loaded
  library; a name found in two different libraries is an error.
- With `::T`, the annotation is compared once per snapshot with the return
  type the manifest recorded, and a contradiction is an error. Without it, the
  return type is read from the snapshot at run time, which makes the call a
  dynamic dispatch.
- A hand-written `extern "C"` function has no panic channel (`channel ==
  C_NULL`), so the guard does nothing; a panic in it aborts the process.

## Beyond scalars: how each kind of value crosses

Only C-compatible values can pass through `ccall`. Every richer Rust type is
*lowered* to such values by the generated wrapper and rebuilt on the other
side. The single source of truth for what is allowed and how it is lowered is
the table in `src/ffi/ffi_contract.jl`, from which
[The FFI Type Contract](type_contract.md) page is generated. An unknown type is
refused, never guessed.

| Rust type | Passed as | Notes |
|-----------|-----------|-------|
| integers, floats, `bool` | by value | `char` crosses as a `UInt32` code point and is converted. |
| `&str` argument | `(ptr, len)` | Points into the Julia `String`, kept alive with `GC.@preserve`. UTF-8 validity is checked first. |
| `String` return | `(ptr, len, cap)` struct | Rust leaks the buffer with `mem::forget`; Julia copies the bytes, then calls `<fn>_free_rust_string` **from the same library** so that the allocator that allocated also frees. |
| `&[T]`, `&mut [T]` argument | `(ptr, len)` | Points into the Julia array; Rust rebuilds the slice with `slice::from_raw_parts`. Element type, contiguity and mutable aliasing are checked in Julia before the call. |
| `Result<T, E>` return | `#[repr(C)] struct CResult_<fn> { is_ok: u8, ok_value, err_value }` | Read in Julia as `CResultType{T, E}` and converted to `RustResult{T, E}`. `Option<T>` is analogous. |
| `#[julia]` struct | opaque pointer | See below. |
| `extern "C" fn(A...) -> R` argument | C function pointer | See below. |

### Structs are handles

A `#[julia]` struct is never copied into Julia. The constructor wrapper
(`rustcall_Counter_new`) allocates the value with `Box::new` and returns
`Box::into_raw`, a raw pointer; `Counter_free` turns it back into a `Box` and
drops it. The generated Julia type holds the pointer:

```julia
mutable struct Counter
    ptr::Ptr{Cvoid}                 # the Rust value
    lib_name::String
    free_ptr::Ptr{Cvoid}            # address of Counter_free, captured at construction
    alive::Base.RefValue{Bool}      # liveness flag of the library that allocated it
    free_channel::Ptr{Cvoid}        # panic channel of the destructor
end
```

Methods pass `ptr` as the first argument of `rustcall_Counter_<method>`.
Fields are reached through generated accessor functions (`Counter_get_value`,
`Counter_set_value`) behind `getproperty` / `setproperty!`.

The object registers `finalize_rust_object!` (`src/ffi/structs.jl`) as its
finalizer. Its rules are strict, because a finalizer runs at an arbitrary
point on an arbitrary thread:

- it uses only what the object captured at construction (`free_ptr`, `alive`,
  `free_channel`), and never looks anything up;
- it never takes the registry lock, never calls `dlsym`, and never logs;
- it nulls `ptr` before calling the destructor, and skips the call entirely
  when `alive[]` is false, that is, when the library has been closed.

The constructor's snapshot includes the destructor of the *same* library
generation, so an object can never be freed by a different image than the one
that allocated it. `test/test_finalizers.jl` checks these rules against the
source.

### Callbacks

A Rust argument of type `extern "C" fn(i32) -> i32` accepts a Julia function.
RustCall does not use closure `@cfunction`s, which are unavailable on some
platforms (aarch64). Instead the wrapper pushes the Julia function onto a
task-local stack as a `CallbackFrame` for the duration of the call and passes
Rust a constant `@cfunction` pointer to a `CallbackSlot{k, R}` singleton, which
looks the function up in the current frame. A Julia exception inside the
callback must not unwind through Rust frames: it is stored, a zero value is
returned to Rust, and `guard_rust_panic_ptr` rethrows it after the Rust call
has returned. See [Callbacks](callbacks.md).

### Generics

A compiled library contains no generic functions, only instantiations. For
`fn identity<T>(x: T) -> T`, the block's manifest marks the function
`is_generic`, no wrapper is exported, and Julia registers the *source* in a
generic registry. On the first call with, say, an `Int32`:

1. the type parameters are inferred from the Julia argument types;
2. `rustcall-extract specialize` rewrites the source at the syntax-tree level
   with `T = i32` and emits a wrapper `rustcall_identity_i32`;
3. that source is compiled into a **separate small library**, cached on disk
   under its own artifact key, loaded, and its `FunctionInfo` memoized.

A generic struct is handled the same way, with all of its methods, accessors
and its destructor instantiated together in one library. See
[Generics](generics.md).

## `@rust_crate`: binding a crate

`@rust_crate path` (`src/crate_bindings/`) follows the same four steps with a
crate in place of a string. `generate_bindings` is the orchestrator:

1. **Snapshot the environment.** One `BuildEnvSnapshot` is taken first; every
   later decision (cache key, Cargo subprocess environment, Python interpreter
   for PyO3 crates) is derived from it and nothing reads `ENV` again.
2. **Scan.** `scan_crate` runs `rustcall-extract manifest --mode crate
   --crate-root src/lib.rs`, which follows the crate's module tree. The crate
   is then rescanned under the cfg set of the actual build, so the bindings
   list exactly the items that build exports.
3. **Build.** If the crate already declares `crate-type = ["cdylib"]`, Cargo
   builds it directly. Otherwise RustCall generates a small wrapper crate
   (`<name>_julia_wrapper`) that depends on the user's crate and is a `cdylib`.
   The `#[julia]` proc macro produces the `extern "C"` wrappers during that
   build. The product is cached under `compute_crate_hash`.
4. **Emit a Julia module.** `emit_crate_module` produces a module containing a
   Julia function per `#[julia]` function and a type per struct, one submodule
   per Rust module.

There are two emitters that must stay equivalent. `@rust_crate` uses the
*expression* emitter and evaluates the module in memory.
`write_bindings_to_file` uses the *source-text* emitter and writes a `.jl` file
a package can `include` (the route that precompiles best). Both share one
layout, one field plan and one payload plan.

A generated function in a crate module looks like this (from a written
bindings file, with the `rustcall′Base.` / `rustcall′RustCall.` prefixes
shortened):

```julia
const var"#TC#fn#rustcall_add" = RustCall.CrateTargetCache()
function add(a, b)
    func_ptr, panic_channel = _call_target(var"#TC#fn#rustcall_add", "rustcall_add")
    _guard_panic(RustCall.call_rust_function(func_ptr, Int32, Int32(a), Int32(b)),
                 panic_channel, "add")
end
```

The shape is that of the inline wrapper, with two differences in carriers:

- **The library is module-local.** The module's `__init__` calls
  `load_artifact!` on a private copy of the built library and holds the result
  in `_LIB_GEN`, a single atomically replaced record of
  `(handle, liveness flag, generation)`. `_call_target` takes its snapshot from
  one read of that record.
- **The per-call-site cache is a named `const`**, because a written source file
  cannot contain a spliced object. The name contains `#`, which no Rust
  identifier can, so it cannot collide with an item the crate exports. For the
  same reason generated code refers to `Base` and `RustCall` only through
  aliases spelled with a character Rust identifiers cannot contain
  (`src/ffi/emitted_names.jl`).

## Loading and lifetime

Every library RustCall opens goes through `load_artifact!`
(`src/loading/loadpolicy.jl`). Each front door names a `LoadPolicy` describing
its decisions:

```@example internals
RustCall.inline_rustc_policy()
```

What `load_artifact!` guarantees:

- **`dlopen` runs outside the registry lock** (it executes the library's
  initialization code and can be slow), and then the handle, its symbol cache,
  the name-to-symbol mappings, the return types and the liveness flag are
  published **in one locked step**. No task can observe a library without its
  metadata.
- **`RTLD_LOCAL`.** Symbols are never made process-global. Every call goes
  through `dlsym` on a specific handle, so two libraries can both export
  `rustcall_add`.
- **A replaced library is retired, not closed.** When a name is re-registered
  (hot reload, an edited block), the old image stays mapped, because a call
  that started a moment ago may still be executing inside it and objects it
  allocated still need its destructor. Each image has one liveness flag,
  shared by every name and every object of that image. Only an explicit
  close (`unload_library(name; close = true)` and its relatives) flips the
  flag and calls `dlclose`, and objects of that image then become inert instead of freeing through
  unmapped code.
- **Generations.** Each registration of a name gets a generation number, which
  a `CallTarget` records. [Hot Reload](hot_reload.md) builds on this: it
  rebuilds the crate, loads the new file from a fresh path, and publishes the
  new generation in one transaction, while calls in flight finish in the old
  one.

## State and threads

All mutable run-time state lives in one container:

```julia
const STATE = Base.Lockable(RustCallState(Dict{Symbol, Any}()))
```

The historical registry names (`RUST_LIBRARIES`, `FUNCTION_REGISTRY`,
`ARTIFACT_ALIVE`, …) are `StateView`s, lock-taking handles into it, and
`REGISTRY_LOCK` is its lock. The rule that keeps the package deadlock-free and
its calls scalable is:

> Hold the state lock only for an in-memory transaction. Never while running
> user code, compiling, calling `dlopen` / `dlsym` / `dlclose`, or executing a
> Rust `ccall`.

Every write passes through `_state_mutate_storage!`
(`src/loading/state_filter.jl`), which is also where `ARTIFACT_EPOCH` is
incremented. That is what lets call sites reuse snapshots without a lock: a
write they did not see is impossible. `test/test_state.jl` scans the module so
that a new mutable global registry cannot be added outside the container.
[Panics, Visibility and Lifetime](panics.md) documents the lock ordering in
full.

## The helper library

`RustBox{T}`, `RustRc{T}`, `RustArc{T}` and `RustVec{T}` do not come from user
code. They are backed by `deps/rustcall_helpers`, a `cdylib` of monomorphic
C-ABI functions such as `rust_box_new_i32` and their `drop` counterparts,
built by `Pkg.build`. `__init__` loads it through the same `load_artifact!`
with `helper_library_policy()`, and `src/ffi/memory.jl` selects the symbol for
a given `T`. If the library is missing, the package still loads and only these
types are unavailable.

## Where to look when changing something

| To change | Look at | And run |
|-----------|---------|---------|
| How a Rust wrapper is generated | `deps/rustcall_julia_core/src/codegen.rs` | `cargo test` there; a golden-corpus failure in `tests/corpus/` shows the output changed |
| What the manifest says about an item | `manifest.rs` / `extract.rs`, then `src/macros/manifest.jl` | `test/test_manifest.jl`, `test/test_schema_version.jl` |
| What types may cross, and how | `src/ffi/ffi_contract.jl` | `test/test_docs_generated.jl` (the contract page is generated) |
| The Julia wrapper for a function / struct | `src/macros/julia_functions.jl`, `src/ffi/structs.jl` | the feature's `test/test_*.jl` |
| `@rust_crate` output | `src/crate_bindings/crate_wrappers_expr.jl` **and** `crate_module_source.jl` | `test/test_crate_bindings.jl`, `test/test_boundary_collect.jl` |
| Cache keys | `src/artifacts/artifact_id.jl` only | `scripts/lint_artifact_identity.sh src` |
| Loading / unloading | `src/loading/loadpolicy.jl` only | `scripts/lint_load_path.sh src`, `test/test_hot_reload_transaction.jl` |
| Anything on the call path | `src/ffi/codegen.jl`, `src/macros/ruststr.jl` | `test/test_dispatch_cache.jl`, `benchmark/benchmarks_dispatch.jl` |

Useful introspection while working:

```julia
RustCall.expand_inline(code).source           # the Rust that is actually compiled
RustCall.expand_inline(code).manifest         # what Julia is told about it
@macroexpand rust"""…"""                      # the Julia that is generated
RustCall.list_loaded_libraries()              # registered library names
RustCall.list_library_functions(lib)          # names a library registered
RustCall.inline_boundary_report(code)         # every boundary position and any refusal
RustCall.check_toolchain()                    # resolved rustc, cargo, extractor
```

After changing anything under `deps/`, rebuild the extractor with
`julia --project deps/build.jl` before running Julia tests; a stale binary is
rejected by the schema check. The [Project Guide](project_guide.md) covers the
repository layout, the test suite and the release process.
