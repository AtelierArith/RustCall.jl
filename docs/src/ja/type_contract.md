<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/type_contract.md. -->
# [FFI の型契約](@id The-FFI-type-contract)

「この Rust 型を C 境界でどう表現するか」は `src/ffi/ffi_contract.jl` の1つの表で決まります。ラッパー生成、引数変換、戻り値スロット、解放シンボルがすべてこの表を参照します（#276）。別の表や、未対応型の推測はありません。

## [契約に記録する情報](@id What-the-contract-records)

Rust 型の表記と方向（引数または戻り値）に対して次を記録します。

- **C ABI の形式**：値、ポインタ、`(ptr, len)`、`(ptr, len, cap)`、またはユニット型の空の表現。
- **`ccall` のスロット**：複数ワードの値は引数では複数スロットへ展開しますが、戻り値は1型しか指定できないため `#[repr(C)]` の集成型になります。
- **利用者から見える Julia 型**。
- **所有権**：参照先メモリを誰が解放するか。必要なら**解放シンボル**も記録します。

```julia
julia> RustCall.ffi_return_contract("String"; abi = "string", owner = "shout")
```

この結果は `abi = :ptr_len_cap`、戻り値スロット `CRustString`、表層型 `RustString`、所有権 `:owned_by_rust`、解放シンボル `shout_free_rust_string` となり、生成ラッパーが使う情報と一致します。

## [表記ではなくマニフェストが決定](@id The-manifest-decides,-not-the-spelling)

Rust の `String` は複数の形式で境界を通るため、表記だけでは決まりません。`rustcall-extract` の `Arg.abi`、`Function.return_abi`、`Method.return_abi`、`Field.abi` が正式な情報で、`abi` キーワードとしてそのまま渡します。ABI 情報のない `"String"` は意図的に**不明**とし、実際には行われていない変換を仮定せず拒否します。

## [不明な型は拒否](@id Unknown-types-fail-closed)

表にない表記には Julia 型がありません。生成コードの動作は `RustCall.FFI_STRICT[]` で選びます。

| 値 | 動作 |
|----|------|
| `:error` | シグネチャを示す `RustError`（既定） |
| `:warn` | シグネチャごとに一度警告し `Any` を生成 |
| `:none` | 警告なしで `Any` を生成 |

`ccall` の `Any` は動作が明確に定義されません。`:warn` / `:none` は未対応型を修正する間だけ既存クレートをビルドするためのものです。`write_bindings_to_file(...; strict = :warn)` で個別に選べます。

## [対応する型](@id Supported-types)

`RustCall.FFI_TYPE_TABLE` と `RustCall.ffi_describe` から生成します。表の本体を手で編集しないでください。ABI 名と所有権の値は契約の識別子です。

<!-- TYPE_MATRIX_START -->
| Rust | ABI（戻り値） | 引数スロット | 戻り値スロット | Julia | 所有権（戻り値） | 解放関数 |
| ---- | ------------ | -------------- | ----------- | ----- | ------------------ | ----------- |
| `&str` | ptr_len | `Ptr{UInt8}`, `UInt64` | `RustCall.CRustStr` | `RustCall.RustStr` | borrowed | — |
| `()` | void | — | — | `Nothing` | none | — |
| `String` | ptr_len_cap | `Ptr{UInt8}`, `UInt64` | `RustCall.CRustString` | `RustCall.RustString` | owned_by_rust | `<owner>_free_rust_string` |
| `bool` | by_value | `Bool` | `Bool` | `Bool` | none | — |
| `c_char` | by_value | `Cchar` | `Cchar` | `Cchar` | none | — |
| `c_double` | by_value | `Cdouble` | `Cdouble` | `Cdouble` | none | — |
| `c_float` | by_value | `Cfloat` | `Cfloat` | `Cfloat` | none | — |
| `c_int` | by_value | `Cint` | `Cint` | `Cint` | none | — |
| `c_long` | by_value | `Clong` | `Clong` | `Clong` | none | — |
| `c_longlong` | by_value | `Clonglong` | `Clonglong` | `Clonglong` | none | — |
| `c_uint` | by_value | `Cuint` | `Cuint` | `Cuint` | none | — |
| `c_ulong` | by_value | `Culong` | `Culong` | `Culong` | none | — |
| `c_ulonglong` | by_value | `Culonglong` | `Culonglong` | `Culonglong` | none | — |
| `char` | by_value | `UInt32` | `UInt32` | `Char` | none | — |
| `f32` | by_value | `Float32` | `Float32` | `Float32` | none | — |
| `f64` | by_value | `Float64` | `Float64` | `Float64` | none | — |
| `i128` | by_value | `Int128` | `Int128` | `Int128` | none | — |
| `i16` | by_value | `Int16` | `Int16` | `Int16` | none | — |
| `i32` | by_value | `Int32` | `Int32` | `Int32` | none | — |
| `i64` | by_value | `Int64` | `Int64` | `Int64` | none | — |
| `i8` | by_value | `Int8` | `Int8` | `Int8` | none | — |
| `isize` | by_value | `Cssize_t` | `Cssize_t` | `Cssize_t` | none | — |
| `str` | ptr_len | `Ptr{UInt8}`, `UInt64` | `RustCall.CRustStr` | `RustCall.RustStr` | borrowed | — |
| `u128` | by_value | `UInt128` | `UInt128` | `UInt128` | none | — |
| `u16` | by_value | `UInt16` | `UInt16` | `UInt16` | none | — |
| `u32` | by_value | `UInt32` | `UInt32` | `UInt32` | none | — |
| `u64` | by_value | `UInt64` | `UInt64` | `UInt64` | none | — |
| `u8` | by_value | `UInt8` | `UInt8` | `UInt8` | none | — |
| `usize` | by_value | `Csize_t` | `Csize_t` | `Csize_t` | none | — |
<!-- TYPE_MATRIX_END -->

