<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/internals.md. -->
# [RustCall が Rust を呼ぶ仕組み](@id How-RustCall-Calls-Rust)

`rust"""` から機械語呼び出しまでの内部構造を、開発者向けに説明します。使い方は[チュートリアル](tutorial.md)を参照してください。ここではビルド時に内部関数の例も実行しますが、公開 API ではなく変更される場合があります。

## [仕組みの概要](@id The-mechanism-in-one-paragraph)

Rust を通常の共有ライブラリへコンパイルし、C ABI の `ccall` で呼びます。

1. Rust パーサーが項目ごとの C ラッパーと署名のマニフェストを生成します。
2. Julia が rustc / Cargo で cdylib を作ります。
3. dlopen し、マニフェストから Julia 関数を生成します。
4. dlsym のアドレスへ ccall し、パニックを確認します。

```
 rust"""…"""
     │
     │  macro-expansion time
     ▼
 rustcall-extract expand ──► expanded Rust source ─────────────┐
     │                                                         │
     └──► manifest (TOML) ──► Julia wrapper definitions        │
                                                               │
     ┌──────────────────────── run time ◄──────────────────────┘
     ▼
 rustc / cargo ──► libxxx.so ──► dlopen ──► handle + symbols registered in STATE

 add(1, 2)
     │  a call
     ▼
 CallTarget (function pointer, panic channel, …)
     ──► ccall(function pointer, …)
     ──► ccall(panic channel)   # did Rust panic?
```

## [手動で全体を動かす](@id The-whole-thing-by-hand)

REPL で段階的に実行できます。

**1：展開**。`expand_inline` が展開ソースとマニフェストを返します。

```@example internals
using RustCall, Libdl

code = """
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

expanded = RustCall.expand_inline(code)
f = only(expanded.manifest["functions"])
f["name"], f["symbol"], f["return_type"], [(a["name"], a["rust_type"]) for a in f["args"]]
```

元の `add` に対して C シンボルは `rustcall_add` です。ラッパーが加わるので展開結果は長くなります。

```@example internals
count(==('\n'), code), count(==('\n'), expanded.source)
```

**2：コンパイル**。一時ファイルへ書き、`rustc --crate-type=cdylib -C opt-level=2 -C panic=unwind --target=<triple>` を実行します。

```@example internals
path = RustCall.compile_rust_to_shared_lib(RustCall.wrap_rust_code(expanded.source))
basename(path)
```

**3：読み込みと実行**。通常の Libdl と ccall を使います。

```@example internals
handle = Libdl.dlopen(path, Libdl.RTLD_LOCAL | Libdl.RTLD_NOW)
fptr   = Libdl.dlsym(handle, :rustcall_add)
ccall(fptr, Int32, (Int32, Int32), 10, 20)
```

**4：パニック確認**。`<symbol>_take_panic` が0ならパニックはありません。

```@example internals
channel = Libdl.dlsym(handle, :rustcall_add_take_panic)
ccall(channel, Csize_t, (Ptr{UInt8}, Csize_t), C_NULL, 0)
```

これが基本機構で、以降は安全性と自動化を加える部品です。

