//! The diff "Tests" section: per `language:test_set` (tag) counts of how a change
//! affected the test suite. Split into structural churn (added/deleted/changed/
//! pending tests) and quality signals (tests that kill no mutants, add no
//! coverage, or kill no *distinct* mutants — i.e. are redundant for kills).
//!
//! This module is pure: it takes the base- and head-commit test inventories
//! (built from `test_exposure_events`) plus the diff's changed test-file lines,
//! and returns one [`TestSummary`] per `(language, test_set)` that changed. The
//! DB query that materializes the inventories lives in storage; keeping the
//! logic here makes every metric unit-testable without a database.

use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use ts_rs::TS;

/// Test-level attributes a runner may attach to a test-exposure record's
/// `payload_json`: the test's own file and definition span (for "changed"),
/// whether it is pending/skipped, and the set of mutant ids it killed (for
/// "kills no distinct mutants"). All optional — absent fields degrade.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct TestPayloadMeta {
    pub language: String,
    pub test_path: String,
    pub start_line: u32,
    pub end_line: u32,
    pub pending: bool,
    pub killed_mutants: BTreeSet<String>,
}

impl TestPayloadMeta {
    pub fn parse(payload: &str) -> Self {
        let v: Value = serde_json::from_str(payload).unwrap_or(Value::Null);
        let str_at = |keys: &[&str]| -> String {
            keys.iter()
                .find_map(|k| v.get(*k).and_then(Value::as_str))
                .unwrap_or_default()
                .to_string()
        };
        let u32_at = |keys: &[&str]| -> Option<u32> {
            keys.iter()
                .find_map(|k| v.get(*k).and_then(Value::as_u64))
                .map(|n| n as u32)
        };
        let test_path = str_at(&["test_path", "test_file"]);
        let start_line = u32_at(&["test_start_line", "start_line"]).unwrap_or(0);
        let end_line = u32_at(&["test_end_line", "end_line"]).unwrap_or(start_line);
        let pending = ["pending", "skipped"]
            .iter()
            .any(|k| v.get(*k).and_then(Value::as_bool).unwrap_or(false));
        let killed_mutants = v
            .get("killed_mutant_ids")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|e| e.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        Self {
            language: language_from_path(&test_path),
            test_path,
            start_line,
            end_line,
            pending,
            killed_mutants,
        }
    }
}

/// Best-effort language of a source path, by extension.
pub fn language_from_path(path: &str) -> String {
    let ext = path.rsplit('.').next().unwrap_or("");
    match ext {
        "rb" => "ruby",
        "go" => "go",
        "zig" => "zig",
        "rs" => "rust",
        "py" => "python",
        "js" | "jsx" | "mjs" => "javascript",
        "ts" | "tsx" => "typescript",
        _ => "unknown",
    }
    .to_string()
}

/// One test's aggregated evidence at a single commit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TestInventoryRow {
    /// Stable test identity (e.g. `spec/foo_spec.rb:BarTest#baz`).
    pub test_id: String,
    /// Test tag / suite: `unit` | `integration` | `fuzz` (from `test_type`).
    pub test_set: String,
    /// Language of the test file (e.g. `ruby`, `go`), from the test path.
    pub language: String,
    /// The test's own definition file (not the production file it covers).
    pub test_path: String,
    /// Definition line span, used to decide whether the diff changed this test.
    pub start_line: u32,
    pub end_line: u32,
    /// The test is skipped/pending (rspec `pending`, Go `t.Skip`, minitest skip).
    pub pending: bool,
    /// Count of distinct production lines this test exercised.
    pub covered_lines: usize,
    /// Whether this test was exercised under mutation at all (so an empty kill
    /// set is meaningful — "ran mutants, killed none" vs "never ran mutants").
    pub had_mutation: bool,
    /// The set of mutant ids this test killed.
    pub killed_mutants: BTreeSet<String>,
}

/// Per `(language, test_set)` test-churn + quality summary. Only groups with at
/// least one nonzero count are emitted (the "only show tags that changed" rule).
/// New-test timing for a group: how the change's new tests compare to the
/// recent per-stage baseline. `pending` means a measurement was expected but has
/// not landed yet (the background runner fills it in).
#[derive(Debug, Clone, Default, PartialEq, Serialize, TS)]
pub struct TestTiming {
    pub pending: bool,
    /// Percent change vs the baseline (+ is slower).
    pub pct: f64,
    /// Confidence half-width in percentage points (the `±`).
    pub ci_pct: f64,
    /// Repeat measurements behind the estimate.
    pub samples: usize,
    /// Historical commits behind the baseline; 0 means measured-but-no-baseline
    /// yet (the delta is not meaningful, the baseline is still building).
    pub baseline_n: usize,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, TS)]
