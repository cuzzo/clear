//! The collector's C rules are the oracle: whatever it derives today is what
//! this port has to keep deriving.
//!
//! The corpus is one ordered sequence, not a set of independent cases. A
//! collection's shape is remembered against the classes it was carrying, so a
//! later answer depends on the earlier ones -- which means the port has to be
//! fed the same observations in the same order and rebuild the same memo.

use fact_mine_rust::value_domain::{DomainDeriver, RawObservation};
use serde::Deserialize;
use std::path::Path;

#[derive(Deserialize)]
struct Pair {
    #[serde(rename = "case")]
    label: String,
    raw: RawObservation,
    domain: serde_json::Value,
}

struct Corpus {
    pairs: Vec<Pair>,
}

/// One pair per line, so a re-recorded case is a one-line diff rather than a
/// two-hundred-line block of reindented JSON.
fn corpus() -> Corpus {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../nil-kill/spec/fixtures/value_domain_parity.jsonl");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    let pairs = text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).expect("parity pair"))
        .collect();
    Corpus { pairs }
}

#[test]
fn derives_every_recorded_domain_from_the_raw_observation_alone() {
    let corpus = corpus();
    // No source roles are configured for the corpus, so nothing is
    // non-production; the verdict is still recorded wherever a class had a
    // declaring file, and absent where it had none.
    let mut deriver = DomainDeriver::new(Vec::new());
    // A corpus that failed to load would pass this test by describing nothing.
    assert_eq!(corpus.pairs.len(), 53, "parity corpus size");
    assert!(
        corpus.pairs.iter().any(|pair| !pair.domain["shapes"].as_array().unwrap().is_empty()),
        "corpus must contain shaped values"
    );
    let mut mismatches = Vec::new();
    for pair in &corpus.pairs {
        let derived = deriver.derive(&pair.raw).to_value();
        if derived != pair.domain {
            mismatches.push(format!(
                "{}\n  collector {}\n  derived   {}",
                pair.label,
                serde_json::to_string(&pair.domain).unwrap(),
                serde_json::to_string(&derived).unwrap()
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "{} of {} cases diverge from the collector:\n{}",
        mismatches.len(),
        corpus.pairs.len(),
        mismatches.iter().take(6).cloned().collect::<Vec<_>>().join("\n")
    );
}

/// The tuple rule, on the same corpus. A fixed-length mixed array is a tuple; a
/// long uniform one is an array and nothing else.
#[test]
fn recognizes_a_tuple_only_where_the_collector_would() {
    use fact_mine_rust::value_domain::tuple_of;

    let corpus = corpus();
    let named = |label: &str| {
        corpus.pairs.iter().find(|pair| pair.label == label).expect("case").raw.clone()
    };

    // Complete, uniform: still a tuple. Every position was observed, so the
    // length is a fact about the value even where the classes agree.
    let uniform = tuple_of(&named("integer array"), 20).expect("complete uniform is a tuple");
    assert_eq!(uniform.types, vec!["Integer", "Integer", "Integer"]);
    assert!(uniform.complete && !uniform.mixed);
    // Mixed and complete: each position has to be spelled out.
    let mixed = tuple_of(&named("mixed array"), 20).expect("mixed array is a tuple");
    assert_eq!(mixed.types, vec!["Integer", "String", "Symbol"]);
    assert_eq!(mixed.size, "3");
    assert!(mixed.complete && mixed.mixed);
    // Longer than the sample and uniform: not a tuple. The tail went
    // unobserved, and the head says nothing the element type does not.
    assert!(tuple_of(&named("oversampled strings"), 20).is_none());
    assert!(tuple_of(&named("oversampled array"), 20).is_none());
    // Longer than the sample but already disagreeing: a tuple of unknown
    // length, because the positions observed cannot be one element type.
    let long = tuple_of(&named("long mixed array"), 20).expect("incomplete mixed is a tuple");
    assert_eq!(long.size, ">=20");
    assert!(!long.complete && long.mixed);
    // Only arrays. A hash of the same contents is a mapping.
    assert!(tuple_of(&named("string hash"), 20).is_none());
    assert!(tuple_of(&named("empty array"), 20).is_none());
}
