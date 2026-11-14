<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../en/examples.md. -->
# [使用例](@id Examples)

Rust 側と Julia 側を一緒に示した、単独で動く小さな例です。明記した例外を除き、ビルド時に実行して実際の出力を掲載します。

通常の Rust 型を使える `#[julia]` を中心に説明します。初めてなら[チュートリアル](tutorial.md)、構文は [Julia 利用者のための Rust 入門](rust_primer.md)を参照してください。

```@setup cookbook
using RustCall
```

## [数値カーネル](@id Numerical-kernels)

### [ループ](@id A-loop)

```@example cookbook
rust"""
#[julia]
fn power(x: f64, n: u32) -> f64 {
    let mut result = 1.0;
    for _ in 0..n {
        result *= x;
    }
    result
}
"""

power(2.0, 10)
```

`for _ in 0..n` は `n` 回の反復です。`_` は「変数を使わない」ことを表します。

### [フィボナッチ数](@id Fibonacci)

```@example cookbook
rust"""
#[julia]
fn fibonacci(n: u32) -> u64 {
    if n <= 1 {
        return n as u64;
    }

    let (mut a, mut b) = (0u64, 1u64);
    for _ in 2..=n {
        (a, b) = (b, a + b);
    }
    b
}
"""

Int.(fibonacci.(0:10))
```

`0u64` は型付きリテラル、`n as u64` は明示的変換です。Rust は数値型を暗黙変換しません。生成された Julia 関数にも通常のブロードキャストを使えます。

### [配列の統計量](@id Statistics-over-an-array)

`&[f64]` は Julia 配列をコピーせず借用します。複数の結果には `#[julia]` 構造体を返し、フィールドを読みます。

```@example cookbook
rust"""
#[julia]
pub struct Summary {
    pub mean: f64,
    pub variance: f64,
    pub min: f64,
    pub max: f64,
}

impl Summary {
    pub fn new(xs: &[f64]) -> Self {
        let n = xs.len() as f64;
        let mean = xs.iter().sum::<f64>() / n;
        let variance = xs.iter().map(|x| (x - mean) * (x - mean)).sum::<f64>() / n;
        let min = xs.iter().copied().fold(f64::INFINITY, f64::min);
        let max = xs.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        Self { mean, variance, min, max }
    }
}
"""

s = Summary([1.0, 2.0, 3.0, 4.0, 5.0])
(mean = s.mean, std = sqrt(s.variance), min = s.min, max = s.max)
```

`xs.iter()` は反復子、`.map(|x| …)` はクロージャの適用、`.sum::<f64>()` はここで必要な結果型の明示です。`.fold(init, f)` は Julia の `foldl(f, xs; init)` に相当します。

## [文字列](@id Strings)

借用する `&str` と所有する `String` は、Julia 側ではいずれも `String` です。

### [検索](@id Searching)

```@example cookbook
rust"""
#[julia]
fn find_substring(haystack: &str, needle: &str) -> Option<usize> {
    haystack.find(needle)
}

#[julia]
fn count_words(text: &str) -> usize {
    text.split_whitespace().count()
}
"""

found   = find_substring("hello world", "world")
missing = find_substring("hello world", "xyz")
RustCall.unwrap(found), RustCall.is_none(missing), count_words("The quick brown fox")
```

`str::find` は `Some(position)` / `None` の `Option` を返します。Julia の `findfirst` は範囲か `nothing` です。Rust の位置は**0始まりのバイトオフセット**なので、例の `6` は Julia の添字 `7` です。

### [新しい文字列を返す](@id Returning-a-new-string)

```@example cookbook
rust"""
#[julia]
fn reverse_chars(s: &str) -> String {
    s.chars().rev().collect()
}

#[julia]
fn shout(s: &str) -> String {
    format!("{}!", s.to_uppercase())
}
"""

reverse_chars("こんにちは"), shout("hello")
```

`.chars()` はバイトではなく Unicode 文字を反復するため、非 ASCII 文字も扱えます。`.collect()` は宣言した戻り値型（ここでは `String`）に集めます。

### [入力検証](@id Validating-input)

