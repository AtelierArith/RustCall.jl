# Cxx.jl 内部実装の詳細

このドキュメントでは、C++コードがどのように処理されてJuliaと連携できるのかの詳細な仕組みを説明します。

## 目次

1. [アーキテクチャ概要](#アーキテクチャ概要)
2. [処理フロー](#処理フロー)
3. [マクロ処理 (`@cxx`)](#マクロ処理-cxx)
4. [文字列リテラル (`cxx""` と `icxx""`)](#文字列リテラル-cxx-と-icxx)
5. [型システム](#型システム)
6. [コード生成プロセス](#コード生成プロセス)
7. [Clang統合](#clang統合)
8. [LLVM IR統合](#llvm-ir統合)

---

## アーキテクチャ概要

Cxx.jlは以下の3つの主要なコンポーネントで構成されています:

1. **Julia側のマクロとステージド関数**: Juliaの構文を解析し、型情報を抽出
2. **Clang統合**: C++コードを解析し、AST（抽象構文木）を生成
3. **LLVM統合**: Clang ASTからLLVM IRを生成し、Juliaの`llvmcall`に埋め込む

### データフロー

```
Juliaコード (@cxx マクロ)
    ↓
構文解析・型情報抽出 (cxxmacro.jl)
    ↓
ステージド関数 (@generated)
    ↓
Clang AST生成 (codegen.jl)
    ↓
LLVM IR生成 (Clang CodeGen)
    ↓
llvmcall埋め込み
    ↓
Julia実行時
```

---

## 処理フロー

### 1. マクロ展開段階

ユーザーが `@cxx foo::bar(args...)` と書くと:

```julia
# cxxmacro.jl の cpps_impl 関数が処理
@cxx foo::bar(args...)
    ↓
# 構文を解析し、名前空間と関数名を抽出
CppNNS{(:foo, :bar)} として型パラメータに格納
    ↓
# ステージド関数 cppcall を呼び出す式を生成
cppcall(__current_compiler__, CppNNS{(:foo, :bar)}(), args...)
```

### 2. ステージド関数実行段階

`@generated` 関数はコンパイル時に実行され、型情報に基づいてコードを生成:

```julia
@generated function cppcall(CT::CxxInstance, expr, args...)
    # CT: コンパイラインスタンス
    # expr: CppNNS{(:foo, :bar)} の型
    # args: 引数の型情報

    C = instance(CT)  # Clangインスタンスを取得

    # 1. 型チェック
    check_args(argt, expr)

    # 2. Clang ASTを構築
    callargs, pvds = buildargexprs(C, argt)
    d = declfornns(C, expr)  # 名前解決

    # 3. 呼び出し式を生成
    ce = CreateCallExpr(C, dne, callargs)

    # 4. LLVM IRを生成してllvmcallに埋め込む
    EmitExpr(C, ce, ...)
end
```

### 3. Clang AST生成

`buildargexprs` 関数は、Juliaの引数をClangのASTノードに変換:

```julia
function buildargexprs(C, argt; derefval = true)
    callargs = pcpp"clang::Expr"[]
    pvds = pcpp"clang::ParmVarDecl"[]

    for i in 1:length(argt)
        t = argt[i]
        st = stripmodifier(t)  # 修飾子を除去

        # Clangの型を取得
        argit = cpptype(C, st)

        # ParmVarDeclを作成（関数パラメータの宣言）
        argpvd = CreateParmVarDecl(C, argit)
        push!(pvds, argpvd)

        # DeclRefExprを作成（変数参照）
        expr = CreateDeclRefExpr(C, argpvd)

        # 修飾子を適用（*や&など）
        expr = resolvemodifier(C, t, expr)
        push!(callargs, expr)
    end

    callargs, pvds
end
```

### 4. LLVM IR生成と埋め込み

`EmitExpr` 関数は、Clang ASTからLLVM IRを生成し、Juliaの`llvmcall`に埋め込みます:

```julia
function EmitExpr(C, ce, nE, ctce, argt, pvds, rett = Cvoid)
    # 1. LLVM関数を作成
    f = CreateFunctionWithPersonality(C, llvmrt, map(julia_to_llvm, llvmargt))

    # 2. Clangのコード生成環境をセットアップ
    state = setup_cpp_env(C, f)
    builder = irbuilder(C)

    # 3. LLVM引数を処理
    args = llvmargs(C, builder, f, llvmargt)

    # 4. Clang ASTとLLVM値を関連付け
    associateargs(C, builder, argt, args, pvds)

    # 5. Clang ASTをLLVM IRにコンパイル
    ret = EmitCallExpr(C, ce, rslot)

    # 6. llvmcall式を生成
    createReturn(C, builder, f, argt, llvmargt, llvmrt, rett, rt, ret, state)
end
```

最終的に、以下のような`llvmcall`式が生成されます:

```julia
Expr(:call, Core.Intrinsics.llvmcall,
    convert(Ptr{Cvoid}, f),  # LLVM関数へのポインタ
    rett,                    # 戻り値の型
    Tuple{argt...},         # 引数の型
    args2...)               # 実際の引数
```

---

## マクロ処理 (`@cxx`)

### 構文解析

`cxxmacro.jl` の `cpps_impl` 関数が、Juliaの構文を解析してC++の意図を抽出します:

```julia
# 例: @cxx foo::bar::baz(a, b)
#
# 1. 名前空間の抽出
nns = Expr(:curly, Tuple, :foo, :bar, :baz)

# 2. 関数呼び出しの検出
cexpr = :(baz(a, b))

# 3. ステージド関数呼び出しを生成
build_cpp_call(mod, cexpr, nothing, nns)
    ↓
cppcall(__current_compiler__, CppNNS{(:foo, :bar, :baz)}(), a, b)
```

### メンバー呼び出し

`@cxx obj->method(args)` の場合:

```julia
# 1. -> 演算子を検出
expr.head == :(->)
a = expr.args[1]  # obj
b = expr.args[2]  # method(args)

# 2. メンバー呼び出し用のステージド関数を呼び出す
cppcall_member(__current_compiler__, CppNNS{(:method,)}(), obj, args...)
```

### 修飾子の処理

- `@cxx foo(*(a))`: `CppDeref` でラップ
- `@cxx foo(&a)`: `CppAddr` でラップ
- `@cxx foo(cast(T, a))`: `CppCast` でラップ

---

## 文字列リテラル (`cxx""` と `icxx""`)

### `cxx""` (グローバルスコープ)

`cxxstr.jl` の `process_cxx_string` 関数が処理:

```julia
cxx"""
    void myfunction(int x) {
        std::cout << x << std::endl;
    }
"""
```

処理の流れ:

1. **Julia式の抽出**: `$` で埋め込まれたJulia式を検出
2. **プレースホルダー置換**: `__julia::var1`, `__julia::var2` などに置換
3. **Clangパーサーに渡す**: `EnterBuffer` または `EnterVirtualSource`
4. **パース**: `ParseToEndOfFile` でC++コードを解析
5. **グローバルコンストラクタの実行**: `RunGlobalConstructors`

### `icxx""` (関数スコープ)

`icxx""` は関数内で使用され、実行時に評価されます:

```julia
function myfunc(x)
    icxx"""
        int result = $(x) * 2;
        return result;
    """
end
```

処理の流れ:

1. **ステージド関数の生成**: `cxxstr_impl` が `@generated` 関数として実行
2. **Clang関数の作成**: `CreateFunctionWithBody` でClangの関数宣言を作成
3. **パース**: `ParseFunctionStatementBody` で関数本体を解析
4. **LLVM IR生成**: `EmitTopLevelDecl` でLLVM IRにコンパイル
5. **呼び出し式の生成**: `CallDNE` で関数を呼び出す式を生成

### Julia式の埋め込み

`$` 構文でJulia式を埋め込む場合:

```julia
cxx"""
    void test() {
        $:(println("Hello from Julia")::Nothing);
    }
"""
```

処理:

1. `find_expr` 関数が `$` を検出
2. Julia式をパース: `Meta.parse(str, idx + 1)`
3. プレースホルダーに置換: `__juliavar1` など
4. Clangの外部セマンティックソースが、実行時にJulia式を評価

---

## 型システム

### Julia型からC++型への変換

`typetranslation.jl` の `cpptype` 関数が変換を担当:

```julia
# 基本型
cpptype(C, ::Type{Int32}) → QualType (clang::Type* へのポインタ)

# C++クラス
cpptype(C, ::Type{CppBaseType{:MyClass}})
    → lookup_ctx(C, :MyClass)  # 名前解決
    → typeForDecl(decl)        # Clang型を取得

# テンプレート
cpptype(C, ::Type{CppTemplate{CppBaseType{:vector}, Tuple{Int32}}})
    → specialize_template(C, cxxt, targs)  # テンプレート特殊化
    → typeForDecl(specialized_decl)

# ポインタ・参照
cpptype(C, ::Type{CppPtr{T, CVR}})
    → pointerTo(C, cpptype(C, T))  # ポインタ型を取得
    → addQualifiers(..., CVR)      # const/volatile/restrictを追加
```

### C++型からJulia型への変換

`juliatype` 関数が変換を担当:

```julia
function juliatype(t::QualType, quoted = false, typeargs = Dict{Int,Cvoid}())
    CVR = extractCVR(t)  # const/volatile/restrictを抽出
    t = extractTypePtr(t)
    t = canonicalType(t)  # 正規化

    if isPointerType(t)
        pt = getPointeeType(t)
        tt = juliatype(pt, quoted, typeargs)
        return CppPtr{tt, CVR}
    elseif isReferenceType(t)
        t = getPointeeType(t)
        pointeeT = juliatype(t, quoted, typeargs)
        return CppRef{pointeeT, CVR}
    elseif isEnumeralType(t)
        T = juliatype(getUnderlyingTypeOfEnum(t))
        return CppEnum{Symbol(get_name(t)), T}
    # ... 他の型
end
```

### 型の表現

- **CppBaseType{s}**: 基本型（例: `int`, `MyClass`）
- **CppTemplate{T, targs}**: テンプレート型（例: `std::vector<int>`）
- **CppPtr{T, CVR}**: ポインタ型
- **CppRef{T, CVR}**: 参照型
- **CppValue{T, N}**: 値型（スタック上）
- **CxxQualType{T, CVR}**: CVR修飾子付き型

---

## コード生成プロセス

### 1. 引数の準備 (`buildargexprs`)

```julia
function buildargexprs(C, argt; derefval = true)
    # 各引数に対して:
    # 1. Clangの型を取得
    argit = cpptype(C, stripmodifier(t))

    # 2. ParmVarDeclを作成（関数パラメータの宣言）
    argpvd = CreateParmVarDecl(C, argit)

    # 3. DeclRefExprを作成（変数参照式）
    expr = CreateDeclRefExpr(C, argpvd)

    # 4. 修飾子を適用（*や&など）
    expr = resolvemodifier(C, t, expr)
end
```

### 2. 名前解決 (`declfornns`)

```julia
function declfornns(C, ::Type{CppNNS{Tnns}}, cxxscope=C_NULL)
    nns = Tnns.parameters  # (:foo, :bar, :baz)
    d = translation_unit(C)  # 翻訳単位から開始

    for (i, n) in enumerate(nns)
        if n <: CppTemplate
            # テンプレートの特殊化
            d = specialize_template_clang(C, cxxt, arr)
        else
            # 通常の名前解決
            d = lookup_name(C, (n,), cxxscope, d, i != length(nns))
        end
    end

    d
end
```

### 3. 呼び出し式の生成

```julia
# 通常の関数呼び出し
ce = CreateCallExpr(C, dne, callargs)

# メンバー関数呼び出し
me = BuildMemberReference(C, callargs[1], cpptype(C, argt[1]),
                          argt[1] <: CppPtr, fname)
ce = BuildCallToMemberFunction(C, me, callargs[2:end])

# コンストラクタ呼び出し
ctce = BuildCXXTypeConstructExpr(C, rt, callargs)

# new式
nE = BuildCXXNewExpr(C, QualType(typeForDecl(cxxd)), callargs)
```

### 4. LLVM IR生成

```julia
function EmitExpr(C, ce, nE, ctce, argt, pvds, rett = Cvoid)
    # 1. LLVM関数を作成
    f = CreateFunctionWithPersonality(C, llvmrt, map(julia_to_llvm, llvmargt))

    # 2. コード生成環境をセットアップ
    state = setup_cpp_env(C, f)
    builder = irbuilder(C)

    # 3. LLVM引数を処理（Julia型からLLVM型へ変換）
    args = llvmargs(C, builder, f, llvmargt)

    # 4. Clang ASTとLLVM値を関連付け
    associateargs(C, builder, argt, args, pvds)

    # 5. Clang ASTをLLVM IRにコンパイル
    if ce != C_NULL
        ret = EmitCallExpr(C, ce, rslot)
    elseif nE != C_NULL
        ret = EmitCXXNewExpr(C, nE)
    elseif ctce != C_NULL
        EmitAnyExprToMem(C, ctce, args[1], true)
    end

    # 6. llvmcall式を生成
    createReturn(C, builder, f, argt, llvmargt, llvmrt, rett, rt, ret, state)
end
```

### 5. LLVM値の変換

`resolvemodifier_llvm` 関数が、JuliaのLLVM表現をClangのLLVM表現に変換:

```julia
# ポインタ型
resolvemodifier_llvm(C, builder, t::Type{Ptr{ptr}}, v)
    → IntToPtr(builder, v, toLLVM(C, cpptype(C, Ptr{ptr})))

# CppValue型（値型）
resolvemodifier_llvm(C, builder, t::Type{T} where T <: CppValue, v)
    → CreatePointerFromObjref(C, builder, v)
    → CreateBitCast(builder, v, getPointerTo(getPointerTo(toLLVM(C, ty))))

# CppRef型（参照）
resolvemodifier_llvm(C, builder, t::Type{CppRef{T, CVR}}, v)
    → IntToPtr(builder, v, toLLVM(C, ty))
```

---

## Clang統合

### Clangインスタンスの初期化

`initialization.jl` の `setup_instance` 関数:

```julia
function setup_instance(PCHBuffer = []; makeCCompiler=false, ...)
    x = Ref{ClangCompiler}()

    # C++側のinit_clang_instanceを呼び出し
    ccall((:init_clang_instance, libcxxffi), Cvoid,
        (Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt8}, ...),
        x, target, CPU, sysroot, ...)

    # デフォルトABIを適用
    useDefaultCxxABI && ccall((:apply_default_abi, libcxxffi), ...)

    x[]
end
```

### ヘッダー検索パスの追加

```julia
function addHeaderDir(C, dirname; kind = C_User, isFramework = false)
    ccall((:add_directory, libcxxffi), Cvoid,
        (Ref{ClangCompiler}, Cint, Cint, Ptr{UInt8}),
        C, kind, isFramework, dirname)
end
```

### ソースバッファの入力

```julia
# 匿名バッファ
function EnterBuffer(C, buf)
    ccall((:EnterSourceFile, libcxxffi), Cvoid,
        (Ref{ClangCompiler}, Ptr{UInt8}, Csize_t),
        C, buf, sizeof(buf))
end

# 仮想ファイル（ファイル名を指定）
function EnterVirtualSource(C, buf, file::String)
    ccall((:EnterVirtualFile, libcxxffi), Cvoid,
        (Ref{ClangCompiler}, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
        C, buf, sizeof(buf), file, sizeof(file))
end
```

### パース

```julia
function ParseToEndOfFile(C)
    hadError = ccall((:_cxxparse, libcxxffi), Cint, (Ref{ClangCompiler},), C) == 0
    if !hadError
        RunGlobalConstructors(C)  # グローバルコンストラクタを実行
    end
    !hadError
end
```

---

## LLVM IR統合

### llvmcallの使用

Cxx.jlは、Juliaの`llvmcall`の第2形式（ポインタ形式）を使用:

```julia
llvmcall(convert(Ptr{Cvoid}, f),  # LLVM関数へのポインタ
         rett,                     # 戻り値の型
         Tuple{argt...},          # 引数の型タプル
         args...)                 # 実際の引数
```

この形式では、JuliaはLLVM関数を直接呼び出し、引数の変換とインライン化を行います。

### LLVM関数の作成

```julia
function CreateFunction(C, rt, argt)
    pcpp"llvm::Function"(
        ccall((:CreateFunction, libcxxffi), Ptr{Cvoid},
            (Ref{ClangCompiler}, Ptr{Cvoid}, Ptr{Ptr{Cvoid}}, Csize_t),
            C, rt, cptrarr(argt), length(argt)))
end
```

### 型変換

```julia
function julia_to_llvm(@nospecialize x)
    isboxed, ty = _julia_to_llvm(x)
    isboxed ? getPRJLValueTy() : ty  # ボックス化された型はjl_value_t*に
end
```

### 戻り値の処理

`createReturn` 関数が、LLVM IRの戻り値をJuliaの形式に変換:

```julia
function createReturn(C, builder, f, argt, llvmargt, llvmrt, rett, rt, ret, state)
    if ret == C_NULL
        CreateRetVoid(builder)
    else
        if rett <: CppEnum || rett <: CppFptr
            # 構造体にラップ
            undef = getUndefValue(llvmrt)
            ret = InsertValue(builder, undef, ret, 0)
        elseif rett <: CppRef || rett <: CppPtr || rett <: Ptr
            # ポインタを整数に変換
            ret = PtrToInt(builder, ret, llvmrt)
        elseif rett <: CppValue
            # 値型は特別な処理が必要
            # ...
        end
        CreateRet(builder, ret)
    end

    # llvmcall式を生成
    Expr(:call, Core.Intrinsics.llvmcall, convert(Ptr{Cvoid}, f), rett, ...)
end
```

---

## メモリ管理

### C++オブジェクトのライフサイクル

- **CppPtr**: ヒープに確保されたオブジェクトへのポインタ
- **CppRef**: 既存オブジェクトへの参照
- **CppValue**: スタック上またはJuliaの構造体内に格納された値

### デストラクタの呼び出し

`CppValue` で非自明なデストラクタを持つ型の場合:

```julia
if rett <: CppValue
    T = cpptype(C, rett)
    D = getAsCXXRecordDecl(T)
    if D != C_NULL && !hasTrivialDestructor(C, D)
        # finalizerを登録してデストラクタを呼び出す
        push!(B.args, :(finalizer($(get_destruct_for_instance(C)), r)))
    end
end
```

---

## エラーハンドリング

### C++例外の処理

`exceptions.jl` でC++例外をJulia例外に変換:

```julia
function setup_exception_callback()
    callback = cglobal((:process_cxx_exception, libcxxffi), Ptr{Cvoid})
    unsafe_store!(callback, @cfunction(process_cxx_exception, Union{}, (UInt64, Ptr{Cvoid})))
end
```

C++側で例外が発生すると、このコールバックが呼び出され、Julia例外に変換されます。

---

## 最適化のポイント

1. **型情報の活用**: ステージド関数により、コンパイル時に型が確定しているため、適切なC++関数を選択可能
2. **インライン化**: `llvmcall`により、LLVM IRがJuliaのIRにインライン化され、最適化が適用される
3. **PCH（Precompiled Header）**: 頻繁に使用されるヘッダーをプリコンパイルして高速化
4. **テンプレート特殊化のキャッシュ**: 一度特殊化したテンプレートは再利用

---

## まとめ

Cxx.jlは、以下の技術を組み合わせてC++とJuliaの相互運用を実現しています:

1. **マクロとステージド関数**: 構文解析と型情報の抽出
2. **Clang統合**: C++コードの解析とAST生成
3. **LLVM統合**: ASTからLLVM IRへの変換とJuliaへの埋め込み
4. **型システム**: Julia型とC++型の双方向変換

このアーキテクチャにより、C++コードをJuliaから直接呼び出すことができ、両言語の最適化を活用できます。
