//! `rustcall-extract`: command-line front end over `rustcall_core`.
//!
//! ```text
//! rustcall-extract manifest   --mode <inline|crate> [--out FILE] [--cfg-file FILE] [--cfg-lenient] [--skip-unparsable] (--crate-root FILE | FILE...)
//! rustcall-extract wrap       --crate-name NAME [--out FILE] [--cfg-file FILE] [--cfg-lenient] [--skip-unparsable] (--crate-root FILE | FILE...)
//! rustcall-extract expand     [--manifest FILE] [--cfg-file FILE] [--cfg-lenient] FILE
//! rustcall-extract specialize --fn NAME --new-name NAME --bind T=TYPE... [--manifest FILE] FILE
//! rustcall-extract schema-version
//! ```
//!
//! `manifest` writes the manifest to `--out` or stdout. `expand` and `specialize`
//! write Rust source to stdout and the manifest to `--manifest` when given.
//! Errors go to stderr with exit status 1.
//!
//! File arguments are handled as `OsString`/`PathBuf` so non-UTF-8 paths work
//! on every platform; option names and values that name Rust identifiers must
//! be UTF-8.

use std::ffi::OsString;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use rustcall_core::cfg::CfgSet;
use rustcall_core::extract::ExtractError;
use rustcall_core::manifest::{Manifest, Mode, SCHEMA_VERSION};

const USAGE: &str = "usage:
  rustcall-extract manifest   --mode <inline|crate> [--out FILE] [--cfg-file FILE] [--cfg-lenient] [--skip-unparsable] (--crate-root FILE | FILE...)
  rustcall-extract wrap       --crate-name NAME [--out FILE] [--cfg-file FILE] [--cfg-lenient] [--skip-unparsable] (--crate-root FILE | FILE...)
  rustcall-extract expand     [--manifest FILE] [--cfg-file FILE] [--cfg-lenient] FILE
  rustcall-extract specialize --fn NAME --new-name NAME --bind PARAM=TYPE... [--manifest FILE] FILE
  rustcall-extract schema-version

Use '-' as FILE to read from stdin.
--cfg-file: output of `rustc --print cfg`; items disabled by #[cfg] are dropped
from the manifest and the expanded source. Without it every item is reported.
--cfg-lenient: with --cfg-file, decide only target predicates (unix, windows,
target_*); feature/profile predicates are unknown and keep their items (Cargo builds).
--skip-unparsable: files that are not a complete Rust module (e.g. include!() fragments)
are skipped with a warning instead of failing the run.
wrap: generate the `src/lib.rs` of a wrapper crate for the PyO3 items of the crate
scanned from FILE... (#275 Phase 2), and write it, together with the manifest that
describes what it exports, as one TOML document to --out or stdout. Always crate
mode; --crate-name is the dependency's package name.
--crate-root: crate-mode only. Scan the crate by following its module tree from
this file (src/lib.rs) instead of treating every FILE as a root, so each item's
module_path and the visibility of its enclosing modules are real (#275) and a
#[julia] impl block finds its struct in another file (#315). The tree is the file
list: FILE arguments are not accepted with it, and a file no `mod` reaches is not
compiled by rustc, so it exports nothing.";

/// One command-line argument: either an option/value that must be UTF-8, or a
/// path that may not be.
struct Arg(OsString);

impl Arg {
    /// The argument as a `&str` when it is valid UTF-8.
    fn as_utf8(&self) -> Option<&str> {
        self.0.to_str()
    }

    fn path(&self) -> PathBuf {
        PathBuf::from(&self.0)
    }

    fn display(&self) -> String {
        self.0.to_string_lossy().into_owned()
    }
}

fn read_source(path: &Path) -> Result<String, String> {
    if path == Path::new("-") {
        let mut s = String::new();
        io::stdin()
            .read_to_string(&mut s)
            .map_err(|e| format!("failed to read stdin: {e}"))?;
        Ok(s)
    } else {
        fs::read_to_string(path).map_err(|e| format!("failed to read {}: {e}", path.display()))
    }
}

fn read_cfg_file(path: Option<&Path>, lenient: bool) -> Result<Option<CfgSet>, String> {
    match path {
        Some(p) => {
            let text = fs::read_to_string(p)
                .map_err(|e| format!("failed to read cfg file {}: {e}", p.display()))?;
            let mut set = CfgSet::parse(&text)
                .map_err(|e| format!("invalid cfg file {}: {e}", p.display()))?;
            if lenient {
                set = set.lenient();
            }
            Ok(Some(set))
        }
        None => Ok(None),
    }
}

fn write_manifest(manifest: &Manifest, out: Option<&Path>) -> Result<(), String> {
    let text = manifest
        .to_toml()
        .map_err(|e| format!("failed to serialize manifest: {e}"))?;
    match out {
        Some(path) => {
            fs::write(path, text).map_err(|e| format!("failed to write {}: {e}", path.display()))
        }
        None => io::stdout()
            .write_all(text.as_bytes())
            .map_err(|e| format!("failed to write stdout: {e}")),
    }
}

/// The raw value following option `flag`.
fn take_raw<'a>(args: &'a [Arg], i: &mut usize, flag: &str) -> Result<&'a Arg, String> {
    *i += 1;
    args.get(*i)
        .ok_or_else(|| format!("{flag} requires a value"))
}

