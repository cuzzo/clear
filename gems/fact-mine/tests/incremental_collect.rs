//! An incremental collect, end to end, with no Ruby but the traced program.
//!
//! The property that matters is not that `--fast` is quick -- it is that the
//! evidence it leaves behind is the evidence a full collect would have left.
//! An increment that reruns too few shards is indistinguishable from a correct
//! one until something downstream reads evidence for code that no longer
//! exists, so every case here checks what was written, not just that it ran.

use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;

const BINARY: &str = env!("CARGO_BIN_EXE_fact-mine-rust");

/// The collector object the traced program loads. Built out of tree by the
/// gem's extconf, so its absence means "not built here", not "broken".
fn collector() -> Option<PathBuf> {
    let path = Path::new(BINARY)
        .ancestors()
        .nth(4)?
        .join("gems/nil-kill/ext/nil_kill_trace/nil_kill_trace.so");
    path.is_file().then_some(path)
}

fn ruby_available() -> bool {
    Command::new("ruby").arg("-e").arg("").status().is_ok_and(|status| status.success())
}

struct Project {
    root: tempfile::TempDir,
}

impl Project {
    fn new() -> Self {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path();
        std::fs::create_dir_all(path.join("lib")).expect("lib");
        std::fs::create_dir_all(path.join("test")).expect("test");
        std::fs::write(
            path.join("lib/calculator.rb"),
            "class Calculator\n  def double(value)\n    value * 2\n  end\n\n  \
             def triple(value)\n    value * 3\n  end\nend\n",
        )
        .expect("write");
        for (name, method, expected, argument) in [
            ("double", "double", 8, 4),
            ("triple", "triple", 9, 3),
        ] {
            std::fs::write(
                path.join(format!("test/{name}_test.rb")),
                format!(
                    "require \"minitest/autorun\"\nrequire_relative \"../lib/calculator\"\n\
                     class {name}Test < Minitest::Test\n  def test_{name}\n    \
                     assert_equal {expected}, Calculator.new.{method}({argument})\n  end\nend\n"
                ),
            )
            .expect("write");
        }
        Self { root }
    }

    fn path(&self) -> &Path {
        self.root.path()
    }

    fn write(&self, relative: &str, contents: &str) {
        std::fs::write(self.path().join(relative), contents).expect("write");
    }

    fn edit(&self, relative: &str, from: &str, to: &str) {
        let path = self.path().join(relative);
        let source = std::fs::read_to_string(&path).expect("read");
        assert!(source.contains(from), "{relative} does not contain {from:?}");
        std::fs::write(&path, source.replace(from, to)).expect("write");
    }

