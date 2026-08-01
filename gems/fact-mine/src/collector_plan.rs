//! The plan the collector reads.
//!
//! A traced program is handed flat records rather than a document plus the code
//! to reshape it: what it should demand at which coordinate, which record fields
//! are still worth sampling, and where the T.let sites are. Everything here was
//! already decided by the time the plan was built, so deciding it again inside
//! the program under observation would be work in the worst possible place.
//!
//! Records are `\x02`-separated because demand keys contain `\x01` of their own.

use anyhow::{Context, Result};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

const FIELD: char = '\u{2}';

/// Build the collector's sidecar from the plan and the instrumentation controls
/// beside it. Insertion order is preserved for the demands, so the file is
/// stable across builds of the same plan.
pub fn render(plan: &Value, target_dirs: &[String], root: &Path) -> String {
    let mut lines: Vec<String> = target_dirs
        .iter()
        .map(|dir| format!("t{FIELD}{}", absolute(dir, root)))
        .collect();

    // A coordinate answers one anchor: the first request to claim it wins, as
    // it did when the collector was handed the whole plan and took `.first`.
    let mut demands: Vec<(String, String)> = Vec::new();
    let mut seen_demand = BTreeMap::new();
    let mut states: BTreeMap<String, String> = BTreeMap::new();

    let requests = plan
        .get("runtime_evidence")
        .and_then(|evidence| evidence.get("requests"))
        .or_else(|| plan.get("requests"))
        .and_then(Value::as_array);
    for request in requests.into_iter().flatten() {
        let Some(anchor) = request.get("anchor").filter(|value| value.is_object()) else {
            continue;
        };
        let path = absolute(anchor["relative_path"].as_str().unwrap_or_default(), root);
        let name = anchor["display_name"].as_str().unwrap_or_default();
        let range = request
            .get("execution_range")
            .filter(|value| value.is_object())
            .or_else(|| anchor.get("range").filter(|value| value.is_object()));
        if let Some(range) = range {
            let symbol = anchor["symbol"].as_str().unwrap_or_default();
            let start = range["start_line"].as_i64().unwrap_or_default();
            let end = range["end_line"].as_i64().unwrap_or_default();
            for line in start..=end {
                let key = format!("{path}\u{1}{}\u{1}{name}", line + 1);
                if seen_demand.insert(key.clone(), ()).is_none() {
                    demands.push((key, symbol.to_string()));
                }
            }
        }

        // A state write is the one anchor kind with no event of its own:
        // nothing is raised when an ivar is assigned, so the collector reads the
        // member back and needs the member's own name to do it.
        if anchor["kind"].as_str() != Some("STATE_WRITE") || name.is_empty() {
            continue;
        }
        let Some(own) = anchor.get("range").filter(|value| value.is_object()) else { continue };
        let line = own["start_line"].as_i64().unwrap_or_default() + 1;
        states.insert(format!("{path}\u{1}{line}\u{1}{name}"), format!("@{name}"));
    }

    for (key, symbol) in demands {
        lines.push(format!("d{FIELD}{key}{FIELD}{symbol}"));
    }
    for (key, ivar) in states {
        lines.push(format!("s{FIELD}{key}{FIELD}{ivar}"));
    }
    for (key, sampled) in struct_fields(plan) {
        lines.push(format!("f{FIELD}{key}{FIELD}{}", if sampled { "1" } else { "0" }));
    }
    for key in tlets(plan) {
        lines.push(format!("l{FIELD}{key}"));
    }
    lines.join("\n") + "\n"
}

fn struct_fields(plan: &Value) -> Vec<(String, bool)> {
    plan.get("struct_fields")
        .and_then(Value::as_object)
        .into_iter()
        .flatten()
        .map(|(key, sampled)| (key.clone(), sampled.as_bool().unwrap_or(true)))
        .collect()
}