/// A path-valued option.
fn take_path(args: &[Arg], i: &mut usize, flag: &str) -> Result<PathBuf, String> {
    Ok(take_raw(args, i, flag)?.path())
}

/// A UTF-8 option value (mode, identifiers, bindings).
fn take_value(args: &[Arg], i: &mut usize, flag: &str) -> Result<String, String> {
    let raw = take_raw(args, i, flag)?;
    raw.as_utf8()
        .map(str::to_string)
        .ok_or_else(|| format!("{flag} value is not valid UTF-8: {}", raw.display()))
}

/// Dispatch on an argument that must be an option or a file.
enum Token<'a> {
    Option(&'a str),
    File(&'a Arg),
}

fn token(arg: &Arg) -> Token<'_> {
    match arg.as_utf8() {
        Some(s) if s.starts_with("--") => Token::Option(s),
        _ => Token::File(arg),
    }
}

/// What every scan needs, so `manifest` and `wrap` cannot drift apart: the two
/// commands must describe the same items for the same inputs.
struct ScanOptions {
    mode: Mode,
    cfg: Option<CfgSet>,
    skip_unparsable: bool,
    crate_root: Option<PathBuf>,
    files: Vec<PathBuf>,
}

/// Run the scan `opts` describes and return the merged manifest.
fn scan(opts: &ScanOptions) -> Result<Manifest, String> {
    let mut merged = Manifest::new(opts.mode);
    match (opts.mode, &opts.crate_root) {
        (Mode::Inline, _) => {
            for f in &opts.files {
                let src = read_source(f)?;
                match rustcall_core::extract::extract_with_cfg(&src, opts.mode, opts.cfg.as_ref()) {
                    Ok(m) => merged.merge(m),
                    Err(e) => skip_or_fail(e, f, opts.skip_unparsable)?,
                }
            }
        }
        (Mode::Crate, Some(root)) => {
            scan_crate_tree(root, opts.cfg.as_ref(), opts.skip_unparsable, &mut merged)?;
        }
        // No root: every FILE is its own module root. Structs and impl blocks
        // are still married across the files (#315) and exported symbols
        // checked crate-wide (#300).
        (Mode::Crate, None) => {
            let mut scan = rustcall_core::extract::TreeScan::new();
            // A listed file's own out-of-line `mod`s are not followed here:
            // without a root there is no module tree to place them in, and the
            // caller listed the files it wants scanned. What it *cannot* list
            // is what a file pulls in implicitly — an `include!` fragment, and
            // in turn whatever that fragment declares — so those are followed
            // (#343, #343 review). `follow_modules` marks a file reached that
            // way.
            let mut queue: Vec<QueuedFile> = opts
                .files
                .iter()
                .rev()
                .map(|f| QueuedFile {
                    dir: f.parent().unwrap_or(Path::new(".")).to_path_buf(),
                    file: f.clone(),
                    position: rustcall_core::extract::FilePosition::module(&[], true, &[]),
                    follow_modules: false,
                    fragment: false,
                })
                .collect();
            // Keyed by (file, module path) as the crate-root walk is: one
            // fragment `include!`d under two different modules is compiled
            // twice by rustc and belongs in the manifest twice, under each
            // module's own path (#343 review).
            let mut seen: Vec<(PathBuf, Vec<String>)> = Vec::new();
            // What the caller listed. A file it named is scanned as its own
            // root, and following a fragment into it as well would scan it
            // twice under two module paths — a `#[julia]` item would then
            // claim its symbol twice and the run would fail with a
            // duplicate-symbol error. In this mode the caller's list wins
            // (#343 review).
            let listed: Vec<PathBuf> = opts
                .files
                .iter()
                .map(|f| fs::canonicalize(f).unwrap_or_else(|_| f.clone()))
                .collect();
            while let Some(QueuedFile {
                file,
                dir,
                position,
                follow_modules,
                fragment,
            }) = queue.pop()
            {
                let canonical = fs::canonicalize(&file).unwrap_or_else(|_| file.clone());
                let key = (canonical, position.module_path.clone());
                if seen.contains(&key) {
                    continue;
                }
                seen.push(key);
                let src = read_source(&file)?;
                let scanned = scan.file(
                    &src,
                    opts.cfg.as_ref(),
                    &position,
                    &mut merged,
                    &file.display().to_string(),
                );
                let pending = match scanned {
                    Ok(v) => v,
                    Err(e) => {
                        if fragment {
                            skip_fragment_or_fail(e, &file)?;
                        } else {
                            skip_or_fail(e, &file, opts.skip_unparsable)?;
                        }
                        continue;
                    }
                };
                for next in pulled_in(&file, &dir, pending, follow_modules) {
                    let canonical =
                        fs::canonicalize(&next.file).unwrap_or_else(|_| next.file.clone());
                    if listed.contains(&canonical) {
                        continue;
                    }
                    queue.push(next);
                }
            }
            scan.finish(&mut merged).map_err(|e| e.to_string())?;
        }
    }
    if opts.files.len() > 1 || opts.crate_root.is_some() {
        merged.sort();
    }
    Ok(merged)
}

