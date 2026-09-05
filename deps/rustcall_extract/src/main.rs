//! `rustcall-extract`: command-line front end over `rustcall_core`.
//!
//! ```text
//! rustcall-extract manifest   --mode <inline|crate> [--out FILE] [--cfg-file FILE] [--cfg-lenient] [--skip-unparsable] FILE...
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
use rustcall_core::manifest::{Manifest, Mode, SCHEMA_VERSION};

const USAGE: &str = "usage:
  rustcall-extract manifest   --mode <inline|crate> [--out FILE] [--cfg-file FILE] [--cfg-lenient] [--skip-unparsable] FILE...
  rustcall-extract expand     [--manifest FILE] [--cfg-file FILE] [--cfg-lenient] FILE
  rustcall-extract specialize --fn NAME --new-name NAME --bind PARAM=TYPE... [--manifest FILE] FILE
  rustcall-extract schema-version

Use '-' as FILE to read from stdin.
--cfg-file: output of `rustc --print cfg`; items disabled by #[cfg] are dropped
from the manifest and the expanded source. Without it every item is reported.
--cfg-lenient: with --cfg-file, decide only target predicates (unix, windows,
target_*); feature/profile predicates are unknown and keep their items (Cargo builds).
--skip-unparsable: files that are not a complete Rust module (e.g. include!() fragments)
are skipped with a warning instead of failing the run.";

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

fn cmd_manifest(args: &[Arg]) -> Result<(), String> {
    let mut mode: Option<Mode> = None;
    let mut out: Option<PathBuf> = None;
    let mut cfg_file: Option<PathBuf> = None;
    let mut cfg_lenient = false;
    let mut skip_unparsable = false;
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
    if files.is_empty() {
        return Err("at least one FILE is required".into());
    }
    let cfg = read_cfg_file(cfg_file.as_deref(), cfg_lenient)?;
    let mut merged = Manifest::new(mode);
    for f in &files {
        let src = read_source(f)?;
        match rustcall_core::extract::extract_with_cfg(&src, mode, cfg.as_ref()) {
            Ok(m) => merged.merge(m),
            Err(e) if skip_unparsable => {
                eprintln!(
                    "rustcall-extract: skipping {}: not a complete Rust module ({e})",
                    f.display()
                );
            }
            Err(e) => return Err(format!("{}: {e}", f.display())),
        }
    }
    if files.len() > 1 {
        merged.sort();
    }
    write_manifest(&merged, out.as_deref())
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
