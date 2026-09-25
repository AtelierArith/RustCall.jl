# Changelog

All notable changes to RustCall.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.2] - 2026-09-26

### Breaking
- **Regenerate every file written by `write_bindings_to_file` under an
  earlier RustCall.** The bindings format is still `0.7`, so a file written by
  v0.7.1 passes `check_bindings_format`, but its `__init__` refuses to load
  with a `RustError` that says the build environment changed since the
  library was compiled and names the variable `<Rust toolchain>`.
  The file records the `toolchain_fingerprint()` it was built under, which
  folds in the source digest of `rustcall_julia_core`, and this release
  changes those sources (the entries below), so the digest moved
  (`79c40787…` in v0.7.1, `8f4209e2…` now) and the module's `__init__` check
  (`_warn_if_build_env_changed(...; strict = true)`) refuses the library it
  was built with. The message suggests `Pkg.precompile(; force = true)`,
  which does not help a written file. Run `write_bindings_to_file` again with
  this RustCall. Nothing else in a v0.7.1-written file breaks: with only the
  recorded fingerprint changed to the current one, a `sample_crate` file
  written by v0.7.1 loads under v0.7.2, and its functions, constructors,
  methods, field properties, `Result` / `Option` returns, caught panics and
  finalizers behave exactly as under v0.7.1. `@rust_crate` modules and
  `rust"""` blocks are rebuilt as usual; a cache written by v0.7.1 only misses.