fn tlets(plan: &Value) -> Vec<String> {
    plan.get("tlets")
        .and_then(Value::as_object)
        .into_iter()
        .flatten()
        .map(|(key, _)| key.clone())
        .collect()
}

fn absolute(path: &str, root: &Path) -> String {
    if path.starts_with('/') {
        return path.to_string();
    }
    root.join(path).to_string_lossy().to_string()
}

pub fn write(plan_path: &Path, output: &Path, target_dirs: &[String], root: &Path) -> Result<()> {
    let raw = std::fs::read_to_string(plan_path)
        .with_context(|| format!("unreadable plan {}", plan_path.display()))?;
    let plan: Value = serde_json::from_str(&raw)
        .with_context(|| format!("invalid plan {}", plan_path.display()))?;
    std::fs::write(output, render(&plan, target_dirs, root))
        .with_context(|| format!("failed to write {}", output.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn lines(rendered: &str) -> Vec<Vec<String>> {
        rendered
            .lines()
            .map(|line| line.split(FIELD).map(str::to_string).collect())
            .collect()
    }

    #[test]
    fn a_demanded_range_becomes_one_coordinate_per_line() {
        let plan = json!({"runtime_evidence": {"requests": [{
            "anchor": {
                "relative_path": "lib/a.rb", "display_name": "size", "symbol": "sym-1",
                "range": {"start_line": 4, "end_line": 6},
            },
        }]}});
        let rendered = render(&plan, &[], Path::new("/w"));

        // Ranges are zero-based and the collector reports one-based lines.
        assert_eq!(
            lines(&rendered),
            vec![
                vec!["d", "/w/lib/a.rb\u{1}5\u{1}size", "sym-1"],
                vec!["d", "/w/lib/a.rb\u{1}6\u{1}size", "sym-1"],
                vec!["d", "/w/lib/a.rb\u{1}7\u{1}size", "sym-1"],
            ]
        );
    }

    #[test]
    fn the_first_request_to_claim_a_coordinate_keeps_it() {
        let request = |symbol: &str| {
            json!({"anchor": {
                "relative_path": "lib/a.rb", "display_name": "size", "symbol": symbol,
                "range": {"start_line": 0, "end_line": 0},
            }})
        };
        let plan = json!({"runtime_evidence": {"requests": [request("first"), request("second")]}});

        assert_eq!(lines(&render(&plan, &[], Path::new("/w")))[0][2], "first");
    }

    /// A state write raises no event of its own, so the collector reads the
    /// member back and needs its ivar name. Only the anchor's own range names
    /// the write; an execution range would name the statement around it.
    #[test]
    fn a_state_write_carries_the_member_to_read_back() {
        let plan = json!({"runtime_evidence": {"requests": [{
            "execution_range": {"start_line": 0, "end_line": 9},
            "anchor": {
                "relative_path": "lib/a.rb", "display_name": "count", "symbol": "sym-1",
                "kind": "STATE_WRITE", "range": {"start_line": 3, "end_line": 3},
            },
        }]}});
        let rendered = render(&plan, &[], Path::new("/w"));
        let state = lines(&rendered).into_iter().find(|line| line[0] == "s").expect("state record");

        assert_eq!(state, vec!["s", "/w/lib/a.rb\u{1}4\u{1}count", "@count"]);
    }

    #[test]
    fn a_resolved_record_field_is_marked_unsampled() {
        let plan = json!({
            "struct_fields": {"User\u{0}name": true, "User\u{0}id": false},
            "tlets": {"/w/lib/a.rb\u{0}12": true},
        });
        let rendered = lines(&render(&plan, &[], Path::new("/w")));

        assert!(rendered.contains(&vec!["f".into(), "User\u{0}name".into(), "1".into()]));
        assert!(rendered.contains(&vec!["f".into(), "User\u{0}id".into(), "0".into()]));
        assert!(rendered.contains(&vec!["l".into(), "/w/lib/a.rb\u{0}12".into()]));
    }
}
