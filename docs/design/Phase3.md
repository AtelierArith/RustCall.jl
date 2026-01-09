# Phase 3: 外部ライブラリ統合とrustscript風フォーマット

## 概要

Phase 3では、外部Rustクレート（ライブラリ）を`rust""`文字列リテラル内で使用できるようにし、rustscript風の依存関係指定フォーマットをサポートします。これにより、ndarrayなどの外部ライブラリを使った実用的なコードをJuliaから直接実行できるようになります。

**目標期間**: 3-4ヶ月
**成果物**: 外部クレート依存関係管理、rustscript風フォーマット、Cargoプロジェクト自動生成、ndarray統合例

---

## 実装タスク一覧

### タスク1: 依存関係パーサーの実装

**優先度**: 最高
**見積もり**: 1週間

#### 実装内容

1. **rustscript風フォーマットの解析**

   ```julia
   # src/dependencies.jl

   """
   rustscript風の依存関係指定を解析

   サポートする形式:
   1. ドキュメントコメント形式:
      //! ```cargo
      //! [dependencies]
      //! ndarray = "0.15"
      //! serde = { version = "1.0", features = ["derive"] }
      //! ```

   2. 単一行コメント形式:
      // cargo-deps: ndarray="0.15", serde="1.0"
   """
   struct DependencySpec
       name::String
       version::Union{String, Nothing}
       features::Vector{String}
       git::Union{String, Nothing}
       path::Union{String, Nothing}
   end

   function parse_dependencies_from_code(code::String)
       deps = DependencySpec[]

       # 形式1: ドキュメントコメント形式を解析
       cargo_block = extract_cargo_block(code)
       if !isnothing(cargo_block)
           deps = vcat(deps, parse_cargo_toml_block(cargo_block))
       end

       # 形式2: 単一行コメント形式を解析
       cargo_deps_line = extract_cargo_deps_line(code)
       if !isnothing(cargo_deps_line)
           deps = vcat(deps, parse_cargo_deps_line(cargo_deps_line))
       end

       deps
   end

   function extract_cargo_block(code::String)
       # ```cargo ... ``` ブロックを抽出
       pattern = r"```cargo\n(.*?)```"s
       m = match(pattern, code)
       isnothing(m) ? nothing : m.captures[1]
   end

   function parse_cargo_toml_block(block::String)
       # TOML形式の依存関係を解析
       # [dependencies]セクションを抽出してパース
       deps = DependencySpec[]
       # 実装: TOMLパーサーまたは正規表現で解析
       deps
   end

   function extract_cargo_deps_line(code::String)
       # // cargo-deps: ... の行を抽出
       pattern = r"//\s*cargo-deps:\s*(.+?)(?:\n|$)"
       m = match(pattern, code)
       isnothing(m) ? nothing : m.captures[1]
   end

   function parse_cargo_deps_line(line::String)
       # cargo-deps: name="version", name2="version2" を解析
       deps = DependencySpec[]
       # 実装: カンマ区切りで分割してパース
       deps
   end
   ```

2. **依存関係の正規化**

   ```julia
   function normalize_dependency(dep::DependencySpec)
       # バージョン指定の正規化
       # 機能のソート
       # 重複のチェック
       dep
   end

   function merge_dependencies(deps1::Vector{DependencySpec}, deps2::Vector{DependencySpec})
       # 依存関係のマージ（重複を除去）
       merged = Dict{String, DependencySpec}()
       for dep in vcat(deps1, deps2)
           if haskey(merged, dep.name)
               # バージョン競合の解決
               merged[dep.name] = resolve_version_conflict(merged[dep.name], dep)
           else
               merged[dep.name] = dep
           end
       end
       collect(values(merged))
   end
   ```

---

### タスク2: Cargoプロジェクトの自動生成

**優先度**: 最高
**見積もり**: 1週間

#### 実装内容

1. **Cargo.tomlの生成**

   ```julia
   # src/cargoproject.jl

   struct CargoProject
       name::String
       version::String
       dependencies::Vector{DependencySpec}
       edition::String
       path::String
   end

   function create_cargo_project(
       name::String,
       dependencies::Vector{DependencySpec};
       edition::String = "2021",
       path::Union{String, Nothing} = nothing
   )
       if isnothing(path)
           path = mktempdir(prefix="lastcall_cargo_")
       end

       # Cargo.tomlを生成
       cargo_toml = generate_cargo_toml(name, dependencies, edition)
       write(joinpath(path, "Cargo.toml"), cargo_toml)

       # src/main.rsを作成（またはlib.rs）
       src_dir = joinpath(path, "src")
       mkpath(src_dir)
       lib_rs_path = joinpath(src_dir, "lib.rs")
       # lib.rsは後でRustコードを書き込む

       CargoProject(name, "0.1.0", dependencies, edition, path)
   end

   function generate_cargo_toml(name::String, deps::Vector{DependencySpec}, edition::String)
       lines = String[]
       push!(lines, "[package]")
       push!(lines, "name = \"$name\"")
       push!(lines, "version = \"0.1.0\"")
       push!(lines, "edition = \"$edition\"")
       push!(lines, "")
       push!(lines, "[lib]")
       push!(lines, "crate-type = [\"cdylib\"]")
       push!(lines, "")
       push!(lines, "[dependencies]")

       for dep in deps
           dep_line = format_dependency_line(dep)
           push!(lines, dep_line)
       end

       join(lines, "\n")
   end

   function format_dependency_line(dep::DependencySpec)
       if !isnothing(dep.git)
           return "$(dep.name) = { git = \"$(dep.git)\" }"
       elseif !isnothing(dep.path)
           return "$(dep.name) = { path = \"$(dep.path)\" }"
       elseif !isempty(dep.features)
           features_str = join(dep.features, ", ")
           return "$(dep.name) = { version = \"$(dep.version)\", features = [$features_str] }"
       else
           return "$(dep.name) = \"$(dep.version)\""
       end
   end
   ```

2. **Rustコードの統合**

   ```julia
   function write_rust_code_to_project(project::CargoProject, code::String)
       # 依存関係のコメントを除去
       clean_code = remove_dependency_comments(code)

       # lib.rsに書き込み
       lib_rs_path = joinpath(project.path, "src", "lib.rs")
       write(lib_rs_path, clean_code)
   end

   function remove_dependency_comments(code::String)
       # ```cargo ... ``` ブロックを除去
       code = replace(code, r"```cargo\n.*?```"s => "")

       # // cargo-deps: ... の行を除去
       code = replace(code, r"//\s*cargo-deps:.*?\n" => "")

       code
   end
   ```

---

### タスク3: Cargoビルド統合

**優先度**: 最高
**見積もり**: 1週間

#### 実装内容

1. **Cargoビルドの実行**

   ```julia
   # src/cargobuild.jl

   function build_cargo_project(project::CargoProject; release::Bool = false)
       # cargo buildを実行
       cmd = `cargo build $(release ? "--release" : "")`
       cd(project.path) do
           try
               run(cmd)
           catch e
               error("Cargo build failed: $e")
           end
       end

       # 生成されたライブラリのパスを取得
       lib_path = get_built_library_path(project, release)
       if !isfile(lib_path)
           error("Library not found after build: $lib_path")
       end

       lib_path
   end

   function get_built_library_path(project::CargoProject, release::Bool)
       target_dir = release ? "release" : "debug"
       lib_ext = @static Sys.iswindows() ? ".dll" : (@static Sys.isapple() ? ".dylib" : ".so")
       lib_name = "lib$(project.name)$lib_ext"
       joinpath(project.path, "target", target_dir, lib_name)
   end
   ```

2. **ビルドキャッシュの統合**

   ```julia
   function build_cargo_project_cached(
       project::CargoProject,
       code_hash::String;
       release::Bool = false
   )
       # 依存関係のハッシュも含める
       deps_hash = hash_dependencies(project.dependencies)
       cache_key = "$(code_hash)_$(deps_hash)_$(release)"

       # キャッシュをチェック
       cached_lib = get_cached_library(cache_key)
       if !isnothing(cached_lib) && isfile(cached_lib)
           return cached_lib
       end

       # ビルド
       lib_path = build_cargo_project(project, release=release)

       # キャッシュに保存
       cache_library(cache_key, lib_path)

       lib_path
   end
   ```

---

### タスク4: rust""文字列リテラルの拡張

**優先度**: 最高
**見積もり**: 1週間

#### 実装内容

1. **依存関係の自動検出と処理**

   ```julia
   # src/ruststr.jl (拡張)

   function process_rust_string_with_dependencies(str::String, global_scope::Bool, source)
       # 1. 依存関係を解析
       dependencies = parse_dependencies_from_code(str)

       # 2. 依存関係がある場合はCargoプロジェクトを作成
       if !isempty(dependencies)
           project_name = "lastcall_$(hash(str))"
           project = create_cargo_project(project_name, dependencies)

           # 3. Rustコードをプロジェクトに書き込み
           write_rust_code_to_project(project, str)

           # 4. Cargoでビルド
           lib_path = build_cargo_project_cached(project, hash(str))

           # 5. ライブラリを読み込み
           lib = Libdl.dlopen(lib_path, Libdl.RTLD_GLOBAL)
           lib_name = basename(lib_path)
           register_library(lib_name, lib)

           # 6. 一時プロジェクトをクリーンアップ（オプション）
           # cleanup_cargo_project(project)
       else
           # 依存関係がない場合は従来の方法でコンパイル
           process_rust_string(str, global_scope, source)
       end

       nothing
   end
   ```

2. **既存のprocess_rust_stringとの統合**

   ```julia
   # ruststr.jlの既存関数を拡張
   function process_rust_string(str::String, global_scope::Bool, source)
       # 依存関係をチェック
       dependencies = parse_dependencies_from_code(str)

       if !isempty(dependencies)
           return process_rust_string_with_dependencies(str, global_scope, source)
       end

       # 既存の実装（依存関係なしの場合）
       # ...
   end
   ```

---

### タスク5: 依存関係のバージョン管理と解決

**優先度**: 高
**見積もり**: 1週間

#### 実装内容

1. **バージョン競合の解決**

   ```julia
   # src/dependency_resolution.jl

   function resolve_version_conflict(dep1::DependencySpec, dep2::DependencySpec)
       if dep1.name != dep2.name
           error("Cannot resolve conflict between different dependencies")
       end

       # バージョン指定が異なる場合の解決ロジック
       # 1. より厳密なバージョン指定を優先
       # 2. セマンティックバージョニングに基づいて最新を選択
       # 3. ユーザーに警告を出す

       if dep1.version != dep2.version
           @warn "Version conflict for $(dep1.name): $(dep1.version) vs $(dep2.version). Using $(dep1.version)"
       end

       # 機能をマージ
       merged_features = unique(vcat(dep1.features, dep2.features))
       DependencySpec(
           dep1.name,
           dep1.version,  # またはより厳密なバージョン
           merged_features,
           dep1.git,
           dep1.path
       )
   end
   ```

2. **依存関係の検証**

   ```julia
   function validate_dependencies(deps::Vector{DependencySpec})
       for dep in deps
           if isnothing(dep.version) && isnothing(dep.git) && isnothing(dep.path)
               error("Dependency $(dep.name) must have version, git, or path specified")
           end
       end
   end
   ```

---

### タスク6: エラーハンドリングの拡張

**優先度**: 中
**見積もり**: 3日

#### 実装内容

1. **Cargoビルドエラーの処理**

   ```julia
   # src/exceptions.jl (拡張)

   struct CargoBuildError <: Exception
       message::String
       stderr::String
       project_path::String
   end

   Base.showerror(io::IO, e::CargoBuildError) = print(io,
       "CargoBuildError: $(e.message)\nProject: $(e.project_path)\n$(e.stderr)")

   function build_cargo_project_with_error_handling(project::CargoProject; release::Bool = false)
       cmd = `cargo build $(release ? "--release" : "")`
       cd(project.path) do
           result = run(pipeline(cmd, stdout=stdout, stderr=stderr), wait=false)
           if !success(result)
               stderr_output = read(pipeline(cmd, stderr=stdout), String)
               throw(CargoBuildError(
                   "Cargo build failed",
                   stderr_output,
                   project.path
               ))
           end
       end
   end
   ```

2. **依存関係解決エラーの処理**

   ```julia
   struct DependencyResolutionError <: Exception
       dependency::String
       message::String
   end

   Base.showerror(io::IO, e::DependencyResolutionError) = print(io,
       "DependencyResolutionError: $(e.dependency) - $(e.message)")
   ```

---

### タスク7: テストスイートの拡張

**優先度**: 高
**見積もり**: 1週間

#### 実装内容

1. **依存関係パーサーのテスト**

   ```julia
   # test/test_dependencies.jl
   @testset "Dependency parsing" begin
       code1 = """
       //! ```cargo
       //! [dependencies]
       //! serde = "1.0"
       //! ```
       """
       deps = parse_dependencies_from_code(code1)
       @test length(deps) == 1
       @test deps[1].name == "serde"
       @test deps[1].version == "1.0"

       code2 = """
       // cargo-deps: ndarray="0.15", serde={version="1.0", features=["derive"]}
       """
       deps2 = parse_dependencies_from_code(code2)
       @test length(deps2) == 2
   end
   ```

2. **Cargoプロジェクト生成のテスト**

   ```julia
   # test/test_cargo.jl
   @testset "Cargo project creation" begin
       deps = [DependencySpec("ndarray", "0.15", [], nothing, nothing)]
       project = create_cargo_project("test_project", deps)

       @test isdir(project.path)
       @test isfile(joinpath(project.path, "Cargo.toml"))

       cargo_toml = read(joinpath(project.path, "Cargo.toml"), String)
       @test occursin("ndarray = \"0.15\"", cargo_toml)
   end
   ```

3. **ndarray統合のテスト**

   ```julia
   # test/test_ndarray.jl
   @testset "ndarray integration" begin
       rust"""
       //! ```cargo
       //! [dependencies]
       //! ndarray = "0.15"
       //! ```

       use ndarray::Array2;

       #[no_mangle]
       pub extern "C" fn add_arrays(
           a_ptr: *const f64,
           b_ptr: *const f64,
           len: usize,
           result_ptr: *mut f64
       ) {
           let a = unsafe { Array2::from_shape_ptr((len, 1).f(), a_ptr) };
           let b = unsafe { Array2::from_shape_ptr((len, 1).f(), b_ptr) };
           let result = &a + &b;
           unsafe {
               std::ptr::copy_nonoverlapping(
                   result.as_ptr(),
                   result_ptr,
                   result.len()
               );
           }
       }
       """

       a = [1.0, 2.0, 3.0]
       b = [4.0, 5.0, 6.0]
       result = Vector{Float64}(undef, 3)
       @rust add_arrays(pointer(a), pointer(b), 3, pointer(result))
       @test result ≈ [5.0, 7.0, 9.0]
   end
   ```

---

## 実装の詳細

### ファイル構成（拡張）

```
src/
├── LastCall.jl              # メインモジュール
├── rustmacro.jl         # @rust マクロ
├── ruststr.jl           # rust"" と irust""（拡張）
├── rusttypes.jl         # Rust型の定義
├── typetranslation.jl   # 型変換
├── exceptions.jl        # エラーハンドリング（拡張）
├── dependencies.jl     # 依存関係パーサー（新規）
├── cargoproject.jl     # Cargoプロジェクト管理（新規）
├── cargobuild.jl       # Cargoビルド統合（新規）
├── dependency_resolution.jl  # 依存関係解決（新規）
└── ndarray.jl          # ndarray統合（新規）
```

### 主要な関数のシグネチャ

```julia
# dependencies.jl
parse_dependencies_from_code(code) -> Vector{DependencySpec}
extract_cargo_block(code) -> Union{String, Nothing}
parse_cargo_toml_block(block) -> Vector{DependencySpec}
extract_cargo_deps_line(code) -> Union{String, Nothing}
parse_cargo_deps_line(line) -> Vector{DependencySpec}
normalize_dependency(dep) -> DependencySpec
merge_dependencies(deps1, deps2) -> Vector{DependencySpec}

# cargoproject.jl
create_cargo_project(name, dependencies; kwargs...) -> CargoProject
generate_cargo_toml(name, deps, edition) -> String
format_dependency_line(dep) -> String
write_rust_code_to_project(project, code) -> Nothing
remove_dependency_comments(code) -> String

# cargobuild.jl
build_cargo_project(project; release) -> String
get_built_library_path(project, release) -> String
build_cargo_project_cached(project, code_hash; release) -> String

# dependency_resolution.jl
resolve_version_conflict(dep1, dep2) -> DependencySpec
validate_dependencies(deps) -> Nothing

# ndarray.jl
RustNdArray(ptr, shape, strides) -> RustNdArray
create_rust_ndarray(arr) -> RustNdArray
to_julia_array(ndarr) -> Array
```

---

## 使用例

### 基本的な外部ライブラリの使用

```julia
using LastCall

# serdeを使用した例
rust"""
//! ```cargo
//! [dependencies]
//! serde = { version = "1.0", features = ["derive"] }
//! serde_json = "1.0"
//! ```

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
pub struct Person {
    name: String,
    age: u32,
}

