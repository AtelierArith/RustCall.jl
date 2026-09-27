"""
    _crate_init_prologue(origin::Symbol)

What a generated crate module's `__init__` does before it loads its library, in
order, shared by both emitters: the in-memory module splices these expressions
(`origin = :rust_crate`) and `emit_crate_module_code` prints them
(`:bindings_file`), so a written file cannot drift from `@rust_crate` (#474
review). Only the in-memory check names its origin: a written file is loaded by
every RustCall of its format line, so it makes only calls the oldest of them
accepts — the origin-less one, which the check reads as a written file's
(#531). First the strict
build-environment check against `_BUILD_RECORD` — a precompiled module refuses
to load a library built under another `RUSTFLAGS`, `PYO3_PYTHON`, Cargo
configuration or toolchain (#339, #355) — then the mirror registration, which
must precede the load (#277).
"""
function _crate_init_prologue(origin::Symbol)
    _check_build_env_origin(origin)
    # A written file makes only calls every RustCall of its format line
    # accepts (#531 review): a file written here is loaded by any 0.7.x, and an
    # older one has no `origin` keyword. The origin-less call is the written
    # file's (`_warn_if_build_env_changed(::CrateBuildRecord)` reads it as
    # `:bindings_file`), so only the in-memory module, which is always emitted
    # by the RustCall that loads it, names its origin.
    check = origin === :rust_crate ?
        @_emitted(:(RustCall._warn_if_build_env_changed(_BUILD_RECORD; strict = true,
                                                        origin = :rust_crate))) :
        @_emitted(:(RustCall._warn_if_build_env_changed(_BUILD_RECORD; strict = true)))
    return (check, @_emitted(:(RustCall.register_handle_mirror!(_LIB_NAME, _LIB_GEN))))
end

