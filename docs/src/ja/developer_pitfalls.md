<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/developer_pitfalls.md. -->
# [開発時の注意点](@id Developer-Pitfalls)

このプロジェクトで実際にバグの原因となった Julia の落とし穴です。コードを追加する際に確認してください。

## [添字を含む文字列補間](@id String-Interpolation-with-Indexing)

**関連バグ**：[#69](https://github.com/AtelierArith/RustCall.jl/issues/69)

`"$var[i]"` は添字アクセスをしません。`var` の値を補間した後、文字列 `[i]` を付けます。正しくは `"$(var[i])"` です。

```julia
# WRONG — interpolates the whole array, then appends "[1]"
types = ["i32", "i64"]
s = "$types[1]"        # => "[\"i32\", \"i64\"][1]"

# CORRECT — indexes first, then interpolates the element
s = "$(types[1])"      # => "i32"
```

**規則**：添字、フィールド、関数呼び出しなど複雑な式は必ず `$(...)` で囲みます。

**CI 検査**：`scripts/lint_interpolation.sh` が `$identifier[` を検出します。指摘された行を確認して括弧を追加してください。

## [型エイリアス](@id Type-Aliases)

**関連バグ**：[#70](https://github.com/AtelierArith/RustCall.jl/issues/70)

同じ型を表す名前ごとにメソッドを定義すると、プリコンパイル中に `Method overwriting is not permitted during Module precompilation` が発生します。

### [よく使う型エイリアス](@id Common-Type-Aliases)

| 別名 | 実体 | 備考 |
|------|------|------|
| `Cvoid` | `Nothing` | `Cvoid === Nothing` は `true` |
| `Cstring` | `Ptr{UInt8}` | `Cstring === Ptr{UInt8}` は `true` |
| `Cwstring` | `Ptr{Cwchar_t}` | 文字型はプラットフォーム依存 |
| `Cuint` | `UInt32` | ほとんどの環境 |
| `Clong` | `Int64` | 64ビット Linux/macOS。Windows は `Int32` |
| `Culong` | `UInt64` | 64ビット Linux/macOS。Windows は `UInt32` |
| `Csize_t` | `UInt64` | 64ビット環境 |

### [確認方法](@id How-to-Check)

新しい型のメソッドを追加する前に、別名ではないか確認します。

```julia
julia> Cvoid === Nothing
true

julia> Cstring === Ptr{UInt8}
true
```

### [対処方法](@id How-to-Handle)

代表となる型だけに定義し、コメントで理由を示します。

```julia
# Void type (Cvoid === Nothing in Julia, so this handles both)
RustCall.juliatype_to_rust(::Type{Nothing}) = "()"
```

利用者向けコードで両方の名前を扱う場合は、メソッドを分けず、シンボルや文字列に対する条件分岐を使います。

```julia
if t == Cvoid || t == Nothing
    # handle void
end
```

## [プラットフォーム依存の型サイズ](@id Platform-Dependent-Type-Sizes)

C 連携用の型の一部は環境によりサイズが異なります。

```julia
# 64-bit Linux/macOS
Clong === Int64
Culong === UInt64

# Windows (even 64-bit)
Clong === Int32
Culong === UInt32
```

型変換コードでは次のいずれかを選びます。

1. `Clong` などの Julia の別名を使い、サイズをプラットフォームに任せる。
2. 環境固有の処理が必要なら `sizeof(Clong)` を明示的に確認する。
