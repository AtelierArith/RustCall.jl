# LLVM optimization passes for RustCall.jl
# Phase 2: Optimization integration

using LLVM

"""
    OptimizationConfig

Configuration for LLVM optimization passes.

!!! warning "Deprecated"
    The LLVM IR integration path is deprecated and will be removed in a future
    release (see [#265](https://github.com/AtelierArith/RustCall.jl/issues/265)).
    Use `@rust` instead.
"""
struct OptimizationConfig
    level::Int  # 0-3
    size_level::Int  # 0-2 (0=none, 1=optimize for size, 2=minimize size)
    inline_threshold::Int
    enable_vectorization::Bool
    enable_loop_unrolling::Bool
    enable_licm::Bool  # Loop-invariant code motion

    # Positional construction is public API too, so it warns as well (#265).
    # `_optimization_config` passes `_warn=false` for internal use.
    function OptimizationConfig(level::Int, size_level::Int, inline_threshold::Int,
                                enable_vectorization::Bool, enable_loop_unrolling::Bool,
                                enable_licm::Bool; _warn::Bool = true)
        _warn && _llvm_path_depwarn("OptimizationConfig", :OptimizationConfig)
        return new(level, size_level, inline_threshold,
                   enable_vectorization, enable_loop_unrolling, enable_licm)
    end
end

# Defining a typed inner constructor suppresses Julia's default converting
# outer constructor; keep positional calls with convertible arguments
# (`OptimizationConfig(Int8(2), Int8(0), Int16(225), true, true, true)`) working.
function OptimizationConfig(level, size_level, inline_threshold,
                            enable_vectorization, enable_loop_unrolling, enable_licm)
    return OptimizationConfig(Int(level), Int(size_level), Int(inline_threshold),
                              Bool(enable_vectorization), Bool(enable_loop_unrolling),
                              Bool(enable_licm))
end

"""
    OptimizationConfig(; kwargs...)

Create an OptimizationConfig with specified settings.

!!! warning "Deprecated"
    The LLVM IR integration path is deprecated and will be removed in a future
    release (see [#265](https://github.com/AtelierArith/RustCall.jl/issues/265)).
    Use `@rust` instead.
"""
function OptimizationConfig(; kwargs...)
    _llvm_path_depwarn("OptimizationConfig", :OptimizationConfig)
    return _optimization_config(; kwargs...)
end

function _optimization_config(;
    level::Int = 2,
    size_level::Int = 0,
    inline_threshold::Int = 225,
    enable_vectorization::Bool = true,
    enable_loop_unrolling::Bool = true,
    enable_licm::Bool = true
)
    @assert 0 <= level <= 3 "Optimization level must be 0-3"
    @assert 0 <= size_level <= 2 "Size level must be 0-2"
    OptimizationConfig(level, size_level, inline_threshold,
                       enable_vectorization, enable_loop_unrolling, enable_licm; _warn=false)
end

# Default optimization config
const DEFAULT_OPT_CONFIG = Ref{OptimizationConfig}()

function get_default_opt_config()
    _llvm_path_depwarn("get_default_opt_config", :get_default_opt_config)
    return _get_default_opt_config()
end

function _get_default_opt_config()
    if !isassigned(DEFAULT_OPT_CONFIG)
        DEFAULT_OPT_CONFIG[] = _optimization_config()
    end
    return DEFAULT_OPT_CONFIG[]
end

function set_default_opt_config(config::OptimizationConfig)
    _llvm_path_depwarn("set_default_opt_config", :set_default_opt_config)
    DEFAULT_OPT_CONFIG[] = config
end

"""
    optimize_module!(mod::LLVM.Module; config=get_default_opt_config())

Apply optimization passes to an LLVM module using LLVM's New Pass Manager.
Returns the optimized module (modified in place).

!!! warning "Deprecated"
    The LLVM IR integration path is deprecated and will be removed in a future
    release (see [#265](https://github.com/AtelierArith/RustCall.jl/issues/265)).
    Use `@rust` instead.
"""
function optimize_module!(mod::LLVM.Module; config::OptimizationConfig = _get_default_opt_config())
    _llvm_path_depwarn("optimize_module!", :optimize_module!)
    return _optimize_module!(mod; config)
end

function _optimize_module!(mod::LLVM.Module; config::OptimizationConfig = _get_default_opt_config())
    if config.level == 0 && config.size_level == 0
        return mod
    end

    # Determine effective optimization level for DefaultPipeline
    opt_level = if config.size_level >= 2
        's'  # Oz — minimize size
    elseif config.size_level >= 1
        's'  # Os — optimize for size
    else
        config.level
    end

    # Use the New Pass Manager with LLVM's built-in DefaultPipeline.
    # DefaultPipeline maps to LLVM's standard -O1/-O2/-O3/-Os pipelines which
    # include instcombine, simplifycfg, mem2reg, GVN, DCE, DSE, inlining,
    # LICM, loop unrolling, vectorization, and more.
    LLVM.@dispose pb=LLVM.NewPMPassBuilder(
        loop_vectorization=config.enable_vectorization,
        slp_vectorization=config.enable_vectorization,
        loop_unrolling=config.enable_loop_unrolling,
        loop_interleaving=config.enable_loop_unrolling
    ) begin
        LLVM.add!(pb, LLVM.DefaultPipeline(opt_level=opt_level))

        # Additional size-focused passes beyond what DefaultPipeline provides
        if config.size_level >= 2
            LLVM.add!(pb, LLVM.NewPMModulePassManager()) do mpm
                LLVM.add!(mpm, "mergefunc")
            end
        end

        LLVM.run!(pb, mod)
    end

    return mod
