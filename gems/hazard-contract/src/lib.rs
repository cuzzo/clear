//! The canonical hazard contract and its query resources.
//!
//! The contract is parsed once by this crate, and Rust consumers resolve
//! hazard metadata through the same anchored glob matcher. Ruby consumers
//! load the JSON resource and exercise the shared matcher vectors.

use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::sync::OnceLock;

/// Versioned proof-boundary payload shared by Rust SARIF producers.
/// Ruby producers use the matching `FactMine::ProofBoundary` implementation.
pub mod proof_boundary {
    use serde_json::{json, Value};
    use std::collections::BTreeSet;

    pub const PROPERTY: &str = "fact_mine.proof_boundary";
    pub const SUMMARY_PROPERTY: &str = "fact_mine.proof_boundary_summary";
    pub const SCHEMA: &str = "fact-mine.proof-boundary.v3";

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum InputCompleteness {
        Complete,
        Partial,
        Unknown,
    }

    impl InputCompleteness {
        const fn as_str(self) -> &'static str {
            match self {
                Self::Complete => "complete",
                Self::Partial => "partial",
                Self::Unknown => "unknown",
            }
        }
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum ClaimStatus {
        Proven,
        Observed,
        Review,
    }

    impl ClaimStatus {
        const fn as_str(self) -> &'static str {
            match self {
                Self::Proven => "proven",
                Self::Observed => "observed",
                Self::Review => "review",
            }
        }
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum CoverageDischarge {
        Satisfiable,
        Unsatisfiable,
        NotApplicable,
        Unknown,
    }

    impl CoverageDischarge {
        const fn as_str(self) -> &'static str {
            match self {
                Self::Satisfiable => "satisfiable",
                Self::Unsatisfiable => "unsatisfiable",
                Self::NotApplicable => "not_applicable",
                Self::Unknown => "unknown",
            }
        }
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum ProofScopeKind {
        ReportedSpan,
        Function,
        Owner,
        File,
        Project,
        ClosedBuildTarget,
        Local,
    }

    impl ProofScopeKind {
        const fn as_str(self) -> &'static str {
            match self {
                Self::ReportedSpan => "reported_span",
                Self::Function => "function",
                Self::Owner => "owner",
                Self::File => "file",
                Self::Project => "project",
                Self::ClosedBuildTarget => "closed_build_target",
                Self::Local => "local",
            }
        }
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
    pub enum ProofBlockerKind {
        CallResolution,
        MissingEvidence,
        OpenCorpus,
        ParserRecovery,
        Unknown,
        UnsupportedLanguage,
    }