### [生ポインタ](@id Raw-pointers)

`*const T` / `*mut T` は任意の `T` に対応し、再帰的に解決します。例えば `*const *mut i32` は `Ptr{Ptr{Int32}}` です。不透明なハンドルや1ワードの C 表現がない型など、参照先を対応付けられなければ、スロットとして明確な `Ptr{Cvoid}` になります。

生ポインタの所有権は**表記からは決まりません**。生成コンストラクタの `Box::into_raw` は Julia が解放しますが、別の `*mut T` は Rust が保持するメモリかもしれません。契約は `:unknown` とし、メタデータを知る側が明示します。

```julia
RustCall.ffi_return_contract("*mut Point"; ownership = :transferred_to_julia,
                             free_symbol = "Point_free")
```

所有する位置で解放シンボルを指定しないと `ArgumentError` です。解放方法のない所有値は #246 / #249 の問題を再現するため、記録を拒否します。

### [スロット型と表層型の違い](@id Slot-and-surface-can-differ)

Rust の `char` は境界で `UInt32` の Unicode スカラー値ですが、Julia の `Char` は左詰め UTF-8 のビット表現で、コードポイントそのものではありません。`src/ffi/codegen.jl` の `ccall_return_type` / `convert_return` と引数側の対応関数に変換を一元化しています。生成した各呼び出しが独自に変換・再解釈することはありません。`0x10FFFF` 超やサロゲート範囲など、不正なスカラー値は拒否します。

### [Windows の128ビット整数](@id 128-bit-integers-on-Windows)

`i128` / `u128` は `Int128` / `UInt128` に対応しますが、`x86_64-pc-windows-msvc` では**往復できません**。MSVC にネイティブの128ビット整数がなく、`extern "C"` の受け渡しで Rust と Julia が一致しないためです（rust-lang/rust#54341）。型対応では直せない ABI の問題です。Windows 対応時は2つの `u64` に分けるかポインタで渡します。

### [パスの修飾](@id Path-qualifiers)

`core::primitive::i32` / `std::primitive::i32` は、先頭の `::` の有無にかかわらず `i32` と同じです。それ以外は修飾を除きません。`mycrate::i32` は配置の異なるエイリアスかもしれないため不明のままです。

### [意図的に拒否する型](@id Types-the-contract-deliberately-refuses)

`Vec<T>`、`HashMap`、`Box`、`Rc`、`Arc`、`Cow`、表にないユーザー型には導出可能な C 表現がありません。`*mut MyType` のポインタで渡すか、対応型を返すアクセサーを持つ `#[julia]` 構造体に包みます。

### [文字列引数は正しい UTF-8 が必要](@id String-arguments-must-be-valid-UTF-8)

