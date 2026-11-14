<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/integration_guide.md. -->
# [安全な Rust/Julia 連携](@id Safe-Rust/Julia-integration)

Rust/Julia 境界を小さく明示的な API にすると、動作を予測しやすくなります。任意の Rust クレートをそのまま投影する代わりに、配布用バインディングの設計を整理します。今後の改善は [#441](https://github.com/AtelierArith/RustCall.jl/issues/441) で追跡します。

## [推奨構成](@id Recommended-architecture)

Julia と実処理のクレートの間に、Rust の窓口層を置きます。

```text
Julia API
    |
RustCall generated wrapper (`#[julia]`)
    |
Rust facade with a small FFI surface
    |
Existing Rust crate and its internal types
```

窓口には基本値、文字列、バイトバッファ、対応する構造体を公開し、複雑なジェネリクス・トレイト・ライフタイム・非同期状態・内部型は Rust 内に保ちます。長く保持する値は、生成・操作・破棄の経路が明確な、不透明な所有オブジェクトにします。

これにより内部表現を Julia API と独立に変更でき、Julia が借用チェッカーを再現せずに済み、境界を網羅的にテストできます。安定した API には `#[julia]`、明示的な C ABI が必要なら `@rust` を使います。削除済みの `@irust` は[移行ガイド](migrating_from_irust.md)に従って置き換えます。

## [実例：`examples/SafeLedger.jl`](@id Worked-example:-examples/SafeLedger.jl)

[完全なパッケージ](https://github.com/AtelierArith/RustCall.jl/tree/main/examples/SafeLedger.jl)で、`test/test_integration_example.jl` と Examples ワークフローで検証します。

**窓口**（`deps/safe_ledger/src/lib.rs`）は公開フィールドのない `#[julia]` 構造体です。内部の `HashMap<String, i64>` は境界を通しません。

```rust
#[julia]
pub struct Ledger {
    balances: HashMap<String, i64>,
}

#[julia]
impl Ledger {
    #[julia]
    pub fn new() -> Self { /* ... */ }

    #[julia]
    pub fn withdraw(&mut self, account: &str, amount: i64) -> Result<i64, String> {
        // an unknown account, a non-positive amount or insufficient funds is an
        // `Err`, and leaves the ledger unchanged
    }

    #[julia]
    pub fn balance(&self, account: &str) -> Option<i64> { /* ... */ }
}
```

Rust の `#[cfg(test)]` テストで、バインディング以前にロジックを検証します。非公開フィールドは `HashMap`、`Vec`、`Box`、別構造体でもよく、アクセサーを生成しないため不透明なハンドルとして扱えます。

**バインディング**は1行です。プリコンパイル中に `Native` を生成します。

```julia
@rust_crate joinpath(@__DIR__, "..", "deps", "safe_ledger") submodule="Native"
```

**Julia API** は `Native` を内部に隠し、ハンドルを所有するオブジェクトで包みます。

```julia
struct LedgerError <: Exception
    msg::String
end

mutable struct Ledger
    handle::Union{Native.Ledger, Nothing}
    Ledger() = new(Native.Ledger())
end

function Base.close(ledger::Ledger)          # explicit, idempotent release
    handle = ledger.handle
    handle === nothing && return nothing
    ledger.handle = nothing
    finalize(handle)                         # runs the generated destructor now
    return nothing
end

_ok(r::RustCall.RustResult) =
    RustCall.is_ok(r) ? RustCall.unwrap(r) : throw(LedgerError(r.value))

withdraw!(ledger::Ledger, account::AbstractString, amount::Integer) =
    _ok(Native.withdraw(_handle(ledger), String(account), Int64(amount)))
```

`_handle` は閉じた値に `InvalidStateException` を投げます。`Ledger(f)` の do ブロックは例外時も閉じ、利用者に `RustResult`・ポインタ・生成型を見せません。

```julia
SafeLedger.Ledger() do ledger
    SafeLedger.deposit!(ledger, "alice", 100)   # 100
    SafeLedger.withdraw!(ledger, "alice", 500)  # throws LedgerError("insufficient funds in alice: 100 < 500")
end                                             # the Rust allocation is freed here
```

テストは生成、正常操作、失敗時の状態不変、明示的・do ブロックの解放、アンロード後を検証します。通常の `unload_library` 後は呼び出しを拒否しても退役イメージで解放できます。イメージを閉じた後は `RustError` とし、解放は何もせず、無効コードを実行する代わりにリークします。

## [文字列ペアを一括で渡す](@id Batch-string-pairs-in-one-call)

[BatchStrings.jl](https://github.com/AtelierArith/RustCall.jl/blob/main/examples/batch_strings/BatchStrings.jl) は、UTF-8 の**バイト長**を ASCII 十進数とコロンで前置し、文字列ペアを反復順につなぐ実行可能な例です。空バッチは空文字列です。コロン・空値・Unicode・NUL もエスケープ不要です。置換は順番に適用します。式の置換に応用するなら各キー・値の解析が別途必要です。`Dict` の順序は辞書に従うので、順序が重要ならペアのベクターを使います。

```julia
include("examples/batch_strings/BatchStrings.jl")
BatchStrings.replace_batch("a+b", ["a" => "b", "b" => "猫"])
# "猫+猫" (the second replacement also affects the first one's result)
```

Julia の不正 UTF-8 を拒否し、Rust は全フレーム・整数オーバーフロー・UTF-8 境界・ペアの完全性・空でないキーを検証してから適用します。不正なら `Err(String)` を Julia の `ArgumentError` に変換します。`Atom` のような状態を更新する場合は、全式の解析・検証後に候補へ適用し、成功してから状態を置換してください。この例は転送形式であり、Symbolica の解析や同時置換の実装ではありません。

文字列引数を呼び出し中にコピーし、Result の結果は生成元ライブラリで解放します。Rust の `Vec` と借用スライスは呼び出し内に留まり、その配置や Julia バッファ内のポインタは ABI に渡しません。メモリ使用はバッチ量に比例するため、巨大・非信頼入力には上限を設けます。反復処理では高価な式を所有ハンドルに保ち、更新を直列化します。ペアごとの FFI を避けますが、コピーと解析は必要で、ベンチマークは未実施です。

## [所有権と生存期間](@id Ownership-and-lifetime-rules)

- 意味が合うなら `RustBox`、`RustRc`、`RustArc`、`RustVec` を使います。`RustSlice` は借用ビューで、元の割り当てを保持・解放しないため所有者を保ちます。
- 各所有値に解放経路を1つ用意し、割り当てたライブラリ自身で解放します。
- Julia の参照より先に所有者が消える借用を返さず、所有値かハンドルを返します。
- 生ポインタ使用中は Julia の参照を保持し、低水準呼び出しでは `GC.@preserve` を使います。
- `unload_library(...; close = true)` は、依存する呼び出し・オブジェクトが残らない時だけ使います。
- エラーと後処理を API の一部として設計します。

生成ラッパーはデストラクタと生存フラグを捕捉しますが、不正ポインタや所有権移転の誤りまでは安全にしません。[型契約](type_contract.md)と[生存期間](panics.md)も参照してください。

## [単純な FFI 境界を保つ](@id Keep-the-FFI-surface-boring)

整数・浮動小数・真偽値、対応する文字列変換、所有者が明確なバッファやスライス、対応形式の `Result` / `Option`、複雑な処理を内部で行う不透明なオブジェクトを使います。単にコンパイルできるという理由で `Vec<T>` や任意の構造体を公開しないでください。[対応表](type_contract.md)と、ビルドしない境界レポートで確認します。

```julia
RustCall.boundary_report("deps/my_facade")        # a crate bound with @rust_crate
RustCall.inline_boundary_report(source)           # the source of a rust""" block
# RustCall boundary report for crate deps/my_facade: 1 unsupported position(s) of 12 checked:
#   total, argument `values`: Vec<f64> — Vec<f64>: not in the FFI contract
```

レポートは実際の生成器を記録モードで動かし、拒否する全引数・戻り値を報告します（#454）。戻り値は生成時、未対応引数は呼び出し時に失敗する場合があるため、窓口のテストに `@test isempty(RustCall.boundary_report(path; io = devnull).unsupported)` を追加すると有効です。未知の型は既定で拒否します。`:warn` を未設計 API の恒久策にしません。

`report.notes` は表現できても利用者の責任が残る位置です（#490）。生ポインタの戻り値や Result/Option ペイロードには解放情報がないので、所有権を渡すなら対応する解放関数か注釈付き構造体が必要です。インラインの手書き `#[no_mangle] extern "C"` にはパニック境界がなく、異常終了し得ます。クレートの手書き公開は `@rust_crate` が生成しないためレポート対象外です。

同時 `&mut self`、閉じたイメージ、保存・別スレッドのコールバック、Rust が作るスレッドのパニックなど、シグネチャに表れない条件も利用者が保証します。生成器自体が拒否する `unsafe fn`、未対応ジェネリクス、`impl Trait`、const 引数、不正な Result/Option、表現できない `Self`、長すぎる `&str` 借用はビルド前に `entry point` として報告します（#491、#503）。`unsafe` には必要な保証を満たす安全な窓口を作ります。

コールバックは引数位置・同期・同一スレッドだけです。この条件を API に明記してください。

## [制約の一覧](@id Limitations-at-a-glance)

| 分野 | 対応 | 未対応・利用者の責任 | 対策 |
|------|------|--------------------|------|
| スカラー | 整数、浮動小数、`bool` | Windows の128ビット整数 | 2つの `u64` かポインタ |
| 文字列 | `String` / `&str` | 不正 UTF-8 は拒否 | 非テキストはバイト列で渡す |
| コレクション | 対応数値スライスは専用契約 | `Vec`、`HashMap`、`Box` / `Rc` / `Arc` / `Cow` の直接受け渡し | 構造体内部へ保持 |
| 構造体 | ハンドルと対応型の公開フィールド | 所有者より長寿命の借用 | 所有値を返す |
| エラー | 対応型の Result/Option | — | Julia ラッパーで例外化 |
| パニック | 生成境界から `RustPanicError` | 生の C 公開、Rust の別スレッド | `#[julia]` の入口を使う |
| コールバック | 同期・同一スレッドの C 関数ポインタ引数 | 保持、別スレッド | Julia に戻って再度呼ぶ |
| スレッド | Julia の各スレッドからの呼び出し | 同じ値への並行可変アクセス | `ReentrantLock` などで直列化 |
| 生存期間 | finalizer、`finalize(obj)` | 閉じたイメージの使用は拒否しリーク | 利用がなくなってから閉じる |
| ジェネリクス | 必要時の関数・構造体の単相化 | トレイトオブジェクト等 | 具体型の窓口 |

## [ビルドと CI](@id Build-and-CI-practices)

- 再現性が必要なアプリ・fixture・連携クレートは `Cargo.lock` をコミットします。
- 初回のツールチェーン・依存取得とビルドには時間がかかるため、キャッシュを準備・保存します。
- 下流パッケージは Pkg 経由でビルドします。

```julia
using Pkg
Pkg.build("RustCall")
```

`deps/build.jl` と `RUSTCALL_EXTRACT` は RustCall ソース開発用です。下流では通常の環境とインストール済み成果物の検索を使います。

- 対応する Julia/Rust/OS と Windows のリンカー・SDK を検証します。
- 宣言済みの依存を取得後、`RUSTCALL_OFFLINE=1` の CI で未宣言の取得を検出します。
- 依存関係を窓口の背後に置き、生成範囲と環境依存ビルドを小さくします。

### [キャッシュの準備と保存](@id Warming-and-persisting-the-caches)

| 保存対象 | 場所 | 作成する処理 |
|----------|------|--------------|
| Rust ライブラリ、インライン依存の lockfile、クレートのビルド | `RustCall.get_cache_dir()` または `RUSTCALL_CACHE_DIR` | 初回ビルド |
| レジストリのクレート | `$CARGO_HOME/registry`、`$CARGO_HOME/git`（既定 `~/.cargo`） | Cargo |
| Julia のプリコンパイル | depot の `compiled/` | `Pkg.precompile()` |
| Rust の Artifacts | depot の `artifacts/` | RustToolChain |

`Pkg.precompile()` は `@rust_crate` をビルドします。インラインには初回まで遅延するものもあるため、テストや各入口を呼ぶスクリプトも実行します。GitHub Actions の例です。

```yaml
- uses: julia-actions/setup-julia@v2
- uses: julia-actions/cache@v2          # the depot: packages, artifacts, compiled/
- id: rust                                # the system toolchain, if any
  shell: bash
  run: echo "version=$( (rustc --version; cargo --version) 2>/dev/null | tr -c 'A-Za-z0-9.' '-')" >> "$GITHUB_OUTPUT"
- uses: actions/cache@v4
  with:
    path: |
      ${{ runner.temp }}/rustcall-cache
      ~/.cargo/registry
      ~/.cargo/git
    key: rustcall-${{ runner.os }}-${{ steps.rust.outputs.version }}-${{ hashFiles('deps/**/Cargo.toml', 'deps/**/Cargo.lock', 'deps/**/*.rs', 'src/**/*.jl', 'Manifest.toml') }}
    restore-keys: rustcall-${{ runner.os }}-
- run: julia --project -e 'using Pkg; Pkg.instantiate(); Pkg.precompile(); Pkg.test()'
  env:
    RUSTCALL_CACHE_DIR: ${{ runner.temp }}/rustcall-cache
```

各項目の `ArtifactId` はソース・依存・コンパイラなどを含むので、変化は誤ヒットではなくキャッシュミスになります。ただし GitHub キャッシュは不変で、外側の `hashFiles` が完全一致すると再保存しません。Rust ソース・Cargo ファイル、インラインを持つ Julia ソース、Julia `Manifest.toml`、ツールチェーン、指定した `RUSTC_WRAPPER` をキーに含めます。`PATH` に Rust がある場合は実際のバージョン、なければ Manifest が固定する Artifacts 版を使います。入力が漏れると毎回再ビルドして保存できなくなります。

### [lockfile と再現性](@id Lockfiles-and-reproducible-builds)

`// cargo-deps:` は保存した `RustCall.lockfile_path(source)` を `--locked` で使います。同じ依存解決を共有するならコピーをコミットします（[性能](performance.md)）。独自 `cdylib` は元クレートの `Cargo.lock` に従います。通常の生成ラッパーは独立ルートなので元の lockfile は適用されません。必要なら `cdylib` や `serde = "=1.0.210"` の正確な制約を使います。

オフラインでは一度オンラインで取得後に `RUSTCALL_OFFLINE=1` を設定します。不足した取得はすぐ失敗します。

### [`@rust_crate` の出力先](@id Where-@rust_crate-builds)

ビルド成果物は元クレート内に書かず、`RustCall.crate_target_directory(crate, flavour)` が決めるキャッシュに置きます（#486）。直接ビルド・再読み込み・Python ホスト・PyO3 ラッパーは元クレートを作業ディレクトリとし、`.cargo/config.toml` と `rust-toolchain.toml` を参照します。直接・再読み込み・ホストは元クレートが Cargo ルートなので `[patch]` と lockfile も有効です。PyO3 ラッパーと probe は lockfile と `[patch]` / `[replace]` をコピーします。

通常の**生成ラッパー**だけは一時プロジェクト自身からビルドします。元クレートの設定・ツールチェーン指定・patch・lockfile は適用されず、`CARGO_HOME` と環境だけで新しく解決します。cfg probe だけは元の文脈です。元の設定を使いたいなら `cdylib` を宣言します。

| 方式 | Cargo の対象 | 出力先 | `--locked` | 読み取り専用 |
|------|-------------|--------|------------|--------------|
| 直接 `cdylib` | ビルドと cfg probe | `crate_target_directory(crate)` | なし | 対応 |
| ホットリロード | 再走査 probe とビルド | 直接ビルドと同じ | なし | 対応 |
| `pyo3_host=true` | 拡張ビルド | `crate_target_directory(crate, :pyo3_host)` | なし | 対応 |
| PyO3 ラッパー | 元の場所から `--manifest-path` で probe とラッパー | `crate_target_directory(crate, :pyo3_wrapper)` | なし | 対応 |
| その他のラッパー | 一時プロジェクト自身 | その `target/`（probe は `:pyo3_wrapper`） | なし | 対応 |

ユーザーのクレートには `--locked` を付けません。直接形式の Cargo は lockfile がなければ作成し、古ければマニフェストの隣で更新します。PyO3 形式はコピーだけを更新し、通常のラッパーは元を読みません。読み取り専用の配布物は**最新の `Cargo.lock` を同梱**してください。なければ Cargo の書き込みが権限エラーになります。

出力先は `<cache>/cargo/targets/<クレートパスのダイジェスト>` の下にまとまり、キャッシュ削除の対象です。Cargo の増分状態を保つ場所で、完成ライブラリは別途成果物キーで保存します。Windows の260文字制限のため16文字の短縮 ID を使い、完全なダイジェストを内部に記録して毎回照合します。インライン依存だけは RustCall がプロジェクトを管理するため前述の `--locked` を使います。

### [ツールチェーンとプラットフォーム](@id Toolchain-and-platform-requirements)

Julia 1.12 以降、Rust stable を使い、CI は stable / beta を検証します。最低 rustc は extractor の `rust-version`（1.85）です。`check_toolchain()` は選択した実行ファイル、最低版、extractor のビルド・スキーマを、ビルドも例外送出もせず報告します。CI では `check_toolchain(; io = devnull).ok` が使えます。

RustToolChain は `PATH` を優先し、なければ Artifacts を取得します。コンパイラの変更はキャッシュを無効化します。Linux x86_64、macOS aarch64、Windows x86_64 で検証し、Windows は MSVC が必要です（[ガイド](platforms/windows.md)）。

## [デバッグの流れ](@id Debugging-workflow)

1. **ツールチェーンとビルド**：実際に選ばれるコンパイラを確認して再ビルドします。

```julia
using Pkg, RustCall
RustCall.check_toolchain()   # rustc/cargo versions, the supported floor, the extractor
Pkg.build("RustCall")
```

キャッシュ削除より先に Cargo の診断を読みます。Artifacts 版や `PATH` と異なる選択にも注意します。
2. **Rust API**：窓口を通常の Rust クレートとして先にテストします。
3. **マニフェストと ABI**：`boundary_report` / `inline_boundary_report` で未対応位置を確認し、属性と C ABI の条件を確認します。
4. **読み込み**：登録済み・退役イメージと、残る呼び出し・オブジェクトを確認します。
5. **実行時**：生成・成功・失敗・後処理を含む最小例に絞ります。

パニックを例外にするなら `#[julia]` が必要です。手書きの C 公開や Rust の別スレッドは境界外で、異常終了し得ます。

### [症状ごとの確認先](@id Troubleshooting-checklist)

| 症状 | 確認先 |
|------|--------|
| `no working rustc` / Cargo 不在 | `check_toolchain()`、Windows は MSVC |
| rustc 1.85 以上が必要 | `rustc_supported` |
| schema mismatch | `.extractor` と `Pkg.build("RustCall")` |
| 生成コードのコンパイル失敗 | `expand_inline(source).source` |
| `CargoBuildError` | Cargo 診断。オフラインならレジストリ不足 |
| 未対応型・値渡し拒否 | `boundary_report`、窓口へ内部型を隠す |
| エラーなしで誤った値 | C シグネチャ、順序、`Clong` などの幅、`bool` |
| `RustPanicError` | Rust のメッセージ、`cargo test` で再現 |
| パニックで異常終了 | 手書き公開（`.notes`）や Rust の別スレッド |
| ポインタ返却でメモリ増加 | 解放呼び出し、レポートの `.notes` |
| 解放済みオブジェクト | `close` / `finalize` 後使用 |
| 未ロードのオブジェクト | アンロードのタイミング |
| `finalizer_failure_count()` 増加 | パニックする `Drop` |
| CI で毎回初回が遅い | [キャッシュ保存](#Warming-and-persisting-the-caches) |

[トラブルシューティング](troubleshooting.md)も参照してください。

## [設計の判断基準](@id Practical-decision-rule)

Rust が自己完結した高速処理やライブラリを提供し、境界を小さくできる場合に向いています。多数の借用参照を保持したり、複雑な値をフィールド単位で往復したり、小さな処理ごとに呼ぶ必要があるなら、バインディングを増やす前に処理を Rust の窓口へまとめてください。