```@example cookbook
rust"""
#[julia]
fn is_ipv4(text: &str) -> bool {
    let parts: Vec<&str> = text.split('.').collect();
    parts.len() == 4 && parts.iter().all(|part| part.parse::<u8>().is_ok())
}
"""

is_ipv4("192.168.1.1"), is_ipv4("999.1.1.1"), is_ipv4("1.2.3")
```

`part.parse::<u8>()` は8ビット符号なし整数への変換を試みて `Result` を返します。0～255の数値かどうかを1式で調べられます。`Vec<&str>` は可変長配列です。関数内部では自由に使えますが、境界の引数・戻り値にはできません。

## [配列](@id Arrays)

### [読み取り](@id Reading)

```@example cookbook
rust"""
#[julia]
fn sum_wide(xs: &[i32]) -> i64 {
    xs.iter().map(|&x| x as i64).sum()
}

#[julia]
fn max_element(xs: &[i32]) -> Option<i32> {
    xs.iter().copied().max()
}
"""

arr = Int32[1, 5, 3, 9, 2]
sum_wide(arr), RustCall.unwrap(max_element(arr)), RustCall.is_none(max_element(Int32[]))
```

空スライスの最大値は存在しないため `max()` は `Option` を返します。`i64` で合計して `i32` のオーバーフローを避けます。

### [その場で変更](@id Modifying-in-place)

`&mut [T]` は Julia 配列への書き込み可能なビューです。

```@example cookbook
rust"""
#[julia]
fn sort_in_place(xs: &mut [i32]) {
    xs.sort();
}

#[julia]
fn normalize(xs: &mut [f64]) -> Result<(), String> {
    let norm = xs.iter().map(|x| x * x).sum::<f64>().sqrt();
    if norm == 0.0 {
        return Err("cannot normalize a zero vector".to_string());
    }
    for x in xs.iter_mut() {
        *x /= norm;
    }
    Ok(())
}
"""

a = Int32[5, 2, 8, 1, 9]
sort_in_place(a)

v = [3.0, 4.0]
normalize(v)
a, v
```

`Result<(), String>` は「返す値はないが失敗し得る」を表します。この例の失敗時は配列を変更せず、Julia にメッセージを返します。

```@example cookbook
RustCall.result_to_exception(normalize([3.0, 4.0]))   # Ok: returns nothing
r = normalize(zeros(3))
RustCall.is_err(r), r.value
```

