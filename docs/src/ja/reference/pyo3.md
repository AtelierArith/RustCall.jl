<!-- Translation source: 960be32b16e7387ce39c1f3ca662c2e057d3b9c5; English counterpart: ../../en/reference/pyo3.md. -->
# [PyO3 クレート](@id PyO3-crates)

PyO3 拡張の `#[pyfunction]` / `#[pymethods]` を Julia から呼ぶラッパークレート、Python ランタイムを探すリンク計画、走査時のスキップ理由、既存の Python 拡張として読み込むホスト経路を扱います。使い方は [PyO3 クレート](../pyo3.md)を参照してください。

## [PyO3 ラッパークレート（`src/pyo3/pyo3.jl`）](@id PyO3-wrapper-crates-(src/pyo3/pyo3.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "pyo3", "pyo3.jl")]
```

## [Python ホスト経路（`src/pyo3/pyo3_host.jl`）](@id The-Python-host-path-(src/pyo3/pyo3_host.jl))

```@autodocs
Modules = [RustCall]
Pages = [joinpath("src", "pyo3", "pyo3_host.jl")]
```
