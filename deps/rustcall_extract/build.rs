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
//! the `[package] version` of this tree's own release crates, and only those,
//! left out — and is printed by `rustcall-extract source-digest`.

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

/// The crates whose `[package] version` is the RustCall release version and
/// moves with it — the only manifests whose version line is left out of the
/// digest, and only when they are this tree's own `deps/<name>`. Any other
/// local crate a fork adds keeps its version: it may read
/// `env!("CARGO_PKG_VERSION")`, so a bump of that alone can change what it
/// compiles to (RustCall.jl #372 review).
const RELEASE_CRATES: [&str; 4] = [
    "rustcall_core",
    "rustcall_extract",
    "rustcall_julia_macros",
    "rustcall_julia_macros_impl",
];

/// Whether `dir` is this tree's own release crate `name`: the name is on the
/// list and the directory *is* `<deps>/<name>` beside the extractor.
fn is_release_crate(dir: &Path, name: &str, deps: &Path) -> bool {
    RELEASE_CRATES.contains(&name)
        && fs::canonicalize(dir).ok() == fs::canonicalize(deps.join(name)).ok()
}

/// `Cargo.toml` without the `version = "..."` line of its `[package]` table:
/// the one line a release rewrites. Everything else — dependencies and their
/// versions, features — still counts. Applied to release crates only; any
/// other manifest is hashed as it is.
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

/// `Cargo.lock` without the `version = "..."` line of any package that is one
/// of `release` — the release crates this build resolves by path, whose
/// versions a release rewrites — and has no `source`. Every other version
/// stays: a registry package's pins what `syn` or `prettyplease` this binary
/// parses and prints with, and a fork's local helper may read its own.
fn lockfile_without_release_versions(path: &Path, release: &[String]) -> Vec<u8> {
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
        let name = block.lines().find_map(|l| {
            let t = l.trim();
            t.strip_prefix("name = \"")
                .and_then(|rest| rest.strip_suffix('"'))
                .map(str::to_owned)
        });
        let strip = !has_source && name.is_some_and(|n| release.contains(&n));
        for line in block.lines() {
            let trimmed = line.trim();
            if strip && trimmed.starts_with("version") && trimmed[7..].trim_start().starts_with('=')
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
    let deps = here.join("..");
    let named: Vec<(String, PathBuf)> = crates
        .iter()
        .map(|krate| {
            let name = package_name(&krate.join("Cargo.toml")).unwrap_or_else(|| {
                krate
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default()
            });
            (name, krate.clone())
        })
        .collect();
    // The release crates among them, by provenance: these are the only
    // versions left out, in the manifests and in the lockfile.
    let release: Vec<String> = named
        .iter()
        .filter(|(name, dir)| is_release_crate(dir, name, &deps))
        .map(|(name, _)| name.clone())
        .collect();

    let mut hasher = Sha256::new();
    // The resolved dependency graph this binary is built against.
    let lock = here.join("Cargo.lock");
    println!("cargo:rerun-if-changed={}", lock.display());
    hasher.update(b"Cargo.lock\0");
    hasher.update(lockfile_without_release_versions(&lock, &release));
    hasher.update(b"\0");
    for (name, krate) in &named {
        let manifest = krate.join("Cargo.toml");
        println!("cargo:rerun-if-changed={}", manifest.display());
        hasher.update(name.as_bytes());
        hasher.update(b"\0Cargo.toml\0");
        if release.contains(name) {
            hasher.update(manifest_without_package_version(&manifest));
        } else {
            hasher.update(fs::read(&manifest).unwrap_or_default());
        }
        hasher.update(b"\0");

        // A build script is part of what the crate compiles to. Its own
        // inputs beyond the crate's manifest and sources cannot be known
        // here; this tree's scripts read only those.
        let build_script = krate.join("build.rs");
        println!("cargo:rerun-if-changed={}", build_script.display());
        if build_script.is_file() {
            hasher.update(name.as_bytes());
            hasher.update(b"\0build.rs\0");
            hasher.update(fs::read(&build_script).unwrap_or_default());
            hasher.update(b"\0");
        }

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
