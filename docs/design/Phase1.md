# Phase 1: C互換ABI経由の基本実装（MVP）

## 概要

Phase 1では、C互換ABI（Application Binary Interface）を使用して、Rust関数をJuliaから呼び出せるようにする基本的な実装を行います。このフェーズでは、Rustの高度な機能（generics、traits、ownershipシステムなど）は使用せず、基本的な型と関数呼び出しに焦点を当てます。

**目標期間**: 2-3ヶ月
**成果物**: 基本的な`@rust`マクロ、型マッピング、文字列リテラル、エラーハンドリング

---

## 実装タスク一覧

### タスク1: プロジェクト構造のセットアップ

**優先度**: 最高
**見積もり**: 1日

#### 実装内容

1. **プロジェクトディレクトリの作成**
   ```
   LastCall.jl/
   ├── Project.toml
   ├── README.md
   ├── src/
   │   ├── LastCall.jl
   │   ├── rustmacro.jl
   │   ├── ruststr.jl
   │   ├── rusttypes.jl
   │   ├── typetranslation.jl
   │   ├── exceptions.jl
   │   └── utils.jl
   ├── deps/
   │   ├── build.jl
   │   └── build_librustffi.jl
   ├── test/
   │   ├── runtests.jl
   │   ├── basic.jl
   │   ├── types.jl
   │   └── strings.jl
   └── docs/
       └── src/
           └── index.md
   ```

2. **Project.tomlの作成**
   ```toml
   name = "Rust"
   uuid = "..." # 生成されたUUID
   version = "0.1.0"

   [deps]
   Libdl = "8f399da3-3557-5675-b5ff-fb832c97cbdb"
   REPL = "3fa0cd96-eef1-5676-8a61-b3b8758bbffb"

   [extras]
   Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

   [targets]
   test = ["Test"]
   ```

3. **基本的なモジュール構造**
   ```julia
   # src/LastCall.jl
   __precompile__(true)
   module Rust

   module RustCore
       # 内部実装
   end

   # 公開API
   export @rust, @rust_str, @irust_str
   # ...

   end
   ```

---

### タスク2: 基本的な型システムの実装

**優先度**: 最高
**見積もり**: 1週間

#### 実装内容

1. **Rust型のJulia表現**

   ```julia
   # src/rusttypes.jl

   # 基本型のマッピング
   const RUST_TYPE_MAP = Dict(
       :i8 => Int8,
       :i16 => Int16,
       :i32 => Int32,
       :i64 => Int64,
       :u8 => UInt8,
       :u16 => UInt16,
       :u32 => UInt32,
       :u64 => UInt64,
       :f32 => Float32,
       :f64 => Float64,
       :bool => Bool,
       :usize => UInt,  # プラットフォーム依存
       :isize => Int,   # プラットフォーム依存
   )

   # ポインタ型
   struct RustPtr{T}
       ptr::Ptr{Cvoid}
   end

   # 参照型（Julia側ではRefとして扱う）
   struct RustRef{T}
       ptr::Ptr{Cvoid}
   end

   # Result型
   struct RustResult{T, E}
       is_ok::Bool
       value::Union{T, E}

       function RustResult{T, E}(is_ok::Bool, value) where {T, E}
           new(is_ok, value)
       end
   end

   # Option型
   struct RustOption{T}
       is_some::Bool
       value::Union{T, Nothing}

       function RustOption{T}(is_some::Bool, value) where {T}
           new(is_some, value)
       end
   end
   ```

2. **型変換関数**

   ```julia
   # src/typetranslation.jl

   """
   Rust型名（Symbol）をJulia型に変換
   """
   function rusttype_to_julia(rust_type::Symbol)
       get(RUST_TYPE_MAP, rust_type) do
           error("Unsupported Rust type: $rust_type")
       end
   end

   """
   Julia型をRust型名（String）に変換
   """
   function juliatype_to_rust(julia_type::Type)
       for (rust_sym, julia_typ) in RUST_TYPE_MAP
           if julia_typ == julia_type
               return string(rust_sym)
           end
       end
       error("Unsupported Julia type: $julia_type")
   end

   """
   Rustの関数シグネチャを解析して型情報を取得
   """
   function parse_rust_signature(sig::String)
       # 例: "fn add(a: i32, b: i32) -> i32"
       # 実装: 正規表現またはパーサーで解析
       # 戻り値: (関数名, 引数型の配列, 戻り値型)
   end
   ```

---

### タスク3: `@rust` マクロの基本実装

**優先度**: 最高
**見積もり**: 1週間

#### 実装内容

1. **マクロの基本構造**

   ```julia
   # src/rustmacro.jl

   """
       @rust expr

   Call a Rust function from Julia using C-compatible ABI.

   Examples:
       @rust add(10, 20)
       @rust mymodule::myfunction(x, y)
   """
   macro rust(expr)
       rust_impl(__module__, expr)
   end

   function rust_impl(mod, expr)
       if isexpr(expr, :call)
           build_rust_call(mod, expr)
       elseif isexpr(expr, Symbol("::"))
           build_rust_namespace_ref(mod, expr)
       else
           error("Unsupported Rust expression: $expr")
       end
   end
   ```

