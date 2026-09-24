# Short on-disk names for full artifact keys, and the ownership that makes them
# safe (#504).
#
# `artifact_short_id` exists for names a human reads (#278). Windows' 260-character
# path limit made some of those names *locations* as well (#486): a crate's Cargo
# target directory, the PyO3 wrapper's Cargo package (and so its output file),
# the PyO3 host extension's cache directory, a debug build's source and library.
# Two full keys that share a prefix would then share an output. This file is the
# one place a short id may name a path or a Cargo package, and every such name
# comes with ownership by the full key:
#
# * a **persistent** name — one that outlives the build, so a later lookup finds
#   it — is claimed for good by an owner record holding the full key, created
#   exclusively (`O_CREAT | O_EXCL`); a different key is refused, never shared
#   (`claim_short_name!`);
# * every use that writes and then reads back an output under the name holds an
#   exclusive file lock from build start through copy-out
#   (`with_short_name_lock`), so two builds of one name take turns rather than
#   interleave, in one process or several (`with_owned_short_name` does both).
#
# `scripts/lint_artifact_identity.sh` forbids `artifact_short_id` anywhere else
# in `src/` unless the line is marked as a label (a registry name, a Rust symbol
# inside its own library, a log line) or a lease-owned token.

"""
    SHORT_NAME_KEY_FILE

The owner record of a persistent short name that is a directory: a file inside
it holding the full key the name was derived from (`claim_short_name!`). The
spelling is the one #495 gave the crate target directory's record, so a target
directory created before #504 stays owned by the key it already records.
"""
const SHORT_NAME_KEY_FILE = ".rustcall-crate-key"

"""
    SHORT_NAME_LOCK_FILE

The lock file inside a persistent short-named directory (`with_owned_short_name`).
"""
const SHORT_NAME_LOCK_FILE = ".rustcall-lock"

"""
    short_name(key; prefix = "", n = ARTIFACT_SHORT_ID_LEN) -> String

`prefix` followed by the first `n` hex characters of the full artifact `key`:
the on-disk or Cargo-package spelling of a key where the full 64 characters do
not fit (#486). Pure — it names; `claim_short_name!` / `with_short_name_lock`
own. Every short name that is a location is spelled here (#504).
"""
short_name(key::AbstractString; prefix::AbstractString = "", n::Int = ARTIFACT_SHORT_ID_LEN) =
    string(prefix, artifact_short_id(key, n))

"""
    short_name_path(root, key; prefix = "", n = ARTIFACT_SHORT_ID_LEN) -> String

`joinpath(root, short_name(key; prefix, n))`, touching nothing. A caller that
writes there claims it first (`claim_short_name!` / `with_owned_short_name`).
"""
short_name_path(root::AbstractString, key::AbstractString; prefix::AbstractString = "",
                n::Int = ARTIFACT_SHORT_ID_LEN) =
    joinpath(String(root), short_name(key; prefix = prefix, n = n))

# Where the owner record and the lock of a persistent name live: inside it when
# the name is a directory, beside it (`<path>.rustcall-key` / `.rustcall-lock`)
# when the name is a file stem.
_short_name_record(path::AbstractString, stem::Bool) =
    stem ? String(path) * ".rustcall-key" : joinpath(String(path), SHORT_NAME_KEY_FILE)
_short_name_lock(path::AbstractString, stem::Bool) =
    stem ? String(path) * ".rustcall-lock" : joinpath(String(path), SHORT_NAME_LOCK_FILE)