/// Only a file that is not a Rust module is skippable (an `include!()`
/// fragment); an item RustCall refuses fails the scan.
/// A fragment that does not parse is not a fragment of items — an
/// `include!("table.rs")` holding `[1, 2, 3]` is an expression — so it is left
/// to the compiler whatever `--skip-unparsable` says about the crate's own
/// files. An `ExtractError::Unsupported` is a different thing entirely: the
/// fragment *is* items, and one of them is something RustCall refuses (a
/// `#[julia]` item in an unmarked inline module, a crate-wide duplicate
/// symbol). Swallowing that would hand back a manifest missing an item the
/// proc-macro still wraps, so it fails closed exactly as it would in a file of
/// the module tree (#343 review).
fn skip_fragment_or_fail(e: ExtractError, file: &Path) -> Result<(), String> {
    match e {
        ExtractError::Parse(e) => {
            eprintln!(
                "rustcall-extract: {} is not a list of items ({e}); skipping it",
                file.display()
            );
            Ok(())
        }
        e => Err(format!("{}: {e}", file.display())),
    }
}

fn skip_or_fail(e: ExtractError, file: &Path, skip_unparsable: bool) -> Result<(), String> {
    match e {
        ExtractError::Parse(e) if skip_unparsable => {
            eprintln!(
                "rustcall-extract: skipping {}: not a complete Rust module ({e})",
                file.display()
            );
            Ok(())
        }
        e => Err(format!("{}: {e}", file.display())),
    }
}

