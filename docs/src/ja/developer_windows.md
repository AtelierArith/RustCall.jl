<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/developer_windows.md. -->
# [Windows での開発](@id Windows-Development)

Windows のソースチェックアウトで開発する方向けの説明です。インストールと利用は [Windows ガイド](platforms/windows.md)を参照してください。

## [Windows のネイティブシェルでテスト](@id Run-the-test-suite-from-a-native-Windows-shell)

PowerShell または **Developer PowerShell for VS 2022** を使います。後者は Cargo に必要な MSVC リンカーと Windows SDK の変数を設定します。WSL は独立した Linux 環境なので、そこで作ったバイナリを Windows の Julia に読み込めません。

リポジトリのルートで、テスト前に2つのネイティブ成果物を再ビルドします。

```powershell
julia --project deps/build.jl

$extractor = (Resolve-Path .\deps\rustcall_extract\target\release\rustcall-extract.exe).Path
$env:RUSTCALL_EXTRACT = $extractor
& $extractor schema-version       # must match the MAJOR.MINOR of Project.toml

julia --startup-file=no -e 'using Pkg; Pkg.activate("."); Pkg.test()'
```

extractor はマニフェストのスキーマと対応します。例えば `Project.toml` が `0.7.x` なら `schema-version` の出力は `0.7` が必要です。次のエラーは、

```text
manifest schema version mismatch: the rustcall-extract binary produced schema "0.6", but this RustCall.jl (v0.7.0) expects "0.7"
```

`RUSTCALL_EXTRACT` または `deps/rustcall_extract/target` に古いバイナリがあることを示します。`deps/build.jl` を再実行し、上記のコマンドを確認してから Julia のテストを調べてください。

`Pkg.test()` は、依存関係や compat が解決済みマニフェストから変わった場合も警告します。extractor のエラーとは別問題です。意図的な変更なら環境を解決し、コミット前に `Manifest.toml` の差分を確認します。

テストランナーと直接実行する `test/test_cache.jl` は、RustCall を読み込む前に専用の Julia depot を先頭に置きます。既存 depot は依存検索用に残し、ワーカーや子プロセスも専用 depot を引き継ぎます。キャッシュ削除テストがアプリのキャッシュに触れないよう、`RUSTCALL_CACHE_DIR` は無視します。これはテストだけの隔離で、通常の API や保存先選択は変更しません。

Windows では DLL が一時 depot を使用中にするため、テストプロセスの実行中は削除しません。手動削除する前に Julia と全ワーカーを終了してください。

## [MSVC リンカーと Windows SDK](@id MSVC-linker-and-Windows-SDK)

RustToolChain.jl は Rust を提供しますが Windows のリンカーは含みません。通常は MSVC ターゲットなので、Visual Studio Build Tools の **Desktop development with C++** に加え、MSVC ツールセットと Windows 10 / 11 SDK を導入します。Julia を起動するシェルで確認します。

```powershell
where.exe rustc
where.exe cargo
where.exe cl.exe
where.exe link.exe
rustc --version
cargo --version
```

`rustc` と `cargo` があっても、MSVC リンカーを呼べなければビルドできません。通常の PowerShell で `link.exe not found`、`Windows SDK not found`、リンクエラーが出る場合は Developer PowerShell から Julia を実行します。

## [Application Control とロックされた成果物](@id Application-Control-and-locked-build-products)

Cargo は Julia の scratch 領域で `build-script-build.exe` を実行し、Julia は `%USERPROFILE%\.julia\compiled` からプリコンパイル済み DLL を読み込みます。管理対象の Windows では Application Control がこれらを禁止する場合があります。代表的な診断は次のとおりです。

```text
An Application Control policy has blocked this file. (os error 4551)
```

Documenter で `Parsers` などを読み込む際も同様です。

```text
Error opening package file ...\.julia\compiled\v1.13\Parsers\...dll:
An Application Control policy has blocked this file.
```

これは端末のポリシーによる失敗です。管理者に承認済みの Julia/Cargo ビルド場所を許可してもらうか、承認された開発環境を使ってください。一般的な回避策として保護機能を無効化しないでください。

Windows は読み込み中の DLL や Cargo 出力をロックします。生成 `.exe` に `LNK1104` が出たら、残った Julia/Cargo プロセスを終了して新しいセッションで試し、ウイルス対策や Application Control のログを確認します。チェックアウトと scratch のパスは短いローカルパスにし、ネットワーク共有を避けます。

`%USERPROFILE%\.julia\scratchspaces\<RustCall UUID>\cache-v2\cargo` 内の **Bad Image** ダイアログも、`MZ` / `PE` ヘッダーが正常なら通常は環境や生存期間の問題です。キャッシュ削除や再ビルド前に全ワーカーを停止し、新しい Julia プロセスで対象をビルドし直します。同じ DLL を新しいプロセスだけが読める場合は、ポリシーのログを調べ、古いワーカーやキャッシュの再使用を避けます。

## [PyO3 テストと Python](@id PyO3-tests-and-Python)

- `:python_free` は Python 不要です。
- `:link_libpython` は実際の Python とリンク可能な `python3xy.lib` が必要です。

`WindowsApps` 内の `python.exe` エイリアスは Microsoft Store を開くだけなので使えません。明示的に確認します。

```powershell
where.exe python
python --version
```

リンクを必要とするテストには開発ファイル付きの Python を導入し、必要に応じて対象インタープリターを指定します。

```powershell
$env:PYO3_PYTHON = "C:\Python312\python.exe"
$env:RUSTCALL_PYTHON_LIBDIR = "C:\Python312\libs"
```

リンク可能なライブラリがなければ、対象テストは明示的にスキップを報告します。`python_free` の Cargo 失敗や、ライブラリ検出後の失敗は通常の不具合として調査し、スキップ変数で隠さないでください。
