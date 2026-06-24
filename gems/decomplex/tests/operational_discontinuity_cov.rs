use decomplex_rust::decomplex::detectors::operational_discontinuity;
use decomplex_rust::decomplex::syntax::Document;
use serde_json::json;

#[test]
fn test_operational_discontinuity_coverage() {
    // 1. Create a Document with a method that gets filtered out due to score < 12 (score = 11)
    // dead = 2, new = 2, continuing = 1. score = 2+2-1+8 = 11.
    let doc_low_score: Document = serde_json::from_value(json!({
        "file": "a.rb",
        "language": "ruby",
        "local_methods": [
            {
                "id": "m1",
                "owner": "Class",
                "name": "low_score_method",
                "file": "a.rb",
                "line": 10,
                "span": [10, 1, 15, 1],
                "statements": [
                    {
                        "index": 0, "line": 10, "end_line": 10, "span": [10, 1, 10, 10], "source": "x",
                        "reads": ["d1", "d2", "c"], "writes": [], "dependencies": [], "co_uses": []
                    },
                    {
                        "index": 1, "line": 11, "end_line": 11, "span": [11, 1, 11, 10], "source": "x",
                        "reads": ["d1", "d2", "c"], "writes": [], "dependencies": [], "co_uses": []
                    },
                    {
                        "index": 3, "line": 13, "end_line": 13, "span": [13, 1, 13, 10], "source": "x",
                        "reads": ["n1", "n2", "c"], "writes": [], "dependencies": [], "co_uses": []
                    }
                ],
                "boundaries": [
                    {
                        "before_index": 1,
                        "after_index": 3,
                        "line": 12,
                        "kind": "comment",
                        "text": "# Step 1"
                    }
                ]
            }
        ]
    })).unwrap();

    let report = operational_discontinuity::scan_documents(&[doc_low_score]);
    assert!(report.is_empty());

    // 2. Create multiple documents to test sorting and confidence categories
    // Method A: score = 12 (review)
    // Method B: score = 20 (high_score, parse method -> reasons filtered)
    // Method C: repeated resets, phase marker -> score = 24
    let doc_main: Document = serde_json::from_value(json!({
        "file": "a.rb",
        "language": "ruby",
        "local_methods": [
            {
                "id": "mA",
                "owner": "Class",
                "name": "method_a",
                "file": "a.rb",
                "line": 10,
                "span": [10, 1, 15, 1],
                "statements": [
                    {
                        "index": 0, "line": 10, "end_line": 10, "span": [10, 1, 10, 10], "source": "x",
                        "reads": ["d1", "d2"], "writes": [], "dependencies": [], "co_uses": []
                    },
                    {
                        "index": 2, "line": 12, "end_line": 12, "span": [12, 1, 12, 10], "source": "x",
                        "reads": ["n1", "n2"], "writes": [], "dependencies": [], "co_uses": []
                    }
                ],
                "boundaries": [
                    {
                        "before_index": 0,
                        "after_index": 2,
                        "line": 11,
                        "kind": "comment",
                        "text": "normal comment"
                    }
                ]
            },
            {
                "id": "mB",
                "owner": "Class",
                "name": "parse_method", // starts with parse, checks retain branch on line 168
                "file": "a.rb",
                "line": 20,
                "span": [20, 1, 25, 1],
                "statements": [
                    {
                        "index": 0, "line": 20, "end_line": 20, "span": [20, 1, 20, 10], "source": "x",
                        "reads": ["d1", "d2", "d3", "d4", "d5", "d6"], "writes": [], "dependencies": [], "co_uses": []
                    },
                    {
                        "index": 2, "line": 22, "end_line": 22, "span": [22, 1, 22, 10], "source": "x",
                        "reads": ["n1", "n2", "n3", "n4", "n5", "n6"], "writes": [], "dependencies": [], "co_uses": []
                    }
                ],
                "boundaries": [
                    {
                        "before_index": 0,
                        "after_index": 2,
                        "line": 21,
                        "kind": "comment",
                        "text": "normal comment" // explicit_phase is false
                    }
                ]
            }
        ]
    })).unwrap();

    let doc_main2: Document = serde_json::from_value(json!({
        "file": "b.rb",
        "language": "ruby",
        "local_methods": [
            {
                "id": "mC",
                "owner": "Class",
                "name": "method_c",
                "file": "b.rb",
                "line": 10,
                "span": [10, 1, 15, 1],
                "statements": [
                    {
                        "index": 0, "line": 10, "end_line": 10, "span": [10, 1, 10, 10], "source": "x",
                        "reads": ["a1", "a2"], "writes": [], "dependencies": [], "co_uses": []
                    },
                    {
                        "index": 2, "line": 12, "end_line": 12, "span": [12, 1, 12, 10], "source": "x",
                        "reads": ["b1", "b2"], "writes": [], "dependencies": [], "co_uses": []
                    },
                    {
                        "index": 4, "line": 14, "end_line": 14, "span": [14, 1, 14, 10], "source": "x",
                        "reads": ["c1", "c2"], "writes": [], "dependencies": [], "co_uses": []
                    }
                ],
                "boundaries": [
                    {
                        "before_index": 0,
                        "after_index": 2,
                        "line": 11,
                        "kind": "comment",
                        "text": "# 1. First Phase" // matches phase_marker
                    },
                    {
                        "before_index": 2,
                        "after_index": 4,
                        "line": 13,
                        "kind": "comment",
                        "text": "# Step 2" // matches phase_marker
                    }
                ]
            }
        ]
    })).unwrap();

    let report = operational_discontinuity::scan_documents(&[doc_main, doc_main2]);
    assert_eq!(report.len(), 3);

    // Sorting check: b.rb:method_c has 2 resets, score = 28.
    // parse_method has score = 20.
    // method_a has score = 12.
    assert_eq!(report[0].defn, "method_c");
    assert_eq!(report[0].score, 28);
    assert_eq!(report[0].confidence, "high");
    assert!(report[0].confidence_reasons.contains(&"repeated_resets".to_string()));
    assert!(report[0].confidence_reasons.contains(&"explicit_phase_marker".to_string()));
    assert!(report[0].confidence_reasons.contains(&"high_score".to_string()));

    assert_eq!(report[1].defn, "parse_method");
    assert_eq!(report[1].score, 20);
    // high_score should have been retained but grammar_method cleans it up since explicit_phase is false
    assert!(report[1].confidence_reasons.is_empty());
    assert_eq!(report[1].confidence, "review");

    assert_eq!(report[2].defn, "method_a");
    assert_eq!(report[2].score, 12);
    assert_eq!(report[2].confidence, "review");
}
