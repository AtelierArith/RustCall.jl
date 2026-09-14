//! Embeds a digest of the sources this executable is built from, so RustCall
//! can identify the extractor it actually runs by *behaviour* rather than by
//! the bytes of the binary or the version of the crate (RustCall.jl #372).
//!
//! A patch release bumps `[package] version`, and Cargo folds that into
//! `-C metadata`, so the same sources give a byte-different executable; the
//! binary's hash therefore moved every cache key on a release that promises
//! to keep them. And hashing the checkout's sources on the Julia side describes
//! the tree, not the executable `RUSTCALL_EXTRACT` may point at. The digest
//! below is of exactly what decides this binary's output — its own sources,
//! `rustcall_core`'s, and the locked versions of the registry crates it parses
//! and prints with — with each release-coupled `[package] version` left out,
//! and is printed by `rustcall-extract source-digest`.

use std::fs;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

fn rust_sources(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            rust_sources(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            out.push(path);
        }
    }
}

/// `Cargo.toml` without the `version = "..."` line of its `[package]` table:
/// the one line a release rewrites. Everything else — dependencies and their
/// versions, features — still counts.
fn manifest_without_package_version(path: &Path) -> Vec<u8> {
    let Ok(text) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut in_package = false;
    let mut kept = String::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_package = trimmed == "[package]";
        } else if in_package
            && trimmed.starts_with("version")
            && trimmed[7..].trim_start().starts_with('=')
        {
            continue;
        }
        kept.push_str(line);
        kept.push('\n');
    }
    kept.into_bytes()
}

/// `Cargo.lock` without the `version = "..."` line of any package that has no
/// `source` — the root and its path dependencies, whose versions a release
/// rewrites. A registry package's version pins what `syn` or `prettyplease`
/// this binary parses and prints with, and stays: updating one changes what
/// the extractor emits without touching a source file, so it must move the
/// digest.
fn lockfile_without_path_versions(path: &Path) -> Vec<u8> {
    let Ok(text) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut kept = String::new();
    let blocks: Vec<&str> = text.split("\n[[package]]").collect();
    for (i, block) in blocks.iter().enumerate() {
        if i > 0 {
            kept.push_str("\n[[package]]");
        }
        let has_source = block.lines().any(|l| l.trim_start().starts_with("source"));
        for line in block.lines() {
            let trimmed = line.trim();
            if !has_source
                && trimmed.starts_with("version")
                && trimmed[7..].trim_start().starts_with('=')
            {
                continue;
            }
            kept.push_str(line);
            kept.push('\n');
        }
    }
    kept.into_bytes()
}

fn main() {
    let here = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let crates = [here.clone(), here.join("..").join("rustcall_core")];

    let mut hasher = Sha256::new();
    // The resolved dependency graph this binary is built against.
    let lock = here.join("Cargo.lock");
    println!("cargo:rerun-if-changed={}", lock.display());
    hasher.update(b"Cargo.lock\0");
    hasher.update(lockfile_without_path_versions(&lock));
    hasher.update(b"\0");
    for krate in &crates {
        let name = krate
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let manifest = krate.join("Cargo.toml");
        println!("cargo:rerun-if-changed={}", manifest.display());
        hasher.update(name.as_bytes());
        hasher.update(b"\0Cargo.toml\0");
        hasher.update(manifest_without_package_version(&manifest));
        hasher.update(b"\0");

        let src = krate.join("src");
        println!("cargo:rerun-if-changed={}", src.display());
        let mut files = Vec::new();
        rust_sources(&src, &mut files);
        files.sort();
        for file in files {
            let rel = file.strip_prefix(krate).unwrap_or(&file);
            // Forward slashes, so the digest is the same on every platform.
            let rel = rel.to_string_lossy().replace('\\', "/");
            hasher.update(name.as_bytes());
            hasher.update(b"\0");
            hasher.update(rel.as_bytes());
            hasher.update(b"\0");
            hasher.update(fs::read(&file).unwrap_or_default());
            hasher.update(b"\0");
        }
    }
    let digest = hasher.finalize();
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    println!("cargo:rustc-env=RUSTCALL_SOURCE_DIGEST={hex}");
}
