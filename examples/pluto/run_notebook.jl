# Run `hello.jl` headlessly with Pluto and fail when any cell errors.
#
# A Pluto notebook file is not a script: the order of the cells in the file is
# not their execution order, and a cell's result is only known once Pluto has
# evaluated the whole dependency graph. So this driver opens the notebook in a
# `Pluto.ServerSession` (no browser, no HTTP server), lets Pluto run every cell
# in its own worker process exactly as a reader would see it, and then inspects
# each cell's `errored` flag.
#
# Usage, from the repository root:
#
#     julia --project=examples/pluto -e 'using Pkg; Pkg.instantiate()'
#     julia --project=examples/pluto examples/pluto/run_notebook.jl
#
# The notebook itself does `Pkg.activate` on the repository root and then
# `using RustCall`, so it always runs against the RustCall of this checkout
# (instantiated and built beforehand, see .github/workflows/Examples.yml);
# this environment only provides Pluto.

using Pluto

const NOTEBOOK = get(ARGS, 1, joinpath(@__DIR__, "hello.jl"))

options = Pluto.Configuration.from_flat_kwargs(;
    # Never rewrite the committed notebook file (Pluto normally saves on run).
    disable_writing_notebook_files = true,
    launch_browser = false,
    # Cell `println` output is captured into the cell's log; stream it to the
    # CI log too so a failure is diagnosable from the job output alone.
    capture_stdout = false,
)
session = Pluto.ServerSession(; options)

nb = Pluto.SessionActions.open(session, NOTEBOOK; run_async = false)

failed = [c for c in nb.cells if c.errored]
for c in failed
    # An errored cell's output body is a Dict with the rendered error message
    # and a stack trace; `:plain_error` is the plain-text rendering.
    body = c.output.body
    message = body isa AbstractDict ? get(body, :plain_error, body) : body
    println(stderr, "ERROR in cell ", c.cell_id, ":\n", c.code, "\n-> ", message)
end

Pluto.SessionActions.shutdown(session, nb)

isempty(failed) || error("$(length(failed)) of $(length(nb.cells)) cell(s) errored in $(NOTEBOOK)")
println("all $(length(nb.cells)) cells of $(basename(NOTEBOOK)) ran without error")
