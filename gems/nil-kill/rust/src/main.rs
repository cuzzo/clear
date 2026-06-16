mod source_index;

use anyhow::{bail, Context, Result};
use std::path::PathBuf;

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.first().map(String::as_str) != Some("source-index") {
        bail!("usage: nil-kill-rust source-index --root ROOT [--target-dir DIR] [--exclude-dir DIR] FILE...");
    }
    args.remove(0);

    let mut root = None::<PathBuf>;
    let mut target_dirs = Vec::<String>::new();
    let mut exclude_dirs = Vec::<String>::new();
    let mut files = Vec::<PathBuf>::new();
    let mut usage_files = Vec::<PathBuf>::new();
    let mut idx = 0;
    while idx < args.len() {
        match args[idx].as_str() {
            "--root" => {
                idx += 1;
                let value = args.get(idx).context("--root requires a value")?;
                root = Some(PathBuf::from(value));
            }
            "--target-dir" => {
                idx += 1;
                target_dirs.push(args.get(idx).context("--target-dir requires a value")?.clone());
            }
            "--exclude-dir" => {
                idx += 1;
                exclude_dirs.push(args.get(idx).context("--exclude-dir requires a value")?.clone());
            }
            "--usage-file" => {
                idx += 1;
                usage_files.push(PathBuf::from(args.get(idx).context("--usage-file requires a value")?));
            }
            flag if flag.starts_with("--") => bail!("unknown source-index flag {flag}"),
            value => files.push(PathBuf::from(value)),
        }
        idx += 1;
    }

    let root = root.unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let bundle = source_index::run(&root, target_dirs, exclude_dirs, files, usage_files)?;
    println!("{}", serde_json::to_string(&bundle)?);
    Ok(())
}
