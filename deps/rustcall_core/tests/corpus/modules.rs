//! Module-qualified symbols (#300): the same item names in two modules, a
//! nested module, and underscores in both module and item names.
//!
//! In a crate the `#[julia]` on each inline `mod` is what tells the proc-macro
//! its path; inline expansion strips the marker and walks the modules itself.

#[julia]
pub mod a {
    #[julia]
    pub fn run() -> i32 {
        1
    }

    #[julia]
    pub struct C {
        pub v: i32,
        pub label: String,
    }

    #[julia]
    impl C {
        #[julia]
        pub fn new(v: i32) -> Self {
            Self { v, label: String::new() }
        }

        #[julia]
        pub fn get(&self) -> i32 {
            self.v
        }

        #[julia]
        pub fn describe(&self) -> String {
            format!("a::C({})", self.v)
        }

        #[julia]
        pub fn checked(&self) -> Result<i32, String> {
            Ok(self.v)
        }
    }

    #[julia]
    pub mod deep_er {
        #[julia]
        pub fn run() -> i32 {
            3
        }

        #[julia]
        pub fn snake_case_fn(x_1: i32) -> i32 {
            x_1
        }
    }
}

#[julia]
pub mod b {
    #[julia]
    pub fn run() -> i32 {
        2
    }

    #[julia]
    pub struct C {
        pub v: i32,
    }

    #[julia]
    impl C {
        #[julia]
        pub fn new(v: i32) -> Self {
            Self { v }
        }

        #[julia]
        pub fn get(&self) -> i32 {
            self.v
        }
    }
}

// A crate-root item keeps its bare name; `a_0b__c` and `a__b_0c` are the
// prefix-free encodings of `a_b::c` and `a::b_c`.
#[julia]
pub fn run() -> i32 {
    0
}

#[julia]
pub mod a_b {
    #[julia]
    pub fn c() -> i32 {
        4
    }
}

#[julia]
pub mod a {
    #[julia]
    pub fn b_c() -> i32 {
        5
    }
}