2. **関数呼び出しの構築**

   ```julia
   function build_rust_call(mod, expr)
       if !isexpr(expr, :call)
           error("Expected a function call, got: $expr")
       end

       fname = expr.args[1]
       args = expr.args[2:end]

       # 関数名を取得
       func_name = isa(fname, Symbol) ? string(fname) : error("Function name must be a Symbol")

       # 現在のライブラリを取得
       lib_name = get_current_lib_name()

       # 型情報を推論（実行時に決定）
       # 注: Phase 1では型情報を明示的に指定する必要がある場合がある

       # ccallを生成
       quote
           ccall((Symbol($func_name), $lib_name),
                 Any,  # 戻り値の型（後で改善）
                 ($(map(_ -> :Any, args)...),),  # 引数の型（後で改善）
                 $(map(esc, args)...))
       end
   end
   ```

3. **ライブラリ管理**

   ```julia
   # src/utils.jl

   # 現在読み込まれているRustライブラリを管理
   const loaded_libraries = Dict{String, Ptr{Cvoid}}()
   const current_lib_name = Ref{String}("")

   function get_current_lib_name()
       if isempty(current_lib_name[])
           error("No Rust library loaded. Use rust\"\" to load a library first.")
       end
       current_lib_name[]
   end

   function set_current_lib_name(name::String)
       current_lib_name[] = name
   end

   function register_library(name::String, lib::Ptr{Cvoid})
       loaded_libraries[name] = lib
       set_current_lib_name(name)
   end
   ```

---

### タスク4: `rust""` 文字列リテラルの実装

**優先度**: 高
**見積もり**: 1週間

#### 実装内容

1. **マクロの実装**

   ```julia
   # src/ruststr.jl

   """
       rust"C++ code"

   Compile and load Rust code as a shared library.
   The code will be wrapped in a C-compatible interface.

   Example:
       rust\"""
           #[no_mangle]
           pub extern "C" fn add(a: i32, b: i32) -> i32 {
               a + b
           }
       \"""
   """
   macro rust_str(str, args...)
       process_rust_string(str, true, __source__)
   end
   ```

2. **Rustコードのコンパイル**

   ```julia
   function process_rust_string(str::String, global_scope::Bool, source)
       # 1. 一時ファイルに書き込み
       tmp_file = tempname() * ".rs"
       write(tmp_file, wrap_rust_code(str))

       # 2. コンパイル
       lib_path = compile_rust_file(tmp_file)

       # 3. 共有ライブラリを読み込み
       lib = Libdl.dlopen(lib_path, Libdl.RTLD_GLOBAL)

       # 4. ライブラリを登録
       lib_name = basename(lib_path)
       register_library(lib_name, lib)

       # 5. 関数を登録（オプション）
       register_functions_from_lib(lib)

       nothing
   end

   function wrap_rust_code(code::String)
       # 必要に応じてRustコードをラップ
       # 例: extern "C"ブロックの追加など
       code
   end

   function compile_rust_file(rs_file::String)
       lib_ext = @static Sys.iswindows() ? ".dll" : (@static Sys.isapple() ? ".dylib" : ".so")
       lib_path = rs_file * lib_ext

       # rustcでコンパイル
       cmd = `rustc --crate-type cdylib -o $lib_path $rs_file`
       run(cmd)

       if !isfile(lib_path)
           error("Failed to compile Rust file: $rs_file")
       end

       lib_path
   end
   ```

3. **関数の自動登録（オプション）**

   ```julia
   function register_functions_from_lib(lib::Ptr{Cvoid})
       # 共有ライブラリからエクスポートされた関数を検出
       # 注: これは複雑な実装が必要（objdump、nmなどのツールを使用）
       # Phase 1では手動登録でも可
   end
   ```

---

### タスク5: `irust""` 文字列リテラルの実装（制限版）

**優先度**: 中
**見積もり**: 3日

#### 実装内容

1. **マクロの実装**

   ```julia
   """
       irust"Rust code"

   Execute Rust code at function scope.
   Note: This is limited in Phase 1 and may require
   compilation to a separate function.

   Example:
       function myfunc(x)
           irust\"""
               let result = $(x) * 2;
               result
           \"""
       end
   """
   macro irust_str(str, args...)
       process_irust_string(str, __source__)
   end
   ```

2. **制限版の実装**

   ```julia
   function process_irust_string(str::String, source)
       # Phase 1では、irust""は以下の制限がある:
       # 1. 単一の式のみ
       # 2. 戻り値は基本型のみ
       # 3. 関数としてコンパイルされる

       # 一時的なRust関数を生成
       func_name = "irust_func_$(hash(str))"
       rust_code = """
       #[no_mangle]
       pub extern "C" fn $func_name($(extract_args(str))) -> $(extract_return_type(str)) {
           $str
       }
       """

       # コンパイルして実行
       # （実装はrust""と同様）
   end
   ```

---

