<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/panics.md. -->
# [パニック・シンボルの可視性・オブジェクトの生存期間](@id Panics,-Symbol-Visibility-and-Object-Lifetime)

以前はコンパイル経路により異なっていた3つの性質を統一しています。保証と、利用者のクレートによって異なる条件を説明します。

## [パニック](@id Panics)

生成境界内の Rust `panic!` はメッセージ付きの [`RustCall.RustPanicError`](@ref) となり、Julia セッションは継続します。

```julia
rust"""
#[julia]
fn checked_div(a: i32, b: i32) -> i32 {
    assert!(b != 0, "division by zero");
    a / b
}
"""

checked_div(Int32(10), Int32(2))    # 5

try
    checked_div(Int32(1), Int32(0))
catch e
    e isa RustCall.RustPanicError && println(e.message)
    # "checked_div panicked: division by zero"
end

checked_div(Int32(9), Int32(3))     # 3 — the library is still usable
```

### [仕組み](@id How-it-works)

全生成ラッパーは `catch_unwind` で囲み、パニック時に**ラッパー固有のスレッドローカルチャネル**へメッセージを保存し、null、空バッファ、Result/Option の失敗タグ、または `MaybeUninit::zeroed()` を返します。

通常の値や getter の結果は `MaybeUninit<T>` として返します。サイズ・整列・ABI は `T` と同じです（#462）。`mem::zeroed::<T>()` は参照・Box・NonZero・関数ポインタなどで未定義動作となり、巻き戻せない二次パニックで異常終了するため使いません。Rust から生成ラッパーを読む場合は、パニックがないことを確認して `assume_init()` します。

Julia は呼び出し直後に、事前解決・保存した `<wrapper symbol>_take_panic` を読み、番兵値を使う前に例外を送出します。手続きマクロはクレート全体を見られず、別モジュールのマングルなしシンボルも Rust パスとして参照できないため、チャネルはラッパーごとです。

### [診断を静かにするフック](@id The-quiet-hook)

Rust は捕捉前に panic hook を呼ぶため、処理済みでも stderr に異常終了のようなログが出ていました。#304 以降は境界の内部だけ静かにし、外部では以前のフックへ委譲します。イメージごとのスレッドローカル深度カウンターを使い、`load_artifact!` が dlopen 直後に一度 `__rustcall_install_panic_hook` を呼び、最後の close 前に uninstall します。解放済みコードへのフックは残しません。

インライン（rustc / Cargo）、単相化、生成ラッパー、利用者の `#[julia]` クレートすべてに適用します。インライン全体を生成できる場合はルートの `crate::__RustCallBoundary`、手続きマクロの場合は通常ライブラリ `rustcall_julia_macros` の共有状態を使います。生成ラッパーも対象と同じライブラリを共有し、1イメージ・1フック・1カウンターにします。

`rustcall_julia_macros` 依存を rename しないでください。生成ガードがこの名前を使います。また、ソース開発でラッパーを作る場合は読み込み側と同じコピーを参照し、別コピーの二重シンボルを避けます。**`__rustcall_` で始まるシンボルは予約済み**です。

Rust が作る別スレッド、手書きの公開関数、境界外のコンストラクタなどは保護対象外です。`RUSTCALL_PANIC_HOOK=default` で既定フックに戻せます。パニックの診断が見えない場合の確認にも使います。

`-C prefer-dynamic` では std のフック登録が共有され、別イメージのフックと干渉するため既定のままにします。ビルド時の `RUSTFLAGS`、`CARGO_ENCODED_RUSTFLAGS`、ターゲット別 RUSTFLAGS をトークンとして確認し、`prefer-dynamic=no` は正しく無効扱いします。Cargo 設定経由など検出外で有効化された場合はフックが干渉することがありますが、イメージを閉じる前に解除するため解放済みコードへは入りません。

### [unwind に固定する理由](@id Why-unwinding-is-pinned)

`catch_unwind` は abort を捕捉できないため、管理するビルドには `-C panic=unwind`、生成マニフェストの設定、`CARGO_PROFILE_<PROFILE>_PANIC` を指定します。継承した abort 設定や予想外の既定値で境界が無効にならないようにします。以前の直接 rustc の abort と Cargo の既定値の違いは解消しています。

### [経路別の動作](@id The-matrix)

| コード | ビルド | パニック時 |
|--------|--------|------------|
| インラインの `#[julia]` | rustc または Cargo | `RustPanicError` |
| 生成メソッド・コンストラクタ・ジェネリクス | 各経路 | `RustPanicError` |
| 独自 cdylib のないクレート | 生成マニフェスト | `RustPanicError` |
| 独自 cdylib のあるクレート | 利用者のマニフェスト | プロファイルが abort でなければ `RustPanicError` |
| 手書きの `#[no_mangle] extern "C"` | 各経路 | **異常終了** |
| 生成デストラクタからの Drop | unwind 有効 | 捕捉し finalizer の失敗数を加算 |
| 生成アクセサー・clone | unwind 有効 | `RustPanicError` |

手書き公開には `#[julia]` を使い、独自クレートの `[profile.release] panic="abort"` は必要なら外します。生成アクセサーも結果変換前にチャネルを読みます。setter が古い値の Drop 中にパニックした場合など、変更のロールバックはありません。巻き戻し中の二重パニックも異常終了し得ます。`must_assume_unwind(policy)` で未捕捉の可能性を調べられます。

## [シンボルの可視性](@id Symbol-visibility)