pub struct TestSummary {
    pub language: String,
    pub test_set: String,
    // Structural churn (require base+head inventories; see `inventory_available`).
    pub added: usize,
    pub deleted: usize,
    pub changed: usize,
    pub pending: usize,
    // Quality signals (head-only; require mutation/coverage evidence).
    pub kill_no_mutants: usize,
    pub no_coverage: usize,
    pub kill_no_distinct: usize,
    /// True when the base commit had test evidence, so added/deleted/changed are
    /// trustworthy (otherwise everything would look "added").
    pub inventory_available: bool,
    /// True when head tests carried mutation evidence, so `kill_no_mutants` /
    /// `kill_no_distinct` reflect real kill data rather than absence.
    pub mutation_available: bool,
    /// New-test timing (delta ± CI), or pending, when this group added tests.
    #[serde(default)]
    pub timing: Option<TestTiming>,
}

impl TestSummary {
    fn any_change(&self) -> bool {
        self.added
            + self.deleted
            + self.changed
            + self.pending
            + self.kill_no_mutants
            + self.no_coverage
            + self.kill_no_distinct
            > 0
    }
}

/// Compute the per-`(language, test_set)` summaries.
///
/// - `base` / `head`: test inventories at each commit, already scoped to the
///   tests that live in the diff's changed test files.
/// - `changed_lines`: per test-file, the set of line numbers the diff touched
///   (added or removed). A test whose span intersects these is "changed".
/// - `base_present`: whether the base commit had *any* test evidence; when
///   false, added/deleted/changed are suppressed (not fabricated) and
///   `inventory_available` is false on every emitted group.
pub fn test_summaries(
    base: &[TestInventoryRow],
    head: &[TestInventoryRow],
    changed_lines: &BTreeMap<String, BTreeSet<u32>>,
    base_present: bool,
) -> Vec<TestSummary> {
    // Redundancy is a suite-wide property: a test "kills no distinct mutants" if
    // every mutant it kills is also killed by some *other* head test. Compute the
    // union once, then test each row against the union of the others.
    let redundant: BTreeSet<&str> = redundant_test_ids(head);

    let base_ids: BTreeSet<&str> = base.iter().map(|r| r.test_id.as_str()).collect();
    let head_by_id: BTreeMap<&str, &TestInventoryRow> =
        head.iter().map(|r| (r.test_id.as_str(), r)).collect();

    let mut groups: BTreeMap<(String, String), TestSummary> = BTreeMap::new();

    // Head-side: added, changed, pending, and every quality signal.
    for row in head {
        let g = group_mut(&mut groups, &row.language, &row.test_set, base_present);
        if base_present && !base_ids.contains(row.test_id.as_str()) {
            g.added += 1;
        } else if base_present {
            // Present in both commits: "changed" if the diff touched its span.
            if let Some(lines) = changed_lines.get(&row.test_path) {
                if lines.iter().any(|l| *l >= row.start_line && *l <= row.end_line) {
                    g.changed += 1;
                }
            }
        }
        if row.pending {
            g.pending += 1;
        }
        if row.had_mutation {
            g.mutation_available = true;
            if row.killed_mutants.is_empty() {
                g.kill_no_mutants += 1;
            } else if redundant.contains(row.test_id.as_str()) {
                g.kill_no_distinct += 1;
            }
        }
        if row.covered_lines == 0 {
            g.no_coverage += 1;
        }
    }

    // Base-side: deleted tests (present at base, gone at head).
    if base_present {
        for row in base {
            if !head_by_id.contains_key(row.test_id.as_str()) {
                group_mut(&mut groups, &row.language, &row.test_set, base_present).deleted += 1;
            }
        }
    }

    groups
        .into_values()
        .filter(TestSummary::any_change)
        .collect()
}

fn group_mut<'a>(
    groups: &'a mut BTreeMap<(String, String), TestSummary>,
    lang: &str,
    set: &str,
    base_present: bool,
) -> &'a mut TestSummary {
    groups
        .entry((lang.to_string(), set.to_string()))
        .or_insert_with(|| TestSummary {
            language: lang.to_string(),
            test_set: set.to_string(),
            inventory_available: base_present,
            ..TestSummary::default()
        })
}