"""
    claim_short_name!(path, key; stem = false, what = "artifact", wait = 10.0)

Record `key` as the owner of the persistent short name `path`, or confirm it
already is. A name another key owns is refused with a `RustError`, never
shared: its outputs are looked up again later by the name alone, so sharing it
could hand one key another key's build. `path` is a directory (created; the
record is `SHORT_NAME_KEY_FILE` inside it) or, with `stem = true`, a file stem
whose record sits beside it.

The record is created with the exclusive-create claim of `_claim_lockfile!`
(`O_CREAT | O_EXCL`), so of two claimants exactly one creates it and the other
compares the full key. A check-then-rename was not that: both could pass the
check (#495 review). The winner writes the key after creating the file, so a
loser that finds it empty or partial waits `wait` seconds for the whole key
before deciding.
"""
function claim_short_name!(path::AbstractString, key::AbstractString;
                           stem::Bool = false, what::AbstractString = "artifact",
                           wait::Real = 10.0)
    stem ? mkpath(dirname(String(path))) : mkpath(String(path))
    record = _short_name_record(path, stem)
    if _claim_lockfile!(record)
        write(record, key)
        return nothing
    end
    deadline = time() + Float64(wait)
    owner = strip(read(record, String))
    while length(owner) < length(key) && time() < deadline
        sleep(0.05)
        owner = strip(read(record, String))
    end
    owner == key && return nothing
    reason = length(owner) < length(key) ?
        "holds an incomplete owner record (a process died while claiming it)" :
        "already belongs to another key (its short id collides with that of $(what))"
    throw(RustError(
        "RustCall's short-named location `$(path)` $(reason). Remove it, or clear " *
        "RustCall's cache (`RustCall.clear_cache()` / `RustCall.clear_cargo_cache()`), " *
        "and build again."))
end

"""
    with_short_name_lock(f, lock_path; poll = 0.05)

Run `f()` holding an exclusive lock on `lock_path`, waiting while another holder
has it — another process, or another task of this one (the lock belongs to the
open file description, `_try_lock_lease`). A build that writes an output under a
short name holds it from the build until the output is copied out, so two builds
of one name take turns (#495 review, #504). The lock is released when the file
is closed, and a holder that dies releases it with the process; the file itself
is left in place, since removing it would let a waiter lock a file a newcomer no
longer opens. Where the file system has no locking at all, `f` runs unlocked.
"""
function with_short_name_lock(f::Function, lock_path::AbstractString; poll::Real = 0.05)
    mkpath(dirname(String(lock_path)))
    io = open(String(lock_path), "a")
    try
        while _try_lock_lease(io) === false
            sleep(poll)
        end
        return f()
    finally
        close(io)
    end
end

"""
    with_owned_short_name(f, path, key; stem = false, what = "artifact", wait = 10.0,
                          poll = 0.05)

`claim_short_name!(path, key)`, then `f()` under the name's lock: full-key
ownership for the lifetime of the use — a colliding key is refused, and two
uses by the owning key serialize from build start through copy-out.
"""
function with_owned_short_name(f::Function, path::AbstractString, key::AbstractString;
                               stem::Bool = false, what::AbstractString = "artifact",
                               wait::Real = 10.0, poll::Real = 0.05)
    claim_short_name!(path, key; stem = stem, what = what, wait = wait)
    return with_short_name_lock(f, _short_name_lock(path, stem); poll = poll)
end

"""
    with_short_name(f, root, key; prefix = "", n = ARTIFACT_SHORT_ID_LEN, poll = 0.05)

`f(name)` with `name = short_name(key; prefix, n)` held under the lock
`<root>/<name>.lock` for the whole call: for a short name that is **reused**
over time rather than owned for good — the PyO3 wrapper's Cargo package, whose
`<profile>/lib<name>.*` in the crate's shared target directory `root` is
rewritten by every wrapper build of that name. Two builds whose full keys share
the short id take turns from the build until the output is copied out under the
full key, so neither can copy the other's output (#495 review, #504).
"""
function with_short_name(f::Function, root::AbstractString, key::AbstractString;
                         prefix::AbstractString = "", n::Int = ARTIFACT_SHORT_ID_LEN,
                         poll::Real = 0.05)
    name = short_name(key; prefix = prefix, n = n)
    return with_short_name_lock(joinpath(String(root), name * ".lock"); poll = poll) do
        f(name)
    end
end
