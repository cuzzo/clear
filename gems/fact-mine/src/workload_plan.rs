//! Splitting a workload into shards.
//!
//! One shard per test file, so an incremental collect can rerun the tests a
//! change actually touched instead of all of them. A command that names no
//! recognizable test runner gets one opaque shard per command and no such
//! selectivity -- which is correct, not a fallback: nothing about it says which
//! part of it a source change affects.
//!
//! Fingerprinting the test files is the language's own business (Ruby digests a
//! Ripper tree so a reformat is not an edit), so this reports which files need
//! one and the caller fills them in.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Shard {
    pub id: String,
    pub test_path: String,
    pub command: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct Plan {
    pub mode: &'static str,
    pub shards: Vec<Shard>,
    /// Files whose fingerprints the caller must supply: the tests that own a
    /// shard, and the support files a change to which invalidates all of them.
    pub test_paths: Vec<String>,
    pub support_paths: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Rspec,
    Minitest,
}

/// Which runner a command names. An rspec executable is explicit; minitest is
/// recognized by the test file the command already points at.
pub fn kind_of(command: &[String]) -> Option<Kind> {
    let names_rspec = command.iter().any(|part| {
        Path::new(part).file_name().is_some_and(|name| {
            name.to_string_lossy().starts_with("rspec")
        })
    });
    if names_rspec {
        return Some(Kind::Rspec);
    }
    let joined = command.join(" ");
    (joined.contains("_test.rb") || joined.contains("Dir[") && joined.contains("test"))
        .then_some(Kind::Minitest)
}

fn shard_id(relative: &str) -> String {
    use sha2::{Digest, Sha256};
    format!("test-{:x}", Sha256::digest(relative.as_bytes()))[..21].to_string()
}

/// The command that runs exactly one file, built from the one that ran them all.
pub fn command_for(command: &[String], path: &str, kind: Kind) -> Vec<String> {
    let basename = |part: &String| {
        Path::new(part).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()
    };
    if kind == Kind::Rspec {
        if let Some(at) = command.iter().position(|part| basename(part).starts_with("rspec")) {
            return command[..=at].iter().cloned().chain([path.to_string()]).collect();
        }
    }
    // `-e` means the command inlined a loader; the file replaces the whole of it.
    if let Some(at) = command.iter().position(|part| part == "-e") {
        return command[..at].iter().cloned().chain([path.to_string()]).collect();
    }
    if let Some(at) = command.iter().position(|part| {
        let name = basename(part);
        name == "ruby"
            || (name.starts_with("ruby")
                && name[4..].chars().all(|c| c.is_ascii_digit() || c == '.'))
    }) {
        return command[..=at].iter().cloned().chain([path.to_string()]).collect();
    }
    vec!["ruby".to_string(), path.to_string()]
}

fn relative(path: &Path, root: &Path) -> String {
    path.strip_prefix(root)
        .map(|rest| rest.to_string_lossy().to_string())
        .unwrap_or_else(|_| path.to_string_lossy().to_string())
}

fn ruby_files(directory: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let Ok(entries) = std::fs::read_dir(directory) else { return found };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            found.extend(ruby_files(&path));
        } else if path.extension().is_some_and(|extension| extension == "rb") {
            found.push(path);
        }
    }
    found
}

/// The projects a set of targets belongs to: a `lib`, `src` or `app` directory
/// means the project is its parent, and anything else means the root.
fn projects(targets: &[PathBuf], root: &Path) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = Vec::new();
    for target in targets {
        let absolute = if target.is_absolute() { target.clone() } else { root.join(target) };
        let directory = if absolute.is_dir() { absolute } else {
            absolute.parent().map(Path::to_path_buf).unwrap_or_else(|| root.to_path_buf())
        };
        let named = directory.file_name().map(|n| n.to_string_lossy().to_string());
        let project = match named.as_deref() {
            Some("lib") | Some("src") | Some("app") => {
                directory.parent().map(Path::to_path_buf).unwrap_or_else(|| root.to_path_buf())
            }
            _ => root.to_path_buf(),
        };
        if !found.contains(&project) {
            found.push(project);
        }
    }
    found
}

pub fn build(targets: &[PathBuf], command: &[String], root: &Path) -> Option<Plan> {
    let kind = kind_of(command)?;
    let projects = projects(targets, root);
    let suffix = if kind == Kind::Rspec { "_spec.rb" } else { "_test.rb" };
    let directory = if kind == Kind::Rspec { "spec" } else { "test" };

    let mut entries = projects
        .iter()
        .flat_map(|project| ruby_files(&project.join(directory)))
        .filter(|path| path.to_string_lossy().ends_with(suffix))
        .collect::<Vec<_>>();
    entries.sort();
    entries.dedup();
    if entries.is_empty() {
        return None;
    }

    let mut all = projects
        .iter()
        .flat_map(|project| {
            ["test", "spec"].iter().flat_map(|name| ruby_files(&project.join(name))).collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();
    all.sort();
    all.dedup();

    let test_paths = entries.iter().map(|path| relative(path, root)).collect::<Vec<_>>();
    let support_paths = all
        .iter()
        .filter(|path| !entries.contains(path))
        .map(|path| relative(path, root))
        .collect::<Vec<_>>();
    let shards = entries
        .iter()
        .map(|path| {
            let test_path = relative(path, root);
            Shard {
                id: shard_id(&test_path),
                command: command_for(command, &path.to_string_lossy(), kind),
                test_path,
            }
        })
        .collect();
    Some(Plan { mode: "test_files", shards, test_paths, support_paths })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_shard_id_is_the_relative_path_digest() {
        // "test-" plus sixteen hex characters, which is what the manifest and
        // every stored snapshot key on.
        let id = shard_id("test/a_test.rb");
        assert_eq!(id.len(), 21);
        assert!(id.starts_with("test-"));
        assert_eq!(id, shard_id("test/a_test.rb"));
        assert_ne!(id, shard_id("test/b_test.rb"));
    }

    #[test]
    fn a_command_is_rewritten_to_run_one_file() {
        let ruby = ["bundle", "exec", "ruby", "-Ilib", "-Itest", "x_test.rb"]
            .map(str::to_string)
            .to_vec();
        assert_eq!(
            command_for(&ruby, "test/a_test.rb", Kind::Minitest),
            ["bundle", "exec", "ruby", "test/a_test.rb"].map(str::to_string).to_vec()
        );
        let rspec = ["bundle", "exec", "rspec", "spec/"].map(str::to_string).to_vec();
        assert_eq!(
            command_for(&rspec, "spec/a_spec.rb", Kind::Rspec),
            ["bundle", "exec", "rspec", "spec/a_spec.rb"].map(str::to_string).to_vec()
        );
        // `-e` inlined a loader; the file replaces the whole of it.
        let inline = ["ruby", "-Ilib", "-e", "Dir['test/**'].each"].map(str::to_string).to_vec();
        assert_eq!(
            command_for(&inline, "test/a_test.rb", Kind::Minitest),
            ["ruby", "-Ilib", "test/a_test.rb"].map(str::to_string).to_vec()
        );
    }

    #[test]
    fn a_command_naming_no_runner_has_no_plan() {
        assert_eq!(kind_of(&["make".to_string(), "check".to_string()]), None);
        assert_eq!(
            kind_of(&["bundle".to_string(), "exec".to_string(), "rspec".to_string()]),
            Some(Kind::Rspec)
        );
        assert_eq!(
            kind_of(&["ruby".to_string(), "a_test.rb".to_string()]),
            Some(Kind::Minitest)
        );
    }
}