全成果物を `RTLD_LOCAL | RTLD_NOW` で開き、プロセス全体の名前空間へ公開しません。異なるブロックの `f` は読み込み順ではなくハンドルで決定します。`@rust` は引き続き読み込み済みライブラリをハンドルごとに検索します。旧 `RUSTCALL_DLOPEN_GLOBAL=1` は v0.5 で削除しました（[#417](https://github.com/AtelierArith/RustCall.jl/issues/417)）。Windows の LoadLibrary には LOCAL/GLOBAL の区別はありません。

## [オブジェクトの生存期間](@id Object-lifetime)

注釈付き構造体は Julia ラッパーが所有し、finalizer が生成元の `<Struct>_free` を呼び Box を破棄します。インラインも同じです。

- **検索せず捕捉**：生成時に同じイメージのデストラクタ・パニックチャネル・生存フラグを保存します。finalizer はロックを取らず、dlsym・コンパイル・ログも行いません。
- **二重解放防止**：呼ぶ前にポインタを `C_NULL` にするため、2回目は何もしません。
- **閉じたイメージへ入らない**：close がフラグを無効化すると何もせず、データはリークさせます。通常の退役だけならまだ解放できます。
- **Drop のパニックは数える**：捕捉チャネルを割り当てなしで直ちに消費し、`finalizer_failure_count()` を増やします。Julia 例外は投げません。Rust のフック診断は出る場合があります。
- **解放後の操作は例外**：null の参照外しはしません。

## [実行時状態とロック順序](@id Runtime-state-and-lock-ordering)

可変レジストリは `Base.Lockable` の `RustCall.STATE` にまとめ、旧名もロック付きビューです。ロックは短いメモリ内トランザクションだけに使い、コンパイル・dlopen/close・コールバック・Rust 呼び出しは外で実行します。

`RustBox` / `RustRc` / `RustArc` / `RustVec` は生成時に解放先と生存フラグを捕捉し、明示的 `drop!` と原子的に一度だけ解放を獲得します。STATE 内の遅延キューは、helper 対象なしの生ポインタラッパーの明示的 drop 用だけで、finalizer はキューに積みません。生ポインタを使う間は所有ラッパーへの参照か `GC.@preserve` を保ちます。

### [ライブラリは閉じずに退役](@id Libraries-are-retired,-not-closed)

再読み込みと `unload_library` は登録・シンボル・型ヒント・単相化・チャネル・モジュールの参照を外しますが、**イメージはマップしたまま**です。実行中の関数ポインタがあるかもしれないためです。全呼び出しに原子的な読者カウンターを課す代わりに、再読み込みごとに数百 KiB 程度のコードを保持します。

退役中のオブジェクトは元のイメージのデストラクタを使えます。コードは残ってもデータは通常どおり解放します。回収するには呼び出しがないことを保証します。

```julia
RustCall.unload_library(name; close = true)
RustCall.unload_all_libraries(; close = true)
```

`retired_handles()` または名前付き形式で一覧を得ます。`close=true` は実行中でないことと、残るオブジェクトが解放されず不活性になることの両方を受け入れる指定です。通常の REPL では不要で、多数回再読み込みする長寿命プロセスなどで使います。

#### [回収費用の評価（#291）](@id Reclamation-cost-assessment-(#291))

`benchmark/benchmarks_retirement.jl` を `julia --threads=4 --project` で実行できます。同じ呼び出しに2回の原子的 read-modify-write を足し、結果と最終読者数を検証します。

2026-09-09 の Darwin x86_64 / Julia 1.12.7 / rustc 1.98.0、20バッチ・各ワーカー5万回の中央値です。

| ワーカー | キャッシュ済み呼び出し | 共有読者カウンター |
|----------|-----------------------:|-------------------:|
| 1 | 4.45 ns/完了呼び出し | 20.74 ns/完了呼び出し |
| 4 | 0.85 ns/完了呼び出し | 37.08 ns/完了呼び出し |

壁時計のスループットであり、個々の遅延や実アプリの予測ではありません。これは競合費用の下限の測定で、**安全な回収手順ではありません**。公開・再確認の順序、後で破棄するオブジェクトの保持も必要です。epoch / hazard pointer の可能性を否定せず、完全な手順と実負荷の根拠が揃うまで明示的回収を維持します。

#### [ビルド設定 probe の費用（#291）](@id Build-configuration-probe-cost-(#291))

`build.rs` は列挙不能な入力を読めるため cfg probe はメモ化しません。`benchmarks_cfg_probe.jl` は独立した依存なしクレートで、入力変更を次の probe が検出することも確認します。

同日の Darwin / Julia 1.12.7 では初回0.725秒、無変更10回の中央値0.075秒（0.073～0.108）、入力変更後1.650秒でした。初回は Julia コンパイル、変更後は Cargo 再ビルドも含みます。大規模クレートの上限ではありません。FFI の各呼び出しではなく読み込み時の費用として受け入れています。

### [アロケーターの契約](@id The-allocator-contract)

**割り当てたライブラリ自身で解放**します。同じ rustc でも各 cdylib のアロケーター shim が別なので、別イメージ経由の解放は未定義動作です。

| 値 | 解放関数 | 解決するイメージ |
|----|----------|------------------|
| 構造体ハンドル | `<Struct>_free` | 生成元 |
| 所有 String | `<owner>_free_rust_string` | 返却元 |
| RustBox / RustVec / RustArc | rustcall_helpers | 割り当てた helper |

別ブロックの解放関数へ渡さないでください。helper なしで所有権型を作ると、その場で `Pkg.build("RustCall")` を案内します。

## [逆方向：コールバック中の Julia 例外](@id The-reverse-direction:-a-Julia-exception-inside-a-callback)

C 関数ポインタで渡した Julia 関数は Rust の下で実行します。トランポリンが例外を捕捉し、Rust へゼロを返して、戻った後に同じ例外を再送出します。ゼロが原因の Rust パニックは消費します。規則と例は[コールバック](callbacks.md)を参照してください。
