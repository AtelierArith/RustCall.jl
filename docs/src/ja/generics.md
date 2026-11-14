<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/generics.md. -->
# [ジェネリクス](@id Generics)

Rust のジェネリック関数は、Julia の型引数付きメソッドのように、型の集まりに対して一度だけ定義します。

```rust
fn largest<T: PartialOrd + Copy>(a: T, b: T) -> T {
    if a > b { a } else { b }
}
```


```julia
largest(a::T, b::T) where {T} = a > b ? a : b      # the Julia counterpart
```

両言語とも実際に使う具体的な `T` ごとに特殊化したコードを作ります。Rust はこれを**単相化**と呼びます。Julia は初回呼び出し時、Rust はライブラリのコンパイル時に行うため、Rust ライブラリには要求済みの具体化しか含まれません。

RustCall は**新しい型の組み合わせで初めて呼ぶと、その具体化をコンパイル・保存して実行**します。構文は [Rust 入門のジェネリクス](rust_primer.md#Generics)も参照してください。

```@setup generics
using RustCall
```

## [最初のジェネリック関数](@id A-first-generic-function)

`rust"""` に定義し、`@rust` で呼びます。

```@example generics
rust"""
pub fn largest<T: PartialOrd + Copy>(a: T, b: T) -> T {
    if a > b { a } else { b }
}
"""

(@rust largest(Int32(3), Int32(7))), (@rust largest(2.5, 1.5))
```

`largest::<i32>` と `largest::<f64>` を初回だけコンパイルします。同じ型はセッション内とディスク上のキャッシュを再利用します。

[通常の関数](tutorial.md)との違いは次のとおりです。

- **`@rust` で呼ぶ**：`#[julia]` の有無によらず `largest` という Julia 関数は生成しません。
- **引数から型を推論**：`T = i32` なら `Int32(3)` を渡します。`3` は `Int64` なので `i64` になります。
- **戻り値注釈は任意**：具体化の戻り値型は既知なので、`::Float64` は付けても省いても構いません。

同じ `T` に異なる型を要求すると、コンパイル前に拒否します。

```@example generics
try
    @rust largest(1, 2.5)
catch err
    sprint(showerror, err)
end
```

## [トレイト境界](@id Trait-bounds)

`T: PartialOrd + Copy` は型が提供すべき機能を示します。Julia は実行時に `>` を試せますが、Rust は具体型を決める前に関数を検査するため、必要な機能を宣言します。不足するとコンパイラが指摘します。

```text
error[E0369]: cannot add `T` to `T`
 help: consider restricting type parameter `T` with trait `Add`
   |
   | pub fn add<T: std::ops::Add<Output = T>>(a: T, b: T) -> T {
   |             +++++++++++++++++++++++++++
```

数値コードでよく使う境界です。

| 境界 | 可能になる操作 | Julia との対応 |
|------|----------------|----------------|
| `Copy` | `.clone()` なしで値を再利用 | `isbits` の数値 |
| `PartialOrd` | `<`, `>`, `<=`, `>=` | 順序比較 |
| `PartialEq` | `==`, `!=` | 等値比較 |
| `std::ops::Add<Output = T>` | `T` を返す加算 | `T` で閉じる `+` |
| `std::ops::Mul<Output = T>` | `T` を返す乗算 | `*`。減算・除算も同様 |
| `Default` | `T::default()` | 数値の `zero(T)` に近い |
| `std::fmt::Display` | `format!("{}", x)` | `print` |

複数は `+` で結び、長い宣言は同じ意味の `where` に移せます。

```rust
pub fn dot2<T>(a: T, b: T, c: T, d: T) -> T
where
    T: std::ops::Mul<Output = T> + std::ops::Add<Output = T> + Copy,
{
    a * b + c * d
}
```

[型表](rust_primer.md#Types)の整数・浮動小数型は上記に対応します。RustCall 自身は境界を検証せず、不適合な具体化は Rust コンパイラの診断付き `RustCall.CompilationError` になります。

## [複数の型パラメーター](@id More-than-one-type-parameter)

各パラメーターは、それを使う引数から独立に推論します。

```@example generics
rust"""
pub fn pick_first<T, U>(a: T, _b: U) -> T {
    a
}
"""

@rust pick_first(Int32(10), 2.5)
```

## [ジェネリック構造体](@id Generic-structs)

インラインの `#[julia]` 構造体は Julia のパラメトリック型となり、生成時に型を明示します。

```@example generics
rust"""
#[julia]
pub struct Span<T> {
    lo: T,
    hi: T,
}

impl<T: Copy> Span<T> {
    pub fn new(lo: T, hi: T) -> Self {
        Self { lo, hi }
    }

    pub fn flip(&mut self) {
        let tmp = self.lo;
        self.lo = self.hi;
        self.hi = tmp;
    }

    pub fn low(&self) -> T {
        self.lo
    }
}
"""

s = Span{Int32}(1, 9)
flip(s)
low(s), s.hi, typeof(s)
```

`impl<T: Copy> Span<T>` は「`Copy` な各 `T` に対するメソッド」です。オブジェクトが `T` を決めるため、`flip` / `low` は通常の Julia 関数です。コンストラクタは引数から推論せず `Span{Int32}(1, 9)` と書きます。生成・破棄を含む全ラッパーを1ライブラリにまとめます（[詳細](struct_mapping.md#Generic-Structs)）。

## [呼び出し時の処理](@id What-happens-on-a-call)

1. **登録**：Rust パーサーのマニフェストからソースとシグネチャを登録します。この時点では公開関数はありません。
2. **推論**：`Int32` 引数とシグネチャから `T = i32` を求めます。
3. **特殊化**：未生成なら `rustcall-extract specialize` が型を置換し、C ABI ラッパーを追加します。

```rust
// registered:   pub fn largest<T: PartialOrd + Copy>(a: T, b: T) -> T { … }
// instantiated: pub fn largest_i32(a: i32, b: i32) -> i32 { … }
//               + #[no_mangle] pub extern "C" fn rustcall_largest_i32_…(…)
```

4. **ビルドと保存**：専用の小さなライブラリを作り、成果物キャッシュへ保存して読み込みます。
5. **実行**：通常のネイティブ呼び出しになります。

初回の3・4は `rustc` が必要です。[複数の具体化をまとめてコンパイル](@ref Compiling-several-instantiations-at-once)で前払いできます（[内部実装](#Implementation-Details)）。

## [未対応の機能](@id What-is-not-supported)

- 推論は `x: T` のように**引数そのものが型パラメーター**で、整数・浮動小数・`bool` の場合です。`xs: &[T]` を `Vector` から推論しません。要素型ごとの具体関数や、データを所有するジェネリック構造体を使います。
- 外部クレートの `#[julia]` ジェネリクスは非対応です。具体的な窓口か[明示的な具体化](crate_bindings.md#Explicit-instances-of-generic-types)を使います。
- メソッド独自の型引数は拒否します（[制約](#Limitations)）。

## [高度な使い方](@id Advanced-Usage)

### [明示的な型パラメーター](@id Explicit-Type-Parameters)

`call_generic_function` は推論しますが、[`RustCall.monomorphize_function`](@ref) は `Dict{Symbol, Type}` で型を指定し、呼ばずにビルドまたは取得できます。

```@example generics
code = """
pub fn scale<T: std::ops::Mul<Output = T>>(x: T, factor: T) -> T {
    x * factor
}
"""

RustCall.register_generic_function("scale", code, [:T])

# Explicitly monomorphize scale::<i64>; nothing is called yet
info = RustCall.monomorphize_function("scale", Dict{Symbol, Type}(:T => Int64))

# A call at the same types reuses that instantiation instead of compiling again
scaled = RustCall.call_generic_function("scale", Int64(7), Int64(6))  # => 42

# symbol: rustcall_scale_i64_<id>, argument types [Int64, Int64], returns Int64
(symbol = info.name, arg_types = info.arg_types, return_type = info.return_type, scaled)
```

同じ辞書なら再利用します。[`RustCall.precompile_generics`](@ref) は複数をまとめます（[一括コンパイル](@ref Compiling-several-instantiations-at-once)）。

### [手動登録](@id Manual-Registration)

`rust"""` で読み込まないソースも登録できます。通常の Rust と同じく `T: std::ops::Add<Output = T>` などの境界が必要ですが、C ABI ラッパーは extractor が作るため `#[no_mangle]` / `extern "C"` は不要です。

```@example generics
code = """
pub fn generic_add<T: std::ops::Add<Output = T>>(a: T, b: T) -> T {
    a + b
}
"""

RustCall.register_generic_function("generic_add", code, [:T])

# Call with different types; each new type is monomorphized on first use
sum_i32 = RustCall.call_generic_function("generic_add", Int32(10), Int32(20))  # => 30
sum_f64 = RustCall.call_generic_function("generic_add", 1.5, 2.25)             # => 3.75
(sum_i32, sum_f64)
```

### [どの `f` が呼ばれるか](@id Which-f-a-call-reaches)

型注釈とジェネリクスの有無によらず、`@rust f(x)` は次の順で解決します。

1. **呼び出し元モジュール自身のブロック**を新しい順に調べ、通常の公開関数とジェネリック登録を同時に探します。最初の定義を使うので、後のブロックは種類によらず以前の `f` を再定義します。`@rust lib::f(x)` はそのライブラリだけを調べます。
2. なければ**プロセス全体のジェネリック登録**、次いで他のライブラリの公開関数を探します。複数ライブラリの同名公開は拒否します。

各モジュールは自分の `f` に到達します。モジュールを指定しない `call_generic_function("f", ...)` は全体の最新登録です。

ジェネリック構造体の全メンバーは名前検索ではなく、定義ブロック自身の登録を使います。別モジュールの同名 `Boxed` や後の通常関数 `Boxed_new` は干渉しません。

### [依存関係付きの特殊化](@id Dependency-backed-specializations)

`// cargo-deps:` のあるブロックは、`#[cfg]` / `cfg!` を含め Cargo で特殊化します。登録時の依存仕様・環境・正確な lockfile・ルートパッケージ名を保持し、後で環境や保存済み lockfile が変わっても再現します。path 依存の変更は新しい成果物となり、既存オブジェクトは元のメンバーを使い続けます。

Cargo 設定ファイルが変わったら元のブロックを再評価します。異なる設定で条件除去済みのソースをビルドせず拒否します。構造体の全メンバーは具体化ごとに1つの Cargo イメージです。依存なしなら直接 `rustc` を使います。

## [トレイト境界の記録](@id How-trait-bounds-are-recorded)

境界はマニフェストから読みます。インライン（`T: Copy + Clone`）、`where`、`Add<Output = T>` のような引数付きトレイト、それらの併用に対応します。

### [境界の利用](@id Using-Trait-Bounds)

登録時に自動で解析・保存します。

```julia
using RustCall

# Define a function with trait bounds
code = """
pub fn identity<T: Copy + Clone>(x: T) -> T {
    x
}
"""

# Signatures and trait bounds come from the FFI manifest produced by the
# Rust-side parser (rustcall-extract); Julia never parses the source itself.
manifest = RustCall.extract_manifest(code; mode = "inline")
sig = only(RustCall.manifest_function_signatures(manifest; only_attributed = false))
println(sig.constraints)  # Dict(:T => RustCall.TypeConstraints([Copy, Clone]))
```

### [制約の手動指定](@id Manually-Specifying-Constraints)

登録時に手で指定することもできます。

```julia
using RustCall

code = """
pub fn add<T>(a: T, b: T) -> T {
    a + b
}
"""

# Using RustCall.TypeConstraints (recommended)
constraints = Dict(:T => RustCall.TypeConstraints([
    RustCall.TraitBound("Copy", String[]),
    RustCall.TraitBound("Add", ["Output = T"])
]))
RustCall.register_generic_function("add", code, [:T], constraints)

# Or using the legacy string format (backward compatible)
RustCall.register_generic_function("add_legacy", code, [:T], Dict(:T => "Copy + Add<Output = T>"))
```

## [制約](@id Limitations)

### [トレイト境界の検証](@id Trait-Bounds-Validation)

Julia 型が Rust の境界を満たすかの実行時検証は未実装です。記録は資料・イントロスペクション、将来のコード生成、エラー報告に使います。実際の具体化は Rust コンパイラが検査します。

### [複雑な型推論](@id Complex-Type-Inference)

単純な引数と型パラメーターの対応に限り、複数の場合は順序に従います。戻り値からの推論などは未対応です。

### [非ジェネリック構造体のジェネリックメソッド](@id Generic-methods-of-a-non-generic-struct)

単相化するのは独立関数と構造体自身の型引数です。`impl Acc { pub fn echo<T>(&self, x: T) -> T }` や `impl Trait` は、固定シンボルのメソッドに型を結び付けられないため `compile_error!` です（#471）。独立関数、具体型ごとの委譲メソッド、または非公開にします（[構造体の説明](struct_mapping.md#Generic-methods-of-a-non-generic-struct)）。`impl<T> Wrap<T>` 内の独自 `U` も、構造体が決めるのは `T` だけなので拒否します（#477）。

ラッパーは impl とメソッドの generics / `where` を保持し、`Self` を具体的な impl 型へ書き換えます（例：`where Wrap<T>: Sized`、#482）。[where 条件](struct_mapping.md#Where-predicates)も参照してください。

## [API リファレンス](@id API-Reference)

### [型](@id Types)

- `TraitBound(trait_name, type_params)`：個々の境界。
- `TypeConstraints(bounds)`：型パラメーターの全境界。
- `GenericFunctionInfo`：ジェネリック関数情報。

### [関数](@id Functions)

#### [ジェネリック関数の管理](@id Generic-Function-Management)

- [`register_generic_function`](@ref RustCall.register_generic_function)`(func_name, code, type_params, constraints=Dict())`：登録。
- `is_generic_function(func_name)`：登録の有無。
- [`call_generic_function`](@ref RustCall.call_generic_function)`(func_name, args...)`：自動単相化して呼ぶ。
- [`monomorphize_function`](@ref RustCall.monomorphize_function)`(func_name, type_params)`：明示的単相化。
- `specialize_generic(source, fn_name, bindings, new_name)`：CLI による具体化。
- `infer_type_parameters(func_name, arg_types)`：引数型から推論。
- `julia_type_to_rust_string(T)`：Rust の型表記。

#### [トレイト境界](@id Trait-Bounds)

Rust パーサーが記録し、Julia は `GenericFunctionInfo.constraints` の `TypeConstraints` として受け取ります。Julia は Rust ソースを解析しません。

### [レジストリ](@id Registries)

- `GENERIC_FUNCTION_REGISTRY`：名前 → 全体の最新 `GenericFunctionInfo`。
- `GENERIC_FUNCTIONS_BY_LIB`：`(ライブラリ名, 関数名)` → 定義ブロックの関数・構造体ラッパー。`owner` がそのライブラリです。
- `MONOMORPHIZED_FUNCTIONS`：`(function_name, type_params_tuple)` → `FunctionInfo`。

## [例](@id Examples)

### [例1：単純なジェネリック関数](@id Example-1:-Simple-Generic-Function)

```@example generics
rust"""
pub fn identity<T>(x: T) -> T {
    x
}
"""

# Automatically monomorphized and called
result1 = @rust identity(Int32(42))::Int32  # => 42
result2 = @rust identity(Float64(3.14))::Float64  # => 3.14
println("Int32 result: $result1")
println("Float64 result: $result2")
```

### [例2：複数の型パラメーター](@id Example-2:-Multiple-Type-Parameters)

```@example generics
rust"""
pub fn first<T, U>(a: T, b: U) -> T {
    a
}
"""

result = @rust first(Int32(10), Float64(20.0))::Int32  # => 10
println("Result: $result")
```

### [例3：手動登録と単相化](@id Example-3:-Manual-Registration-and-Monomorphization)

```@example generics
# The registered source is an ordinary generic function; the extractor
# instantiates and exports it on demand. Argument types come from the manifest
# when a rust""" block is loaded; when registering by hand, pass them explicitly.
code = """
pub fn multiply<T: std::ops::Mul<Output = T>>(a: T, b: T) -> T {
    a * b
}
"""

RustCall.register_generic_function("multiply", code, [:T]; arg_types = ["T", "T"], return_type = "T")

# Call with automatic monomorphization
result = RustCall.call_generic_function("multiply", Int32(5), Int32(6))  # => 30
println("Result: $result")
```

## [内部実装](@id Implementation-Details)

### [コードの特殊化](@id Code-Specialization)

`Pkg.build("RustCall")` で用意した `rustcall-extract specialize` が次を行います。

1. `syn` で Rust を解析し、`where`、入れ子、コメントを正しく扱います。
2. シグネチャと本体の AST 上で型引数を置換します。
3. 束縛済み型引数とその `where` 条件を除去します。
4. `identity_i32` のように名前を変え、`#[no_mangle] pub extern "C" fn rustcall_identity_i32` を隣に生成します（#279）。
5. Julia の `ccall` 用マニフェストを返します。

文脈内の構造体と impl はそのままです。例えば `Point_new<T>` を `Point_new_i32` にしても、`struct Point<T>` はジェネリックのまま残します。

### [単相化の流れ](@id Monomorphization-Process)

キャッシュ確認 → `specialize`（構造体全体は `specialize-many`）→ `rustc` → 保存・読み込み → `FunctionInfo` を返します。

### [キャッシュ方針](@id Caching-Strategy)

関数名と宣言順の型引数タプルをキーにします。構造体はコンストラクタ・デストラクタを含め同じ成果物にし、割り当て元と解放先を一致させます。

#254 以降はディスクにも成果物と `<key>.spec.toml` を保存します。次のセッションでは extractor も `rustc` も不要です。記録が欠落・読めない・異形式なら再ビルドします。キーにツールチェーン識別を含み、別の extractor / core の結果を誤って復元しません。

復元時も常に**専用コピー**を開きます。退役後に再取得すると、元の静的状態・生存フラグとは独立した新しいイメージになります（#291）。キャッシュ本体は同時更新や削除が可能な保存領域なので、直接マップしません。

### [複数の具体化をまとめてコンパイル](@id Compiling-several-instantiations-at-once)

遅延生成は型ごとに1回の `rustc` と1イメージですが、`precompile_generics` は全体を1回のビルドにまとめます。

```julia
RustCall.precompile_generics("identity", Int32, Int64, Float64)
RustCall.precompile_generics("pair", (Int32, Int64), (Int64, Int32))
```

単一の型、宣言順のタプル、`param => type` の対応で指定します。メモリまたはディスクにあれば再ビルドしません。一括生成分は次のセッションで個別に復元しても1イメージを共有します。構造体は既に全メンバーが1ライブラリなので具体化ごとに作ります。

### [具体化の解放](@id Releasing-instantiations)

長いセッションで多くの型を使うとイメージが増えます。生の関数ポインタや、デストラクタポインタを保持する構造体の参照がなくなったかはレジストリから分からないため、`release_generics` は明示的に行います。

```julia
RustCall.release_generics("identity")                 # every instantiation
RustCall.release_generics("identity", Int32, Int64)   # only these
RustCall.release_generics("identity"; close = true)   # and close the images
```

通常は登録を外してイメージを退役させ、マップは残します。次の呼び出しはディスクから新しいイメージを復元し、古いポインタやオブジェクトは元のイメージを使えます。`close = true` は生存フラグを無効化して閉じるため、呼び出しやオブジェクトが残らないと確信できる場合だけ使います。

安全な回収は、まず `release_generics(f)`、利用がなくなってから `release_generics(f; close = true)` の2段階です。後者は以前退役させた分も閉じますが、戻り値の件数はその呼び出しが新たに退役させた分だけです。型指定版は対象の型を持つイメージに適用します。

一括生成分は1つを解放すると同じライブラリの他の具体化も外れます。構造体も、いずれかのメンバーを指定するとその具体化全体を外します。次に使うとキャッシュから戻ります。

## [関連情報](@id See-Also)

- [チュートリアル](tutorial.md)
- [使用例](examples.md)
- `test/test_generics.jl`：テストと例。