/// Generate the wrapper crate of a PyO3 crate (#275 Phase 2).
fn cmd_wrap(args: &[Arg]) -> Result<(), String> {
    let mut crate_name: Option<String> = None;
    let mut out: Option<PathBuf> = None;
    let mut cfg_file: Option<PathBuf> = None;
    let mut cfg_lenient = false;
    let mut skip_unparsable = false;
    let mut crate_root: Option<PathBuf> = None;
    let mut files: Vec<PathBuf> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match token(&args[i]) {
            Token::Option("--skip-unparsable") => skip_unparsable = true,
            Token::Option("--crate-name") => {
                crate_name = Some(take_value(args, &mut i, "--crate-name")?)
            }
            Token::Option("--out") => out = Some(take_path(args, &mut i, "--out")?),
            Token::Option("--cfg-file") => cfg_file = Some(take_path(args, &mut i, "--cfg-file")?),
            Token::Option("--cfg-lenient") => cfg_lenient = true,
            Token::Option("--crate-root") => {
                crate_root = Some(take_path(args, &mut i, "--crate-root")?)
            }
            Token::Option("--") => {
                files.extend(args[i + 1..].iter().map(Arg::path));
                break;
            }
            Token::Option(f) => return Err(format!("unknown option `{f}`\n{USAGE}")),
            Token::File(f) => files.push(f.path()),
        }
        i += 1;
    }
    let crate_name = crate_name.ok_or("--crate-name is required")?;
    check_inputs(&files, crate_root.as_deref())?;
    let cfg = read_cfg_file(cfg_file.as_deref(), cfg_lenient)?;
    // Whether the scan decided every `#[cfg]` predicate. When it did not,
    // `wrapper_crate` refuses a `#[cfg]`-carrying item rather than generating
    // a call to something the build may not have.
    let cfg_resolved = cfg.is_some() && !cfg_lenient;
    let scanned = scan(&ScanOptions {
        mode: Mode::Crate,
        cfg,
        skip_unparsable,
        crate_root,
        files,
    })?;
    let wrapper = rustcall_core::wrap::wrapper_crate(&scanned, &crate_name, cfg_resolved);
    let text = wrapper
        .to_toml()
        .map_err(|e| format!("failed to serialize wrapper crate: {e}"))?;
    match out {
        Some(path) => {
            fs::write(&path, text).map_err(|e| format!("failed to write {}: {e}", path.display()))
        }
        None => io::stdout()
            .write_all(text.as_bytes())
            .map_err(|e| format!("failed to write stdout: {e}")),
    }
}

fn cmd_manifest(args: &[Arg]) -> Result<(), String> {
    let mut mode: Option<Mode> = None;
    let mut out: Option<PathBuf> = None;
    let mut cfg_file: Option<PathBuf> = None;
    let mut cfg_lenient = false;
    let mut skip_unparsable = false;
    let mut crate_root: Option<PathBuf> = None;
    let mut files: Vec<PathBuf> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match token(&args[i]) {
            Token::Option("--skip-unparsable") => skip_unparsable = true,
            Token::Option("--mode") => {
                let v = take_value(args, &mut i, "--mode")?;
                mode = Some(Mode::parse(&v).ok_or_else(|| format!("unknown mode `{v}`"))?);
            }
            Token::Option("--out") => out = Some(take_path(args, &mut i, "--out")?),
            Token::Option("--cfg-file") => cfg_file = Some(take_path(args, &mut i, "--cfg-file")?),
            Token::Option("--cfg-lenient") => cfg_lenient = true,
            Token::Option("--crate-root") => {
                crate_root = Some(take_path(args, &mut i, "--crate-root")?)
            }
            Token::Option("--") => {
                files.extend(args[i + 1..].iter().map(Arg::path));
                break;
            }
            Token::Option(f) => return Err(format!("unknown option `{f}`\n{USAGE}")),
            Token::File(f) => files.push(f.path()),
        }
        i += 1;
    }
    let mode = mode.ok_or("--mode is required")?;
    check_inputs(&files, crate_root.as_deref())?;
    if crate_root.is_some() && mode != Mode::Crate {
        return Err("--crate-root is only meaningful with --mode crate".into());
    }
    let cfg = read_cfg_file(cfg_file.as_deref(), cfg_lenient)?;
    let merged = scan(&ScanOptions {
        mode,
        cfg,
        skip_unparsable,
        crate_root,
        files,
    })?;
    write_manifest(&merged, out.as_deref())
}

