//! A facade in the sense of docs/src/integration_guide.md: one opaque,
//! Rust-owned object whose methods take and return only types with a
//! supported C representation (`&str`, `i64`, `usize`, `Result<_, String>`,
//! `Option<i64>`).
//!
//! `Ledger` has no `pub` field, so the Julia type RustCall generates for it is
//! a handle and nothing more: the `HashMap` inside is never mirrored in Julia,
//! and it can change without changing the Julia API.

use rustcall_julia_macros::julia;
use std::collections::HashMap;

#[julia]
pub struct Ledger {
    balances: HashMap<String, i64>,
}

#[julia]
impl Ledger {
    #[julia]
    pub fn new() -> Self {
        Ledger {
            balances: HashMap::new(),
        }
    }

    /// Adds `amount` to `account`, creating it if needed; returns the new balance.
    #[julia]
    pub fn deposit(&mut self, account: &str, amount: i64) -> Result<i64, String> {
        if amount <= 0 {
            return Err(format!("deposit must be positive, got {amount}"));
        }
        let balance = self.balances.entry(account.to_string()).or_insert(0);
        *balance = balance
            .checked_add(amount)
            .ok_or_else(|| format!("balance of {account} would overflow"))?;
        Ok(*balance)
    }

    /// Takes `amount` from `account`; returns the new balance. On error the
    /// ledger is unchanged.
    #[julia]
    pub fn withdraw(&mut self, account: &str, amount: i64) -> Result<i64, String> {
        if amount <= 0 {
            return Err(format!("withdrawal must be positive, got {amount}"));
        }
        let balance = self
            .balances
            .get_mut(account)
            .ok_or_else(|| format!("unknown account {account}"))?;
        if amount > *balance {
            return Err(format!(
                "insufficient funds in {account}: {balance} < {amount}"
            ));
        }
        *balance -= amount;
        Ok(*balance)
    }

    #[julia]
    pub fn balance(&self, account: &str) -> Option<i64> {
        self.balances.get(account).copied()
    }

    #[julia]
    pub fn account_count(&self) -> usize {
        self.balances.len()
    }
}

impl Default for Ledger {
    fn default() -> Self {
        Self::new()
    }
}

// Test the facade as an ordinary Rust crate first (`cargo test`): a failure
// here is a Rust bug, not a binding bug.
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deposit_and_withdraw() {
        let mut ledger = Ledger::new();
        assert_eq!(ledger.deposit("alice", 100), Ok(100));
        assert_eq!(ledger.withdraw("alice", 30), Ok(70));
        assert_eq!(ledger.balance("alice"), Some(70));
        assert_eq!(ledger.balance("bob"), None);
        assert_eq!(ledger.account_count(), 1);
    }

    #[test]
    fn errors_leave_the_ledger_unchanged() {
        let mut ledger = Ledger::new();
        ledger.deposit("alice", 10).unwrap();
        assert!(ledger.withdraw("alice", 11).is_err());
        assert!(ledger.withdraw("bob", 1).is_err());
        assert!(ledger.deposit("alice", 0).is_err());
        assert!(ledger.deposit("alice", i64::MAX).is_err());
        assert_eq!(ledger.balance("alice"), Some(10));
    }
}