- **A trait impl's `#[julia]` method exports a symbol that carries its
  trait** ([#506](https://github.com/AtelierArith/RustCall.jl/issues/506)).
  `#[julia] impl tr::Far for Buf { #[julia] fn m }` exported
  `rustcall_Buf_m`, the symbol an inherent `Buf::m` exports, so an inherent
  method and a trait's of one name, or two traits' methods of one name,
  defined one `#[no_mangle]` symbol twice. Every per-method name now hangs
  off one method stem (`rustcall_julia_core::codegen::method_stem`): the
  method's name for an inherent method, the trait's name, length-prefixed,
  ahead of it for a trait's. So the symbol is now `rustcall_Buf_3Far_m`, and
  its string buffers (`Buf_3Far_m_…`) and `CResult_` / `COption_` aggregates
  are named the same way. No identifier starts with a digit, so the stem
  never equals an inherent name. Inherent methods' symbols are unchanged. A
  hand-written `@rust rustcall_Buf_m(..)` call that reached a trait method
  must use the new name; `@rust_crate` bindings read symbols from the manifest.
  The proc macro exports different symbols, and `rustcall_julia_core` gains
  public API (`codegen::method_stem`, `Method.julia_name`), so the next
  publish of the Rust crates is a minor bump, to 0.4.0.
- **An item whose Rust name Julia reserves is bound with a trailing
  underscore** ([#514](https://github.com/AtelierArith/RustCall.jl/issues/514)).
  A `#[julia]` function, method, field, struct or module named `function`,
  `end`, `quote`, `begin`, ... — or any Rust keyword as a raw identifier
  (`r#for`, `r#let`) — was bound under that name: `rust"""` and `@rust_crate`
  defined a binding reachable only as `var"function"` (a raw name kept its
  `r#`, so `var"r#for"`), a file written by `write_bindings_to_file` did not
  parse, and a module of such a name was refused. One function,
  `RustCall.julia_binding_name`, now decides the Julia name of every item
  kind in every emitter: the `r#` is dropped and a name Julia reserves gets a
  `_` (`for_`, `end_`, `let_`; a field's accessors are `get_let_` /
  `set_let_!`). The set of reserved names is Julia's own (a name
  `Meta.parse` does not read as a plain identifier). `@rust` finds a function
  under the same name: the generic registry and the name → symbol table are
  keyed by it (`@rust for_(x)` for a generic `fn r#for<T>`), while
  specialization keeps the Rust path. Code that reached such a binding through
  `var"..."` must use the new name. Exported symbols do not change.

### Fixed
- **A stale `write_bindings_to_file` module names the remedy that works**
  ([#531](https://github.com/AtelierArith/RustCall.jl/issues/531)). When the
  build environment a generated crate module recorded no longer matches — a
  changed `RUSTFLAGS`, Cargo configuration or toolchain, or a RustCall whose
  extractor sources moved (a file written by v0.7.1 loaded by a later
  release) — `__init__` refused with a message telling the user to run
  `Pkg.precompile(; force = true)`. That rebuilds a `@rust_crate` module, but a
  file written by `write_bindings_to_file` records the environment in its own
  source, so re-precompiling read the same record and failed again. The
  message now comes from one function, `RustCall._build_env_changed_message`,
  given the module's origin, and a written file is told to be regenerated with
  `write_bindings_to_file` (the call is spelled out, with the crate's path as
  a Julia string literal). The in-memory `@rust_crate` module passes
  `origin = :rust_crate`; a written file keeps making the origin-less call
  every 0.7.x makes, which is read as a written file's. So the fix reaches files
  v0.7.1 wrote, and a file written now still loads under v0.7.0 / v0.7.1
  (PR #532 review). `test/test_build_env_remedy.jl` checks both emitters and a
  v0.7.1-spelled file against a recorded toolchain that no longer matches.
  **A written file makes only calls the oldest release of its format line
  accepts**: `test/fixtures/bindings_surface_0.7.0.txt` records every name
  v0.7.0 defines with each method's positional arity and keywords
  (`test/record_bindings_surface.jl`), and the #528 option sweep checks every
  `RustCall` reference of every file it emits against it
  (`test/bindings_surface.jl`), so a keyword or helper a later patch adds
  cannot reach a written file.
- **A crate item named like something the generated code uses no longer
  replaces it** ([#528](https://github.com/AtelierArith/RustCall.jl/issues/528)).
  Generated modules spelled `Base.show`, `getfield(x, :ptr)`, `RustCall.StateView`,
  `PythonCall.Py`, `Int32`, `nothing`, ... by their plain names, and the crate's
  items are bound in the same module. A `#[pyclass] struct Base` made a PyO3
  host module fail with `FieldError: type DataType has no field getproperty`; a
  `#[julia] fn getfield` or `fn nothing` broke every wrapper that called it; a
  `#[julia] fn Int32` added a method to Base's `Int32` constructor; and
  `@rust_crate` refused a struct or module named `Base`, `Core`, `RustCall`,
  `Libdl`, any Base export or a prelude helper, from lists kept for that. The
  emitted code now reaches everything outside its own module through a name no
  Rust identifier can spell: the expression emitters (`@rust_crate`, the PyO3
  host, and the argument plans `rust"""` shares) write their templates with
  `RustCall.@_emitted`, which turns every free name of Base, Core and RustCall
  into a `GlobalRef` when RustCall is loaded, and a file written by
  `write_bindings_to_file` binds `import Base as rustcall′Base` and
  `import RustCall as rustcall′RustCall` once per module and goes through them
  (U+2032 is a Julia identifier character and never a Rust one). Every
  function a generated module defines is declared its own
  (`function Int32 end`) before its methods. The lists are gone: an item may
  take any of those names, and only the module's own definitions — its
  helpers and constants (#463), and the `eval` / `include` Julia defines in
  every module — are refused. `rust"""` was already hygienic; the one name its
  expansion took from the caller, the `Vararg` lowering spells for an
  `args...` closure, is now RustCall's. `test/test_module_name_shadowing.jl`
  lowers the output of every emitter, under a covering set of every
  combination of its keyword options (read off the emitter's method, so a new
  option fails the test until it is swept; any three options' values occur
  together), and requires each free global a Rust identifier could spell to be
  one of that module's own definitions. That sweep found the written file's
  `relative_lib_path` spelling `joinpath(@__DIR__, ...)` bare, which a crate's
  `fn joinpath` took over; it goes through the alias too. A
  written file no longer imports `RustCall`'s helpers under their names;
  regenerate an older file to get the fix.
- **A Rust parameter named like a name its wrapper uses no longer breaks the
  wrapper** ([#526](https://github.com/AtelierArith/RustCall.jl/issues/526)).
  A generated wrapper's parameters are named after the Rust ones, and its
  body calls names of its own without qualification. So
  `#[julia] fn echo(pointer: &str)` made the `@rust_crate` and
  `write_bindings_to_file` wrapper call its own argument (`objects of type
  String are not callable`), a method parameter `getfield` did the same to
  `getfield(self, :ptr)`, and a PyO3 host method `fn m(&self, obj: i32)` gave
  its wrapper two parameters named `obj`, which Julia refuses to define; so
  did `Int64: i64` beside the `Int64(x)` the wrapper converts through, and a
  generic struct's type variable (`G<obj_>` with `obj: obj_`). No list of
  such names can be complete, so every emitter now names its parameters
  against its own output (`RustCall._rename_parameters`): it emits its items
  once with a unique placeholder for each parameter (nothing logged, nothing
  recorded for a boundary report) — a name no Rust identifier can spell
  (`rustcall′arg′1`: the prime is a Julia identifier character and no
  `XID_Continue` one), recognised by identity against the set the probe made,
  so a crate's `struct __rustcall_arg_1__` or parameter of that name is an
  ordinary name and never taken for one (PR #527 review) — collects every other name of each
  definition taking one — what it reads, calls or binds, its other
  parameters, its type variables — and gives the parameter a name outside
  that set through the one allocator, `RustCall.julia_parameter_names`
  (`pointer_`, `obj_`, `Int64_`). `rust"""`, both `@rust_crate` emitters
  (the source text parsed) and the PyO3 host do this. `test/test_parameter_names.jl`
  checks every emitter: a corpus whose parameter is spelled like any name its
  definitions use must emit, up to the parameter's final name, exactly what
  the same corpus emits with an unused spelling.
  Every name an emitter binds itself inside a definition it generates is in
  that namespace too (PR #527 review): the receiver (`rustcall′self`), the
  pointer / panic-channel / payload locals (`rustcall′func_ptr`,
  `rustcall′c_result`, ...), the string and callback temporaries
  (`rustcall′str′<param>`, `rustcall′cb′frame`, formerly
  `__rustcall_str_<param>`), a struct constructor's arguments, the
  `getproperty` / `setproperty!` / `show` locals and the PyO3 host's
  (`rustcall′obj`, `rustcall′p`, ...). A crate item and a wrapper's local are
  therefore disjoint by construction — a `struct __rustcall_str_s` whose
  constructor takes `s: &str` used to have its type shadowed by the string
  temporary — and a parameter spelled like a former local (`func_ptr`,
  `c_result`) keeps its name. `test/test_parameter_names.jl` checks every
  emitter: no definition that takes a parameter or is defined on a crate type
  binds a name a Rust identifier can spell.
  The probe emits with exactly the options the emission uses (PR #527
  review): the emission's strictness — `write_bindings_to_file(...; strict)`
  is scoped over both crate emitters (`RustCall._ffi_strict()`, which every
  contract decision's default now reads, `FFI_STRICT[]` outside an emission),
  so the expression half no longer runs at the global setting — and
  collecting mode only when the emission collects. A refusal it raises is the
  emission's own and propagates; there is no longer a fallback that left every
  item of a module unrenamed. The probe logs nothing and does not use up a
  `:warn` signature's one warning.
- **A PyO3 host property declared through `#[getter]` / `#[setter]` methods is
  read under its Julia name** ([#524](https://github.com/AtelierArith/RustCall.jl/issues/524)).
  `#[getter] fn r#for(&self)` is the Python attribute `for`, but
  `pyo3_host = true` bindings remapped only declared fields, so `obj.for_`
  was sent to Python as `for_` and raised `AttributeError`; such a property
  was also missing from `propertynames` and from the name-clash check. The
  host now reads one list of bound properties
  (`RustCall._pyo3_host_bound_properties`): every exposed field and every
  accessor method, merged by the Python attribute, each under
  `julia_binding_name` of that attribute (`for_`, `end_`). That one list
  drives the remapping, `propertynames`, `getproperty` / `setproperty!` (a
  getter types the read as a field's Rust type does; a property with no
  setter raises `ArgumentError`) and the clash definitions, so a
  `#[getter] fn r#for` beside a `#[pyo3(get)] for_` field is refused with
  both items named. A field renamed with `#[pyo3(get, name = "...")]` is now
  a property under that name too. The extractor records a getter's or
  setter's property in the manifest's `python_name` — the attribute's name,
  or the method's without `r#` and without a `get_` / `set_` prefix, PyO3's
  rule — so the PyO3 wrapper crate's Python-owned accessor helpers look up
  the same attribute (a `#[getter] fn get_x` read `get_x` there, not `x`).
  **Every PyO3 host value now crosses by what it is at run time, never by
  the Rust spelling of its position** (PR #525 review). The generated module
  defines two conversions every binding, getter and setter goes through:
  `_pyo3_to_python` hands Python a class handle's Python object, a Julia
  array of numbers as a `numpy.ndarray` when numpy imports (pyo3-numpy
  extracts from nothing else, and PyO3 reads a `Vec` from one as from any
  sequence), another array or a tuple element by element, and anything else
  as it is (`nothing` is `None`); `_pyo3_from_python` reads `None` back as
  `nothing` and an object as the Julia handle of the most derived of the
  module's classes in its type's MRO (a table built once from the class
  objects), so a `#[pyclass(extends = ...)]` object stays itself and an
  instance of a Python-defined subclass of a `#[pyclass(subclass)]` is its
  nearest bound base.
  So a type alias of a class handle (`type Handle = Py<Point>`), an optional
  one, a bare `Option` beside a glob of a module whose `Option` is private,
  a crate's own `Option` (by path or shadowing the bare name), `Py<Self>`,
  `Option<Py<PyAny>>`, a `Vec` of class objects returned, and every setter
  of these are called as a Python caller would call them; before, each of
  them depended on reading the type, and a misread handed PyO3 a
  `juliacall` wrapper or returned a raw `Py`. Arguments are untyped (Python
  checks them). The extractor still describes each position
  (`py_shape` / `py_return`, `rustcall_julia_core::manifest::PyShape`,
  additive within schema 0.7), read off the spelling with no path
  resolution — a primitive, `String` / `&str`, `Vec` / `Option` bare or
  under a std root, a pyo3-numpy array by its name, `Python` / `PyModule`
  as interpreter-supplied, else opaque — and it is a hint only: it types
  what the value conversion left (`i32` is `Int32`, a numpy return a
  `Vector{Float64}`, a `PyResult` the `RustResult`'s parameter), and a value
  that does not fit it stays the Python object it is. The one thing the host
  takes from it is which arguments the interpreter supplies, by PyO3's own
  rule (a type whose last segment is `Python`). The Julia-side spelling
  parsers (class, numpy, injected-argument and value-type readers) are gone,
  and a manifest from an extractor that predates the field is refused with
  the instruction to rebuild it.
  An identifier-form property name
  (`#[getter(r#type)]`) is unrawed like every Rust name (`type`); a string
  `name = "..."` is taken as written. And
  a name the generated module or type defines for itself — the handle field
  `_rustcall_py`, `_pyo3_module`, `_PYO3_MODULE`, `_pyo3_to_python`,
  `_pyo3_from_python`, `_PyO3Object`, the imports — is part of the
  one-namespace clash check: a crate item bound under
  one (a `#[getter] fn _rustcall_py`, a `#[pyfunction] fn _pyo3_module`) is
  refused with both named instead of shadowing the handle or redefining the
  module's import function. The reserved names are read off the prelude the
  emitter emits (`_pyo3_host_prelude_exprs`), not listed.
- **`rustcall_julia_core::codegen::method_symbol` spells a raw method name as
  the exported symbol** (PR #517 review). `method_symbol(&[], "S", "r#match")`
  returned `rustcall_S_r#match`; the wrapper exports `rustcall_S_match`. It
  now goes through `method_stem`, and every public name helper of `codegen`
  (`method_symbol_of`, `struct_free_symbol`, `method_string_owner`, the field
  accessor symbols, `panic_symbol`, `generic_method_wrapper_name`) drops an
  `r#` it is handed. A core test calls each with raw names and checks that
  the list it calls is every such helper in `codegen.rs`. No symbol the
  generators emit changes.
- **`@rust f(x)` reaches the caller's own block first, whatever the form**
  ([#520](https://github.com/AtelierArith/RustCall.jl/issues/520)). The
  typed `@rust f(x)::T` tried every loaded library's exports before the
  generic registry, and the untyped `@rust f(x)` asked the generic registry
  first — a registry keyed by the bare name, process-wide. So an unrelated
  block's plain `f` shadowed a module's own generic `f` under `::T`, and that
  generic captured another module's untyped `@rust f(x)`; two modules' generics
  of one name shared the last registration. One function,
  `RustCall.resolve_rust_call`, now decides for every form (typed or untyped,
  generic or not, `lib::f` or not): the caller's own blocks first, most
  recently run first, each asked for an exported function and a generic of
  that name together — so a later block of the module redefines the name
  whichever kind it is — then the process-wide generic of that name, then
  another block's export. A block's generics are owned by its
  library (`RustCall.GENERIC_FUNCTIONS_BY_LIB`, dropped with it) as well as
  registered by bare name, which `call_generic_function(name, ...)` still reads.
  A library's generics are installed in the same transaction as its symbol
  mappings and return-type hints (`install_library_metadata!`), so a block
  re-registered or reloaded while calls run is never visible without its own
  generics. A precompiled block rebound to a reloaded library name moves its
  key and its order in one transaction, and the resolver reads both in one.
  A generated method wrapper calls its exported symbol (`rustcall_S_m`)
  directly (`_rust_call_symbol`) and never through this name resolution, so a
  generic free function whose Julia name equals that symbol cannot capture
  the method.
- **Two modules' generic structs of one name are each their own**
  ([#522](https://github.com/AtelierArith/RustCall.jl/issues/522)). A generic
  `#[julia]` struct's wrappers (`Boxed_new`, `Boxed_tag`, `Boxed_free`, ...)
  were registered by that bare name and grouped by the struct's name alone,
  so a second module's `Boxed` replaced the first's registration, and
  constructing the first module's `Boxed` built — and called — the second
  module's source. The members are now owned by the library of the block
  that defines them (`GenericFunctionInfo.owner`, rows in
  `RustCall.GENERIC_FUNCTIONS_BY_LIB`, dropped with the library), a group is
  one owner's members, and the generated constructor, methods, accessors and
  destructor read them from the library of the block that emitted the struct
  (found by the block's recorded content, so a reload that renames the
  library is followed) — not by `@rust` name resolution, so a later block's
  ordinary export of a member's name does not take them either. A member and
  its whole group are read as one snapshot in one transaction
  (`RustCall.GenericStructSnapshot`) and the instantiation uses only that, so
  an unload racing a call can never leave a constructor-only group; a known
  owner whose rows are gone is retried and then refused, never answered by
  another module's registration of the name. A struct's group rows are
  installed with the rest of its library's metadata, in the one transaction
  that publishes the library. The same rule now holds for `@rust f(x)`: when
  one of the caller's own blocks is found unloaded after it was restored, the
  call restores it again (up to three times) or raises, and never falls
  through to another module's generic of the same name
  (`RustCall._resolve_own_definition`, shared by both lookups). Whether one
  of the caller's blocks defines the name is decided from one snapshot of
  their loaded state, generation and rows (`RustCall._own_definition_snapshot`),
  so an unload and a restore between two separate reads cannot make it look
  both missing and loaded. A
  hand-registered, ungrouped generic constructor keeps finding its separately
  registered `_free`. An instantiation's cache key is unchanged (the source,
  the bindings, the compiler and the struct's name, never the owner), so two
  same-named structs share an instantiation only when their sources are the
  same.
- **A return type that only ends in the impl header's name is not the struct**
  ([#518](https://github.com/AtelierArith/RustCall.jl/issues/518)). Whether
  a method returns its own type (and so is boxed as `*mut Struct`, and may be
  a constructor) compared only the last path segment of the return type with
  the header's. So in an inline block with `use super::Gauge as Meter; impl
  Meter { fn raw(&self) -> other::Meter }`, where `other::Meter` is some
  other type, `raw` was boxed as a `Gauge` and the block did not compile. A
  return type is now the struct when it is `Self` or spelled exactly as the
  header spells it (`codegen::returns_own_type`, both flavours). In a
  `rust"""` block it is also the struct when the header's own path resolver
  (`paths::names_struct`, the `locate` of the header without its glob and
  unique-name fallbacks) resolves it to the struct, e.g. `-> super::Gauge`,
  `-> crate::Gauge`, or `-> ::Gauge` (a block is compiled as edition 2015,
  where a leading `::` is the crate root, the rule `paths::edition_type_qualifier`
  now gives every resolution of a written type path). The proc macro sees one block and cannot resolve a
  name, so in a `#[julia]` crate only `Self` or the header's spelling is
  boxed. There, `-> crate::Gauge` inside `impl Gauge` is now read as a plain
  by-value return, which Julia refuses; write `Self`. Exported symbols are
  unchanged. `rustcall_julia_core` gains public API
  (`MethodModel::returns_own_type_resolved`,
  `StructModel::attach_impl_resolving`, `paths::names_struct`) and
  `types::is_self_type` no longer matches a path that only ends in the name.
- **A `#[julia]` argument named like a Julia keyword no longer breaks a
  written bindings file** ([#516](https://github.com/AtelierArith/RustCall.jl/issues/516)).
  `fn f(end: i32)` or `fn g(r#for: &str)` gave the generated wrapper a
  parameter spelled `end` / `r#for`, so the file `write_bindings_to_file`
  wrote did not parse. One function, `RustCall.julia_parameter_names`,
  applied by the `RustFunctionSignature` / `RustMethod` constructors, now
  names every generated parameter for every emitter (`rust"""`, both crate
  emitters, the PyO3 host): the name `julia_binding_name` gives (`end_`,
  `for_`), further underscores where another parameter already has that name
  (`end` beside `end_` is `end__`), and `arg<i>` for a pattern or `_`, which
  had no readable name at all. Wrappers are called positionally, so no call
  changes.
- **A callback argument followed by another argument loads from a written
  bindings file** ([#516](https://github.com/AtelierArith/RustCall.jl/issues/516)).
  The source-text emitter printed each call argument on its own, and a lone
  `Base.@cfunction` prints in its space-separated form, which inside the call
  swallowed the arguments after it; the file failed to load with "could not
  evaluate cfunction argument type". The argument list is now printed as one
  call, which parenthesizes the macro.
- **A keyword renamed onto a taken name is refused, not bound twice**
  ([#514](https://github.com/AtelierArith/RustCall.jl/issues/514)). `fn r#for`
  beside `fn for_`, a field `r#let` beside `let_`, a method `r#end` beside
  `end_`, `struct r#while` beside `fn while_` or `mod r#do` beside `mod do_`
  would be bound under one Julia name; the layout checks (`rust"""`,
  `@rust_crate`, `write_bindings_to_file`) compare the names
  `julia_binding_name` returns and refuse the block or crate with both items
  named. The check runs over what each emitter defines at the top level of a
  module (`julia_definitions`, and `_pyo3_host_definitions` for the PyO3 host):
  a constructor, the bare form of a static method, a field accessor and a
  submodule count as definitions like any other. So it also catches a PyO3-host
  static method beside a `#[pyfunction]` of its Julia name, and a crate method
  `get_x` beside a field `x`. A module has one namespace: a method of one
  struct bound under another struct's type name is refused in either emission
  order. #341 had allowed the order in which it became a method of the type.
  The PyO3 host bindings are generated from the scan of the build's own
  configuration, as the `#[julia]` path already was, so `#[cfg]`-exclusive
  variants of one item are not reported as a clash. A property is remapped to
  its Python attribute only for a field the host binds.
- **A raw `#[pyclass]` name is recognised as the class in argument and return
  position** ([#514](https://github.com/AtelierArith/RustCall.jl/issues/514)).
  The PyO3 host keyed its class map by the manifest spelling `r#type`, while a
  type spelling (`PyRef<'_, r#type>`) was looked up by `type`. Every
  Julia-side lookup, key or composed name of a manifest name now goes through
  `rust_name`, and a source test keeps emitters from keying or binding a raw
  name.
- **A raw struct or field name no longer breaks the crate scan**
  ([#514](https://github.com/AtelierArith/RustCall.jl/issues/514)).
  `#[julia] pub struct r#for` made `rustcall-extract` panic (it built
  `rustcall_r#for_new` as an identifier), and a raw field `r#let` was
  described with the accessors `S_get_r#let` / `S_set_r#let`, which nothing
  exports; the manifest now names `S_get_let` / `S_set_let`, the symbols the
  proc macro has always exported.
- **One unraw rule on the Rust side, one namespace for `@rust`**
  ([#514](https://github.com/AtelierArith/RustCall.jl/issues/514)).
  `rustcall_julia_core::codegen::unraw` is the one place a Rust item's name
  loses its `r#`. Every symbol and helper identifier is built through it
  (`symbol_stem`, `method_stem`, `source_ident` build on it), and a source test
  (`tests/raw_names.rs::no_identifier_is_built_from_a_raw_name`) refuses a
  `format_ident!` / `Ident::new` that reads an item name without it. This
  fixes a Python-owned PyO3 class with a raw method or field, whose wrapper
  crate generation panicked. A hand-written `#[no_mangle] extern "C" fn r#for`
  is recorded with its native symbol `for`. The name-clash check of a
  `rust"""` block also covers `@rust`'s name table (`_registry_signatures`,
  hand-written exports included), so a raw export beside a `#[julia] fn` of
  its Julia name is refused instead of one replacing the other.
- **A raw name is unrawed wherever it is spelled**
  ([#514](https://github.com/AtelierArith/RustCall.jl/issues/514)). A raw
  method of a generic inline struct (`impl<T> Boxed<T> { fn r#match }`) got a
  generic wrapper named `Boxed_r#match`, which is not an identifier, so the
  block failed to expand; it is now `Boxed_match`. A PyO3 item with a raw name
  (`#[pyfunction] fn r#for`, a raw `#[pyclass]`, method or field) is recorded
  with the `python_name` PyO3 exposes it under (`for`), so the PyO3 host
  bindings and the wrapper crate look up the attribute Python has; a raw
  `#[pyclass]` no longer panics the scan, and a raw field's wrapper-crate
  accessors are `rustcall_<C>_get_<f>` without the `r#`. A raw
  `#[pymethods]` method's symbol hangs off the method stem as a `#[julia]`
  method's does (`rustcall_<C>_match`, not `rustcall_<C>_r#match`, which the
  wrapper crate could not spell, so `@rust_crate` dropped the method). The PyO3 host
  bindings run the same Julia-name clash check as every other emitter.
- **`@rust_crate` binds the `#[julia]` methods of a trait impl**
  ([#506](https://github.com/AtelierArith/RustCall.jl/issues/506)). The crate
  scan skipped trait impls, so the methods the proc macro wrapped were neither
  described nor bound. They are now in the manifest with their `trait_path`
  and symbol, and both crate emitters (`@rust_crate` and
  `write_bindings_to_file`) bind them. A trait method keeps its name unless
  another method of the struct has the same name. Then the inherent method
  keeps the name and each trait's is bound as `<Trait>_<name>` (`Far_m`). That
  name is decided once by the scan and carried as `Method.julia_name`
  (additive within manifest schema 0.7). A trait's `Self`-returning function
  is bound under its name, not as a second constructor. Whether a method
  returns a boxed struct (and is a constructor) is read from its return type
  alone, never its name, in both flavours: a `fn new() -> i32` returns an
  `i32` (it used to be boxed as `*mut Struct`, which did not compile). The scan refuses a
  crate where two traits ending in one name wrap a method of one name (a
  duplicate symbol), or where a qualified name is already taken.
  `boundary_report` examines every such method. A trait impl of a type
  without `#[julia]` is still left alone; one through a `type` alias fails the
  scan with the alias named instead of being dropped silently.
- **A method's receiver is read in one place, for inherent and trait methods
  alike** ([#509](https://github.com/AtelierArith/RustCall.jl/issues/509)).
  `self: &mut Self` (and `self: &mut Buf`, `self: &mut &mut Self`) used to be
  bound as `&Buf`, because only the `&mut self` shorthand was read as
  mutable, so the wrapper failed to compile inside generated code (a trait
  impl's was refused). `rustcall_julia_core::receiver::Receiver` now reads
  every receiver as reference layers over `Self` or the impl header's own
  spelling of the type, and the wrapper's `*const` / `*mut` pointer, its
  binding, its call and the manifest's `is_mutable` all come from it, in both
  flavours and in a generic struct's wrappers. Every method is now called by
  path — `<Buf>::m(self_obj, ..)` for an inherent method, as
  `<Buf as tr::Far>::m(..)` already was for a trait impl's (#497) — so the
  call no longer depends on method-call autoref. A receiver the syntax cannot
  resolve — a type alias, `Box<Self>`, `Rc<Self>`, `Arc<Self>`,
  `Pin<&mut Self>`, the type spelled otherwise than the header — is refused at
  the receiver for an **inherent** method too, in both flavours (it failed
  inside generated code before, except an alias of `&Self`, which happened to
  compile), and the refusal kind is now `receiver_type` (was
  `trait_receiver`, trait impls only; a v0.7.1 manifest carrying
  `trait_receiver` is still read as refused). `mut self` (a copy) is no longer
  reported as `is_mutable`. Exported symbols are unchanged. A PyO3 method with
  a receiver other than `&self` / `&mut self` is skipped as `receiver_type`,
  since a wrapper spelled from the manifest can express only those.
  `rustcall_julia_core`'s public API changed (`MethodModel`'s `is_static` /
  `is_mutable` fields are methods, `skip_reason::TRAIT_RECEIVER` is
  `RECEIVER_TYPE`), so the next publish of the Rust crates is a minor bump,
  to 0.4.0.

### Rust crates
- **`rustcall_julia_core`, `rustcall_julia_macros_impl` and
  `rustcall_julia_macros` are `0.4.0`**. The published `0.3.0` (v0.7.1)
  exports items that #511 removed and structs that #513 and #525 gave new
  public fields, and #513 changes the symbol `#[julia]` exports for a trait
  impl's method, so for a `0.x` crate set this is a minor bump; each crate
  still pins the one below it exactly (`version = "=0.4.0"`), and a `#[julia]`
  crate depending on the release writes `rustcall_julia_macros = "0.4"`. The
  bump moves no cache key: the crates' `[package] version` and the exact
  requirements stay out of every artifact identity, and the extractor's source
  digest (`8f4209e2…`) and `toolchain_fingerprint()` are the same before and
  after it.
  - Removed from `rustcall_julia_core` (#511): the public fields
    `model::MethodModel::{is_static, is_mutable}`; they are methods of the
    same names now, read from the method's `receiver()`.
  - Changed in `rustcall_julia_core`: new public fields on public structs, so
    a struct literal of them no longer compiles without the field —
    `manifest::Method::julia_name` (#513), `manifest::Arg::py_shape`,
    `manifest::Field::py_shape`, `manifest::Function::py_return`,
    `manifest::Method::py_return` (#525), and
    `model::MethodModel::returns_own_type_resolved` (#519).
    `codegen::method_symbol` and every public symbol helper of `codegen` drop
    an `r#` they are handed (#525), and a trait impl's method symbol carries
    the trait (`rustcall_Buf_3Far_m`, #513).
  - Added to `rustcall_julia_core`: the `receiver` module (`Receiver`,
    `Layer`, `Receiver::{of, reference, is_single_reference, is_static,
    is_mutable, is_readable}`), `MethodModel::receiver`,
    `manifest::skip_reason::{RECEIVER_TYPE, LEGACY_CODEGEN_REFUSALS}` (#511);
    `codegen::{method_stem, trait_name_of, returns_own_type}`,
    `manifest::Method::{julia_name, method_stem}`,
    `MethodModel::{method_stem, returns_boxed_struct, is_constructor}` (#513);
    `codegen::{unraw, source_ident}` (#515); `model::attach_impl_resolving`,
    `paths::{edition_type_qualifier, names_struct}` (#519);
    `manifest::PyShape` (`kind`, `name`, `rank`, `inner`; `of`, `named`,
    `wrapping`) (#525).

## [0.7.1] - 2026-09-24

### Changed
- **Every refusal of the `#[julia]` codegen reaches the boundary report**
  ([#503](https://github.com/AtelierArith/RustCall.jl/issues/503)). The
  decision to refuse an item is made in one place,
  `rustcall_julia_core::refusal`, and both the `compile_error!` and the
  manifest are derived from it: a refused item stays in the manifest with a
  `skip_reason` from `skip_reason::CODEGEN_REFUSALS` — `unsafe_fn` (#491) and
  now `generic_signature`, `impl_trait`, `non_ffi_payload`,
  `self_trait_path`, `unspellable_self`, `lowered_str_borrow`,
  `lowered_str_lifetime`, and `trait_receiver` for the trait-impl receiver
  refusal of #497 below (additive within manifest schema 0.7, as is
  `Method.trait_path`, which keeps a refused trait-impl method apart from a
  same-named inherent one). A generic
  method of an inline struct, a crate's generic `#[julia]` function, struct or
  impl block, a `Self` inside a macro, a lowered `&str` whose lifetime the
  wrapper cannot honour, and the refused `#[julia]` methods of a crate trait
  impl are no longer missing from the manifest or unmarked in it:
  `boundary_report` / `inline_boundary_report` list each at its
  `"entry point"`, Julia binds nothing for it, and it takes no name and claims
  no symbol. A refused item is now kept as written next to its refusal (an
  `unsafe fn` and a function with a non-FFI payload used to be dropped), and a
  non-FFI payload's diagnostic points at the payload type. `#[julia]` on a
  file module, on an impl header that is not a type path, or on any other item
  kind (enum, `macro_rules!`, `use`, ... — decided exhaustively over `syn::Item`) now
  fails the crate scan and a `rust"""` expansion with the refusal's own message. `rustcall_julia_core`'s
  public API changed (`extract::function_entry` takes a `Mode`;
  `codegen::unsafe_function_error`, `method_skip_reason`,
  `inline_method_is_generic`, `inline_method_is_wrapped` and
  `method_is_unsafe` are replaced by `refusal::*`), so the Rust crates take a
  minor bump to 0.3.0 (see Rust crates below).

### Fixed
- **A `#[julia]` method of a trait impl is called through the trait**
  ([#497](https://github.com/AtelierArith/RustCall.jl/issues/497)). The
  proc-macro wrapper of `#[julia] impl tr::Far for Buf { #[julia] fn m(&self) }`
  called `self_obj.m()`, which failed with E0599 inside generated code when
  the trait was not in scope under a bare name, and silently called an
  inherent `Buf::m` instead of the trait's when one existed. It now calls
  `<Buf as tr::Far>::m(self_obj)` (static methods `<Buf as tr::Far>::m()`),
  spelled as the impl header spells the type and the trait. The receiver
  argument follows the receiver's declared type (`self: &&Self` is passed
  `&self_obj`), since a path call applies no autoref. A typed receiver whose
  shape is not literal reference layers over `Self` — a type alias, `Box<Self>`,
  `Rc<Self>`, `Pin<&mut Self>`, the type's own name — and `self: &mut Self`
  (#509) are refused at the receiver with a `compile_error!`; none of them
  compiled before either. Exported symbols
  are unchanged. The inline `rust"""` flavour wraps no trait-impl method and is
  unaffected. A wrapper now lowers such a method differently, so the published
  Rust crates take a minor bump to 0.3.0 (see Rust crates below).
- **Two artifacts whose short ids collide never share an output location**
  ([#504](https://github.com/AtelierArith/RustCall.jl/issues/504),
  [#507](https://github.com/AtelierArith/RustCall.jl/pull/507)). Since #495
  (#486) Windows' path limit makes a 16-hex short id name some locations: a
  crate's Cargo target directory, the PyO3 wrapper's Cargo package, the PyO3
  host extension's cache directory and a debug build's files. Two full keys
  sharing that prefix could reach the same location, and two concurrent PyO3
  wrapper builds could copy out each other's library and cache it under the
  wrong key. Each such name is now spelled and owned in one place
  (`src/short_name.jl`): a persistent location is claimed for good by an
  `O_EXCL` owner record holding the full key and a colliding key is refused,
  a build holds the name's lock from build start through copy-out, and a
  location with contents but no owner record (for example a `pyo3-host/<short>`
  directory written by an earlier RustCall) is emptied when it is RustCall's
  own rebuildable output, or refused, and never adopted. On a file system
  without locking, emptying is refused too and the error names the path to
  remove. `scripts/lint_artifact_identity.sh` rejects any other use of a short
  id as a path. Cache keys are unchanged.

### Rust crates
- **`rustcall_julia_core`, `rustcall_julia_macros_impl` and
  `rustcall_julia_macros` are `0.3.0`**. The published `0.2.0` (#500) exports
  items that #503 removed or changed, and #497 lowers a trait-impl method
  differently, so for a `0.x` crate set this is a minor bump; each crate still
  pins the one below it exactly (`version = "=0.3.0"`), and a `#[julia]` crate
  depending on the release writes `rustcall_julia_macros = "0.3"`. The bump
  moves no cache key: the crates' `[package] version` and the exact
  requirements stay out of every artifact identity, and the extractor's source
  digest and `toolchain_fingerprint()` are the same before and after it.
  - Removed from `rustcall_julia_core` (#503):
    `codegen::unsafe_function_error`, `codegen::method_skip_reason`,
    `codegen::method_is_unsafe`, `codegen::inline_method_is_generic`,
    `codegen::inline_method_is_wrapped`; their decisions are made by
    `refusal::function_refusal` / `refusal::method_refusal`, and a
    `Refusal`'s `skip_reason()` / `compile_error()` replace the strings and
    tokens they returned.
  - Changed in `rustcall_julia_core` (#503): `extract::function_entry` takes
    the extraction `Mode` in place of `wrapped: bool`;
    `manifest::Method` has a new public field `trait_path: String`, so a
    struct literal of it no longer compiles without the field;
    `codegen::payload_is_representable` is now a re-export of
    `refusal::payload_is_representable` (same signature).
  - Added to `rustcall_julia_core` (#503): the `refusal` module (`Refusal`
    with public fields `kind`, `detail`, `span`, `end`, `message` and methods
    `skip_reason`, `compile_error`; `MethodSite`; `function_refusal`,
    `method_refusal`, `struct_refusal`, `impl_refusal`,
    `impl_header_refusal`, `module_refusal`, `item_kind_refusal`,
    `julia_item_refusal`, `attribute_target_refusal`,
    `unsupported_item_kind`, `item_attrs`, `without_julia_attr`,
    `payload_is_representable`; the kinds `IMPL_NOT_A_PATH`, `FILE_MODULE`,
    `UNSUPPORTED_ITEM`), `codegen::transform_unsupported_item`,
    `manifest::skip_reason::{GENERIC_SIGNATURE, IMPL_TRAIT, NON_FFI_PAYLOAD,
    SELF_TRAIT_PATH, UNSPELLABLE_SELF, LOWERED_STR_BORROW,
    LOWERED_STR_LIFETIME, TRAIT_RECEIVER, CODEGEN_REFUSALS,
    is_codegen_refusal}`, `model::MethodModel::{trait_path, is_same_method}`,
    `paths::ImplHeader::of_any`.
  - Changed in what `#[julia]` generates: a `#[julia]` method of a trait impl
    is called through the trait (`<Buf as tr::Far>::m(self_obj)`), and a
    typed receiver that is not literal reference layers over `Self`, or
    `self: &mut Self`, is refused with a spanned compile error (#497, #509);
    `#[julia]` on a file module, on an impl whose header is not a type path,
    or on any other item kind (enum, `macro_rules!`, `use`, ...) is refused
    with the refusal's own message, and a non-FFI payload's diagnostic points
    at the payload type (#503). Exported symbols are unchanged.

## [0.7.0] - 2026-09-24

### Added
- **`RustCall.check_toolchain()` and boundary-report notes**
  ([#490](https://github.com/AtelierArith/RustCall.jl/issues/490), [#496](https://github.com/AtelierArith/RustCall.jl/pull/496)). `check_toolchain()` (not exported)
  reports the `rustc` / `cargo` RustToolChain resolves, compares `rustc`
  with the supported floor (`rust-version = "1.85"`, now declared in
  `deps/rustcall_extract/Cargo.toml`, so Cargo refuses an older compiler
  before building), and checks the extractor's path, schema and identity. It
  builds nothing and raises nothing. `boundary_report` /
  `inline_boundary_report` now also return `notes`: a raw-pointer return or
  payload, and a hand-written `#[no_mangle]` export that `@rust` calls with no
  generated panic boundary. A note is not a finding.
- **A hot reload guide** ([#465](https://github.com/AtelierArith/RustCall.jl/issues/465), [#472](https://github.com/AtelierArith/RustCall.jl/pull/472)):
  `docs/src/hot_reload.md` names the supported doors, which library and which
  build a reload uses, and what is refused, with runnable examples. The
  generics guide's manual monomorphization examples now run as doctests
  ([#467](https://github.com/AtelierArith/RustCall.jl/pull/467)).

### Changed
- **The bindings format follows the release's semver**
  ([#489](https://github.com/AtelierArith/RustCall.jl/issues/489)).
  `RustCall.BINDINGS_FORMAT_VERSION` is no longer an integer bumped on its own
  (it went 12 → 13 while the package went 0.6.3 → 0.6.6): it is the
  `MAJOR.MINOR` of `Project.toml`, read when the package is loaded — the same
  identifier as the manifest schema. A file written by `write_bindings_to_file`
  carries `# Bindings format: <MAJOR.MINOR>` and checks it when included
  (`RustCall.check_bindings_format`) and again in its `__init__`: a RustCall of
  the same `MAJOR.MINOR` loads it whatever the patch, a different minor or
  major refuses it with a message to regenerate the file. A bindings-format
  change therefore ships only in a minor or major release. **Files of the old
  integer format (13 and below, written by RustCall v0.6.6 and earlier) are no
  longer readable** and are refused with the same message: regenerate them with
  `RustCall.write_bindings_to_file`.
- **The boundary report is derived from the wrapper generators**
  ([#454](https://github.com/AtelierArith/RustCall.jl/issues/454)).
  `RustCall.boundary_report` and `inline_boundary_report` (#441) no longer
  re-read the manifest with their own copy of generation's rules — each review
  round of #450 had found one the report did not yet mirror. They run the
  emitters `rust"""` and `@rust_crate` run, in a collecting mode where every
  argument and return position a generator decides is recorded and a refusal
  is a finding instead of an error, so a rule added to generation is in the
  report by construction. The output is unchanged for every case the tests of
  #450 cover.
- **The manifest schema identifier is `0.7`**. As for every minor release,
  `rustcall_julia_core::manifest::SCHEMA_VERSION` follows `Project.toml`'s
  `MAJOR.MINOR`, so the extractor's source digest moves once and every cached
  artifact is rebuilt on first use; an installed extractor from v0.6.x is
  refused until `Pkg.build("RustCall")` rebuilds it. Bindings files written by
  v0.6.x must be regenerated (#489 above).
- **A hot reload rebuilds only from the module's build record**
  ([#474](https://github.com/AtelierArith/RustCall.jl/issues/474), [#473](https://github.com/AtelierArith/RustCall.jl/issues/473), [#478](https://github.com/AtelierArith/RustCall.jl/pull/478)). A generated crate module
  carries one `RustCall.CrateBuildRecord` (crate, library name, profile,
  features, kind, build environment, Cargo configuration, toolchain, Python)
  in place of the loose `_BUILD_OPTIONS` / `_CRATE_DIR` / ... constants, and
  checks it in `__init__` in both the in-memory and the written form. The
  module form of `enable_hot_reload_for_crate` reads its inputs only from the
  record and refuses a disagreeing keyword with an `ArgumentError`; the path
  form requires a `cdylib`. A reload whose rescan fails now fails like a
  failed build — `trigger_reload` returns `false`, the callback gets the
  error, and the previous image stays current.
- **Each crate build takes one environment snapshot**
  ([#481](https://github.com/AtelierArith/RustCall.jl/issues/481), [#485](https://github.com/AtelierArith/RustCall.jl/pull/485), [#494](https://github.com/AtelierArith/RustCall.jl/pull/494)). `@rust_crate`,
  `write_bindings_to_file`, the PyO3 host path and hot reload read `ENV`,
  `PATH` and the Python interpreter once, at the start of the build; the
  probe, the build, the record and the cache key all come from that snapshot,
  so a concurrent change to `ENV` cannot pair one environment's library with
  another's record. An interpreter replaced in place during a build is
  refused, and the PyO3 wrapper's record is taken from its verified plan.
- **A generic method of an inline `#[julia]` struct is refused at compile
  time** ([#471](https://github.com/AtelierArith/RustCall.jl/issues/471), [#476](https://github.com/AtelierArith/RustCall.jl/pull/476), [#477](https://github.com/AtelierArith/RustCall.jl/issues/477), [#480](https://github.com/AtelierArith/RustCall.jl/pull/480)). A
  `pub fn f<T>` on a concrete struct, or a method with type parameters of its
  own on a generic struct, used to load and fail when called (or not compile
  at all); the block now stops with one spanned diagnostic naming the method
  and the alternatives. Lifetime-only methods are still wrapped. The
  `#[julia]` proc macro likewise refuses generic items ([#470](https://github.com/AtelierArith/RustCall.jl/pull/470)).
- **Generated wrappers return `MaybeUninit<T>`** ([#462](https://github.com/AtelierArith/RustCall.jl/issues/462),
  [#470](https://github.com/AtelierArith/RustCall.jl/pull/470)): the panic sentinel is `MaybeUninit::zeroed()` instead of
  `mem::zeroed::<T>()`, so a panic under a `&T`, `Box<T>`, `NonZero*` or
  function-pointer return no longer aborts the process. The C signature Julia
  calls is unchanged; Rust code calling a generated wrapper directly now calls
  `.assume_init()`. Wrappers of generic inline structs are module-qualified
  through `symbol_stem` (`geo__QualPt_new`), recorded in the manifest as
  `Method.generic_wrapper_name`.
- **Every `@rust_crate` flavour builds outside the crate tree**
  ([#486](https://github.com/AtelierArith/RustCall.jl/issues/486), [#495](https://github.com/AtelierArith/RustCall.jl/pull/495)). The direct `cdylib` build and its cfg
  probe, the PyO3 host extension (which wrote `<crate>/target`) and the PyO3
  wrapper crate with its probes (under `<crate>/target/rustcall-pyo3-*`) all
  build in one per-crate directory of RustCall's cache,
  `RustCall.crate_target_directory(crate, flavour)`, so a crate in a
  read-only tree (an installed package) binds with every flavour. The PyO3
  wrapper and probes still run in the crate's Cargo context
  (`.cargo/config.toml` is discovered), and the crate's lockfile is copied by
  contents. No flavour passes `--locked`: a read-only crate must ship a
  current `Cargo.lock`. The rule per flavour is in the integration and hot
  reload guides. The directory is named by the key's short id, with the full
  key recorded inside and claimed by an exclusive create, so Cargo's nested
  paths stay within Windows' `MAX_PATH`; a colliding crate is refused, never
  shared.

### Removed
- **Dead code** ([#463](https://github.com/AtelierArith/RustCall.jl/issues/463), [#475](https://github.com/AtelierArith/RustCall.jl/pull/475), [#479](https://github.com/AtelierArith/RustCall.jl/pull/479)), among it
  the untyped `rust_box_drop` export of `rustcall_helpers` (unused since
  #468) and the unused `pub` items `paths::imports_in`,
  `types::is_bare_ident` and `CfgSet::is_lenient` of `rustcall_julia_core`.
  Stale docs were corrected and the oversized reference pages split.

### Fixed
- **An inline `#[julia]` struct's instance method returning `Self` no longer
  fails at expansion**
  ([#454](https://github.com/AtelierArith/RustCall.jl/issues/454)).
  `rust"""` resolved the `Self` spelling through the return contract before
  deciding the result was a boxed handle, so every `fn twin(&self) -> Self`
  was refused with "the FFI contract cannot describe the return type" while
  the report of #450 skipped it as a handle. The handle is bound to the
  generation that allocated it, as a constructor's is, and `Self` is not
  looked up.
- **Seven FFI boundary defects** ([#460](https://github.com/AtelierArith/RustCall.jl/issues/460), [#468](https://github.com/AtelierArith/RustCall.jl/pull/468)): an
  inline struct setter converts to the field's type (`obj.x = 1` on an `f64`
  field stores `1.0`); a callback slot with no frame or a mistyped return
  records an error instead of raising through Rust; an owned `String` result
  is released when a callback's exception is re-raised; `CompilationError`
  display no longer throws on non-ASCII text; every `rustc` invocation keeps
  RustToolChain's whole command; `RustBox` of an unsupported `T` never drops
  through an untyped helper; specialization records are published through a
  unique temporary file.
- **`@rust_crate` and build paths** ([#461](https://github.com/AtelierArith/RustCall.jl/issues/461), [#469](https://github.com/AtelierArith/RustCall.jl/pull/469)):
  `write_bindings_to_file` on a crate without a `cdylib` keeps its library;
  the wrapper crate names the crate by its `[lib] name`;
  `enable_hot_reload_for_crate` registers under the name `@rust_crate` uses
  and rebuilds like it (RustToolChain's `cargo`, `crate_target_directory`);
  builds no longer `cd` the process; the PyO3 host key includes the build
  environment; `RUSTCALL_OFFLINE` reaches every Cargo call; written bindings
  import `Libdl` through RustCall.
- **Codegen soundness** ([#462](https://github.com/AtelierArith/RustCall.jl/issues/462), [#470](https://github.com/AtelierArith/RustCall.jl/pull/470)): a struct's `#[cfg]`
  and a field's own `#[cfg]` now gate every helper generated for them, and
  `CResult_*` / `COption_*` names are claimed against user items.
- **A wrapper declares the item's whole environment**
  ([#482](https://github.com/AtelierArith/RustCall.jl/issues/482), [#483](https://github.com/AtelierArith/RustCall.jl/pull/483), [#492](https://github.com/AtelierArith/RustCall.jl/pull/492), [#480](https://github.com/AtelierArith/RustCall.jl/pull/480)). Named
  lifetimes on struct-reference arguments, `impl<'x>` blocks, `where`
  predicates naming `Self` (in types and in expression paths such as
  `[(); Self::N]`), and `-> Self::Assoc` in a trait impl used to fail with
  E0261 / E0411 inside generated code; `Self` is now spelled as the impl
  type. A lowered `&str` whose lifetime must outlive the call, and a `Self`
  inside a macro invocation, are refused with a spanned diagnostic.
- **An elided return lifetime is named on the wrapper**
  ([#484](https://github.com/AtelierArith/RustCall.jl/issues/484), [#498](https://github.com/AtelierArith/RustCall.jl/pull/498)). `fn get(&self) -> &i32` and the like
  failed with E0106 in the wrapper; the wrapper now spells out the lifetime
  elision picks on the item. A return that would borrow a lowered `&str`
  argument is refused at the argument. Under the default `FFI_STRICT` a `&T`
  return is still refused by the FFI contract, as a named one always was.
- **A `#[julia]` `unsafe fn` or `unsafe` method is refused at the item and
  listed by the boundary report** ([#491](https://github.com/AtelierArith/RustCall.jl/issues/491), [#501](https://github.com/AtelierArith/RustCall.jl/pull/501)). An
  `unsafe` method of a `#[julia]` struct used to get a wrapper that failed
  with E0133 inside generated code; it is now refused with a spanned,
  `#[cfg]`-gated `compile_error!`, as an `unsafe fn` already was. The manifest
  marks both with `skip_reason = "unsafe_fn"`, every Julia emitter binds no
  wrapper for them, and `boundary_report` / `inline_boundary_report` list
  them as a finding at the item's `"entry point"` with the reason.

### Rust crates
- **`rustcall_julia_core`, `rustcall_julia_macros_impl` and
  `rustcall_julia_macros` are `0.2.0`**
  ([#487](https://github.com/AtelierArith/RustCall.jl/issues/487)). The
  published `0.1.0` (from #451) exported items that have since been removed
  or changed, so for a `0.x` crate set this is a minor bump; each crate still
  pins the one below it exactly (`version = "=0.2.0"`), and a `#[julia]` crate
  depending on the release writes `rustcall_julia_macros = "0.2"`. The bump
  moves no cache key: the crates' `[package] version` and the exact
  requirements stay out of every artifact identity, and the extractor's source
  digest and `toolchain_fingerprint()` are the same before and after it.
  - Removed from `rustcall_julia_core` (#475):
    `cfg::CfgSet::is_lenient`, `paths::imports_in`, `types::is_bare_ident`.
  - Removed from `rustcall_julia_core` (#479):
    `claims::scanned_function_claims`, `codegen::function_uses_strings`,
    `manifest::Function::claimed_symbols`,
    `manifest::Method::declares_owned_string`,
    `manifest::Struct::claimed_symbols`, `model::collect_struct_models`,
    `model::collect_struct_models_in`.
  - Changed in `rustcall_julia_core`:
    `codegen::inline_generic_wrappers` takes the struct's module path
    (`(model, module_path)`, #470); `manifest::Method` has a new public field
    `generic_wrapper_name` (#470); `model::MethodModel` has a new public field
    `host: Option<ImplHost>` and `model::ImplHost` is new (#483). A struct
    literal of either no longer compiles without the field.
  - Added to `rustcall_julia_core`: the `environment` module (#483; its
    items are crate-private, so it adds no callable API),
    `claims::aggregate_name`, `codegen::generic_method_wrapper_name`,
    `codegen::inline_generic_method_refusals`,
    `codegen::inline_method_is_generic` (#470, #476, #480),
    `model::StructModel::field_cfg_attrs` (#470).
  - Changed in what `#[julia]` generates: a plain return is
    `MaybeUninit<T>` in the wrapper (same C ABI; the panic sentinel is sound
    for any `T`, #470); a wrapper declares the wrapped item's lifetime
    parameters and `where` clause, with `Self` spelled as the impl type
    (#480, #483), in expression paths and const arguments as well as types
    (`[(); Self::N]` becomes `[(); <Buf>::N]`, #492); an elided return
    lifetime is named on the wrapper by Rust's elision rules instead of being
    copied as written, which failed with E0106 in generated code (#498); and
    `#[julia]` refuses, with a spanned compile error, a generic function,
    method or struct item it used to accept (#470), a lowered `&str` argument
    whose lifetime the wrapper cannot instantiate (#483), a `Self` inside a
    macro invocation (#483, #492), and an elided return that would borrow a
    lowered `&str` argument (#498).

## [0.6.6] - 2026-09-22

### Changed
- **The Rust crates carry a version of their own, and `rustcall_core` is
  `rustcall_julia_core`**
  ([#451](https://github.com/AtelierArith/RustCall.jl/pull/451)).
  `rustcall_julia_core`, `rustcall_julia_macros_impl` and `rustcall_julia_macros`
  share one semver, `0.1.0` to start, independent of `Project.toml`, so they
  can be published on crates.io — each pins the one below it exactly
  (`version = "=0.1.0"`), so Cargo can never pair one version's facade with
  another's proc macro; a `#[julia]` crate writes
  `rustcall_julia_macros = "0.1"` (or the `path` it uses today) and the other
  two are transitive. `rustcall_extract` is not published and keeps the
  package's version. The manifest identifier is unchanged in kind:
  `rustcall_julia_core::manifest::SCHEMA_VERSION` is a literal kept equal to
  the release's `MAJOR.MINOR` and checked by `test/test_schema_version.jl`,
  not derived from any crate version. A coordinated bump of the three crates
  moves no cache key: their `[package] version` and the `version` requirement
  each puts on the sibling it takes by path both leave the artifact identity.
  The rename itself moves the extractor's source digest once, so every
  cached artifact is rebuilt on first use after this release.
  `.github/workflows/PublishCrates.yml` publishes whichever of the three is
  not on crates.io yet after a green `CI` push run of this repository's
  `main` (a manual dispatch is accepted only from `main`), through
  `scripts/publish_rust_crates.sh`: idempotent, dependency-ordered, with a
  `--dry-run` that runs `cargo publish --dry-run` where Cargo can and names
  what it cannot check, and an index probe that tells an unreachable
  crates.io from an unpublished version rather than guess.

### Fixed
- **A `#[julia]` struct holding a `Vec` or another struct binds as a handle**
  ([#453](https://github.com/AtelierArith/RustCall.jl/issues/453)). A field
  of type `Vec<T>` (either flavour, `pub` or not) or a struct held by value
  (inline) got a generated getter whose type the FFI contract cannot describe,
  so binding the whole struct failed with "cannot describe the return type of
  `Bag::items -> Vec<i32>`". A field now gets a getter and a setter exactly
  when its value crosses `extern "C"` on its own — a primitive, a raw pointer,
  a `String`, or a generic struct's own type parameter — decided by one
  predicate that the manifest, the proc macro and the inline generator share.
  Every other field gets none, so the struct is an opaque handle that Julia
  reaches through its methods.

## [0.6.5] - 2026-09-22

### Fixed
- **The first PyO3 host call no longer compiles RustCall's scan and cache
  code** ([#449](https://github.com/AtelierArith/RustCall.jl/issues/449)).
  With the extension module already cached, the first `pyo3_host_import` — and
  the first call of any `@rust_crate ... pyo3_host=true` binding — spent most
  of a second compiling `scan_crate`, `compute_crate_hash` and the cache
  lookup, and a downstream package could neither `precompile` it (the path is
  reached through dynamic dispatch) nor execute it while precompiling (it needs
  an interpreter). RustCall's own precompilation now runs that interpreter-free
  half against a throwaway crate, with no `rustc`, `cargo` or Python started
  and nothing left in the state it serialises; `RustCallPyO3HostExt`
  precompiles the import. Measured on Julia 1.13 the first host call went from
  5.7 s to 0.6 s with a warm cache, and `using RustCall` from ~210 ms to
  ~105 ms, because the registry directives are now derived from the containers
  rather than listed by hand (one had drifted). The hook is also split:
  `RustCall.pyo3_host_import(artifact::PyO3Extension)` imports what
  `build_pyo3_extension` built, so a package can run the interpreter-free build
  in its `__init__` or a `deps/build.jl` and keep only the import lazy. The
  interpreter's `EXT_SUFFIX` and fingerprint are read in one Python start
  instead of two, and `pyo3_host_import(artifact)` checks both, plus the
  fingerprint, against the running interpreter before importing. The
  fingerprint now ends with `platform.machine()` (a universal macOS Python
  reports the same everything else under arm64 and under Rosetta), so every
  PyO3 artifact key moves once and is rebuilt on first use.

## [0.6.4] - 2026-09-22

### Added
- **A boundary report of the FFI surface**
  ([#441](https://github.com/AtelierArith/RustCall.jl/issues/441), #450).
  `RustCall.boundary_report(crate_path)` and
  `RustCall.inline_boundary_report(source)` read the extractor's manifest
  without building or loading anything. No Cargo runs: a crate's target
  configuration comes from `rustc --print cfg`. They list every position of
  the generated wrappers that the FFI contract cannot describe: arguments,
  returns, `Result` / `Option` payloads, and the getters of readable fields.
  Callback arguments are checked through `ffi_callback_plan` and against the
  callback-slot limit. Each entry names the module-qualified item, the
  position, the Rust type and the reason, and the result can be asserted in a
  test (`isempty(report.unsupported)`). Until now, an unsupported argument (a
  `Vec<f64>`, a `&OtherStruct`) compiled and failed only when called, with a
  message about the Julia value's layout. Examined: `#[julia]` functions and
  the wrapped methods and fields of non-generic `#[julia]` structs. The
  integration guide points its debugging workflow and troubleshooting
  checklist at the report.

### Known issues
- A **private** field whose type is a `Vec<T>` or a bare struct name still gets
  a generated getter, and binding the struct fails
  ([#453](https://github.com/AtelierArith/RustCall.jl/issues/453)). The
  boundary report lists such a field as an unsupported `field getter`. The
  integration guide gives the workaround: box the state (`inner: Box<Inner>`).

## [0.6.3] - 2026-09-22

### Added
- **A safe Rust/Julia integration guide**
  ([#441](https://github.com/AtelierArith/RustCall.jl/issues/441), #442):
  `docs/src/integration_guide.md` recommends a Rust-side facade that exposes
  only simple FFI types and opaque, Rust-owned handles. It covers ownership and
  lifetime rules, the FFI type surface, callbacks, panic boundaries, build and
  CI practice, and a layer-by-layer debugging workflow.
- **A runnable safe-integration example, `examples/SafeLedger.jl`**
  ([#441](https://github.com/AtelierArith/RustCall.jl/issues/441), #444): a
  facade crate with one opaque `#[julia]` struct, bound with `@rust_crate`,
  behind a Julia API with typed errors and explicit release. Its tests
  (construction, normal use, the error path, release, unload) run in the
  Examples workflow and in RustCall's own suite as
  `test/test_integration_example.jl`. The guide gains a walkthrough of it, a
  limitation matrix, a troubleshooting checklist, and cache-warming, lockfile
  and toolchain guidance for CI.

### Fixed
- **An inline `#[julia]` struct's constructor and static methods resolve
  through their own module**
  ([#443](https://github.com/AtelierArith/RustCall.jl/issues/443), #446).
  They used the session's last-compiled library (`get_current_library()`). So
  in a precompiled package whose first Rust call was a constructor they failed
  with "No Rust library loaded", and after another module compiled a block
  defining the same struct they called that module's code. They now go through
  `module_symbol_library(@__MODULE__, symbol)`, like free `#[julia]` functions:
  it restores the module's recorded blocks first. The block records their
  wrapper symbols as its own.
- **A `cdylib` crate bound with `@rust_crate` is built without writing into
  it** ([#445](https://github.com/AtelierArith/RustCall.jl/issues/445), #447).
  The direct build and its `--print cfg` probe ran Cargo with the crate's own
  `target/`, so a package installed into a read-only depot could not
  precompile its facade, and a CI cache of RustCall's cache did not carry the
  dependency build. Both now use `RustCall.crate_target_directory(crate)`, one
  directory per crate under RustCall's Cargo cache, named by the full
  `artifact_key` of the crate's canonical path. `clear_cargo_cache`,
  `get_cargo_cache_size` and `cleanup_old_cache` cover these directories;
  `cleanup_old_cache` ages them by a last-used stamp. Hot reload probes in
  `<crate>/target`, where it builds. `get_cache_size` tolerates entries that
  vanish mid-walk. Cargo still reads the crate's `Cargo.lock`, which a
  read-only package must ship.

## [0.6.2] - 2026-09-20

### Added
- **A probe-free Phase-1 mode for `scan_report`**
  ([#425](https://github.com/AtelierArith/RustCall.jl/issues/425)).
  `RustCall.scan_report(crate; resolve = false)` runs no Cargo at all: the plan
  is the declaration-only reading of `Cargo.toml` (`plan.resolved == false`),
  the scan is lenient, and `candidates` is empty. The default route's cfg probe
  compiles the crate's whole dependency graph as a wrapper dependency — minutes
  and hundreds of MB on a crate with large path dependencies — which this mode
  avoids for large crates, offline machines, and item inventories. A workspace
  member that inherits `version` / `edition` has both read from the workspace
  manifest, so the mode never falls back to `cargo metadata`.
  `generate = false` is orthogonal and does not avoid the probe.
- **The PyO3 Python-host path covers numpy arrays, declarative modules,
  classmethods, callables and async**
  ([#424](https://github.com/AtelierArith/RustCall.jl/issues/424)).
  A `pyo3-numpy` array argument is typed `AbstractArray` and converted with
  `numpy.asarray`, and a numpy return becomes a Julia array; items of a
  declarative `#[pymodule] mod` bind below the imported module and a nested
  module contributes its attribute path; a `#[classmethod]` drops its class
  argument and calls through the class object; a class's `propertynames` lists
  only the fields PyO3 exposes and a get-only field raises on assignment; a
  Python callable argument stays `Any`; an `async fn` is skipped, since the path
  has no event loop to drive the coroutine. `docs/src/pyo3.md` states the
  policies.
- **An example, `examples/Pyo3HostImport.jl`, binds two PyO3-only crates**
  ([#424](https://github.com/AtelierArith/RustCall.jl/issues/424),
  [#434](https://github.com/AtelierArith/RustCall.jl/issues/434)). It shows both
  front doors in one package: `@rust_crate ... pyo3_host=true` and
  `RustCall.pyo3_host_import` directly.

### Changed
- **`using RustCall` loads much faster.** `__init__`'s helper-library load wrote
  several `StateView`s through a closure specialised on each container type, so
  the first write of every registry was JIT-compiled at load time (measured at
  ~0.65 s of a ~0.86 s load). The closure is now a `@nospecialize`d callable and
  the path is replayed during precompilation, so a warm `using RustCall` falls to
  ~0.27 s ([#430](https://github.com/AtelierArith/RustCall.jl/issues/430)).

### Fixed
- **A one-argument `#[new]` no longer breaks package precompilation**
  ([#433](https://github.com/AtelierArith/RustCall.jl/issues/433)).
  A `#[new]` whose argument maps to untyped Julia `Any` (`Py<PyAny>`, a
  class-typed argument) emitted `Class(obj::Any)`, overwriting Julia's
  synthesized single-field constructor. Outside precompilation that is a
  warning; while precompiling a package it is an error, so a package using such
  a crate could not precompile. The host struct now declares an explicit inner
  constructor, and the emitted method is a new outer method.
- **The PyO3 shaped-project claim is atomic, with no grace window**
  ([#437](https://github.com/AtelierArith/RustCall.jl/issues/437)).
  A project's `<project>.lease` is now locked under a staging name and renamed
  into place *before* the directory is made, so a sweep never sees a project
  whose owner is still claiming it. The lock alone decides held versus free:
  the timing-based grace window, the age stamp, the lease retry/abort, the
  post-lock liveness re-check and the separate claimed-removal path are gone.
  A lease left by an owner that died between the claim and `mkdir` is swept.
  Windows and lockless volumes, which carry no lease, still decide by the
  machine-wide pid in the name.
- **An interrupted PyO3 cfg probe no longer leaves its project tree behind**
  ([#425](https://github.com/AtelierArith/RustCall.jl/issues/425)).
  A probe project carries a held `<project>.lease` for its lifetime, and the
  next project's creation sweeps the projects whose lease is free — never one a
  live process still holds, even when that process is in another pid namespace
  (a container sharing the target volume). A pre-#425 project with no lease
  falls back to its owner pid.
- **The Windows lease lock uses the file handle correctly.** `_get_osfhandle`
  returns a `WindowsRawSocket`, a primitive type that *is* the HANDLE, and has
  no `.handle` field; taking a lease on every shaped project made that branch
  run and exposed the crash.
- **Generation copies carry no lease on Windows.** A lease held for the life of
  the process is a file an active lock keeps `DeleteFile` from unlinking, which
  refused any test or rebuild that removed a temp tree holding a live copy. The
  machine-wide process table decides there instead (Windows has no pid
  namespaces), and the instance token already makes the copy name unique.

## [0.6.1] - 2026-09-17

### Fixed
- **The PyO3 host path handles PyO3's default arguments, and class-typed
  returns and arguments** ([#424](https://github.com/AtelierArith/RustCall.jl/issues/424)).
  A `#[pyo3(signature = (dim, tags = None, plev = 0))]` constructor is now one
  Julia method per arity, so `Index(2)` reaches PyO3's own dispatcher instead of
  falling through to the struct's inner constructor and failing to convert;
  a return or argument that spells a scanned `#[pyclass]` (`PyTensor`,
  `Py<PyTensor>`, `Bound<'_, PyTensor>`, `&Point`, `Vec<PyRef<'_, Point>>`) is
  that Julia struct rather than a raw `Py`, and a class argument is passed as
  the Python object the handle holds. Found while binding `tensor4all-py` end
  to end (private `#[pyclass]`es, `Python<'_>`, NumPy buffers, a Julia function
  as the TreeTCI `evaluate` callable).

## [0.6.0] - 2026-09-17

### Added
- **The PyO3 Python-host path**
  ([#424](https://github.com/AtelierArith/RustCall.jl/issues/424)).
  `@rust_crate ... pyo3_host=true` builds a PyO3 crate **as the Python
  extension it already is** — the `extension-module` build the link plan calls
  `:unlinkable` — imports it through PythonCall, and calls the imported module.
  That reaches what the C-ABI wrapper path refuses: a private `#[pyfunction]`
  (rustc E0603 to an outside crate), and `Python<'_>` / `Py<T>` / numpy /
  callable signatures that need a live interpreter. `PyResult<T>` stays
  `RustResult{T, String}`, now carrying the interpreter's own message instead
  of the opaque sentence the interpreter-free path can only produce. RustCall
  stays interpreter-free: the host lives in the `RustCallPyO3HostExt` package
  extension, loaded with PythonCall, and the crate is built (pinned to
  `PythonCall.python_executable_path()`) and imported lazily on first call.
  `load_crate_bindings` and `generate_bindings` take the same `pyo3_host`
  keyword.

### Fixed
- **The `CrateBindings` proxy no longer reserves `value` and `bindings`**
  ([#424](https://github.com/AtelierArith/RustCall.jl/issues/424)). Property
  access on the value `@rust_crate` returns forwards wholesale to the wrapped
  object, so a `#[pyclass]` with a field named `value` is readable and
  assignable through it (`B.Counter(...).value`); the proxy's own fields are
  `_`-prefixed and reached with `getfield`.

### Changed
- **The manifest schema identifier is now `0.6`** — the `MAJOR.MINOR` of this
  release (#372). A `rustcall-extract` built for `0.5` is refused with the
  rebuild message rather than read, so `Pkg.build("RustCall")` (or the build
  step that ships with the package) rebuilds it. The extractor is identified by
  its sources, so this is the only cache-key movement the release causes.

## [0.5.1] - 2026-09-17

### Fixed
- **Generation copies are owned by a lease, not by a pid**
  ([#321](https://github.com/AtelierArith/RustCall.jl/issues/321)). Two
  processes that share a library's volume and its hostname but run in
  different pid namespaces — two containers over one bind mount — could hold
  the same pid and generation counter, pick one copy path, and take each
  other's live copy for abandoned. The copy name now carries a per-process
  instance token (`<lib>.rustcall.<host>.<pid>.<instance>.<n>.<ext>`), and
  beside every copy the owner keeps `<copy>.lease` open and locked
  (`flock` / `LockFileEx`) for its whole life; the stale-copy sweep removes a
  copy only when it can lock that lease — no owner anywhere on the volume —
  and falls back to the process table only where there is no lease to ask.
  v0.5.x copies without a token are still swept by pid for one release.

## [0.5.0] - 2026-09-16

### Added
- **Callbacks: a Julia function can be passed to Rust as an `extern "C" fn`
  argument** ([#296](https://github.com/AtelierArith/RustCall.jl/issues/296)).
  `#[julia] fn apply(f: extern "C" fn(i64) -> i64, x: i64)` is driven by
  `apply(x -> 2x, 20)`, closures included. The manifest reports the pointer's
  signature (`Arg.abi = "callback"`, `callback_args`, `callback_return`; an
  additive column) and the wrapper builds the `@cfunction` from it, so Julia
  reads no Rust syntax; the FFI contract decides at wrapper generation which
  parameter and return types a callback may have (one-slot by-value and raw
  pointer types with slot = surface; `&str`, `String`, `char` and aggregates
  are refused with a `RustError` naming the argument). No closure
  `@cfunction` is involved — Rust gets a constant slot-function pointer and
  the Julia function rides in a task-local frame for the call, so this works
  on aarch64 too. Synchronous borrow, same-thread invocation, and a
  Julia exception that never unwinds through Rust: the trampoline stores it
  for the task and returns a sentinel, and the panic guard re-raises the
  same exception after the Rust call returns. Argument position only, not in
  generic functions. See `docs/src/type_contract.md`.

### Removed
- **The one-release compatibility fallbacks and deprecated entry points**
  ([#417](https://github.com/AtelierArith/RustCall.jl/issues/417)), all of
  which were announced with the release that made them redundant:
  - the pre-v0.4 helper library name (`deps/rust_helpers`, `librust_helpers`)
    as a lookup fallback and the `RUSTCALL_RUST_HELPERS` alias (#387): an
    installed tree built by v0.3.x is rebuilt once with `Pkg.build("RustCall")`;
  - `deps/rustcall_extract/build.rs` and `rustcall-extract source-digest`
    (#372 → #409): the extractor's identity is the record `deps/build.jl`
    writes beside the binary, and the binary reports nothing about itself.
    The digest algorithm is unchanged, but the extractor crate no longer has
    a build script, so the digest of a plain build moves — as every cache key
    does on a minor release anyway (the schema identifier is now `0.5`);
  - the `RUSTCALL_DLOPEN_GLOBAL` escape hatch (#250, #277 Phase B2): every
    policy is `RTLD_LOCAL | RTLD_NOW` with no override;
  - `call_rust_function_infer` (#276), which had only raised since 0.3.0;
  - the `@rust_crate_static` error stub;
  - the `#[julia_pyo3]` migration table in `docs/src/pyo3.md` (the attribute
    itself was removed in 0.3.0, #312); the table stays readable in the v0.4.2
    documentation.

## [0.4.2] - 2026-09-16

### Changed
- **The extractor's identity is decided by a closed rule, not by an
  enumeration of Cargo's build inputs**
  ([#413](https://github.com/AtelierArith/RustCall.jl/issues/413)). A source
  digest is claimed only for a *plain* build — nothing in the environment
  that Cargo or rustc would act on beyond where things are, which toolchain
  and how Cargo talks, and no discovered configuration file with a table
  beyond those kinds. v0.4.1 hashed each other input as it was found (flags,
  wrappers, the linker, response files, ...); now none is hashed and any of
  them makes the build non-canonical, identified by its bytes. The digest of
  a plain build is unchanged, so cache keys survive; a build under
  `RUSTFLAGS`, `RUSTC_WRAPPER` or a `[build]` table moves once, from a hashed
  identity to a bytes identity, and stays exact — only not stable across a
  patch release. `rust-toolchain` files are no longer an input: the compiler
  is not a source, and the same sources through any compiler emit the same
  manifest.

## [0.4.1] - 2026-09-16

### Changed
- **The extractor's identity comes from Cargo's view of its build, not from
  the binary's own report**
  ([#409](https://github.com/AtelierArith/RustCall.jl/issues/409)).
  `deps/build.jl` now computes the source digest right after building the
  extractor — the package set from `cargo tree`, the workspace from
  `cargo locate-project`, the configuration files Cargo discovered, the
  build-affecting environment and the bytes of every executable Cargo is
  told to run (`rustc`, its wrappers, the linker) — and stores it beside the
  binary keyed by the binary's SHA-256 (`rustcall-extract.identity.toml`).
  `extractor_source_digest` reads that record and trusts it only while the
  binary still matches; every other binary — one built under a source
  replacement, a `@file` response argument, an unresolvable executable, a
  foreign layout — is identified by its bytes. The digest is byte-compatible
  with what v0.4.0's `build.rs` embedded for this tree's layout, so the
  upgrade keeps every cache key; `build.rs` still embeds it as a cross-check
  the tests assert and is removed in v0.5. The class of "an input Cargo
  consults that the digest neither hashes nor declines" is closed
  structurally in v0.5.0 by
  [#413](https://github.com/AtelierArith/RustCall.jl/issues/413).

### Added
- Examples: `SampleCrate.jl` gains an inline `rust"""` block beside its
  generated bindings, and the new `RustCrateMacro.jl` puts all three front
  doors in one package — a `#[julia]` crate, `@rust_crate ... submodule=`
  generated at precompile time, and an inline `rust"""` block that composes
  the two ([#412](https://github.com/AtelierArith/RustCall.jl/pull/412)).

## [0.4.0] - 2026-09-15

### Added
- **`RustCall.release_generics(f[, types...]; close = false)` lets a session
  give instantiations back**
  ([#397](https://github.com/AtelierArith/RustCall.jl/issues/397)). Lazy
  instantiation maps one image per type, and nothing ever unmapped one: a
  long-running session touching many types kept every image for its lifetime,
  the third acceptance criterion of #254. Releasing is explicit because the
  implicit answer is not decidable — an instantiation hands out a raw function
  pointer, and a generic struct instantiation hands out objects holding a
  destructor pointer and the image's liveness flag (#291), so the registry
  cannot know when nothing refers to an image any more. It retires the images
  exactly as `unload_library` does: out of the registry, so the next call gets a
  fresh image (from the on-disk cache, without a rebuild), and still mapped, so a
  pointer or object holding the old one keeps working and finalizes through the
  image that allocated it; `close = true` closes them too, flipping the liveness
  flags first. Instantiations built together by `precompile_generics` share one
  library and are released together, and a generic struct group is released by
  naming any of its members. Each instantiation now records which generic owns
  it (`MONOMORPHIZATION_OWNERS`), which is what makes "every instantiation of
  `f`" answerable without being told the types. A release in two steps —
  retire now, `close = true` later once nothing holds the old images — works:
  the closing call also closes what an earlier non-closing release of the
  same generic left mapped.

### Changed
- **Breaking: the manifest schema identifier is the release's `MAJOR.MINOR`**
  ([#372](https://github.com/AtelierArith/RustCall.jl/issues/372)). Through
  v0.3.x the extractor's manifest carried an integer bumped on every manifest
  edit — thirteen times — kept in step by hand between `rustcall_core` and
  `src/manifest.jl`. It is now the release: `"0.4"` for every v0.4.x, derived on
  the Julia side from `Project.toml` and on the Rust side from the crate's own
  version, with `test/test_schema_version.jl` pinning the four manifest crates
  to the package version so the two cannot drift. A **patch** release therefore
  never invalidates an installed extractor or a cached artifact, and a
  **minor** release always does — every cache key folds the identifier in
  through `toolchain_fingerprint` — so a manifest may change shape freely inside
  a minor release and a change that must ship in a patch has to be additive. A
  pre-v0.4 extractor reports `13`, which never equals a release string; the
  refusal names the integer scheme, this release and `Pkg.build("RustCall")`.
  See `docs/src/project_guide.md`.
- **The documented requirements no longer ask for a Rust toolchain on `PATH`**
  ([#404](https://github.com/AtelierArith/RustCall.jl/issues/404)). RustCall
  depends on RustToolChain.jl, which uses the `rustc`/`cargo` on `PATH` when
  there is one and otherwise installs an isolated toolchain through Julia's
  Artifacts system, so a system Rust installation is optional (Windows still
  needs the MSVC build tools for linking). This is also why the prebuilt
  helper library once planned as `RustCallHelpers_jll` is withdrawn: the
  helpers compile with that toolchain on any machine.
- **Breaking: the ownership helper crate is `deps/rustcall_helpers`, and its
  library `librustcall_helpers`**
  ([#387](https://github.com/AtelierArith/RustCall.jl/issues/387)). Every Rust
  component RustCall owns was named `rustcall_*` except this one, which was still
  `rust_helpers` / `librust_helpers.{so,dylib}` / `rust_helpers.dll`. It now
  matches its siblings (`rustcall_core`, `rustcall_extract`,
  `rustcall_julia_macros`), the crate carries its `panic = "unwind"` pin (#244)
  across unchanged, and `helper_library_policy()` registers the image as
  `rustcall_helpers`. Three things follow for a deployment, since the file name
  is what it sees. **The override variable is `RUSTCALL_HELPERS`**;
  `RUSTCALL_RUST_HELPERS` is still honoured as a deprecated alias when the new
  one is unset, with a one-time warning naming the replacement. **A tree built
  by v0.3.x keeps loading**: the old file name is searched in every location
  the current one is, after all of them, so an installed package that has not
  been rebuilt since v0.3 still finds its `librust_helpers`, and a rebuild under
  the new name is always preferred — this fallback lasts one release and is
  removed in v0.5. And **nothing builds under the old name any more**:
  `native_product_filename(:rustcall_helpers)` names the new file, there is no
  `:rust_helpers` product, and `deps/build.jl` needed no change of its own
  because it asks `src/native_layout.jl` (#258). The prebuilt package once
  planned under this name, `RustCallHelpers_jll` (#404), is withdrawn — see
  the entry above: RustToolChain.jl already provides the toolchain that builds
  the helpers.

### Fixed
- **A crate module's generation record is published atomically**
  ([#402](https://github.com/AtelierArith/RustCall.jl/issues/402)). The record a
  generated `@rust_crate` module reads — handle, liveness flag and generation
  number — is deliberately one immutable value so that a reader can never pair
  one generation's handle with another's flag (#277, #291). It was kept in a
  `Base.RefValue{CrateGeneration}`, and `src/loadpolicy.jl` reasoned that
  because the record holds a `Ref{Bool}` it is not `isbits`, so the `RefValue`
  holds a *pointer* and publishing is a single store. That is wrong: Julia
  stores the struct inline, `sizeof(Base.RefValue{CrateGeneration})` is **24**,
  and publishing was a 24-byte write with nothing keeping it apart from a
  reader's 24-byte read. Measured with one writer alternating two records and
  one reader checking that the three fields came from the same one:
  **137129 torn reads out of 13211045**. No generated wrapper ever observed one
  — a module reaches the cell through a `StateView`, which takes the same lock
  the publisher writes under — so what was broken is the contract rather than
  any shipped call path: the type promised a lock-free read, the registration
  API hands out a bare cell so that a caller can have one, and the reload stress
  test reads exactly that way, which is how this was found. The record now lives
  in a `CrateGenerationCell` whose single field is `@atomic` and pointer-sized
  (`Union{Nothing, CrateGeneration}`; a bare `@atomic` field wider than a
  pointer falls back to a lock), so publishing is one store and reading is one
  load. It still behaves as a `Ref`, so no generated file changes and the
  bindings format is unchanged.

## [0.3.7] - 2026-09-14

### Fixed
- **Publishing a compiled library into the cache is atomic**
  ([#394](https://github.com/AtelierArith/RustCall.jl/issues/394)). The cache
  was written with `cp(src, dst; force = true)`, which unlinks the destination
  and then copies — and the copy of a multi-megabyte `.dylib` is not instant.
  Every cache key is the complete artifact identity, so two processes routinely
  want the same destination, and `CACHE_LOCK` cannot help because it is
  process-local. A process that had just looked the key up and found it could
  therefore lose it mid-read: `SystemError: opening file …/cache-v2/cargo/<key>.dylib`
  out of `include_dependency`, or `could not load library` out of `dlopen`. A
  reader polling one destination while twelve republications ran observed it
  **absent 1182 times and short 32971 times** out of 34615 observations. The
  symptom was the test suite, whose sixteen parallel workers share one cache
  directory — two runs minutes apart on the same tree died in two unrelated
  files — but any two Julia sessions building the same block at the same time
  could hit it. Publication now goes to a per-process temporary name in the same
  directory and the destination is then created as a **hard link** to it, which
  both publishes atomically — the name appears already pointing at the finished
  copy — and refuses an existing destination, so a second publisher gets
  `EEXIST` rather than replacing the first. A rename would not have been enough:
  it replaces, and two direct-`rustc` builds of one key come from different
  temporary directories and need not be byte-identical, so the loser could leave
  the winner's checksum describing bytes that are gone — which a concurrent
  verifier treats as corruption and deletes. An entry that already exists is
  therefore left strictly alone, and only the process that actually published
  writes the checksum (a later one fills in a *missing* checksum, computed from
  the cached file rather than from its own build). On a filesystem that rejects
  hard links — reachable, since `RUSTCALL_CACHE_DIR` points wherever it is told
  — the cache write fails and the caller carries on uncached, which every caller
  already does for a failed cache write: no cache is better than one that can
  delete its own entries.

## [0.3.6] - 2026-09-13

### Added
- **`RustCall.precompile_generics(f, types...)` builds a whole set of
  instantiations with one `rustc` invocation**
  ([#254](https://github.com/AtelierArith/RustCall.jl/issues/254)). Lazy
  instantiation cannot know which types are coming, so it compiles one library
  per type and maps one image per type. Passing the set up front —
  `RustCall.precompile_generics("identity", Int32, Int64, Float64)`, or tuples
  of types for a multi-parameter generic — specializes all of them into one
  source file and compiles it once. All the instantiations of a batch then share
  **one** mapped image, in the session that built it and in every later session
  that instantiates them lazily. Instantiations already in memory or already in
  the cache are not rebuilt, so a second call compiles nothing, and a batch that
  fails to compile (one inapplicable type poisons the whole file) falls back to
  building the types one at a time, where the caller gets the compiler's
  diagnostics for the type actually at fault.

### Changed
- **A monomorphized generic outlives the session that compiled it**
  ([#254](https://github.com/AtelierArith/RustCall.jl/issues/254)). Every
  instantiation was compiled into a temporary directory and cached only in
  memory, so restarting Julia re-ran the extractor and `rustc` for each one. The
  compiled library is now published to the artifact cache under the artifact key
  the instantiation is already identified by, together with a record of what the
  extractor reported about it (`<key>.spec.toml` beside the cache metadata); a
  later session restores both and runs **neither**. Measured over six
  instantiations of one generic function in two sessions sharing a cache, with
  `rustc` launches counted through a `PATH` shim: six `rustc` invocations in the
  second session before, **zero** after. What is left of an instantiation is a
  checksum verification, a file copy and a `dlopen` — about 0.02 s on an idle
  machine against about 0.5 s for the build it replaces. The record is only ever an
  optimisation — missing, unreadable, or written by another format version, it
  reads as a cache miss — and the artifact key folds in the toolchain
  fingerprint, so a library built by a different extractor or `rustcall_core`
  can never be restored. Nothing is ever mapped out of the cache directory
  itself, because the cache is a mutable store that a concurrent publisher may
  rewrite and `clear_cache()` may empty: an instantiation's own library is
  opened from a private copy, exactly as a freshly compiled one is — so
  retiring an image and asking for the instantiation again still produces a new
  image with its own statics and its own liveness flag (#291) — and a batch
  from one copy shared by the whole batch, which is what keeps its members on
  one image.
- **A `@rust_crate` wrapper no longer re-resolves its target on every call**
  ([#253](https://github.com/AtelierArith/RustCall.jl/issues/253)). The inline
  and `#[julia]` paths stopped doing that in 0.3.5; a generated crate module
  still took `REGISTRY_LOCK` to deref its generation mirror and looked its
  wrapper and panic-channel symbols up again on every call — about 1.0 µs and 14
  allocations in front of a 6.5 ns `ccall`, and calls from several threads ran
  *slower* than one (0.70× at four tasks). Each call site now keeps the snapshot
  it resolved in a `RustCall.CrateTargetCache` of its own and reuses it while
  `ARTIFACT_EPOCH` and `SESSION_TOKEN` say it is still this process's current
  answer: **21.8 ns and no allocations**, and 3.89× at four tasks. What is kept
  is one whole snapshot from one `_LIB_GEN` deref, never reassembled from
  pieces, so the generation rule of #277 is unchanged — an unload, a reload or
  an alias drops every kept snapshot, and the two mirror helpers bump the epoch
  themselves rather than relying on a neighbouring registry write to do it.
  Because a generated module is also written out as Julia source, its caches are
  named `const`s of the module rather than spliced objects, and
  `BINDINGS_FORMAT_VERSION` is **11**: regenerate any file written by
  `write_bindings_to_file`. See `docs/src/performance.md`.

## [0.3.5] - 2026-09-13

### Fixed
- **PyO3 wrapper follow-ups**
  ([#370](https://github.com/AtelierArith/RustCall.jl/issues/370)). Four edge
  cases deferred from #369, each of which made an otherwise wrappable crate fail:
  a **Python-owned class method returning `&str`** produced a helper that could
  not compile — the reference borrows the Python string bound to `py` and cannot
  leave `Python::attach` — and is now extracted as an owned `String` and carried
  on the existing owned-string ABI; the `rustcall_pyo3` alias now names the
  **package Cargo resolved** rather than a registry release of the same version,
  so a crate taking pyo3 from a `path` or `git` dependency no longer ends up with
  two pyo3 instances in one build; every **default-arity** entry point
  (`rustcall_foo__default_1` and its panic and string helpers) is reserved during
  collision analysis, so `foo(value = 1)` alongside a function named
  `foo__default_1` is refused instead of defining one symbol twice; and a crate
  whose pyo3 predates **0.26** — where `Python::initialize` / `Python::attach`
  arrived — is refused with a diagnostic naming the version, the floor and the
  way out, instead of failing later with rustc errors about generated code. See
  `docs/src/pyo3.md`.

  Four more corners found while reviewing that work, each one a name or a fact
  taken from the wrong place: whether a wrapper needs the pyo3 alias is now
  **reported by the generator** rather than inferred by scanning the Rust it
  emitted; the pyo3 the alias names is the crate's *normal* dependency, with
  Cargo's own `--filter-platform` deciding which `[target.'cfg(...)']` edges are
  live, so neither a `dev-dependencies` pyo3 of another version nor a live
  Unix-only one is mistaken for it; a wrapped crate whose own name is
  `rustcall_pyo3` or `rustcall_julia_macros` — the two the wrapper spends on
  itself — is depended on under `rustcall_target_<name>` instead of writing one
  dependency table twice; and an entry the generator **refuses** no longer keeps
  the symbols it would have exported, so `foo(values = vec![])` refused for its
  `Vec<i32>` argument no longer costs a function actually named
  `foo__default_1` its own name. That last one makes generation and the symbol
  analysis a fixpoint: the wrapper is lowered, what came out is reported back,
  and the analysis runs again while the answer keeps changing.

### Changed
- **A `@rust` call no longer re-resolves everything on every call**
  ([#253](https://github.com/AtelierArith/RustCall.jl/issues/253)). Each call
  walked the calling module's blocks, took the global `REGISTRY_LOCK`, rebuilt
  the symbol strings, looked up handle, pointer, panic channel and return ABI,
  and then computed the `ccall` signature from the argument types — about 9.9 µs
  and a hundred allocations in front of a 5 ns call, all under one lock, so four
  threads calling Rust ran *slower* than one. A call site now keeps the snapshot
  it resolved and reuses it while `RustCall.ARTIFACT_EPOCH`, bumped by every
  write to RustCall's state, says nothing has changed. Measured against a raw
  `ccall` into the same library (`benchmark/benchmarks_dispatch.jl`): a
  `#[julia]` function's generated wrapper 9891 ns → **10.0 ns**,
  `@rust f(a, b)::Int32` 8940 ns → **11.9 ns**, and throughput across four
  threads from 0.85× one thread to 5.18×. This does not weaken the generation
  rule of #277: what is cached is one whole snapshot, and it is dropped the
  moment the epoch moves — and an entry carries the process that wrote it, so a
  cache serialised into a precompiled package (a downstream package that calls a
  generated wrapper from a precompile workload does exactly that) can never be
  mistaken for a live one. `@rust f(a, b)` **without** a return-type annotation
  stays about 68× a raw `ccall` and is the one shape that cannot be fixed — its
  return type is read from the snapshot at run time, so the call is a dynamic
  dispatch by construction; annotate it, or mark the Rust function `#[julia]`
  and call the wrapper. See `docs/src/performance.md`.

  A follow-up ([#391](https://github.com/AtelierArith/RustCall.jl/pull/391))
  fixes the ordering this exposed: a caller module restored from a precompiled
  package was declared to have no such function *before* it had been restored,
  because the failure was raised from inside the `try` that does the restoring.
  Resolving the library now happens first and outside it.
- **A panic RustCall catches no longer prints `panicked at` to stderr**
  ([#304](https://github.com/AtelierArith/RustCall.jl/issues/304)). Rust runs
  the panic hook before the unwind `catch_unwind` catches, so every panic the
  generated wrapper handled correctly — recorded in its channel, raised as
  `RustCall.RustPanicError` — still looked like a crash in the log first. A
  generated artifact now keeps a thread-local boundary depth at its crate root
  and installs a hook that is silent while a wrapper body is running and
  delegates to the hook it replaced otherwise, so a panic outside a boundary
  still prints. Julia installs it once per image right after `dlopen`, which is
  what removes the install race the per-wrapper attempt in #302 had, and removes
  it in `close_artifact_handle!` before the image is unmapped. This covers every
  artifact RustCall loads that has a generated wrapper — inline blocks, `@irust`,
  monomorphized generics, the generated `@rust_crate` wrapper crate, **and a
  crate you wrote yourself and annotated with `#[julia]`**.
  `RUSTCALL_PANIC_HOOK=default` turns the hook off, and `-C prefer-dynamic`
  builds never get one, because a shared `std` shares the hook registry too.
  See `docs/src/panics.md`.
- **`rustcall_julia_macros` is a normal library crate, not a proc-macro crate**
  ([#304](https://github.com/AtelierArith/RustCall.jl/issues/304)). Nothing in
  your `Cargo.toml` changes — the dependency keeps its name, version and path,
  and `use rustcall_julia_macros::julia;` keeps working — but the package is now
  a facade that re-exports `#[julia]` from the new
  `deps/rustcall_julia_macros_impl` and adds a runtime module. That module is
  what makes the paragraph above true for hand-written crates: the quiet hook
  needs a thread-local depth counter shared by every wrapper in the image, an
  attribute proc macro is handed one item at a time and can emit no crate-wide
  state, and a proc-macro crate is compiled for the host and linked into no
  `cdylib` — so the state lives in the crate `#[julia]` itself comes from, which
  every such crate already depends on, and a wrapper names its guard
  `::rustcall_julia_macros::__RustCallBoundary`. `#[no_mangle]` items of a
  dependency rlib are exported from the `cdylib` that links it, so the image
  still answers to `__rustcall_install_panic_hook` and the loader is unchanged.
  The runtime module (`deps/rustcall_julia_macros/src/rt.rs`) is generated from
  the same `rustcall_core` definition the inline flavours use and asserted
  against it by `deps/rustcall_core/tests/runtime_crate.rs`. The one thing this
  costs: **renaming** the `rustcall_julia_macros` dependency in your
  `Cargo.toml` no longer compiles, because the generated guard names the crate
  literally.
- **`Pkg.build("RustCall")` no longer wipes its Cargo state, and no longer
  writes into an installed package**
  ([#258](https://github.com/AtelierArith/RustCall.jl/issues/258)). Through
  v0.3.4 the build script ran `cargo clean` before every build, so each build
  event — including the transitive ones Pkg triggers — paid a full Rust
  compile of `deps/rust_helpers` and `deps/rustcall_extract`. Cargo already
  knows which of its inputs changed, down to the `rustc` identity and the
  profile; rebuilding both crates unchanged went from ~31 s to ~0.1 s of Cargo
  time. The products' location is now decided in one place,
  `src/native_layout.jl`, which `deps/build.jl` includes rather than
  reimplements: a checkout keeps building in `deps/<crate>/target`, where the
  documented developer commands already put them, while an **installed**
  package builds into
  `<depot>/scratchspaces/<UUID>/native-v1/<slug>/<crate>` and its package
  directory is never written to — so a read-only package store works, and two
  installed RustCall versions in one depot cannot pick up each other's
  extractor. `RUSTCALL_EXTRACT` still overrides the CLI outright, and
  `RUSTCALL_RUST_HELPERS` now does the same for the helper library. Moving
  `CARGO_TARGET_DIR` is not enough by itself — Cargo writes `Cargo.lock` beside
  the manifest whatever the target directory says, which on a read-only tree
  fails the build outright — so both crates commit their lockfile and are built
  with `--locked`.

## [0.3.4] - 2026-09-12

### Fixed
- **A clash on a generated internal name is refused, and named for what it is**
  ([#338](https://github.com/AtelierArith/RustCall.jl/issues/338)). A wrapper
  defines more than its exports: the thread-local slot of its panic channel is
  the wrapper's symbol upper-cased, so `#[julia] fn foo` next to `#[julia] fn
  FOO` export two different symbols and still define
  `__RUSTCALL_PANIC_RUSTCALL_FOO` twice. The duplicate check now counts those
  names, and its two diagnostics tell the kinds apart: an exported symbol
  keeps the message it had, while an internal item says so and explains where
  the name comes from, instead of being called an export. The same covers the
  string buffer types two items with one buffer owner would declare twice. A
  private name is compared only within the module its wrapper is emitted into
  and within its own Rust namespace, so two modules may spell one slot name
  and a generated buffer type may share a spelling with an exported function.

### Changed
- **The default test run needs no crate from outside the repository's declared
  dependency closure, and CI proves it**
  ([#259](https://github.com/AtelierArith/RustCall.jl/issues/259)). The two
  registry crates the suite genuinely needs — `itoa` for the `// cargo-deps:`
  tests and `pyo3` for the fixtures — are declared in
  `test/fixtures/offline_prefetch/Cargo.toml`; everything else resolves
  through `path =` or through the closure of the repository's own crates. The
  new `Offline tests` workflow fetches exactly those manifests into an empty
  `CARGO_HOME` and runs the whole suite with `CARGO_NET_OFFLINE=true`, so a
  test that starts needing another registry crate fails until the crate is
  added there. `test/test_phase4_pi.jl` was the one outlier and no longer
  uses `rand`: it samples from a seeded linear congruential generator written
  in the block, which also makes its estimate reproducible. The fixture crates
  now carry a committed `Cargo.lock`, so their resolution is pinned instead of
  being whatever crates.io offers on the day.
- **One list of what a manifest entry claims**
  ([#338](https://github.com/AtelierArith/RustCall.jl/issues/338)). The
  `#[julia]` duplicate-symbol check and the PyO3 collision analysis each
  derived the names an entry's generated code defines, and the two lists had
  drifted — the `#[julia]` side forgot the panic readers, fixed in v0.3.3.
  Both now read `rustcall_core::claims`, and the three respects in which the
  scans genuinely differ — whether module-private names count, whether a
  `#[cfg]`-gated entry is kept with its predicate, and whether the string
  helpers are taken as declared or reserved because the wrapper crate has not
  been generated yet — are a `Policy` rather than a second implementation.

### Changed
- **Skipped testsets are counted, and the hot-reload tests no longer use a
  fixed `sleep` to synchronise**
  ([#259](https://github.com/AtelierArith/RustCall.jl/issues/259)). Sixty-five
  testsets announced a missing toolchain with `@warn` and returned, so they
  vanished from the summary rather than appearing as skips; they use
  `@test_skip` now. In `test/test_hot_reload.jl`, the five sleeps that waited
  for a watcher to stop are gone — `disable_hot_reload` already waits for the
  task through `stop_watch_task` — and the lock-serialisation test hands off
  through a channel and `wait(t)` instead of two fixed sleeps.

## [0.3.3] - 2026-09-11

### Fixed
- **The crate-wide duplicate-symbol scan sees the panic readers too**
  ([#338](https://github.com/AtelierArith/RustCall.jl/issues/338)). Every
  generated wrapper exports a second `#[no_mangle]` item next to itself — the
  reader of its panic channel, `<symbol>_take_panic` — and the scan did not
  count it. A crate-root `#[julia] fn a__run_take_panic` next to `#[julia] pub
  mod a { #[julia] pub fn run }` therefore reached the linker as two items of
  one symbol instead of being refused with both owners named. Struct methods
  claim their reader the same way, and inline expansion asks the same question
  of the manifest it has just built. A plain `#[no_mangle] extern "C"`
  function claims only its own name: RustCall generates nothing for it, so a
  hand-written `release` / `release_take_panic` pair stays two unrelated
  exports.

### Changed
- **The test suite states its own preconditions and no longer downloads crates
  by default** ([#259](https://github.com/AtelierArith/RustCall.jl/issues/259)).
  Around sixty testsets step aside when `rustc` is missing, so a provisioning
  failure on some platform could leave the suite green while asserting almost
  nothing; `test/test_toolchain.jl` now asserts under `CI=true` (or
  `RUSTCALL_REQUIRE_TOOLCHAIN=true`) that rustc and cargo resolve and that
  `Pkg.build` produced the helpers library. The serde_json, regex, uuid and
  ndarray integration tests became opt-in — their variables default to `false`
  and a scheduled `Network integration` workflow, which is allowed to fail,
  sets them — so a crates.io hiccup no longer turns an unrelated pull request
  red. `test_external_crates.jl`, `test_ndarray.jl` and
  `test_phase4_ndarray.jl` reach the registry only when asked to; the
  cargo-tree regression of #278 moved to `test/test_cargo.jl`, where it keeps
  running by default.

### Changed
- **`BenchmarkTools` is no longer a runtime dependency, and Aqua.jl now
  enforces that** ([#260](https://github.com/AtelierArith/RustCall.jl/issues/260)).
  It was listed in `[deps]` while only `benchmark/*.jl` used it, so every
  installation of RustCall pulled it and its transitive dependencies into the
  runtime graph. It moves to a `benchmark/Project.toml` of its own; the
  benchmark scripts are now run with `--project=benchmark` and resolve the
  repository checkout through `benchmark/setup.jl`. `test/test_aqua.jl` runs
  `Aqua.test_all`, which fails on a stale dependency, a missing `[compat]`
  bound, type piracy, an unbound type parameter or an undefined export, so the
  class cannot come back silently.
- **`deps/juliacall_macros` renamed to `deps/rustcall_julia_macros`.** The
  crate's name suggested a companion to the unrelated `juliacall` PyPI
  package (the Python-side counterpart of `PythonCall.jl`) rather than a
  RustCall.jl crate; it also broke the `rustcall_` prefix shared by
  `rustcall_core` and `rustcall_extract`. This is a rename only — the
  `#[julia]` attribute macro it exports is unchanged, and it is still not
  published to crates.io, so consumers keep depending on it via a `path`
  dependency (now pointing at `deps/rustcall_julia_macros`).

## [0.3.2] - 2026-09-10

### Fixed
- **Python-owned PyO3 handles keep their lifetime policy after method
  filtering** ([#371](https://github.com/AtelierArith/RustCall.jl/issues/371)).
  The wrapper manifest now records the authoritative handle decision before
  unsupported methods are removed, so generated bindings continue to pin the
  library image and keep Python-owned finalizers live.

## [0.3.1] - 2026-09-09

### Fixed
- **Two cfg-exclusive modules including one fragment are both scanned**
  ([#357](https://github.com/AtelierArith/RustCall.jl/issues/357)). Since #343
  the crate walk keyed the files it had seen by (file, module path), so
  `#[cfg(feature = "x")] mod api { include!("frag.rs"); }` beside
  `#[cfg(not(feature = "x"))] mod api { include!("frag.rs"); }` scanned the
  fragment once and recorded its items under whichever predicate the walk
  reached last — the *off* branch for a build that enables the feature, so
  the binding was dropped while the library exported the symbol. The key is
  now the file and its full position (module path, `#[cfg]`, reachability,
  `#[julia] mod` chain), so a lenient scan reports both entries; one fragment
  included twice at the same position is still one scan.
- **A panic inside an `@irust` snippet is a catchable exception, not an abort**
  ([#346](https://github.com/AtelierArith/RustCall.jl/issues/346)). `@irust`
  hand-wrote a bare `#[no_mangle] pub extern "C"` entry point with no
  `catch_unwind` boundary and no panic-channel write, so an unwind crossing it
  terminated the Julia process — while `_call_irust_function` dutifully read a
  channel nothing ever wrote. The snippet is now emitted as a `#[julia]` item
  and expanded by `rustcall-extract`, exactly like a `rust"""` block, so it
  gets the same generated wrapper: `@irust("\$x / \$z")` with `z == 0` raises
  `RustCall.RustPanicError` and the session survives. The call goes through the
  wrapper's exported symbol, and that symbol and the return type are memoized
  with the snippet instead of being re-derived on a cache hit.
- **`@irust` with no interpolated variable works, and so does `irust"..."`**
  ([#347](https://github.com/AtelierArith/RustCall.jl/issues/347)). The
  argument-type vectors were built with `collect(map(...))`, which is a
  `Vector{Union{}}` for an empty tuple and matched none of the downstream
  methods, so every argument-less `@irust` died with a `MethodError` before it
  compiled anything. `irust"..."` shares `@irust`'s expansion now, so
  `irust"$x * 2"` interpolates too — a non-standard string literal is not
  interpolated by Julia, so it needs no backslash.
- **`@irust`'s return type comes from rustc instead of a regex**
  ([#348](https://github.com/AtelierArith/RustCall.jl/issues/348)). The type
  was guessed by ordered heuristics over the snippet's text: anything
  containing `->` (an inner `fn`, a closure), `=>` (a `match` arm) or a
  comparison was called `bool`, `$x as f64` with an integer argument was called
  `i64`, and a `Float32` argument forced `f64` — every miss surfacing as a
  rustc error in generated source the user never wrote. The snippet is now
  type-checked on its own first (`--emit=metadata`, no linking) and the type is
  read out of rustc's `--error-format=json` diagnostics as **data**
  (`RustCall.rustc_diagnostics`), so `@irust("$x as f64")`,
  `@irust("if $x > 0 { 1 } else { -1 }")` and
  `@irust("{ fn sq(v: i64) -> i64 { v * v }  sq($x) }")` simply work. A snippet
  that does not type-check raises with rustc's own diagnostic about the
  snippet; a snippet whose value is `()` returns `nothing`. **Every** return
  site is reconciled, not just the first: the probe's `()` return type keeps
  the sites of `if flag { return 0; } x` from unifying with each other the way
  they will in the real function, so a concrete type wins over an unconstrained
  literal and genuinely disagreeing sites are named rather than guessed
  between. The snippet is bound to a local first and compared to `()` after, so
  its own inference finishes before `()` is applied to it — pushing the
  expected type into the block instead would pin a `loop` at its first `break`
  and hide the later one that knows the type. A path that already produces `()`
  provokes no diagnostic — it matches the probe's own return type — so the
  answer is *confirmed* by
  type-checking the snippet once more with that type declared, which is what
  catches `if flag { return 1i64; }` and reports rustc's own "`if` may be
  missing an `else` clause" about the snippet instead of a later error in
  generated source. The probe is compiled with the same target, opt-level and
  panic flags as the build (`_cfg_rustc_flags`), because those decide `#[cfg]`
  predicates — `debug_assertions` is on at opt-level 0 and off above it. The
  scalar set (`IRUST_SCALAR_TYPES`) is checked on the **result** as well as on
  the arguments, so a snippet whose value is an `i128`/`u128` is refused rather
  than read back over an ABI Rust and Julia disagree about on
  `x86_64-pc-windows-msvc`.
  `_infer_return_type_improved` / `_infer_return_type` are gone, and with them
  the last regex over Rust source in `src/` that decided anything (#264).
- **An `@irust` snippet may contain statements**
  ([#349](https://github.com/AtelierArith/RustCall.jl/issues/349)). The snippet
  used to be closed by looking at its first word — wrapped whole as
  `return <snippet>;` unless it already started with `return` — so
  `let t = …; t + 1` became non-Rust and a `return`-first snippet had to be a
  single statement. It is now the **body** of the generated function: a
  trailing expression is the value, `return` works, and `let` bindings, loops,
  early returns and multi-line snippets need no special case.
- **`$$` is a literal `$` in an `@irust` snippet**
  ([#350](https://github.com/AtelierArith/RustCall.jl/issues/350)). The escape
  was documented in a comment but absent from the pattern, so `$$x` substituted
  the *second* `$` and emitted `$arg1`; a snippet containing `macro_rules!`
  with `$metavar` could not be written at all. The interpolation rules — what
  `$name` matches, that substitution reaches inside Rust string literals, and
  what the escape is — are now documented in the `@irust` docstring, in
  `README.md` and in the manual, together with `@irust`'s remaining limitations
  (scalars only, textual substitution, not type-stable, a compiler invocation
  per new snippet) and the guidance to use `rust"""..."""` with `@rust` for
  anything larger.
- **An inline `rust"""` block's cross-module `#[julia] impl` compiles**
  ([#342](https://github.com/AtelierArith/RustCall.jl/issues/342)). Since #315 a
  `#[julia] impl` block may sit in another module than its struct. The inline
  expander emitted every method's wrapper next to the *struct*, so a method
  whose signature named a type only the impl's module can see (`type Count =
  i32;` beside the block) produced a `cannot find type` error in generated
  code. Such a wrapper is now emitted **inside the impl's module**, spelling
  the struct the way the header does (`super::Gauge`) — which is what the
  proc-macro has always done for the crate flavour. The exported symbol is
  crate-global and still follows the struct (`rustcall_Gauge_read`), so nothing
  a caller sees changes. A wrapper emitted at the block declares string buffers
  of its own (`<Struct>_<method>_RustCallOwnedString`) instead of sharing the
  struct's, and a struct whose only string-returning method is cross-module no
  longer grows shared buffers nothing would use. The manifest gained
  `Method.string_owner` so Julia reads which buffer each method uses instead
  of deriving it from the flavour, and the **manifest schema goes to 8**: the
  column is a breaking addition, not an additive one, because a consumer that
  ignores it derives `<Struct>_free_rust_string` for a cross-module method
  whose buffer is released through `<Struct>_<method>_free_rust_string` — and
  where the struct has no local string helper that symbol does not exist, so
  the buffer leaks in silence. `src/manifest.jl` validates exact equality, so
  the version is what makes such a consumer refuse the manifest.
- **An out-of-line `mod` inside an `include!`d file is followed**
  ([#343](https://github.com/AtelierArith/RustCall.jl/issues/343)). The crate
  walk followed a literal `include!("api.rs")` since #315, but it did so inside
  `rustcall_core`, which is not the layer that owns the filesystem: a
  `mod nested;` written in the fragment was reported to nobody, so a `#[julia]`
  item in `nested.rs` was missing from the manifest while the proc-macro still
  wrapped it, and the PyO3 scan never saw a fragment's items at all. Both scans
  are now fed by one walk. `TreeScan::file` returns a `PullIns` — the
  out-of-line `mod` declarations *and* the `include!` fragments — and
  `rustcall-extract`, the only layer that touches files, follows both: a
  fragment is read and scanned as a file of its own at the *including* item's
  position (same module path, same `#[julia] mod` chain, same `#[cfg]`), and a
  `mod` declared inside it resolves against the **fragment's own directory**,
  which is rustc's rule (`include!("frag/api.rs")` in `src/lib.rs` with
  `mod nested;` inside wants `src/frag/nested.rs`, whether or not the
  `include!` sits in an inline module). A fragment that does not exist, or that
  is not a list of items (`include!("table.rs")` holding `[1, 2, 3]`), is noted
  on stderr and skipped as a missing `mod` target already was — never a failed
  scan.
- **A package that uses `@rust_crate` at top level can be precompiled**
  ([#339](https://github.com/AtelierArith/RustCall.jl/issues/339)). The macro
  evaluated the generated module into an anonymous `Module` under `Main`, so
  `Pkg.precompile()` of such a package failed with ``Evaluation into the closed
  module `##RustCallCrateRuntime#N` breaks incremental compilation``. The
  module is now defined **inside the module that expands the macro**
  (`load_crate_bindings(...; target_module = __module__)`), in a hidden,
  per-call child namespace (`Caller.var"##RustCallCrateRuntime#N"`), so nothing
  the caller did not name appears in its namespace and repeated calls never
  collide (the #222 contract). The return value is unchanged, a
  `RustCall.CrateBindings`; `load_crate_bindings` called without a
  `target_module` keeps the anonymous module. Two consequences for the
  generated module: `_LIB_PATH` of an
  in-memory `@rust_crate` module is now the **durable** library — RustCall's
  cache copy, or Cargo's output — instead of the per-process generation copy,
  which is made in `__init__` (as the written file already did since format 6),
  because after precompilation `__init__` runs in a later session than the one
  that generated the module (visible only through `Bindings.module_ref._LIB_PATH`);
  and the module declares that library **and the crate's own input files** —
  the set its artifact identity is computed from: the crate directory, every
  local `path` dependency, a workspace root's manifest and lockfile, an
  out-of-directory `[lib] path` — with `Base.include_dependency`. So editing
  `src/lib.rs`, or `RustCall.clear_cache()`, makes the package's precompile
  cache stale and the next `using` re-precompiles it and builds the crate
  again, instead of `__init__` opening a path that is gone or the package
  going on calling a build that no longer matches its source. Tracking the
  library alone would not do the second of those: the library is
  content-addressed, so a new build lands at a *different* path and leaves the
  old file untouched (found in review of
  [#351](https://github.com/AtelierArith/RustCall.jl/pull/351)). The
  crate is built when the package is precompiled, nothing is written into the
  package, and the library is not opened during precompilation (`__init__` is
  deferred to load time), so the bindings are callable after the package's
  `__init__`, not from its own top level. The generated module imports `Libdl`
  through RustCall (`import RustCall.Libdl`), so the package does not need
  `Libdl` among its dependencies.
- **A changed build environment is reported rather than ignored**
  ([#339](https://github.com/AtelierArith/RustCall.jl/issues/339)). `RUSTFLAGS`,
  `PYO3_PYTHON` and a `PYO3_CONFIG_FILE` pointing at another file decide the
  artifact but are not files, so Julia — which invalidates a precompile image
  from files — keeps the image and the package loads a library built under the
  previous values. The generated module records the environment it was built
  under (`artifact_build_env`) and `__init__` warns when it no longer matches,
  naming the variables that changed and how to force a rebuild.
  [#355](https://github.com/AtelierArith/RustCall.jl/issues/355) tracks
  representing such inputs in the invalidation scheme itself.
- **A plain crate's cache key covers the build environment**
  ([#339](https://github.com/AtelierArith/RustCall.jl/issues/339)).
  `compute_crate_hash` was called without `build_env` on the non-PyO3 path, so
  two `cargo build`s under different `RUSTFLAGS` — or a different `CC` a build
  script reads, or anything else in the #282 allowlist — shared one cache entry
  and the second was handed the first one's library. The PyO3 wrapper path
  already folded `artifact_build_env()` in; the plain path does now too, and
  like the wrapper it hashes the *contents* of `PYO3_CONFIG_FILE` on top —
  the allowlist records the path, and a plain build of a crate that depends on
  pyo3 reads the file, so an in-place edit of the configuration is a different
  binary under the same key (`_plain_crate_build_env`). One
  consequence is that the load-time warning above can be acted on: forcing the
  package to be precompiled again really does rebuild the artifact, instead of
  finding the stale one under the same key.
- **`@rust_crate <crate> cache=false` on a crate that RustCall has to wrap**
  ([#339](https://github.com/AtelierArith/RustCall.jl/issues/339)). A crate
  whose `[lib]` is not a `cdylib` is bound through a generated wrapper project
  in a temporary directory, which is deleted as soon as the build returns.
  With caching on, the library had already been copied into the cache; with
  `cache = false` nothing copied it, so the generated module named a file that
  no longer existed and loading it failed with `could not load library
  ".../rustcall_wrapper_XXXXXX/target/release/..."`. The library is now taken
  out of the wrapper project before the cleanup — into the cache, or into a
  directory of its own under the Cargo cache that outlives the process (a
  package precompiled with `cache = false` is loaded by a *later* process, and
  a `mktempdir()` cleaned at exit would have taken the recorded `_LIB_PATH`
  with it; the PyO3 wrapper path had the same `mktempdir()` and uses the same
  home now). `cache = false` is still not the shape to use inside a
  package: `docs/src/crate_bindings.md` says which path the module then carries
  and what makes its precompile cache stale.

### Added
- **`@rust_crate ... submodule="Bindings"`**
  ([#339](https://github.com/AtelierArith/RustCall.jl/issues/339)) defines the
  generated module in the calling module under that name, so a package can
  `using .Bindings: f, T` from it — the idiom that pairs with the precompile
  fix above, and the same shape as `include("generated/Bindings.jl")`. `name=`
  is unchanged: it names the generated module and defines nothing, which is
  what keeps the documented `const MyBindings = @rust_crate path name="MyBindings"`
  working. The two are separate options on purpose: an earlier cut of this
  change made `name=` define the module, and a package written that way
  precompiled and then **segfaulted** on load, because the constant was bound
  over the module binding the macro had just created (found in review of
  [#351](https://github.com/AtelierArith/RustCall.jl/pull/351)).
- **`examples/RustCrateMacroPyO3Only.jl`**, a Julia package that binds a
  **PyO3-only** Rust crate with the **`@rust_crate` macro**. Its crate
  `deps/macro_pyo3_only` carries no RustCall attribute and no
  `rustcall_julia_macros` dependency — `#[pyfunction] scale` / `join_words` /
  `checked_div`, a `#[pyclass(get_all, set_all)] Counter` with `#[new]`, a
  `#[staticmethod]`, `&self` / `&mut self` / `String` / `PyResult` methods, and
  a `#[pymodule]` initializer the scan skips — so RustCall binds it through the
  generated wrapper crate
  ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275) Phase 2, link
  plan `:link_libpython`). It is the sibling of
  `examples/SampleCratePyO3Only.jl`: the same Rust, the other **front door**.
  `@rust_crate joinpath(...) submodule="Bindings"` sits at the package's top
  level, so there is no `deps/build.jl`, no `src/generated/` and nothing
  generated in the repository — the crate is built and the bindings module
  defined while the package is *precompiled*
  ([#339](https://github.com/AtelierArith/RustCall.jl/issues/339)). Its
  `Pkg.test()` runs in the `Examples` workflow (job
  `Example - RustCrateMacroPyO3Only.jl`), which installs a Python interpreter
  with `actions/setup-python` and pins it with `PYO3_PYTHON`, as it already did
  for `SampleCratePyO3Only.jl`.

## [0.3.0] - 2026-09-08

### Breaking
- **Exported symbols carry the module path** ([#300](https://github.com/AtelierArith/RustCall.jl/issues/300)).
  The scheme of #279 (`rustcall_<name>`, `<Struct>_free`, ...) had no module
  path, so two `#[julia] fn run` — or two `#[pyclass] struct C` — in different
  modules of one crate wanted the same symbol: a duplicate-symbol error from
  rustc, or a silently wrong binding. Every symbol now hangs off the item's
  **FFI name** (`rustcall_core::codegen::symbol_stem`, the one derivation every
  flavour uses — proc-macro, inline expansion, `specialize`, the PyO3 wrapper
  generator): the bare name at the crate root, otherwise the module path and
  the name joined with `__`, each `_` inside a segment spelled `_0`
  (`a::run` → `rustcall_a__run`, `a::C` → `a__C_free` / `rustcall_a__C_new`,
  `my_mod::my_fn` → `rustcall_my_0mod__my_0fn`; `a_b::c` and `a::b_c` cannot
  meet). What changes for users:
  - **`#[julia]` on inline modules.** A proc-macro cannot see its enclosing
    module, so the module carries the attribute: `#[julia] pub mod a { #[julia]
    pub fn run() ... }` expands its `#[julia]` items with the module path, and
    nested marked modules accumulate. A `#[julia]` item inside an inline module
    that is *not* marked is refused by the scan with the fix in the message
    (it would have been exported under the crate-root symbol). File modules
    (`mod a;`) cannot carry the attribute and stay transparent (root symbols);
    a duplicate across them is reported by a new crate-wide check in
    `rustcall-extract`, naming both locations. Items at the crate root keep
    every symbol they had.
  - **Symbols of items inside inline modules change**, in crates and in
    `rust"""` blocks alike (the inline expander qualifies by the modules it
    walks, no marker needed). Anything resolving `rustcall_<name>` by hand for
    such an item must use the manifest's `symbol` / `ffi_name`.
  - **One Julia submodule per Rust module.** `@rust_crate` and
    `write_bindings_to_file` bind `a::run` as `bindings.a.run()` and `a::C` as
    `bindings.a.C`, mirroring the Rust tree; root items stay where they were.
    Static-method name collisions (#323) are decided per module. The bindings
    file format marker is `7`; regenerate written modules.
  - **Manifest schema 7** (together with the `#[julia_pyo3]` removal below):
    `Function.ffi_name` / `Struct.ffi_name` carry the stem, `symbol` and the
    field accessors are qualified, crate mode records `module_path` for
    `#[julia]` items (the chain of marked modules), and entries are sorted by
    module path. `RustFunctionSignature`, `RustStructInfo` and
    `SpecializedFunction` gain an `ffi_name` field, which `ffi_struct_free_symbol`
    / `ffi_free_symbol` callers now pass instead of `name`.
  - PyO3-scanned items are qualified by their real module path, so the
    cross-module `symbol_collision` skip reason of #294 is unreachable; the
    reason survives only for same-module coincidences (an item whose own name
    spells another item's generated symbol).
  - A module name Julia cannot define next to a parent binding — Rust keeps
    `fn a` and `mod a` in separate namespaces, Julia does not — is refused when
    the bindings are laid out (functions, structs, methods, field accessors and
    the generated helpers, the imported names and the exports of `Base` all
    count), naming both sides and the fix; a struct whose type name repeats a
    function-like binding of its own module (`fn C` + `struct C`, legal in
    Rust) is refused the same way. A raw identifier module (`r#type`) is bound as `type`; a
    module whose name is a Julia keyword (`end`, `function`, `macro`, …) is
    refused rather than written into a file Julia cannot parse.
  - A `#[julia] impl C` must sit in the same module as its `#[julia] struct
    C`: the proc-macro derives the method symbols from the module the impl is
    in, so an impl of a struct defined elsewhere — which used to be dropped
    silently — is refused with the rule. Inside a `#[julia] mod`, a gated
    struct's or impl block's `#[cfg]` is copied onto every helper generated
    for it, so the crate still builds with the gate off.
  - The PyO3 scan's Julia-surface collision check (`julia_name_collision`) is
    scoped per module, matching the layout: `a::parse(x)` and `B::parse(x)` in
    `b` no longer refuse each other.
  - **A module's `#[cfg]` now gates the items inside it** in every scan: an
    entry's `cfg` / `cfg_features` include the predicates of its enclosing
    modules (`#[cfg(feature = "x")] mod a { fn f }` reports `f` under
    `feature = "x"`), for `#[julia]` items in crate and inline mode and for
    PyO3-scanned items, including files reached through a gated `mod a;`. A
    lenient scan used to report such items as unconditional and bind them in a
    build without the feature.

### Added
- **`examples/SampleCratePyO3Only.jl`**, a third example package: a Julia
  package with a crate **written for PyO3 only** embedded under
  `deps/sample_crate_pyo3_only` — no RustCall attribute anywhere, no
  `rustcall_julia_macros` dependency — bound through the wrapper crate RustCall
  generates (`write_bindings_to_file`, [#275](https://github.com/AtelierArith/RustCall.jl/issues/275)
  Phase 2). It shows `#[pyfunction]` / `#[pyclass(get_all, set_all)]` /
  `#[new]` / `#[staticmethod]` bindings without `#[julia]`, `PyResult<T>`
  arriving as `RustResult{T, String}` with the opaque
  `RustCall.PYO3_OPAQUE_ERROR` and a Julia layer over it, and the
  `:link_libpython` link plan: the wrapper links libpython, so the package
  needs a Python interpreter to build (`PYO3_PYTHON` pins one). The
  `Examples` workflow tests it with a `actions/setup-python` interpreter.

### Removed
- **`#[julia_pyo3]`** ([#312](https://github.com/AtelierArith/RustCall.jl/issues/312)),
  deprecated in 0.2.0 (#275 Phase 3). The proc-macro is gone from
  `rustcall_julia_macros`, so a crate that still uses it fails to build with
  ``cannot find attribute `julia_pyo3` `` at every use site, and with it goes
  everything that existed only for it: the frozen lowering
  (`transform_function_julia_pyo3` / `transform_struct_julia_pyo3` /
  `transform_impl_julia_pyo3`, the either/or `cfg(feature = "python")` shape
  and the as-written signature of #269, `FreeFnOptions::extra_cfg` and the
  `lower_strings` knob of the wrapper generator, which nothing else ever turned
  off), the `julia_pyo3` value of the manifest's `attribute` origin
  (**manifest schema 6 → 7**, `RustCall.MANIFEST_SCHEMA_VERSION` /
  `rustcall_core::manifest::SCHEMA_VERSION`, so a stale extractor is rejected
  as before), the inert `python` feature of `rustcall_julia_macros`
  (`examples/sample_crate_pyo3` enables `pyo3` alone now), and the Julia-side
  deprecation notice — the `@rust_crate` / `write_bindings_to_file` warning and
  the `scan_report` marker — together with its fixtures. Write `#[julia]` next
  to PyO3's own attributes instead; the migration table stays in
  `docs/src/pyo3.md`, "Migrating from `#[julia_pyo3]`", for this release.
- **`@rust_llvm` and the LLVM IR integration path** ([#265](https://github.com/AtelierArith/RustCall.jl/issues/265),
  Phase 2; deprecated in 0.2.0 by [#267](https://github.com/AtelierArith/RustCall.jl/pull/267)).
  `@rust_llvm` performed the same function-pointer `ccall` as `@rust`, and
  rustc tracks a newer LLVM than the one bundled with Julia (Julia 1.12 ships
  LLVM 18, rustc 1.98 emits LLVM 22 IR), so the emitted IR could not be parsed
  reliably. **Breaking**: use `@rust name(args...)::T`. RustCall no longer
  depends on `LLVM.jl`. Removed, so a user can grep:
  - macros and calls: `@rust_llvm`, `_rust_llvm_call`, `rust_call_generated`
  - registration: `compile_and_register_rust_function`,
    `get_registered_function`, `RustFunctionInfo`, `LLVM_FUNCTION_REGISTRY`,
    `LLVMCodeGenerator`, `get_default_codegen`, `generate_llvmcall_ir`,
    `build_llvmcall_expr`, `extract_function_ir`, `julia_type_to_llvm_ir_string`
  - IR loading: `compile_rust_to_llvm_ir`, `load_llvm_ir`, `RustModule`,
    `RUST_MODULES`, `LLVM_REGISTRY_LOCK`, `get_function`, `list_functions`,
    `get_function_signature`, `get_or_compile_function`, `dispose_module`,
    `llvm_type_to_julia`, `julia_type_to_llvm`,
    `sanitize_unsupported_llvm_ir_attributes`, `parse_llvm_module_with_fallback`
  - optimization: `OptimizationConfig`, `get_default_opt_config`,
    `set_default_opt_config`, `optimize_module!`, `optimize_function!`,
    `optimize_for_speed!`, `optimize_for_size!`, `optimize_balanced!`,
    `get_optimization_stats`, `verify_module`, `print_module_ir`,
    `print_function_ir`
  - Julia-side helpers that existed only for the path: `RUST_MODULE_REGISTRY`
    (nothing ever wrote to it), `get_rust_module`, `infer_function_types`,
    `SignatureInferenceError`, `get_cached_llvm_ir`, `save_cached_llvm_ir`,
    `llvm_to_julia_type`, `julia_to_llvm_type` (the string-based helpers in
    `typetranslation.jl`), and the `llvm_policy` load policy.
  - `benchmark/benchmarks_llvm.jl`, the `@rust_llvm` column of
    `benchmark/benchmarks.jl`, and the "LLVM integration (deprecated)"
    reference page.
  `list_library_functions(lib)` now returns the function names the manifest
  recorded for the library instead of always returning an empty list.

### Changed
- **Every example under `examples/` is self-contained.** `examples/SampleCrate.jl`
  and `examples/SampleCratePyO3.jl` used to build the sibling crates
  `examples/sample_crate` and `examples/sample_crate_pyo3`, which were also the
  test suite's fixtures. Each package now embeds its own crate in the layout the
  Precompilation Support guide prescribes — `deps/sample_crate/` and
  `deps/sample_crate_pyo3/` (with `main.py`) — and `deps/build.jl` builds that;
  the embedded `sample_crate` is trimmed to what the package exports and tests.
  The only reference an example makes outside its directory is the
  `rustcall_julia_macros` path dependency, because the proc-macro crate is not on
  crates.io yet. The fixtures moved to `test/fixtures/sample_crate`,
  `test/fixtures/sample_crate_pyo3`, `test/fixtures/sample_crate_pyo3_only`,
  `_mixed` and `_optional`, and `cargo test` passes again in `sample_crate`:
  its `Result` / `Option` unit tests read the pre-#279 `CResult` fields
  (`result.is_ok`, `ok_value`) and did not compile; they now compare the plain
  `Result` / `Option` values, in the fixture and in the embedded copy.
  Documentation that pointed `@rust_crate` at `examples/sample_crate*` now
  names the embedded crate or the fixture.

### Fixed
- **A `#[julia] impl` block in another module than its struct binds its methods**
  ([#315](https://github.com/AtelierArith/RustCall.jl/issues/315)). The crate
  scan matched an impl block only to a struct at the same file / module level,
  so for `struct Gauge` in `lib.rs` and `impl crate::Gauge` in `ops.rs` the
  proc-macro emitted `rustcall_Gauge_read` while the manifest listed `Gauge`
  with no methods and the Julia module had no `read`. `rustcall-extract` now
  scans the crate's module tree once for both `#[julia]` and PyO3 items
  (`--crate-root`, which no longer takes FILE arguments), collects structs and
  `#[julia] impl` blocks crate-wide and marries them through the resolver the
  PyO3 scan already had (`crate::`, `super::`, `self::`, a `use`, a bare name);
  the inline expander does the same within a `rust"""` block. The method
  symbols follow the struct the header names, so the proc-macro now reads the
  header (`impl super::Gauge` inside `#[julia] mod ops` is `rustcall_Gauge_read`,
  not `rustcall_ops__Gauge_read`) and spells the struct in the wrapper the way
  the header does, so nothing needs to be in scope next to the block. A block
  whose header names no `#[julia]` struct, an ambiguous one, or one the
  proc-macro would qualify differently from the struct fails the scan with the
  header to write instead of being dropped; the crate-wide duplicate-symbol
  check of #300 now runs inside the scan, within one file as much as across
  files. A header that resolves to a struct **without** `#[julia]` — the plain
  `struct C` beside the block, which is what Rust resolves to — is refused with
  the fix to make, never attached to a same-named annotated struct elsewhere.
  A file reached only by a literal `include!("api.rs")` is scanned as part of
  the including module, so items the proc-macro wraps there are in the manifest
  too. The `#[julia_pyo3]` half of the issue is moot: that macro was removed
  in v0.3.0 (#330). Known limitation: in a `rust"""` block a cross-module
  method's signature must be in scope at the struct
  ([#342](https://github.com/AtelierArith/RustCall.jl/issues/342)).

## [0.2.1] - 2026-09-07

### Added
- **The Pluto notebook `examples/pluto/hello.jl` runs in CI.** The `Examples`
  workflow gains a `Pluto - hello.jl` job that opens the notebook headlessly in
  a Pluto session (`examples/pluto/run_notebook.jl`, with Pluto provided by
  `examples/pluto/Project.toml`), runs every cell in Pluto's own worker process
  against the RustCall of the checkout, and fails when any cell errors — so the
  notebook is tested like the example packages instead of being found broken
  by a reader.

### Fixed
- **A static `#[julia]` method no longer overwrites a free function of the same
  name** ([#323](https://github.com/AtelierArith/RustCall.jl/issues/323)). A
  method without `self` was bound as a bare Julia function named after the
  method, so `Labeler::shout` and the crate's free `fn shout` defined
  `shout(::Any)` twice: the second silently replaced the first under
  `@rust_crate`, and a module written by `write_bindings_to_file` failed to
  precompile ("Method overwriting is not permitted"). A static method now
  dispatches on the type — `shout(Labeler, s)` — and keeps the bare
  `shout(s)` form only when no free function or other static method of the
  crate has that name, so every existing non-colliding call still works and the
  free function always keeps its name. The inline `rust"""` path applies the
  same rule to a `#[julia] impl` block's static methods (`add(MathUtils, a, b)`).
  `examples/sample_crate` is unchanged and now binds both `shout`s.

### Changed
- **The sample crates have Julia packages beside them.** `examples/SampleCrate.jl`
  wraps `examples/sample_crate` and `examples/SampleCratePyO3.jl` wraps
  `examples/sample_crate_pyo3`, each a `Pkg`-testable package in the shape of
  `examples/MyExample.jl` and of the documented package workflow: Rust stays in
  the crate's `src/lib.rs`, `deps/build.jl` writes `src/generated/Bindings.jl`
  with `write_bindings_to_file` (loading the package runs it once when the file
  is missing; `Pkg.build` regenerates), `src/<Package>.jl` holds the
  hand-written Julia (a `Result` becomes a value or an exception, an `Option` a
  value or `nothing`), and `test/runtests.jl` is what `Pkg.test()` runs. The ad
  hoc scripts `examples/sample_crate/example.jl` and
  `examples/sample_crate_pyo3/main.jl` moved into those tests, and the suite no
  longer spawns `main.jl` (`test_crate_bindings.jl`); the `Examples` GitHub
  workflow runs every example package's `Pkg.test()` instead.

## [0.2.0] - 2026-09-07

### Deprecated
- **`#[julia_pyo3]`** ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275),
  Phase 3). `#[julia]` is additive since #279 and composes with PyO3's own
  attributes, which spell the Python half with their full option surface
  where this macro could only guess (`#[pyfunction]` per function,
  `#[pyclass(get_all, set_all)]` per struct, `#[new]` on anything named
  `new`). Write `#[julia] #[cfg_attr(feature = "python", pyo3::pyfunction)]`
  on a function, `#[julia] #[cfg_attr(feature = "python", pyo3::pyclass(...))]`
  on a struct, and a `#[cfg(feature = "python")] #[pyo3::pymethods] impl`
  beside the `#[julia] impl` for methods. The macro still expands as before
  and the manifest still reports its items under the `julia_pyo3` origin, so
  existing crates keep building; rustc now reports `use of deprecated macro`
  at every use site, `@rust_crate` / `write_bindings_to_file` warn once per
  crate, and `scan_report` marks each item — a `#[julia]` struct whose impl
  block is the deprecated one included, since a method's manifest entry now
  records the attribute of the impl block it came from (`Method.attribute`,
  additive within schema 6). Removal comes with the next breaking release.
  `examples/sample_crate_pyo3` is migrated to the new shape and
  `docs/src/pyo3.md` gains "Migrating from `#[julia_pyo3]`".

### Added
- **`// cargo-deps:` builds are pinned and reproducible**
  ([#256](https://github.com/AtelierArith/RustCall.jl/issues/256)). The first
  build of a dependency set resolves it once (`cargo generate-lockfile`) and
  persists the `Cargo.lock` under `<cache dir>/lockfiles/`, named by the
  declared set alone (`RustCall.lockfile_path`, `cargo_lockfile_id`); every
  later build — of any block with the same dependencies, on any machine that
  has the file — replays it with `cargo build --locked`. The lockfile's content
  is part of the block's artifact identity, so a changed resolution is a new
  artifact rather than a stale cache hit. `RUSTCALL_OFFLINE=1` adds `--offline`
  to every Cargo invocation and fails loudly without a warm registry cache.
  `clear_cache` keeps the lockfiles (they are inputs, not output);
  `RustCall.clear_lockfiles()` discards them. The generated project's package
  name is now derived from the dependency set (`RustCall.cargo_block_package`),
  so one lockfile fits every block declaring it.
- **`@rust_crate` binds a PyO3 crate that carries no RustCall attribute**
  ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275), Phase 2).
  RustCall generates a *second* crate that depends on the target, emits one
  `extern "C"` entry point per wrappable item, builds it under the Phase-1.5
  link plan and loads the result. A `#[pyfunction]` becomes `rustcall_<name>`;
  a `#[pyclass]` becomes an opaque handle with `<Class>_free`, one wrapper per
  `#[pymethods]` method (`#[new]`, `#[staticmethod]`, `#[getter]`, `#[setter]`
  included) and accessors for the fields `#[pyo3(get, set)]` / `get_all` /
  `set_all` expose. Every entry point comes out of
  `rustcall_core::codegen::generate_wrapper`, the generator `#[julia]` has used
  since #279, so the string ABI, the `CResult`/`COption` aggregates and the
  per-wrapper panic channel are identical and the Julia emitters bind both
  kinds the same way. `write_bindings_to_file` takes the same path.

  A `PyResult<T>` becomes `RustResult{T, String}` whose error is always
  `RustCall.PYO3_OPAQUE_ERROR`: creating and dropping a `PyErr` without an
  interpreter is safe, but rendering one panics inside pyo3 and the panic
  crossing `extern "C"` aborts the process, so the generated code drops it
  without looking at it.

  A crate carrying **both** kinds of marker keeps both: the wrapper generates
  entry points for the PyO3 items and links the `#[julia]` ones the crate
  already exports, and one `@rust_crate` module exposes them together. The
  Rust path in generated calls is the crate's **library target** name
  (`[lib] name`), not its package name.

  The scan that feeds the generator runs under the configuration the wrapper is
  compiled with whenever Cargo could resolve it, so a `#[cfg]`-gated item that
  the requested feature set enables is wrapped rather than refused; a build that
  exposes nothing to PyO3 (every marker behind a feature that is off) falls back
  to the pre-#275 binding path instead of producing an empty cdylib.

  `@rust_crate` gains `features=` and `default_features=`, which select the
  feature set the wrapper is built against and are part of the artifact
  identity (`ArtifactId` kind `pyo3-wrapper`), together with the build
  environment the wrapper inherits (`artifact_build_env()`, the #282
  allowlist, which now captures the `PYO3_*` namespace, plus the contents of
  `PYO3_CONFIG_FILE`) and, for a `:link_libpython` build, the interpreter
  `PYO3_PYTHON` is pinned to — its path and what it reports about itself
  (`plan.interpreter_config`: implementation, version, ABI tag, library), so a
  Python upgraded in place is a different wrapper. That interpreter and the
  library directory are decided together (`python_link_source()`,
  `plan.interpreter`): a caller's own `PYO3_PYTHON` is honoured rather than
  replaced by the first `python3` on `PATH`, and the cfg probe follows the
  build profile (`pyo3_link_plan(crate; release = false)`). `#[pyo3(get)]` and
  `#[pyo3(set)]` are independent — a `set`-only field is a setter with no
  getter. A `#[pymethods]` method is boxed as the class only as a `#[new]` or
  a `Self` return, never for being named `new`; a class member whose own
  `#[cfg]` the scan could not decide is refused (`cfg_undecided`) like an
  item; `impl super::C` is resolved against the parent module (and a `use
  super::C` disambiguates a bare `impl C`) instead of falling back to a
  same-named local class; and the panic reader `<symbol>_take_panic` is a
  reserved symbol, so an item that would *be* one is reported as a
  `symbol_collision`. A `&str` returned by an item that takes a string leaves
  as an owned copy (it may point into the argument the wrapper built), a
  `Vec<T>` field gets no accessor (there is no owned-vector ABI on the Julia
  side yet), the cfg probe runs the crate as the wrapper's
  dependency rather than as its own Cargo root, and the feature set a caller
  asks for is honoured — and is in the artifact identity — on the plain
  `@rust_crate` path as well. The wrapper and the probe are built under the
  crate's own `target/` with its `Cargo.lock` and `[patch]` table carried
  over, so the crate's `.cargo/config.toml`, pins and overrides apply as they
  do to the crate (for a workspace member, from its workspace root, whose
  manifest and lockfile are then part of the member's artifact identity; a
  package the workspace `exclude`s is its own root; both generated manifests
  declare an empty `[workspace]` so they are roots of their own); the probe
  runs under the wrapper's panic policy and its memo follows the root's
  manifest and lockfile and pyo3's own configuration (`PYO3_*`, the contents
  of `PYO3_CONFIG_FILE`), so a changed Python is a new probe as it is a new
  artifact; a PyO3 crate that exposes nothing under the
  requested build falls back to the plain path **under that build's
  configuration**, so a `#[julia]` item the selected features disable is not
  bound; the wrapper's link options travel in a generated `build.rs` rather
  than in `RUSTFLAGS` (which `CARGO_ENCODED_RUSTFLAGS` overrides and which
  replaced a crate's `[build] rustflags`); a `std::`-anchored return type is
  never mistaken for a class of the same name; the string helpers a wrapper
  declares (`<owner>_RustCallOwnedString` and friends) are reserved per owner
  like every other symbol, as is the case-folded panic slot two items whose
  names differ only by case would share; on Windows, where there is no rpath,
  the plan records the interpreter's own `python3xy.dll`
  (`plan.runtime_libraries`) and the generated module opens it before the
  wrapper (`load_artifact!`'s `preload`), so a `PYO3_PYTHON` that is not on
  `PATH` loads; every project RustCall generates is built with its output
  pinned to its own `target/` (`CARGO_TARGET_DIR`), so an inherited
  `CARGO_TARGET_DIR` or a discovered `[build] target-dir` no longer turns a
  successful build into "Library not found after build"; an `async fn` is
  refused by the scan (`async_fn`) rather than wrapped as if it returned the
  value its future resolves to; a crate whose `[lib] crate-type` offers no
  `rlib` (a `["cdylib"]`-only PyO3 extension) is refused before the build with
  the one-line fix, instead of failing inside the generated wrapper; a package
  a workspace lists in `members` stays a member even under an `exclude`d
  directory, as Cargo has it; the plain `#[julia]` path scans the crate under
  the configuration it builds — profile and requested feature set — so a
  feature-gated item is bound exactly when the library exports it (hot reload
  already rescanned this way) — probed as the Cargo root when it is built as
  one (a `cdylib`) and as a wrapper's dependency otherwise, so the profile the
  probe sees is the profile the build applies; the cfg probe runs under the
  plan's interpreter (`PYO3_PYTHON`), as the wrapper build does; a
  `#[staticmethod]` whose Julia name and arity another item already defines —
  or a function named like a class — is refused (`julia_name_collision`)
  instead of silently replacing it; the generated `get_<field>` /
  `set_<field>!` helpers check the object is live, as `getproperty` /
  `setproperty!` do; and the conservative plan (Cargo could not resolve the
  crate) keeps the requested `features` / `default_features`, so the wrapper's
  dependency entry is the configuration asked for; a library root outside the
  package directory (`[lib] path = "../shared/lib.rs"`) and every file beside
  it are part of the artifact identity; a PyO3 crate whose requested build
  exposes nothing is bound through the same build-shaped probe as any plain
  crate; and a `#[pyo3(set)]` field's value is converted to the field's type
  before the setter is called, so `set_scale!(obj, 3)` on an `f64` field stores
  `3.0` rather than reinterpreting an integer register; and
  `PYO3_CROSS_LIB_DIR` or a `PYO3_CONFIG_FILE`'s `lib_dir` names the link
  directory ahead of any interpreter. Anything the generator cannot
  lower is reported with a reason (`unsupported_arg`, `unsupported_return`,
  `py_result_payload`, `cfg_undecided`) instead of being emitted — including a
  plain `Result` / `Option` on a `#[pymethods]` **method**, which the `#[julia]`
  method wrappers have never lowered either. `scan_report`
  gains a "wrapper crate exports" column naming each symbol. The generated
  `CResult_*` mirrors subtype `RustCall.FFIByValue`, the layout assertion #245
  requires and #295 enforces, exactly as the `#[julia]` path's do. New extractor
  subcommand `rustcall-extract wrap`; new example
  `examples/sample_crate_pyo3_optional`, a crate whose wrapper links no
  libpython at all.

- **`Result` and `Option` returns on `#[julia]` struct methods**
  ([#268](https://github.com/AtelierArith/RustCall.jl/issues/268)). A method
  returning `Result<T, E>` / `Option<T>` is now lowered exactly like a free
  function: the wrapper returns a `#[repr(C)]` `CResult_<Struct>_<method>` /
  `COption_<Struct>_<method>` aggregate (private fields, `MaybeUninit`
  payloads, `new` / `is_ok` / `is_some` / `ok` / `err` / `some` / `panicked`
  accessors) and Julia hands back a `RustResult` / `RustOption`. It used to
  return the `Result` as written — not FFI-safe — and the manifest reported
  `return_kind = plain`, so the Julia emitters raised under the default
  `FFI_STRICT = :error`. Both wrapper flavours (inline `rust"""` and the
  `@rust_crate` proc-macro) and all three Julia emitters (`src/structs.jl`,
  the in-memory `@rust_crate` emitter and `write_bindings_to_file`) now agree,
  with `#[cfg]` / `#[cfg_attr]` propagated to every generated item and the
  panic channel read before either payload is decoded.

- **`String` / `&str` payloads inside `Result` and `Option`**
  ([#268](https://github.com/AtelierArith/RustCall.jl/issues/268)). A string
  payload is lowered to the owned buffer the string ABI already uses —
  `<owner>_RustCallOwnedString { ptr, len, cap }`, released through
  `<owner>_free_rust_string` — so the `Result` lowering and the string lowering
  compose and `Result<String, String>` works. Julia copies the active payload
  out and releases it through the release function resolved in the **same**
  generation snapshot as the call; the inactive payload is never touched. This
  lifts the compile error `#[julia]` used to emit for a `String` payload on a
  free function too. A `&str` payload is copied rather than borrowed. Payloads
  the aggregate cannot carry (`Vec<T>`, `Box<T>`, …) are unchanged: a compile
  error on a free function, returned as written on a method.

### Changed
- **Manifest schema 5 → 6** (`RustCall.MANIFEST_SCHEMA_VERSION`,
  `rustcall_core::manifest::SCHEMA_VERSION`), bundling two changes that neither
  shipped separately ([#268](https://github.com/AtelierArith/RustCall.jl/issues/268),
  [#275](https://github.com/AtelierArith/RustCall.jl/issues/275) Phase 2).
  `Method.return_kind` now reports `result` / `option` where it always said
  `plain`, which is an **ABI change** for those methods and not merely a richer
  description: a schema-5 consumer would read a two-payload aggregate as the
  scalar it used to be. `Function` and `Method` also gain `ok_abi` / `err_abi` /
  `inner_abi`, which say whether a payload travels as an owned string buffer.
  Separately, a `py_*` entry can now be `exported` with a `return_abi`, a
  lowered `PyResult` reports the `i32` code in `err_type`, and the skip-reason
  vocabulary gains the four reasons the wrapper *generator* uses; a schema-5
  consumer would read a wrapper manifest as a scan and never call anything.
  Rebuild the extractor (`Pkg.build("RustCall")`) after upgrading.

- **Bindings format 5** ([#268](https://github.com/AtelierArith/RustCall.jl/issues/268)).
  A file written by `write_bindings_to_file` now imports
  `RustCall._result_payload`, which older RustCall versions do not define.
  Regenerate after upgrading.

- **The API reference is one page per group of source files**
  ([#288](https://github.com/AtelierArith/RustCall.jl/issues/288)).
  `docs/src/api.md` rendered every docstring in the package on one page, which
  hit Documenter's `size_threshold` twice and left 58 docstrings out of the
  manual altogether. It is now an index over `docs/src/reference/` — artifact
  identity and caching, the FFI type contract, compilation and codegen, the FFI
  manifest, Cargo projects and dependencies, external crates and hot reload,
  PyO3 crates, types/memory/ownership, generics and `#[julia]` functions,
  errors and load policy, and the deprecated LLVM path — each an
  `@autodocs` block per source file with an explicit `Pages` filter, so every
  `src/*.jl` is rendered on exactly one page and no docstring is left out.
  `size_threshold` is back near Documenter's default. Deep links into `api.md`
  itself still resolve; links to individual docstrings now point at the
  reference page of the defining file.

### Fixed
- **Metadata and documentation drift**
  ([#261](https://github.com/AtelierArith/RustCall.jl/issues/261)). The
  registry tarball no longer ships internal development artifacts
  (`docs/plans/`, `docs/design/`, `docs/superpowers/` and a force-added
  `benchmark/Manifest.toml`). This changelog states the supported Julia
  versions the way `Project.toml` and CI do and dates 0.1.0 by its General
  registration; `CLAUDE.md` no longer names the vendored `Cxx.jl/` / `julia/`
  trees removed in #215; `docs/src/status.md` drops its hand-counted
  inventory; the orphaned `docs/troubleshooting.md` is merged into the built
  page; `deploydocs` uses the lowercase owner; the ten test files headed
  "converted from `examples/...`" now say those files are gone; and the
  `__init__` warning explains that `rustc` is resolved through RustToolChain.jl
  (a `PATH` binary first, then the Artifacts toolchain) and how to diagnose a
  failure.
- **A module written by `write_bindings_to_file` no longer maps Cargo's output
  in place** ([#309](https://github.com/AtelierArith/RustCall.jl/issues/309)).
  Its `__init__` opens a private generation copy
  (`RustCall.loadable_library_copy`), as the in-memory `@rust_crate` path has
  since #289, so the next `cargo build` of the crate — hot reload, another
  binding path, a regeneration of the file — can overwrite the library, which
  Windows refuses for a mapped DLL ("Access is denied"; the order-dependent
  Windows CI failure in `test_hot_reload.jl`). The bindings format marker is
  `6`; regenerate written files after upgrading. The copy is named
  `<lib>.rustcall.<host>.<pid>.<generation>.<ext>` now, so two processes
  loading the same built library — two test workers, two sessions on one
  crate, two hosts sharing a volume — never pick the same copy name, which on
  Windows would have made the second fall back to mapping Cargo's output in
  place. Copies left behind by processes that no longer exist are swept the
  next time the library is copied (process liveness is checked on every
  platform, so a copy another live process has made but not yet mapped is
  safe), so an application that launches Julia repeatedly keeps only the
  live processes' copies beside the library; only names carrying the
  `rustcall` marker and this host's tag are ever candidates — another
  host's copy cannot be judged from this host's process table.
- **`test_cargo.jl`'s Cargo-cache assertions no longer race the parallel runner**
  ([#306](https://github.com/AtelierArith/RustCall.jl/issues/306)). The Cargo
  cache is a depot-level directory shared by every worker, and two testsets
  asserted on its whole contents — its size after a clear, and the number of
  libraries in it after one evaluation — so any other worker compiling a Cargo
  block in the meantime failed them. Both now run under a cache root of their
  own (`RUSTCALL_CACHE_DIR`), and the "exactly one key" assertion is also made
  key-specifically, which is what it actually means.

- **`extension-module` is no longer called unlinkable on Windows**
  ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275)). A DLL
  resolves every import at link time, so pyo3 links the interpreter's import
  library there regardless of the feature and the wrapper loads like any other
  `:link_libpython` build; only Unix leaves the symbols undefined.
  `RustCall.extension_module_is_linkable()` is the predicate — applied on the
  resolved path and on the conservative `Cargo.toml` fallback alike, so the two
  cannot disagree about one crate — and
  `pyo3_link_rustflags` no longer emits `-Wl,-rpath` — which `link.exe` rejects
  — on Windows, where the interpreter's DLL directory belongs on `PATH`
  instead.

- **A link plan whose `--print cfg` probe failed no longer claims to be
  resolved** ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275)).
  `cargo tree` can answer while `cargo rustc -- --print cfg` does not; the plan
  then had an empty `cfg_text` with `resolved = true`, and `scan_report`
  silently fell back to a lenient scan. Such a plan is now `resolved = false`
  with the probe failure in its `reason`.

- **macOS framework builds of Python get the right rpath**
  ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275)). A framework
  build is linked as `@rpath/Python3.framework/Versions/3.x/Python3`, so
  `python_library_dir()` now returns the directory *containing* the
  `.framework` rather than `LIBDIR`, which sits one level inside it and
  produced a cdylib that could not be loaded.

- **`#[pymethods]` matching keeps the anchor of a written path**
  ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275)).
  `impl crate::a::C` inside module `m` was matched against `m::a::C` first,
  because the `crate::` prefix was stripped before matching; when both classes
  existed the block attached to the wrong one. `crate::` now resolves only at
  the crate root, `self::` only in the enclosing module, and the same
  distinction applies to `use` paths.

- **Re-aliasing a library under a name it already has no longer declares it
  dead** ([#291](https://github.com/AtelierArith/RustCall.jl/issues/291)).
  `alias_artifact!` retired whatever was registered under the target name —
  correct when that name pointed at a *different* image, and destructive when
  it already pointed at this one, because then the retired flag is this image's
  own. Every object holding it went inert, its destructor never ran, and every
  `alive[]` check turned a working call into an error.
  `_alias_reloaded_library` runs on every `_resolve_lib`, so the second call
  through one precompiled module reached exactly this. Aliasing a name that
  already names the same handle with the same flag is now a no-op for
  liveness; aliasing over a name that pointed elsewhere still retires it.

- **One liveness flag per image, even under two live names**
  ([#291](https://github.com/AtelierArith/RustCall.jl/issues/291)). Loading the
  same path under a second name while the first is still registered minted a
  second flag for one image — `dlopen` refcounts and answers with the same
  handle, so it is one lifetime with two registry rows. `unload_artifact!`
  retires the image with **one** of those flags and drops the other from
  `ARTIFACT_ALIVE` without ever flipping it, so every object that captured the
  dropped flag believed itself live after `close = true` had unmapped the code
  its destructor calls into. `load_artifact!` now adopts the flag the image
  already has (`registered_alive_for_handle`).

- **Invalid UTF-8 in a string argument now raises instead of being silently
  substituted** ([#246](https://github.com/AtelierArith/RustCall.jl/issues/246)).
  A Julia `String` is a byte vector and need not be UTF-8; Rust's `&str` is
  UTF-8 by definition. The generated wrapper built the `&str` with
  `String::from_utf8_lossy`, which *replaces* an invalid byte with U+FFFD — so
  `f(String([0xff, 0xfe]))` ran the Rust function on data the caller never
  passed and returned a wrong answer with no error anywhere.

  The check now happens on the Julia side, before the pointer exists, and
  raises a `RustError` naming the argument (by its Rust name), the function it
  belongs to and the first offending byte. The Rust-side `from_utf8_lossy`
  stays as defence in depth: a `&str` built from invalid bytes is undefined
  behaviour, and nothing may reach it. Free functions, struct methods and
  monomorphized generics share the path; a generic names the argument by
  position (`argument #1`), since a `FunctionInfo` records ABIs and not
  parameter names. `BINDINGS_FORMAT_VERSION` goes to `3`: a written-out
  bindings file now imports `RustCall.ffi_string_argument`, a name an older
  RustCall does not have, so regenerate after upgrading.

### Breaking
- **The compilation cache moved out of `~/.julia/compiled/`**
  ([#252](https://github.com/AtelierArith/RustCall.jl/issues/252)). RustCall
  used to write compiled `.dylib`/`.so`/`.dll` files, their `.sha256`
  checksums, the `metadata/` tree and the Cargo build products into
  `$(DEPOT_PATH[1])/compiled/vX.Y/RustCall` — **Julia's own package precompile
  directory**, which Pkg neither tracks nor garbage-collects for foreign files
  and which is read-only in common deployments (shared/HPC depots, baked
  container images), where `mkpath` threw and RustCall was simply unusable.

  `RustCall.get_cache_dir()` is now a [Scratch.jl](https://github.com/JuliaPackaging/Scratch.jl)
  space, `<depot>/scratchspaces/<RustCall UUID>/cache-v2` — writable by
  construction, accounted for by `Pkg.gc()`, and removable with
  `Pkg.Scratch.clear_scratchspaces!`. The space name folds in
  `CACHE_FORMAT_VERSION`, so RustCalls that disagree about the on-disk layout
  keep separate trees. Three consequences:

  - **Nothing is written under `~/.julia/compiled/` any more.** That directory
    is read *only* by the opt-in legacy sweep and is never created by RustCall.
    `RustCall.clear_cache(sweep_legacy = true)` removes the tree the old layout
    left behind (its `v<n>` and `cargo`/`metadata` directories and loose files
    matching the exact pre-#278 naming) and nothing else — Julia's `.ji` and
    native images in the same directory are left alone.
  - **A read-only `DEPOT_PATH[1]` is no longer fatal.** `Scratch` defaults to
    the first depot; RustCall scans `DEPOT_PATH` for the first *writable* one.
    With no writable depot at all the failure is a named `RustError` naming the
    depots tried, not an `IOError` from inside a file copy.
  - **`RUSTCALL_CACHE_DIR` overrides the location entirely**, for air-gapped
    and CI setups that need the cache in a specific place.

  Existing caches are not migrated: the first compile after upgrading rebuilds.

- **Passing a Julia struct to Rust by value is opt-in**
  ([#245](https://github.com/AtelierArith/RustCall.jl/issues/245)).
  `is_supported_arg_type(::Type{T}) = isbitstype(T)` accepted *any* isbits Julia
  struct or tuple as a by-value argument or return, and `ccall_arg_type` passed
  it through unchanged — assuming its layout matched the Rust side's. Rust's
  default `repr(Rust)` layout is explicitly unspecified (fields may be
  reordered, niches exploited), so an unannotated struct that works today is a
  silent miscompile waiting for a toolchain upgrade.

  An aggregate now needs a layout assertion, and `RustCall.register_ffi_struct`
  is where it is made:

  ```julia
  struct Point            # matches #[repr(C)] pub struct Point { x: f64, y: f64 }
      x::Float64
      y::Float64
  end
  @register_ffi_struct Point
  ```

  Without it the call raises a `RustError` naming the type, its fields and the
  opt-in. Registration is for **concrete types only**: `Point{Float64}` says
  nothing about `Point{Int32}` — a parameter changes sizes, alignment and
  register classes — and registering the `UnionAll` `Point`, or an abstract
  type, is an error rather than a family-wide claim. `@register_ffi_struct` is
  the form to use at a package's top level: it expands in the calling module, so
  the method it defines is carried by that package's precompile cache whatever
  `T` is — including a `Tuple`, whose `parentmodule` is `Core` and for which the
  function form has no home but RustCall itself. Scalars, pointers,
  `Cstring`, `Char` and
  `Bool` are unaffected — their ABI is their width. So are the wrappers
  RustCall generates from a `#[julia] struct`, which cross as opaque handles,
  and RustCall's own `#[repr(C)]` mirrors: `CRustString`, `CRustSlice` and
  friends have `ffi_by_value_layout` methods in the package, and the
  `CResult_<fn>` / `COption_<fn>` aggregates the wrapper generators emit
  subtype `RustCall.FFIByValue`. The assertion is a **method**, defined in the
  module that owns the type, so `register_ffi_struct` at a package's top level
  is carried by that package's precompile cache and holds in every later
  session — a mutated global would not be. `unregister_ffi_struct` withdraws an
  assertion; `repr_c = false` is rejected, because then there is nothing to
  assert. The supported-type matrix and the opt-in are documented on the FFI
  type contract page. `BINDINGS_FORMAT_VERSION` goes to `4`: a written-out
  bindings file now imports `RustCall.FFIByValue`, a name an older RustCall does
  not have, so regenerate after upgrading.

- **A `::T` return annotation may no longer contradict the manifest**
  ([#245](https://github.com/AtelierArith/RustCall.jl/issues/245)). `@rust
  f(x)::Float64` on a function the manifest records as `-> i32` used to win, and
  the `ccall` then read a 32-bit return slot as a `Float64` — silent garbage.
  An annotation supplies a return type RustCall does not know; when one *is*
  recorded, a differing annotation raises a `RustError` naming both types.
  Agreement is *the same `ccall` return slot*, not the same Julia type — the
  manifest records the slot while an annotation names the surface type, so
  `::Char` and `::UInt32` both agree with a `-> char` and `::Int32` does not.
  Annotations on symbols with no recorded type are unchanged. Convert on the
  Julia side if you wanted the other type.

- **One load/registration path** ([#277](https://github.com/AtelierArith/RustCall.jl/issues/277),
  Phase B). Twelve `dlopen` sites with four different flag sets and eight
  open-coded `RUST_LIBRARIES[...] = ...` writes became one:
  `RustCall.load_artifact!` (`src/loadpolicy.jl`), with `unload_artifact!` and
  `alias_artifact!` as the reverse and the aliasing operations.
  `scripts/lint_load_path.sh` keeps it that way in CI. Five user-visible
  consequences:

  - **Every artifact is `RTLD_LOCAL` now**
    ([#250](https://github.com/AtelierArith/RustCall.jl/issues/250)). A
    compiled block no longer publishes its symbols into the process-global
    namespace, so two `rust"""` blocks that both export `f` stop shadowing one
    another and which one a call reaches no longer depends on load order. It
    also stops depending on whether the block happened to declare
    `// cargo-deps:`, which used to flip the same construct from `RTLD_LOCAL`
    to `RTLD_GLOBAL`. Calling across blocks does not need global symbols —
    `@rust f(...)` searches the loaded libraries by handle. Code that relied
    on the old behaviour can set `RUSTCALL_DLOPEN_GLOBAL=1` for one minor
    release, with a warning; the variable will be removed. On Windows nothing
    changes: `LoadLibrary` has no LOCAL/GLOBAL distinction.

  - **A Rust panic is now a catchable Julia exception**
    ([#244](https://github.com/AtelierArith/RustCall.jl/issues/244)). A
    `panic!`, a failed `assert!`, an `unwrap()` on `None` or an out-of-bounds
    index inside a `#[julia]` function raises `RustCall.RustPanicError` with
    the panic message, and the Julia session survives — it used to abort the
    process. Every generated `extern "C"` wrapper runs the body inside
    `catch_unwind` and exports a `<symbol>_take_panic` channel Julia reads
    after each call.

    **This changes what RustCall builds, so the first run after upgrading
    recompiles everything.** `-C panic=abort` is gone from the direct-`rustc`
    path and `panic = "unwind"` is pinned in every `Cargo.toml` RustCall
    generates and in `CARGO_PROFILE_<PROFILE>_PANIC` in the environment it
    passes to Cargo — `catch_unwind` can only catch a panic that unwinds, and
    an inherited `CARGO_PROFILE_RELEASE_PANIC=abort` would otherwise silently
    disable the boundary. Two cases still abort, both visible from the source
    and documented in `docs/src/panics.md`: a raw `#[no_mangle] extern "C" fn`
    you wrote yourself (RustCall generates no wrapper for it, so there is no
    boundary — add `#[julia]`), and a `@rust_crate` crate whose own profile
    pins `panic = "abort"`.

  - **Finalizers of inline `#[julia]` structs now free the Rust allocation**
    ([#249](https://github.com/AtelierArith/RustCall.jl/issues/249)). They
    used to leak — the free was disabled with a "diagnose segfault" comment —
    while the same construct from a `@rust_crate` crate freed. If your code
    depended on an inline struct's Rust object outliving its Julia wrapper,
    keep a reference to the wrapper or use `GC.@preserve`. The finalizer is
    safe to run by construction: it captures the destructor pointer and the
    library's liveness flag at construction time, so it takes no lock,
    resolves no symbol and logs nothing; a failure is counted
    (`RustCall.finalizer_failure_count()`). A method or field access on a
    finalized object now raises instead of dereferencing `C_NULL`, and an
    object whose library was unloaded goes inert rather than calling into a
    closed image.

  - **Libraries are retired, not closed.** A hot reload replacing a library
    and `unload_library` dropping one both remove everything that *reaches*
    the library and leave the image mapped. A call that started a moment
    earlier may still be inside it, and closing it there is a
    use-after-`dlclose`; RustCall has no per-call reader pin, and adding one
    would put two atomics on every FFI call. The image costs a few hundred
    kilobytes until you say it is safe to reclaim:
    `unload_library(name; close = true)` or
    `unload_all_libraries(; close = true)`. `RustCall.retired_handles()` lists
    what is waiting.

    While an image is retired its objects keep working — a finalizer holds its
    own image's destructor and that image is still mapped, so an object
    allocated before a reload still frees through the code that allocated it.
    Closing is the moment objects of that image become inert (they leak rather
    than jumping into unmapped code), so `close = true` says both "no call is
    in flight" and "I accept that surviving objects will not be freed".

  - **A failed hot reload keeps the previous library**
    ([#255](https://github.com/AtelierArith/RustCall.jl/issues/255)). The
    rebuild, the rescan and the `dlopen` all complete before anything is
    swapped, so saving a file with a compile error leaves the loaded library
    working instead of emptying the registry; the error is reported once per
    distinct failure rather than on every watch tick. Each reload opens its own
    `<lib>.<generation>.<ext>` copy, which is what makes reloading a *loaded*
    library work on Windows. The watcher is event-driven
    (`FileWatching.watch_folder`) with a 100 ms debounce instead of an mtime
    poll, so an idle watch costs nothing and a burst of saves is one rebuild;
    `enable_hot_reload(...; poll = true)` restores polling for filesystems the
    kernel will not watch.

  - **`unload_library` now purges everything a library owns.** Its
    `RUST_LIBRARIES` entry and pointer cache, its symbol mappings and
    return-type hints, its `FUNCTION_REGISTRY` rows, the monomorphizations
    whose pointers point into it, its `@irust` memos and its panic channels —
    and it flips the library's liveness flag, retiring objects it produced. An
    `@irust` snippet no longer leaves a stale memo behind. `@rust_crate`
    libraries are visible to it for the first time: the generated module
    publishes its handle through the loader instead of keeping it only in a
    module-local `Ref`.

### Changed
- **A call cannot straddle a hot reload.** Every FFI entry point resolves what
  it needs — function pointer, panic channel, owned-`String` release function,
  struct destructor, liveness flag and **return ABI** — in one locked step and
  then uses only that snapshot, so a library replaced mid-call can no longer
  have the call enter the retired image while the `free`, the panic channel or
  the return type belongs to its replacement. In practice this fixes a reload
  racing a call that returns a `String` (the buffer was released through the
  wrong image's allocator), a reload racing a struct construction (the object
  could capture one generation's destructor and another's liveness flag), and a
  reload racing an untyped `@rust` call (the result of one generation could be
  read with another's return type — a scalar as a struct). A cached record is a
  snapshot too: a monomorphized generic's `FunctionInfo` carries the panic
  channel and the image it was built against, so a panic is still raised after
  its library has been unloaded, rather than returning the wrapper's zero
  sentinel as a result. `scripts/lint_generation_snapshot.sh` fails CI if a new
  entry point resolves a piece on its own. A constructor is part of this: the
  object it returns captures the destructor and the liveness flag of the
  generation that **allocated** it, taken from the constructor call's own
  snapshot, so a reload between the allocation and the object's construction
  can no longer bind a pointer from the retired image to the replacement's
  `free`. The same holds for a **generic** struct: its constructor resolves the
  instantiated destructor in the same step that allocates, preferring the
  constructor's own image and otherwise taking the destructor's own image's
  flag, so the flag always describes the image the finalizer will call into.
  (Each generic instantiation is still its own artifact, so a generic object
  can be allocated by one image and freed through another: [#291](https://github.com/AtelierArith/RustCall.jl/issues/291).)
- Two `rust"""` blocks in **one module** may no longer export the same name.
  The second block raises, naming the symbol and the library that already owns
  it. Previously the second Julia wrapper silently replaced the first while
  both libraries stayed loaded ([#250](https://github.com/AtelierArith/RustCall.jl/issues/250)).
- A generated wrapper resolves through **its own module's** library rather than
  through whichever block was compiled last in the session, so two modules that
  each define `add` call their own `add`.
- A generated `@rust_crate` module keeps its state in one immutable record
  (`_LIB_GEN`) instead of separate `_LIB_HANDLE` / `_LIB_ALIVE` `Ref`s, so a
  wrapper reads handle, liveness flag and generation as one value. Regenerate
  bindings files after upgrading (`# Bindings format: 2`).
- Bindings files written by `write_bindings_to_file` carry
  `# Bindings format: 2`. Files generated by an older RustCall still work but
  do not get the unload, panic or lifetime guarantees — regenerate after
  upgrading.
- **One mapped image, one liveness flag — across an unload and a reopen.**
  `unload_library(name)` retires an image without closing it, so it stays
  mapped and the objects it produced hold its flag; the next load of the same
  path gets that same image back from the loader and now keeps that same flag,
  instead of minting a fresh one that nothing would ever flip.
- **Closing a retired image closes what the retirement owned**, recorded when
  it was retired, rather than draining the live counter — a task reopening the
  same path while the close runs keeps its own reference.
- **An idle hot-reload watcher now really is idle.** `watch_folder` returning
  "the wait expired" was treated as a filesystem event, so a watched project
  with nothing happening still `stat`ed every source file every interval. A
  timeout is now ignored and only a real event triggers a scan;
  `RustCall.source_scan_count()` exposes the number so the behaviour is
  checkable. `enable_hot_reload(...; poll = true)` still polls, as it must.
- **The crate `#[cfg]` probe is memoized on what decides it**, not on the crate
  path alone: its `Cargo.toml`, its `build.rs`, and the `.cargo/config.toml`
  chain. Turning a default feature on or off between two reloads used to reuse
  the previous answer, so the rescan described `#[cfg]` items the new build did
  not have and registered the wrong ABI for them. A **hot reload re-probes
  unconditionally** rather than trusting that digest: a `build.rs` can emit a
  different `cargo::rustc-cfg` from inputs no digest can enumerate, and a
  reload has just run a full build anyway.
- **Closing a retired image drains its loader references.** One file loaded
  under two names is one image with two `dlopen`s; retirement discarded the
  record after a single `dlclose`, leaving the last reference unreclaimable and
  the image mapped for the life of the process. `close_retired_handles!` and
  `unload_all_libraries(; close = true)` now close once per owned open.
- Hot reload no longer needs `Cargo.lock` to be stable. The check that the
  sources did not change under the rescan hashes the scan's own inputs (the
  Rust sources and `Cargo.toml`); it used to hash the whole crate, including
  the `Cargo.lock` that the very `cargo build` it straddles writes, so on a
  fresh checkout the rescan was always discarded and the reloaded library was
  registered with no symbol mappings.
- `RustCall.scan_crate` accepts `cfg` / `cfg_text`, and hot reload probes the
  crate's real build configuration (`cargo rustc --release --lib -- --print
  cfg` in the crate) before rescanning, so mutually exclusive
  `#[cfg(feature = ...)]` variants of one `#[julia] fn` collapse to the one
  that was built and its return type is registered. An unavailable probe falls
  back to the previous lenient scan.
- `RustCall.load_cached_library` returns the verified cache *path* instead of
  opening the library.
- A `@rust_crate` library's registry name includes its build profile, so a
  `build_release = false` and a `build_release = true` module of one crate are
  two entries rather than one that clobbers the other.
- Ownership operations (`RustBox`, `RustRc`, `RustArc`, `RustVec`) refuse to
  construct a value when the helper library is missing, naming the operation
  and the `Pkg.build("RustCall")` that fixes it.

### Added
- **PyO3 crates without a RustCall attribute: the scan and the link plan**
  ([#275](https://github.com/AtelierArith/RustCall.jl/issues/275), Phases 1 and
  1.5). A crate that only carries `#[pyfunction]` / `#[pyclass]` /
  `#[pymethods]` is now reported by the extractor:
  `RustCall.scan_report(crate_path)` prints which items a wrapper crate will be
  able to wrap and why the others cannot be, and `RustCall.scan_crate` returns
  them in the new `pyo3_functions` / `pyo3_structs` fields of `CrateInfo`.
  Manifest schema 5 adds a PyO3 `attribute` origin (`py_function`, `py_class`,
  `py_methods`, `py_module`), `vis`, `skip_reason`, `python_name` and
  `accessor` columns, and the `py_result` return kind. An item carrying both
  `#[julia]` and `#[pyfunction]` is owned by `#[julia]`, which already exports
  `rustcall_<name>` (#279), and is skipped by the scan.
  `RustCall.pyo3_link_plan(crate_path)` decides from `Cargo.toml` alone whether
  a wrapper cdylib can be linked and loaded — `:python_free`,
  `:link_libpython` or `:unlinkable` — and `RustCall.pyo3_link_rustflags`
  turns that into build flags or a precise `RustError`. Generating the wrapper
  crate is Phase 2 and is not implemented yet. `#[julia_pyo3]` is unchanged.
  See `docs/src/pyo3.md` and `examples/sample_crate_pyo3_only`.
- `docs/src/panics.md`: the panic semantics matrix, the symbol-visibility rule
  and the object-lifetime/allocator contract.
- `test/test_panics.jl`, `test/test_finalizers.jl`,
  `test/test_load_conformance.jl`, `test/test_hot_reload_transaction.jl`,
  `test/test_pyo3_link_plan.jl`.


### Breaking
- **One artifact identity** ([#278](https://github.com/AtelierArith/RustCall.jl/issues/278),
  Phase B). Twelve places answered "which compiled artifact corresponds to this
  request?", each with its own component list, its own concatenation format and
  its own truncation. Every one of them now builds a `RustCall.ArtifactId` and
  calls `artifact_key` (`src/artifact_id.jl`). Five user-visible consequences:

  - **The cache directory is now `.../RustCall/v2`.** `CACHE_FORMAT_VERSION = 2`
    namespaces the on-disk layout, and `get_metadata_dir()` /
    `get_cargo_cache_dir()` nest under it. Nothing is silently served from the
    old layout; `clear_cache()` and `cleanup_old_cache()` sweep older `v*`
    siblings and the unversioned pre-#278 tree best effort. A *newer* sibling is
    left alone.
  - **Every on-disk key changes value**, so the first build after upgrading
    recompiles. Keys are the full 64-hex digest now: truncation happens only in
    `artifact_short_id`, and only for names a human reads (library names,
    temporary Cargo project directories, log lines).
  - **A missing toolchain is an error on compile paths.** `_get_rustc_version()`
    (a bare `rustc` from `PATH`, degrading to the string `"unknown"`) and
    `_get_cargo_version()` are deleted; keys name the compiler
    `RustToolChain.rustc()` / `cargo()` resolves to
    (`RustCall.artifact_compiler_identity()`), and an unidentifiable compiler
    raises `RustError` instead of caching everything under one sentinel
    ([#252](https://github.com/AtelierArith/RustCall.jl/issues/252)).
    `toolchain_fingerprint()` itself stays total.
  - **Monomorphized names changed.** A specialization is now
    `<name>_<types in declaration order>_<8 hex>` and its library is
    `rust_generic_<16 hex>`. The old key sorted the type *values*, so
    `pair<T=i32, U=i64>` and `pair<T=i64, U=i32>` shared one cache entry and the
    second call ran the first one's machine code
    ([#247](https://github.com/AtelierArith/RustCall.jl/issues/247)); each
    instantiation also used to register under one colliding `RUST_LIBRARIES`
    key.
  - **`RustBlockSnapshot` has an `artifact_schema` field** (defaulted by an
    inner constructor). A snapshot from an older RustCall is recomputed and then
    aliased, never an error.

- **One FFI type contract** ([#276](https://github.com/AtelierArith/RustCall.jl/issues/276)).
  Five independent tables decided "what does this Rust type mean at the C
  boundary?", and they disagreed with each other. Every call site now reads
  `src/ffi_contract.jl`; `_rust_type_to_julia_conversion_type`,
  `_rust_type_to_julia_type_symbol`, `_RUST_PRIMITIVE_TO_JULIA`,
  `rust_to_julia_type_sym`, `julia_sym_to_type` and `RUST_TO_JULIA_TYPE_MAP`
  are deleted. Four user-visible consequences:

  - **Manifest schema 3 → 4.** `Function.return_abi`, `Field.abi` and
    `Method.returns_boxed_struct` are new; the `has_*_string_helper` booleans
    stay for one release, derived from `return_abi`. Run
    `Pkg.build("RustCall")` to rebuild the extractor — a stale binary is
    refused with that hint. Every cache key includes the schema, so artifacts
    are rebuilt.
  - **`str` and `*const u8` are no longer `Cstring`.** `rusttype_to_julia("str")`
    is `RustStr` and `rusttype_to_julia("*const u8")` is `Ptr{UInt8}`. A Rust
    `str` is an unsized UTF-8 slice reached through a `(ptr, len)` fat pointer
    and a `*const u8` is a plain byte pointer; neither is a NUL-terminated C
    string, and treating them as one is
    [#246](https://github.com/AtelierArith/RustCall.jl/issues/246).
    `julia_to_c_type(::Type{RustString})` / `(::Type{RustStr})` are gone for the
    same reason.
  - **Unknown types raise instead of becoming `Any`.** A type the contract
    cannot describe now stops wrapper generation with a message naming the
    signature. `RustCall.FFI_STRICT[]` selects `:error` (default), `:warn` (one
    warning per signature, then `Any` — the pre-#276 behaviour, kept for one
    minor release) or `:none`. `write_bindings_to_file(...; strict = :warn)` and
    `emit_crate_module_code(...; strict)` thread it explicitly, so concurrent
    calls with different settings do not interfere. Monomorphized generic
    returns obey it too; they used to become `Any` silently.
    Generated crate bindings also change text: `usize` is
    spelled `Csize_t`, `*mut i32` is `Ptr{Int32}`, and a `String` field is read
    as an owned buffer rather than `Any`.
  - **A `String` field on the crate path is lowered.** Its getter returns an
    owned `<Struct>_RustCallOwnedString` buffer released through
    `<Struct>_free_rust_string`, as the inline path already did; it used to be
    read as `Any` and leaked
    ([#246](https://github.com/AtelierArith/RustCall.jl/issues/246)).

### Changed
- Cargo-backed blocks fold the **effective Cargo configuration** into the key:
  the project-local `.cargo/config.toml` chain Cargo searches, not only
  `$CARGO_HOME/config.toml` (`RustCall._cargo_config_digest(env; dir)`).
- Local **path dependencies are identified by content**, so editing one rebuilds
  while moving the checkout does not. Every byte of every input is read on every
  call — file contents are never memoized, because a `(mtime, size)` stamp can
  alias distinct contents and the cost of being wrong is running the wrong
  machine code. What *is* memoized is the resolved dependency graph (the
  `cargo tree` process spawn), validated against the **content digests** of
  every manifest that can decide the graph — each crate's `Cargo.toml` /
  `Cargo.lock` *and* the workspace root each crate belongs to, since a member
  can inherit a path from `[workspace.dependencies]` in a manifest that is not
  a package at all — including one named by an explicit
  `[package] workspace = "../elsewhere"`, which need not be an ancestor. A block
  that declares no `path =` dependency never resolves a graph, so a warm
  `rust"""` re-evaluation spawns no `cargo tree`.
- `clear_cache` gains `sweep_legacy` (default `false`). RustCall's cache root is
  `.../compiled/vX.Y/RustCall`, which is **Julia's own precompile directory for
  RustCall** — its `.ji` and native images live there. The pre-#278 layout's
  loose files are removed only on explicit request and only when they match the
  exact naming that layout used; `cleanup_old_cache` never removes them at all,
  and nothing else in that directory is ever touched.
- `build_cargo_project_cached(project, id::ArtifactId; ...)` takes the artifact
  identity instead of a code-hash string, and uses `artifact_key(id)` unchanged:
  a Cargo block has exactly one key for its in-memory name, its disk lookup, its
  build and its save. The effective Cargo configuration is folded in by the
  caller, once, so a `.cargo/config.toml` change rebuilds instead of matching
  the pre-change binary. A profile disagreeing with the identity is an error.
- `generate_cache_key` and `is_cache_valid` take a `cfg_text` keyword, so the
  disk key and the in-memory library name of a `rust"""` block are one value.
- New CI lint: `scripts/lint_artifact_identity.sh` fails when Julia source
  outside `src/artifact_id.jl` concatenates key material, truncates a digest, or
  names an artifact with Julia's session-randomized `hash()`.


### Deprecated
- `call_rust_function_infer` guessed the **return** type from the type of the
  **first argument** — `Float64` for `fn f(x: f64) -> i32`, `Cstring` for a
  string argument, `Int64` otherwise. None of that is derivable from an
  argument, and reading a return slot at the wrong width is undefined
  behaviour. It now emits a `Base.depwarn` and raises a `RustError` naming the
  fix ([#245](https://github.com/AtelierArith/RustCall.jl/issues/245),
  [#246](https://github.com/AtelierArith/RustCall.jl/issues/246)). Pass the
  return type: `call_rust_function(func_ptr, T, args...)`, or annotate the call
  site `@rust f(x)::T`. `@rust f(x)` on a function with no manifest-recorded
  return type raises with the same advice instead of guessing.

### Fixed
- `i128`, `u128`, `char`, the `std::os::raw` aliases and raw pointers cross the
  boundary correctly in every position — free functions, methods, struct fields
  and monomorphized generics. `char` crosses as its `UInt32` Unicode scalar
  value and is converted back to a Julia `Char` — never reinterpreted from
  Julia's left-aligned UTF-8 bit pattern — in both directions and on every path,
  including monomorphized generics, whose `ccall` signature now comes from the
  slots the manifest recorded rather than from the runtime Julia argument types.
  A slot that is not a Unicode scalar value is refused rather than turned into
  an invalid `Char`. `Result<char, E>` and `Option<char>` payloads convert too:
  the `CResult_*` / `COption_*` field is declared with the C slot Rust stored
  and the active payload is read back as its surface type
  ([#245](https://github.com/AtelierArith/RustCall.jl/issues/245)). The one
  exception is `i128` / `u128` on `x86_64-pc-windows-msvc`, where MSVC has no
  native 128-bit integer and Rust and Julia disagree on how `extern "C"` passes
  one (rust-lang/rust#54341) — a platform ABI mismatch no Julia-side mapping can
  fix.
- Small-integer and platform-sized struct fields (`u16`, `usize`, …) resolve to
  their own type instead of `Any`
  ([#245](https://github.com/AtelierArith/RustCall.jl/issues/245)).
- Every owned string return names the symbol that releases it, and that symbol
  is resolved inside the library that allocated the buffer — so two libraries
  exporting the same `<owner>_free_rust_string` no longer free through each
  other's allocator
  ([#246](https://github.com/AtelierArith/RustCall.jl/issues/246),
  [#249](https://github.com/AtelierArith/RustCall.jl/issues/249)).

- `#[julia]` is **additive**: the annotated item is kept exactly as written
  (minus the attribute itself) and the `extern "C"` entry point is emitted
  *next to it* under a distinct symbol
  ([#279](https://github.com/AtelierArith/RustCall.jl/issues/279)).
  The export-symbol scheme, documented at the top of
  `deps/rustcall_core/src/codegen.rs`, is:

  | generated item | symbol |
  |---|---|
  | free function `f` | `rustcall_f` |
  | method / constructor `Struct::m` | `rustcall_Struct_m` |
  | specialized generic instantiation `f_i32` | `rustcall_f_i32` |
  | destructor / accessors / clone | `Struct_free`, `Struct_get_x`, `Struct_set_x`, `Struct_clone` (unchanged) |
  | `Result` / `Option` payloads | `CResult_f`, `COption_f` (unchanged) |
  | string buffers | `<owner>_RustCallOwnedString`, `<owner>_free_rust_string`, `<owner>_RustCallBorrowedString` (unchanged) |

  Nothing changes for Julia users: `add(1, 2)`, `@rust add(...)`, `@rust_crate`
  and `write_bindings_to_file` all go through the manifest's `symbol` field.
  What changes is that `fn shout(s: String) -> String` still *exists* in Rust
  after expansion, so `#[julia]` now composes with `#[pyfunction]`, with
  in-crate callers, with `#[test]`s and with `pub use` re-exports. Anyone who
  `dlsym`ed the Rust name directly must switch to the `rustcall_`-prefixed
  symbol, and any generated bindings (e.g. a `write_bindings_to_file` module)
  must be regenerated.
- The FFI manifest schema is now version 3
  ([#279](https://github.com/AtelierArith/RustCall.jl/issues/279)):
  `Function.symbol` and `Method.symbol` differ from `name` for *every* wrapped
  item, not only for generic instantiations. A RustCall.jl expecting schema 2
  refuses a version-3 manifest and vice versa. **Rebuild the extractor** with
  `Pkg.build("RustCall")` after updating.
- The FFI manifest schema was version 2 (`rustcall_core::manifest::SCHEMA_VERSION`,
  `RustCall.MANIFEST_SCHEMA_VERSION`): the string ABI columns `abi`,
  `return_abi` and the `has_owned_string_helper` / `has_borrowed_string_helper`
  flags change how the exported symbols must be called, so a RustCall.jl that
  expects schema 1 refuses a version-2 manifest and vice versa. Rebuild the
  extractor with `Pkg.build("RustCall")` after updating.

### Deprecated
- The LLVM IR integration path is deprecated and will be removed in a future
  breaking release ([#265](https://github.com/AtelierArith/RustCall.jl/issues/265)).
  Affected entry points emit `Base.depwarn` and keep working unchanged:
  `@rust_llvm`, `compile_and_register_rust_function`, `get_registered_function`,
  `compile_rust_to_llvm_ir`, `load_llvm_ir`, `get_function_signature`,
  `get_or_compile_function`, `OptimizationConfig`, `set_default_opt_config`,
  `optimize_module!`, `optimize_function!`, `optimize_for_speed!`,
  `optimize_for_size!`, `optimize_balanced!`.
  Reasons: `@rust_llvm` performs the same function-pointer `ccall` as `@rust`,
  and rustc tracks a newer LLVM than the one bundled with Julia, so the emitted
  IR cannot be parsed reliably. Use `@rust` instead.

### Added
- `#[julia]` functions accept `String` / `&str` arguments and return `String` /
  `&str` ([#242](https://github.com/AtelierArith/RustCall.jl/issues/242)):
  the wrapper uses the same `(ptr, len)` ABI and `<fn>_RustCallOwnedString` /
  `<fn>_free_rust_string` helpers as struct methods, the manifest records
  `has_owned_string_helper` / `has_borrowed_string_helper`, and the Julia
  wrappers (inline blocks and `@rust_crate`) convert transparently.
- CI/CD pipeline with GitHub Actions
- Julia 1.12 or later is required (`Project.toml` compat `julia = "1.12"`);
  CI tests the current stable release (`version: '1'`) on Linux, Windows and
  macOS, plus one 4-thread Linux job
- Cross-platform testing (Linux, macOS, Windows)
- CompatHelper integration for dependency updates
- TagBot integration for automated version tagging

### Changed
- Rust syntax is no longer parsed on the Julia side. `rust"""` blocks,
  `@rust_crate` and generics go through the `rustcall-extract` CLI
  (`deps/rustcall_core`, `deps/rustcall_extract`), which emits a TOML FFI
  manifest ([#264](https://github.com/AtelierArith/RustCall.jl/issues/264),
  [#266](https://github.com/AtelierArith/RustCall.jl/pull/266)).
- `#[cfg(...)]`-disabled items are no longer reported by the FFI manifest:
  `rustcall-extract manifest`/`expand` take `--cfg-file` (the output of
  `rustc --print cfg`), evaluate `all`/`any`/`not`/`name`/`name = "value"`
  predicates on items, impl methods, struct fields and inline modules, and drop
  what rustc would not compile. Every reported item records its predicate in a
  new `cfg` field. For direct `rustc` builds Julia queries the configuration
  with the same target and codegen flags as the compilation (`:strict`); for
  the Cargo projects RustCall generates (`// cargo-deps:` blocks) it evaluates
  the same way against Cargo's effective configuration, probed with a throwaway
  crate (`:cargo`). Only external crates (`@rust_crate`), whose features and
  build script RustCall does not control, decide target predicates alone
  (`--cfg-lenient`, `:lenient`). The cfg set is part of the toolchain fingerprint (follow-up of #264).
- Function parameters carrying their own `#[cfg]`
  (`fn f(a: i32, #[cfg(any())] b: i32)`) are pruned like items, so the manifest
  and the generated wrapper match the C ABI rustc actually compiles
  (follow-up of #264).
- Crate-level `#![cfg(...)]` / `#![cfg_attr(...)]` is evaluated before the
  items: a block or crate disabled at file level compiles to nothing, so
  nothing is reported instead of emitting bindings for symbols that never
  exist (follow-up of #264).
- `cfg_attr` expansion runs until nothing changes, so any nesting depth
  reaches its `cfg`; the remaining safety limit (64 levels) is an error, never
  a partial expansion (follow-up of #264).
- Cargo-backed `rust"""` blocks record the tracked Cargo environment as a
  snapshot that is authoritative even when empty: a build or precompiled
  reload clears a `RUSTFLAGS` / profile override that was not set at
  expansion time instead of inheriting it. `CARGO_TARGET_<TRIPLE>_RUSTFLAGS`
  and `CARGO_TARGET_<TRIPLE>_LINKER` are now tracked as well (credential-like
  names stay excluded).
- The in-memory identity of a direct-`rustc` block (`rust_<hash>`) now covers
  the compiler snapshot (target, opt-level, debug info), the cfg text and the
  rustc environment (`RUSTFLAGS`, `RUSTUP_TOOLCHAIN`), through the same
  `_block_identity` helper Cargo-backed blocks use, so the same source built
  under two configurations is two libraries and a lookup never returns the
  other build.
- `#[cfg]`-disabled generic parameters (`fn f<#[cfg(any())] T, U>`, lifetimes
  and const generics, on functions, impls, structs, enums and traits) are
  pruned like items and function parameters (follow-up of #264).
- `--cfg-file` values are parsed as Rust string literals and unescaped exactly
  once, so `custom="\"quoted\""` is no longer conflated with
  `custom="quoted"`; a malformed value is an error.
- `CARGO_HOME` is part of the tracked Cargo environment, together with a
  digest of the effective `$CARGO_HOME/config.toml` (whose `[build] rustflags`
  the cfg probe observes), so a block precompiled under one Cargo home is
  rebuilt rather than reused under another.
- Generic functions of a `// cargo-deps:` block whose body contains `#[cfg]`
  or `cfg!` (reported by the new `body_has_cfg` manifest field) refuse lazy
  specialization with a `RustError`: the specialization is a direct `rustc`
  build under a different configuration than the Cargo build, so the body
  could take another branch. Move such code out of the generic body.
- After a reload that derives a new library name (toolchain or snapshot
  changed since precompilation), the loaded handle is aliased under the
  stored name and the module's active library is updated, so later calls no
  longer reload on every call or fall back to the global symbol search.
- The `CResult_<fn>` / `COption_<fn>` wrappers store the inactive payload as
  `MaybeUninit<T>`, so zero-filling it is no longer undefined behaviour for
  types with invalid zero bit patterns (`NonZeroU32`, references). The C
  layout is unchanged. Rust code reading the wrappers must use the new
  `ok()`, `err()` and `some()` accessors instead of the raw fields
  (follow-up of #264).
- `#[julia]` functions returning `Result`/`Option` keep their `#[cfg]`
  attributes on every generated item (wrapper struct, inner fn, extern fn),
  including the `#[cfg_attr(pred, cfg(...))]` form, which decides whether the
  function is compiled just like a direct `#[cfg]`.
- `rustcall-extract` reads its arguments as `OsString`, so non-UTF-8 file
  paths work on Windows (follow-up of #264).


## [0.1.0] - 2026-04-23

### Added
- **Phase 1: C-Compatible ABI**
  - `@rust` macro for calling Rust functions
  - `rust""` string literal for compiling and loading Rust code
  - `@irust` macro for function-scope Rust execution
  - Type mapping between Rust and Julia types
  - `RustResult<T, E>` and `RustOption<T>` support
  - String type support (`*const u8`, `Cstring`)
  - Compilation caching system (SHA256-based)

- **Phase 2: LLVM IR Integration**
  - `@rust_llvm` macro (experimental)
  - LLVM optimization passes
  - Ownership types: `RustBox`, `RustRc`, `RustArc`, `RustVec`, `RustSlice`
  - Array operations (indexing, iteration, conversion)
  - Generics support with automatic monomorphization
  - Enhanced error handling with `RustError` exception type
  - Function registration and caching system

- **Phase 3: External Library Integration**
  - Cargo dependency management
  - Support for `//! ```cargo ... ``` ` and `// cargo-deps:` formats
  - Automatic crate downloading and building
  - Integration with popular crates (ndarray, serde, rand, etc.)

- **Phase 4: Rust Structs as Julia Objects**
  - Automatic struct detection and Julia wrapper generation
  - C-FFI wrapper generation for Rust methods
  - Dynamic Julia type generation at macro expansion time
  - Automatic memory management with finalizers
  - Managed lifecycle for Rust objects in Julia

### Documentation
- Comprehensive API documentation
- Design documents (Phase1-4)
- Usage examples and tutorials
- Performance benchmarks
- Troubleshooting guide

### Testing
- 750+ tests covering all major features
- Test suites for cache, ownership, arrays, generics, error handling
- Integration tests for Rust helpers library
- Documentation examples tests

[Unreleased]: https://github.com/atelierarith/RustCall.jl/compare/v0.7.2...HEAD
[0.7.2]: https://github.com/atelierarith/RustCall.jl/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/atelierarith/RustCall.jl/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/atelierarith/RustCall.jl/compare/v0.6.6...v0.7.0
[0.6.6]: https://github.com/atelierarith/RustCall.jl/compare/v0.6.5...v0.6.6
[0.6.5]: https://github.com/atelierarith/RustCall.jl/compare/v0.6.4...v0.6.5
[0.6.4]: https://github.com/atelierarith/RustCall.jl/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/atelierarith/RustCall.jl/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/atelierarith/RustCall.jl/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/atelierarith/RustCall.jl/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/atelierarith/RustCall.jl/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/atelierarith/RustCall.jl/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/atelierarith/RustCall.jl/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/atelierarith/RustCall.jl/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/atelierarith/RustCall.jl/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/atelierarith/RustCall.jl/compare/v0.3.7...v0.4.0
[0.3.7]: https://github.com/atelierarith/RustCall.jl/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/atelierarith/RustCall.jl/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/atelierarith/RustCall.jl/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/atelierarith/RustCall.jl/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/atelierarith/RustCall.jl/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/atelierarith/RustCall.jl/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/atelierarith/RustCall.jl/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/atelierarith/RustCall.jl/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/atelierarith/RustCall.jl/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/atelierarith/RustCall.jl/compare/6e98d5cb62c0a0ca8b2f894c6fe53af209d9d3ea...v0.2.0
[0.1.0]: https://github.com/atelierarith/RustCall.jl/commit/6e98d5cb62c0a0ca8b2f894c6fe53af209d9d3ea
