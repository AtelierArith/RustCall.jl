# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RustCall.jl is a Julia FFI package for calling Rust code directly from Julia, inspired by Cxx.jl. It provides `rust"""..."""` string literals for compiling Rust snippets, `@rust` for FFI calls, `@irust` for inline Rust with `$var` binding, `@rust_crate` for external crate bindings, and a `#[julia]` proc-macro attribute. Requires Julia 1.12+; the Rust toolchain comes from RustToolChain.jl (a `rustc`/`cargo` on PATH when present, otherwise an artifact toolchain), so no system Rust installation is required.

## Common Commands

```bash
# Setup and build
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project -e 'using Pkg; Pkg.build("RustCall")'   # builds deps/rustcall_helpers

# Run all tests
julia --project -e 'using Pkg; Pkg.test()'

# Run a single test file
julia --project test/test_cache.jl

# Build documentation
julia --project=docs docs/make.jl

# Rust crates (deps/rustcall_julia_core, deps/rustcall_extract, deps/rustcall_julia_macros{,_impl}, deps/rustcall_helpers)
cd deps/rustcall_julia_core && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
UPDATE_GOLDEN=1 cargo test          # in deps/rustcall_julia_core: regenerate tests/corpus/*.toml and *.expanded.rs
julia --project deps/build.jl                       # builds the helpers and the CLI Julia calls, and writes the extractor's identity record (#409)
cd deps/rustcall_extract && cargo build --release   # the CLI alone; no identity record, so that binary is identified by its bytes
cd deps/rustcall_julia_macros && cargo test --all-features
cd deps/rustcall_julia_macros_impl && cargo test
cd deps/rustcall_helpers && cargo fmt --check && cargo clippy --all-targets --all-features -- -D warnings

# Lints run in CI
bash scripts/lint_interpolation.sh src
bash scripts/lint_rust_syntax_regex.sh src   # Julia must not parse Rust syntax with regexes
bash scripts/lint_artifact_identity.sh src  # artifact identity only via src/artifact_id.jl
bash scripts/lint_load_path.sh src          # dlopen/dlclose/RUST_LIBRARIES only via src/loadpolicy.jl
bash scripts/lint_generation_snapshot.sh src  # FFI entry points resolve via a snapshot, never piecemeal
bash scripts/lint_state_container.sh src      # mutable registries are StateViews into RustCall.STATE
```

## Architecture

### Rust syntax is parsed only on the Rust side (issue #264)

