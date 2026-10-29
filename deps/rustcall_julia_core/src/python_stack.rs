//! The bookkeeping half of the stack bounds a generated PyO3 wrapper gives
//! CPython on a Julia task (#542). This file is **not part of this crate's
//! API**: `wrap::python_attach_items` embeds its text, verbatim, in every
//! generated wrapper crate that attaches to Python, and this crate compiles it
//! only for its own tests, so the logic the wrapper runs is the logic tested
//! here. It must therefore name nothing outside `std`; the wrapper resolves
//! the CPython and Julia functions itself and hands them in.

use std::cell::RefCell;
use std::ffi::{c_int, c_void};

/// `PyUnstable_ThreadState_SetStackProtection(tstate, start, size)`.
pub type SetStackProtection = unsafe extern "C" fn(*mut c_void, *mut c_void, usize) -> c_int;
/// `PyUnstable_ThreadState_ResetStackProtection(tstate)`.
pub type ResetStackProtection = unsafe extern "C" fn(*mut c_void);

/// What CPython is told is the bottom of a task's stack is this far above
/// the bottom Julia reports (#546). Julia's task stacks start with a
/// `PROT_NONE` guard of `jl_guard_size` (32 KiB, not exported), and CPython
/// puts its hard and soft limits one and two 16 KiB margins above the bottom
/// it is given, so the reported bottom would put both limits in or on the
/// guard: deep C recursion would fault before `RecursionError` could be
/// raised. Twice the guard leaves room for CPython's margins above it. A
/// stack without a Julia guard (a thread's root task, copy-stacks mode) only
/// gives up this much of its depth.
pub const GUARD_SKIP: usize = 64 * 1024;

/// The smallest range CPython accepts (`_PyOS_MIN_STACK_SIZE`, three 16 KiB
/// margins on 64-bit); asking for less raises in CPython and is not tried.
pub const MIN_SIZE: usize = 3 * 16 * 1024;

/// The `(start, size)` to give CPython for a stack Julia reports as
/// `[total_start, total_end)`, when `here` — an address in the caller's frame
/// — lies on it; `None` otherwise (an unstarted task, a foreign stack, a range
/// too small once the guard is skipped).
pub fn fit(total_start: usize, total_end: usize, here: usize) -> Option<(usize, usize)> {
    if total_start == 0 || total_end <= total_start || here <= total_start || here > total_end {
        return None;
    }
    let start = total_start.checked_add(GUARD_SKIP)?;
    if here <= start || total_end <= start || total_end - start < MIN_SIZE {
        return None;
    }
    Some((start, total_end - start))
}

struct Entry {
    id: u64,
    tstate: *mut c_void,
    start: usize,
    size: usize,
}

thread_local! {
    // The bounds this thread's live wrapper calls have set, oldest first.
    static ACTIVE: RefCell<(u64, Vec<Entry>)> = const { RefCell::new((0, Vec::new())) };
}

/// Puts back what the thread had before the call it belongs to (#547): the
/// bounds of the newest call still running on the same thread state, or the
/// thread's own when there is none. CPython has no getter for the current
/// setting, and `ResetStackProtection` restores the thread's defaults, not the
/// previous setting, so the record is kept here.
pub struct Restore {
    id: u64,
    tstate: *mut c_void,
    set: SetStackProtection,
    reset: ResetStackProtection,
}

/// Sets `(start, size)` on `tstate` and records it. `None` when CPython
/// refuses it — the caller then clears the Python error it raised.
///
/// # Safety
/// `tstate` is the calling thread's attached thread state, and `set` /
/// `reset` are CPython's functions (or functions of the same contract).
pub unsafe fn enter(
    tstate: *mut c_void,
    start: usize,
    size: usize,
    set: SetStackProtection,
    reset: ResetStackProtection,
) -> Option<Restore> {
    if unsafe { set(tstate, start as *mut c_void, size) } != 0 {
        return None;
    }
    let id = ACTIVE.with(|active| {
        let mut active = active.borrow_mut();
        active.0 += 1;
        let id = active.0;
        active.1.push(Entry {
            id,
            tstate,
            start,
            size,
        });
        id
    });
    Some(Restore {
        id,
        tstate,
        set,
        reset,
    })
}

