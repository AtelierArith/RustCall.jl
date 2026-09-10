# sample_crate (test fixture)

A test fixture of RustCall.jl: the Rust crate the suite loads with
`@rust_crate` and writes bindings for (`test/test_crate_bindings.jl`,
`test/test_hot_reload.jl`, `test/test_static_methods.jl`,
`test/test_method_result_option.jl`, `test/test_load_conformance.jl`,
`test/test_docs_examples.jl`, `test/test_regressions.jl`). It is **not** the
example to copy: the runnable example is the package
[`examples/SampleCrate.jl`](../../../examples/SampleCrate.jl/), which embeds its
own trimmed copy of this crate under `deps/sample_crate/`.

## What it carries

Everything the example crate has — `add`, `multiply`, `fibonacci`, `is_prime`,
the string functions (`shout`, `join_repeat`, `char_count`, `crate_greeting`,
`identity_str`), the `Result` / `Option` functions (`safe_divide`,
`parse_positive`, `parse_int`, `first_char`, `safe_sqrt`, `find_positive`) and
the structs `Point`, `Counter`, `Labeler`, `Rectangle` with their methods — plus
the items only the suite needs:

| Items | Exercised by |
|-------|--------------|
| `shadow_str_len`, `shadow_parse_int`, `shadow_first_char`, `shadow_double` | arguments named after the generated wrapper's locals must not be shadowed (#242 review) |
| `panicky`, `panicky_assert`, `panicky_unwrap`, `panicky_index`, `panicky_string`, `panicky_result`, `PanicCounter` | the panic boundary of every generated wrapper (#244) |
| `Divider` (`checked_div`, `ratio`, `describe`, `tag`, `bump`, `parse_scale`, `panicky_div`, `panicky_ratio`), `describe_scale` | `Result` / `Option` returns on methods, `String` payloads (#268) |
| `Labeler::shout` next to the free `fn shout` | a static method must not overwrite a free function of the same name (#323) |

## Loading it ad hoc

```julia
using RustCall

crate = joinpath(pkgdir(RustCall), "test", "fixtures", "sample_crate")
const Sample = @rust_crate crate

Sample.add(Int32(2), Int32(3))        # => 5
p = Sample.Point(3.0, 4.0)
Sample.distance_from_origin(p)        # => 5.0
p.x                                   # => 3.0
```

## Build and test the Rust alone

```bash
cd test/fixtures/sample_crate
cargo build --release
cargo test
```

## Dependencies

- `rustcall_julia_macros` (the `#[julia]` attribute), as a path dependency on
  `../../../deps/rustcall_julia_macros`.