Julia の `String` は任意のバイト列を持てるため、`String([0xff, 0xfe])` も作れます。Rust の `&str` / `String` は常に UTF-8 なので、受け渡し時に検査します（[#246](https://github.com/AtelierArith/RustCall.jl/issues/246)）。

```julia
rust"""
#[julia]
pub fn shout(name: &str) -> String { name.to_uppercase() }
"""

shout("héllo")                  # "HÉLLO"
shout(String([0xff, 0xfe]))
# ERROR: RustError: argument `name` of `shout` is not valid UTF-8 (first
# invalid byte at index 1, 0xff). ...
```

診断には Rust の引数名、関数名、最初の不正なバイトを示します。構造体のメソッドも同じ検査を通ります。

検査がなければ生成ラッパーの `String::from_utf8_lossy` が不正バイトを U+FFFD に**置換**し、渡したものと違うデータで計算して、エラーなしの誤結果を返します。不正な `&str` は未定義動作なので、多層防御として `from_utf8_lossy` は残し、Julia 側の検査で捕捉可能な例外にします。

文字データなら `isvalid(s)` で調べ、`transcode` や実際の符号化に基づく再エンコードで修正します。文字でないバイト列は `#[julia]` の `&[u8]` に連続した `Vector{UInt8}` を渡します。検査付きで呼び出し中だけ借用します（[数値スライスの借用](@ref Borrowing-numeric-slices)）。手動の C ABI では `*const u8` と長さも使えます。

## [Julia 構造体の値渡しは明示的に登録](@id Passing-a-Julia-struct-to-Rust-by-value-is-opt-in)

Julia の構造体は C 型ではありません。従来の `@rust f(p)` は `isbits` なら同じ配置と仮定していましたが、Rust の既定 `repr(Rust)` は**配置が未規定**です。フィールド順序やニッチ最適化がバージョンで変わるため、偶然動く値渡しを拒否します（[#245](https://github.com/AtelierArith/RustCall.jl/issues/245)）。

```julia
struct Point
    x::Float64
    y::Float64
end

@rust process_point(Point(3.0, 4.0))::Float64
# ERROR: RustError: cannot pass `Point` to Rust by value as argument 1:
# RustCall has no layout assertion for it (#245). ...
```

Rust 側をフィールド順序が固定される `#[repr(C)]` にし、一度登録します。

```julia
@register_ffi_struct Point

@rust process_point(Point(3.0, 4.0))::Float64   # 25.0
```

`register_ffi_struct` は、対応する Rust 型が `#[repr(C)]` でフィールドの順序・型が Julia と一致すると**利用者が保証する**操作です。RustCall は検証できません。保証は `RustCall.ffi_by_value_layout` のメソッドとして記録します。

パッケージのトップレベルではマクロを使います。

```julia
@register_ffi_struct Point
@register_ffi_struct Tuple{Int32, Float64}
```

マクロは呼び出し元のモジュールにメソッドを定義するため、プリコンパイルに保存され、読み込み時に復元されます。関数版 `register_ffi_struct(Point)` は `parentmodule(T)` に定義します。自作型なら同じですが、`Tuple` のように `Core` が所有する型では RustCall に定義し、依存先の変更は下流パッケージのキャッシュから再実行されません。関数版は REPL・スクリプト・関数内、プリコンパイルを越えて保持する登録にはマクロを使います。

登録できるのは**具体型だけ**です。抽象型や未具体化の `Point` は拒否します。`Point{T}` は型引数でサイズ・アラインメント・レジスターの分類まで変わるためです。`register_ffi_struct(Point{Float64})` はその型だけを保証し、`Point{Int32}` は保証しません。`RustCall.unregister_ffi_struct(T)` で撤回できます。`repr_c = false` は拒否します。

次の型には登録は不要です。

- スカラー、ポインタ、`Cstring`、`Char`、`Bool`：幅により ABI が決まります。
- `#[julia]` から生成する構造体ラッパー：フィールドのコピーではなく不透明なハンドルで渡します（[構造体の対応付け](struct_mapping.md)）。
- RustCall 自身の `#[repr(C)]` 対応型：`CRustString`、`CRustSlice` などは既にメソッドを持ちます。`::Type{<:RustPtr}` のような包括的な保証も、自分の型に限り行います。利用者用の登録関数はこれを許しません。生成する `CResult_<fn>` / `COption_<fn>` は `RustCall.FFIByValue` のサブタイプなので追加操作は不要です。

Rust 型が `#[repr(C)]` でなければ登録しないでください。ポインタで渡すか `#[julia]` のハンドル方式を使います。

## [戻り値の注釈はマニフェストと一致させる](@id A-return-annotation-may-not-contradict-the-manifest)

`::T` は RustCall が知らない戻り値型を補うためのものです。既知の型と異なる注釈は上書きではなくエラーです。32ビットの戻り値を `Float64` と読むのはキャストではなく未定義動作です。

```julia
rust"""
#[julia]
pub fn double(a: i32) -> i32 { a * 2 }
"""

@rust double(Int32(21))            # Int32(42) — the manifest decides
@rust double(Int32(21))::Int32     # Int32(42) — agreeing is fine
@rust double(Int32(21))::Float64
# ERROR: RustError: return type annotation `::Float64` on `@rust double(...)`
# disagrees with the manifest, which records `Int32` ...
```

`Float64` が必要なら Julia 側で変換します。

一致とは **`ccall` の戻り値スロットが同じ**ことです。マニフェストはスロット、注釈は表層型を指定します。Rust の `char` はスロットが `UInt32`、表層型が `Char` なので、`::Char` / `::UInt32` はどちらも一致しますが `::Int32` は一致しません。