end

"""
    optimize_function!(fn::LLVM.Function; config=get_default_opt_config())

Apply optimization passes to a single LLVM function.

!!! warning "Deprecated"
    The LLVM IR integration path is deprecated and will be removed in a future
    release (see [#265](https://github.com/AtelierArith/RustCall.jl/issues/265)).
    Use `@rust` instead.
"""
function optimize_function!(fn::LLVM.Function; config::OptimizationConfig = _get_default_opt_config())
    _llvm_path_depwarn("optimize_function!", :optimize_function!)
    mod = LLVM.parent(fn)

    if config.level == 0
        return fn
    end

    # Run a function-scoped pipeline via the New Pass Manager
    LLVM.@dispose pb=LLVM.NewPMPassBuilder() begin
        LLVM.add!(pb, LLVM.NewPMFunctionPassManager()) do fpm
            if config.level >= 1
                LLVM.add!(fpm, "mem2reg")
                LLVM.add!(fpm, "instcombine")
                LLVM.add!(fpm, "simplifycfg")
                LLVM.add!(fpm, "reassociate")
            end
            if config.level >= 2
                LLVM.add!(fpm, "gvn")
                LLVM.add!(fpm, "dce")
                LLVM.add!(fpm, "dse")
            end
            if config.level >= 3
                LLVM.add!(fpm, "aggressive-instcombine")
                LLVM.add!(fpm, "instcombine")
                LLVM.add!(fpm, "simplifycfg")
            end
        end
        LLVM.run!(pb, mod)
    end

    return fn
end

"""
    get_optimization_stats(mod::LLVM.Module) -> Dict{String, Any}

Get statistics about an LLVM module for optimization analysis.
"""
function get_optimization_stats(mod::LLVM.Module)
    stats = Dict{String, Any}()

    # Count functions
    func_count = 0
    total_instructions = 0
    total_basic_blocks = 0

    for fn in LLVM.functions(mod)
        if !LLVM.isdeclaration(fn)
            func_count += 1
            for bb in LLVM.blocks(fn)
                total_basic_blocks += 1
                for inst in LLVM.instructions(bb)
                    total_instructions += 1
                end
            end
        end
    end

    stats["function_count"] = func_count
    stats["total_instructions"] = total_instructions
    stats["total_basic_blocks"] = total_basic_blocks
    stats["avg_instructions_per_function"] = func_count > 0 ? total_instructions / func_count : 0

    return stats
end

"""
    verify_module(mod::LLVM.Module) -> Bool

Verify that an LLVM module is well-formed.
"""
function verify_module(mod::LLVM.Module)
    return LLVM.verify(mod)
end

"""
    print_module_ir(mod::LLVM.Module; io::IO=stdout)

Print the LLVM IR of a module for debugging.
"""
function print_module_ir(mod::LLVM.Module; io::IO=stdout)
    print(io, string(mod))
end

"""
    print_function_ir(fn::LLVM.Function; io::IO=stdout)

Print the LLVM IR of a function for debugging.
"""
function print_function_ir(fn::LLVM.Function; io::IO=stdout)
    print(io, string(fn))
end

# ============================================================================
# Convenience functions for common optimization scenarios
# ============================================================================

"""
    optimize_for_speed!(mod::LLVM.Module)

Apply optimizations focused on execution speed.

!!! warning "Deprecated"
    The LLVM IR integration path is deprecated and will be removed in a future
    release (see [#265](https://github.com/AtelierArith/RustCall.jl/issues/265)).
    Use `@rust` instead.
"""
function optimize_for_speed!(mod::LLVM.Module)
    _llvm_path_depwarn("optimize_for_speed!", :optimize_for_speed!)
    config = _optimization_config(
        level=3,
        size_level=0,
        inline_threshold=300,
        enable_vectorization=true,
        enable_loop_unrolling=true,
        enable_licm=true
    )
    return _optimize_module!(mod; config=config)
end

"""
    optimize_for_size!(mod::LLVM.Module)

Apply optimizations focused on code size.

!!! warning "Deprecated"
    The LLVM IR integration path is deprecated and will be removed in a future
    release (see [#265](https://github.com/AtelierArith/RustCall.jl/issues/265)).
    Use `@rust` instead.
"""
function optimize_for_size!(mod::LLVM.Module)
    _llvm_path_depwarn("optimize_for_size!", :optimize_for_size!)
    config = _optimization_config(
        level=2,
        size_level=2,
        inline_threshold=50,
        enable_vectorization=false,
        enable_loop_unrolling=false,
        enable_licm=true
    )
    return _optimize_module!(mod; config=config)
end

"""
    optimize_balanced!(mod::LLVM.Module)

Apply balanced optimizations (default).

!!! warning "Deprecated"
    The LLVM IR integration path is deprecated and will be removed in a future
    release (see [#265](https://github.com/AtelierArith/RustCall.jl/issues/265)).
    Use `@rust` instead.
"""
function optimize_balanced!(mod::LLVM.Module)
    _llvm_path_depwarn("optimize_balanced!", :optimize_balanced!)
    config = _optimization_config()  # Uses defaults
    return _optimize_module!(mod; config=config)
end
