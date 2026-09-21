using SafeLedger
using Test

# The same checks run in RustCall's own suite (test/test_integration_example.jl),
# which includes this package's source rather than installing it.
include("ledger_tests.jl")
