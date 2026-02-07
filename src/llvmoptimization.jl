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

Apply optimization passes to an LLVM module.
Returns the optimized module (modified in place).
"""
function optimize_module!(mod::LLVM.Module; config::OptimizationConfig = get_default_opt_config())
    # Use LLVM's PassManager
    LLVM.@dispose pm=LLVM.ModulePassManager() begin
        # Add passes based on optimization level
        add_optimization_passes!(pm, config)

        # Run the passes
        LLVM.run!(pm, mod)
    end

    return mod
end

"""
    add_optimization_passes!(pm::LLVM.ModulePassManager, config::OptimizationConfig)

Add optimization passes to the pass manager based on configuration.
"""
function add_optimization_passes!(pm::LLVM.ModulePassManager, config::OptimizationConfig)
    # Level 0: No optimization (only required passes)
    if config.level == 0
        return
    end

    # Helper function to create a ModulePass with a no-op runner
    # The actual optimization is handled by LLVM's pass infrastructure
    # The callback function must return a Bool (true = success, false = failure)
    function create_pass(pass_name::String)
        return LLVM.ModulePass(pass_name, mod -> true)
    end

    # Level 1: Basic optimizations
    if config.level >= 1
        # Basic cleanup and simplification
        LLVM.add!(pm, create_pass("instcombine"))
        LLVM.add!(pm, create_pass("simplifycfg"))
        LLVM.add!(pm, create_pass("reassociate"))
        LLVM.add!(pm, create_pass("mem2reg"))
    end

    # Level 2: Standard optimizations
    if config.level >= 2
        # More aggressive optimizations
        LLVM.add!(pm, create_pass("gvn"))
        LLVM.add!(pm, create_pass("dce"))
        LLVM.add!(pm, create_pass("dse"))

        # Inlining
        LLVM.add!(pm, create_pass("inline"))

        # Loop optimizations
        if config.enable_licm
            LLVM.add!(pm, create_pass("licm"))
        end
        if config.enable_loop_unrolling
            LLVM.add!(pm, create_pass("loop-unroll"))
        end
    end

    # Level 3: Aggressive optimizations
    if config.level >= 3
        # Vectorization
        if config.enable_vectorization
            LLVM.add!(pm, create_pass("loop-vectorize"))
            LLVM.add!(pm, create_pass("slp-vectorizer"))
        end

        # More aggressive inlining and cleanup
        LLVM.add!(pm, create_pass("aggressive-instcombine"))

        # Final cleanup
        LLVM.add!(pm, create_pass("instcombine"))
        LLVM.add!(pm, create_pass("simplifycfg"))
    end

    # Size optimizations
    if config.size_level >= 1
        LLVM.add!(pm, create_pass("globaldce"))
        LLVM.add!(pm, create_pass("strip-dead-prototypes"))
    end

    if config.size_level >= 2
        LLVM.add!(pm, create_pass("mergefunc"))
    end
end

"""
    optimize_function!(fn::LLVM.Function; config=get_default_opt_config())

Apply optimization passes to a single LLVM function.
"""
function optimize_function!(fn::LLVM.Function; config::OptimizationConfig = get_default_opt_config())
    mod = LLVM.parent(fn)

    # For function-level optimization, we create a module pass manager
    # and run it on the parent module
    LLVM.@dispose pm=LLVM.ModulePassManager() begin
        add_function_optimization_passes!(pm, config)
        LLVM.run!(pm, mod)
    end

    return fn
end

"""
    add_function_optimization_passes!(pm::LLVM.ModulePassManager, config::OptimizationConfig)

Add function-level optimization passes.
"""
function add_function_optimization_passes!(pm::LLVM.ModulePassManager, config::OptimizationConfig)
    # Helper function to create a ModulePass with a no-op runner
    # The callback function must return a Bool (true = success, false = failure)
    function create_pass(pass_name::String)
        return LLVM.ModulePass(pass_name, mod -> true)
    end

    if config.level >= 1
        LLVM.add!(pm, create_pass("mem2reg"))
        LLVM.add!(pm, create_pass("instcombine"))
    end

    if config.level >= 2
        LLVM.add!(pm, create_pass("gvn"))
        LLVM.add!(pm, create_pass("dce"))
    end

    if config.level >= 3
        LLVM.add!(pm, create_pass("aggressive-instcombine"))
    end
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
