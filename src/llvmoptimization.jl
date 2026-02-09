# LLVM optimization passes for RustCall.jl
# Phase 2: Optimization integration

using LLVM

"""
    OptimizationConfig

Configuration for LLVM optimization passes.
"""
struct OptimizationConfig
    level::Int  # 0-3
    size_level::Int  # 0-2 (0=none, 1=optimize for size, 2=minimize size)
    inline_threshold::Int
    enable_vectorization::Bool
    enable_loop_unrolling::Bool
    enable_licm::Bool  # Loop-invariant code motion
end

"""
    OptimizationConfig(; kwargs...)

Create an OptimizationConfig with specified settings.
"""
function OptimizationConfig(;
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
                      enable_vectorization, enable_loop_unrolling, enable_licm)
end

# Default optimization config
const DEFAULT_OPT_CONFIG = Ref{OptimizationConfig}()

function get_default_opt_config()
    if !isassigned(DEFAULT_OPT_CONFIG)
        DEFAULT_OPT_CONFIG[] = OptimizationConfig()
    end
    return DEFAULT_OPT_CONFIG[]
end

function set_default_opt_config(config::OptimizationConfig)
    DEFAULT_OPT_CONFIG[] = config
end

"""
    optimize_module!(mod::LLVM.Module; config=get_default_opt_config())

Apply optimization passes to an LLVM module using LLVM's New Pass Manager.
Returns the optimized module (modified in place).
"""
function optimize_module!(mod::LLVM.Module; config::OptimizationConfig = get_default_opt_config())
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
"""
function optimize_function!(fn::LLVM.Function; config::OptimizationConfig = get_default_opt_config())
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
"""
function optimize_for_speed!(mod::LLVM.Module)
    config = OptimizationConfig(
        level=3,
        size_level=0,
        inline_threshold=300,
        enable_vectorization=true,
        enable_loop_unrolling=true,
        enable_licm=true
    )
    return optimize_module!(mod; config=config)
end

"""
    optimize_for_size!(mod::LLVM.Module)

Apply optimizations focused on code size.
"""
function optimize_for_size!(mod::LLVM.Module)
    config = OptimizationConfig(
        level=2,
        size_level=2,
        inline_threshold=50,
        enable_vectorization=false,
        enable_loop_unrolling=false,
        enable_licm=true
    )
    return optimize_module!(mod; config=config)
end

"""
    optimize_balanced!(mod::LLVM.Module)

Apply balanced optimizations (default).
"""
function optimize_balanced!(mod::LLVM.Module)
    config = OptimizationConfig()  # Uses defaults
    return optimize_module!(mod; config=config)
end
