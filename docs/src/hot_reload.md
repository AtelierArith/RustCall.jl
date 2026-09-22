# Hot Reload

Hot reload rebuilds a Rust crate when its sources change and swaps the new
library in under a running Julia session. The Julia module that `@rust_crate`
generated keeps working, and its next call reaches the new code.

```@setup hotreload
using RustCall
```

## What it supports

| Door | Hot reload |
| --- | --- |
| `@rust_crate` on a crate whose `[lib]` has `crate-type = ["cdylib"]` | **Supported**: `RustCall.enable_hot_reload_for_crate` |
| `@rust_crate` on a crate with no `cdylib` target (bound through a generated wrapper crate) | Not supported: refused with an `ArgumentError` |
| `rust"""..."""` with `// cargo-deps: my_crate = { path = "..." }` | **Not supported.** Evaluate the block again instead (see below) |
| `rust"""..."""`, `@irust`, generics | Not applicable: evaluating the source again builds a new library |

Why `rust"""` with a path dependency is not a hot reload target: the block is
compiled into a library of its own, registered as `rust_cargo_<id>`, that links
the dependency statically. A hot reload rebuilds the *dependency's* `cdylib`, and
that library does not contain the block's wrappers, so there is nothing
correct to swap in under the block's name. You don't need to swap anything,
though. A block's artifact key includes the content of its path dependencies, so
evaluating the block again after you edit the dependency builds and loads a
new library.

## A complete example

Here is a small `#[julia]` crate with its own `cdylib` target. In your own
crate, the `rustcall_julia_macros` dependency is the path to RustCall's
`deps/rustcall_julia_macros` (see [External Crate Bindings](crate_bindings.md));
`RustCall.rustcall_runtime_crate_path()` returns it.

```@example hotreload
crate = joinpath(mktempdir(), "hot_counter")
mkpath(joinpath(crate, "src"))
runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
write(joinpath(crate, "Cargo.toml"), """
    [package]
    name = "hot_counter"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    rustcall_julia_macros = { path = "$(runtime)" }
    """)
write(joinpath(crate, "src", "lib.rs"), """
    use rustcall_julia_macros::julia;

    #[julia]
    pub fn step() -> i32 { 1 }
    """)

HotCounter = @rust_crate crate
first_step = HotCounter.step()   # 1
```

Turn hot reload on by passing the value `@rust_crate` returned. That way the
reload reuses the module's registry name and build options (see below). The callback
runs after every rebuild attempt; here it reports each result on a channel,
so the example can wait for the rebuild:

```@example hotreload
reloads = Channel{Bool}(Inf)
state = RustCall.enable_hot_reload_for_crate(HotCounter, crate;
    poll = true, interval = 0.25,
    callback = (lib_name, success, error) -> put!(reloads, success))
state.lib_name == HotCounter._LIB_NAME
```

Edit the source. The watcher sees the change, rebuilds and swaps the library,
and the same module now calls the new code:

```@example hotreload
write(joinpath(crate, "src", "lib.rs"), """
    use rustcall_julia_macros::julia;

    #[julia]
    pub fn step() -> i32 { 2 }
    """)

timedwait(() -> isready(reloads), 600.0)   # a release build can take a while
rebuilt = take!(reloads)                   # true: the new library is loaded
second_step = HotCounter.step()            # 2
```

Stop watching when you are done:

```@example hotreload
RustCall.disable_hot_reload(state.lib_name)
RustCall.is_hot_reload_enabled(state.lib_name)   # false
```

## Which library is reloaded, and which build

A reload must reach the module and must rebuild the *same build* the module was
generated for. Two things identify that build:

- **The registry name.** `@rust_crate` loads a crate under
  `rust_crate_<name>_<id>`, where the id comes from the crate's content and
  build options, not from the module's name. The module records it as
  `_LIB_NAME`.
- **The build options.** The module records its profile (`release`),
  `features` and `default_features` as `_BUILD_OPTIONS`. A reload that rebuilt
  a default release build instead would compile other `#[cfg]`s under a module
  whose wrappers were generated for these ones.

**Pass the module** (or the value `@rust_crate` returned). This form reads both
records, so a reload keeps the name, the profile and the features:

```julia
B = @rust_crate "deps/my_crate" release=false features=["simd"]
RustCall.enable_hot_reload_for_crate(B, "deps/my_crate")   # rebuilds debug, with "simd"
```

The other forms don't read the module, so they can't know how it was built:

- `RustCall.enable_hot_reload_for_crate(crate; release, features,
  default_features)` takes the build as keywords, defaulting to `@rust_crate`'s
  defaults. It computes the registry name for that build of the crate *as it is
  now*, so call it before editing the sources. It doesn't guess: a crate loaded
  with other options is reached only if you pass them, or pass `lib_name`.
- `RustCall.enable_hot_reload(lib_name, crate)` is the low-level call. It
  reloads the given registry name with a default release build.

Both forms of `enable_hot_reload_for_crate` raise an `ArgumentError` rather
than rebuild something else in two cases:

- **A module bound through a generated wrapper crate.** This is a crate with no
  `cdylib` target of its own, and a reload cannot reproduce the wrapper build.
