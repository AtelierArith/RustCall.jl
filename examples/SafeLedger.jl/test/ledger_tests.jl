# Checks for the safe integration pattern of docs/src/integration_guide.md (#441):
# construction, normal use, the error path, explicit release, and what an
# object does once its library is unloaded. Every name is qualified, so the
# file runs both under `using SafeLedger` and after `include`-ing the source.

using RustCall

@testset "SafeLedger: construction" begin
    ledger = SafeLedger.Ledger()
    try
        @test isopen(ledger)
        @test SafeLedger.naccounts(ledger) == 0
        @test SafeLedger.balance(ledger, "alice") === nothing
    finally
        close(ledger)
    end
end

@testset "SafeLedger: normal use" begin
    SafeLedger.Ledger() do ledger
        @test SafeLedger.deposit!(ledger, "alice", 100) === Int64(100)
        @test SafeLedger.deposit!(ledger, "alice", 20) === Int64(120)
        @test SafeLedger.withdraw!(ledger, "alice", 30) === Int64(90)
        @test SafeLedger.deposit!(ledger, "日本", 1) === Int64(1)
        @test SafeLedger.balance(ledger, "alice") === Int64(90)
        @test SafeLedger.balance(ledger, "日本") === Int64(1)
        @test SafeLedger.naccounts(ledger) == 2
    end
end

@testset "SafeLedger: the error path" begin
    SafeLedger.Ledger() do ledger
        SafeLedger.deposit!(ledger, "alice", 10)

        # Rust's `Err(String)` reaches Julia as a typed exception with the message.
        err = try
            SafeLedger.withdraw!(ledger, "alice", 11)
            nothing
        catch e
            e
        end
        @test err isa SafeLedger.LedgerError
        @test err.msg == "insufficient funds in alice: 10 < 11"
        @test_throws SafeLedger.LedgerError SafeLedger.withdraw!(ledger, "bob", 1)
        @test_throws SafeLedger.LedgerError SafeLedger.deposit!(ledger, "alice", 0)
        @test_throws SafeLedger.LedgerError SafeLedger.deposit!(ledger, "alice", -5)

        # A failed operation leaves the Rust state unchanged.
        @test SafeLedger.balance(ledger, "alice") === Int64(10)
        @test SafeLedger.naccounts(ledger) == 1
    end
end

@testset "SafeLedger: explicit release" begin
    failures = RustCall.finalizer_failure_count()

    ledger = SafeLedger.Ledger()
    SafeLedger.deposit!(ledger, "alice", 1)
    close(ledger)
    @test !isopen(ledger)
    close(ledger)                                   # idempotent
    @test_throws InvalidStateException SafeLedger.deposit!(ledger, "alice", 1)
    @test_throws InvalidStateException SafeLedger.balance(ledger, "alice")
    @test_throws InvalidStateException SafeLedger.naccounts(ledger)

    # The do-block form releases on the way out, also when the body throws.
    kept = Ref{Any}(nothing)
    @test_throws SafeLedger.LedgerError SafeLedger.Ledger() do l
        kept[] = l
        SafeLedger.withdraw!(l, "nobody", 1)
    end
    @test !isopen(kept[])

    @test RustCall.finalizer_failure_count() == failures
end

# Last: this retires and then closes the example's library image, after which
# no new ledger can be made in this process.
@testset "SafeLedger: unloading the library" begin
    failures = RustCall.finalizer_failure_count()
    retired = SafeLedger.Ledger()
    SafeLedger.deposit!(retired, "alice", 5)
    closed = SafeLedger.Ledger()
    lib = SafeLedger.library_name()

    # Unloading retires the image: the generated module no longer calls into
    # it, so an operation raises, but the image stays mapped and an object it
    # allocated still frees through its own destructor.
    RustCall.unload_library(lib)
    @test !isempty(RustCall.retired_handles(lib))
    err = try
        SafeLedger.balance(retired, "alice")
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("is not loaded", sprint(showerror, err))
    close(retired)
    @test !isopen(retired)
    @test RustCall.finalizer_failure_count() == failures

    # Closing the retired image makes its surviving objects inert: a call
    # raises instead of jumping into unmapped code, and release is a no-op.
    RustCall.close_retired_handles!(RustCall.retired_handles(lib))
    err = try
        SafeLedger.balance(closed, "alice")
        nothing
    catch e
        e
    end
    @test err isa RustCall.RustError
    @test occursin("unloaded Ledger object", err.message)
    close(closed)
    @test !isopen(closed)
    @test RustCall.finalizer_failure_count() == failures
end
