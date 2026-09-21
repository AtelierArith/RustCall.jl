"""
    SafeLedger

The runnable example of RustCall's safe integration pattern
(`docs/src/integration_guide.md`, #441): a Rust facade exposes one opaque,
Rust-owned object whose methods take and return only simple FFI types, and a
small Julia API on top turns Rust errors into Julia exceptions and gives the
object an explicit release path.

```julia
using SafeLedger

SafeLedger.Ledger() do ledger
    SafeLedger.deposit!(ledger, "alice", 100)   # => 100
    SafeLedger.withdraw!(ledger, "alice", 30)   # => 70
    SafeLedger.balance(ledger, "bob")           # => nothing
    SafeLedger.withdraw!(ledger, "alice", 500)  # throws LedgerError
end                                             # released here
```
"""
module SafeLedger

using RustCall

# ============================================================================
# Rust side: the facade
# ============================================================================

# `Native` is the module `@rust_crate` generates from the facade crate under
# `deps/safe_ledger`, while this package is precompiled. `Native.Ledger` is the
# opaque handle: the Rust struct has no `pub` field, so its Julia type carries
# the pointer and what its finalizer captured, nothing else. Its methods return
# `RustResult` / `RustOption`, which the public API below unwraps. Keep it
# internal.
@rust_crate joinpath(@__DIR__, "..", "deps", "safe_ledger") submodule="Native"

# ============================================================================
# Julia side: the public API
# ============================================================================

"""
    LedgerError(msg)

A Rust `Err(String)` from the ledger, raised as a Julia exception.
"""
struct LedgerError <: Exception
    msg::String
end

Base.showerror(io::IO, e::LedgerError) = print(io, "LedgerError: ", e.msg)

"""
    Ledger()
    Ledger(f)

A ledger owned by Rust. Release it with `close(ledger)` as soon as it is no
longer needed; the do-block form `Ledger() do ledger ... end` does that on the
way out, also when the body throws. A ledger that is never closed is still
freed by its finalizer when Julia collects it — `close` only makes the release
deterministic.
"""
mutable struct Ledger
    handle::Union{Native.Ledger, Nothing}
    Ledger() = new(Native.Ledger())
end

function Ledger(f::Function)
    ledger = Ledger()
    try
        return f(ledger)
    finally
        close(ledger)
    end
end

Base.isopen(ledger::Ledger) = ledger.handle !== nothing

"""
    close(ledger::Ledger)

Release the Rust allocation now. Idempotent. Every later operation on `ledger`
throws `InvalidStateException`.
"""
function Base.close(ledger::Ledger)
    handle = ledger.handle
    handle === nothing && return nothing
    ledger.handle = nothing
    # Runs the finalizer the generated type registered: it frees through the
    # destructor captured at construction and clears the pointer, so the
    # collector's later run is a no-op.
    finalize(handle)
    return nothing
end

function _handle(ledger::Ledger)
    handle = ledger.handle
    handle === nothing && throw(InvalidStateException("the ledger is closed", :closed))
    return handle
end

_ok(result::RustCall.RustResult) =
    RustCall.is_ok(result) ? RustCall.unwrap(result) : throw(LedgerError(result.value))

"""
    deposit!(ledger, account, amount) -> Int64

Add `amount` to `account`, creating it if needed; return the new balance.
Throws `LedgerError` unless `amount` is positive.
"""
deposit!(ledger::Ledger, account::AbstractString, amount::Integer) =
    _ok(Native.deposit(_handle(ledger), String(account), Int64(amount)))

"""
    withdraw!(ledger, account, amount) -> Int64

Take `amount` from `account`; return the new balance. Throws `LedgerError` for
an unknown account, a non-positive amount, or insufficient funds, in which case
the ledger is unchanged.
"""
withdraw!(ledger::Ledger, account::AbstractString, amount::Integer) =
    _ok(Native.withdraw(_handle(ledger), String(account), Int64(amount)))

"""
    balance(ledger, account) -> Union{Int64, Nothing}

The balance of `account`, or `nothing` if it has never received a deposit.
"""
function balance(ledger::Ledger, account::AbstractString)
    option = Native.balance(_handle(ledger), String(account))
    return RustCall.is_some(option) ? RustCall.unwrap(option) : nothing
end

"""
    naccounts(ledger) -> Int

The number of accounts in `ledger`.
"""
naccounts(ledger::Ledger) = Int(Native.account_count(_handle(ledger)))

"""
    library_name() -> String

The RustCall library name of the facade's image, as accepted by
`RustCall.unload_library`. Only needed by code that manages library lifetime
explicitly, such as a test harness.
"""
library_name() = Native._LIB_NAME

end # module SafeLedger
