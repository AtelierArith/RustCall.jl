<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../../en/reference/generics.md. -->
# [ジェネリクスと `#[julia]` 関数](@id Generics-and-#[julia]-functions)

ジェネリック関数の登録、`rustcall-extract specialize` による単相化、`Result` / `Option` に対応する `#[julia]` 関数の Julia ラッパーを扱います。利用方法は[ジェネリクス](../generics.md)を参照してください。

## [ジェネリクス（`src/macros/generics.jl`）](@id Generics-(src/macros/generics.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "macros", "generics.jl")]
```

## [`#[julia]` 関数（`src/macros/julia_functions.jl`）](@id [julia]-functions-(src/macros/julia_functions.jl))

### [`#[julia]` 関数の文字列](@id Strings-in-#[julia]-functions)

独立関数は `String` / `&str` 引数と戻り値に対応します（#242）。元の関数を変更せず隣に生成する `rustcall_<fn>` は、引数を `(ptr, len)` の UTF-8 バイト列として受けます（NUL 終端は不要で、内部の NUL も可能）。`String` 戻り値は所有するバッファを Julia にコピーし、`<fn>_free_rust_string` で解放します。`&str` は借用ビューとして返し、直ちにコピーします（#279）。Julia 側は `AbstractString` を受け取り `String` を返します。インラインブロックと `@rust_crate` の両方に対応します。`Result` / `Option` 内の `String` はまだ未対応です。

```julia
rust\"\"\"
#[julia]
pub fn shout(input: String) -> String { input.to_uppercase() }
\"\"\"
shout("hello")  # "HELLO"
```


```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "macros", "julia_functions.jl")]
```

## [Rust 項目の Julia 名（`src/macros/julia_names.jl`）](@id Julia-names-of-Rust-items-(src/macros/julia_names.jl))

関数・メソッド・フィールド・構造体・モジュールの Julia 名を一元的に決めます（#514）。生識別子から `r#` を除き、Julia の予約語には末尾に `_` を付けます。

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "macros", "julia_names.jl")]
```
