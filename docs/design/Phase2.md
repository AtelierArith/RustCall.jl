# Phase 2: LLVM IR統合

## 概要

Phase 2では、LLVM IRを直接操作して、より柔軟で高性能なRust-Julia統合を実現します。このフェーズでは、rustcで生成されたLLVM IRを取得し、Juliaの`llvmcall`に埋め込むことで、C互換ABIの制限を回避し、より高度な型システムと最適化を実現します。

**目標期間**: 4-6ヶ月
**成果物**: LLVM IR統合、拡張された型システム、所有権型のサポート、最適化

---

## 実装タスク一覧

### タスク1: LLVM.jlの統合とセットアップ

**優先度**: 最高
**見積もり**: 1週間

#### 実装内容

1. **依存関係の追加**

   ```toml
   # Project.toml
   [deps]
   LLVM = "929cbde3-209d-540e-8aea-1fcc83b56489"
   LLVM_jll = "dad2f222-ce93-54a1-a47d-0025e8a3acab"
   ```

2. **LLVMモジュールの初期化**

   ```julia
   # src/llvmintegration.jl
   using LLVM
   using LLVM.Interop

   # LLVMコンテキストの管理
   const llvm_contexts = Dict{String, LLVM.Context}()

   function get_llvm_context(name::String = "default")
       if !haskey(llvm_contexts, name)
           llvm_contexts[name] = Context()
       end
       llvm_contexts[name]
   end
   ```

3. **LLVM IRの読み込み機能**

   ```julia
   function parse_llvm_ir(ir_file::String)
       ctx = get_llvm_context()
       mod = parse(LLVM.Module, read(ir_file, String), ctx)
       mod
   end

   function parse_llvm_ir_string(ir_string::String)
       ctx = get_llvm_context()
       mod = parse(LLVM.Module, ir_string, ctx)
       mod
   end
   ```

---

### タスク2: Rustコンパイラ統合

**優先度**: 最高
**見積もり**: 2週間

#### 実装内容

1. **Rustコンパイラの設定**

   ```julia
   # src/rustcompiler.jl

   struct RustCompiler
       target_triple::String
       optimization_level::Int  # 0-3
       emit_debug_info::Bool
       crate_type::String  # "cdylib", "rlib", etc.
   end

   function RustCompiler(;
       target_triple::String = get_default_target(),
       optimization_level::Int = 2,
       emit_debug_info::Bool = false,
       crate_type::String = "cdylib"
   )
       RustCompiler(target_triple, optimization_level, emit_debug_info, crate_type)
   end

   function get_default_target()
       # 現在のプラットフォームのターゲットを取得
       @static Sys.iswindows() ? "x86_64-pc-windows-msvc" :
       @static Sys.isapple() ? "x86_64-apple-darwin" :
       "x86_64-unknown-linux-gnu"
   end
   ```

2. **RustコードからLLVM IRへのコンパイル**

   ```julia
   function compile_rust_to_llvm(
       compiler::RustCompiler,
       code::String;
       output_file::Union{String, Nothing} = nothing
   )
       # 1. 一時ファイルに書き込み
       tmp_file = tempname() * ".rs"
       write(tmp_file, wrap_rust_code_for_llvm(code))

       # 2. LLVM IRファイルのパスを決定
       if output_file === nothing
           ir_file = tempname() * ".ll"
       else
           ir_file = output_file
       end

       # 3. rustcでLLVM IRを生成
       cmd = `rustc --emit llvm-ir
              --target $(compiler.target_triple)
              -C opt-level=$(compiler.optimization_level)
              $(compiler.emit_debug_info ? "-g" : "")
              -o $ir_file $tmp_file`

       try
           run(cmd)
       catch e
           error("Failed to compile Rust code: $e")
       end

       # 4. LLVM IRを読み込み
       if !isfile(ir_file)
           error("LLVM IR file not generated: $ir_file")
       end

       mod = parse_llvm_ir(ir_file)

       # 5. 一時ファイルをクリーンアップ（オプション）
       # rm(tmp_file, force=true)

       mod
   end

   function wrap_rust_code_for_llvm(code::String)
       # Rustコードを適切にラップ
       # 必要に応じて、extern "C"ブロックやその他の設定を追加
       code
   end
   ```

3. **インクリメンタルコンパイルのサポート**

   ```julia
   # コンパイル結果をキャッシュ
   const compilation_cache = Dict{String, LLVM.Module}()

   function compile_rust_to_llvm_cached(
       compiler::RustCompiler,
       code::String
   )
       code_hash = hash(code)
       cache_key = "$(code_hash)_$(compiler.optimization_level)"

       if haskey(compilation_cache, cache_key)
           return compilation_cache[cache_key]
       end

       mod = compile_rust_to_llvm(compiler, code)
       compilation_cache[cache_key] = mod
       mod
   end
   ```