- `deps/rustcall_julia_core` — `syn`-based core: FFI manifest model (`manifest.rs`), extraction (`extract.rs`), inline expansion of `#[julia]` items (`expand.rs`), wrapper codegen for both the proc-macro and inline flavours (`codegen.rs`), AST-level generic instantiation (`specialize.rs`). Golden tests in `tests/corpus/`.
- `deps/rustcall_extract` — the `rustcall-extract` CLI: `manifest` (crate/inline scan), `expand` (inline `#[julia]` expansion), `wrap` (the generated PyO3 wrapper crate, `wrap_crate` in `src/manifest.jl`), `specialize` / `specialize-many` (one or a batch of generic instantiations; `specialize_generic_group`), `schema-version` (the manifest identifier `test/test_schema_version.jl` compares with `MANIFEST_SCHEMA_VERSION`). `--cfg-file` takes `rustc --print cfg` so `#[cfg]`-disabled items are dropped. Built by `Pkg.build("RustCall")`; located by `RustCall.extractor_path()` (override with `RUSTCALL_EXTRACT`).
- `deps/rustcall_julia_macros` — the crate a user's `#[julia]` crate depends on. It is a **normal library**, not a proc-macro crate: it re-exports the attribute from `deps/rustcall_julia_macros_impl` (the thin proc-macro wrapper over `rustcall_julia_core::codegen`) and carries the one thing a proc macro cannot emit for itself — the crate-wide quiet-panic state of #304, in `src/rt.rs`. That file is **generated** from `rustcall_julia_core::codegen::runtime_module_source()` and asserted against it by `deps/rustcall_julia_core/tests/runtime_crate.rs` (regenerate with `UPDATE_GOLDEN=1 cargo test`, then `cargo fmt`), so the hook a `#[julia]` crate gets and the hook an inline block gets cannot drift apart.
- `src/native_layout.jl` — the one place that decides where `Pkg.build` puts the two native products and where they are found again (#258). Included by `src/RustCall.jl` **and** by `deps/build.jl`, which runs before the module exists, so the build and the lookup cannot drift. A checkout builds into `deps/<crate>/target`; an installed package (a tree under a depot's `packages/`) builds into `<depot>/scratchspaces/<UUID>/native-v1/<slug>/<crate>` and its package directory is never written to. `deps/build.jl` runs no `cargo clean` (Cargo's own fingerprint decides what to redo) and passes `--locked`, because Cargo writes `Cargo.lock` beside the manifest whatever `CARGO_TARGET_DIR` says; `deps/rustcall_helpers/Cargo.lock` and `deps/rustcall_extract/Cargo.lock` are committed for that reason, and a stale one fails the build. Overrides: `RUSTCALL_EXTRACT`, `RUSTCALL_HELPERS` (`RUSTCALL_RUST_HELPERS` is a deprecated alias). The helper crate was `deps/rust_helpers` / `librust_helpers` through v0.3.x (#387); the old name was a lookup fallback through v0.4.x and is not searched since v0.5 (#417), and `helper_library_policy()` registers the image as `rustcall_helpers`.
- `src/manifest.jl` — runs the CLI, validates `schema_version`, converts the TOML manifest into `RustFunctionSignature` / `RustStructInfo` / `RustMethod`, and computes `toolchain_fingerprint()` (the schema identifier + the source digest of the **selected extractor's build**, computed by `deps/build.jl` from Cargo's own view of that build (`src/extractor_identity.jl`, #409) and stored beside the binary keyed by its SHA-256 (`extractor_source_digest()`) + the tree's `rustcall_julia_core` / `rustcall_julia_macros` / `rustcall_julia_macros_impl` sources with each `[package] version` left out + `artifact_compiler_identity()`) that is part of every cache key. The extractor's *bytes* are deliberately not in it (#372): a patch release bumps the crate version and Cargo folds that into `-C metadata`, so the same sources give a byte-different executable, and the key would move on a release that promises to keep it; the record follows `RUSTCALL_EXTRACT` only to a binary it names, and any other binary — one without a record, one whose record names another binary, or one whose build was not this tree's own layout (Cargo's `locate-project` and `tree` decide: the crate must be its own workspace root, every local package one of the four release crates in `deps/`, every other package from crates.io) — is identified by its bytes (`binary:<sha256>`), never by this checkout's sources. A digest is claimed only for a **plain** build (the closed rule, #413): nothing in the environment that Cargo or rustc would act on beyond where things are, which toolchain, and how Cargo talks (`CARGO_HOME`, `CARGO_TARGET_DIR`, `RUSTUP_*`, `CARGO_TERM_*`, `CARGO_NET_*`, ...), and no discovered configuration file with a table beyond those kinds (`[net]`, `[http]`, `[term]`, `[registries]`, ...). A flag, a wrapper, a linker, a profile override, a source replacement, a `[build]` or `[target]` table — anything else — is not hashed on top of the sources; it makes the build non-canonical and the binary is identified by its bytes. There is therefore no list of build inputs to keep complete. The binary reports nothing about itself: `deps/rustcall_extract/build.rs` and the `source-digest` subcommand, which embedded the same digest as a cross-check through v0.4.x, were removed in v0.5 (#417). Only the four release crates (`RUSTCALL_RELEASE_CRATES`, `src/artifact_id.jl`) lose their version in an identity — any other crate may read `env!("CARGO_PKG_VERSION")` — and only as *this package's* `deps/<name>` (`_is_rustcall_release_crate`, a `realpath` comparison; a lockfile entry only when the crate takes that name by path from there): a same-named fork keeps its version. The extractor's own digest folds in `deps/rustcall_extract/Cargo.lock` minus the release-coupled version lines, so a registry bump of `syn` or `prettyplease` moves it.
- **Exported symbols are derived in exactly one place** (#300): `rustcall_julia_core::codegen::symbol_stem(module_path, name)` — the bare name at the crate root, otherwise the module path folded in (`a::run` → `a__run`, `_` inside a segment spelled `_0`). `function_symbol` / `method_symbol` and every struct-level symbol (`<stem>_free`, accessors, string helpers) hang off it; the manifest carries it as `ffi_name` and Julia passes `ffi_name`, never `name`, to `ffi_struct_free_symbol` / `ffi_free_symbol`. The proc-macro learns the path from `#[julia]` on inline modules (`transform_module`); crate extraction refuses a `#[julia]` item in an unmarked inline module, and `rustcall-extract` fails closed on a crate-wide duplicate symbol. Julia binds one submodule per Rust module (`bindings.a.run()`). The unexported generic wrappers of a generic inline struct hang off the same stem (`a__Pair_new`, `a__Pair_get_x`, `a__Pair_free`, #462): the manifest carries each method's as `Method.generic_wrapper_name` and every accessor's in `Field.getter` / `setter`, and Julia registers them under those names (`_generic_method_wrapper_name`), never `"$(name)_$(method)"`, owned by the defining block's library (`GenericFunctionInfo.owner`, `GENERIC_FUNCTIONS_BY_LIB`, #522): a group is one owner's members, and the generated code reads them from its defining block's library — the block's `RustBlockSnapshot` is spliced into it and matched against the module's recorded blocks after `_resolve_lib`, so a reload rename is followed (`_generic_struct_snapshot` / `_generic_struct_owner`); the member and its whole group are one `GenericStructSnapshot` read in one transaction (`_read_generic_struct_snapshot`, the only reader of the generic registrations in `src/structs.jl`, which `test/test_generic_struct_ownership.jl` asserts on the parsed source) and the instantiation (`_instantiate_generic_struct_group`) reads none; a known owner's rows that vanish mid-lookup are restored and read again or refused, never answered by the bare name — one helper, `_resolve_own_definition`, shared with `resolve_rust_call`, which applies the same rule to a caller's own block found unloaded after its restore, deciding from one `_own_definition_snapshot` (loaded, generation, generic row, export — one transaction) plus a generation re-check after its cold symbol lookups, never from a row read and a liveness check made separately; never `@rust` name resolution, which a later block's ordinary export of a member's name would answer — so two modules' same-named generic structs never share a registration.
- **The proc macro refuses a generic `#[julia]` item** (#462): a type or `const` parameter, or `impl Trait` in a signature, on a function, struct, impl block or method is one spanned `compile_error!` at the item (`crate_generic_refusal` in `refusal.rs`, trybuild `tests/ui/generic_*.rs`); lifetime parameters are wrapped as usual. Generics are a `rust"""` feature, monomorphized through `specialize` — for free functions and generic structs only: a generic `pub fn` of a **non-generic** inline struct is refused at the method too (`inline_generic_method_refusal`, #471), gated by its `#[cfg]`, since no struct parameter binds the method's own; a method of a **generic** inline struct with parameters of its own is refused the same way (`inline_generic_method_refusals`, #477), since instantiating the struct binds only the struct's. **Every refusal is decided in one place** (#503): `deps/rustcall_julia_core/src/refusal.rs` returns a `Refusal { kind, detail, span, message }` (`function_refusal`, `method_refusal` with a `MethodSite`, `struct_refusal`, `impl_refusal`, `module_refusal`, `item_kind_refusal`; the wrapper-level ones — `Self`, lowered `&str` lifetimes — come from `codegen::generate_wrapper`'s own `wrapper_tokens`, asked through `free_function_wrapper_refusal` / `method_wrapper_refusal`). The expansion emits only `Refusal::compile_error` (bare, spanned start..end, cfg-gated, the item kept as written) and the manifest keeps every refused item with `Refusal::skip_reason` — a value of `skip_reason::CODEGEN_REFUSALS` (`unsafe_fn`, `generic_signature`, `impl_trait`, `non_ffi_payload`, `self_trait_path`, `unspellable_self`, `lowered_str_borrow`, `lowered_str_lifetime`, `receiver_type`), additive within schema 0.7; a refused item is not `exported` and claims no symbol. A crate trait impl's refused `#[julia]` methods are recorded on their struct with `Method.trait_path` (additive within 0.7), and a method is identified by `(trait_path, name)` (`MethodModel::is_same_method`), so an inherent or another trait's method of the same name never merges a refusal away; the report labels it `<S as tr::Trait>::m`. Since #506 every `#[julia]` method of a crate trait impl is described (refused or wrapped) and bound by both crate emitters; every per-method name (symbol, string owner, `CResult_`/`COption_`) hangs off `codegen::method_stem` — the name for an inherent method, `<len><Trait>_<name>` (`3Far_m`) for a trait's — and a trait method whose name another method of the struct shares is bound in Julia as `<Trait>_<name>` (`Method.julia_name`, decided by `extract::julia_method_names`, read through `julia_method_name`; `julia_name_clash` refuses a taken name, `claims` a duplicate symbol); a trait's `Self`-returning function is not a constructor. What no manifest entry can carry (`#[julia] mod a;`, a non-path impl header, `#[julia]` on any other item kind) fails the crate scan with the refusal's message; the unsupported kinds are decided exhaustively over `syn::Item` (`Verbatim` included, its attributes read from its tokens) by `refusal::unsupported_item_kind`, and the scan, the `#[julia] mod` expansion, the `rust"""` expander (which then fails) and the proc macro (`attribute_target_refusal`) all ask `julia_item_refusal` / `item_kind_refusal`. Julia mirrors the kinds in `RUST_CODEGEN_REFUSALS` (`src/ffi_contract.jl`; `_rust_refuses`, `_binds_julia_struct`); `tests/refusals.rs` (core) and `test/test_codegen_refusals.jl` walk every kind through every position — add a case there with any new refusal. **A wrapper declares the item's whole environment, verbatim** (`deps/rustcall_julia_core/src/environment.rs`, #477, #482): the impl block's lifetime parameters and `where` clause (`ImplHost` on `MethodModel` / `WrapperSpec`), then the method's, with `Self` spelled as the impl header's type (`Self::Assoc` → `<Buf>::Assoc`, or `<Buf as Trait>::Assoc` in a trait impl; in type and expression position, e.g. `[(); Self::N]`; an unqualified `Self::N` *constant* is always `<Buf>::N`, even in a trait impl — rustc's own lookup, inherent first — and is refused when the trait impl names its trait by a path, which may be out of scope at the wrapper; generic-struct wrappers too). Every method is called by path, never by method-call syntax (which needs a trait in scope and reaches a same-named inherent method first): `<Buf as tr::Far>::m(self_obj, ..)` for a trait impl's (`environment::trait_item_path`, #497), `<Buf>::m(self_obj, ..)` for an inherent one (`environment::method_item_path`, #509). **One receiver model** (`deps/rustcall_julia_core/src/receiver.rs`, #509): `Receiver::of` reads the receiver as reference layers over `Self` or the header's own spelling of the type (`self: &mut Self`, `self: &Buf` in `impl Buf`, `self: &&Self`, by value) and decides the wrapper's `*const` / `*mut`, the `self_obj` binding, the path call's first argument and the manifest's `is_mutable` (innermost layer `&mut`), for inherent and trait methods, both flavours and generic-struct wrappers; `MethodModel::receiver()` is the only reader. A receiver it cannot read (alias, smart pointer, other spelling) is refused as `receiver_type` (`refusal::receiver_refusal`). No predicate is selected, rewritten by a token rule or dropped — do not reintroduce per-predicate filtering. Only lifetimes the wrapper names nowhere are pruned (so `fn f<'a>(s: &'a str)` keeps `rustcall_f` unparameterised and the golden corpus is unchanged). A `Self` inside a macro, and a lowered `&str` argument whose lifetime must outlive the call (`'static`, named by the return, by a passed-through argument other than as its outermost reference, or by a type predicate, directly or through `'c: 'a` bounds — `lowered_lifetime_error`), are refused with a spanned bare `compile_error!` at that token. Corpus: `tests/predicate_transfer.rs` in core and in `rustcall_julia_macros` (+ `tests/ui/lowered_lifetime.rs`). **An elided output lifetime is named, not copied** (#484, `name_elided_return`): the wrapper's receiver is a raw pointer and a lowered string a byte pair, so elision on the wrapper would find nothing (E0106 in generated code); Rust's rules are applied to the item instead — the reference receiver's lifetime (named, or a fresh `'rustcall` declared on the wrapper), else the one argument lifetime (an elided one named on both sides). The one lifetime being a lowered `&str`'s is refused at that argument; an ambiguous item gets no wrapper (rustc reports E0106 at its own signature). Generic-struct wrappers name a reference receiver's the same way. Corpus: `tests/elided_returns.rs` in core and in `rustcall_julia_macros` (+ `tests/ui/elided_return.rs`).
- **A plain return leaves a wrapper as `MaybeUninit<T>`** (#462): same ABI as `T`, and the panic sentinel is `MaybeUninit::zeroed()`, never `mem::zeroed::<T>()` (UB — and a non-unwinding abort — for `&T`, `Box<T>`, `NonZero*`, fn pointers). Generated struct helpers (`guard_struct_helper`) follow the same rule. A Rust caller of a generated wrapper reads it with `assume_init()`.
- Do not add regexes over Rust source in `src/`; `scripts/lint_rust_syntax_regex.sh` fails CI. Allowlisted: `$var` interpolation in `@irust` (`ruststr.jl`), the `// cargo-deps:` DSL (`dependencies.jl`), and the brace-count hint in `exceptions.jl` (diagnostics only).

### Compilation pipeline

1. `rust"""..."""` (`src/ruststr.jl`) calls `expand_inline` (extractor) at macro-expansion time, emits Julia definitions from the manifest, and compiles the expanded source at run time (direct `rustc`, or a temporary Cargo project when `// cargo-deps:` is present)
2. `src/compiler.jl` invokes `rustc` to produce shared libraries
3. `src/codegen.jl` generates `ccall` expressions (the LLVM IR path and `@rust_llvm` were removed in 0.3.0, #265)
4. `src/rustmacro.jl` expands `@rust` and `@irust` into the appropriate call mechanism
5. `src/cache.jl` provides caching of compiled artifacts in a **Scratch.jl space** (#252): `get_cache_dir()` is `<depot>/scratchspaces/<RustCall UUID>/cache-v$(CACHE_FORMAT_VERSION)`, with `metadata/` and `cargo/` under it. RustCall writes **nothing** under `~/.julia/compiled/` — that is Julia's own precompile directory, read-only for RustCall and never created by it; `_legacy_cache_root()` is read only by the opt-in legacy sweep (`clear_cache(sweep_legacy = true)`), which removes RustCall's own `v<n>`/`cargo`/`metadata` directories and loose files matching the exact pre-#278 naming, and nothing else. The depot is the first *writable* entry of `DEPOT_PATH`, so a read-only `DEPOT_PATH[1]` still works; `RUSTCALL_CACHE_DIR` overrides the location outright.

### Artifact identity is computed in exactly one place (issue #278)

- `src/artifact_id.jl` — `ArtifactId` (the exhaustive record) and `artifact_key` (its SHA-256 over a netstring-framed, injective encoding). Every cache key, library name and temporary project name in the package derives from it: `generate_cache_key` / `_rustc_block_identity` (direct rustc), `_cargo_block_id` / `_cargo_block_identity` / `build_cargo_project_cached` (Cargo), `_monomorphization_id` (generics), `compute_crate_hash` (`@rust_crate`), `@irust`.
- `artifact_short_id` is the **only** truncation, and only for names a human reads. Lookup keys are the full 64-hex digest.
- **A short id that is a location is owned by its full key** (#504). Windows' path limit (#486) makes some short ids paths or Cargo package names: the crate target directory (`crate_target_directory`), the PyO3 wrapper's package `rustcall_wrapper_<short>` (its output lands in the crate's shared target directory), the PyO3 host extension's cache directory (`pyo3-host/<short>`), a debug build's `rust_<short>.rs` / library in `debug_dir`. Every one is spelled and owned in `src/short_name.jl`: `short_name` / `short_name_path` spell it; a **persistent** name (found again later by the name alone) is claimed for good with an `O_EXCL` owner record holding the full key (`claim_short_name!`; inside a directory, `SHORT_NAME_KEY_FILE`, or beside a file stem) and a colliding key is refused, never shared; a location with contents but **no** record is foreign, never adopted (#507 review) — under `SHORT_NAME_CLAIM_LOCK` in the parent it is emptied (`foreign = :clear`: the crate target directory, the PyO3 host cache, a debug stem's own `<stem>.*` / `lib<stem>.*` files) or refused (`:refuse`, the default), and only an empty or absent one is claimed as it stands; a build that writes and copies out an output under the name holds the name's lock from build start through copy-out (`with_short_name` for a name reused over time, `with_owned_short_name` for claim + lock). `scripts/lint_artifact_identity.sh` rule 4 fails CI on any other `artifact_short_id(` in `src/` unless the line is marked `# short-id: label` (an in-process registry name such as `rust_<short>` / `rust_crate_<name>_<short>`, a Rust symbol inside its own library, the `rustcall_block_<short>` package of a fresh private Cargo project, a log field) or `# short-id: lease` (the generation-copy host / instance tokens, not artifact keys, owned by their generation lease); a marked line may not build a path. `test/test_short_name.jl` forces a prefix collision for each name.
- `artifact_compiler_identity()` names the `rustc`/`cargo` `RustToolChain` resolves — never a bare `rustc` on `PATH` — and raises when it cannot (#252). `toolchain_fingerprint()` folds it in and, without a compiler, records an unmemoized placeholder instead of raising (it still needs the extractor).
- Path dependencies are hashed by content, re-read in full on every call (a `(mtime, size)` stamp can alias distinct contents). Only the resolved dependency graph is memoized — validated against the content digests of every manifest that decides it, including each crate's workspace root, found through an explicit `[package] workspace = "..."` before the ancestor search — and a block with no `path =` dependency never spawns `cargo tree`.
- Do not concatenate key material, truncate a digest, or name an artifact with Julia's randomized `hash()` outside `src/artifact_id.jl`; `scripts/lint_artifact_identity.sh` fails CI.

### Type system and runtime

- `src/types.jl` — Rust/Julia wrapper types: `RustPtr`, `RustRef`, `RustResult`, `RustOption`, ownership types (`RustBox`, `RustRc`, `RustArc`, `RustVec`, `RustSlice`)
- `src/typetranslation.jl` — bidirectional Rust ↔ Julia type mapping
- `src/memory.jl` — ownership operations backed by the Rust helpers library (`deps/rustcall_helpers/`)
- `src/exceptions.jl` — `RustError`, `CompilationError`, `RuntimeError`
- **Callbacks (#296)** — a `#[julia]` argument of type `extern "C" fn(A...) -> R` is reported by the extractor as `Arg.abi = "callback"` with `callback_args` / `callback_return`; `ffi_callback_plan` (`src/ffi_contract.jl`) decides at wrapper generation which pointer signatures are buildable (one-slot by-value / raw-pointer types with slot = surface), and `_string_arg_plan` passes Rust a constant `Base.@cfunction` pointer to the singleton slot `CallbackSlot{k, R}()` (no closure `@cfunction`: aarch64 has none; `R` is a parameter so a slot invoked with no frame records a `RustError` and returns a zero of `R` instead of raising through Rust, #460; `_callback_slot_k` remains only for bindings files of format <= 11) while the user's function travels in a `CallbackFrame` pushed onto a task-local stack for the call and popped by the `try … finally` every wrapper generator wraps its `ccall` in (`_in_callback_frame` / `_emit_in_callback_frame`). The trampoline never lets a Julia exception unwind through Rust: it stores the exception in task-local storage (fast path: the `_CALLBACK_ERRORS_PENDING` atomic) and `guard_rust_panic_ptr` — the one choke point every generated call passes after the `ccall` — re-raises it, draining a panic Rust raised on the sentinel. Argument position only; synchronous borrow; same thread.

### External crate integration

- `src/dependencies.jl` + `src/dependency_resolution.jl` — parse `// cargo-deps:` and `` //! ```cargo ``` `` formats
- `src/cargoproject.jl` + `src/cargobuild.jl` — generate and build Cargo projects
- `src/julia_functions.jl` — `RustFunctionSignature` and Julia wrappers for `#[julia]` functions (Result/Option aware)
- `src/crate_bindings.jl` — crate scanning via the extractor (crate mode), Julia wrapper generation, `@rust_crate` macro
- **Emitted code names nothing a crate item can take** (#528, `src/emitted_names.jl`). A generated module binds the crate's items under their names, so every reference the emitted code makes to Base, Core, RustCall or PythonCall goes through a name no Rust identifier can spell: expression templates (`@rust_crate`, the PyO3 host, the shared argument plans) are written with `@_emitted`, which turns their free Base/Core/RustCall names into `GlobalRef`s at load time; a contract type spelling spliced into one goes through `_emitted_type`; the source-text emitter binds `import Base as rustcall′Base` / `import RustCall as rustcall′RustCall` per module and prints shared expressions with `_emitted_source` (U+2032 is never XID_Continue). Every function a module defines is declared first (`function Int32 end`). Do not add a bare `Base.`, `RustCall.` or Base-function call to a template outside `@_emitted`, and never reserve an item name for it: `test/test_module_name_shadowing.jl` lowers every emitter's output and fails on any free global a Rust identifier could spell that the module does not define itself.
- **One environment snapshot per crate build** (#481, `src/build_env_snapshot.jl`): `generate_bindings` (`@rust_crate`: direct crate, generated wrapper crate, PyO3 wrapper crate), `write_bindings_to_file`, `build_pyo3_extension` (PyO3 host) and a hot reload (`_reload_library_once`) each take exactly one `BuildEnvSnapshot()` at their start. The PyO3 plan and its probes, the cfg probe, the cache key (`compute_crate_hash(...; snapshot)`), the registry name, the `CrateBuildRecord` (`crate_build_record(...; snapshot)`, required), the checks against a record (`_build_record_mismatch(record, snapshot)`), every Cargo subprocess (`snapshot_env` / `_record_build_subprocess_env(record, snapshot)`) and every Python interpreter (`snapshot_cmd`, `snapshot_which` for `PATH` lookups) are derived from it. So are the scans (`scan_crate(...; cargo_env)`, which probes its lenient cfg with `_cargo_cfg_text(env)`) and the path-dependency graph behind the key (`artifact_path_dependency_digest(...; env)`). After the snapshot, nothing on a build path reads `ENV`, calls `Sys.which`, or spawns a command outside `setenv` / `snapshot_cmd`. `test/test_build_env_snapshot.jl` asserts this at the source level. It finds the build path from the signatures: any function taking a `BuildEnvSnapshot`, plus the named entry points. A helper that defaults to the live environment (`artifact_build_env`, `_cargo_config_digest`, `_cargo_network_args`, `compute_crate_hash`, ...) must be handed the build's own. After building and before caching or publishing, every build path re-asks the Python interpreter it pinned (`_verify_build_interpreter`), so an interpreter replaced in place during the build is refused. The record is taken **once per build**, and a build path always hands it to the emitter (`build_record`). The source test forbids an emitter call on a build path without one: the emitter's own fallback would ask the interpreter again after verification. The PyO3 wrapper's record comes from its verified plan (`pyo3_wrapper_build_record`, `link_source`), which holds the values its key was computed from (#485 review). The task-local `_AFTER_BUILD_ENV_SNAPSHOT` seam calls a test's hook with a stage: `:snapshot` right after the snapshot is taken, and `:verified` right after an interpreter check passes. Zero-argument convenience forms (`_recorded_build_env()`, `python_link_source()`, ...) take their own snapshot and are for callers off the build path only.

### Loading, unloading and registration happen in exactly one place (issue #277)

- `src/loadpolicy.jl` — `LoadPolicy` (the four decisions a front door used to make for itself: `dlopen` flags, panic strategy, registration, finalizer policy) and the one load path: `load_artifact!` / `adopt_artifact!` / `register_artifact_metadata!` / `unload_artifact!` / `alias_artifact!`. Every door names its own policy (`inline_rustc_policy()`, `inline_cargo_policy()`, `irust_policy()`, `generics_policy()`, `hot_reload_policy()`, `crate_direct_policy()`, `crate_wrapper_policy()`, `helper_library_policy()`), so changing a policy is one edit.
- Every policy is `RTLD_LOCAL | RTLD_NOW`: nothing RustCall loads needs process-global symbols, because every call goes through `dlsym` on a specific handle. The `RUSTCALL_DLOPEN_GLOBAL=1` escape hatch was removed in v0.5 (#417).
- Every policy RustCall builds is pinned to `panic = "unwind"` — on the `rustc` command line, in the generated `Cargo.toml`, and in `CARGO_PROFILE_<PROFILE>_PANIC` — because the generated `catch_unwind` boundary can only catch a panic that unwinds. See `docs/src/panics.md` for the semantics matrix.
- Do not call `Libdl.dlopen`/`dlclose` or write `RUST_LIBRARIES[...]` in `src/`; `scripts/lint_load_path.sh` fails CI (no allowlist since #265 Phase 2).

### Other modules

- `src/generics.jl` — generic function registry and monomorphization through `rustcall-extract specialize`
- `src/structs.jl` — `RustStructInfo` / `RustMethod` and Julia type generation for `#[julia]` structs
- `src/hot_reload.jl` — file watching and reload for crate workflows. **A reload's inputs come from one record** (#474): every generated `@rust_crate` module holds one immutable `CrateBuildRecord` (`_BUILD_RECORD`: crate dir, lib name, profile, features, default features, kind, build env, Cargo config digest, toolchain, python flag), made by one call (`crate_build_record`) and emitted identically by the expression and source-text emitters (`repr` is its source spelling; `_LIB_NAME` is read from it). `HotReloadState` carries that record and nothing else about the build; `_scan_crate_signatures`, `rebuild_crate` and the environment check (`_build_record_mismatch`) take the record. The module form of `enable_hot_reload_for_crate` reads it once and only *compares* caller arguments with it; the path form and `enable_hot_reload` construct one. A new rebuild input is a new field, and `test/test_hot_reload_record.jl` fails until it has a refusal case. Every reload step — env check, rescan, build, copy, load — fails the reload the same way (`false`, `last_failure`, callback, previous image current, #473).
- `src/precompile.jl` — what RustCall's own package image carries beyond what its methods reach statically (#449). Two workloads run only under `jl_generating_output`: the `__init__` helper-load path, and the interpreter-free half of the PyO3 host path (`scan_crate`, `compute_crate_hash`, the cache lookup) against a throwaway crate in a temporary directory. The second **starts no `rustc`, `cargo` or Python** (RustToolChain may have to download a toolchain; a compiler identity would be memoized): every memo the path would fill by running a tool holds a placeholder for the duration and is restored in `finally`, the extractor is optional (a checkout precompiles before `Pkg.build`), and `test/test_precompile.jl` compares every state value before and after, then checks in a child process with `--trace-compile` that the path's entry points are not compiled at run time. `Base` methods reached through the `@nospecialize` `StateView` read/write callables have no backedge from RustCall's code, so their directives are derived from the registries' container types (`_precompile_state_container_ops`), never listed by hand. Call sites that read a memo (`extractor_path()`, `get_cache_dir()`) are typed `::String` so the spawn or call behind them is inferred and kept.
- `src/boundary_report.jl` — `boundary_report` / `inline_boundary_report` (#441) are **computed by the wrapper generators themselves** (#454). The report runs the same emitters `rust"""` and `@rust_crate` run (`_inline_wrapper_exprs`, `_crate_wrapper_exprs`) in the collecting mode of `src/ffi_contract.jl` (`_collect_boundary`, task-local like the callback frame stack), where every position a generator decides is recorded (`_boundary_examined!`) and a refusal is a finding instead of a `RustError` (`_boundary_refuse`, `_ffi_unsupported_return`); the report prints what was recorded. No rule about what is wrapped, examined or refused lives in the report, and `test/test_boundary_collect.jl` asserts that at the source level, shows a refusal added to a generator appearing in the report, and checks that the expression and source-text crate emitters record the same positions. Four things keep it by construction: an emitter's entry point names its item (`_boundary_item!`) **before** its argument plan, and a position recorded with no item named is an error rather than a misfiled finding; a generator's own refusal goes through `_boundary_refuse` (throw outside collecting mode, record inside); a `Result` / `Option` payload names its position (`ffi_payload_symbols(...; position = "Ok payload")`, no default) and a field's one position comes from `_ffi_field_position`, whatever accessor reads or writes it; a return spelling generation never resolves — a boxed `Self` handle, a `Result` / `Option` whose payloads are the positions — is looked up but not recorded (`_ffi_method_return`, `_ffi_item_return`). **Notes** (#490) are the same mechanism for decisions the contract accepts but that leave a responsibility with the author: `_boundary_note!` files a `BoundaryNote` under the named item (not a position, not counted in `checked`). Two rules, both in `src/ffi_contract.jl` and called only by generators: `_boundary_raw_pointer_return!` (a raw-pointer return or payload has no derived release function — from `_ffi_item_return`, `ffi_payload_symbols`, `_manifest_return_type`) and `_boundary_unguarded_export!` (a hand-written `#[no_mangle] extern "C"` export `@rust` can call without a panic boundary — from `_manifest_registry_entries`, which `inline_boundary_report` runs over `_registry_signatures(manifest)`, the list `_register_manifest` registers). A crate's hand-written exports are not bound by `@rust_crate` and get no note. **A refusal the Rust codegen makes on its own** (#491: a `#[julia]` function or method that is an `unsafe fn`, refused with a `compile_error!` gated by the item's `#[cfg]`) reaches Julia as the manifest's `skip_reason` (`unsafe_fn`, added in schema 0.7); every emitter asks `_rust_refused_item!` right after `_boundary_item!` (function loops through `_function_skipped!`, generics included), emits no wrapper — the layout checks (`_check_module_names`, `_static_method_collisions`) skip the same functions through the same `_binds_julia_wrapper`, so a refused item takes no name — and in collecting mode records the refusal at the item's `"entry point"` through `_boundary_refuse`. Outside collecting mode it raises nothing — the codegen's refusal stands, and a lenient crate scan cannot tell whether the build configures the item away.
- `src/toolchain_check.jl` — `RustCall.check_toolchain()` (#490): the resolved `rustc` / `cargo`, their versions against `minimum_supported_rustc()` (the `rust-version` of `deps/rustcall_extract/Cargo.toml`, which `test/test_toolchain_check.jl` checks against the locked dependency graph — bump it when a lockfile update raises the graph's floor), and the extractor's path, schema and identity. Builds nothing, raises nothing; returns a NamedTuple with `ok` and `problems`.

### Include order

`src/RustCall.jl` defines the include order, which reflects module dependencies. New modules must be added respecting this order.

## Thread Safety

Mutable runtime state is stored in `RustCall.STATE`, a `Base.Lockable{RustCallState}` in
`src/RustCall.jl`. The legacy names (`RUST_LIBRARIES`,
`GENERIC_FUNCTION_REGISTRY`, the per-library metadata tables and
`ARTIFACT_ALIVE`) are lock-taking `StateView`s into that container; they are not
independent mutable globals. `REGISTRY_LOCK` is the container's lock. The lock
ordering rule is: take `STATE`/`REGISTRY_LOCK` only for an in-memory state
transaction, never while calling user Julia code, compiling, opening/closing a
library, or executing a Rust `ccall`; perform those operations before or after
the transaction. The deferred-drop queue's storage is also in `STATE` and its
compatibility lock aliases the state lock. Only explicit drops enqueue;
ownership finalizers use captured destructor pointers and liveness flags,
with an atomic exactly-once claim, and never access that queue.

Read-only tables use immutable dictionaries and tuples. The state test scans
module values (including factory results and immutable wrappers), so a new
mutable registry is rejected without adding its name to a list. A Julia-AST
check also rejects blocking operations, FFI and logging inside explicit state
transactions. Compiler initialization publishes only if no concurrent setter
has won. Watcher selection, task publication and stop snapshots are state
transactions; scheduling, waiting, source I/O and callbacks occur outside them.
StateView cache defaults are evaluated outside STATE, then published only if
another task has not already supplied the key. This includes the cold Cargo
and rustc cfg probes, whose subprocess must never run inside a state transaction.
Library metadata iterators and string conversions are materialized and validated
before STATE is acquired. The publication helper accepts only prepared concrete
rows, so a failing iterator or invalid return type cannot erase prior metadata.
Explicit retirement also materializes its caller-supplied handle iterator before
changing liveness flags under STATE.
StateView `filter!` likewise evaluates predicates on a snapshot outside STATE.
Active filters observe container writes in the same state transaction; key
updates and original vector-occurrence tokens distinguish delete/reinsert from
an unchanged entry, even when the value is identical. The deferred queue and
module metadata use that same mutation path. Observations are released when
filtering completes or throws. Callers must not wrap arbitrary callbacks in
their own outer STATE transaction.

FFI layout method definitions use a separate, STATE-owned definition gate.
Never acquire that gate while holding STATE: fetch it first, release STATE,
then serialize the method-table edit. User-defined layout callbacks run outside
both locks, with the exact method rechecked before accepting an existing
registration. `Core.eval` and method deletion never run inside STATE.

Inline `rust"""` caller modules also use owner-qualified `StateView`s for
their library, symbol and active-library tables.
Legacy caller containers are copied into concrete STATE-owned storage outside
the lock when adopted; internal module binding access then returns owned views.
The caller's historical Dict/Ref constants are no longer live registry aliases.
`src/module_state.jl` publishes these tables together after validating every
symbol collision. During caller
precompilation, only immutable `ModuleBlockRecord`s are serialized; a fresh
process reconstructs the mutable tables in `STATE` before loading the recorded
blocks. Runtime cache hits do not add precompile-record bindings. Both crate
module templates also expose owner-qualified views for their generation cell
and symbol cache; preload paths, source inputs and recorded environment values
are immutable tuples. A symbol-cache miss resolves outside STATE and only its
publication takes the state lock.

**Finalizers must never take `REGISTRY_LOCK`, do a registry lookup, resolve a symbol, or log.** A finalizer runs at an arbitrary point on an arbitrary thread, possibly while that thread already holds the lock — taking it deadlocks, a `dlsym` plus method compilation inside a finalizer is a crash, and `@warn` allocates and can yield. Everything a finalizer needs is captured at construction: the destructor pointer and the library's liveness `Ref{Bool}` (`RustCall.artifact_alive_ref`). The shared body is `finalize_rust_object!` in `src/structs.jl`; a destructor that raises is counted (`finalizer_failure_count()`), not logged. `test/test_finalizers.jl` asserts this at the source level, so a new finalizer that breaks the rule fails CI.

**A caught panic prints nothing (#304).** A generated artifact keeps a
thread-local boundary depth at its crate root and exports
`__rustcall_install_panic_hook` / `__rustcall_uninstall_panic_hook`; `load_artifact!`
installs once per image right after `dlopen` (never lazily — that is what removes
the race) and `close_artifact_handle!` removes it before `dlclose`, on the last
loader reference and only while the handle still has none left. Those two
transitions — record-a-reference-then-install and confirm-none-left-then-uninstall
— are serialized by `QUIET_HOOK_LOCK`, **taken before `REGISTRY_LOCK`, never
after**; the only foreign code called under it is the artifact's own
installer/uninstaller, and `REGISTRY_LOCK` is never held across that call.
Install and uninstall are repeatable on the Rust side (one mutex, not a `Once`),
so a reopened image can restore its own hook. Names beginning with
`__rustcall_` are reserved: Julia calls the installer it finds under that name as
`extern "C" fn()`, so the name must be one the symbol scheme cannot produce for a
user's item. The hook is
silent inside a boundary and delegates to the hook it replaced outside one. The counter lives in one of
two places, and `rustcall_julia_core::codegen::PanicHook` is the choice:
`FileOwned` puts it at the root of a file RustCall writes whole (inline blocks,
`@irust`, generics) and the guard reads `crate::__RustCallBoundary`; `Runtime`
takes it from the `rustcall_julia_macros` rlib the crate already links
(`::rustcall_julia_macros::__RustCallBoundary`), which is the only route open to
`#[julia]` — an attribute proc macro is handed one item and can emit no
crate-wide state. **The generated `@rust_crate` wrapper crate uses `Runtime` too**,
although RustCall writes it whole: it links the same rlib as the crate it wraps,
so emitting the items as well would define `#[no_mangle]`
`__rustcall_install_panic_hook` twice in one `cdylib` and split the image's
wrappers across two counters. A third variant, `External`, takes no guard
at all and keeps the default hook; nothing RustCall generates uses it — it is
the conservative default of `FreeFnOptions`, since a wrapper without a guard
still compiles where one naming an unreachable guard would not. `#[no_mangle]` items of a dependency rlib are
exported from the `cdylib` that links it — that is what makes the `Runtime`
route work at all — but only when something references the crate, so an artifact
with no generated wrapper exports no installer and gets no hook, which is
correct. The loader asks the **image** for the installer symbol rather than
asking the policy: every `@rust_crate` module loads with `crate_direct_policy()`,
so a policy flag would miss both the generated wrapper crate and every
hand-written `#[julia]` crate. `RUSTCALL_PANIC_HOOK=default` and
`-C prefer-dynamic` both keep the default hook; so does renaming the
`rustcall_julia_macros` dependency, which does not compile. See
`docs/src/panics.md`.

**A call site keeps its snapshot (#253).** Re-resolving everything on every call
cost ~9.9 µs and ~100 allocations in front of a 5 ns `ccall`, and did it all
under `REGISTRY_LOCK`, so four threads calling Rust ran *slower* than one. A
call site now keeps the `CallTarget` it resolved in a `CallTargetCache` spliced
into its expansion, and reuses it while `ARTIFACT_EPOCH` says no state write has
happened since. Four rules hold this together:

* **The epoch is bumped in `_state_mutate_storage!`** (`src/state_filter.jl`),
  the one helper every state-container write already passes through — never at
  the mutation sites, which are many and which grow. Over-invalidating costs a
  re-resolution; under-invalidating is a call into a retired image, so the
  counter is conservative in the only direction that is safe.
* **A cached entry carries the process that wrote it, not just the epoch.** The
  cache object is spliced into its wrapper's method body, so a package that calls
  a generated wrapper **from a precompile workload** serialises a populated entry
  — native pointers included — into its `.ji`. `ARTIFACT_EPOCH` starts at the
  same value in every process and cannot tell; a matching counter made the child
  `ccall` a pointer from the process that wrote it (`signal 10: Bus error`,
  reproduced). `SESSION_TOKEN` is a freshly allocated object replaced in
  `__init__` and compared by `===`, so a foreign entry can never validate — an
  identity, not a random seed that is merely unlikely to repeat.
* **Sample the epoch before resolving, never after.** `_refresh_call_target!`
  reads it first; a write landing in between then leaves the entry stamped with
  the older epoch and it is re-resolved, where sampling afterwards could stamp a
  pre-write snapshot as current and keep it forever.
* **Verify before publishing.** `@rust f(x)::T` checks the annotation against the
  snapshot (#245); that check moved to publication time, because both its inputs
  are fixed for the life of an entry. It must therefore run *before*
  `publish_call_target!`, or a rejected snapshot would sit in the cache and be
  reused with the check never running again.
* **The generation rule of #277 is unchanged.** What is cached is one whole
  snapshot, taken under one lock by `resolve_call_target`; nothing is ever
  reassembled from pieces, and `scripts/lint_generation_snapshot.sh` still
  forbids that everywhere.

Three smaller costs were on the same path and are gone: `normalize_arg_types` is
`@generated` (pure type arithmetic, 529 ns per call); `ffi_check_by_value_signature`
decides at compile time for any signature with no aggregate in it, and falls back
to the runtime check for one that has (so a later `register_ffi_struct` still
takes effect); and every cached entry point takes `args::Vararg{Any, N}) where {N}`
rather than `args...`, because a plain vararg method shares one specialisation
across arities and left the `ccall` behind a dynamic dispatch (590 ns).

`@rust f(a, b)` with no return-type annotation stays ~68× a raw `ccall`: its
return type is read from the snapshot at run time, so the call is a dynamic
dispatch by construction. `_call_and_guard` keeps it to exactly one.
`docs/src/performance.md` says to annotate it or use `#[julia]`.
`benchmark/benchmarks_dispatch.jl` is the instrument; `test/test_dispatch_cache.jl`
asserts the invalidation contract, including that a warmed call site completes
while another task holds `REGISTRY_LOCK`.

**A `@rust_crate` call site keeps its snapshot too, in a named `const`.** Same
scheme, a different carrier: a generated crate module is also emitted as
*source text* by `write_bindings_to_file`, and an object has no source
spelling, so the spliced `CallTargetCache` of `@rust` is not available to it.
Each call site declares a `RustCall.CrateTargetCache` of its own beside the
wrapper that uses it, and `_call_target` / `_vec_target` / `_ctor_target` /
`_struct_generation` take it as their first argument. Four things make that
work:

* **The cache name is `(kind, symbol)`, and `kind` is the *emitter*** —
  `_target_cache_name` in `src/crate_bindings.jl`: `:fn` a free function, `:m` a
  method wrapper, `:free` a struct's destructor, `:acc` a `get_x` / `set_x!`
  helper, `:prop` a `getproperty` branch. Each emits a given symbol at most once
  per module, so no `const` is ever declared twice — a field getter reached
  through the accessor *and* through `getproperty` is two call sites with two
  caches, which is what the split kinds are for. The name is spelled
  `var"#TC#<kind>#<symbol>"`, and the `#` is load-bearing: a generated module
  also binds whatever the crate exports, so a plain `_TC_fn_rustcall_foo` would
  collide with a crate exporting a Rust function of that name — legal Rust, and
  the module would redefine a `const` or define methods on a `CrateTargetCache`
  and fail to load. `#` cannot occur in a Rust identifier, so the two namespaces
  are disjoint by construction rather than by diagnosis.
* **`_symbol` / `_required_symbol` are declared `::Ptr{Cvoid}`.** The symbol
  memo is a `StateView` and hands back an `Any`; without the declaration every
  snapshot is a tuple of `Any`, and the cached fast path still boxes the
  pointer and the channel — 64 bytes and 150 ns a call, against 0 and 17 ns
  with it (measured).
* **The generation mirror bumps the epoch itself.** `_update_handle_mirrors!` /
  `_retire_handle_mirrors!` write a `Ref` rather than going through
  `_state_mutate_storage!`, so they are the one write a kept crate snapshot
  depends on that the choke point does not see. They call
  `_invalidate_kept_snapshots!` after the store. Every caller happens to change
  a registry row in the same transaction as well; a kept snapshot must not
  depend on that staying true.
* **`test/test_state.jl` exempts `CrateTargetCache`** from its mutable-registry
  scan, next to `StateView` and for the same reason: it is not state, it is one
  call site's memory of a snapshot STATE already published, discarded the moment
  the epoch or the session token says otherwise. Without the exemption a
  constructor's populated cache would be flagged, because the snapshot it keeps
  contains the image's liveness `Ref{Bool}`.

`BINDINGS_FORMAT_VERSION` became 11 for this: a file emitted here names
`RustCall.CrateTargetCache`, which an older RustCall does not have. It was 12
since #460 and 13 since #474. **Since #489 it is not a number of its own: it is
`RELEASE_FORMAT_IDENTIFIER`, the `MAJOR.MINOR` of `Project.toml` read at load
time (`src/manifest.jl`, the same value as `MANIFEST_SCHEMA_VERSION`).** Both
emitters write `# Bindings format: <MAJOR.MINOR>` and
`const _BINDINGS_FORMAT = RustCall.check_bindings_format("<MAJOR.MINOR>")`; the
check compares `VersionNumber`s — same `MAJOR.MINOR` loads (patch may differ),
another minor or major is refused with "regenerate with
`write_bindings_to_file`" — and `register_handle_mirror!(name, ::StateView)`
repeats it from `__init__`, which is what refuses an integer-format (≤ 13) file:
it declares no `_BINDINGS_FORMAT`. A bindings-format change therefore ships only
in a minor or major release, and a `MAJOR.MINOR` bump updates the marker quoted
in `docs/src/crate_bindings.md`, which `test/test_crate_bindings.jl` asserts
equals the constant.

**The panic channel is thread-local.** A generated wrapper records a panic in a `thread_local!` slot of its own library and returns a sentinel; Julia reads that slot with a second `ccall` immediately after the first. A Julia task may migrate to another OS thread at any yield point, so nothing that can yield — a lock, logging, I/O — may sit between the two `ccall`s; the channel pointer is resolved *before* the call (cached at load time). `test/test_panics.jl` stresses this with hundreds of tasks on the 4-thread CI job.

**One generation snapshot per call.** A library can be replaced under a running program (hot reload), so every FFI entry point captures its handle, cached pointers, liveness `Ref` and **return ABI** in **one** locked step. Cold function, panic-channel and release/destructor pointers are then resolved on that captured handle outside STATE. No later name lookup may supply any part of the returned target: that could cross a swap and pair an old call with a replacement's channel, allocator or ABI. Cache publication writes only to the captured image's cache. The legacy name-keyed panic cache compares its captured registry entry before publishing, but that comparison never changes the pointer returned to its caller. Explicit closing requires quiescence of the entire FFI operation, including target resolution.

There are exactly four snapshot constructors, and `scripts/lint_generation_snapshot.sh` fails CI if anything else resolves a piece on its own:

| constructor | where | what it returns |
| --- | --- | --- |
| `resolve_call_target` | `src/ruststr.jl` | `CallTarget`: pointer, panic channel, owned-`String` release fn, handle, return type / `FunctionInfo`, generation |
| `artifact_generation_snapshot` | `src/structs.jl` | `ArtifactGeneration`: a struct's destructor + the flag of the image that exports it |
| `generic_struct_generation_snapshot` | `src/structs.jl` | the same, for a monomorphized generic destructor |
| `_call_target` / `_struct_generation` | the two `@rust_crate` templates | the same two, from **one deref** of the module's `_LIB_GEN` — or the whole tuple that deref produced, kept in the call site's `CrateTargetCache` (#253) |

Two consequences worth knowing:

- **A constructor's snapshot includes the object's destructor.** `resolve_call_target(lib, ctor; free_symbol = "<Struct>_free")` returns the allocating wrapper *and* the `free_ptr` / `alive` the resulting object captures, so an object can never be bound to a generation other than the one that allocated it. `_call_rust_constructor` returns `(ptr, target)` for exactly this; the crate templates use `_ctor_target`.
- **A retired image keeps its identity.** An image is retired, not closed, so it stays mapped with live objects holding its flag; loading the same path again gets the same handle back and adopts that same flag (one mapped image, one flag), and a retirement closes exactly the number of owned opens it was retired with — never the live counter, which a concurrent reopen may have raised.
- **A cached record is a snapshot too.** `FunctionInfo` (a monomorphized generic, `register_function`) carries the channel, the handle and the generation it was built with, because it is called long after the lookup that produced it.
- **Generic objects keep image-specific members.** `GENERIC_STRUCT_ARTIFACTS` is keyed by both artifact name and the image's liveness flag. Rebuilding identical source after retirement reuses the name but creates a separate member map; methods and accessors select with the object's captured flag, never the current name alone. Retired mapped images keep their records; making an image inert during explicit reclamation removes its member map without touching a live replacement's map.
- **A generated `@rust_crate` module keeps one immutable record, not several `Ref`s.** `_LIB_GEN` is an owner-qualified StateView of a `CrateGenerationCell` in STATE — a mutable cell whose single field is `@atomic` and pointer-sized, so publishing a generation is one store and reading it is one load. A plain `Base.RefValue{CrateGeneration}` is **not** that: Julia stores the 24-byte record inline, so the write tore and a reader could pair one generation's handle with another's flag (#402, measured at 137129 torn reads out of 13211045). The record holds handle + liveness flag + generation, replaced wholesale by `_update_handle_mirrors!` inside the `REGISTRY_LOCK` transaction; wrappers read it once per call — or reuse the whole tuple a previous deref produced, while `ARTIFACT_EPOCH` and `SESSION_TOKEN` say it is still current (#253) — releasing STATE before symbol resolution or FFI. Two independently read cells are not a snapshot. `__init__` registers the mirror **before** loading and never assigns it afterwards — an assignment after `load_artifact!` would overwrite a newer generation a concurrent reload had already published. The raw-`Ref` registration overload is **refused** with a diagnostic naming `CrateGenerationCell` (#402) — since #489 a `RustError` that leads with the regeneration instruction, because the caller that actually reaches it is a pre-`StateView` bindings file: a `Ref` stores the record inline, so publishing into one is not a single store, and adapting by wrapping the caller's `Ref` would leave it silently no longer tracking the library. Nothing generated needs it — a module registers its `StateView`, and the cell behind that view is created by RustCall, so a file emitted before the change keeps working.

A replaced image is **retired, not closed**, so a call already inside one stays valid; a cached pointer finds its own image's flag through `alive_ref_for_handle`, never through the name. **One image, one flag**: every name of a handle shares it — an alias by construction (`alias_artifact!`), and a second `load_artifact!` of the same path by adopting the flag the image already has (`registered_alive_for_handle`, #291). A second flag would not be cosmetic: `unload_artifact!` retires with one of them and drops the other without flipping it, so objects holding the dropped flag believe themselves live over unmapped code. For the same reason, re-aliasing a name that already names this image does not retire it. `test/test_hot_reload_transaction.jl` asserts all of this adversarially: a reload loop against tasks that call, panic, allocate and drop — plus one that reads the crate-module record — checking that no call returns an unpublished generation, that no generation number is ever paired with two different results, that no panic is lost and that no finalizer fails.

`load_artifact!` (`src/loadpolicy.jl`) is the one place a library is opened and registered. `dlopen` runs **outside** the lock — it executes arbitrary init code and is slow — and everything else (handle, function-pointer cache, symbol mappings, return-type hints, `CURRENT_LIB`, liveness flag) is installed in one locked block, so no task can observe a half-registered library. Two tasks racing on the same path both open it; the registration mode decides the winner and the loser's duplicate handle is closed.

## Testing

Generated struct destructors use the shared Rust panic boundary. Constructor
snapshots and generated objects capture the destructor's `free_channel` along
with `free_ptr` and liveness from the same image. The finalizer calls free and
then consumes that captured channel with `(out = C_NULL, cap = typemax(Csize_t))`
before anything can yield, counting a failure without allocating a Julia
message buffer. This reserved read discards the message; normal null/zero
queries retain it for the usual message-reading path. Do not resolve a channel
or take STATE inside a finalizer. `test_destructor_panics.jl` runs real panicking
destructors in child processes, so a missing boundary fails instead of aborting
the entire test worker.

- Entry point: `test/runtests.jl`, driven by ParallelTestRunner. It auto-discovers every `test/test_*.jl` (74 files; other `.jl` files there are helpers) and runs them in parallel worker processes, then runs a serial set one at a time — `test_cache`, `test_core_api`, `test_cargo`, `test_pyo3_wrapper`, `test_pyo3_host` — because they assert on or share the Cargo cache. Positional arguments filter by name (`Pkg.test(test_args = ["test_cache"])`), `--list` lists, `--jobs=N` sets the workers.
- Network-dependent testsets (`test_external_crates`, `test_ndarray`, `test_phase4_ndarray`) skip unless `RUSTCALL_RUN_SERDE_TESTS` / `_REGEX_` / `_UUID_` / `_CHRONO_` / `RUSTCALL_RUN_HEAVY_INTEGRATION_TESTS` are set; the PythonCall layer of `test_pyo3_host` runs only in a session that has PythonCall. A skip is a visible `@test_skip`, never a silent `return` or an `if` with no `else` (#464).
- Tests are organized by feature: ownership, arrays, generics, cargo, crate bindings, hot reload, etc.
- `test/test_regressions.jl` holds regression tests for fixed issues
- Proc-macro tests: `deps/rustcall_julia_macros/tests/`
- Many tests require `rustc` and skip gracefully if unavailable
- **PyO3 wrapper tests that link libpython skip only when the prerequisite is absent.** A crate whose pyo3 dependency is mandatory is wrapped as a `:link_libpython` build (`docs/src/pyo3.md`). The shared `_link_libpython_wrapper` helper first requires `plan.mode === :link_libpython` and a linkable library in the directory selected by `python_link_source()`; it logs the reason and skips only then. Once that prerequisite holds, wrapper generation, Cargo, compiler, loading, and calls are hard failures. The helper is shared by `test/test_pyo3_wrapper.jl` and the PyO3 cross-module case in `test/test_module_symbols.jl`. A skipped testset is not a pass: on a machine whose Python ships a linkable library — `libpython3.x.so` (Linux, `python3-dev`), `libpython3.x.dylib` or a `Python3.framework` bundle (macOS), `python3xy.lib` (Windows) — or with `PYO3_PYTHON` / `RUSTCALL_PYTHON_LIBDIR` pointing at one, they run in full, and the Ubuntu CI jobs do run them. `test/test_pyo3_link_plan.jl` and `test/test_manifest.jl` only *compute* the plan (`plan.mode === :link_libpython`) and always run; so do the scan-level assertions and every `:python_free` case (`test/fixtures/sample_crate_pyo3_optional`, `sample_crate_pyo3`), which need no Python at all.

## CI

`.github/workflows/CI.yml`:
- **Rust tests**: `cargo fmt --check`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo test --all-features` in `deps/rustcall_julia_core`, `deps/rustcall_extract`, `deps/rustcall_julia_macros`, `deps/rustcall_julia_macros_impl`, `deps/rustcall_helpers` (stable + beta, Linux/macOS/Windows)
- **Julia tests**: `Pkg.test()` on Julia 1.x (Ubuntu x64, Windows x64, macOS aarch64) with `JULIA_NUM_THREADS=1`, plus **one Ubuntu job with `JULIA_NUM_THREADS=4`**, which first runs `test_state.jl`, `test_hot_reload_transaction.jl` and `test_generic_reload.jl` with `--threads=4 --check-bounds=yes` (the bounds-checked state and mixed-reload stress step)
- **Code Lint**: every `scripts/lint_*.sh`
- **Compile benchmark**: `benchmark/benchmarks_compile.jl` (cold and warm) on all three OSes, result in the job summary; informational

Other workflows:
- `Examples.yml` — `Pkg.test()` of every package under `examples/` (one job each, Ubuntu) against this checkout, plus the Pluto notebook `examples/pluto/hello.jl` run headlessly; a new example package must be added to its matrix.
- `OfflineTests.yml` — the whole suite with `CARGO_NET_OFFLINE=true` after fetching only the declared crates (`test/fixtures/offline_prefetch/Cargo.toml`) into an empty `CARGO_HOME`, no caches (#259); a test that needs a new registry crate must be added there.
- `NetworkIntegration.yml` — weekly (and `workflow_dispatch`) run with the network test flags on, three OSes, `continue-on-error`, not a required check.
- `PublishCrates.yml` — after a green `CI` **push** run on `main`, `scripts/publish_rust_crates.sh` publishes whichever of the three crates.io crates is not published yet (`release` environment secret).
- `Documenter.yml`, `TagBot.yml`, `CompatHelper.yml` — docs deploy, release tags, compat bumps.

**Why the 4-thread job exists.** Three guarantees are only *exercised* with more than one thread, and their testsets skip themselves when `Threads.nthreads() < 2`, so without this job they would never run anywhere: (1) the panic channel is a thread-local — the rule that the wrapper `ccall` and the channel-read `ccall` happen on one thread with no yield point between them (#244) is invisible single-threaded; (2) `load_artifact!` racing two tasks on the same path (#277); (3) finalizers running on a thread other than the allocating one (#249). Keep the skip guards and this job together: a new thread-sensitive test must skip below 2 threads *and* be covered by the 4-thread job.

**Job names are load-bearing.** The repository ruleset for `main` lists `Julia 1 - ubuntu-latest - x64`, `Julia 1 - windows-latest - x64` and `Julia 1 - macos-latest - aarch64` as required status checks. The single-threaded jobs must keep exactly those names (the matrix `suffix` is empty for them); renaming them leaves the required checks unreported and blocks every merge. Add new variants with a suffix (` - 4 threads`) instead of renaming.

## Known Pitfalls

- **String interpolation**: `"$var[i]"` interpolates only `var`, not `var[i]`. Always use `"$(var[i])"` for complex expressions. CI lint checks for this pattern.
- **Julia type aliases**: `Cvoid === Nothing` and `Cstring === Ptr{UInt8}`. Defining methods for both causes "method overwritten" warnings. Define for the canonical type only.
- **Platform-dependent types**: `Clong`/`Culong` size varies by OS and architecture.

## Conventions

- 4-space indentation, no tabs
- `CamelCase` for modules/types; `snake_case` for functions/variables
- Extend existing modules rather than introducing parallel pipelines
- Keep generated/binding code deterministic and cache-aware
- Add tests alongside new functionality; include regression coverage for macro/parsing changes
- **Minimal exports**: Only macros (`@rust`, `@rust_str`, `@irust`, `@irust_str`, `@rust_crate`, `@register_ffi_struct`) are exported. All other identifiers should be accessed via `RustCall.XXX` or `using RustCall: XXX`. Do not add new `export` statements unless the identifier is a macro intended for end-user use.

## Git Workflow

- Do not commit directly to `main` or `master`
- Create a topic branch for any implementation or documentation change
- Push the topic branch and open a draft PR for review-oriented sharing
- If work is accidentally committed on `main`, move it onto a topic branch and reset local `main` back to `origin/main`

## Pull Request Workflow

Every change goes through this loop; the definition of done is the issue's acceptance criteria, not "the cause is gone".

1. **Open a draft PR** from a topic branch off `origin/main`. Commit in logical steps, each leaving `Pkg.test()` green. Commit messages and the PR body carry the attribution trailers the session was given.
2. **Request review the moment a push lands**: comment `@codex review` right after every push (the first one and each fix), without waiting for CI — CI and Codex run in parallel. Codex does **not** re-review on its own in this repository; a push without a fresh request gets no review. Keep the branch quiet until the round is answered, then fix, push, request again.
3. **Monitor per head SHA**: CI results (`gh pr checks`) and Codex reviews are tracked against the current head; a green result on an older SHA means nothing.
4. **Answer every finding**: fix real ones (with a regression test), reply on the thread with the fixing SHA, resolve the thread. Never resolve a thread you did not act on.
5. **Scope decision**: when findings converge on one class that a tech-debt issue solves structurally, fix the current round, post a "scope decision" comment naming that issue, stop re-requesting review, and merge on green. Record the deferred items on the issue.
6. **`Closes #N` only when every acceptance criterion of #N has a named test** (list criterion → test in the PR body). Otherwise write `Advances #N` and list what remains. A tech-debt fix removes the *class* of bug; the bug issue's concrete deliverables still need their own work.
7. **Merge**: squash, subject `<PR title> (#PR)`, after CI is green, no unresolved threads, and the scope decision (if any) is recorded. Then pull `main` and rebase any open PR that overlaps.

Practical rules that CI enforces or that have bitten before:

- Docstrings in `src/*.jl` must not use `(@ref)` links to internal bindings — the Documentation job fails. Plain backticks.
- `test/runtests.jl` auto-discovers `test_*.jl`; never add an `include`.
- Rebuild the extractor with `julia --project deps/build.jl` (writes `rustcall-extract.identity.toml` beside it, #409) and export `RUSTCALL_EXTRACT` before running Julia tests; a stale binary is rejected by the manifest schema check, and a binary from a raw `cargo build` has no record and is identified by its bytes (the fingerprint then moves on every rebuild).
- Golden corpus: run the plain `cargo test` in `deps/rustcall_julia_core` first — a golden failure is the signal that the extractor's output changed. Only when that change is intended, regenerate with `UPDATE_GOLDEN=1 cargo test` (it overwrites without comparing) and review `git diff tests/corpus` before committing.
- Run every `scripts/lint_*.sh src` locally; they are all CI jobs.
- On Windows a loaded DLL cannot be deleted or overwritten: tests unload libraries before removing temp trees and clean up best-effort; hot reload opens a fresh generation path per rebuild.
- Finalizers must never take `REGISTRY_LOCK`, `dlsym`, or log; they use pointers captured at construction. Enforced by `test/test_finalizers.jl` from #277 Phase B (PR #289) onward; older finalizers in `src/types.jl` / `src/crate_bindings.jl` are migrated there.
- The API reference is split into `docs/src/reference/*.md` (#288), each page filtered by source file, under Documenter's default 200 KiB limit with a 150 KiB warning (`docs/make.jl`). A reference page that warns is split further, never the limit raised; a docstring in a new `src/` file needs its file added to a page's `Pages` filter.
- Verify tests pass before every commit; never commit red.