    fn collect(&self, arguments: &[&str]) -> (String, bool) {
        let root = self.path();
        let mut command = Command::new(BINARY);
        command
            .arg("nil-kill-collect")
            .arg("--root")
            .arg(root)
            .args(arguments)
            .env("NIL_KILL_ROOT", root)
            .env("NIL_KILL_TARGETS", root.join("lib"))
            .env("NIL_KILL_TMP_DIR", root.join(".nil-kill"));
        if let Some(extension) = collector() {
            command.env("NIL_KILL_COLLECTOR_EXTENSION", extension);
        }
        let output = command.output().expect("collect");
        (
            format!(
                "{}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            ),
            output.status.success(),
        )
    }

    /// A full collect over both test files, one shard each.
    fn full(&self) -> (String, bool) {
        let loader = format!(
            "Dir['{}'].sort.each {{ |file| require file }}",
            self.path().join("test/*_test.rb").display()
        );
        self.collect(&[
            "--",
            "ruby",
            "-I",
            &self.path().join("lib").to_string_lossy(),
            "-e",
            &loader,
        ])
    }

    fn fast(&self) -> (String, bool) {
        self.collect(&["--fast"])
    }

    fn read_gz(&self, relative: &str) -> Value {
        use std::io::Read;
        let bytes = std::fs::read(self.path().join(relative)).expect("read");
        let mut text = String::new();
        flate2::read::GzDecoder::new(&bytes[..]).read_to_string(&mut text).expect("gunzip");
        serde_json::from_str(&text).expect("json")
    }

    fn manifest(&self) -> Value {
        self.read_gz(".nil-kill/runtime/runtime-snapshot.json.gz")
    }

    fn stored_shards(&self) -> usize {
        std::fs::read_dir(self.path().join(".nil-kill/runtime/shard-evidence"))
            .into_iter()
            .flatten()
            .flatten()
            .count()
    }

    /// Anchors with the identity of the run that produced them removed, which
    /// is the only thing two collects of the same code may differ in.
    fn evidence(&self) -> Vec<String> {
        let document = self.read_gz(".nil-kill/runtime/runtime-evidence.v1.json.gz");
        let mut rows = document["anchors"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|anchor| {
                let mut anchor = anchor.clone();
                anchor["capture"].as_object_mut().map(|map| map.remove("run_ids"));
                for execution in anchor["executions"].as_array_mut().into_iter().flatten() {
                    execution["provenance"].as_object_mut().map(|map| map.remove("run_id"));
                }
                serde_json::to_string(&anchor).unwrap_or_default()
            })
            .collect::<Vec<_>>();
        rows.sort();
        rows
    }
}

fn skip_unless_collectable() -> bool {
    if collector().is_none() {
        eprintln!("skipping: the collector extension is not built");
        return true;
    }
    if !ruby_available() {
        eprintln!("skipping: no ruby to trace");
        return true;
    }
    false
}

#[test]
fn an_increment_leaves_the_evidence_a_full_collect_would_have() {
    if skip_unless_collectable() {
        return;
    }
    let project = Project::new();
    let (output, ok) = project.full();
    assert!(ok, "full collect failed: {output}");
    assert_eq!(project.manifest()["generation"], 0);
    assert_eq!(project.manifest()["mode"], "full");
    assert_eq!(project.stored_shards(), 2);
    // What each shard reached is what makes the next increment selective; a
    // manifest that recorded nothing would rerun everything forever, silently.
    let manifest = project.manifest();
    for field in ["dependencies", "callsites"] {
        let recorded = manifest[field].as_object().expect(field);
        assert_eq!(recorded.len(), 2, "{field}: {recorded:?}");
        assert!(
            recorded.values().all(|entry| !entry.as_array().expect("array").is_empty()),
            "{field}: {recorded:?}"
        );
    }

    // Nothing changed: the workload does not run at all.
    let (output, ok) = project.fast();
    assert!(ok, "{output}");
    assert!(output.contains("workload skipped"), "{output}");
    assert_eq!(project.manifest()["generation"], 0, "a skipped collect is not a generation");

    // Reformatting is not an edit, so neither is this.
    project.edit("lib/calculator.rb", "value * 2", "value  *  2 # doubled");
    let (output, ok) = project.fast();
    assert!(ok, "{output}");
    assert!(output.contains("workload skipped"), "reformatting retraced: {output}");

    // A real edit reruns the one shard whose evidence depended on it.
    project.edit("lib/calculator.rb", "value  *  2 # doubled", "value + value");
    let (output, ok) = project.fast();
    assert!(ok, "{output}");
    assert!(output.contains("1 changed functions"), "{output}");
    assert!(output.contains("1 traced shards"), "{output}");

    // ... and the result is still the whole picture, not just that shard's.
    let incremental = project.evidence();
    let reference = Project::new();
    reference.edit("lib/calculator.rb", "value * 2", "value + value");
    let (output, ok) = reference.full();
    assert!(ok, "{output}");
    assert_eq!(incremental, reference.evidence());
}

#[test]
fn a_workload_change_reruns_what_it_has_to_and_no_more() {
    if skip_unless_collectable() {
        return;
    }
    let project = Project::new();
    let (output, ok) = project.full();
    assert!(ok, "{output}");

    // A new test file is a new shard.
    project.write(
        "test/added_test.rb",
        "require \"minitest/autorun\"\nrequire_relative \"../lib/calculator\"\n\
         class AddedTest < Minitest::Test\n  def test_added\n    \
         assert_equal 10, Calculator.new.double(5)\n  end\nend\n",
    );
    let (output, ok) = project.fast();
    assert!(ok, "{output}");
    assert!(output.contains("1 changed tests"), "{output}");
    assert!(output.contains("1 traced shards"), "{output}");
    assert_eq!(project.stored_shards(), 3);

    // A support file is not attributable to any one shard, so all of them go.
    project.write("test/test_helper.rb", "HELPER_VERSION = 1\n");
    let (output, ok) = project.fast();
    assert!(ok, "{output}");
    assert!(output.contains("3 traced shards"), "{output}");
    assert_eq!(project.manifest()["support_changed"], true);
    assert_eq!(project.manifest()["fallback_full"], true);

    // A deleted test takes its stored evidence with it and runs nothing.
    std::fs::remove_file(project.path().join("test/added_test.rb")).expect("delete");
    let (output, ok) = project.fast();
    assert!(ok, "{output}");
    assert!(output.contains("0 traced shards"), "{output}");
    assert_eq!(project.manifest()["deleted_tests"], serde_json::json!(["test/added_test.rb"]));
    assert_eq!(project.stored_shards(), 2);
}

#[test]
fn a_failing_shard_leaves_the_previous_evidence_exactly_where_it_was() {
    if skip_unless_collectable() {
        return;
    }
    let project = Project::new();
    let (output, ok) = project.full();
    assert!(ok, "{output}");
    let before = project.evidence();
    let generation = project.manifest()["generation"].clone();

    project.edit("test/double_test.rb", "assert_equal 8", "raise \"trace failure\" #");
    let (output, ok) = project.fast();

    assert!(!ok, "a failing shard must fail the collect: {output}");
    assert!(output.contains("canonical evidence was not replaced"), "{output}");
    assert_eq!(project.evidence(), before);
    assert_eq!(project.manifest()["generation"], generation);
    assert_eq!(project.manifest()["complete"], false);
    assert_eq!(project.manifest()["potentially_stale"], true);
    assert!(
        project.manifest()["stale_reason"]
            .as_str()
            .is_some_and(|reason| reason.contains("required trace shard")),
        "{:?}",
        project.manifest()["stale_reason"]
    );

    // Fixing the test recovers: a stale snapshot is a state to collect out of,
    // not one that needs a full collect to escape.
    project.edit("test/double_test.rb", "raise \"trace failure\" #", "assert_equal 8");
    let (output, ok) = project.fast();
    assert!(ok, "{output}");
    assert_eq!(project.manifest()["complete"], true);
    assert_eq!(project.manifest()["potentially_stale"], false);
    assert_eq!(project.evidence(), before);
}

#[test]
fn an_incremental_collect_without_a_snapshot_says_so() {
    let project = Project::new();
    let (output, ok) = project.collect(&["--fast"]);

    assert!(!ok);
    assert!(output.contains("run a full collect first"), "{output}");
}

#[test]
fn a_workload_can_be_named_in_a_file_one_command_per_line() {
    // A workload too long for a command line is still one collect.
    let project = Project::new();
    let listing = project.path().join("commands.txt");
    std::fs::write(
        &listing,
        "# ignored\nruby -e 'exit 0'\n\nruby -e 'exit 0'\n",
    )
    .expect("write");

    let (output, ok) = project.collect(&["--commands", &listing.to_string_lossy()]);

    // Two shards ran; the collect got as far as needing evidence from them,
    // which is what proves both lines parsed into commands.
    assert!(ok || output.contains("shard"), "{output}");
    assert!(!output.contains("requires a command"), "{output}");
}
