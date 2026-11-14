<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/pyo3.md. -->
# [PyO3 クレート](@id PyO3-Crates)

[PyO3](https://pyo3.rs) は Rust で Python 拡張を作るライブラリです。科学計算向けの多くの Rust コードもこの形で配布されています。RustCall はクレートを変更・fork して `#[julia]` を加えなくても、Julia から利用できます。

!!! note "このページの対象"
    Python 向け PyO3 クレートを呼ぶ場合や、同じ Rust クレートを両言語から使う場合に参照してください。Julia 専用なら[外部クレートのバインディング](crate_bindings.md)で十分です。最初の3節が導入で、以降は拒否されたビルドや項目を調べる資料です。

## [Julia 利用者向けの PyO3 入門](@id PyO3-in-a-minute,-for-Julia-users)

RustCall の属性と同様に、公開内容に属性を付けます。

```rust
use pyo3::prelude::*;

#[pyfunction]
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[pyclass]
pub struct Point {
    #[pyo3(get, set)]
    pub x: f64,
    #[pyo3(get, set)]
    pub y: f64,
}

#[pymethods]
impl Point {
    #[new]
    pub fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    pub fn norm(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}
```

| PyO3 | 意味 | Julia への対応 |
|------|------|----------------|
| `#[pyfunction]` | Python 関数 | Julia 関数 |
| `#[pyclass]` | Python クラス | ハンドルを持つ型 |
| `#[pymethods] impl` | メソッド | オブジェクトを先頭に渡す関数 |
| `#[new]` | コンストラクタ | `Point(3.0, 4.0)` |
| `#[staticmethod]` | `self` なし | 静的メソッド |
| `#[pyo3(get, set)]`, `#[getter]`, `#[setter]` | 属性 | `p.x` / `p.x = …` |
| `PyResult<T>` | 値または Python 例外 | `RustCall.RustResult{T, String}` |
| `#[pymodule]` | Python モジュールへの登録 | Python ホストが項目を取得 |

## [2つのバインド方法](@id Two-ways-to-bind-a-PyO3-crate)

| | ネイティブラッパー（既定） | Python ホスト（`pyo3_host=true`） |
|-|---------------------------|----------------------------------|
| 仕組み | 別クレートから通常の Rust として呼び C ABI を公開 | 既存 Python 拡張としてビルドし [PythonCall](https://github.com/JuliaPy/PythonCall.jl) で import |
| インタープリター | 起動しない | PythonCall のものを起動 |
| `using PythonCall` | 不要 | 必要 |
| 対象 | 公開され、Python 型を含まない Rust 項目 | `#[pymodule]` が登録する非公開項目、numpy、callable なども含む |
| PyResult の診断 | 固定文 | 元の Python 例外メッセージ |
| 所有権 | Julia finalizer が破棄 | Python が所有 |
| 用途 | 数値・文字列・自作構造体が中心 | Python オブジェクトを使う拡張 |

迷ったらネイティブを試し、`scan_report` の `not_public` / `pyo3_type` が必要項目に出るならホストを使います。

### [ネイティブラッパー](@id The-native-wrapper)

```julia
using RustCall

Sample = @rust_crate "path/to/pyo3_crate"

Sample.add(2, 3)              # => 5
p = Sample.Point(3.0, 4.0)
Sample.norm(p)                # => 5.0
p.x                           # => 3.0
```

pyo3 が任意依存で feature を無効にしたビルドなら Python は不要です。必須依存ならリンク可能な libpython を持つ Python（Linux の `python3-dev` や conda など）が必要です。`PYO3_PYTHON` で選択しますが、リンクするだけで起動しません。Unix で `extension-module` を有効にしたビルドは Python 自身が読み込む形式なので拒否し、ホスト経路を使います（Windows の例外は後述）。[リンク計画](#The-link-plan)を参照してください。

### [Python ホスト](@id The-Python-host)

```julia
using RustCall
using PythonCall

Sample = @rust_crate "path/to/pyo3_crate" pyo3_host=true

Sample.add(2, 3)
Sample.Point(3.0, 4.0).x
```

詳しくは[ホスト経路](#The-Python-host-path)を参照してください。

### [1クレートを両言語で使う](@id One-crate-for-both-languages)

`#[julia]` は元の定義を保つため、PyO3 の属性と併記できます。

```rust
#[julia]
#[cfg_attr(feature = "python", pyo3::pyfunction)]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

`python` feature と任意依存で `#[cfg_attr(feature = "python", …)]` を切り替えれば、Julia ビルドは Python を参照せず、`maturin build --features python` は同じ関数を公開できます。Julia 側は `#[julia]` の全機能を使えます。完全な例は `examples/SampleCratePyO3.jl` です。内側の PyO3 属性の制約は後述します。

## [このページの案内](@id Where-to-find-what-on-this-page)

[Python ホスト](#The-Python-host-path)、[ネイティブ利用](#Using-it)、[走査](#Scanning-a-crate)、[マニフェスト](#What-the-manifest-records)、[リンク計画](#The-link-plan)、[任意依存化の制約](#Making-pyo3-optional:-the-cfg_attr-limitation)の順に説明します。

内部では、**走査**（`scan_report`）が項目と拒否理由、**リンク計画**（`pyo3_link_plan`）がリンク可能性とフラグを決定し、**ラッパークレート**を `@rust_crate` / `write_bindings_to_file` が生成・ビルドします。旧称は Phase 1 / 1.5 / 2 です。

## [Python ホスト経路](@id The-Python-host-path)

ネイティブは外から `pub` な項目を呼びますが、PyO3 自体は `pub` を要求せず、`Python<'_>`、`Py<T>`、numpy、callable を使います。そのまま利用するのが `pyo3_host=true` です（#424）。既存の拡張形式でビルドし、PythonCall から import して呼びます。

```julia
using RustCall
using PythonCall            # enables the RustCallPyO3HostExt package extension

Sample = @rust_crate "path/to/pyo3_crate" pyo3_host=true
Sample.add(Int32(2), Int32(3))
Sample.Point(3.0, 4.0).x
```

ラッパークレートや `pub` は不要です。値変換・GIL・生存管理は PythonCall が担い、PyResult のエラーは実メッセージです。フィールドは Python の descriptor を通るので非公開でも使えます。Python が所有し、生成デストラクタや `finalize` はありません。

プリコンパイル中は Python を起動できないため、初回呼び出し時に `PYO3_PYTHON = PythonCall.python_executable_path()` に固定してビルドします。ソースとインタープリターは成果物キーに含みます。例です。

```julia
Sample = @rust_crate "examples/SampleCratePyO3Only.jl/deps/sample_crate_pyo3_only" \
    submodule="Bindings" pyo3_host=true
```

これらのクレートは `pub` なし、`cdylib` と `extension-module` の組み合わせです。`RustCrateMacroPyO3Only.jl`、両属性を持つ `SampleCratePyO3.jl` もあります。ネイティブ経路は、Python 型なしの公開 API や、パニック・世代・生存管理を使いたい場合に引き続き有効です。

元が `cdylib` でなくても明示的に選んでビルドしますが、**`#[pymodule]` が登録したものだけ**に到達できます。宣言形式の入れ子モジュールも `Sample.inner.g` のように対応します。

変換は Rust の表記ではなく実行時の値に従うため、エイリアスや再公開にも対応します。引数に型注釈を付けず Python が検査します。クラスハンドルは保持する Python 値を渡し、登録クラスの戻り値は対応ハンドルになります。`None` は `nothing`、数値配列は numpy があれば `ndarray`、numpy の戻り値は Julia 配列、Julia 関数は Python callable、`Py<PyAny>` は Python オブジェクトのままです。抽出器の戻り値ヒントに合わない値も Python オブジェクトとして残します。

`classmethod` のクラスと `pass_module` のモジュールは Python が注入し、Julia 引数から除きます。get 専用フィールドへの代入は `ArgumentError` です。フィールドと getter/setter を1つのプロパティにまとめ、`r#for` → `for_`、`#[getter(end)]` → `end_`、`get_x` → `x` とします。変換後が重なる別属性は拒否します（#524）。`async fn` はイベントループがないため `async_fn` として拒否し、動かない awaitable を返しません。PyResult の Julia 型は両経路で共通です。

### [初回の費用を前払いする（#449）](@id The-first-call,-and-paying-it-earlier-(#449))

初回は走査・キー計算・検索または Cargo ビルド・import を行います。成果物があれば extractor、ツールチェーン、`cargo tree`、Python の `EXT_SUFFIX` と指紋確認などの子プロセスだけで、RustCall 自体の新規コンパイルは不要です。走査・検索は RustCall のイメージ、import は拡張モジュールのイメージに含みます。下流の独自 `precompile` は不要です。以前は動的ディスパッチの先を事前コンパイルできず、1秒近い追加費用がありました。

2つの段階を別々に呼べます。

```julia
# interpreter-free: scan, key, the cached artifact — or the build. Python runs
# only as a subprocess, for the module suffix and the interpreter fingerprint.
artifact = RustCall.build_pyo3_extension(crate; python = PythonCall.python_executable_path())

# needs the interpreter: put the artifact's directory on `sys.path` and import.
mod = RustCall.pyo3_host_import(artifact)
```

`pyo3_host_import(crate)` はこの2つです。`__init__` でビルドして成果物を保持すれば、最初の呼び出しは照合と import だけです。`deps/build.jl` は別プロセスなので成果物オブジェクトは保持できず、キャッシュだけを準備します。実行時は走査・probe・検索が必要ですが Cargo は不要です。どちらもパッケージのプリコンパイル中には行えません。

成果物の指紋（実装・版・SOABI・ライブラリ・アーキテクチャ）と `EXT_SUFFIX` を PythonCall と照合します。パスが同じでも更新で ABI は変わり、仮想環境とベースの異なるパスが同じ実体を表すこともあるためです。不一致は両方を示す `RustError` です。クレート指定の形式は直前に同じインタープリターでビルドしたため再照合を省きます。事前ビルドにも CondaPkg や `JULIA_PYTHONCALL_EXE` が選ぶ同じ Python を使います。

## [対応する pyo3 バージョン](@id Which-pyo3-versions-work)

通常の直接呼び出しは対象クレートが対応する pyo3 で使えます。**既定引数付き callable と継承クラス**のラッパーだけは `Python::initialize` / `Python::attach` を使うため **0.26 以降**が必要です。それ以前は生成コードのコンパイル前に版と最低条件を示して拒否します。

ラッパーは対象と同じ pyo3 を `rustcall_pyo3` として参照し、レジストリなら正確な版、path なら同じ場所、git なら解決済みコミットに固定します。別の pyo3 インスタンスでは Python 型やトレイトが一致しません。ラッパー自身が使う `rustcall_pyo3` / `rustcall_julia_macros` と対象名が同じなら、対象を `rustcall_target_<name>` に Cargo rename します。利用者の操作は不要です。

## [ネイティブラッパーの利用](@id Using-it)

```julia
using RustCall
# a crate written for PyO3 only; this one is RustCall's test fixture
Sample = @rust_crate "test/fixtures/sample_crate_pyo3_only"

Sample.add(Int32(2), Int32(3))          # 5
Sample.shout("hello")                   # "HELLO!"
Sample.parse("42")                      # RustResult{Int32, String}(true, 42)
Sample.render(true)                     # RustResult{String, String}
Sample.defaulted()                      # 37, from a private Rust default helper

p = Sample.Point(3.0, 4.0)              # #[new]
Sample.norm(p)                          # 5.0
p.x                                     # 3.0, through #[pyo3(get, set)]
p.x = 6.0
Sample.label(p)                         # a String method
Sample.scaled(p, 2.0)                    # a PyResult method
Sample.shifted(p, 1.0)                   # RustResult{Point, String}

c = Sample.InheritedCounter()           # #[pyclass(extends = BaseCounter)]
Sample.increment(c)                     # defaulted mutating method
```

元クレートは変えず、依存する第2クレートが `rustcall_<name>`、クラスの `rustcall_<Class>_<method>`、フィールドの getter/setter、`<Class>_free` を公開します。

公開 `String` フィールドは読み書きでき、書き込み専用も可能です。setter は UTF-8 ポインタと長さなので空文字列や NUL を保持し、不正 UTF-8 は Julia で拒否します。インラインのバインディングには `set_<field>!` もあります。非公開フィールドと frozen クラスの setter は不可です。

公開 `Vec<T>` も具体的なスカラー・ポインタ要素で対応します。getter は複製して `RustVec{T}` を返し、`collect` で Julia へコピー、`drop!` で早期解放できます。生成元世代の解放関数を保持します。setter は全要素を変換してから Rust を呼びます。`Vec<bool>`、入れ子、具体配置のない要素は除外します。

両属性が混在しても同じモジュールに公開でき、二重に付けた項目のシンボルは `#[julia]` が所有します。依存の呼び出し名は package 名ではなく `[lib] name` を使います。共通の Rust 生成器を使うため文字列・Result/Option・パニックの契約も共通で、捕捉したパニックは `RustPanicError` です。

### [feature の選択](@id Selecting-a-feature-set)

Cargo と同じ feature 一覧と既定 feature の有無を指定します。

```julia
Sample = @rust_crate "path/to/crate" features=["python"] default_features=false
```

`pyo3_feature_candidates` で pyo3 と `extension-module` を有効にする feature を調べます。feature と継承するビルド環境（`RUSTFLAGS` 等）は成果物と登録を区別します。リンク計画・Python 選択・cfg probe・キー・ビルド・記録は開始時の1つのスナップショットを使い、途中の `ENV` 変更は反映しません。選んだ Python が同じパスで置換されても、ビルド後の再確認で保存前に拒否します。

### [rlib ターゲットが必要](@id The-crate-needs-an-rlib-target)

外部ラッパーから Rust ライブラリとしてリンクできる必要があります。`crate-type` を省くか、`rlib` / `lib` / `dylib` を含めます。次の `cdylib` だけでは、

```toml
[lib]
crate-type = ["cdylib"]
```

リンク可能な依存ターゲットがないため、ビルド前に修正を案内します。

```toml
[lib]
crate-type = ["cdylib", "rlib"]
```

追加しても Python 拡張の動作は変わりません。

### [ラップしない項目と理由](@id What-is-not-wrapped,-and-why)

非公開、Python 固有型、ジェネリクス、モジュール初期化、実行器のない `async fn` は外部ラッパーから呼べません。Julia の名前衝突も拒否します。クラス、独立関数、静的メソッドの順に名前を確保し、後の衝突項目に先の項目を示します。変換時の理由は次のとおりです。

| 理由 | 意味 |
|------|------|
| `unsupported_arg:<T>` | FFI 対応型・文字列以外の引数 |
| `unsupported_return:<T>` | C ABI の1値にできない Vec・構造体・その Result ペイロード等 |
| `py_result_payload:<T>` | CResult にできない成功型。拡張は [#303](https://github.com/AtelierArith/RustCall.jl/issues/303) |
| メソッドの `unsupported_return:Result<…>` | 通常の Result/Option の変換はこの経路では独立関数のみ。`#[julia]` のメソッド用生成器は `#[pymethods]` には適用しない。拡張は #303 |
| `cfg_undecided:<predicate>` | Cargo の解決に失敗し、その項目が存在するか不明 |

`scan_report` は走査結果と、実際に生成するシンボルの両方を表示します。

```julia
RustCall.scan_report("test/fixtures/sample_crate_pyo3_only")
```

「Wrapper crate exports」にない項目はシンボルも Julia 定義も生成しません。

### [PyResult のエラーを不透明にする理由](@id PyResultT:-an-opaque-error,-on-purpose)

`PyResult<T>` は `RustResult{T,String}` です。スカラーは値、文字列はコピー後解放する所有バッファ、`PyResult<Self>` は世代付きの新しいクラスハンドルです。Err の文は常に次になります。

```julia
RustCall.PYO3_OPAQUE_ERROR
# "PyErr (Python-side error; message unavailable without an interpreter)"
```

生成する `CResult_<owner>` は `FFIByValue` のサブタイプとして、生成した C 配置を保証します（#245、#295）。

インタープリターなしでも `PyErr` の生成・破棄は安全ですが、`Display` / `Debug` は起動済み Python を要求し、C 境界を越えるパニックで異常終了します。型を読むにも Python token が必要です。このため内容を見ずに破棄し固定コードを返します。`PyResult<()>` の成功値は `nothing` です。

### [ビルドと同じ設定で走査](@id The-wrapper-is-generated-for-one-build,-and-scanned-under-it)

`plan.resolved` なら実際の feature と cfg で厳密に評価します。Cargo 不在・オフライン・解決失敗の場合だけ lenient にし、未決の条件項目を `cfg_undecided` として拒否します。

任意の pyo3 を無効にすると `cfg_attr` の Python マーカー自体が適用されず、ラッパー用項目はありません。`@rust_crate` は空の cdylib を作らず従来のバインドへ戻ります。有効なら `:link_libpython` です。したがって `:python_free` は「このビルドには pyo3 と PyO3 項目がない」という計画の結果です。`sample_crate_pyo3_optional` が両方を検証します。

## [クレートの走査](@id Scanning-a-crate)

```julia
using RustCall
RustCall.scan_report("test/fixtures/sample_crate_pyo3_only")
```


```text
Crate sample_crate_pyo3_only v0.1.0 (…/test/fixtures/sample_crate_pyo3_only)
  Build scanned: default features
  RustCall items (wrapped today): 0
  PyO3 items the scan can name: 13
    fn add -> i32 [py_function]
    fn shout -> String [py_function]
    fn parse -> PyResult<i32> [py_function]
    struct Point [py_class]
    method new -> Self
    method norm -> f64
    method origin -> Self
    method sum -> f64
    …
  Wrapper crate exports: 13
    fn add -> i32 [py_function] -> rustcall_add
    struct Point [py_class] -> Point_free
    method new -> Self -> rustcall_Point_new
    …
  PyO3 items skipped: 3
    fn private_add -> i32 [py_function] — not `pub`, so a wrapper crate cannot name it (rustc E0603)
    fn describe -> i32 [py_function] — the signature uses a type that needs a live Python interpreter (Python<'_>)
    fn sample_crate_pyo3_only -> PyResult<()> [py_module] — a `#[pymodule]` initializer: it only means something to Python's import machinery
  Link plan: link_libpython — pyo3 is a mandatory dependency, so the wrapper cdylib links libpython; … is added as an rpath at wrapper-build time
```

既定は Cargo の依存解決とラッパー相当の cfg probe を行います。大きなクレートでは依存全体のコンパイルに分単位・GB 単位の費用がかかるため、Cargo を全く動かさない一覧には `resolve=false` を使います。宣言だけを読み、`plan.resolved=false`、未決 cfg は未決として報告します。`generate=false` は生成器だけを省く別の指定です。

`scan_crate` の `pyo3_functions` / `pyo3_structs` でも取得できますが、既定の lenient もターゲット cfg probe や継承値の `cargo metadata` を呼ぶことがあります。Cargo 不使用には `scan_report(...; resolve=false)` または明示的な空 `cfg_text` を使います。ラッパーソースの生成だけではコンパイルしません。

## [マニフェストの内容](@id What-the-manifest-records)

| 列 | 内容 |
|----|------|
| `attribute` | `julia` / `py_function` / `py_class` / `py_methods` / `py_module`。メソッドは所属 impl の属性 |
| `vis` | `pub`、制限付き公開、非公開など元の可視性 |
| `skip_reason` | ラップできない理由 |
| `python_name` | `pyo3(name=...)`、生識別子、getter/setter のプロパティなど Python 公開名 |
| `accessor` | `getter` / `setter` |
| `py_shape` / `py_return` | `vec` / `option` の内側、`array` の rank・要素、`scalar`、`string`、`unit`、`injected`、`opaque` などのヒント。値変換後の型付けと注入引数の判別に使用 |
| `return_kind`, `ok_type`, `err_type`, `inner_type` | メソッドも含む Result 等の構造。PyResult は `py_result` |
| フィールドの `abi="vec"`, `vec_element`, `free_symbol` | 所有ベクターの要素配置と解放シンボル（旧 schema 10） |
| `python_default`, `python_kind` | 既定引数の式と種類。式の評価は元の PyO3 dispatcher（旧12） |
| `pyo3_extends`, `pyo3_options` | Python 所有の継承ハンドルの選択（旧12） |
| `python_owned_handle` | メソッド除外後もイメージ固定と finalizer を保つ正式な所有方式（旧13） |

走査時の `symbol` は生成予定の `rustcall_<name>` / `rustcall_<Struct>_<method>`、`exported=false` はまだ生成していないことを表します。

### [スキップ理由](@id Skip-reasons)

| 理由 | 意味 |
|------|------|
| `not_public` | 外からアクセスできない。非公開モジュール内でもアクセス可能な `pub use` があれば可 |
| `pyo3_type:<T>` | `PyObject`、`Py<T>`、`Bound`、`PyAny`、`Python`、`PyRef` / `PyRefMut`、`pyo3::` 型等 |
| `pymodule` | Python の import 用初期化関数 |
| `generic` | PyO3 項目の単相化は対象外 |
| `owner_skipped:<reason>` | 所属クラス自体がスキップ |
| `symbol_collision:<owner>` | 既に別項目が同じ公開名を使用。モジュール修飾後も、例えば `P_get_v` 関数と P の v getter が衝突する場合 |

PyO3 はクレート内で生成するため `pub` 不要ですが、外のラッパーは E0603 になります。ネイティブを使うなら公開し、変更できない場合はホストを使ってください。

### [PyResult はスキップではなく変換](@id PyResultT-is-wrapped,-not-skipped)

`return_kind=py_result` と `ok_type` を記録します。生成コードは `PyErr` をフォーマットせず、不透明な失敗フラグへ変換します。

### [pyclass は不透明なハンドル](@id [pyclass]-structs-are-opaque-handles)

`#[repr(C)]` は不要です。通常は Rust 値を Box 化し Rust アクセサーから扱います。継承や既定引数を使うクラスは Python 所有にし、Julia にはどちらも `Ptr{Cvoid}` だけを見せます。

フィールドは PyO3 が公開する方向だけ、かつネイティブでは `pub` の場合だけ使えます。set 専用は読み取れません。非公開も一覧には残しますがアクセサーは生成しません。全 `pymethods` を集め、new はコンストラクタ、static/classmethod は静的、getter/setter はプロパティです。classmethod は通常 `PyType` 引数によりネイティブではスキップします。

`subclass`、`dict`、`weakref` は Python オブジェクト用です。`extends` では親子の状態を平坦な `Box<Child>` にせず登録済み Python 型を構築して `Py<PyAny>` を保持し、同じ値へ attach して操作します。finalizer は事前割り当てノードをロックフリーキューへ積むだけで、Python に attach した安全な時点で decref します。Python の型やコールバックが残るためイメージはプロセスに固定します。

CPython 3.14 はスタックアドレスで再帰と解放の延期を判断しますが、Julia タスクは OS スレッドと別スタックです。wrapper は `jl_active_task_stack` の範囲を `PyUnstable_ThreadState_SetStackProtection` に渡します（3.14.1以降、#542）。下端のガードを避け64 KiB 上から設定し、深い C 再帰は `RecursionError` にします（#546）。再入呼び出し後は前の範囲、最外では `ResetStackProtection` でスレッドの範囲へ戻します（#547）。関数は実行時に検索します。3.14より前は呼び出し数で制限するため影響しません。Linux/macOS の3.14.1以降は対応済みですが、**3.14.0 と Windows の3.14以降**は未対応で、タスクから使う Python 所有値の Drop がプロセス終了まで遅れる場合があります（#548）。

### [既定引数の Rust スコープを保つ](@id PyO3-defaults-keep-their-original-Rust-scope)

`pyo3(signature=...)`、`pyfunction` 内の署名、旧 `args` の引数種別と式を記録します。Julia は式をコピー・評価せず、各末尾省略数に対して元の PyO3 dispatcher を呼びます。非公開ヘルパーも元の場所で使え、可変メソッドは同じ Python 値を変更します。keyword-only 引数は dispatcher 側でキーワードへ移します。

`#[pyclass(generic)]` は Python の generic alias であり Rust 型引数ではありません。PyO3 0.29 は型パラメーター付きクラスやトレイトの `pymethods` をコンパイル前に拒否します。トレイトへ委譲する固有メソッドや、具体型のクラスを使います。

### [モジュールを正確に追跡](@id Modules-are-followed,-not-guessed)

`module_path` は定義位置とシンボル・Julia 階層を決め、外部向けの別名は `callable_path`（旧schema 9）に記録します。`src/lib.rs` または `[lib] path` を起点に、ファイルモジュール、`#[path]`、インライン内の外部モジュールも rustc と同じ規則で追います。非公開の親は直接アクセスを妨げますが、公開の名前付き・連鎖・glob 再公開やモジュール別名で外部経路を与えられます。非公開・制限付き import、アクセス不能な途中経路、曖昧 glob は不可です。条件付き経路の cfg を保ち、無条件経路を優先します。

別名でも所有型は定義位置に1つだけ作り、コンストラクタ・メソッド・解放はアクセス可能な Rust パスを使います。公開できても async やシグネチャの制約は残ります。生成予定などで存在しないモジュールファイルはスキップします。

### [Cargo build script の生成ソース](@id Sources-generated-by-Cargo-build-scripts)

解決済みの走査は対象パッケージの build script を先に実行し、その `OUT_DIR` / `cargo:rustc-env` で生成 include を追います。依存先や周囲の `OUT_DIR` は使いません。コミットしたファイルに PyO3 属性がなくても `include!(concat!(env!("OUT_DIR"), "/api.rs"))` から公開できます。独自 build パスと `build=false` も尊重します。

リテラル、入れ子の文字列 `concat!`、明示的環境にある `env!` に対応し、任意マクロは展開しません。不明式や欠けた変数は `skip_unparsable=true` でも抽出エラーです。未解決の通常走査は build script を動かしません。

probe と実ビルドは依存出力先を共有し、実際に読んだ生成ファイルを識別と生成モジュールの入力に含めます。クレート外の入力による内容変更も無効化し、既存イメージは元の世代を保ちます。

### [同じファイルを2つのモジュールにする](@id One-file,-two-modules)

`#[path="shared.rs"] mod a` と `b` は別項目として記録し、`rustcall_a__shared_0fn` / `rustcall_b__shared_0fn`、Julia の `bindings.a.shared_fn()` / `bindings.b.shared_fn()` に対応します（#300）。

### [pymethods のクレート全体での対応付け](@id [pymethods]-is-matched-crate-wide)

クラスと impl を全体から集め、まず同じモジュール、なければ一意の同名クラスへ結びます。複数なら修飾パスや明示的 import・as 別名で判別し、曖昧な場合は推測せず外します。

### [両方の属性がある項目](@id An-item-marked-both-ways-belongs-to-#[julia])

`#[julia]` が C シンボルを所有するため、PyO3 走査では重複ラッパーを生成しません（#279）。

## [リンク計画](@id The-link-plan)

リンク・読み込みが可能かは、Cargo が解決する pyo3 の依存と feature で決まります。

```julia
plan = RustCall.pyo3_link_plan("path/to/crate")                        # default features
plan = RustCall.pyo3_link_plan(crate; features = ["python"],
                                      default_features = false)        # a specific build
plan = RustCall.pyo3_link_plan(crate; release = false)                 # the debug profile

plan.mode                        # :python_free | :link_libpython | :unlinkable
plan.feature_flags               # the Cargo flags that select this build
plan.crate_features              # the crate's features, as Cargo resolved them
plan.pyo3_features               # pyo3's resolved features (empty when absent)
plan.dependency_default_features # what its [dependencies] entry must say
plan.cfg_text                    # the configuration the crate is scanned under
plan.rpath                       # the interpreter's library directory
plan.interpreter                 # the interpreter PYO3_PYTHON is pinned to
plan.interpreter_config          # what it reports about itself (version, ABI, library)
plan.resolved                    # whether Cargo answered
plan.reason                      # why this mode was chosen
```

| モード | 条件 | ビルド |
|--------|------|--------|
| `:python_free` | 解決グラフに pyo3 なし | libpython をリンクしない |
| `:link_libpython` | pyo3 が有効 | `-L` と Unix の rpath を追加してリンク |
| `:unlinkable` | Unix で `extension-module` | 拒否し別 feature を案内 |

### [link_libpython に必要なもの](@id What-a-:link_libpython-build-needs-from-the-machine)

Linux は `libpython3.x.so`、macOS は `.dylib` または `Python3.framework`（その親の prefix）、Windows は import ライブラリ `python3xy.lib` が必要です。Windows の実行時 DLL は別で、インタープリターの隣にあるものを先に開きます。

ディレクトリも Python もなければ計画が拒否します。Python はあるが開発ライブラリがなければ、計画はディレクトリ存在だけを認めた後にリンカーが失敗します。`python3-dev` / `python3-devel`、またはライブラリ付きの Python を `PYO3_PYTHON` / `RUSTCALL_PYTHON_LIBDIR` で指定します。

リンクが必要なテストは共有ヘルパーで前提の実ファイルを検査し、不足時だけ `skipping` を出します。検出後の生成・ビルド・読み込み・呼び出しの失敗はスキップしません。Ubuntu CI は全て実行します。計画だけのテスト、走査、python_free は常に実行します。

`pyo3_dependency_toml` が対象の dependency に default-features を指定します。ラッパーの `cargo build --no-default-features` だけでは対象の既定 feature は無効になりません。

### [feature の解決は Cargo に任せる](@id Cargo-resolves-the-features,-RustCall-does-not)

推移的 feature、ターゲット依存、rename、Boolean cfg を Julia で再実装しません。ラッパー相当の edition-2021 ルートで `cargo tree -e features,normal -p <target>` を実行し、対象の lockfile とルート override を引き継ぎます。build 依存や無関係なワークスペースメンバーの `extension-module` を通常依存の有効機能と誤認しません。

`cargo rustc -- --print cfg` で実際の設定を取得し、関数・型・impl・メソッド・フィールドの `cfg` / `cfg_attr` を厳密に評価します。

### [feature セットを選ぶ](@id Choosing-a-feature-set)

計画は指定したビルドに答えるだけです。`pyo3_feature_candidates` は feature ごとの Cargo 解決で候補を提示します。

```julia
RustCall.pyo3_feature_candidates(crate)
# [(feature = "python",    activates_pyo3 = true, extension_module = false),
#  (feature = "extension", activates_pyo3 = true, extension_module = true)]
```

例えば次のクレートでは、

```toml
[features]
default = ["extension"]
python = ["dep:pyo3"]
extension = ["python", "pyo3/extension-module"]
```

既定も all も extension-module が入り不可、defaults 無効だけでは Python API も消えます。必要なのは次の組み合わせです。

```julia
plan = RustCall.pyo3_link_plan(crate; features = ["python"], default_features = false)
plan.mode   # :link_libpython
RustCall.scan_report(crate; features = ["python"], default_features = false)
```

none / default / all の列挙だけでは見つからないため、呼び出し側が候補を見て指定します。

### [Cargo が使えない場合](@id Without-Cargo)

宣言だけを保守的に読み、extension-module の宣言があれば unlinkable、その他の pyo3 があれば link_libpython、宣言が全くなければ python_free とします。rename と target 表は読みますが feature 解決はしません。`plan.resolved=false` と理由を示します。

### [link_libpython が必要な理由](@id Why-:link_libpython-exists)

extension-module を外すだけでは Python なしになりません。依存グラフに pyo3 が残ると libpython が必要です。macOS の `otool -L` と Linux の `ldd` で確認されており、pyo3 自体が無効な時だけ Python 不要です（#275）。

### [unlinkable を拒否する理由](@id Why-:unlinkable-refuses-outright)

extension-module は Python が解決する未定義シンボルを残します。macOS では依存先の `-undefined dynamic_lookup` がラッパーへ伝わらずリンクに失敗し、強制してもデータシンボルが即時解決されるため読み込めません。Linux は共有ライブラリのリンクは通っても `_Py_Dealloc` などがなく、`RTLD_NOW` / `RTLD_LAZY` とも失敗します。使えない成果物を作る前に拒否します。

### [Windows の違い](@id Windows-is-not-Unix-here)

Windows DLL はリンク時に import を解決するため、**extension-module もリンク可能**です（`extension_module_is_linkable()`）。rpath はなく `-L native=<dir>` だけを出し、生成モジュールが `plan.runtime_libraries` のフルパスで Python DLL を先に読みます。Python を問い合わせない cross/config 形式なら DLL の場所を `PATH` に用意します。

リンク設定は生成 `build.rs` の `cargo:rustc-link-search` / `cargo:rustc-link-arg` で適用し、利用者の `RUSTFLAGS`、`CARGO_ENCODED_RUSTFLAGS`、Cargo 設定を上書きしません。macOS framework は `@rpath/Python3.framework/...` なので、検索先は内部の LIBDIR ではなく framework の親です。

### [Python の選択](@id Which-Python)

`python_link_source()` がリンク先と pyo3 のインタープリターを一緒に選びます。

1. `RUSTCALL_PYTHON_LIBDIR` は指定されたディレクトリを優先。
2. `PYO3_CROSS_LIB_DIR` または `PYO3_CONFIG_FILE` の `lib_dir` は Python を探索せず使用。
3. `PYO3_PYTHON` があればその Python と報告する場所を使用。仮想環境を `PATH` のものへ置き換えない。
4. LIBDIR だけの指定ならインタープリターは `PATH` の python3。
5. 読み込み済み CondaPkg があればその環境。
6. それ以外は `PATH` の python3 / python。

ラッパーと probe は `crate_target_directory(crate,:pyo3_wrapper)` に置き、元の lockfile と `[patch]` / `[replace]` を引き継ぎます。Cargo を元クレートの場所から `--manifest-path` で呼ぶため、元の Cargo 設定やツールチェーン指定が効き、読み取り専用でも使えます。ホストは `:pyo3_host` を使います（#486）。

指紋はパスだけでなく実装・版・ABI・リンクライブラリ（`interpreter_config`）、全 `PYO3_*` と設定ファイル内容を含み、同じ場所の更新でも再ビルドします。probe はプロファイルに従い、対象をラッパーの依存として検査するため、依存では無視される対象自身の `[profile.*]` を誤適用しません。

## [pyo3 の任意依存化と cfg_attr の制約](@id Making-pyo3-optional:-the-cfg_attr-limitation)

項目属性の切り替えには `cfg_attr` が使えます。

```rust
#[cfg_attr(feature = "python", pyfunction)]
pub fn add(a: i32, b: i32) -> i32 { a + b }
```

走査は入れ子の `cfg_attr` からもマーカーを読みます。未決 feature も黙って除外しません。ただし内側の `new`、static/classmethod、getter/setter、`pyo3(get,set)` には使えません。

```rust
#[cfg_attr(feature = "python", pymethods)]
impl Point {
    #[cfg_attr(feature = "python", new)]      // error: cannot find attribute `new`
    pub fn new(x: f64) -> Self { … }
}
```

外側の手続きマクロが先に実行するため `cannot find attribute 'new'` 等になります。必須依存にするか、`cfg` で項目自体を分けます。内側属性も含めて `cfg_attr` だけで任意化できると考えないでください。クラスは通常 link_libpython となります。python_free は pyo3 無効のビルドで、解決済みの実際のマーカー適用に従います。

## [例](@id Example)

- `sample_crate_pyo3_only`：必須の macros 付き pyo3、公開・拒否関数、非公開ヘルパーの既定値、継承クラス、通常クラス、文字列、PyResult、フィールド、pymodule。計画は link_libpython で、マニフェスト・計画・ラッパーテストに使用します。
- `sample_crate_pyo3_optional`：任意依存。feature 無効なら項目なし、有効ならラップします。
- `sample_crate_pyo3_mixed`：両属性、二重注釈、package と異なる lib 名。
- `examples/SampleCratePyO3.jl`：同梱クレートを両言語向けに使う完全な例。

複数の `pymethods` ブロックを使うなら pyo3 の `multiple-pymethods` が必要です。走査できても元のクレートがコンパイルできる必要があります。

## [julia_pyo3 からの移行](@id Migrating-from-#[julia_pyo3])

`#[julia_pyo3]` は0.2.0で非推奨（[#275](https://github.com/AtelierArith/RustCall.jl/issues/275)）、0.3.0で削除（[#312](https://github.com/AtelierArith/RustCall.jl/issues/312)）されました。旧表は [v0.4.2 の資料](https://github.com/AtelierArith/RustCall.jl/blob/v0.4.2/docs/src/pyo3.md#migrating-from-julia_pyo3)にあります。同じ定義へ `#[julia]` と PyO3 本来の属性を併記してください。
