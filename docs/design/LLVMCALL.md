# Julia の llvmcall について

## 概要

`llvmcall`は、Juliaの低レベル機能で、LLVM IR（Intermediate Representation）を直接Juliaコードに埋め込むことができます。これは、Juliaの「インラインアセンブリ」に相当する機能ですが、LLVM IRレベルで動作するため、より高レベルで最適化が効きやすいという利点があります。

## 基本的な構文

`llvmcall`には2つの形式があります：

### 形式1: 文字列形式（String Form）

```julia
llvmcall(ir_string, return_type, arg_types_tuple, args...)
```

**パラメータ**:
- `ir_string`: LLVM IRコード（文字列）
- `return_type`: 戻り値の型
- `arg_types_tuple`: 引数の型のタプル
- `args...`: 実際の引数

**例**:

```julia
function add_ints(x::Int32, y::Int32)
    llvmcall("""
        %3 = add i32 %1, %0
        ret i32 %3
    """, Int32, (Int32, Int32), x, y)
end

# 使用例
result = add_ints(10, 20)  # => 30
```

### 形式2: ポインタ形式（Pointer Form）

```julia
llvmcall(function_pointer, return_type, arg_types_tuple, args...)
```

**パラメータ**:
- `function_pointer`: LLVM関数へのポインタ（`Ptr{Cvoid}`）
- `return_type`: 戻り値の型
- `arg_types_tuple`: 引数の型のタプル
- `args...`: 実際の引数

**例**:

```julia
# LLVM関数へのポインタを取得（通常は外部から生成）
f = get_llvm_function_pointer()

function call_llvm_function(x, y)
    llvmcall(f, Int32, (Int32, Int32), x, y)
end
```

## 2つの形式の違い

### 文字列形式の動作

1. **ラッピング**: Juliaは提供されたLLVM IRを、指定された戻り値の型と引数の型を持つLLVM関数でラップします
2. **引数変換**: Juliaは`ccall`と同様の引数変換（アンボックス化など）を行います
3. **インライン化**: 生成された呼び出し命令はインライン化されます

### ポインタ形式の動作

1. **ラッピングなし**: Juliaはラッピングをスキップし、直接引数変換とインライン化に進みます
2. **より効率的**: 既に完全なLLVM関数がある場合、この形式の方が効率的です
3. **Cxx.jlでの使用**: Cxx.jlはこの形式を使用して、Clangで生成したLLVM IRを直接埋め込みます

## LLVM IRの構文

### 基本的な命令

```llvm
; 加算
%result = add i32 %a, %b

; 減算
%result = sub i32 %a, %b

; 乗算
%result = mul i32 %a, %b

; 除算
%result = sdiv i32 %a, %b  ; 符号付き除算
%result = udiv i32 %a, %b  ; 符号なし除算

; 戻り値
ret i32 %result
ret void  ; 戻り値なし
```

### 型

```llvm
i8    ; 8ビット整数
i16   ; 16ビット整数
i32   ; 32ビット整数
i64   ; 64ビット整数
float ; 32ビット浮動小数点数
double; 64ビット浮動小数点数
void  ; 戻り値なし
```

### 引数の参照

文字列形式では、引数は`%0`, `%1`, `%2`, ... として参照されます：
- `%0`: 最初の引数
- `%1`: 2番目の引数
- 以降同様

**注意**: 引数の順序は、LLVM IR内では逆順になることがあります（例: `%1`が最初の引数、`%0`が2番目の引数）。これはLLVMの呼び出し規約によるものです。

## 使用例

### 例1: 基本的な算術演算

```julia
function multiply(x::Int32, y::Int32)
    llvmcall("""
        %result = mul i32 %1, %0
        ret i32 %result
    """, Int32, (Int32, Int32), x, y)
end

multiply(5, 7)  # => 35
```

### 例2: 浮動小数点演算

```julia
function add_floats(x::Float64, y::Float64)
    llvmcall("""
        %result = fadd double %1, %0
        ret double %result
    """, Float64, (Float64, Float64), x, y)
end

add_floats(3.14, 2.71)  # => 5.85
```

### 例3: 条件分岐

```julia
function max_int(x::Int32, y::Int32)
    llvmcall("""
        %cmp = icmp sgt i32 %1, %0
        %result = select i1 %cmp, i32 %1, i32 %0
        ret i32 %result
    """, Int32, (Int32, Int32), x, y)
end

max_int(10, 20)  # => 20
```

### 例4: ポインタ操作

```julia
function load_and_add(ptr::Ptr{Int32}, value::Int32)
    llvmcall("""
        %loaded = load i32, i32* %1
        %result = add i32 %loaded, %0
        ret i32 %result
    """, Int32, (Ptr{Int32}, Int32), ptr, value)
end
```

### 例5: ポインタ形式の使用（Cxx.jlスタイル）

```julia
# ステージド関数でLLVM関数を生成
@generated function call_cpp_function(args...)
    # LLVM関数を生成（実際の実装は省略）
    f = generate_llvm_function(args)

    # ポインタ形式でllvmcallを生成
    Expr(:call, Core.Intrinsics.llvmcall,
        convert(Ptr{Cvoid}, f),
        get_return_type(args),
        Tuple{map(get_type, args)...},
        [:(args[$i]) for i in 1:length(args)]...)
end
```