要素型は完全一致が必要です（`&[i32]` なら `Vector{Int32}`）。ビュー・行列・別名参照は[配列のスライス渡し](tutorial_new_features.md#Julia-arrays-as-Rust-slices)を参照してください。

## [バイト列](@id Bytes)

### [ハッシュ関数](@id A-hash-function)

```@example cookbook
rust"""
#[julia]
fn fnv1a(data: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in data {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}
"""

function fnv1a_julia(data::Vector{UInt8})
    hash = 0xcbf29ce484222325
    for byte in data
        hash = (hash ⊻ byte) * 0x100000001b3
    end
    return hash
end

data = Vector{UInt8}("hello world")
fnv1a(data) == fnv1a_julia(data)
```

Julia の整数演算はオーバーフロー時に折り返します。Rust では明示的に `wrapping_mul` を使います。通常の `*` のオーバーフローはバグとして扱います。

### [呼び出し側が所有するバッファへ書き込む](@id Writing-into-a-buffer-the-caller-owns)

新しく割り当てた `Vec<u8>` を直接返す代わりに、Julia が出力領域を用意し、Rust が書き込んだ長さを返します。ランレングス符号化の例です。

```@example cookbook
rust"""
#[julia]
fn rle_encode(input: &[u8], output: &mut [u8]) -> Result<usize, String> {
    let mut written = 0;
    let mut i = 0;
    while i < input.len() {
        let byte = input[i];
        let mut run = 1;
        while i + run < input.len() && input[i + run] == byte && run < 255 {
            run += 1;
        }
        if written + 2 > output.len() {
            return Err(format!("output buffer too small ({} bytes)", output.len()));
        }
        output[written] = run as u8;
        output[written + 1] = byte;
        written += 2;
        i += run;
    }
    Ok(written)
}
"""

function rle(data::Vector{UInt8})
    output = zeros(UInt8, 2 * length(data))        # worst case
    n = RustCall.result_to_exception(rle_encode(data, output))
    return resize!(output, n)
end

rle(Vector{UInt8}("aaabbbbcd"))
```

Rust の `input[i]` も範囲を検査します。範囲外ならパニックとなり、RustCall が `RustCall.RustPanicError` に変換します。

## [状態を保持するオブジェクト](@id Objects-that-keep-state)

増大するデータを Rust が所有する場合は、`#[julia]` 構造体内に置きます。Julia はハンドルだけを持ち、`Vec` 自体は境界を通しません。

```@example cookbook
rust"""
#[julia]
pub struct Recorder {
    samples: Vec<f64>,
}

impl Recorder {
    pub fn new() -> Self {
        Self { samples: Vec::new() }
    }

    pub fn record(&mut self, value: f64) {
        self.samples.push(value);
    }

    pub fn record_all(&mut self, values: &[f64]) {
        self.samples.extend_from_slice(values);
    }

    pub fn count(&self) -> usize {
        self.samples.len()
    }

    pub fn average(&self) -> Option<f64> {
        if self.samples.is_empty() {
            None
        } else {
            Some(self.samples.iter().sum::<f64>() / self.samples.len() as f64)
        }
    }

    pub fn copy_into(&self, out: &mut [f64]) -> Result<(), String> {
        if out.len() != self.samples.len() {
            return Err(format!("need a buffer of length {}", self.samples.len()));
        }
        out.copy_from_slice(&self.samples);
        Ok(())
    }
}
"""

rec = Recorder()
record(rec, 1.5)
record_all(rec, [2.5, 3.5, 4.5])

out = zeros(Int(count(rec)))
copy_into(rec, out)
Int(count(rec)), RustCall.unwrap(average(rec)), out
```

`&mut self` は変更用、`&self` は読み取り用です。Julia の GC により Rust の値も破棄します。`count` は現在のモジュールの新しい関数で、`Base.count` ではありません（[メソッド名の注意](tutorial.md#Objects)）。

## [構造化したエラー](@id Errors-with-structure)

`Result<T, String>` はメッセージを返せます。エラー時に早期 return する `?` で、解析や検証を自然に書けます。

```@example cookbook
rust"""
#[julia]
fn parse_endpoint(text: &str) -> Result<u16, String> {
    let (host, port) = text
        .split_once(':')
        .ok_or_else(|| format!("`{}` has no `:port`", text))?;
    if host.is_empty() {
        return Err("empty host".to_string());
    }
    let port: u16 = port
        .parse()
        .map_err(|e| format!("bad port `{}`: {}", port, e))?;
    Ok(port)
}
"""

results = parse_endpoint.(["localhost:8080", "localhost", "localhost:http", ":80"])
[RustCall.is_ok(r) ? Int(RustCall.unwrap(r)) : r.value for r in results]
```

## [画像処理](@id Image-processing)

画像を平坦なバイトバッファにすると、Julia が画像型と表示を担当し、Rust が画素単位のループを担当できます。表示には Images.jl を使います。

ローカルで実行するには、まず `Images` をインストールします。

```julia
using Pkg
Pkg.add("Images")
```


```@example imageprocessing
using RustCall
using Images

# Rust converts the buffer in place. `&mut [u8]` is the Julia vector's own memory.
rust"""
#[julia]
fn grayscale_image(pixels: &mut [u8]) {
    // Interleaved RGB: three bytes per pixel.
    for rgb in pixels.chunks_exact_mut(3) {
        let r = rgb[0] as f32;
        let g = rgb[1] as f32;
        let b = rgb[2] as f32;

        // Standard luminance formula (ITU-R BT.601)
        let gray = (0.299 * r + 0.587 * g + 0.114 * b) as u8;

        rgb[0] = gray;
        rgb[1] = gray;
        rgb[2] = gray;
    }
}
"""

# Create a sample RGB image (gradient with colors)
function create_sample_image(width, height)
    img = zeros(RGB{N0f8}, height, width)
    for y in 1:height, x in 1:width
        r = (x - 1) / (width - 1)    # Red increases left to right
        g = (y - 1) / (height - 1)   # Green increases top to bottom
        b = 0.5                       # Constant blue
        img[y, x] = RGB{N0f8}(r, g, b)
    end
    return img
end

# Convert Julia image to raw RGB bytes (row-major, interleaved RGB)
function image_to_bytes(img)
    h, w = size(img)
    pixels = Vector{UInt8}(undef, h * w * 3)
    idx = 1
    for y in 1:h, x in 1:w
        pixel = img[y, x]
        pixels[idx] = reinterpret(UInt8, red(pixel))
        pixels[idx + 1] = reinterpret(UInt8, green(pixel))
        pixels[idx + 2] = reinterpret(UInt8, blue(pixel))
        idx += 3
    end
    return pixels
end

# Convert raw RGB bytes back to Julia image
function bytes_to_image(pixels, width, height)
    img = zeros(RGB{N0f8}, height, width)
    idx = 1
    for y in 1:height, x in 1:width
        r = reinterpret(N0f8, pixels[idx])
        g = reinterpret(N0f8, pixels[idx + 1])
        b = reinterpret(N0f8, pixels[idx + 2])
        img[y, x] = RGB{N0f8}(r, g, b)
        idx += 3
    end
    return img
end

# Create sample image
width, height = 256, 256
original_img = create_sample_image(width, height)
nothing # hide
```

**元の画像（カラーグラデーション）：**

```@example imageprocessing
original_img
```

Rust でグレースケールに変換します。

```@example imageprocessing
# Process the image with Rust
pixels = image_to_bytes(original_img)
grayscale_image(pixels)
grayscale_img = bytes_to_image(pixels, width, height)
nothing # hide
```

**処理後のグレースケール画像：**

```@example imageprocessing
grayscale_img
```

変換結果を検証します。

```@example imageprocessing
# Check that R, G, B are equal (grayscale property)
sample_pixel = grayscale_img[128, 128]
println("Sample pixel at (128, 128):")
println("  R = $(red(sample_pixel))")
println("  G = $(green(sample_pixel))")
println("  B = $(blue(sample_pixel))")
println("  Grayscale verified: ", red(sample_pixel) == green(sample_pixel) == blue(sample_pixel))
```

**並べた比較：**

```@example imageprocessing
# Create a side-by-side comparison image
comparison = [original_img grayscale_img]
```

!!! note "この例の実行"
    `servedocs()` は docs 環境から実行してください。

```julia
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs -e 'using LiveServer; servedocs()'
```

## [crates.io のクレートを使う](@id Using-crates-from-crates.io)

*ネットワークから取得するため、このビルドでは実行しません。*

`// cargo-deps:` で宣言すると Cargo でビルドします。

```julia
rust"""
// cargo-deps: regex = "1"

use regex::Regex;

#[julia]
fn count_matches(pattern: &str, text: &str) -> Result<usize, String> {
    let re = Regex::new(pattern).map_err(|e| e.to_string())?;
    Ok(re.find_iter(text).count())
}
"""

RustCall.unwrap(count_matches(raw"\d+", "a1 b22 c333"))   # => 3
```

Cargo の構文なので feature や複数クレートも指定できます。

```rust
// cargo-deps: serde = { version = "1.0", features = ["derive"] }, serde_json = "1.0"
```

長い宣言はドキュメントコメント内のマニフェストにも書けます。

```rust
//! ```cargo
//! [dependencies]
//! rand = "0.8"
//! ndarray = "0.15"
//! ```
```

初回は取得とコンパイルに1分ほどかかる場合があります。以後は共有ライブラリをキャッシュから読みます。

## [手書きの `extern "C"` と `@rust`](@id The-same-thing-by-hand:-extern-"C"-and-@rust)

以上は `#[julia]` を使わない C ABI でも書けます。ポインタと長さを自分で渡し、Rust の `unsafe` 内でスライスを再構成します。

```@example cookbook
rust"""
#[no_mangle]
pub extern "C" fn sum_array(data: *const i32, len: usize) -> i64 {
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    slice.iter().map(|&x| x as i64).sum()
}
"""

function sum_by_hand(arr::Vector{Int32})
    GC.@preserve arr begin
        @rust sum_array(pointer(arr), UInt(length(arr)))::Int64
    end
end

sum_by_hand(Int32[1, 5, 3, 9, 2])
```

先の `sum_wide` と違い、次を自分で保証します。

- **`GC.@preserve`**：`pointer(arr)` は単なるアドレスなので、Rust が読んでいる間に Julia が配列を回収・移動しないよう保護します。
- **正確な型**：`UInt(length(arr))` と `usize` を一致させます。変換はありません。
- **パニック**：手書きの `extern "C"` 内のパニックは Julia プロセスを異常終了させます。

既存の C 形式の Rust にはこの方法を使えます。新しいコードには `#[julia]` を優先してください。

## [性能の測定](@id Measuring-performance)

*このビルドでは実行しません。*

```julia
using BenchmarkTools

rust"""
#[julia]
fn sum_of_squares(xs: &[f64]) -> f64 {
    xs.iter().map(|x| x * x).sum()
}
"""

julia_sum_of_squares(xs) = sum(x -> x * x, xs)

data = rand(10_000)
@btime julia_sum_of_squares($data)
@btime sum_of_squares($data)
```

測定時には次を考慮します。

- **Julia 自体も高速**：単純な数値ループなら型の安定した Julia と Rust は似た機械語になります。Rust は既存ライブラリの再利用、予測しやすいメモリ使用、安全性のコンパイラ検査に価値があります。
- **呼び出しの固定コスト**：`#[julia]` の境界通過は数ナノ秒程度でも、加算だけなら支配的です。配列全体を渡してループを Rust 内に置きます。
- **`@rust` の型注釈**：`@rust f(x)::T` は直接呼び出しですが、注釈なしは動的解決で大幅に遅くなります。

測定値は[性能ガイド](performance.md)を参照してください。

## [所有権型](@id Ownership-types)

*`Pkg.build("RustCall")` が作るヘルパーを必要とするため、このビルドでは実行しません。*

独立した Rust のスマートポインタやベクターも保持できます。通常は `#[julia]` 構造体で十分ですが、REPL で所有権モデルを試す際に便利です。

```julia
using RustCall

# RustBox: one owner, freed once.
box = RustCall.RustBox(Int32(42))
RustCall.is_valid(box)       # => true
RustCall.drop!(box)
RustCall.is_dropped(box)     # => true

# RustRc / RustArc: shared ownership by reference counting.
rc1 = RustCall.RustRc(Int32(100))
rc2 = RustCall.clone(rc1)    # a second owner of the same value
RustCall.drop!(rc1)
RustCall.is_valid(rc2)       # => true: the value lives until the last owner goes
RustCall.drop!(rc2)

# RustVec: a growable array whose memory Rust manages.
vec = RustCall.create_rust_vec(Int32[1, 2, 3])
vec[1] = 42
collect(vec)                 # => Int32[42, 2, 3]
RustCall.drop!(vec)
```

`RustArc` はスレッドセーフな `RustRc` です。全 API は[型・メモリ・所有権](reference/ownership.md)を参照してください。

## [確認事項](@id Checklist)

- 検査・変換を受けられる `#[julia]` と `&str`、`String`、`&[T]`、`&mut [T]`、`Result`、`Option` を優先します。
- 配列全体を渡し、要素ごとの境界通過を避けます。
- 想定される失敗は `Result`、バグはパニックにします。
- 複数の結果は構造体、大きな出力は Julia が割り当てた `&mut [T]` で返します。
- 増大するデータや長寿命データは Rust 構造体に保持します。
- コンパイル失敗時は `help:` を読みます（[よくあるエラー](rust_primer.md#Common-first-errors)）。

実際のプロジェクトの構成は[安全な Rust/Julia 連携](integration_guide.md)へ進んでください。