/// One file waiting to be scanned: where it is, which directory its
/// out-of-line children resolve against, and the position its items occupy.
///
/// A file of the module tree and an `include!`d fragment differ only in these
/// two: a fragment keeps the *including* module's position (#343) and brings
/// its own directory, because rustc resolves a `mod` written inside a fragment
/// against the fragment's own directory.
struct QueuedFile {
    file: PathBuf,
    dir: PathBuf,
    position: rustcall_core::extract::FilePosition,
    /// Whether the out-of-line `mod` declarations of this file are followed.
    /// Always true when there is a crate root; without one, true only for a
    /// file reached through an `include!`, because a listed file's modules are
    /// the caller's to list and a fragment's are not (#343 review).
    follow_modules: bool,
    /// An `include!`d fragment rather than a file of the module tree. A
    /// fragment need not be a list of items at all — `include!("table.rs")`
    /// holding `[1, 2, 3]` is an expression — so one that does not parse as a
    /// file is left to the compiler instead of failing the scan, whatever
    /// `--skip-unparsable` says about the crate's own files.
    fragment: bool,
}

/// The files `pending` brings in, as queue entries.
///
/// One step for both walks, so the crate-root scan and the file-list scan
/// cannot disagree about what a file pulls in (#343). `dir` is the *module*
/// directory of `file`, which is where its out-of-line `mod`s live; an
/// `include!` is relative to the directory of the file it is written in
/// instead — `src/a.rs` is the file of module `a`, whose child modules live in
/// `src/a/`, but `include!("x.rs")` in it names `src/x.rs` — and the fragment
/// then owns its own directory for anything *it* declares.
///
/// `follow_modules` is false only for a file the caller listed in a scan with
/// no crate root: its modules are the caller's to list. Everything reached
/// from an `include!` sets it, because nothing outside the crate could have
/// named those files.
fn pulled_in(
    file: &Path,
    dir: &Path,
    pending: rustcall_core::extract::PullIns,
    follow_modules: bool,
) -> Vec<QueuedFile> {
    let mut out = Vec::new();
    if follow_modules {
        for m in pending.modules {
            let Some((child_file, child_dir)) = resolve_module_file(dir, &m) else {
                eprintln!(
                    "rustcall-extract: `mod {};` in {} names no file under {}; skipping it",
                    m.name,
                    file.display(),
                    dir.display()
                );
                continue;
            };
            out.push(QueuedFile {
                file: child_file,
                dir: child_dir,
                position: rustcall_core::extract::FilePosition::module(
                    &m.module_path,
                    m.reachable,
                    &m.cfg,
                ),
                follow_modules: true,
                fragment: false,
            });
        }
    }

    let here = file.parent().unwrap_or(Path::new(".")).to_path_buf();
    for inc in pending.includes {
        let fragment = here.join(&inc.path);
        if !fragment.is_file() {
            eprintln!(
                "rustcall-extract: `include!(\"{}\")` in {} names no file; skipping it",
                inc.path,
                file.display()
            );
            continue;
        }
        out.push(QueuedFile {
            dir: fragment.parent().unwrap_or(Path::new(".")).to_path_buf(),
            file: fragment,
            position: inc.position,
            follow_modules: true,
            fragment: true,
        });
    }
    out
}

