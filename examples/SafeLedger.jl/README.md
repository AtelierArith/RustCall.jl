# SafeLedger.jl

The runnable example of RustCall's
[safe integration pattern](../../docs/src/integration_guide.md): a Rust facade
exposes one opaque, Rust-owned object, and a small Julia API turns its errors
into Julia exceptions and gives it an explicit release path.

```
SafeLedger.jl/
├── deps/safe_ledger/     # the facade crate: #[julia] struct Ledger (no pub fields)
│   └── src/lib.rs        #   deposit / withdraw -> Result<i64, String>, balance -> Option<i64>
├── src/SafeLedger.jl     # @rust_crate ... submodule="Native", plus the Julia API
└── test/                 # construction, normal use, errors, release, unload
```

## Usage

```julia
using SafeLedger

SafeLedger.Ledger() do ledger
    SafeLedger.deposit!(ledger, "alice", 100)   # 100
    SafeLedger.withdraw!(ledger, "alice", 30)   # 70
    SafeLedger.balance(ledger, "bob")           # nothing
    SafeLedger.withdraw!(ledger, "alice", 500)  # throws SafeLedger.LedgerError
end                                             # the Rust allocation is freed here

ledger = SafeLedger.Ledger()
SafeLedger.deposit!(ledger, "alice", 1)
close(ledger)                                   # explicit release; idempotent
SafeLedger.balance(ledger, "alice")             # throws InvalidStateException
```

## Running the tests

```bash
cd deps/safe_ledger && cargo test && cd ../..        # the facade as a plain crate
julia --project=. -e 'using Pkg; Pkg.develop(path="../.."); Pkg.test()'
```

The same checks run in RustCall's own suite as `test/test_integration_example.jl`.
