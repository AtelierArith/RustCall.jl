<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/struct_mapping.md. -->
# [`#[derive(JuliaStruct)]` による構造体の対応付け](@id Struct-Mapping-with-#[derive(JuliaStruct)])

Rust の構造体を Julia のオブジェクトとして利用するバインディングを自動生成します。

!!! note "`#[julia]` と `#[derive(JuliaStruct)]`"
    インラインでは両方が同じ印です。`#[derive(JuliaStruct, Clone)]` の `Clone` はコピー機能を導出します。外部クレートでは `#[julia]` を使います（[ガイド](crate_bindings.md)）。構文は[構造体とメソッド](rust_primer.md#Structs-and-methods)を参照してください。

```@setup struct_mapping
using RustCall
```

## [概要](@id Overview)

Julia 型、フィールドの getter / setter、指定したトレイト実装、メモリを解放する finalizer を生成します。

## [基本的な使い方](@id Basic-Usage)

### [単純な構造体](@id Simple-Struct)

```@example struct_mapping
rust"""
#[derive(JuliaStruct)]
pub struct Point2D {
    x: f64,
    y: f64,
}

impl Point2D {
    pub fn new(x: f64, y: f64) -> Self {
        Point2D { x, y }
    }

    pub fn distance(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}
"""

# Create a Point2D instance
p = Point2D(3.0, 4.0)

# Access fields directly
println(p.x)  # => 3.0
println(p.y)  # => 4.0

# Modify fields
p.y = 5.0
println(p.y)  # => 5.0

# Call methods
dist = p.distance()
println(dist)  # => 5.830951894845301
```

### [Clone への対応](@id With-Clone-Support)

```@example struct_mapping
rust"""
#[derive(JuliaStruct, Clone)]
pub struct PersonInfo {
    name: String,
    age: i32,
}

impl PersonInfo {
    pub fn new(name: String, age: i32) -> Self {
        PersonInfo { name, age }
    }

    pub fn get_name(&self) -> String {
        self.name.clone()
    }
}
"""

# Create a person
person = PersonInfo("Alice", 30)
println(person.name)      # => "Alice"
println(get_name(person)) # => "Alice"

# Clone the person
person2 = copy(person)  # Uses Rust's Clone trait

# Both are independent objects
person.age = 31
println(person.age)   # => 31
println(person2.age)  # => 30
```

## [derive のオプション](@id Derive-Options)

追加の derive を指定できます。

### [対応トレイト](@id Supported-Traits)

- **`Clone`**：Julia の `copy()` を可能にします。
- **`Debug`、`PartialEq`、`Eq`、`PartialOrd`、`Ord`、`Hash`、`Default`**：将来の対応用です。

### [複数トレイトの例](@id Example-with-Multiple-Traits)

```julia
rust"""
#[derive(JuliaStruct, Clone)]
pub struct Config {
    host: String,
    port: i32,
    timeout: f64,
}

impl Config {
    pub fn new(host: String, port: i32, timeout: f64) -> Self {
        Config { host, port, timeout }
    }
}
"""

config = Config("localhost", 8080, 30.0)
config2 = copy(config)  # Clone support
```

## [フィールドへのアクセス](@id Field-Access)

### [自動 getter と setter](@id Automatic-Getters-and-Setters)

`obj.field_name` と `obj.field_name = value` を生成します。

```julia
rust"""
#[derive(JuliaStruct)]
pub struct Rectangle {
    width: f64,
    height: f64,
}

impl Rectangle {
    pub fn new(width: f64, height: f64) -> Self {
        Rectangle { width, height }
    }

    pub fn area(&self) -> f64 {
        self.width * self.height
    }
}
"""

rect = Rectangle(10.0, 20.0)

# Get field values
w = rect.width   # => 10.0
h = rect.height  # => 20.0

# Set field values
rect.width = 15.0
rect.height = 25.0

# Calculate area
rect_area = rect.area()  # => 375.0
```

### [フィールド型の対応](@id Field-Type-Mapping)

独立関数・メソッドと同じ [FFI 型契約](type_contract.md)を使います。

| Rust | Julia | 備考 |
|------|-------|------|
| `i8` … `i128`, `u8` … `u128` | `Int8` … `Int128`, `UInt8` … `UInt128` | |
| `f32`, `f64` | `Float32`, `Float64` | |
| `bool` | `Bool` | |
| `usize`, `isize` | `Csize_t`, `Cssize_t` | |
| `char` | `Char` | `UInt32` のコードポイントから変換。再解釈しない |
| `*const T`, `*mut T` | `Ptr{T}` | 再帰的解決。不透明な参照先は `Ptr{Cvoid}` |
| `String` | `String` | 所有バッファを読み、`<Struct>_free_rust_string` で解放 |
| `&str` | `String` | メソッドの戻り値をコピー |

基本型、生ポインタ、`String`、ジェネリック構造体自身の型引数だけにアクセサーを生成します。`Vec`、`HashMap`、`Box`、値で保持する別構造体などには、公開フィールドでも生成しません。内部に保ち、長さやコピーを返すメソッドを公開します（[#453](https://github.com/AtelierArith/RustCall.jl/issues/453)）。

## [ジェネリック構造体](@id Generic-Structs)

```julia
rust"""
#[derive(JuliaStruct)]
pub struct Pair<T> {
    first: T,
    second: T,
}

impl<T> Pair<T> {
    pub fn new(first: T, second: T) -> Self {
        Pair { first, second }
    }
}
"""

# Create a Pair with Int32
pair_int = Pair{Int32}(10, 20)
println(pair_int.first)   # => 10
println(pair_int.second)  # => 20

# Create a Pair with Float64
pair_float = Pair{Float64}(3.14, 2.71)
println(pair_float.first)   # => 3.14
println(pair_float.second)  # => 2.71
```

!!! note
    `Pair{Int32}` / `Pair{Float64}` のような例に対応します。複雑な制約は追加検証が必要な場合があります。

## [メモリ管理](@id Memory-Management)

Julia の GC がラッパーを回収すると、対応する Rust のメモリも自動で解放します。

## [メソッドのバインド](@id Method-Binding)

インラインの `impl` 内の `pub fn` を自動でバインドします。

```julia
rust"""
#[derive(JuliaStruct)]
pub struct Calculator {
    value: f64,
}

impl Calculator {
    pub fn new(value: f64) -> Self {
        Calculator { value }
    }

    pub fn add(&mut self, x: f64) {
        self.value += x;
    }

    pub fn multiply(&mut self, x: f64) {
        self.value *= x;
    }

    pub fn get_value(&self) -> f64 {
        self.value
    }

    pub fn reset(&mut self) {
        self.value = 0.0;
    }
}
"""

calc = Calculator(10.0)
calc.add(5.0)
calc.multiply(2.0)
println(calc.get_value())  # => 30.0
calc.reset()
println(calc.get_value())  # => 0.0
```

### [非ジェネリック構造体のジェネリックメソッド](@id Generic-methods-of-a-non-generic-struct)

固定シンボルの C ABI には具体型が必要です。メソッド独自の型・const 引数や `impl Trait` は、そのメソッドを示す `compile_error!` で拒否します（#471）。

```text
error: `Acc::echo` is generic over `T`: every `pub fn` of a `#[julia]` struct in a
`rust"""` block gets an `extern "C"` entry point, which needs concrete types, ...
```

[独立関数](generics.md)または[構造体自身](#Generic-Structs)のジェネリクスを使うか、具体型ごとの委譲メソッドにします。Julia から不要なら `pub` を外します。

```rust
impl Acc {
    fn scaled_by<T: Copy + Into<i64>>(&self, k: T) -> i64 { self.total * k.into() }
    pub fn scaled_i32(&self, k: i32) -> i64 { self.scaled_by(k) }
}

#[julia]
pub fn echo<T: Copy>(x: T) -> T { x }
```

`Wrap<T>` のメソッド独自の `U` も、構造体の具体化が束縛しないため拒否します（#477）。ライフタイム引数は別で、`<'a, 'b: 'a>` や `where 'b: 'a` をラッパーにも宣言します。外部クレートもジェネリックメソッドは拒否します（#462）。

### [where 条件](@id Where-predicates)

ラッパーは impl とメソッドのライフタイム・`where` をそのまま宣言します（#482）。`Self` は impl 型へ書き換え、型・式の両方で `where Self: Tagged` → `where Buf: Tagged`、`<Self as Tagged>::Tag` → `<Buf as Tagged>::Tag`、`[(); Self::N]` → `[(); <Buf>::N]` とします。高階境界、関数ポインタ、トレイトオブジェクトなどの条件を選別・削除しません。マクロ内の `Self` は書き換えられず拒否するため型を明示します。

`&str` はポインタ・長さから呼び出し中だけ再構成します。呼び出しまで縮められるライフタイム関係は可能ですが、`'static`、戻り値に現れる期間、他引数の最外参照以外で使う期間、型条件に使う期間は拒否します。必要なら `String` を使います。

### [レシーバー](@id Receivers)

ラッパーはポインタを受け、`<Buf>::m(..)` または `<Buf as tr::Tr>::m(..)` とパスで呼びます（#509）。`Self` または impl ヘッダーと同じ型表記の参照階層に対応します。

| レシーバー | C 引数 | Julia オブジェクト |
|------------|--------|--------------------|
| `&self`, `self: &Self`, `self: &Buf`, `self: &&Self` | `*const Buf` | 読み取り |
| `&mut self`, `self: &mut Self`, `self: &mut Buf`, `self: &mut &mut Self` | `*mut Buf` | その場で変更 |
| `self`, `mut self`, `self: Self` | `*const Buf` | `Copy` 型のコピーを渡す |

エイリアス、`Box` / `Rc` / `Arc` / `Pin`、ヘッダーと異なる型表記は `receiver_type` として拒否します。対応レシーバーを取る委譲メソッドを追加してください。

### [構造体引数の借用](@id Borrowed-struct-arguments)

同じクレート・ブロックの注釈型を指す `&Self`、`&Value`、`&mut Value`、修飾パスや `use` の型はハンドルからポインタを渡せます（#565）。

```rust
#[julia]
impl Value {
    #[julia]
    pub fn sum(&self, other: &Value) -> i32 { self.n + other.n }
    #[julia]
    pub fn absorb(&mut self, other: &Value) { self.n += other.n; }
}
#[julia]
pub fn total(a: &Value, b: &Value) -> i32 { a.n + b.n }
```


```julia
a, b = bindings.Value(Int32(2)), bindings.Value(Int32(3))
bindings.sum(a, b)    # 5
bindings.sum(a, a)    # 4: shared borrows may alias
bindings.absorb(a, a) # ArgumentError: a `&mut` borrow may not alias another
```

コピーや値渡し登録は不要です。Julia は、正しい生成型（別モジュールや別生成経路の同名型は不可）、未解放、閉じていないイメージ、レシーバーを含む同じライブラリ世代、可変借用の非重複を検査します。

変換できる期間は呼び出し内だけで、省略・`'_`・関数自身の境界なしライフタイムに限り、`where` や戻り値に現れるもの、impl の期間、`'static` などはハンドルから変換しません。明示的 `Ptr{Cvoid}` は引き続き未検査で渡せます。全ハンドルは呼び出し中 GC 保護し、一時値も解放されません。再読み込みで配置が変われば新しい値を作ってください。

型は修飾・ローカル・import に従って確実に解決します。同名のローカル型を無視しません。型エイリアスや具体化済みジェネリックなどの制約があります。glob の最新のスコープ証明規則は[外部クレート](crate_bindings.md)を参照してください。

### [参照の戻り値](@id Returned-references)

`-> &i32`、`-> &Self`、`-> Option<&i32>`、`-> &'_ i32` の省略期間は Rust の規則で名前を与えます（#484）。レシーバー、なければ1つの引数の期間を使い、公開名は変えません。

ただし型契約に `&T` はないため、既定の厳密設定では拒否します。`:warn` ならコンパイルでき、`@rust rustcall_Buf_get(obj.ptr)::Ptr{Int32}` などで取れますが、有効なのはオブジェクトの生存中だけです。通常は `-> i32` の値返却を選びます。

唯一の期間が変換した `&str` 由来なら、返した参照が失効するため引数で拒否します。所有値か別の有効期間にしてください。元の出力期間が曖昧な関数は、ラッパーを作らず Rust の E0106 に任せます。

## [静的メソッド](@id Static-Methods)

フィールドを持つ構造体の `self` なしメソッドに対応します。

```julia
rust"""
#[derive(JuliaStruct)]
pub struct MathUtils {
    dummy: i32,
}

impl MathUtils {
    pub fn new() -> Self {
        MathUtils { dummy: 0 }
    }

    pub fn add(a: f64, b: f64) -> f64 {
        a + b
    }

    pub fn multiply(a: f64, b: f64) -> f64 {
        a * b
    }
}
"""

# Call static methods with the type first — the Julia spelling of
# `MathUtils::add(3.0, 4.0)`:
result1 = add(MathUtils, 3.0, 4.0)      # => 7.0
result2 = multiply(MathUtils, 3.0, 4.0) # => 12.0

# The bare form exists too, as long as nothing else in the block is called
# `add` or `multiply`:
result1 = add(3.0, 4.0)                 # => 7.0
```

型を先頭引数にして、同名の独立関数との上書きを防ぎます。独立関数や他の静的メソッドと衝突する場合、静的側は型付き形式だけです（#323）。外部クレートも同じです。

!!! note
    ユニット構造体は将来の対応予定なので、例では通常の構造体を使います。

## [Julia の予約語](@id Names-Julia-reserves)

`end`、`begin`、`quote`、`r#for`、`r#let` などは、`r#` を除去し、Julia 予約語に `_` を付けます（#514）。全生成経路で共通です。

```julia
rust"""
#[julia]
pub struct end { pub r#let: i32, pub begin: i32 }

#[julia]
impl end {
    pub fn new(a: i32, b: i32) -> Self { end { r#let: a, begin: b } }
    pub fn quote(&self) -> i32 { self.r#let + self.begin }
}
"""

e = end_(Int32(2), Int32(3))
e.let_, e.begin_   # (2, 3)
quote_(e)          # 5
```

Rust の公開シンボルは変えません。`r#for` と `for_` のように変換後が重なると、両項目を示して拒否します。

## [Result / Option を返すメソッド](@id Result-and-Option-Returning-Methods)

独立関数と同じく、`#[repr(C)]` の `CResult_<Struct>_<method>` / `COption_<Struct>_<method>` を介し、Julia に `RustResult{T,E}` / `RustOption{T}` を返します（#268）。インライン・クレート・保存済みファイルで共通です。

```julia
rust"""
#[julia]
pub struct Divider {
    pub scale: i32,
}

impl Divider {
    pub fn new(scale: i32) -> Self { Divider { scale } }

    pub fn checked_div(&self, d: i32) -> Result<i32, String> {
        if d == 0 {
            Err(format!("cannot divide {} by zero", self.scale))
        } else {
            Ok(self.scale / d)
        }
    }

    pub fn ratio(&self, d: i32) -> Option<f64> {
        if d == 0 { None } else { Some(self.scale as f64 / d as f64) }
    }

    pub fn describe(&self, unit: String) -> Result<String, String> {
        if unit.is_empty() {
            Err("empty unit".to_string())
        } else {
            Ok(format!("{} {}", self.scale, unit))
        }
    }
}
"""

d = Divider(Int32(10))

RustCall.unwrap(checked_div(d, Int32(2)))   # => 5
checked_div(d, Int32(0)).value              # => "cannot divide 10 by zero"
RustCall.unwrap(ratio(d, Int32(4)))         # => 2.5
RustCall.is_none(ratio(d, Int32(0)))        # => true
RustCall.unwrap(describe(d, "meters"))      # => "10 meters"
```

可変レシーバー、静的、独立関数も同様です。

### [文字列のペイロード](@id String-payloads)

`String` / `&str` は `<owner>_RustCallOwnedString { ptr, len, cap }` に変換し、`<owner>_free_rust_string` で解放します。Result と文字列変換を合成でき、`Result<String, String>` にも対応します。owner はインラインでは構造体、クレートでは `<Struct>_<method>` です。

Julia はコピー後直ちに、呼び出しと**同じ世代スナップショット**の関数で解放します。有効なペイロードだけを読み、未初期化の非選択側は読みません。集成型内の `&str` も一時値の期間を越えないよう、所有バッファへコピーします。

### [パニック](@id Panics)

境界で捕捉した場合は、ペイロードを初期化しない `panicked()`（Err / None タグ）を返します。Julia は復号前にチャネルを読み、`RustPanicError` を送出します。

非ジェネリック構造体の `Result<Self,E>` は成功値を Box 化し、`RustResult{Wrapper,E}` を返します。成功値は呼び出し世代のデストラクタと生存フラグを持ち、失敗時はラッパーを割り当てません。固有の静的メソッドはコンストラクタ（#559）、レシーバー付きとトレイト側は元の名前で独立オブジェクトを返します（#564）。元のレシーバーは有効です。

生成側はコンストラクタにマクロクレート 0.5.0 以降、その他は0.6.0以降が必要です。`<symbol>_boxed_result_v1` を呼び出し前に検査し、古い値渡しの `Self` を所有ポインタと誤読しません。更新後は `Pkg.build("RustCall")` と保存済みバインディング再生成を行います。0.9.0 の厳密検査を無効化して互換性検査を回避しないでください。

### [変換しないもの](@id What-is-not-lowered)

- `Vec`、`Box`、`HashMap` など集成型に置けないペイロードのメソッドは、従来どおり元の型と `return_kind = plain` を記録します。独立関数ではコンパイルエラーです。
- ジェネリック構造体のメソッドは必要時に単相化し、Result/Option の変換は適用しません。

### [ジェネリックオブジェクトと登録更新](@id Generic-objects-and-registration-updates)

具体化ごとの生成・破棄・メソッド・アクセサーは同じライブラリです。各オブジェクトはメンバーのスナップショットも保持し、登録更新は新しい値だけに影響します。既存値の文字列解放とパニックチャネルも元のイメージです。全メンバーをロック外で準備して一度に登録し、置換から消えたメソッドを外しても、既存値のスナップショットは残します。

厳しいトレイト境界や未束縛のメソッド型引数で使えないメンバーは、構築自体を妨げず、その値のメンバー集合から除きます。未提供・解放済みレシーバー・明示的に閉じたイメージはエラーにします。退役だけなら既存値は使えます。

## [推奨事項](@id Best-Practices)

### [1. 属性を付ける](@id 1.-Always-Use-#[derive(JuliaStruct)])

```rust
#[derive(JuliaStruct)]  // ✅ Good
pub struct MyStruct {
    // ...
}
```

### [2. コピーするなら Clone](@id 2.-Use-Clone-for-Expensive-Operations)

```rust
#[derive(JuliaStruct, Clone)]  // ✅ Good for copyable structs
pub struct Config {
    // ...
}
```

### [3. 単純なフィールド型](@id 3.-Keep-Structs-Simple)

```rust
#[derive(JuliaStruct)]
pub struct Point {
    x: f64,  // ✅ Good: simple type
    y: f64,
}
```

### [4. 複雑な操作はメソッドへ](@id 4.-Use-Methods-for-Complex-Operations)

```rust
#[derive(JuliaStruct)]
pub struct BankAccount {
    balance: f64,
}

impl BankAccount {
    pub fn new(balance: f64) -> Self {
        BankAccount { balance }
    }

    pub fn withdraw(&mut self, amount: f64) -> Result<f64, String> {
        if amount > self.balance {
            Err("Insufficient funds".to_string())
        } else {
            self.balance -= amount;
            Ok(self.balance)
        }
    }

    pub fn get_balance(&self) -> f64 {
        self.balance
    }
}
```

## [制約](@id Limitations)

### [現在の制約](@id Current-Limitations)

入れ子の構造体、複雑なジェネリクス、構造体のライフタイム引数、トレイトの関連型には制約があります。

### [回避方法](@id Workarounds)

入れ子はポインタや参照にします。

```rust
#[derive(JuliaStruct)]
pub struct Outer {
    inner: *mut Inner,  // Use pointer instead of direct nesting
}

#[derive(JuliaStruct)]
pub struct Inner {
    value: i32,
}
```

## [例](@id Examples)

### [完全な例：2次元ベクトル](@id Complete-Example:-2D-Vector)

```julia
rust"""
#[derive(JuliaStruct, Clone)]
pub struct Vec2DD {
    x: f64,
    y: f64,
}

impl Vec2DD {
    pub fn new(x: f64, y: f64) -> Self {
        Vec2DD { x, y }
    }

    pub fn zero() -> Self {
        Vec2DD { x: 0.0, y: 0.0 }
    }

    pub fn add(&self, other: &Vec2DD) -> Vec2DD {
        Vec2DD {
            x: self.x + other.x,
            y: self.y + other.y,
        }
    }

    pub fn scale(&mut self, factor: f64) {
        self.x *= factor;
        self.y *= factor;
    }

    pub fn magnitude(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }

    pub fn normalize(&mut self) {
        let mag = self.magnitude();
        if mag > 0.0 {
            self.scale(1.0 / mag);
        }
    }
}
"""

# Create vectors
v1 = Vec2DD(3.0, 4.0)
v2 = Vec2DD(1.0, 2.0)

# Access fields
println("v1: ($(v1.x), $(v1.y))")  # => v1: (3.0, 4.0)

# Modify fields
v1.x = 5.0
println("v1: ($(v1.x), $(v1.y))")  # => v1: (5.0, 4.0)

# Call methods
v3 = v1.add(v2)
println("v3: ($(v3.x), $(v3.y))")  # => v3: (6.0, 6.0)

# Static method
v_zero = Vec2DD.zero()
println("zero: ($(v_zero.x), $(v_zero.y))")  # => zero: (0.0, 0.0)

# Clone
v4 = copy(v1)
v4.scale(2.0)
println("v1 magnitude: $(v1.magnitude())")  # => v1 magnitude: 6.4031242374328485
println("v4 magnitude: $(v4.magnitude())")  # => v4 magnitude: 12.806248474865697
```

!!! note "所有する結果"
    明示的な窓口の具体化は、別のラッパーが所有する値や `Result<Owner,E>` も返せます。`return_wrapper` を指定し、注釈型・`Sized`・`'static` の証明が必要です。入力の借用は同期呼び出し内に限ります（[詳細](crate_bindings.md)）。

## [トラブルシューティング](@id Troubleshooting)

### [構造体が見つからない](@id Struct-Not-Found)

`pub`、`#[derive(JuliaStruct)]`、`rust""` 内の定義を確認します。

```rust
// ❌ Bad: missing pub
struct MyStruct { ... }

// ✅ Good
#[derive(JuliaStruct)]
pub struct MyStruct { ... }
```

### [フィールドアクセスの失敗](@id Field-Access-Errors)

属性、正確なフィールド名、対応型を確認します。

### [Clone が使えない](@id Clone-Not-Working)

`#[derive(JuliaStruct, Clone)]` を指定し、全フィールドが Rust の `Clone` を実装することを確認します。

## [関連情報](@id See-Also)

- [チュートリアル](tutorial.md)
- [使用例](examples.md)
- [API リファレンス](api.md)
- [ジェネリクス](generics.md)