#[no_mangle]
pub extern "C" fn serialize_person(name_ptr: *const u8, name_len: usize, age: u32) -> *mut u8 {
    let name = unsafe {
        std::str::from_utf8(std::slice::from_raw_parts(name_ptr, name_len)).unwrap()
    };
    let person = Person {
        name: name.to_string(),
        age,
    };
    let json = serde_json::to_string(&person).unwrap();
    // メモリ管理の実装が必要
    // ...
}
"""
```

### ndarrayを使った数値計算

```julia
using LastCall

rust"""
//! ```cargo
//! [dependencies]
//! ndarray = "0.15"
//! ```

use ndarray::{Array2, Axis};

#[no_mangle]
pub extern "C" fn matrix_sum_rows(
    data_ptr: *const f64,
    rows: usize,
    cols: usize,
    result_ptr: *mut f64
) {
    let arr = unsafe {
        Array2::from_shape_ptr((rows, cols).f(), data_ptr)
    };
    let sums = arr.sum_axis(Axis(0));
    unsafe {
        std::ptr::copy_nonoverlapping(
            sums.as_ptr(),
            result_ptr,
            sums.len()
        );
    }
}
"""

# Juliaから使用
matrix = [1.0 2.0 3.0; 4.0 5.0 6.0]
result = Vector{Float64}(undef, 3)
@rust matrix_sum_rows(pointer(matrix), 2, 3, pointer(result))
println(result)  # => [5.0, 7.0, 9.0]
```

### 単一行コメント形式の使用

```julia
rust"""
// cargo-deps: tokio="1.0", serde="1.0"

