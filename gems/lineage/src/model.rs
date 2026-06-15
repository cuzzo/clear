use sha2::{Digest, Sha256};
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UnitKind {
    Function,
    Class,
    Module,
}

impl UnitKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Function => "function",
            Self::Class => "class",
            Self::Module => "module",
        }
    }
}

impl fmt::Display for UnitKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EventType {
    Change,
    Move,
    Fix,
}

impl EventType {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Change => "CHANGE",
            Self::Move => "MOVE",
            Self::Fix => "FIX",
        }
    }
}

impl fmt::Display for EventType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogicalUnit {
    pub id: String,
    pub name: String,
    pub kind: UnitKind,
    pub path: String,
    pub ordinal: u32,
    pub start_line: u32,
    pub end_line: u32,
    pub normalized_hash: String,
    pub normalized_source: String,
    pub signature: String,
}

impl LogicalUnit {
    pub fn new(
        name: impl Into<String>,
        kind: UnitKind,
        path: impl Into<String>,
        ordinal: u32,
        start_line: u32,
        end_line: u32,
        signature: impl Into<String>,
        body: &str,
    ) -> Self {
        let name = name.into();
        let path = path.into();
        let signature = signature.into();
        let normalized_source = normalize_source(body);
        let normalized_hash = short_hash(&normalized_source);
        let id = short_hash(&format!("{}:{}:{}:{}", kind, path, name, ordinal));

        Self {
            id,
            name,
            kind,
            path,
            ordinal,
            start_line,
            end_line,
            normalized_hash,
            normalized_source,
            signature,
        }
    }

    pub fn line_count(&self) -> i64 {
        (self.end_line.saturating_sub(self.start_line) + 1) as i64
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    pub unit_id: String,
    pub commit_hash: String,
    pub event_type: EventType,
    pub path: String,
    pub name: String,
    pub start_line: u32,
    pub end_line: u32,
    pub semantic_change: bool,
    pub lines_added: i64,
    pub lines_removed: i64,
    pub timestamp: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum QualityMetric {
    LineCoverage,
    IntegrationCoverage,
    MutantCoverage,
    GateStatus,
}

impl QualityMetric {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::LineCoverage => "LINE_COV",
            Self::IntegrationCoverage => "INTEGRATION_COV",
            Self::MutantCoverage => "MUTANT_COV",
            Self::GateStatus => "GATE_STATUS",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct QualityEvent {
    pub unit_id: String,
    pub commit_hash: String,
    pub timestamp: i64,
    pub metric_type: QualityMetric,
    pub old_value: Option<f64>,
    pub new_value: f64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CrashEvent {
    pub unit_id: String,
    pub commit_hash: String,
    pub timestamp: i64,
    pub error_class: String,
    pub provider_id: String,
    pub is_verified: bool,
    pub path: String,
    pub line: u32,
    pub function: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TestExposureEvent {
    pub unit_id: String,
    pub commit_hash: String,
    pub timestamp: i64,
    pub path: String,
    pub function: Option<String>,
    pub line: Option<u32>,
    pub branch_id: Option<String>,
    pub test_id: String,
    pub test_type: String,
    pub mutation_status: Option<String>,
    pub mutation_kind: Option<String>,
    pub is_mutation_verified: bool,
    pub is_mutation_killed: bool,
    pub is_verified: bool,
    pub payload_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HazardEvent {
    pub unit_id: String,
    pub language: String,
    pub hazard_type: String,
    pub required_evidence: String,
    pub path: String,
    pub line: u32,
    pub symbol: Option<String>,
    pub source: String,
    pub detected_at_hash: String,
    pub is_active: bool,
    pub payload_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitMetadata {
    pub hash: String,
    pub message: String,
    pub timestamp: i64,
}

impl CommitMetadata {
    pub fn is_fix(&self) -> bool {
        let msg = self.message.to_ascii_lowercase();
        [
            "fix",
            "bug",
            "regression",
            "crash",
            "panic",
            "fault",
            "incorrect",
            "wrong",
        ]
        .iter()
        .any(|needle| msg.contains(needle))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlobFile {
    pub path: String,
    pub contents: String,
}

pub fn normalize_source(source: &str) -> String {
    source
        .lines()
        .filter_map(|line| {
            let trimmed = strip_comment(line).trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.split_whitespace().collect::<String>())
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn short_hash(input: &str) -> String {
    let digest = Sha256::digest(input.as_bytes());
    hex::encode(&digest[..16])
}

fn strip_comment(line: &str) -> &str {
    let trimmed = line.trim_start();
    if trimmed.starts_with('#') || trimmed.starts_with("//") {
        return "";
    }

    let hash = line.find('#');
    let slashes = line.find("//");
    match (hash, slashes) {
        (Some(h), Some(s)) => &line[..h.min(s)],
        (Some(h), None) => &line[..h],
        (None, Some(s)) => &line[..s],
        (None, None) => line,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_whitespace_and_comments() {
        let a = "def run(x)\n  x + 1 # comment\nend\n";
        let b = "def run(x)\n\n    x    +    1\nend\n";

        assert_eq!(normalize_source(a), normalize_source(b));
    }

    #[test]
    fn commit_metadata_detects_fix_messages() {
        assert!(CommitMetadata {
            hash: "a".into(),
            message: "Fix parser crash".into(),
            timestamp: 0,
        }
        .is_fix());
    }
}