/// Test ids whose (non-empty) killed-mutant set is fully covered by the union of
/// the *other* tests' kills — they kill nothing distinct.
fn redundant_test_ids(head: &[TestInventoryRow]) -> BTreeSet<&str> {
    let mut redundant = BTreeSet::new();
    for row in head {
        if row.killed_mutants.is_empty() {
            continue;
        }
        let others_union: BTreeSet<&str> = head
            .iter()
            .filter(|o| o.test_id != row.test_id)
            .flat_map(|o| o.killed_mutants.iter().map(String::as_str))
            .collect();
        if row
            .killed_mutants
            .iter()
            .all(|m| others_union.contains(m.as_str()))
        {
            redundant.insert(row.test_id.as_str());
        }
    }
    redundant
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, set: &str, path: &str, start: u32, end: u32) -> TestInventoryRow {
        TestInventoryRow {
            test_id: id.into(),
            test_set: set.into(),
            language: "ruby".into(),
            test_path: path.into(),
            start_line: start,
            end_line: end,
            pending: false,
            covered_lines: 1,
            had_mutation: false,
            killed_mutants: BTreeSet::new(),
        }
    }

    fn get<'a>(v: &'a [TestSummary], lang: &str, set: &str) -> &'a TestSummary {
        v.iter()
            .find(|s| s.language == lang && s.test_set == set)
            .unwrap_or_else(|| panic!("no summary for {lang}:{set}"))
    }

    #[test]
    fn added_deleted_changed_split_by_tag_only_report_touched_groups() {
        let base = vec![
            row("t_a", "unit", "spec/a_spec.rb", 1, 5),
            row("t_gone", "unit", "spec/a_spec.rb", 10, 15),
            row("t_int", "integration", "spec/i_spec.rb", 1, 4),
        ];
        let head = vec![
            row("t_a", "unit", "spec/a_spec.rb", 1, 7), // present in both; changed below
            row("t_new", "unit", "spec/a_spec.rb", 20, 25), // added
            row("t_int", "integration", "spec/i_spec.rb", 1, 4), // untouched
        ];
        // The diff touched lines 6 and 22 of a_spec.rb (inside t_a and t_new).
        let mut changed = BTreeMap::new();
        changed.insert("spec/a_spec.rb".to_string(), BTreeSet::from([6u32, 22]));

        let summaries = test_summaries(&base, &head, &changed, true);
        let unit = get(&summaries, "ruby", "unit");
        assert_eq!(unit.added, 1, "t_new");
        assert_eq!(unit.deleted, 1, "t_gone");
        assert_eq!(unit.changed, 1, "t_a span intersects line 6");
        // integration group had no churn -> not emitted at all.
        assert!(summaries.iter().all(|s| s.test_set != "integration"));
    }

    #[test]
    fn pending_and_no_coverage_are_counted_head_only() {
        let mut pending = row("t_skip", "unit", "spec/a_spec.rb", 1, 3);
        pending.pending = true;
        let mut uncovered = row("t_empty", "unit", "spec/a_spec.rb", 5, 7);
        uncovered.covered_lines = 0;
        let head = vec![pending, uncovered];
        let summaries = test_summaries(&[], &head, &BTreeMap::new(), false);
        let unit = get(&summaries, "ruby", "unit");
        assert_eq!(unit.pending, 1);
        assert_eq!(unit.no_coverage, 1);
        // No base evidence -> structural churn suppressed, not fabricated.
        assert!(!unit.inventory_available);
        assert_eq!(unit.added, 0);
    }

    #[test]
    fn kill_no_mutants_versus_kill_no_distinct() {
        // t_kills uniquely kills m3; t_redundant only kills m1/m2 which t_kills
        // and t_other also kill; t_silent ran mutants but killed none.
        let mut t_kills = row("t_kills", "unit", "spec/a_spec.rb", 1, 3);
        t_kills.had_mutation = true;
        t_kills.killed_mutants = BTreeSet::from(["m1".into(), "m2".into(), "m3".into()]);
        let mut t_other = row("t_other", "unit", "spec/a_spec.rb", 5, 7);
        t_other.had_mutation = true;
        t_other.killed_mutants = BTreeSet::from(["m1".into(), "m2".into()]);
        let mut t_redundant = row("t_redundant", "unit", "spec/a_spec.rb", 9, 11);
        t_redundant.had_mutation = true;
        t_redundant.killed_mutants = BTreeSet::from(["m1".into()]);
        let mut t_silent = row("t_silent", "unit", "spec/a_spec.rb", 13, 15);
        t_silent.had_mutation = true; // ran mutants, killed nothing

        let head = vec![t_kills, t_other, t_redundant, t_silent];
        let summaries = test_summaries(&[], &head, &BTreeMap::new(), false);
        let unit = get(&summaries, "ruby", "unit");
        assert!(unit.mutation_available);
        assert_eq!(unit.kill_no_mutants, 1, "t_silent");
        // t_other kills {m1,m2} both covered by t_kills; t_redundant {m1} covered.
        // t_kills is NOT redundant (m3 is unique to it).
        assert_eq!(unit.kill_no_distinct, 2, "t_other and t_redundant");
    }
}
