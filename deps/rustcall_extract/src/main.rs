//! `rustcall-extract`: command-line front end over `rustcall_core`.
//!
//! ```text
//! rustcall-extract manifest   --mode <inline|crate> [--out FILE] [--skip-unparsable] FILE...
//! rustcall-extract expand     [--manifest FILE] FILE
//! rustcall-extract specialize --fn NAME --new-name NAME --bind T=TYPE... [--manifest FILE] FILE
//! rustcall-extract schema-version
//! ```
//!
//! `manifest` writes the manifest to `--out` or stdout. `expand` and `specialize`
//! write Rust source to stdout and the manifest to `--manifest` when given.
//! Errors go to stderr with exit status 1.

use std::fs;
use std::io::{self, Read, Write};
use std::process::ExitCode;

use rustcall_core::manifest::{Manifest, Mode, SCHEMA_VERSION};

const USAGE: &str = "usage:
  rustcall-extract manifest   --mode <inline|crate> [--out FILE] [--skip-unparsable] FILE...
  rustcall-extract expand     [--manifest FILE] FILE
  rustcall-extract specialize --fn NAME --new-name NAME --bind PARAM=TYPE... [--manifest FILE] FILE
  rustcall-extract schema-version

Use '-' as FILE to read from stdin.
--skip-unparsable: files that are not a complete Rust module (e.g. include!() fragments)
are skipped with a warning instead of failing the run.";

fn read_source(path: &str) -> Result<String, String> {
    if path == "-" {
        let mut s = String::new();
        io::stdin()
            .read_to_string(&mut s)
            .map_err(|e| format!("failed to read stdin: {e}"))?;
        Ok(s)
    } else {
        fs::read_to_string(path).map_err(|e| format!("failed to read {path}: {e}"))
    }
}

fn write_manifest(manifest: &Manifest, out: Option<&str>) -> Result<(), String> {
    let text = manifest
        .to_toml()
        .map_err(|e| format!("failed to serialize manifest: {e}"))?;
    match out {
        Some(path) => fs::write(path, text).map_err(|e| format!("failed to write {path}: {e}")),
        None => io::stdout()
            .write_all(text.as_bytes())
            .map_err(|e| format!("failed to write stdout: {e}")),
    }
}

fn take_value(args: &[String], i: &mut usize, flag: &str) -> Result<String, String> {
    *i += 1;
    args.get(*i)
        .cloned()
        .ok_or_else(|| format!("{flag} requires a value"))
}

fn cmd_manifest(args: &[String]) -> Result<(), String> {
    let mut mode: Option<Mode> = None;
    let mut out: Option<String> = None;
    let mut skip_unparsable = false;
    let mut files: Vec<String> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--skip-unparsable" => skip_unparsable = true,
            "--mode" => {
                let v = take_value(args, &mut i, "--mode")?;
                mode = Some(Mode::parse(&v).ok_or_else(|| format!("unknown mode `{v}`"))?);
            }
            "--out" => out = Some(take_value(args, &mut i, "--out")?),
            "--" => {
                files.extend(args[i + 1..].iter().cloned());
                break;
            }
            f if f.starts_with("--") => return Err(format!("unknown option `{f}`\n{USAGE}")),
            f => files.push(f.to_string()),
        }
        i += 1;
    }
    let mode = mode.ok_or("--mode is required")?;
    if files.is_empty() {
        return Err("at least one FILE is required".into());
    }
    let mut merged = Manifest::new(mode);
    for f in &files {
        let src = read_source(f)?;
        match rustcall_core::extract::extract(&src, mode) {
            Ok(m) => merged.merge(m),
            Err(e) if skip_unparsable => {
                eprintln!("rustcall-extract: skipping {f}: not a complete Rust module ({e})");
            }
            Err(e) => return Err(format!("{f}: {e}")),
        }
    }
    if files.len() > 1 {
        merged.sort();
    }
    write_manifest(&merged, out.as_deref())
}

fn cmd_expand(args: &[String]) -> Result<(), String> {
    let mut manifest_out: Option<String> = None;
    let mut file: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--manifest" => manifest_out = Some(take_value(args, &mut i, "--manifest")?),
            f if f.starts_with("--") => return Err(format!("unknown option `{f}`\n{USAGE}")),
            f => {
                if file.is_some() {
                    return Err("expand takes exactly one FILE".into());
                }
                file = Some(f.to_string());
            }
        }
        i += 1;
    }
    let file = file.ok_or("FILE is required")?;
    let src = read_source(&file)?;
    let expanded = rustcall_core::expand::expand(&src).map_err(|e| format!("{file}: {e}"))?;
    if let Some(path) = manifest_out.as_deref() {
        write_manifest(&expanded.manifest, Some(path))?;
    }
    io::stdout()
        .write_all(expanded.source.as_bytes())
        .map_err(|e| format!("failed to write stdout: {e}"))
}

fn cmd_specialize(args: &[String]) -> Result<(), String> {
    let mut fn_name: Option<String> = None;
    let mut new_name: Option<String> = None;
    let mut bindings: Vec<(String, String)> = Vec::new();
    let mut manifest_out: Option<String> = None;
    let mut file: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--fn" => fn_name = Some(take_value(args, &mut i, "--fn")?),
            "--new-name" => new_name = Some(take_value(args, &mut i, "--new-name")?),
            "--bind" => {
                let v = take_value(args, &mut i, "--bind")?;
                let (p, t) = v
                    .split_once('=')
                    .ok_or_else(|| format!("--bind expects PARAM=TYPE, got `{v}`"))?;
                bindings.push((p.trim().to_string(), t.trim().to_string()));
            }
            "--manifest" => manifest_out = Some(take_value(args, &mut i, "--manifest")?),
            f if f.starts_with("--") => return Err(format!("unknown option `{f}`\n{USAGE}")),
            f => {
                if file.is_some() {
                    return Err("specialize takes exactly one FILE".into());
                }
                file = Some(f.to_string());
            }
        }
        i += 1;
    }
    let fn_name = fn_name.ok_or("--fn is required")?;
    let new_name = new_name.ok_or("--new-name is required")?;
    let file = file.ok_or("FILE is required")?;
    let src = read_source(&file)?;
    let sp = rustcall_core::specialize::specialize(&src, &fn_name, &bindings, &new_name)
        .map_err(|e| format!("{file}: {e}"))?;
    if let Some(path) = manifest_out.as_deref() {
        write_manifest(&sp.manifest, Some(path))?;
    }
    io::stdout()
        .write_all(sp.source.as_bytes())
        .map_err(|e| format!("failed to write stdout: {e}"))
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(cmd) = args.first() else {
        return Err(USAGE.to_string());
    };
    let rest = &args[1..];
    match cmd.as_str() {
        "manifest" => cmd_manifest(rest),
        "expand" => cmd_expand(rest),
        "specialize" => cmd_specialize(rest),
        "schema-version" => {
            println!("{SCHEMA_VERSION}");
            Ok(())
        }
        "--help" | "-h" | "help" => {
            println!("{USAGE}");
            Ok(())
        }
        other => Err(format!("unknown command `{other}`\n{USAGE}")),
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