    impl ProofBlockerKind {
        const fn as_str(self) -> &'static str {
            match self {
                Self::ParserRecovery => "parser_recovery",
                Self::CallResolution => "call_resolution",
                Self::MissingEvidence => "missing_evidence",
                Self::OpenCorpus => "open_corpus",
                Self::UnsupportedLanguage => "unsupported_language",
                Self::Unknown => "unknown",
            }
        }
    }

    /// A canonical reason why a detector cannot make a stronger claim.
    #[derive(Clone, Debug, Eq, PartialEq)]
    pub struct ProofBlocker {
        kind: ProofBlockerKind,
        path: Option<String>,
        span: Option<[i64; 4]>,
    }

    impl ProofBlocker {
        pub fn parser_recovery(path: impl Into<String>, span: Option<[i64; 4]>) -> Self {
            Self {
                kind: ProofBlockerKind::ParserRecovery,
                path: Some(path.into()),
                span,
            }
        }

        pub fn call_resolution(path: impl Into<String>, span: Option<[i64; 4]>) -> Self {
            Self {
                kind: ProofBlockerKind::CallResolution,
                path: Some(path.into()),
                span,
            }
        }

        pub fn missing_evidence(path: Option<String>) -> Self {
            Self {
                kind: ProofBlockerKind::MissingEvidence,
                path,
                span: None,
            }
        }

        pub const fn open_corpus() -> Self {
            Self {
                kind: ProofBlockerKind::OpenCorpus,
                path: None,
                span: None,
            }
        }

        pub const fn unknown() -> Self {
            Self {
                kind: ProofBlockerKind::Unknown,
                path: None,
                span: None,
            }
        }

        fn validate(&self) -> Result<(), String> {
            if self.path.as_deref().is_some_and(str::is_empty) {
                return Err("proof blocker path must not be empty".to_string());
            }
            if let Some([start_line, start_column, end_line, end_column]) = self.span {
                if start_line < 1 || start_column < 0 || end_line < start_line || end_column < 0 {
                    return Err(
                        "proof blocker span must use nonnegative columns and positive lines"
                            .to_string(),
                    );
                }
                if end_line == start_line && end_column < start_column {
                    return Err("proof blocker span end precedes its start".to_string());
                }
            }
            Ok(())
        }

        fn value(self) -> Value {
            let mut value = json!({ "kind": self.kind.as_str() });
            if let Some(path) = self.path {
                value["path"] = json!(path);
            }
            if let Some(span) = self.span {
                value["span"] = json!(span);
            }
            value
        }

        fn canonical_sort_key(&self) -> String {
            self.clone().value().to_string()
        }
    }

    impl Ord for ProofBlocker {
        fn cmp(&self, other: &Self) -> std::cmp::Ordering {
            self.canonical_sort_key().cmp(&other.canonical_sort_key())
        }
    }

    impl PartialOrd for ProofBlocker {
        fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
            Some(self.cmp(other))
        }
    }

    /// Serializes the complete v3 boundary; callers cannot provide free-form
    /// enum values or reconstruct blocker strings at the presentation layer.
    pub fn build(
        input_completeness: InputCompleteness,
        claim_status: ClaimStatus,
        coverage_discharge: CoverageDischarge,
        authority: &[&str],
        claim_kind: &str,
        scope: ProofScopeKind,
        closed: bool,
        blockers: Vec<ProofBlocker>,
    ) -> Result<Value, String> {
        let authority = authority
            .iter()
            .map(|authority| (*authority).to_string())
            .collect::<BTreeSet<_>>();
        if authority.is_empty() || authority.iter().any(|authority| authority.is_empty()) {
            return Err("proof boundary authority must contain nonempty entries".to_string());
        }
        if claim_kind.is_empty() {
            return Err("proof boundary claim_kind must not be empty".to_string());
        }
        let blockers = blockers
            .into_iter()
            .map(|blocker| {
                blocker.validate()?;
                Ok(blocker)
            })
            .collect::<Result<BTreeSet<_>, String>>()?;
        if input_completeness == InputCompleteness::Complete && !blockers.is_empty() {
            return Err("complete input cannot carry proof blockers".to_string());
        }
        if blockers
            .iter()
            .any(|blocker| blocker.kind == ProofBlockerKind::OpenCorpus)
            && input_completeness != InputCompleteness::Unknown
        {
            return Err("open corpus blocker requires unknown input completeness".to_string());
        }
        Ok(json!({
            "schema": SCHEMA,
            "input_completeness": input_completeness.as_str(),
            "claim_status": claim_status.as_str(),
            "coverage_discharge": coverage_discharge.as_str(),
            "authority": authority,
            "claim_kind": claim_kind,
            "scope": { "kind": scope.as_str(), "closed": closed },
            "blockers": blockers.into_iter().map(ProofBlocker::value).collect::<Vec<_>>(),
        }))
    }

    /// Summarizes each proof dimension independently.
    pub fn summary(results: &[Value]) -> Value {
        let mut complete = 0usize;
        let mut partial = 0usize;
        let mut input_unknown = 0usize;
        let mut proven = 0usize;
        let mut observed = 0usize;
        let mut review = 0usize;
        let mut satisfiable = 0usize;
        let mut unsatisfiable = 0usize;
        let mut not_applicable = 0usize;
        let mut discharge_unknown = 0usize;
        let mut results_with_boundary = 0usize;
        for result in results {
            let Some(boundary) = result
                .pointer(&format!("/properties/{PROPERTY}"))
                .and_then(Value::as_object)
            else {
                continue;
            };
            results_with_boundary += 1;
            match boundary.get("input_completeness").and_then(Value::as_str) {
                Some("complete") => complete += 1,
                Some("partial") => partial += 1,
                _ => input_unknown += 1,
            }
            match boundary.get("claim_status").and_then(Value::as_str) {
                Some("proven") => proven += 1,
                Some("observed") => observed += 1,
                _ => review += 1,
            }
            match boundary.get("coverage_discharge").and_then(Value::as_str) {
                Some("satisfiable") => satisfiable += 1,
                Some("unsatisfiable") => unsatisfiable += 1,
                Some("not_applicable") => not_applicable += 1,
                _ => discharge_unknown += 1,
            }
        }
        json!({
            "schema": SCHEMA,
            "result_count": results.len(),
            "results_with_boundary": results_with_boundary,
            "input_completeness": {
                "complete": complete,
                "partial": partial,
                "unknown": input_unknown,
            },
            "claim_status": { "proven": proven, "observed": observed, "review": review },
            "coverage_discharge": {
                "satisfiable": satisfiable,
                "unsatisfiable": unsatisfiable,
                "not_applicable": not_applicable,
                "unknown": discharge_unknown,
            },
        })
    }
}

