# The test files that must not run in the parallel phase (#394).
#
# `test/runtests.jl` runs everything else across sixteen worker processes that
# share one Rust artifact cache. A file belongs here when it either **asserts on
# the contents of that cache** — an assertion another worker's build can falsify
# — or **empties it**, which deletes artifacts a concurrent worker has already
# written and recorded a path to.
#
# Getting this wrong is expensive: the run fails in whichever file happened to
# be `dlopen`ing at the time, so it reads as an intermittent bug in that file's
# feature rather than as a harness problem, and it points at whatever PR is
# being reviewed. Two runs minutes apart on the same tree failed in
# `test_generated_includes` and in `test_pyo3_public_routes`, neither of which
# has anything to do with the cache.
#
# `test/test_suite_isolation.jl` fails the suite when a file outside this list
# gains a `clear_cache()` call, so the list cannot silently fall behind again.
#
# Why each name is here:
#
#   test_cache                   asserts on cache contents throughout
#   test_core_api                builds and caches through the public API
#   test_cargo                   asserts one evaluation leaves exactly **one**
#                                entry in the Cargo cache directory (#287),
#                                which only holds if nothing else is writing
#   test_pyo3_wrapper            builds Cargo projects and caches them
#                                (#275 Phase 2)
#   test_rust_crate_precompile   calls `clear_cache()` to make a precompiled
#                                image stale (#394)
#   test_module_state_precompile calls `clear_cache()` in a child process, for
#                                the same reason (#394)
#
# A file that only ever touches a **private** `RUSTCALL_CACHE_DIR` of its own
# does not belong here — `test_generics_cache` is the example — because it
# cannot reach another worker's artifacts in the first place.
const SERIAL_TEST_NAMES = ("test_cache",
                           "test_core_api",
                           "test_cargo",
                           "test_pyo3_wrapper",
                           "test_rust_crate_precompile",
                           "test_module_state_precompile")