- **A module with no `_BUILD_OPTIONS`**, for example a bindings file written by
  an older RustCall. Regenerate it, or use the path form with the options it
  was built with.

## What a reload does

The steps of one reload, in order:

1. The crate is **rescanned** for its `#[julia]` items, under its own build
   configuration (features, `build.rs` cfgs).
2. It is **rebuilt** the way `@rust_crate` built it: RustToolChain's `cargo`,
   the module's profile and features, output under RustCall's own target
   directory for the crate (not the crate's `target/`), `--offline` under
   `RUSTCALL_OFFLINE=1`.
3. The new library is **swapped in** under the same name in one transaction.

If any step fails, for example a compile error, the swap never happens. The
previous library stays loaded and keeps working, and the error is reported
once. The same failure repeated on later attempts is not printed again.
Fixing the source reloads as usual.

A reload replaces the *code*. It does not regenerate the Julia module:
the module's functions, their argument and return types, and its struct types
are the ones `@rust_crate` generated. Changing a function body is what hot
reload is for. To add a function, remove one, or change a signature or a
struct's fields, evaluate `@rust_crate` again.

## Objects and call sites across a reload

The replaced library is **retired, not closed**. It stays mapped for the rest
of the session, because a call that started before the swap may still be
running inside it. See
[Libraries are retired, not closed](@ref).

- **Call sites.** Each call of a generated function resolves its target from
  one generation snapshot: the handle, function pointer and panic channel all
  come from the same library. A call made after the swap reaches the new
  library, and a call in flight during the swap finishes in the old one. A
  single call never mixes the two. Panics raised by the new code arrive as
  `RustCall.RustPanicError` exactly as before ([Panics](panics.md)).
- **Objects.** A `#[julia]` struct allocated before the reload keeps the
  destructor of the library that allocated it, and that library is still
  mapped, so the object is freed by its own allocator whenever it is collected.
  Its *methods*, like every other wrapper, call the current library. If a
  reload changed the struct's layout, objects created before it must not be
  used again: create new ones.
- **Reclaiming retired libraries.** A long-running process that reloads many
  times can reclaim the retired images when it is done with the crate and no
  call is in flight: `RustCall.unload_library(state.lib_name; close = true)`
  unloads the library and closes it together with its retired images
  (`RustCall.retired_handles(name)` lists them). Closing makes surviving
  objects of those images inert (not freed) rather than letting them call
  unmapped code.

## Watching: `interval`, `poll`, `callback`

`enable_hot_reload_for_crate` and `enable_hot_reload` take the same keywords:

- `poll = false` (the default) waits on filesystem events for every directory
  under `src/`, so an idle watcher uses no CPU. `interval` (seconds, default
  `1.0`) is then the timeout of each wait, which is how quickly the watcher
  notices it has been disabled.
- `poll = true` checks the sources' modification times every `interval`
  seconds instead. Use it on filesystems where change events are not delivered
  (network mounts, some container bind mounts).
- Saves that arrive in a burst (an editor's write-rename-touch, a formatter,
  a multi-file refactor) are merged into one rebuild. A save that lands while a
  rebuild is running causes another rebuild right after it.
- `callback = (lib_name, success, error) -> ...` runs after each rebuild
  attempt, with `error === nothing` on success. An exception thrown by the
  callback is logged and does not stop the watcher.

`RustCall.trigger_reload(lib_name)` rebuilds immediately, without waiting for
the watcher, and returns whether the new library was loaded.

## Turning it off

- `RustCall.disable_hot_reload(lib_name)` stops one watcher. It waits for a
  rebuild in progress to finish, so when it returns no swap is pending. The
  loaded library stays loaded.
- `RustCall.disable_all_hot_reload()` stops every watcher.
- `RustCall.set_hot_reload_global(false)` makes every watcher stop at its next
  wake-up.
- `RustCall.list_hot_reload_crates()` and `RustCall.is_hot_reload_enabled(lib_name)`
  report what is being watched.

Calling `enable_hot_reload_for_crate` again after `disable_hot_reload` starts a
new watcher.

## Windows and generation paths

RustCall never opens the file Cargo writes. Each load, reloads included,
copies the built library to a fresh path beside it:

```
<library>.rustcall.<host>.<pid>.<instance>.<generation>.<ext>
```

and opens that copy. This matters most on Windows, where a loaded DLL cannot be
overwritten: if RustCall mapped Cargo's output, the next build would fail with
`Access is denied (os error 5)` and the crate could not be rebuilt for the rest
of the session. On every platform it also guarantees that a reload opens a
distinct file. Loading an already-mapped path would otherwise return the *old*
image.

Because retired images stay mapped, a session's copies stay on disk while it
runs. Copies whose owning process has exited are removed the next time the
library is loaded, from this process or another.

## API

Reference: [External crates and hot reload](reference/crates.md).

- [`RustCall.enable_hot_reload_for_crate`](@ref), [`RustCall.enable_hot_reload`](@ref)
- [`RustCall.disable_hot_reload`](@ref), [`RustCall.disable_all_hot_reload`](@ref),
  [`RustCall.set_hot_reload_global`](@ref)
- [`RustCall.trigger_reload`](@ref), [`RustCall.is_hot_reload_enabled`](@ref),
  [`RustCall.list_hot_reload_crates`](@ref)