"""
    emit_crate_module(info::CrateInfo, lib_path::String; module_name::Union{String, Nothing}=nothing) -> Expr

Generate a Julia module expression containing bindings for the crate.

# Arguments
- `info::CrateInfo`: Crate information from scan_crate
- `lib_path::String`: Path to the compiled shared library

# Keyword Arguments
- `module_name::Union{String, Nothing}`: Name for the module (default: crate name with first letter capitalized)

# Returns
- `Expr`: A module expression that can be evaluated
"""
function emit_crate_module(info::CrateInfo, lib_path::String;
                           module_name::Union{String, Nothing}=nothing,
                           build_release::Bool = true,
                           lib_name::Union{String, Nothing} = nothing,
                           preload::Vector{String} = String[],
                           extra_inputs::Vector{String} = String[],
                           python::Bool = false,
                           pin_library::Bool = false,
                           build_options::NamedTuple = crate_build_options(release = build_release),
                           build_record::Union{Nothing, CrateBuildRecord} = nothing,
                           snapshot::Union{Nothing, BuildEnvSnapshot} = nothing)
    # The build's snapshot when a build passes one (#481); a direct call takes
    # its own, once.
    snapshot === nothing && (snapshot = BuildEnvSnapshot())
    # Determine module name
    mod_name = if module_name !== nothing
        Symbol(module_name)
    else
        Symbol(snake_to_pascal(info.name))
    end

    # The crate root's items; items inside modules go into the submodules
    # below (#300). A module name Julia cannot define next to a root binding
    # is refused up front.
    tree = _module_tree(info)
    _check_module_names(tree)
    func_defs, struct_defs, submodules = _crate_wrapper_exprs(tree)

    # The registry name of this crate's library. `@rust_crate` used to keep its
    # handle only in a module-local `Ref`, invisible to `unload_library`,
    # `unload_all_libraries` and every registry the rest of RustCall keeps
    # (#250). It goes through `load_artifact!` now, so the module's `Ref` and
    # the registry hold the same handle and the same liveness flag.
    lib_key = lib_name === nothing ?
        crate_library_name(info; release = build_release, snapshot = snapshot) : lib_name

    # The files an edit to the crate would touch; see
    # `_crate_precompile_dependencies`.
    crate_inputs = _crate_precompile_dependencies(info.path, snapshot)
    # Inputs the caller knows about and the crate directory does not — the PyO3
    # wrapper's interpreter and the libraries it preloads. An interpreter
    # upgraded in place keeps its path, so only its *content* says it changed,
    # and `plan.interpreter_config` is in the wrapper's artifact identity
    # (#339 review).
    for extra in extra_inputs
        (isfile(extra) || isdir(extra)) && push!(crate_inputs, abspath(extra))
    end
    unique!(crate_inputs)
    # Every input of this build — crate, registry name, profile, features,
    # kind, and the environment that is not a file — as one immutable value
    # (#474). The source-text emitter records the same value from the same
    # call.
    # A caller that built the library passes the record it built under
    # (`_record_build_subprocess_env`); otherwise it is taken now.
    build_record = something(build_record,
        crate_build_record(info.path, lib_key; build_options = build_options, python = python,
                           snapshot = snapshot))
    build_record.lib_name == lib_key || throw(ArgumentError(
        "the build record names `$(build_record.lib_name)`, not `$(lib_key)`"))
    @debug "Recording generated crate build" lib_key build_record.toolchain

    # Build the module body as a block. Nothing is imported: every name the
    # body takes from Base, Core or RustCall is a `GlobalRef` (`@_emitted`), so
    # a crate item bound here under such a name — `struct Base`,
    # `fn getfield`, `struct RustCall` — cannot capture it (#528). `Libdl` is
    # reached through RustCall, never imported by the caller's environment
    # (#339).
    module_body = @_emitted quote
        # The bindings format this module was generated for, checked by the
        # RustCall that loads it (#489). Both emitters declare it, so the
        # check `__init__` repeats (`register_handle_mirror!`) finds it here too.
        const _BINDINGS_FORMAT = RustCall.check_bindings_format($(BINDINGS_FORMAT_VERSION))

        # The *durable* library — RustCall's cache copy, or Cargo's output —
        # never the per-process generation copy, which is swept once the
        # process that made it is gone. This module may be precompiled as part
        # of a package (`@rust_crate` at top level, #339): its `__init__` then
        # runs in a later session, which must still find this file.
        const _LIB_PATH = $lib_path
        # Every input of the build `_LIB_PATH` is — crate, registry name,
        # profile, features, kind, build environment, Cargo configuration,
        # toolchain — as one immutable record: the only thing a hot reload
        # rebuilds from, so the image it publishes under `_LIB_NAME` has the
        # `#[cfg]`s these wrappers were generated for (#461 review, #474).
        const _BUILD_RECORD = $build_record
        const _LIB_NAME = _BUILD_RECORD.lib_name
        # Libraries the image imports by name that the loader would not find on
        # its own — a PyO3 wrapper's `python3xy.dll` on Windows, where there is
        # no rpath — opened before it (`PyO3LinkPlan.runtime_libraries`).
        const _PRELOAD_LIBRARIES = $(Tuple(preload))
        # Python's type registry and Python-owned handles retain callbacks into
        # this image beyond one logical RustCall generation. A second owned
        # loader reference keeps the private generation copy physically mapped
        # for the process; logical calls still follow `_LIB_GEN` as usual.
        const _PIN_LIBRARY = $pin_library

        # What makes a package that contains this module re-precompile, and so
        # rebuild the crate, when it should (#339). Outside precompilation
        # these record nothing.
        #
        # The library: removed by `RustCall.clear_cache()`, after which Julia
        # sees the image as stale rather than letting `__init__` open a path
        # that is gone.
        Base.include_dependency(_LIB_PATH)
        # And the crate's own inputs — the very files its artifact identity is
        # computed from. Without them an edit to `src/lib.rs` would leave the
        # image valid: the new build lands at a *different* content-addressed
        # cache path and the old file is still there, unchanged, so nothing
        # Julia tracks would have moved and the package would go on calling the
        # previous build (#339 review).
        const _CRATE_INPUTS = $(Tuple(crate_inputs))
        for _input in _CRATE_INPUTS
            Base.include_dependency(_input)
        end
        # The rest of the identity is environment, not files —
        # `RUSTFLAGS`, `PYO3_PYTHON`, a `PYO3_CONFIG_FILE` pointing elsewhere.
        # Julia cannot invalidate an image on those, so the values are recorded
        # in `_BUILD_RECORD` and `__init__` says when they no longer match
        # (#339 review).

        # Everything this module knows about the image it calls — handle,
        # liveness flag and generation number — as **one immutable value**, in
        # one STATE-owned cell exposed through an immutable view.
        #
        # It used to be two `Ref`s, written by the loader under `REGISTRY_LOCK`
        # and read here under this module's own lock. Two unrelated locks over
        # two cells is not a snapshot: a constructor could read the old handle,
        # the reload could commit, and the constructor would then pair that
        # handle with the *replacement's* liveness flag — so an object
        # allocated by the retired image believed itself live after that image
        # was closed, and its finalizer jumped through an unmapped destructor.
        # One record, published by `_update_handle_mirrors!` in the same
        # transaction that swaps the registry entry, makes every read of
        # `_LIB_GEN[]` a consistent generation. The view takes STATE only to
        # read that record; no lock is held while resolving or calling Rust.
        const _LIB_GEN = RustCall.StateView(:crate_generation, @__MODULE__)

        function __init__()
            # Register *before* loading, and do not assign afterwards: the
            # `load_artifact!` transaction is what publishes the generation. An
            # assignment after it would overwrite a newer generation that a
            # concurrent reload had already published, and calls through this
            # module would go back to entering the retired image (#277).
            $(_crate_init_prologue(:rust_crate)...)
            # A private generation copy, never `_LIB_PATH` itself: that file is
            # Cargo's output or the cache copy, and an image mapped in place
            # cannot be overwritten on Windows — the next `cargo build` of the
            # crate would fail (#255, #277, #309). Copied *here*, not when the
            # module was generated, because `__init__` may run in a later
            # session than the one that generated this module (#339).
            rustcall_process_image = RustCall.loadable_library_copy(_LIB_PATH)
            _PIN_LIBRARY && RustCall.preload_dependency!(RustCall.crate_direct_policy(),
                                                         rustcall_process_image)
            RustCall.load_artifact!(RustCall.crate_direct_policy(), rustcall_process_image;
                                    lib_name = _LIB_NAME, preload = _PRELOAD_LIBRARIES)
        end

        # Resolved symbols, memoized per **handle**: a reload swaps the image
        # under the same module, and a pointer resolved against the old one
        # would be a call into code that is no longer there. Negative answers
        # are cached too — a crate built by an older RustCall exports no panic
        # channels and must not be probed on every call.
        const _SYMBOLS = RustCall.StateView(:crate_symbols, @__MODULE__)

        # Declared `::Ptr{Cvoid}`, because the memo is a `StateView` and hands
        # back an `Any`. Without the declaration every snapshot below would be a
        # tuple of `Any`, the wrapper's `ccall` argument and its panic channel
        # would both be boxed, and the cached fast path would still allocate.
        function _symbol(handle::Ptr{Cvoid}, name::String)::Ptr{Cvoid}
            # StateView evaluates a cache default outside STATE, then performs
            # compare-and-publish. Symbol resolution precedes every Rust call.
            get!(_SYMBOLS, (handle, name)) do
                ptr = Libdl.dlsym(handle, name; throw_error = false)
                ptr === nothing ? C_NULL : ptr
            end
        end

        function _required_symbol(handle::Ptr{Cvoid}, name::String)::Ptr{Cvoid}
            ptr = _symbol(handle, name)
            ptr == C_NULL && error("The Rust library '" * _LIB_NAME *
                                   "' does not export '" * name * "'.")
            ptr
        end

        function _live_handle(gen::RustCall.CrateGeneration)
            gen.handle == C_NULL &&
                error("The Rust library backing this module is not loaded. " *
                      "It was either never initialised, or unloaded with " *
                      "RustCall.unload_library(\"" * _LIB_NAME * "\").")
            gen.handle
        end

        _get_func_ptr(name::String) = _required_symbol(_live_handle(_LIB_GEN[]), name)

        # What each arm below yields, named once so the cached answer and the
        # freshly resolved one cannot disagree about its shape.
        const _CALL_TARGET = Tuple{Ptr{Cvoid}, Ptr{Cvoid}}
        const _STRING_TARGET = Tuple{Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}}
        const _VEC_TARGET = Tuple{Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Base.RefValue{Bool}}
        const _CTOR_TARGET = Tuple{Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
                                   Base.RefValue{Bool}, Ptr{Cvoid}}
        const _FREE_TARGET = Tuple{Ptr{Cvoid}, Base.RefValue{Bool}, Ptr{Cvoid}}

        # One snapshot per call: the wrapper and its panic channel, resolved
        # against **one** deref of `_LIB_GEN`. Reading the generation twice
        # could straddle a reload, and the call would then enter the retired
        # image while the channel came from the replacement (#277).
        #
        # `cache` is the call site's own `RustCall.CrateTargetCache` (#253): the
        # snapshot below is kept in it and handed back whole while the artifact
        # epoch and the session token say it is still this process's current
        # answer. Nothing is ever reassembled from pieces — a hit returns the
        # very tuple one `_LIB_GEN` deref produced — so the rule above is
        # unchanged; only the number of times an unchanged answer is recomputed.
        function _call_target(cache::RustCall.CrateTargetCache, symbol::String)
            hit = RustCall.crate_target_hit(cache, _CALL_TARGET)
            hit === nothing || return hit
            # Sampled **before** the snapshot. A state write landing in between
            # leaves this entry stamped with the older epoch, so the next call
            # resolves again; sampling afterwards could stamp a pre-write
            # snapshot as current and keep it forever.
            epoch = RustCall.artifact_epoch()
            handle = _live_handle(_LIB_GEN[])
            return RustCall.publish_crate_target!(cache, epoch,
                (_required_symbol(handle, symbol),
                 _symbol(handle, RustCall.ffi_panic_symbol(symbol))))
        end

        # The owned-`String` arm, with the function that releases the buffer the
        # wrapper returns. Resolving that release function after the call let a
        # reload land in between, and the buffer was then freed through the
        # replacement's allocator (#277).
        function _call_target(cache::RustCall.CrateTargetCache, symbol::String,
                              free_symbol::String)
            hit = RustCall.crate_target_hit(cache, _STRING_TARGET)
            hit === nothing || return hit
            epoch = RustCall.artifact_epoch()
            handle = _live_handle(_LIB_GEN[])
            return RustCall.publish_crate_target!(cache, epoch,
                (_required_symbol(handle, symbol),
                 _symbol(handle, RustCall.ffi_panic_symbol(symbol)),
                 _required_symbol(handle, free_symbol)))
        end

        # An owned Vec outlives the getter call. Capture its release export and
        # the producing generation's liveness flag with the getter snapshot so
        # reload cannot pair the buffer with another allocator (#303).
        function _vec_target(cache::RustCall.CrateTargetCache, symbol::String,
                             free_symbol::String)
            hit = RustCall.crate_target_hit(cache, _VEC_TARGET)
            hit === nothing || return hit
            epoch = RustCall.artifact_epoch()
            gen = _LIB_GEN[]
            handle = _live_handle(gen)
            return RustCall.publish_crate_target!(cache, epoch,
                (_required_symbol(handle, symbol),
                 _symbol(handle, RustCall.ffi_panic_symbol(symbol)),
                 _required_symbol(handle, free_symbol),
                 gen.alive))
        end

        # The constructor arm: the wrapper that *allocates*, its channel, and
        # the destructor and liveness flag the resulting object will carry —
        # all from one deref. Taking the object's half after the call returned
        # would bind a pointer allocated by the retired image to the
        # replacement's destructor (#277).
        function _ctor_target(cache::RustCall.CrateTargetCache, symbol::String,
                              free_symbol::String)
            hit = RustCall.crate_target_hit(cache, _CTOR_TARGET)
            hit === nothing || return hit
            epoch = RustCall.artifact_epoch()
            gen = _LIB_GEN[]
            handle = _live_handle(gen)
            return RustCall.publish_crate_target!(cache, epoch,
                (_required_symbol(handle, symbol),
                 _symbol(handle, RustCall.ffi_panic_symbol(symbol)),
                 _symbol(handle, free_symbol),
                 gen.alive,
                 _symbol(handle, RustCall.ffi_panic_symbol(free_symbol))))
        end

        # The per-object half: a struct's destructor and the liveness flag of
        # the image that exports it — one deref, so they are always the same
        # generation. A missing destructor is `C_NULL`, which makes the
        # finalizer a no-op: a leak, not a crash (#249).
        function _struct_generation(cache::RustCall.CrateTargetCache, free_symbol::String)
            hit = RustCall.crate_target_hit(cache, _FREE_TARGET)
            hit === nothing || return hit
            epoch = RustCall.artifact_epoch()
            gen = _LIB_GEN[]
            # Not published: an unloaded module has no snapshot to keep, and
            # caching this one would survive the load that gives it a handle.
            gen.handle == C_NULL &&
                return (Ptr{Cvoid}(C_NULL), gen.alive, Ptr{Cvoid}(C_NULL))
            return RustCall.publish_crate_target!(cache, epoch,
                (_symbol(gen.handle, free_symbol),
                 gen.alive,
                 _symbol(gen.handle, RustCall.ffi_panic_symbol(free_symbol))))
        end

        # The channel is resolved by the *caller*, before the wrapper call:
        # it is a thread-local in the image, so nothing may yield between the
        # call and the read, and `_panic_channel` can allocate (#244).
        _guard_panic(value, channel::Ptr{Cvoid}, name::String) =
            RustCall.guard_rust_panic_ptr(value, channel, name)
        # For a call that returned an owned buffer still to be decoded: if the
        # guard raises, the buffer is released through `free_ptr` (#460).
        _guard_panic(value, channel::Ptr{Cvoid}, name::String, free_ptr::Ptr{Cvoid}) =
            RustCall.guard_rust_panic_ptr(value, channel, name, free_ptr)

        $(_function_declarations_expr(tree))
        $func_defs
        $struct_defs
        # One Julia submodule per Rust module: `bindings.a.run()` for
        # `a::run` (#300). Each imports the helpers above from its parent.
        $(submodules...)
    end

    # Return a clean module expression (not wrapped in a block)
    # The module expression format is: Expr(:module, not_baremodule, name, body)
    Expr(:module, true, mod_name, module_body)
end

function _function_wrappers_expr(functions)
    exprs = Expr[]

    for func in functions
        # A generic item gets no wrapper (the proc macro refuses it); one the
        # codegen refuses as `unsafe` is still recorded (#491).
        _function_skipped!(func) && continue

        wrapper = _generate_crate_function_wrapper(func)
        push!(exprs, wrapper)
    end

    if isempty(exprs)
        return :()
    end

    Expr(:block, exprs...)
end
