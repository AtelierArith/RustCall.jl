<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../../en/platforms/windows.md. -->
# [Windows ガイド](@id Windows-Platform-Guide)

Windows 固有の導入・設定・問題解決を説明します。

## [前提条件](@id Prerequisites)

### [Rust ツールチェーン（手動導入は任意）](@id Rust-Toolchain-(optional-to-install-yourself))

[RustToolChain.jl](https://github.com/AtelierArith/RustToolChain.jl) が PATH の rustc/cargo を優先し、なければ MSVC ターゲットを Artifacts で取得します。システムへの導入は任意です。手で管理する場合は [rustup.rs](https://rustup.rs/) の rustup-init.exe を実行し、既定の MSVC または必要な MinGW を選び、確認します。

```powershell
rustc --version
cargo --version
```

PATH の rustc が優先されます。

### [Visual Studio Build Tools（MSVC に必要）](@id Visual-Studio-Build-Tools-(required-for-the-MSVC-target))

既定と Artifacts は `x86_64-pc-windows-msvc` です。RustToolChain はリンカーを含まないため、[Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/) の Desktop development with C++、Windows 10/11 SDK、MSVC v143 以降を導入します。winget でも可能です。

```powershell
winget install Microsoft.VisualStudio.2022.BuildTools
```

### [Julia の導入](@id Julia-Installation)

[julialang.org](https://julialang.org/downloads/) の Windows インストーラーを使い、PATH 追加を選びます。

## [PATH 設定](@id PATH-Configuration)

### [自動設定（推奨）](@id Automatic-Configuration-(Recommended))

rustup が Cargo の場所を追加します。

```powershell
# Check Rust tools are accessible
where.exe rustc
where.exe cargo
```

### [手動設定](@id Manual-PATH-Configuration)

スタートメニューの環境変数からユーザーの Path に `%USERPROFILE%\.cargo\bin` を追加します。PowerShell での設定後は再起動します。

```powershell
[Environment]::SetEnvironmentVariable(
    "Path",
    [Environment]::GetEnvironmentVariable("Path", "User") + ";$env:USERPROFILE\.cargo\bin",
    "User"
)
```

## [ツールチェーンの選択](@id Toolchain-Selection)

### [MSVC（既定・推奨）](@id MSVC-Toolchain-(Default,-Recommended))

```powershell
# Check current toolchain
rustup show

# Ensure MSVC is default
rustup default stable-x86_64-pc-windows-msvc
```

Windows ABI とライブラリ連携に適し、一部クレートでは必須です。Build Tools と SDK が必要です。

### [MinGW（明示的設定が必要）](@id MinGW-Toolchain-(alternative,-configuration-dependent))

GCC を使います。既定でも Artifacts の提供対象でもありません。Cargo と直接 rustc の両方を切り替えます。

Cargo（helper/extractor、インライン依存、外部クレート）は有効な rustup ホストでビルドするので、GNU の**ホストツールチェーン**を導入して既定にします。

```powershell
rustup toolchain install stable-x86_64-pc-windows-gnu
rustup default stable-x86_64-pc-windows-gnu
```

`rustup target add` だけでは MSVC ホストの追加ターゲットに留まります。直接 rustc のインラインには RustCall のターゲットも設定します。

```julia
using RustCall
RustCall.set_default_compiler(RustCall.RustCompiler(target_triple = "x86_64-pc-windows-gnu"))
```

どちらかを省くと、その経路は MSVC のままです。小さな導入やクロスコンパイルには便利ですが、ABI 不一致の可能性があり、RustCall CI は MSVC だけを検証します。

### [選択の目安](@id When-to-Use-Which)

| 用途 | 選択 |
|------|------|
| 通常開発・Windows DLL | MSVC |
| 最小導入・Linux からのクロスビルド・小規模 CI | 必要な設定をした MinGW |

## [ターミナル](@id Terminal-Options)

### [PowerShell（推奨）](@id PowerShell-(Recommended))

```powershell
# Run Julia with debug logging
$env:JULIA_DEBUG = "RustCall"
julia --project
```

### [コマンドプロンプト](@id Command-Prompt-(CMD))

構文は異なりますが利用できます。

```cmd
set JULIA_DEBUG=RustCall
julia --project
```

### [Windows Terminal](@id Windows-Terminal)

タブ、Unicode、カスタマイズに対応するターミナルです。

### [WSL](@id WSL-(Windows-Subsystem-for-Linux))

WSL2 も使えますが独立した Linux 環境です。

```bash
# In WSL2 - uses Linux toolchain, not Windows
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
julia --project
```

!!! warning "WSL と Windows の分離"
    そこで作ったライブラリは Windows の Julia で使えず、その逆も同様です。環境を混ぜないでください。

## [よくある問題](@id Common-Issues-and-Solutions)

### [link.exe がない](@id Error:-"link.exe-not-found")

Build Tools または PATH が不足しています。導入後、Developer Command Prompt for VS 2022 から Julia を起動します。

```powershell
# Should show Visual Studio installation
& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -products *
```

### [Windows SDK がない](@id Error:-"Windows-SDK-not-found")

Visual Studio Installer の変更画面で Windows 10/11 SDK を有効にします。

### [DLL を読み込めない](@id Error:-DLL-Loading-Failures)

診断例です。

```
could not load library "..."
The specified module could not be found.
```

出力先を確認します。

```julia
# Debug: Check library path
using RustCall
lib_path = joinpath(RustCall.CACHE_DIR, "...")
@info "Library exists?" isfile(lib_path)
```

dumpbin で依存を確認します。

```powershell
dumpbin /dependents path\to\library.dll
```

依存 DLL が必要なら PATH に追加します。

```powershell
$env:PATH += ";C:\path\to\dlls"
```

### [260文字を超えるパス](@id Error:-Long-Path-Issues-(-260-characters))

Windows 10 1607以降の長いパスを有効にするか、短いパスを使います。

```powershell
# Run as Administrator
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
    -Name "LongPathsEnabled" -Value 1 -PropertyType DWORD -Force
```

プロジェクトをルート近くへ移します。

```powershell
# Instead of: C:\Users\Username\Documents\Projects\MyProject\...
# Use: C:\Dev\MyProject\...
```

Cargo home も短くできます。

```powershell
$env:CARGO_HOME = "C:\cargo"
```

### [Unicode と符号化](@id Error:-Unicode/Encoding-Issues)

パスやソースの非 ASCII 文字で失敗する場合は、ASCII のパスで切り分け、コンソール符号化を設定します。

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001
```

Git の改行も設定します。

```powershell
git config --global core.autocrlf true
```

### [ウイルス対策の干渉](@id Error:-Antivirus-Interference)

アクセス拒否・遅延・不定の失敗ならログを確認します。必要に応じて管理者の方針に従い Cargo・Julia・プロジェクトの開発用ディレクトリを除外対象にします。管理者 PowerShell の例です。

```powershell
Add-MpPreference -ExclusionPath "$env:USERPROFILE\.cargo"
Add-MpPreference -ExclusionPath "$env:USERPROFILE\.julia"
```

## [CI/CD](@id CI/CD-Configuration)

### [GitHub Actions](@id GitHub-Actions)

RustCall CI は Windows を含みます。

```yaml
test:
  runs-on: ${{ matrix.os }}
  strategy:
    matrix:
      os: [windows-latest]
  steps:
    - uses: actions/checkout@v6
    - uses: julia-actions/setup-julia@v2
    - uses: julia-actions/julia-buildpkg@v1
    - uses: julia-actions/julia-runtest@v1
      with:
        test_args: '--jobs=2'
```

### [Rust ビルドのキャッシュ](@id Caching-for-Windows-Builds)

```yaml
- name: Cache Cargo
  uses: actions/cache@v4
  with:
    path: |
      ~/.cargo/bin/
      ~/.cargo/registry/index/
      ~/.cargo/registry/cache/
      ~/.cargo/git/db/
    key: ${{ runner.os }}-cargo-${{ hashFiles('**/Cargo.lock') }}

- name: Cache Julia artifacts
  uses: julia-actions/cache@v2
```

### [Windows CI の注意](@id Windows-Specific-CI-Tips)

YAML は `/` 区切りを使えます。既定シェルは PowerShell です。Git の CRLF/LF も設定してください。

## [推奨事項](@id Best-Practices)

### [1. PowerShell](@id 1.-Use-PowerShell)

スクリプトと Unicode に適しています。

### [2. 短いパス](@id 2.-Keep-Paths-Short)

プロジェクトのパスを100文字未満に抑えると問題を避けやすくなります。

### [3. 定期的な更新](@id 3.-Regular-Updates)

```powershell
rustup update
julia -e 'using Pkg; Pkg.update()'
```

### [4. ネイティブツール](@id 4.-Use-Native-Tools)

Windows 向け開発では WSL と混ぜず Windows のツールを使います。

### [5. ウイルス対策の設定](@id 5.-Configure-Antivirus-Exclusions)

必要な開発用ディレクトリの扱いを確認します。

## [早見表](@id Quick-Reference)

### [主なコマンド](@id Essential-Commands)

```powershell
# Check Rust installation
rustc --version
cargo --version

# Check toolchain
rustup show

# Update Rust
rustup update

# Clean Cargo cache
cargo clean

# Julia with debug logging
$env:JULIA_DEBUG = "RustCall"; julia --project
```

### [よく使うパス](@id Common-Paths)

| パス | 内容 |
|------|------|
| `%USERPROFILE%\.cargo` | Cargo home |
| `%USERPROFILE%\.julia` | Julia depot |
| `%USERPROFILE%\.rustup` | rustup ツールチェーン |
| `%LOCALAPPDATA%\Temp` | 一時ファイル |

### [環境変数](@id Environment-Variables)

| 変数 | 用途 |
|------|------|
| CARGO_HOME | Cargo の場所 |
| RUSTUP_HOME | rustup の場所 |
| JULIA_DEBUG | Julia デバッグログ |
| RUST_BACKTRACE | Rust バックトレース |

## [関連情報](@id See-Also)

[トラブルシューティング](../troubleshooting.md)、[チュートリアル](../tutorial.md)、[Rust 公式 Windows 導入](https://rust-lang.github.io/rustup/installation/windows.html)を参照してください。