pub const CONTRACT_JSON: &str = include_str!("../contract.json");

pub const C_HAZARDS: &str = include_str!("../queries/c_hazards.scm");
pub const CPP_HAZARDS: &str = include_str!("../queries/cpp_hazards.scm");
pub const CSHARP_HAZARDS: &str = include_str!("../queries/csharp_hazards.scm");
pub const GO_HAZARDS: &str = include_str!("../queries/go_hazards.scm");
pub const RUST_HAZARDS: &str = include_str!("../queries/rust_hazards.scm");
pub const ZIG_HAZARDS: &str = include_str!("../queries/zig_hazards.scm");
pub const RUBY_HAZARDS: &str = include_str!("../queries/ruby_hazards.scm");
pub const PYTHON_HAZARDS: &str = include_str!("../queries/python_hazards.scm");
pub const JAVASCRIPT_HAZARDS: &str = include_str!("../queries/javascript_hazards.scm");
pub const TYPESCRIPT_HAZARDS: &str = include_str!("../queries/typescript_hazards.scm");
pub const LUA_HAZARDS: &str = include_str!("../queries/lua_hazards.scm");
pub const JAVA_HAZARDS: &str = include_str!("../queries/java_hazards.scm");
pub const PHP_HAZARDS: &str = include_str!("../queries/php_hazards.scm");
pub const KOTLIN_HAZARDS: &str = include_str!("../queries/kotlin_hazards.scm");
pub const SWIFT_HAZARDS: &str = include_str!("../queries/swift_hazards.scm");

/// The query resources exported by this crate. The manifest's `queries` map
/// is validated against this list so adding a query cannot silently bypass
/// the contract or leave a stale language name behind.
pub const QUERY_RESOURCES: &[(&str, &str)] = &[
    ("c", C_HAZARDS),
    ("cpp", CPP_HAZARDS),
    ("csharp", CSHARP_HAZARDS),
    ("go", GO_HAZARDS),
    ("rust", RUST_HAZARDS),
    ("zig", ZIG_HAZARDS),
    ("ruby", RUBY_HAZARDS),
    ("python", PYTHON_HAZARDS),
    ("javascript", JAVASCRIPT_HAZARDS),
    ("typescript", TYPESCRIPT_HAZARDS),
    ("lua", LUA_HAZARDS),
    ("java", JAVA_HAZARDS),
    ("php", PHP_HAZARDS),
    ("kotlin", KOTLIN_HAZARDS),
    ("swift", SWIFT_HAZARDS),
];

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct EvidencePolicy {
    pub claim: String,
    #[serde(default)]
    pub proves: Vec<String>,
    #[serde(default)]
    pub does_not_prove: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct HazardPolicy {
    #[serde(rename = "match")]
    pub pattern: String,
    pub kind: String,
    pub evidence_provider: String,
    pub evidence_claim: String,
    pub coverage_required: bool,
    pub report_required: bool,
    pub label: String,
    pub mitigation: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct MatcherVector {
    pub pattern: String,
    pub value: String,
    pub matches: bool,
}

#[derive(Debug, Deserialize)]
struct ContractDocument {
    version: u32,
    evidence: BTreeMap<String, EvidencePolicy>,
    policies: Vec<HazardPolicy>,
    queries: BTreeMap<String, String>,
    matcher_vectors: Vec<MatcherVector>,
}

fn contract() -> &'static ContractDocument {
    static CONTRACT: OnceLock<ContractDocument> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(CONTRACT_JSON)
            .unwrap_or_else(|error| panic!("bundled hazard contract must be valid JSON: {error}"))
    })
}