---

### タスク3: LLVM IRの最適化

**優先度**: 高
**見積もり**: 1週間

#### 実装内容

1. **最適化パスの設定**

   ```julia
   # src/llvmoptimization.jl

   function create_optimization_pipeline(level::Int = 2)
       pm = ModulePassManager()

       if level >= 1
           # 基本的な最適化
           add_pass!(pm, Pass("mem2reg"))
           add_pass!(pm, Pass("instcombine"))
           add_pass!(pm, Pass("simplifycfg"))
       end

       if level >= 2
           # より積極的な最適化
           add_pass!(pm, Pass("gvn"))
           add_pass!(pm, Pass("licm"))
           add_pass!(pm, Pass("loop-vectorize"))
       end

       if level >= 3
           # 最大最適化
           add_pass!(pm, Pass("slp-vectorize"))
           add_pass!(pm, Pass("aggressive-instcombine"))
       end

       pm
   end

   function optimize_llvm_module(mod::LLVM.Module, level::Int = 2)
       pm = create_optimization_pipeline(level)
       run!(pm, mod)
       mod
   end
   ```

2. **関数レベルの最適化**

   ```julia
   function optimize_function(fn::LLVM.Function, level::Int = 2)
       fpm = FunctionPassManager(fn)

       if level >= 1
           add_pass!(fpm, Pass("mem2reg"))
           add_pass!(fpm, Pass("instcombine"))
       end

       if level >= 2
           add_pass!(fpm, Pass("gvn"))
       end

       initialize!(fpm)
       run!(fpm, fn)
       finalize!(fpm)
   end
   ```

---

### タスク4: ステージド関数でのLLVM IR埋め込み

**優先度**: 最高
**見積もり**: 2週間

#### 実装内容

1. **RustInstanceの定義**

   ```julia
   # src/rustinstances.jl

   struct RustCompilerInstance
       compiler::RustCompiler
       llvm_modules::Vector{LLVM.Module}
   end

   struct RustInstance{n}
   end

   const active_rust_instances = RustCompilerInstance[]

   function instance(::RustInstance{n}) where {n}
       active_rust_instances[n]
   end

   const __current_rust_compiler__ = RustInstance{1}()
   ```

2. **ステージド関数の実装**

   ```julia
   # src/rustcodegen.jl

   @generated function rustcall(
       CT::RustInstance,
       expr::Type{RustNNS{Tnns}},
       args...
   ) where {Tnns}
       C = instance(CT)

       # 1. 関数名を取得
       func_name = get_function_name_from_nns(Tnns)

       # 2. Rustコードを取得（型情報から、またはキャッシュから）
       rust_code = get_rust_code_for_function(func_name)

       # 3. LLVM IRを生成
       llvm_mod = compile_rust_to_llvm_cached(C.compiler, rust_code)

       # 4. 最適化
       optimize_llvm_module(llvm_mod, C.compiler.optimization_level)

       # 5. 関数を取得
       fn = functions(llvm_mod)[func_name]

       if fn === nothing
           error("Function $func_name not found in LLVM module")
       end

       # 6. 型情報を取得
       ret_type = get_return_type_from_llvm(fn)
       arg_types = get_argument_types_from_llvm(fn)

       # 7. llvmcall式を生成
       Expr(:call, Core.Intrinsics.llvmcall,
           convert(Ptr{Cvoid}, fn),
           ret_type,
           Tuple{arg_types...},
           [:(args[$i]) for i in 1:length(arg_types)]...)
   end
   ```

3. **型情報の取得**

   ```julia
   function get_return_type_from_llvm(fn::LLVM.Function)
       ret_ty = return_type(fn)
       llvm_to_julia_type(ret_ty)
   end

   function get_argument_types_from_llvm(fn::LLVM.Function)
       [llvm_to_julia_type(param_type(fn, i))
        for i in 1:length(parameters(fn))]
   end

   function llvm_to_julia_type(llvm_ty::LLVM.Type)
       if isa(llvm_ty, LLVM.IntegerType)
           width = bits(llvm_ty)
           if width == 1
               return Bool
           elseif width == 8
               return Int8
           elseif width == 16
               return Int16
           elseif width == 32
               return Int32
           elseif width == 64
               return Int64
           end
       elseif isa(llvm_ty, LLVM.FloatingPointType)
           if isa(llvm_ty, LLVM.FloatType)
               return Float32
           elseif isa(llvm_ty, LLVM.DoubleType)
               return Float64
           end
       elseif isa(llvm_ty, LLVM.PointerType)
           return Ptr{Cvoid}  # より詳細な型推論が必要
       elseif isa(llvm_ty, LLVM.VoidType)
           return Cvoid
       end
       error("Unsupported LLVM type: $llvm_ty")
   end
   ```

