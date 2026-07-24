//! Risk weighting for changed units and collapse-tree nodes.
//!
//! Extends the existing `review_next_items` weighting
//! (`warnings*3 + dark_arms*5 + findings + tool_count*2`) with hazard,
//! SARIF-tier, and coverage signals scaled by changed lines of code. Uncovered
//! hazards dominate; uncovered T1 findings rank high. See `docs/agents/cli-ui.md`.

// Weighting constants (MVP).
const HAZARD_UNCOVERED: f64 = 50.0;
const HAZARD_OPEN: f64 = 20.0;
const T1: f64 = 8.0;
const T2: f64 = 3.0;
const T3: f64 = 1.0;
const DARK_ARM: f64 = 5.0;
const UNCOVERED_CHANGE: f64 = 2.0;

/// The four verification states a changed unit / finding can be in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoverageState {
    /// Covered by a test and a mutant was killed there.
    CoveredKilled,
    /// Covered by a test, no mutation evidence.
    Covered,
    /// Some coverage but incomplete (partial branch / tests exist but line cold).
    Partial,
    /// No coverage at all.
    Uncovered,
    /// No evidence loaded yet (DB stale / still analyzing).
    Unknown,
}

impl CoverageState {
    pub fn label(self) -> &'static str {
        match self {
            CoverageState::CoveredKilled => "covered+killed",
            CoverageState::Covered => "covered",
            CoverageState::Partial => "partial",
            CoverageState::Uncovered => "uncovered",
            CoverageState::Unknown => "unknown",
        }
    }

    /// Derive the state from primitive evidence counts.
    pub fn derive(
        covered: bool,
        is_partial: bool,
        distinct_tests: i64,
        mutant_killed_tests: i64,
        has_evidence: bool,
    ) -> Self {
        if !has_evidence {
            return CoverageState::Unknown;
        }
        if covered && mutant_killed_tests > 0 {
            CoverageState::CoveredKilled
        } else if covered && !is_partial {
            CoverageState::Covered
        } else if is_partial || distinct_tests > 0 {
            CoverageState::Partial
        } else {
            CoverageState::Uncovered
        }
    }
}

/// Aggregated evidence for a single changed unit. Filled from the gigasail DB by
/// the evidence layer; defaults to all-zero / `Unknown` when no DB is present.
#[derive(Debug, Clone, PartialEq)]
pub struct Evidence {
    pub hazards_total: u32,
    pub hazards_uncovered: u32,
    pub t1_findings: u32,
    pub t2_findings: u32,
    pub t3_findings: u32,
    pub dark_arm_findings: u32,
    pub uncovered_changed_loc: u32,
    pub coverage: CoverageState,
    /// Coverage of this unit's added lines, split into the bar's segments.
    pub cov_killed: u32,
    pub cov_covered: u32,
    pub cov_partial: u32,
    pub cov_uncovered: u32,
    pub cov_unknown: u32,
}

impl Default for Evidence {
    fn default() -> Self {
        Self {
            hazards_total: 0,
            hazards_uncovered: 0,
            t1_findings: 0,
            t2_findings: 0,
            t3_findings: 0,
            dark_arm_findings: 0,
            uncovered_changed_loc: 0,
            coverage: CoverageState::Unknown,
            cov_killed: 0,
            cov_covered: 0,
            cov_partial: 0,
            cov_uncovered: 0,
            cov_unknown: 0,
        }
    }
}

impl Evidence {
    /// Total non-hazard SARIF findings across tiers.
    pub fn sarif_findings(&self) -> u32 {
        self.t1_findings + self.t2_findings + self.t3_findings
    }

    pub fn has_signal(&self) -> bool {
        self.hazards_total > 0 || self.sarif_findings() > 0 || self.dark_arm_findings > 0
    }
}

/// A comparable risk score. Higher is riskier.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RiskScore(pub f64);

impl RiskScore {
    pub const ZERO: RiskScore = RiskScore(0.0);

    pub fn combine(self, other: RiskScore) -> RiskScore {
        RiskScore(self.0 + other.0)
    }
}