!!! warning "src 内では直接行わない"
    パッケージ内の dlopen / dlclose は `src/loading/loadpolicy.jl` だけに許可し、lint で検査します（[読み込みと生存期間](#Loading-and-lifetime)）。

## [構成要素](@id The-components)

### [Rust 側（deps）](@id Rust-side-(deps/))

Rust 構文はすべて [syn](https://docs.rs/syn) で解析します。Julia の src で正規表現解析をすると CI lint が失敗します。

| クレート | 種類 | 役割 |
|----------|------|------|
| rustcall_julia_core | ライブラリ | manifest、extract、codegen、expand、specialize、refusal |
| rustcall_extract | 実行ファイル | expand / manifest / wrap / specialize / specialize-many / schema-version の CLI |
| rustcall_julia_macros_impl | 手続きマクロ | 同じ codegen を使う属性 |
| rustcall_julia_macros | 通常ライブラリ | 属性の再公開と共有パニック状態 |
| rustcall_helpers | cdylib | RustBox / Rc / Arc / Vec のヘルパー |

`Pkg.build` は extractor と helper を作り、両方の配置・検索を共有の `src/native_layout.jl` が決めます。インラインは extractor がソースを展開し依存マクロ不要、クレートは Cargo 内で手続きマクロを実行します。どちらも同じ core の生成器・シンボル・マニフェストを使います。

### [Julia 側（src）](@id Julia-side-(src/))

全ファイルは単一の `RustCall` モジュールで、include 順が依存順です。

| ディレクトリ | 役割 | 主な入口 |
|--------------|------|----------|
| macros | マクロ・マニフェスト・生成・ジェネリクス | ruststr、rustmacro、manifest、julia_functions、generics |
| build | コンパイラと Cargo | compiler、cargoproject、cargobuild、dependencies |
| artifacts | 識別とキャッシュ | artifact_id、cache |
| loading | 登録・置換・退役 | loadpolicy、hot_reload |
| ffi | 型契約と呼び出し | ffi_contract、codegen、structs、types、memory |
| crate_bindings | 外部クレート | scan_crate、generate_bindings、2つの生成器 |
| pyo3 | Python 拡張 | [PyO3](pyo3.md) |

## [インラインブロックの流れ](@id Life-of-a-rust"""-block)

展開時と実行時を分けます。

### [マクロ展開時](@id At-macro-expansion-time)

Julia の解析・lowering 時に、cfg と既定コンパイラ設定を捕捉し、extractor の `expand --manifest ... --cfg-file ...` を実行します。TOML マニフェストの版を検査し、`(source,cfg)` で結果をメモ化します。`manifest_function_signatures` / `manifest_struct_infos` が型情報を作り、`_inline_wrapper_exprs` が関数・構造体・生成・メソッド・プロパティの式を返します。

```julia
lib_name = RustCall._compile_and_load_rust(code, file, line; cfg_text, compiler_target, compiler_level, cargo_env)
RustCall._record_module_block!(@__MODULE__, lib_name, RustBlockSnapshot(...), ["rustcall_add"])
function add(a, b) ... end        # the generated wrappers
lib_name
```

Julia 関数は展開時に存在して呼び出し元のプリコンパイルに入り、ライブラリはブロック実行時に作ります。

### [実行時](@id At-run-time)

`_compile_and_load_rust` は展開結果を取得し、`_rustc_block_identity` → `generate_cache_key` → `artifact_key` から名前 `rust_<16桁>` を決めます。既に読み込み済みならメタデータを再登録、なければディスクキャッシュ、それもなければ rustc でビルドして保存します。

登録は `_register_manifest` → `load_artifact!` で、ハンドルとシンボル・戻り値情報を一度に公開します。`cargo-deps` または Cargo ドキュメントコメント付きは一時プロジェクト、依存集合の保存済み lockfile、`cargo build --release --locked` を使い、`rust_cargo_<16桁>` になります。

### [成果物の識別](@id Artifact-identity)

`ArtifactId` が展開ソース、ターゲット・最適化、cfg、依存・lockfile、追跡環境、実コンパイラ、extractor / 生成クレートの指紋を記録し、SHA-256 が `artifact_key` です。ファイル・検索は完全なキー、表示名だけ `artifact_short_id` を使います。計算の一元化は lint で検査します。保存先は Scratch.jl です。

```@example internals
RustCall.get_cache_dir()
```

rustc 成果物とチェックサム、`metadata/`、Cargo 用の `cargo/` を置きます。

### [モジュール別の記録とプリコンパイル](@id Per-module-records-and-precompilation)

`_record_module_block!` が所属ブロックと公開シンボルを記録し、同名関数を持つ別モジュールの呼び出しを分離します。ハンドル自体はプリコンパイルできませんが、不変の `RustBlockSnapshot`（ソース・cfg・設定）を保存します。新しいプロセスの初回呼び出しは `_resolve_lib` → `ensure_loaded` でキャッシュから復元します。

## [extractor の生成物](@id What-the-extractor-generates)

元の関数を保持し、隣に次を追加します。実物は `expanded.source` で確認できます。

```rust
fn add(a: i32, b: i32) -> i32 {          // 1. the user's function, as written
    a + b
}

thread_local! {                           // 2. the panic channel: a per-thread slot
    static __RUSTCALL_PANIC_RUSTCALL_ADD: RefCell<Option<String>> = RefCell::new(None);
}
#[no_mangle]
pub extern "C" fn rustcall_add_take_panic(out: *mut u8, cap: usize) -> usize {
    /* report the stored message's length, or copy it into `out` and clear the slot */
}

#[no_mangle]                              // 3. the C-ABI wrapper
pub extern "C" fn rustcall_add(a: i32, b: i32) -> MaybeUninit<i32> {
    let _rustcall_boundary = crate::__RustCallBoundary::enter();
    match std::panic::catch_unwind(AssertUnwindSafe(|| MaybeUninit::new(add(a, b)))) {
        Ok(value) => value,
        Err(payload) => {
            /* store "add panicked: <message>" in the thread-local slot */
            MaybeUninit::zeroed()
        }
    }
}
```

属性は追加的で、シンボルは `codegen::symbol_stem` に一元化します。ルートは `rustcall_add`、モジュール内は `rustcall_a__add` などで、Julia は `symbol` / `ffi_name` を読み、独自に再構成しません。パニックは境界で捕捉し、同じ ABI の `MaybeUninit<T>` を番兵にします。unwind を固定し、ファイル末尾のフックを dlopen 直後に導入して処理済み診断を抑制します。

### [マニフェスト](@id The-manifest)

```@example internals
filter(kv -> first(kv) in ("name", "symbol", "attribute", "exported", "return_type",
                           "return_kind", "is_generic", "module_path", "skip_reason"), f)
```

`attribute` は注釈付きと手書き公開（`none`）、`return_kind` は plain / unit / result / option 等、`skip_reason` は Rust 生成器の拒否を示します。Julia と Rust のラッパーは同じ生成元の署名を使います。識別子はパッケージの MAJOR.MINOR で、異なる minor は拒否します。

## [Julia の生成物](@id What-Julia-generates)

```julia
function add(a, b)
    target = RustCall.cached_call_target(CACHE, @__MODULE__, "rustcall_add")
    RustCall.guard_rust_panic_ptr(
        RustCall.call_rust_function(target.func_ptr, Int32, Base.Int32(a), Base.Int32(b)),
        target.channel, "add")
end
```

`CACHE` は本体へ埋め込む `CallTargetCache` です。`@macroexpand` で確認できます。

### [関数の場所：cached_call_target と resolve_call_target](@id cached_call_target-/-resolve_call_target:-where-is-the-function?)

```@example internals
module Demo
using RustCall
lib = rust"""
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""
end

target = RustCall.resolve_call_target(Demo.lib, "rustcall_add")
(lib = target.lib_name, generation = target.generation, alive = target.alive[],
 return_type = target.return_type, has_channel = target.channel != C_NULL)
```

`CallTarget` はポインタ、チャネル、任意の解放関数、ハンドル、生存フラグ、戻り値型を**同じ世代**から1回のロック内で取得します。未解決シンボルだけ取得済みハンドルからロック外で解決し、イメージ別に保存します。別々に検索すると再読み込みを挟んで世代が混ざるため、4つの専用経路以外の取得は lint で拒否します。

高価な解決を毎回行わず、次の条件中は再利用します。

```@example internals
RustCall.artifact_epoch()
```

全状態更新で変わる `ARTIFACT_EPOCH` が同じであり、プロセスごとに新しく作る `SESSION_TOKEN` も同一であることです。後者でプリコンパイルに残った別プロセスのポインタを無効化します。高速経路は原子的読取と比較だけです。

### [call_rust_function と ccall](@id call_rust_function:-the-ccall)

生成関数が具体的な引数・戻り値型に対するリテラル ccall 式を作ります。

```@example internals
RustCall.call_rust_function(target.func_ptr, Int32, Int32(1), Int32(2))
```

値渡しの構造体は `ffi_check_by_value_signature` が明示登録を要求します。

### [パニックの確認](@id guard_rust_panic_ptr:-did-Rust-panic?)

`guard_rust_panic_ptr` は直後に捕捉チャネルを読みます。非ゼロなら番兵を復号せず `RustPanicError` にします。チャネルはスレッドローカルなので、Rust 呼び出しとチャネル読み取りの間にロック・ログ・I/O など**yield し得る処理を置きません**。チャネルは事前に取得します。

## [名前による rust 呼び出し](@id @rust:-calling-a-symbol-by-name)

```julia
RustCall._rust_call_typed_cached(CACHE, @__MODULE__, "", "f", T, args...)
```

注釈なしは `_rust_call_dynamic_cached` ですが、スナップショットは共通です。名前は呼び出し元のブロック（通常・ジェネリクス）を先に、次いで他ライブラリを検索し、曖昧なら拒否します。注釈は既知の戻り値と照合し、注釈なしは動的ディスパッチになります。手書き C 公開はチャネルが null で、パニックは異常終了します。

## [スカラー以外の受け渡し](@id Beyond-scalars:-how-each-kind-of-value-crosses)

型契約が C 互換表現へ変換します。未知の型は推測しません。

| Rust | C 表現 | 処理 |
|------|--------|------|
| 数値・bool | 値 | char は UInt32 と相互変換 |
| &str 引数 | ptr,len | UTF-8 を検査し Julia 値を GC 保護 |
| String 戻り値 | ptr,len,cap 集成型 | Julia へコピー後、同じライブラリで解放 |
| 数値スライス | ptr,len | 型・連続性・可変重複を検査 |
| Result/Option | repr(C) のタグ付き集成型 | Julia の RustResult / RustOption へ |
| 構造体 | 不透明ポインタ | 下記 |
| C 関数ポインタ | 関数アドレス | 下記 |

### [構造体はハンドル](@id Structs-are-handles)

コンストラクタが `Box::new` / `Box::into_raw` で生成し、`Counter_free` が戻して破棄します。

```julia
mutable struct Counter
    ptr::Ptr{Cvoid}                 # the Rust value
    lib_name::String
    free_ptr::Ptr{Cvoid}            # address of Counter_free, captured at construction
    alive::Base.RefValue{Bool}      # liveness flag of the library that allocated it
    free_channel::Ptr{Cvoid}        # panic channel of the destructor
end
```

メソッドはポインタを先頭に渡し、フィールドは Rust アクセサーを呼びます。`finalize_rust_object!` は生成時に捕捉した `free_ptr` / `alive` / `free_channel` のみを使い、ロック・検索・ログをせず、先に null 化し、閉じたイメージは呼びません。生成と解放が同じイメージであることを保証し、`test_finalizers` が検査します。

### [コールバック](@id Callbacks)

全環境で使えないクロージャ版 cfunction の代わりに、タスクローカルの `CallbackFrame` と固定 `CallbackSlot{k,R}` を使います。Julia 例外を保存しゼロを返して、Rust から戻った後に再送出します（[詳細](callbacks.md)）。

### [ジェネリクス](@id Generics)

マニフェストの `is_generic` をソースとして登録し、初回の引数型から推論、AST の特殊化、別ライブラリのビルド・保存・読み込みを行います。構造体の全メンバーは1つにまとめます（[詳細](generics.md)）。

## [外部クレートのバインド](@id @rust_crate:-binding-a-crate)

`generate_bindings` が、環境スナップショット、モジュール走査と実 cfg 再走査、直接 cdylib または依存するラッパーのビルド、Julia モジュール生成を行います。式の生成器（`@rust_crate`）とソース生成器（保存ファイル）は、配置・フィールド・ペイロード計画を共有し同等に保ちます。

```julia
const var"#TC#fn#rustcall_add" = RustCall.CrateTargetCache()
function add(a, b)
    func_ptr, panic_channel = _call_target(var"#TC#fn#rustcall_add", "rustcall_add")
    _guard_panic(RustCall.call_rust_function(func_ptr, Int32, Int32(a), Int32(b)),
                 panic_channel, "add")
end
```

モジュールの `__init__` が専用コピーを開き、原子的な `_LIB_GEN` の1記録（ハンドル・生存フラグ・世代）を読みます。保存ソースにオブジェクトを埋め込めないためキャッシュは名前付き const です。`#` や `′` を含む Rust から作れない名前で、利用者の公開名との衝突を防ぎます。

## [読み込みと生存期間](@id Loading-and-lifetime)

全ライブラリを `LoadPolicy` 付きの `load_artifact!` に通します。

```@example internals
RustCall.inline_rustc_policy()
```

dl開閉はロック外、ハンドル・キャッシュ・対応・型・生存フラグの公開は1つのロック内です。RTLD_LOCAL でハンドルごとに検索します。置換では旧イメージを退役させ、実行中のコードやデストラクタを保持します。全名・全オブジェクトがイメージごとに1つの生存フラグを共有し、明示 close だけで無効化します。各登録の世代を CallTarget が保持し、再読み込みは1トランザクションで公開します。

## [状態とスレッド](@id State-and-threads)

```julia
const STATE = Base.Lockable(RustCallState(Dict{Symbol, Any}()))
```

旧レジストリ名は `StateView`、`REGISTRY_LOCK` は STATE のロックです。ロックはメモリ内更新だけに使い、ユーザーコード、コンパイル、dlopen / dlsym / dlclose、Rust 呼び出しの間は保持しません。全更新は `_state_mutate_storage!` を通り epoch を増やします。`test_state` が外部の可変レジストリ追加を防ぎます（[詳細](panics.md)）。

## [ヘルパーライブラリ](@id The-helper-library)

RustBox / Rc / Arc / Vec は `rustcall_helpers` の具体型別 C 関数で実装します。Pkg.build が作り、`__init__` が同じロード経路で開き、memory.jl がシンボルを選びます。欠けてもパッケージは読めますが、これらの型は使えません。

## [変更箇所の案内](@id Where-to-look-when-changing-something)

| 変更 | ファイル | 検証 |
|------|----------|------|
| Rust ラッパー | core の codegen.rs | cargo test と golden corpus |
| マニフェスト | manifest.rs / extract.rs、Julia の manifest.jl | manifest / schema テスト |
| 型 | ffi_contract.jl | docs_generated |
| Julia ラッパー | julia_functions.jl / structs.jl | 機能別テスト |
| クレート生成 | crate_wrappers_expr.jl と crate_module_source.jl | crate_bindings / boundary_collect |
| キー | artifact_id.jl のみ | identity lint |
| ロード | loadpolicy.jl のみ | load lint / hot_reload_transaction |
| 呼び出し | codegen.jl / ruststr.jl | dispatch_cache / ベンチマーク |

調査用の例です。

```julia
RustCall.expand_inline(code).source           # the Rust that is actually compiled
RustCall.expand_inline(code).manifest         # what Julia is told about it
@macroexpand rust"""…"""                      # the Julia that is generated
RustCall.list_loaded_libraries()              # registered library names
RustCall.list_library_functions(lib)          # names a library registered
RustCall.inline_boundary_report(code)         # every boundary position and any refusal
RustCall.check_toolchain()                    # resolved rustc, cargo, extractor
```

deps を変えたら Julia テスト前に `julia --project deps/build.jl` で extractor を再ビルドします。[プロジェクトガイド](project_guide.md)も参照してください。