// 非同期処理の例（簡略化）
"""
```

---

## Phase 2からの移行

Phase 2で実装した機能をPhase 3で拡張:

1. **rust""文字列リテラル**: 依存関係の自動検出とCargoプロジェクト生成
2. **コンパイルキャッシュ**: 依存関係のハッシュも含めたキャッシュキー
3. **エラーハンドリング**: Cargoビルドエラーの詳細な表示

---

## 制限事項

Phase 3でも以下の制限があります:

1. **proc-macroのサポート**: proc-macroを使用するクレートは制限的にサポート
2. **ビルド時間**: 外部依存関係がある場合、初回ビルドに時間がかかる
3. **プラットフォーム固有の依存関係**: 一部のクレートは特定のプラットフォームでのみ動作
4. **メモリ管理**: 複雑なデータ構造の受け渡しには追加の実装が必要

---

## 次のステップ（将来の拡張）

Phase 3が完了したら、以下の機能を検討:

1. **依存関係の事前コンパイル**: よく使うクレートを事前にビルド
2. **バイナリキャッシュ**: ビルド済みライブラリの共有
3. **より高度な型マッピング**: 複雑なRust型の自動マッピング
4. **非同期処理の統合**: tokioなどの非同期ランタイムとの統合

---

## 参考実装

- [rust-script](https://github.com/fornwall/rust-script) - Rustスクリプト実行ツール
- [cargo-script](https://github.com/DanielKeep/cargo-script) - Cargoベースのスクリプト実行
- [ndarray-rs](https://github.com/rust-ndarray/ndarray) - Rustの多次元配列ライブラリ
- Cargoのドキュメント: [The Cargo Book](https://doc.rust-lang.org/cargo/)