impl PartialOrd for RiskScore {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        self.0.partial_cmp(&other.0)
    }
}

/// Compute a changed unit's leaf risk from its changed LoC and evidence.
pub fn leaf_risk(added: u32, removed: u32, ev: &Evidence) -> RiskScore {
    let changed = (added + removed) as f64;
    let loc_weight = (1.0 + changed).ln();
    let weighted_findings = HAZARD_UNCOVERED * ev.hazards_uncovered as f64
        + HAZARD_OPEN * (ev.hazards_total.saturating_sub(ev.hazards_uncovered)) as f64
        + T1 * ev.t1_findings as f64
        + T2 * ev.t2_findings as f64
        + T3 * ev.t3_findings as f64
        + DARK_ARM * ev.dark_arm_findings as f64;
    let score = loc_weight * weighted_findings + UNCOVERED_CHANGE * ev.uncovered_changed_loc as f64;
    RiskScore(score)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coverage_state_precedence() {
        assert_eq!(
            CoverageState::derive(true, false, 3, 2, true),
            CoverageState::CoveredKilled
        );
        assert_eq!(
            CoverageState::derive(true, false, 3, 0, true),
            CoverageState::Covered
        );
        assert_eq!(
            CoverageState::derive(true, true, 3, 0, true),
            CoverageState::Partial
        );
        assert_eq!(
            CoverageState::derive(false, false, 1, 0, true),
            CoverageState::Partial
        );
        assert_eq!(
            CoverageState::derive(false, false, 0, 0, true),
            CoverageState::Uncovered
        );
        assert_eq!(
            CoverageState::derive(false, false, 0, 0, false),
            CoverageState::Unknown
        );
    }

    #[test]
    fn zero_evidence_still_scores_nothing() {
        let ev = Evidence::default();
        assert_eq!(leaf_risk(10, 5, &ev), RiskScore(0.0));
    }

    #[test]
    fn uncovered_hazard_dominates_covered_one() {
        let uncovered = Evidence {
            hazards_total: 1,
            hazards_uncovered: 1,
            ..Default::default()
        };
        let covered = Evidence {
            hazards_total: 1,
            hazards_uncovered: 0,
            ..Default::default()
        };
        assert!(leaf_risk(10, 0, &uncovered) > leaf_risk(10, 0, &covered));
    }

    #[test]
    fn tiers_are_ordered_t1_gt_t2_gt_t3() {
        let mk = |t1, t2, t3| Evidence {
            t1_findings: t1,
            t2_findings: t2,
            t3_findings: t3,
            ..Default::default()
        };
        assert!(leaf_risk(5, 0, &mk(1, 0, 0)) > leaf_risk(5, 0, &mk(0, 1, 0)));
        assert!(leaf_risk(5, 0, &mk(0, 1, 0)) > leaf_risk(5, 0, &mk(0, 0, 1)));
    }

    #[test]
    fn more_changed_loc_raises_risk_for_same_findings() {
        let ev = Evidence {
            t1_findings: 1,
            ..Default::default()
        };
        assert!(leaf_risk(100, 0, &ev) > leaf_risk(2, 0, &ev));
    }

    #[test]
    fn uncovered_change_contributes_without_findings() {
        let ev = Evidence {
            uncovered_changed_loc: 12,
            ..Default::default()
        };
        assert_eq!(leaf_risk(12, 0, &ev), RiskScore(24.0));
    }

    #[test]
    fn sarif_findings_sums_tiers() {
        let ev = Evidence {
            t1_findings: 1,
            t2_findings: 2,
            t3_findings: 3,
            ..Default::default()
        };
        assert_eq!(ev.sarif_findings(), 6);
        assert!(ev.has_signal());
        assert!(!Evidence::default().has_signal());
    }

    #[test]
    fn risk_score_combines_and_orders() {
        assert_eq!(RiskScore(1.0).combine(RiskScore(2.0)), RiskScore(3.0));
        assert!(RiskScore(5.0) > RiskScore(4.0));
    }
}
