//! Pre-test check gates: lightweight lint/format commands that run before the
//! test producers and stop `giga test` early on failure. A check ref is either
//! a `contrib:<category>:<lang>` reference to a bundled recommended script, or a
//! repo-relative script path. This is a gate, not a build system - it runs a
//! command and reads its exit code. See docs/agents/tuning-configs.md §14.

use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug)]
pub struct CheckOutcome {
    pub check: String,
    pub passed: bool,
}

/// Run the checks in order, fail-fast. The first failing check returns an Err so
/// the caller stops before running any tests. All-pass returns the outcomes.
/// `changed` is exported as `GIGA_CHANGED` (space-separated) so a check can scope
/// itself to just the changed files rather than the whole tree.
pub fn run(repo: &Path, checks: &[String], changed: &[String]) -> Result<Vec<CheckOutcome>> {
    let changed_env = changed.join(" ");
    let mut outcomes = Vec::new();
    for check in checks {
        let mut cmd = resolve(repo, check)?;
        cmd.env("GIGA_CHANGED", &changed_env);
        let status = cmd
            .status()
            .with_context(|| format!("check {check:?}: failed to spawn"))?;
        outcomes.push(CheckOutcome {
            check: check.clone(),
            passed: status.success(),
        });
        if !status.success() {
            bail!("check {check:?} failed (exit {})", status.code().unwrap_or(-1));
        }
    }
    Ok(outcomes)
}

/// Resolve a check ref to the command that runs it.
/// - `contrib:<a>:<b>...` -> the bundled script `<contrib_dir>/<a>/<b>....sh`
/// - anything else -> a repo-relative script, run by extension
///   (`.rb` -> ruby, `.sh` -> sh, otherwise executed directly).
fn resolve(repo: &Path, check: &str) -> Result<Command> {
    if let Some(rest) = check.strip_prefix("contrib:") {
        let rel = rest.replace(':', "/");
        let script = contrib_dir(repo)?.join(rel).with_extension("sh");
        if !script.is_file() {
            bail!("check {check:?}: no contrib script at {}", script.display());
        }
        let mut cmd = Command::new("sh");
        cmd.arg(script).current_dir(repo);
        Ok(cmd)
    } else {
        let script = repo.join(check);
        if !script.is_file() {
            bail!("check {check:?}: script not found at {}", script.display());
        }
        let mut cmd = match script.extension().and_then(|e| e.to_str()) {
            Some("rb") => {
                let mut c = Command::new("ruby");
                c.arg(&script);
                c
            }
            Some("sh") => {
                let mut c = Command::new("sh");
                c.arg(&script);
                c
            }
            _ => Command::new(&script),
        };
        cmd.current_dir(repo);
        Ok(cmd)
    }
}

/// Locate the bundled `contrib/` script directory. Search order:
/// 1. `$GIGA_CONTRIB_DIR`
/// 2. `<repo>/gems/gigasail/contrib` (dogfooding inside the CLEAR repo)
/// 3. Walking up from the executable (which may be a symlink into the source
///    tree): each ancestor's `contrib/` or `gems/gigasail/contrib/`. This finds
///    the bundled scripts when `giga` is run against an unrelated repo.
fn contrib_dir(repo: &Path) -> Result<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(dir) = std::env::var("GIGA_CONTRIB_DIR") {
        candidates.push(dir.into());
    }
    candidates.push(repo.join("gems/gigasail/contrib"));
    // current_exe() resolves the symlink on Linux, so ancestors reach into the
    // source tree (…/gems/gigasail/target/release/giga -> …/gems/gigasail).
    if let Ok(exe) = std::env::current_exe() {
        for ancestor in exe.ancestors().skip(1).take(6) {
            candidates.push(ancestor.join("contrib"));
            candidates.push(ancestor.join("gems/gigasail/contrib"));
        }
    }
    candidates
        .into_iter()
        .find(|p| p.is_dir())
        .context("no contrib/ dir found for contrib: check (set GIGA_CONTRIB_DIR)")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    fn script(dir: &Path, name: &str, body: &str) -> String {
        let path = dir.join(name);
        fs::write(&path, body).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        name.to_string()
    }

    #[test]
    fn passing_checks_run_in_order_and_failing_one_stops_early() {
        let repo = tempfile::tempdir().unwrap();
        let marker = repo.path().join("ran");
        let ok = script(
            repo.path(),
            "ok.sh",
            &format!("#!/bin/sh\necho \"$GIGA_CHANGED\" >> {}\n", marker.display()),
        );
        let bad = script(repo.path(), "bad.sh", "#!/bin/sh\nexit 3\n");
        let never = script(
            repo.path(),
            "never.sh",
            &format!("#!/bin/sh\necho never >> {}\n", marker.display()),
        );

        // All-pass: both scripts run, GIGA_CHANGED is threaded through.
        let out = run(repo.path(), &[ok.clone()], &["a.rb".into(), "b.rb".into()]).unwrap();
        assert_eq!(out.len(), 1);
        assert!(out[0].passed);
        assert_eq!(fs::read_to_string(&marker).unwrap().trim(), "a.rb b.rb");

        // Fail-fast: bad.sh fails, never.sh must not run.
        fs::remove_file(&marker).unwrap();
        let err = run(repo.path(), &[bad, never], &[]).unwrap_err();
        assert!(err.to_string().contains("failed (exit 3)"));
        assert!(!marker.exists(), "checks after the failing one must not run");
    }

    #[test]
    fn a_missing_script_is_an_error_not_a_silent_skip() {
        let repo = tempfile::tempdir().unwrap();
        let err = run(repo.path(), &["tools/nope.rb".into()], &[]).unwrap_err();
        assert!(err.to_string().contains("script not found"));
    }
}