---

### タスク5: 拡張された型システムの実装

**優先度**: 高
**見積もり**: 2週間

#### 実装内容

1. **所有権型のサポート**

   ```julia
   # src/rusttypes.jl (拡張)

   # Box<T> - ヒープに確保された値
   struct RustBox{T}
       ptr::Ptr{Cvoid}

       function RustBox{T}(ptr::Ptr{Cvoid}) where {T}
           new(ptr)
       end
   end

   # Rc<T> - 参照カウント型
   struct RustRc{T}
       ptr::Ptr{Cvoid}
       # 参照カウントはRust側で管理
   end

   # Arc<T> - アトミック参照カウント型
   struct RustArc{T}
       ptr::Ptr{Cvoid}
       # アトミック参照カウントはRust側で管理
   end
   ```

2. **コレクション型のサポート**

   ```julia
   # Vec<T>
   struct RustVec{T}
       ptr::Ptr{Cvoid}
       len::UInt
       cap::UInt
   end

   # String
   struct RustString
       vec::RustVec{UInt8}
   end

   # &str (文字列スライス)
   struct RustStr
       ptr::Ptr{UInt8}
       len::UInt
   end
   ```

3. **型変換の拡張**

   ```julia
   # src/typetranslation.jl (拡張)

   function rusttype_to_julia_extended(rust_type::String)
       # 基本型
       if haskey(RUST_TYPE_MAP, Symbol(rust_type))
           return RUST_TYPE_MAP[Symbol(rust_type)]
       end

       # Box<T>
       if startswith(rust_type, "Box<")
           inner_type = extract_generic_type(rust_type, "Box")
           return RustBox{rusttype_to_julia_extended(inner_type)}
       end

       # Vec<T>
       if startswith(rust_type, "Vec<")
           inner_type = extract_generic_type(rust_type, "Vec")
           return RustVec{rusttype_to_julia_extended(inner_type)}
       end

       # その他の型...
       error("Unsupported Rust type: $rust_type")
   end

   function extract_generic_type(type_str::String, container::String)
       # "Vec<i32>" -> "i32"
       # 実装: 正規表現またはパーサーで抽出
   end
   ```

---

### タスク6: Genericsの基本サポート

**優先度**: 中
**見積もり**: 2週間

#### 実装内容

1. **Genericsの型表現**

   ```julia
   # src/rusttypes.jl

   struct RustGeneric{T, Args}
       # T: ベース型（例: Vec）
       # Args: 型パラメータのタプル
   end

   # 例: Vec<i32> -> RustGeneric{Val{:Vec}, Tuple{Int32}}
   ```

2. **Generics関数のコンパイル**

   ```julia
   function compile_generic_rust_function(
       compiler::RustCompiler,
       code::String,
       type_params::Dict{Symbol, Type}
   )
       # 1. 型パラメータを具体的な型に置換
       specialized_code = specialize_generic_code(code, type_params)

       # 2. コンパイル
       compile_rust_to_llvm(compiler, specialized_code)
   end

   function specialize_generic_code(code::String, type_params::Dict{Symbol, Type})
       # 型パラメータを具体的な型に置換
       # 例: T -> i32
       specialized = code
       for (param, concrete_type) in type_params
           rust_type = juliatype_to_rust(concrete_type)
           specialized = replace(specialized, "T" => rust_type)
       end
       specialized
   end
   ```

---

### タスク7: メモリ管理の統合

**優先度**: 高
**見積もり**: 1週間

#### 実装内容

1. **所有権の管理**

   ```julia
   # src/memory.jl

   # Rustオブジェクトのライフサイクル管理
   const rust_object_registry = Dict{Ptr{Cvoid}, Any}()

   function register_rust_object(ptr::Ptr{Cvoid}, obj::Any)
       rust_object_registry[ptr] = obj
       finalizer(obj) do x
           # Rust側でドロップを呼び出す
           drop_rust_object(ptr)
           delete!(rust_object_registry, ptr)
       end
   end

   function drop_rust_object(ptr::Ptr{Cvoid})
       # Rust側のdrop関数を呼び出す
       # 実装: ccall経由でRustのdropを呼び出し
   end
   ```

2. **Arc<T>とJuliaのGCの統合**

   ```julia
   function create_rust_arc(T::Type, value)
       # Rust側でArc::newを呼び出す
       arc_ptr = ccall((:rust_arc_new, lib), Ptr{Cvoid}, (Any,), value)

       # Julia側で管理
       arc = RustArc{T}(arc_ptr)
       register_rust_object(arc_ptr, arc)
       arc
   end
   ```