fn ensure_contract_is_valid() {
    static VALIDATED: OnceLock<()> = OnceLock::new();
    VALIDATED.get_or_init(|| {
        validate_contract()
            .unwrap_or_else(|error| panic!("invalid bundled hazard contract: {error}"));
    });
}

/// Resolve a hazard name using the canonical anchored glob semantics.
pub fn resolve_hazard_policy(hazard_type: &str) -> Option<&'static HazardPolicy> {
    ensure_contract_is_valid();
    contract()
        .policies
        .iter()
        .find(|policy| glob_matches(&policy.pattern, hazard_type))
}

/// Return whether `value` matches the complete `pattern`. The only wildcard
/// is `*`, which matches zero or more Unicode scalar values; matching is
/// anchored at both ends.
pub fn glob_matches(pattern: &str, value: &str) -> bool {
    let pattern: Vec<char> = pattern.chars().collect();
    let value: Vec<char> = value.chars().collect();
    let mut current = vec![false; value.len() + 1];
    current[0] = true;

    for pattern_character in pattern {
        let mut next = vec![false; value.len() + 1];
        if pattern_character == '*' {
            next[0] = current[0];
            for index in 1..=value.len() {
                next[index] = current[index] || next[index - 1];
            }
        } else {
            for index in 1..=value.len() {
                next[index] = current[index - 1] && pattern_character == value[index - 1];
            }
        }
        current = next;
    }

    current[value.len()]
}

/// Return whether a numeric literal on a C/C++ arithmetic hazard is
/// sanitizer-relevant. Dynamic operands remain relevant; harmless literals
/// such as `/ 2` and `<< 3` do not. Zero divisors and shift counts at least
/// 32 are retained conservatively for UBSan's target-type checks.
pub fn c_arithmetic_literal_is_relevant(operator: &str, rhs: &str) -> bool {
    let mut literal = rhs.trim();
    let without_suffix = literal.trim_end_matches(['u', 'U', 'l', 'L']);
    literal = without_suffix;
    let value = if let Some(hex) = literal
        .strip_prefix("0x")
        .or_else(|| literal.strip_prefix("0X"))
    {
        u128::from_str_radix(hex, 16).ok()
    } else if literal.chars().all(|character| character.is_ascii_digit()) {
        literal.parse::<u128>().ok()
    } else {
        None
    };
    let Some(value) = value else {
        return true;
    };
    match operator {
        "/" | "%" => value == 0,
        "<<" | ">>" => value >= 32,
        _ => true,
    }
}

fn query_hazard_names(query: &str) -> Vec<String> {
    let bytes = query.as_bytes();
    let mut names = Vec::new();
    let mut index = 0;
    while index + 8 < bytes.len() {
        if bytes[index..].starts_with(b"@hazard.") {
            let start = index + 8;
            let mut end = start;
            while end < bytes.len() && (bytes[end].is_ascii_alphanumeric() || bytes[end] == b'_') {
                end += 1;
            }
            if end > start {
                names.push(query[start..end].to_string());
            }
            index = end;
        } else {
            index += 1;
        }
    }
    names
}