## 最適化の利点

`llvmcall`の重要な利点は、LLVM IRがJuliaのIRにインライン化された**後**に最適化が実行されることです。これにより：

1. **定数伝播**: JuliaとLLVM IRの両方にわたって定数が伝播されます
2. **デッドコード削除**: 使用されないコードが削除されます
3. **インライン化**: 関数呼び出しがインライン化されます
4. **ループ最適化**: ループ最適化が適用されます

これは、機械語のインラインアセンブリとは異なり、コンパイラがコード全体を見て最適化できることを意味します。

## 注意事項

### 1. 引数の順序

LLVM IR内での引数の参照順序は、Juliaの引数の順序と異なる場合があります。通常、`%0`が最後の引数、`%1`がその前の引数、というように逆順になります。

**推奨**: 実際にテストして確認するか、デバッグ出力を使用して順序を確認してください。

### 2. 型の一致

LLVM IR内の型は、Juliaの型と正確に一致する必要があります：

```julia
# 正しい
llvmcall("...", Int32, (Int32, Int32), x, y)

# 間違い（型が一致しない）
llvmcall("...", Int64, (Int32, Int32), x, y)  # 戻り値の型が違う
```

### 3. メモリ安全性

`llvmcall`は低レベルな操作であり、メモリ安全性は保証されません。ポインタ操作を行う場合は、十分に注意してください。

### 4. プラットフォーム依存性

一部のLLVM IR命令は、プラットフォームに依存する可能性があります。可能な限り、プラットフォーム非依存のコードを書くようにしてください。

## Cxx.jlでの使用

Cxx.jlは、`llvmcall`のポインタ形式を使用して、Clangで生成したLLVM IRをJuliaに埋め込みます：

```julia
# Cxx.jlの内部実装（簡略化）
function createReturn(C, builder, f, argt, llvmargt, llvmrt, rett, rt, ret, state)
    # ... LLVM IRの生成 ...

    # llvmcall式を生成
    Expr(:call, Core.Intrinsics.llvmcall,
        convert(Ptr{Cvoid}, f),  # Clangで生成したLLVM関数へのポインタ
        rett,                     # 戻り値の型
        Tuple{argt...},          # 引数の型タプル
        args2...)                # 実際の引数
end
```

このアプローチにより、C++コードをClangでコンパイルし、生成されたLLVM IRを直接Juliaに埋め込むことができます。

## LastCall.jlでの使用予定

LastCall.jl（Phase 2）でも、同様のアプローチを使用します：

```julia
# LastCall.jlの内部実装（予定）
@generated function rustcall(CT::RustInstance, expr, args...)
    # 1. RustコードをLLVM IRにコンパイル
    llvm_mod = compile_rust_to_llvm(rust_code)

    # 2. 関数を取得
    fn = functions(llvm_mod)[func_name]

    # 3. llvmcallに埋め込む
    Expr(:call, Core.Intrinsics.llvmcall,
        convert(Ptr{Cvoid}, fn),
        ret_type,
        Tuple{arg_types...},
        args...)
end
```

## デバッグ

### LLVM IRの確認

生成されたLLVM IRを確認するには、Juliaのコード生成をデバッグモードで実行します：

```julia
# Juliaのコード生成を確認
@code_llvm function_name(args...)

# より詳細な情報
@code_llvm debug=true function_name(args...)
```

### エラーの対処

`llvmcall`でエラーが発生した場合：

1. **型の不一致**: LLVM IR内の型とJuliaの型が一致しているか確認
2. **引数の順序**: 引数の参照順序が正しいか確認
3. **構文エラー**: LLVM IRの構文が正しいか確認

## パフォーマンス

`llvmcall`を使用することで、以下のパフォーマンス上の利点があります：

1. **関数呼び出しのオーバーヘッドの削減**: インライン化により、関数呼び出しのオーバーヘッドが削減されます
2. **最適化の適用**: LLVMの最適化パスが適用されます
3. **型の特殊化**: ステージド関数と組み合わせることで、型に特化したコードを生成できます

## 参考資料

- [Julia Manual: LLVM Call](https://docs.julialang.org/en/v1/manual/performance-tips/#man-llvm-call)
- [LLVM Language Reference Manual](https://llvm.org/docs/LangRef.html)
- [Cxx.jl Implementation](https://github.com/JuliaInterop/Cxx.jl)

## まとめ

`llvmcall`は、Juliaで低レベルな最適化を行うための強力なツールです。特に：

- **文字列形式**: 簡単なLLVM IRコードを直接埋め込む場合に便利
- **ポインタ形式**: 既に生成されたLLVM関数を使用する場合に効率的（Cxx.jl、LastCall.jlで使用）

Cxx.jlやLastCall.jlのようなパッケージでは、外部言語（C++、Rust）のコードをLLVM IRにコンパイルし、`llvmcall`のポインタ形式を使用してJuliaに統合することで、高性能な相互運用を実現しています。