### タスク6: Result型のサポート

**優先度**: 高
**見積もり**: 1週間

#### 実装内容

1. **Result型の定義（再掲）**

   ```julia
   # src/rusttypes.jl

   struct RustResult{T, E}
       is_ok::Bool
       value::Union{T, E}
   end

   # 便利関数
   function unwrap(result::RustResult{T, E}) where {T, E}
       if result.is_ok
           return result.value::T
       else
           error("Unwrap failed: $(result.value::E)")
       end
   end

   function unwrap_or(result::RustResult{T, E}, default::T) where {T, E}
       result.is_ok ? result.value::T : default
   end
   ```

2. **Rust側のResult型の扱い**

   ```rust
   // Rust側の例
   #[repr(C)]
   pub struct RustResult<T, E> {
       pub is_ok: bool,
       pub value: *mut c_void,  // TまたはEへのポインタ
   }

   #[no_mangle]
   pub extern "C" fn divide(a: f64, b: f64) -> RustResult<f64, *const i8> {
       if b == 0.0 {
           let err_msg = CString::new("Division by zero").unwrap();
           RustResult {
               is_ok: false,
               value: err_msg.into_raw() as *mut c_void,
           }
       } else {
           RustResult {
               is_ok: true,
               value: Box::into_raw(Box::new(a / b)) as *mut c_void,
           }
       }
   }
   ```

3. **Julia側での使用**

   ```julia
   # Result型を自動的に処理するマクロ拡張
   function build_rust_call_with_result(mod, expr, result_type)
       # Result型を返す関数の場合、自動的にunwrapするオプションを提供
       # または、明示的にResult型を返す
   end
   ```

---

### タスク7: エラーハンドリング

**優先度**: 高
**見積もり**: 3日

#### 実装内容

1. **エラー型の定義**

   ```julia
   # src/exceptions.jl

   struct RustError <: Exception
       message::String
       code::Int32
   end

   Base.showerror(io::IO, e::RustError) = print(io, "RustError: $(e.message) (code: $(e.code))")
   ```

2. **Result型から例外への変換**

   ```julia
   function result_to_exception(result::RustResult{T, E}) where {T, E}
       if !result.is_ok
           error_msg = result.value
           throw(RustError(string(error_msg), 0))
       end
       result.value::T
   end
   ```

---

### タスク8: テストスイートの作成

**優先度**: 高
**見積もり**: 1週間

#### 実装内容

1. **基本テスト**

   ```julia
   # test/basic.jl
   using Rust
   using Test

   @testset "Basic Rust function calls" begin
       rust"""
       #[no_mangle]
       pub extern "C" fn add(a: i32, b: i32) -> i32 {
           a + b
       }
       """

       @test @rust add(10, 20) == 30
   end
   ```

2. **型テスト**

   ```julia
   # test/types.jl
   @testset "Type mappings" begin
       # 各型のマッピングをテスト
   end
   ```

3. **文字列リテラルテスト**

   ```julia
   # test/strings.jl
   @testset "String literals" begin
       # rust""とirust""のテスト
   end
   ```

---

## 実装の詳細

### ファイル構成

```
src/
├── LastCall.jl              # メインモジュール
├── rustmacro.jl         # @rust マクロ
├── ruststr.jl           # rust"" と irust""
├── rusttypes.jl         # Rust型の定義
├── typetranslation.jl   # 型変換
├── exceptions.jl        # エラーハンドリング
└── utils.jl             # ユーティリティ
```

### 主要な関数のシグネチャ

```julia
# rustmacro.jl
rust_impl(mod, expr) -> Expr
build_rust_call(mod, expr) -> Expr
build_rust_namespace_ref(mod, expr) -> Expr

# ruststr.jl
process_rust_string(str, global_scope, source) -> Nothing
compile_rust_file(rs_file) -> String
wrap_rust_code(code) -> String

# typetranslation.jl
rusttype_to_julia(rust_type) -> Type
juliatype_to_rust(julia_type) -> String
parse_rust_signature(sig) -> Tuple

# utils.jl
get_current_lib_name() -> String
set_current_lib_name(name) -> Nothing
register_library(name, lib) -> Nothing
```

---

## 制限事項

Phase 1では以下の制限があります:

1. **型推論の制限**: 関数の型情報を明示的に指定する必要がある場合がある
2. **Generics非対応**: Rustのジェネリクスは使用できない
3. **Traits非対応**: Rustのトレイトは使用できない
4. **所有権システム**: 所有権の詳細な管理はできない（基本的なポインタ/参照のみ）
5. **irust""の制限**: 関数スコープでの実行は制限的

---

## 次のステップ（Phase 2への移行）

Phase 1が完了したら、以下の機能をPhase 2で実装:

1. LLVM IR統合
2. より高度な型システム
3. Genericsのサポート
4. 所有権システムの統合

---

## 参考実装

- Cxx.jlの`cxxmacro.jl`と`cxxstr.jl`を参考にする
- Juliaの`ccall`のドキュメントを参照
- RustのFFIガイドを参照