/// Scan a whole crate by following its module tree from `root` (#275, #315).
///
/// Only this layer touches the filesystem: `rustcall_core` hands back the
/// out-of-line `mod` declarations and the `include!` fragments of each file,
/// and this resolves them. A `mod` is resolved the way rustc does —
/// `#[path = "..."]` first, then `<dir>/<name>.rs`, then `<dir>/<name>/mod.rs`
/// — and an `include!` relative to the directory of the file it was written
/// in. Anything that does not resolve (a `mod` behind a `#[cfg]` that was
/// pruned, a generated file, an `include!` of a fragment that is not a module
/// such as `include!("table.rs")` holding `[1, 2, 3]`) is noted on stderr and
/// skipped rather than failing the run: the scan describes what it can see.
fn scan_crate_tree(
    root: &Path,
    cfg: Option<&CfgSet>,
    skip_unparsable: bool,
    manifest: &mut Manifest,
) -> Result<(), String> {
    let root_dir = root.parent().unwrap_or(Path::new(".")).to_path_buf();
    let mut queue = vec![QueuedFile {
        file: root.to_path_buf(),
        dir: root_dir,
        position: rustcall_core::extract::FilePosition::module(&[], true, &[]),
        follow_modules: true,
        fragment: false,
    }];
    // Keyed by (file, module path): `#[path = "shared.rs"] pub mod a;` and the
    // same for `b` compile one file as two distinct modules, and both belong in
    // the manifest — under their own module paths, and colliding with each
    // other on the wrapper symbols. An `include!`d fragment is keyed the same
    // way, under the module that includes it.
    let mut visited: Vec<(PathBuf, Vec<String>)> = Vec::new();
    let mut scan = rustcall_core::extract::TreeScan::new();

    while let Some(QueuedFile {
        file,
        dir,
        position,
        follow_modules,
        fragment,
    }) = queue.pop()
    {
        let canonical = fs::canonicalize(&file).unwrap_or_else(|_| file.clone());
        let key = (canonical, position.module_path.clone());
        if visited.contains(&key) {
            continue;
        }
        visited.push(key);

        let src = read_source(&file)?;
        let scanned = scan.file(&src, cfg, &position, manifest, &file.display().to_string());
        let pending = match scanned {
            Ok(v) => v,
            Err(e) => {
                if fragment {
                    skip_fragment_or_fail(e, &file)?;
                } else {
                    skip_or_fail(e, &file, skip_unparsable)?;
                }
                continue;
            }
        };

        queue.extend(pulled_in(&file, &dir, pending, follow_modules));
    }
    // Structs and their impl blocks — `#[julia]` and PyO3 alike — may live in
    // different files, so the structs are only emitted once every file of the
    // tree has been seen.
    scan.finish(manifest).map_err(|e| e.to_string())
}

/// Where a `mod name;` declaration's file lives, and the directory its own
/// child modules would live in. `None` when no candidate exists.
///
/// `dir` is the declaring *file's* module directory; an inline module the
/// declaration sits in contributes a further directory component, because
/// rustc resolves `mod outer { pub mod child; }` in `src/lib.rs` to
/// `src/outer/child.rs`.
fn resolve_module_file(
    dir: &Path,
    m: &rustcall_core::pyo3::PendingModule,
) -> Option<(PathBuf, PathBuf)> {
    let mut base = dir.to_path_buf();
    for component in &m.dir_components {
        base.push(component);
    }
    if let Some(explicit) = &m.path_attr {
        let file = base.join(explicit);
        if file.is_file() {
            let child_dir = file.parent().unwrap_or(&base).to_path_buf();
            return Some((file, child_dir));
        }
        return None;
    }
    let flat = base.join(format!("{}.rs", m.name));
    if flat.is_file() {
        return Some((flat, base.join(&m.name)));
    }
    let nested = base.join(&m.name).join("mod.rs");
    if nested.is_file() {
        return Some((nested, base.join(&m.name)));
    }
    None
}

/// A scan reads either the module tree below `--crate-root` or the FILEs
/// given, never both: a file the tree does not reach is not compiled by rustc
/// and exports nothing, so listing it would describe items that do not exist.
fn check_inputs(files: &[PathBuf], crate_root: Option<&Path>) -> Result<(), String> {
    match (files.is_empty(), crate_root) {
        (true, None) => Err("at least one FILE or --crate-root is required".into()),
        (false, Some(_)) => Err(
            "--crate-root scans the crate's module tree; FILE arguments are not accepted with it"
                .into(),
        ),
        _ => Ok(()),
    }
}

fn single_file(file: &mut Option<PathBuf>, arg: &Arg, cmd: &str) -> Result<(), String> {
    if file.is_some() {
        return Err(format!("{cmd} takes exactly one FILE"));
    }
    *file = Some(arg.path());
    Ok(())
}

