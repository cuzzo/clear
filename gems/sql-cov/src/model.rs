use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThreeValuedLogicState {
    True,
    False,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExpressionSpan {
    pub id: usize,
    pub start_offset: usize,
    pub end_offset: usize,
    pub start_line: usize,
    pub start_column: usize,
    pub end_line: usize,
    pub end_column: usize,
    pub raw_expression: String,
    pub normalized_expression: String,
    pub context: String,
    pub nullable: bool,
    /// Zero-based source parameter ordinals used by anonymous `?` placeholders.
    pub parameter_indices: Vec<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoverageMetric {
    pub span: ExpressionSpan,
    /// Whether the execution driver can collect telemetry for this expression.
    pub measurable: bool,
    pub hit_true_count: u64,
    pub hit_false_count: u64,
    pub hit_unknown_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatementCoverage {
    pub id: usize,
    pub start_line: usize,
    pub end_line: usize,
    pub hit_count: u64,
    pub normalized_sql: String,
}

impl CoverageMetric {
    pub fn covered_branch_count(&self) -> usize {
        usize::from(self.hit_true_count > 0)
            + usize::from(self.hit_false_count > 0)
            + usize::from(self.span.nullable && self.hit_unknown_count > 0)
    }

    pub fn branch_count(&self) -> usize {
        if self.span.nullable {
            3
        } else {
            2
        }
    }

    pub fn is_fully_covered(&self) -> bool {
        self.covered_branch_count() == self.branch_count()
    }

    pub fn is_uncovered(&self) -> bool {
        self.hit_true_count == 0 && self.hit_false_count == 0 && self.hit_unknown_count == 0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceFileCoverage {
    pub format: String,
    pub file_path: String,
    pub dialect: String,
    pub raw_source: String,
    pub metrics: Vec<CoverageMetric>,
    pub statements: Vec<StatementCoverage>,
    pub unsupported: Vec<String>,
}

impl SourceFileCoverage {
    pub fn covered_branches(&self) -> usize {
        self.metrics
            .iter()
            .filter(|metric| metric.measurable)
            .map(CoverageMetric::covered_branch_count)
            .sum()
    }

    pub fn total_branches(&self) -> usize {
        self.metrics
            .iter()
            .filter(|metric| metric.measurable)
            .map(CoverageMetric::branch_count)
            .sum()
    }
}
