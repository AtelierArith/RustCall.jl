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
//! those of every **local path dependency** it is built from (found through
//! the manifests, `rustcall_core` and whatever a fork adds beside it), and the
//! locked versions of the registry crates it parses and prints with — with
//! each release-coupled `[package] version` left out, and is printed by
//! `rustcall-extract source-digest`.

use std::collections::BTreeMap;
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

/// The `path = "..."` dependencies a manifest declares for a build of the
/// crate: `[dependencies]`, `[build-dependencies]` and both under every
/// `[target.'cfg(...)']`. Not `dev-dependencies`, which do not reach the
/// binary.
fn path_dependencies(manifest: &Path) -> Vec<PathBuf> {
    let Ok(text) = fs::read_to_string(manifest) else {
        return Vec::new();
    };
    let Ok(doc) = text.parse::<toml::Table>() else {
        return Vec::new();
    };
    let dir = manifest.parent().unwrap_or(Path::new("."));
    let mut scopes: Vec<&toml::Table> = vec![&doc];
    if let Some(targets) = doc.get("target").and_then(|t| t.as_table()) {
        scopes.extend(targets.values().filter_map(|t| t.as_table()));
    }
    let mut out = Vec::new();
    for scope in scopes {
        for table in ["dependencies", "build-dependencies"] {
            let Some(deps) = scope.get(table).and_then(|d| d.as_table()) else {
                continue;
            };
            for spec in deps.values() {
                if let Some(path) = spec.get("path").and_then(|p| p.as_str()) {
                    out.push(dir.join(path));
                }
            }
        }
    }
    out
}

/// Every local crate this binary is built from: the extractor itself and the
/// closure of its path dependencies, keyed by the canonical directory so a
/// crate reached twice is hashed once. A fork that adds a local helper beside
/// `rustcall_core` is therefore identified by that helper's sources too, and
/// an edit to it moves the digest (RustCall.jl #372 review).
fn local_crates(root: &Path) -> BTreeMap<PathBuf, PathBuf> {
    let mut found = BTreeMap::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        let canonical = fs::canonicalize(&dir).unwrap_or_else(|_| dir.clone());
        if found.contains_key(&canonical) {
            continue;
        }
        pending.extend(path_dependencies(&dir.join("Cargo.toml")));
        found.insert(canonical, dir);
    }
    found
}

/// `[package] name` of a manifest.
fn package_name(manifest: &Path) -> Option<String> {
    let text = fs::read_to_string(manifest).ok()?;
    let doc = text.parse::<toml::Table>().ok()?;
    doc.get("package")?.get("name")?.as_str().map(str::to_owned)
}

/// `path` relative to `base` as a forward-slash string, walking up with `..`
/// where needed: the same for the same tree wherever it is checked out.
fn pathdiff(path: &Path, base: &Path) -> String {
    let path: Vec<_> = path.components().collect();
    let base: Vec<_> = base.components().collect();
    let common = path.iter().zip(&base).take_while(|(a, b)| a == b).count();
    let mut parts: Vec<String> = vec!["..".to_owned(); base.len() - common];
    parts.extend(
        path[common..]
            .iter()
            .map(|c| c.as_os_str().to_string_lossy().into_owned()),
    );
    parts.join("/")
}

fn main() {
    let here = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    // Hashed in the order of their canonical paths *relative to the extractor*
    // — a checkout's location must not reach the digest — and named by the
    // `[package] name` their manifest declares.
    let here_canonical = fs::canonicalize(&here).unwrap_or_else(|_| here.clone());
    let mut crates: Vec<(String, PathBuf)> = local_crates(&here)
        .into_iter()
        .map(|(canonical, dir)| {
            let key = pathdiff(&canonical, &here_canonical);
            (key, dir)
        })
        .collect();
    crates.sort();
    let crates: Vec<PathBuf> = crates.into_iter().map(|(_, dir)| dir).collect();

    let mut hasher = Sha256::new();
    // The resolved dependency graph this binary is built against.
    let lock = here.join("Cargo.lock");
    println!("cargo:rerun-if-changed={}", lock.display());
    hasher.update(b"Cargo.lock\0");
    hasher.update(lockfile_without_path_versions(&lock));
    hasher.update(b"\0");
    for krate in &crates {
        let manifest = krate.join("Cargo.toml");
        let name = package_name(&manifest).unwrap_or_else(|| {
            krate
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default()
        });
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