/// Validate all policy/query invariants shared by FactMine, Lineage, and
/// SlopCop. JSON parsing is delegated to serde_json so UTF-8 and escaped
/// Unicode, including surrogate pairs, follow the JSON specification.
pub fn validate_contract() -> Result<(), String> {
    let contract = contract();
    if contract.version != 1 {
        return Err(format!(
            "unsupported hazard contract version {}",
            contract.version
        ));
    }

    let resource_names: BTreeSet<_> = QUERY_RESOURCES.iter().map(|(name, _)| *name).collect();
    let manifest_names: BTreeSet<_> = contract.queries.keys().map(String::as_str).collect();
    if resource_names != manifest_names {
        return Err(format!(
            "query resources and contract.queries differ: resources={resource_names:?}, manifest={manifest_names:?}"
        ));
    }

    let mut patterns = HashSet::new();
    for policy in &contract.policies {
        for (field, value) in [
            ("match", policy.pattern.as_str()),
            ("kind", policy.kind.as_str()),
            ("evidence_provider", policy.evidence_provider.as_str()),
            ("evidence_claim", policy.evidence_claim.as_str()),
            ("label", policy.label.as_str()),
            ("mitigation", policy.mitigation.as_str()),
        ] {
            if value.is_empty() {
                return Err(format!("policy field {field:?} must not be empty"));
            }
        }
        let Some(evidence) = contract.evidence.get(&policy.evidence_provider) else {
            return Err(format!(
                "policy {:?} uses unknown evidence provider {:?}",
                policy.pattern, policy.evidence_provider
            ));
        };
        if evidence.claim != policy.evidence_claim {
            return Err(format!(
                "policy {:?} claims {:?}, provider {:?} declares {:?}",
                policy.pattern, policy.evidence_claim, policy.evidence_provider, evidence.claim
            ));
        }
        if !patterns.insert(&policy.pattern) {
            return Err(format!("duplicate hazard policy {:?}", policy.pattern));
        }
    }

    if contract.matcher_vectors.is_empty() {
        return Err("contract.matcher_vectors must not be empty".to_string());
    }
    for vector in &contract.matcher_vectors {
        if glob_matches(&vector.pattern, &vector.value) != vector.matches {
            return Err(format!(
                "matcher vector disagrees with anchored glob semantics: {:?}",
                vector
            ));
        }
    }

    for (name, query) in QUERY_RESOURCES {
        let Some(query_path) = contract.queries.get(*name) else {
            return Err(format!("missing query manifest entry {name:?}"));
        };
        let expected_path = format!("queries/{name}_hazards.scm");
        if query_path != &expected_path {
            return Err(format!(
                "query manifest entry {name:?} points to {query_path:?}, expected {expected_path:?}"
            ));
        }
        let captures = query_hazard_names(query);
        if captures.is_empty() {
            return Err(format!("query {name:?} exports no hazard captures"));
        }
        for hazard in captures {
            let matches = contract
                .policies
                .iter()
                .filter(|policy| glob_matches(&policy.pattern, &hazard))
                .count();
            if matches != 1 {
                return Err(format!(
                    "hazard capture {hazard:?} matches {matches} policies; policy overlap is ambiguous"
                ));
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::proof_boundary::{
        build, ClaimStatus, CoverageDischarge, InputCompleteness, ProofBlocker, ProofScopeKind,
    };
    use super::{glob_matches, validate_contract};
    use jsonschema::JSONSchema;
    use serde_json::{json, Value};

    #[test]
    fn canonical_contract_is_valid_and_synchronized() {
        validate_contract().expect("canonical hazard contract must validate");
    }

    #[test]
    fn glob_matching_is_anchored() {
        assert!(glob_matches("go_race_*", "go_race_lock"));
        assert!(!glob_matches("go_race_*", "xgo_race_lock"));
        assert!(!glob_matches("*_metaprogramming", "metaprogramming"));
        assert!(glob_matches("*_vopr_*", "zig_vopr_time"));
        assert!(!glob_matches("*_vopr_*", "zig_vopr"));
    }

    #[test]
    fn proof_boundary_producer_vectors_conform_to_the_versioned_schema() {
        let schema: Value = serde_json::from_str(include_str!("../proof-boundary.v3.schema.json"))
            .expect("proof-boundary schema must be valid JSON");
        let validator = JSONSchema::compile(&schema).expect("proof-boundary schema must compile");
        let fixture: Value =
            serde_json::from_str(include_str!("../fixtures/proof-boundary.v3.json"))
                .expect("proof-boundary fixture must be valid JSON");

        let valid = fixture.get("valid").into_iter().chain(
            fixture
                .get("representative")
                .and_then(Value::as_object)
                .into_iter()
                .flat_map(|producers| producers.values()),
        );
        for boundary in valid {
            assert!(
                validator.is_valid(boundary),
                "representative boundary must satisfy v3 schema: {boundary}"
            );
        }
        assert!(
            !validator.is_valid(&fixture["invalid"]),
            "invalid vector must fail the v3 schema"
        );
    }

    #[test]
    fn proof_boundary_builder_normalizes_and_rejects_invalid_boundaries() {
        let boundary = build(
            InputCompleteness::Partial,
            ClaimStatus::Review,
            CoverageDischarge::Unsatisfiable,
            &[
                "nil_kill_static",
                "fact_mine_normalized_ast",
                "nil_kill_static",
            ],
            "static_nil_pressure",
            ProofScopeKind::Local,
            false,
            vec![
                ProofBlocker::unknown(),
                ProofBlocker::call_resolution("lib/example.rb", Some([3, 0, 3, 5])),
                ProofBlocker::unknown(),
            ],
        )
        .unwrap();
        assert_eq!(
            boundary["authority"],
            json!(["fact_mine_normalized_ast", "nil_kill_static"])
        );
        assert_eq!(
            boundary["blockers"],
            json!([
                {"kind":"call_resolution", "path":"lib/example.rb", "span":[3, 0, 3, 5]},
                {"kind":"unknown"}
            ])
        );

        assert!(build(
            InputCompleteness::Unknown,
            ClaimStatus::Review,
            CoverageDischarge::Unsatisfiable,
            &[],
            "static_nil_pressure",
            ProofScopeKind::Local,
            false,
            vec![],
        )
        .is_err());
        assert!(build(
            InputCompleteness::Unknown,
            ClaimStatus::Review,
            CoverageDischarge::Unsatisfiable,
            &[""],
            "static_nil_pressure",
            ProofScopeKind::Local,
            false,
            vec![],
        )
        .is_err());
        assert!(build(
            InputCompleteness::Unknown,
            ClaimStatus::Review,
            CoverageDischarge::Unsatisfiable,
            &["fact_mine_normalized_ast"],
            "",
            ProofScopeKind::Local,
            false,
            vec![],
        )
        .is_err());
        assert!(build(
            InputCompleteness::Partial,
            ClaimStatus::Review,
            CoverageDischarge::Unsatisfiable,
            &["fact_mine_normalized_ast"],
            "static_nil_pressure",
            ProofScopeKind::Local,
            false,
            vec![ProofBlocker::call_resolution("x.rb", Some([3, 2, 3, 1]))],
        )
        .is_err());
        assert!(build(
            InputCompleteness::Complete,
            ClaimStatus::Review,
            CoverageDischarge::Unsatisfiable,
            &["fact_mine_normalized_ast"],
            "static_nil_pressure",
            ProofScopeKind::Local,
            false,
            vec![ProofBlocker::unknown()],
        )
        .is_err());
        assert!(build(
            InputCompleteness::Partial,
            ClaimStatus::Review,
            CoverageDischarge::Unsatisfiable,
            &["fact_mine_normalized_ast"],
            "static_nil_pressure",
            ProofScopeKind::Local,
            false,
            vec![ProofBlocker::open_corpus()],
        )
        .is_err());
    }
}
