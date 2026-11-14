<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/hot_reload.md. -->
# [ホットリロード](@id Hot-Reload)

Rust ソースの変更を検出してクレートを再ビルドし、実行中の Julia でライブラリを置換します。生成済みモジュールはそのまま、次の呼び出しから新コードを使います。

```@setup hotreload
using RustCall
```

## [対応範囲](@id What-it-supports)

| 入口 | 対応 |
|------|------|
| 独自 `cdylib` の `@rust_crate` | `enable_hot_reload_for_crate` で対応 |
| cdylib のない生成ラッパー経由 | 有効化時に `ArgumentError` |
| path 依存付きインライン | 非対応。ブロックを再評価 |
| 通常のインライン・ジェネリクス | 再評価で新ライブラリを作る |

path 依存を含むブロックは、その依存を静的リンクした独自の `rust_cargo_<id>` です。依存の cdylib を作り直してもブロックのラッパーを含まないため置換できません。依存内容も成果物キーに入るので、編集後のブロック再評価で正しく更新します。

## [完全な例](@id A-complete-example)

独自 cdylib の注釈付きクレートです。ソース開発時のマクロ依存には `rustcall_runtime_crate_path()` を使えます（[外部クレート](crate_bindings.md)）。

```@example hotreload
crate = joinpath(mktempdir(), "hot_counter")
mkpath(joinpath(crate, "src"))
runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
write(joinpath(crate, "Cargo.toml"), """
    [package]
    name = "hot_counter"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    rustcall_julia_macros = { path = "$(runtime)" }
    """)
write(joinpath(crate, "src", "lib.rs"), """
    use rustcall_julia_macros::julia;

    #[julia]
    pub fn step() -> i32 { 1 }
    """)

HotCounter = @rust_crate crate
first_step = HotCounter.step()   # 1
```

マクロの戻り値を渡すと、モジュール自身のビルド記録で再ビルドできます。この例はコールバックからチャネルへ結果を送り、完了を待ちます。

```@example hotreload
reloads = Channel{Bool}(Inf)
state = RustCall.enable_hot_reload_for_crate(HotCounter;
    poll = true, interval = 0.25,
    callback = (lib_name, success, error) -> put!(reloads, success))
state.lib_name == HotCounter._LIB_NAME
```

編集後は同じモジュールが新コードを呼びます。粗い時刻精度のファイルシステムにも対応するため、`write` 後のループで更新時刻が変わったことを確認します。

```@example hotreload
source = joinpath(crate, "src", "lib.rs")
old_mtime = mtime(source)
write(source, """
    use rustcall_julia_macros::julia;

    #[julia]
    pub fn step() -> i32 { 2 }
    """)
while mtime(source) <= old_mtime
    sleep(0.1); touch(source)
end

# A release build can take a while; give up after ten minutes.
if timedwait(() -> isready(reloads), 600.0) !== :ok
    RustCall.disable_hot_reload(state.lib_name)
    error("the watcher did not rebuild $(crate) within 600 s")
end
rebuilt = take!(reloads)            # true: the new library is loaded
second_step = HotCounter.step()     # 2
```

終了時に監視を止めます。

```@example hotreload
RustCall.disable_hot_reload(state.lib_name)
RustCall.is_hot_reload_enabled(state.lib_name)   # false
```

## [どのライブラリ・設定を再ビルドするか](@id Which-library-is-reloaded,-and-which-build)

全生成モジュールは `_BUILD_RECORD` という不変の `CrateBuildRecord` に、元ディレクトリ、登録名、release・feature・default_features・ビルド種別、環境・有効 Cargo 設定・ツールチェーンを記録します。登録名 `rust_crate_<name>_<id>` はモジュール名ではなく内容とオプションから決まります。保存済みファイルも同じ記録を持ちます。

**モジュールまたはマクロの戻り値を渡す**形式を推奨します。

```julia
B = @rust_crate "deps/my_crate" release=false features=["simd"]
RustCall.enable_hot_reload_for_crate(B)   # rebuilds deps/my_crate, debug, with "simd"
```

追加引数は記録を変更せず比較します。パスは省略でき、指定するなら `realpath` で一致する必要があります。登録名・プロファイル・features の不一致、生成ラッパー経由、環境・Cargo 設定・ツールチェーンの変更、記録のない旧ファイルは拒否します。旧ファイルは再生成するか、正しいオプションでパス形式を使います。

有効化時の不一致は `ArgumentError`、各再ビルド前の不一致は失敗扱いで旧ライブラリを残し、`trigger_reload=false` と `(lib_name,false,err)` を返します。各再読み込みの開始時に環境を1回だけ捕捉し、照合・再走査・ビルドで共有します。pyo3 の Python もビルド後に再確認し、同じ場所での更新なら失敗させます。環境を戻すか、新環境で `@rust_crate` をやり直してください。