impl Drop for Restore {
    fn drop(&mut self) {
        // Calls on one thread usually end newest first, but a task that
        // yields while attached can let another task's call end out of order,
        // so the entry is found by its id rather than popped.
        let previous = ACTIVE
            .try_with(|active| {
                let mut active = active.borrow_mut();
                active.1.retain(|e| e.id != self.id);
                active
                    .1
                    .iter()
                    .rev()
                    .find(|e| e.tstate == self.tstate)
                    .map(|e| (e.start, e.size))
            })
            .ok()
            .flatten();
        unsafe {
            match previous {
                // The size was accepted when that call set it.
                Some((start, size)) => {
                    let _ = (self.set)(self.tstate, start as *mut c_void, size);
                }
                None => (self.reset)(self.tstate),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    thread_local! {
        static LOG: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
    }

    unsafe extern "C" fn set(tstate: *mut c_void, start: *mut c_void, size: usize) -> c_int {
        LOG.with(|l| {
            l.borrow_mut().push(format!(
                "set {} {:#x} {size}",
                tstate as usize, start as usize
            ))
        });
        if size < MIN_SIZE {
            -1
        } else {
            0
        }
    }

    unsafe extern "C" fn reset(tstate: *mut c_void) {
        LOG.with(|l| l.borrow_mut().push(format!("reset {}", tstate as usize)));
    }

    fn take_log() -> Vec<String> {
        LOG.with(|l| std::mem::take(&mut *l.borrow_mut()))
    }

    const MIB: usize = 1024 * 1024;

    #[test]
    fn the_range_starts_above_julias_guard() {
        // Julia: an 8 MiB task stack whose first 32 KiB are PROT_NONE.
        let (lo, hi) = (0x1000_0000, 0x1000_0000 + 8 * MIB);
        let (start, size) = fit(lo, hi, hi - 4096).unwrap();
        let guard_top = lo + 32 * 1024;
        let margin = 16 * 1024;
        // CPython's hard limit is `start + margin`, its soft limit
        // `start + 2 * margin`: both strictly above the guard.
        assert!(start + margin > guard_top);
        assert!(start + 2 * margin > guard_top);
        assert_eq!(start + size, hi);
        assert_eq!(start, lo + GUARD_SKIP);
    }

    #[test]
    fn no_range_off_the_stack_or_too_small() {
        let (lo, hi) = (0x1000_0000, 0x1000_0000 + 8 * MIB);
        assert_eq!(fit(0, 0, 5), None);
        assert_eq!(fit(lo, hi, lo - 1), None);
        assert_eq!(fit(lo, hi, hi + 1), None);
        // Inside the skipped bottom: not a frame CPython could protect.
        assert_eq!(fit(lo, hi, lo + 100), None);
        // Too small once the guard is skipped.
        assert_eq!(
            fit(lo, lo + GUARD_SKIP + MIN_SIZE - 1, lo + GUARD_SKIP + 8),
            None
        );
        assert!(fit(lo, lo + GUARD_SKIP + MIN_SIZE, lo + GUARD_SKIP + 8).is_some());
    }

    #[test]
    fn a_nested_call_gives_the_outer_call_its_bounds_back() {
        let t = 7 as *mut c_void;
        let outer = unsafe { enter(t, 0x100000, MIB, set, reset) }.unwrap();
        let inner = unsafe { enter(t, 0x900000, MIB, set, reset) }.unwrap();
        drop(inner);
        assert_eq!(
            take_log(),
            [
                "set 7 0x100000 1048576",
                "set 7 0x900000 1048576",
                "set 7 0x100000 1048576"
            ]
        );
        drop(outer);
        assert_eq!(take_log(), ["reset 7"]);
    }

    #[test]
    fn calls_that_end_out_of_order_leave_the_newest_live_one() {
        let t = 7 as *mut c_void;
        let a = unsafe { enter(t, 0x100000, MIB, set, reset) }.unwrap();
        let b = unsafe { enter(t, 0x900000, MIB, set, reset) }.unwrap();
        take_log();
        // `a` ends first (its task yielded while attached): `b` still runs.
        drop(a);
        assert_eq!(take_log(), ["set 7 0x900000 1048576"]);
        drop(b);
        assert_eq!(take_log(), ["reset 7"]);
    }

    #[test]
    fn another_thread_state_is_left_alone() {
        let (t, u) = (7 as *mut c_void, 8 as *mut c_void);
        let a = unsafe { enter(t, 0x100000, MIB, set, reset) }.unwrap();
        let b = unsafe { enter(u, 0x900000, MIB, set, reset) }.unwrap();
        take_log();
        drop(b);
        assert_eq!(take_log(), ["reset 8"]);
        drop(a);
        assert_eq!(take_log(), ["reset 7"]);
    }

    #[test]
    fn a_refused_range_is_not_recorded() {
        let t = 7 as *mut c_void;
        assert!(unsafe { enter(t, 0x100000, 16, set, reset) }.is_none());
        let a = unsafe { enter(t, 0x900000, MIB, set, reset) }.unwrap();
        take_log();
        drop(a);
        assert_eq!(take_log(), ["reset 7"]);
    }
}