fn cmd_expand(args: &[Arg]) -> Result<(), String> {
    let mut manifest_out: Option<PathBuf> = None;
    let mut cfg_file: Option<PathBuf> = None;
    let mut cfg_lenient = false;
    let mut file: Option<PathBuf> = None;
    let mut i = 0;
    while i < args.len() {
        match token(&args[i]) {
            Token::Option("--manifest") => {
                manifest_out = Some(take_path(args, &mut i, "--manifest")?)
            }
            Token::Option("--cfg-file") => cfg_file = Some(take_path(args, &mut i, "--cfg-file")?),
            Token::Option("--cfg-lenient") => cfg_lenient = true,
            Token::Option(f) => return Err(format!("unknown option `{f}`\n{USAGE}")),
            Token::File(f) => single_file(&mut file, f, "expand")?,
        }
        i += 1;
    }
    let file = file.ok_or("FILE is required")?;
    let cfg = read_cfg_file(cfg_file.as_deref(), cfg_lenient)?;
    let src = read_source(&file)?;
    let expanded = rustcall_core::expand::expand_with_cfg(&src, cfg.as_ref())
        .map_err(|e| format!("{}: {e}", file.display()))?;
    if let Some(path) = manifest_out.as_deref() {
        write_manifest(&expanded.manifest, Some(path))?;
    }
    io::stdout()
        .write_all(expanded.source.as_bytes())
        .map_err(|e| format!("failed to write stdout: {e}"))
}

fn cmd_specialize(args: &[Arg]) -> Result<(), String> {
    let mut fn_name: Option<String> = None;
    let mut new_name: Option<String> = None;
    let mut bindings: Vec<(String, String)> = Vec::new();
    let mut manifest_out: Option<PathBuf> = None;
    let mut file: Option<PathBuf> = None;
    let mut i = 0;
    while i < args.len() {
        match token(&args[i]) {
            Token::Option("--fn") => fn_name = Some(take_value(args, &mut i, "--fn")?),
            Token::Option("--new-name") => new_name = Some(take_value(args, &mut i, "--new-name")?),
            Token::Option("--bind") => {
                let v = take_value(args, &mut i, "--bind")?;
                let (p, t) = v
                    .split_once('=')
                    .ok_or_else(|| format!("--bind expects PARAM=TYPE, got `{v}`"))?;
                bindings.push((p.trim().to_string(), t.trim().to_string()));
            }
            Token::Option("--manifest") => {
                manifest_out = Some(take_path(args, &mut i, "--manifest")?)
            }
            Token::Option(f) => return Err(format!("unknown option `{f}`\n{USAGE}")),
            Token::File(f) => single_file(&mut file, f, "specialize")?,
        }
        i += 1;
    }
    let fn_name = fn_name.ok_or("--fn is required")?;
    let new_name = new_name.ok_or("--new-name is required")?;
    let file = file.ok_or("FILE is required")?;
    let src = read_source(&file)?;
    let sp = rustcall_core::specialize::specialize(&src, &fn_name, &bindings, &new_name)
        .map_err(|e| format!("{}: {e}", file.display()))?;
    if let Some(path) = manifest_out.as_deref() {
        write_manifest(&sp.manifest, Some(path))?;
    }
    io::stdout()
        .write_all(sp.source.as_bytes())
        .map_err(|e| format!("failed to write stdout: {e}"))
}

fn run() -> Result<(), String> {
    let args: Vec<Arg> = std::env::args_os().skip(1).map(Arg).collect();
    let Some(cmd) = args.first() else {
        return Err(USAGE.to_string());
    };
    let rest = &args[1..];
    match cmd.as_utf8() {
        Some("manifest") => cmd_manifest(rest),
        Some("wrap") => cmd_wrap(rest),
        Some("expand") => cmd_expand(rest),
        Some("specialize") => cmd_specialize(rest),
        Some("schema-version") => {
            println!("{SCHEMA_VERSION}");
            Ok(())
        }
        Some("--help" | "-h" | "help") => {
            println!("{USAGE}");
            Ok(())
        }
        _ => Err(format!("unknown command `{}`\n{USAGE}", cmd.display())),
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("rustcall-extract: {e}");
            ExitCode::FAILURE
        }
    }
}