---

### タスク8: パフォーマンス最適化

**優先度**: 中
**見積もり**: 1週間

#### 実装内容

1. **インライン化の最適化**

   ```julia
   function optimize_for_inlining(mod::LLVM.Module)
       # 小さな関数をインライン化対象としてマーク
       for fn in functions(mod)
           if length(parameters(fn)) <= 3 &&
              !has_attributes(fn, "noinline")
               add_inline_attribute!(fn)
           end
       end
   end
   ```

2. **キャッシングの改善**

   ```julia
   # コンパイル結果を永続化
   const persistent_cache = Dict{String, String}()  # code_hash -> ir_file_path

   function get_cached_llvm_ir(code_hash::String)
       if haskey(persistent_cache, code_hash)
           ir_file = persistent_cache[code_hash]
           if isfile(ir_file)
               return parse_llvm_ir(ir_file)
           end
       end
       nothing
   end
   ```

---

### タスク9: テストスイートの拡張

**優先度**: 高
**見積もり**: 1週間

#### 実装内容

1. **LLVM IR統合のテスト**

   ```julia
   # test/llvm.jl
   @testset "LLVM IR integration" begin
       rust_code = """
       pub fn add(a: i32, b: i32) -> i32 {
           a + b
       }
       """

       mod = compile_rust_to_llvm(RustCompiler(), rust_code)
       @test mod !== nothing

       fn = functions(mod)["add"]
       @test fn !== nothing
   end
   ```

2. **所有権型のテスト**

   ```julia
   # test/ownership.jl
   @testset "Ownership types" begin
       # Box, Rc, Arcのテスト
   end
   ```

---

## 実装の詳細

### ファイル構成（拡張）

```
src/
├── Rust.jl              # メインモジュール
├── rustmacro.jl         # @rust マクロ（拡張）
├── ruststr.jl           # rust"" と irust""（拡張）
├── rusttypes.jl         # Rust型の定義（拡張）
├── typetranslation.jl   # 型変換（拡張）
├── rustcompiler.jl      # Rustコンパイラ統合（新規）
├── llvmintegration.jl  # LLVM統合（新規）
├── llvmoptimization.jl # LLVM最適化（新規）
├── rustcodegen.jl      # コード生成（新規）
├── rustinstances.jl    # コンパイラインスタンス（新規）
├── memory.jl           # メモリ管理（新規）
└── exceptions.jl       # エラーハンドリング（拡張）
```

### 主要な関数のシグネチャ（拡張）

```julia
# rustcompiler.jl
RustCompiler(; kwargs...) -> RustCompiler
compile_rust_to_llvm(compiler, code; output_file) -> LLVM.Module
compile_rust_to_llvm_cached(compiler, code) -> LLVM.Module

# llvmintegration.jl
parse_llvm_ir(ir_file) -> LLVM.Module
parse_llvm_ir_string(ir_string) -> LLVM.Module
get_llvm_context(name) -> LLVM.Context

# llvmoptimization.jl
optimize_llvm_module(mod, level) -> LLVM.Module
optimize_function(fn, level) -> Nothing
create_optimization_pipeline(level) -> ModulePassManager

# rustcodegen.jl
rustcall(CT, expr, args...) -> (generated function)
get_return_type_from_llvm(fn) -> Type
get_argument_types_from_llvm(fn) -> Vector{Type}
llvm_to_julia_type(llvm_ty) -> Type

# memory.jl
register_rust_object(ptr, obj) -> Nothing
drop_rust_object(ptr) -> Nothing
create_rust_arc(T, value) -> RustArc{T}
```

---

## Phase 1からの移行

Phase 1で実装した機能をPhase 2で拡張:

1. **@rustマクロ**: ccallからllvmcallに移行
2. **rust""文字列リテラル**: 共有ライブラリからLLVM IR生成に移行
3. **型システム**: 基本型から所有権型、コレクション型に拡張

---

## 制限事項

Phase 2でも以下の制限があります:

1. **Lifetimeの明示的な扱い**: Lifetimeパラメータはまだ完全にはサポートされない
2. **Borrow checker**: コンパイル時チェックはRust側で行う
3. **マクロシステム**: proc-macroの完全サポートはまだ

---

## 次のステップ（Phase 3への移行）

Phase 2が完了したら、以下の機能をPhase 3で実装:

1. rustc内部API統合
2. Lifetimeの完全サポート
3. Borrow checkerとの統合
4. マクロシステムの完全サポート

---

## 参考実装

- Cxx.jlの`codegen.jl`を参考にする
- LLVM.jlのドキュメントを参照
- RustのLLVM IR出力を調査
