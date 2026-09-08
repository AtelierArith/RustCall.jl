//! A `#[julia] impl` block in another module than its struct (#315).
//!
//! The struct sits at the crate root; its methods come from a marked child
//! module through `super::`, from another through `crate::`, and from an
//! unmarked module through a `use`. Every method symbol follows the *struct*
//! (`rustcall_Gauge_read`), not the module the block was written in, in both
//! flavours: the crate flavour reads the header (`impl_target_module_path`),
//! the inline flavour resolves it against the whole block (`ModelTree`).
//! A second struct lives in a marked module and gets a method from a sibling
//! marked module by its full path.
//!
//! A cross-module method's wrapper is emitted **inside the impl's module**
//! (#342), so a signature may name a type only that module can see
//! (`ops::Count`); its string buffers are the wrapper's own
//! (`Gauge_label_RustCallOwnedString`), not the struct's.

#[julia]
pub struct Gauge {
    pub value: i32,
}

#[julia]
impl Gauge {
    #[julia]
    pub fn new(value: i32) -> Self {
        Self { value }
    }
}

#[julia]
pub mod ops {
    // Private to `ops`: a wrapper naming it only compiles where the block is
    // (#342).
    type Count = i32;

    #[julia]
    impl super::Gauge {
        #[julia]
        pub fn read(&self) -> Count {
            self.value
        }

        #[julia]
        pub fn bump(&mut self) {
            self.value += 1;
        }
    }
}

#[julia]
pub mod more {
    #[julia]
    impl crate::Gauge {
        #[julia]
        pub fn label(&self) -> String {
            format!("Gauge({})", self.value)
        }

        #[julia]
        pub fn scaled(value: i32, factor: i32) -> Self {
            Self { value: value * factor }
        }
    }
}

// Unmarked: the block is expanded by the item-level macro, which sees no
// module, so a bare `Gauge` brought in by `use` names the root struct.
pub mod plain {
    use super::Gauge;

    #[julia]
    impl Gauge {
        #[julia]
        pub fn halved(&self) -> Result<i32, String> {
            if self.value % 2 == 0 {
                Ok(self.value / 2)
            } else {
                Err(format!("{} is odd", self.value))
            }
        }
    }
}

#[julia]
pub mod a {
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
    }
}

#[julia]
pub mod b {
    #[julia]
    impl crate::a::C {
        #[julia]
        pub fn get(&self) -> i32 {
            self.v
        }
    }
}