パス形式は指定オプションと現在の環境から記録を作るので、**編集前**に呼びます。別オプションの既存ビルドは推測せず、必要なら `lib_name` も指定します。低水準の `enable_hot_reload(lib_name,crate)` は指定名と既定 release または `build_options` を使います。独自 cdylib はどの形式でも必要です。

## [再読み込みの処理](@id What-a-reload-does)

環境照合 → 実ビルド設定で再走査 → 記録した Cargo ビルド → 新しい世代パスへコピー・読み込み → 1トランザクションで置換、の順です。RustToolChain の Cargo、RustCall の出力先、`RUSTCALL_OFFLINE=1` の `--offline` を使います。

置換前の失敗はすべて旧ライブラリとシンボル対応を保ち、false とコールバックのエラーを返します。同じ失敗のログは一度だけ出し、`state.last_failure` に保存します。Cargo が通っても extractor が拒否すれば失敗です。

ビルド中にソースが変わった場合だけは、成功したライブラリを名前対応なしで公開し、すぐ次を再ビルドします。モジュール自身は公開シンボルを直接呼ぶため、その間も動きます。

置換するのは**コードだけ**です。関数追加・削除・シグネチャ・構造体フィールドを変える場合は、Julia モジュールも `@rust_crate` で作り直してください。

## [再読み込みを越える呼び出しとオブジェクト](@id Objects-and-call-sites-across-a-reload)

旧イメージは[閉じずに退役](@ref Libraries-are-retired,-not-closed)します。

- 呼び出しはハンドル・関数ポインタ・パニックチャネルを同じ世代から取得します。置換前の実行は旧側で完了し、以後は新側へ入り、混在しません。
- オブジェクトは生成元のデストラクタで解放します。メソッドは現在のライブラリを呼ぶため、配置を変えたら旧オブジェクトを使わず作り直します。
- 多数の退役イメージは、実行中の呼び出しがなくなってから `unload_library(state.lib_name; close=true)` で回収できます。残る値は解放されず不活性になります。`retired_handles(name)` で確認します。

## [監視の設定](@id Watching:-interval,-poll,-callback)

- `poll=false`（既定）：`src/` 以下のイベントを待ち、アイドル時に CPU を使いません。`interval=1.0` 秒は停止検知の待ち時間です。
- `poll=true`：同じ間隔で更新時刻を調べます。ネットワークや一部コンテナのマウントに向きます。
- 連続保存を1ビルドにまとめ、ビルド中の変更は直後に再実行します。
- `callback=(lib_name,success,error)->...`：成功時の error は `nothing`。コールバック例外はログに出して監視を続けます。

`trigger_reload(lib_name)` は監視を待たず実行し、読み込み成功を返します。

## [停止](@id Turning-it-off)

`disable_hot_reload` は実行中のビルド完了を待って1つ停止し、ライブラリは残します。`disable_all_hot_reload()` は全停止、`set_hot_reload_global(false)` は次回起床で全停止します。`list_hot_reload_crates()` / `is_hot_reload_enabled` で確認でき、再度 enable すれば新しい監視を開始します。

## [再ビルドの出力先](@id Where-the-rebuild-writes)

再走査 probe とビルドは `crate_target_directory(crate)` を共有し、依存と build script の `OUT_DIR` を再利用します。元の `target/` には出力しません（#486）。[全方式の表](integration_guide.md#Where-@rust_crate-builds)も参照してください。

最新の `Cargo.lock` があれば読み取り専用でも可能です。`--locked` は付けないため、不足・古い lockfile は元の隣への書き込みが必要で失敗します。依存追加にも書き込みが必要です。利用者自身の `cargo build` は別の `target/` を使い、互いのビルドを無効化しません。

## [Windows と世代パス](@id Windows-and-generation-paths)

Cargo 出力は直接開かず、毎回新しい場所へコピーします。

```
<library>.rustcall.<host>.<pid>.<instance>.<generation>.<ext>
```

読み込み中 DLL を上書きできない Windows の `Access is denied` を避けます。他環境でも、同じパスが旧マップを返す問題を防ぎます。退役中のコピーはセッション中に残し、所有プロセス終了後に次の読み込みで削除します。

## [API](@id API)

[リファレンス](reference/crates.md)を参照してください。

- [`RustCall.enable_hot_reload_for_crate`](@ref)、[`RustCall.enable_hot_reload`](@ref)
- [`RustCall.disable_hot_reload`](@ref)、[`RustCall.disable_all_hot_reload`](@ref)、[`RustCall.set_hot_reload_global`](@ref)
- [`RustCall.trigger_reload`](@ref)、[`RustCall.is_hot_reload_enabled`](@ref)、[`RustCall.list_hot_reload_crates`](@ref)
