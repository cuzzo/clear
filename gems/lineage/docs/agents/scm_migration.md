# Epic: Migrate to Declarative Tree-Sitter Query Files (.scm)

This epic covers migrating Lineage's language-specific AST parsing and hazard-scanning heuristics to declarative Tree-Sitter query (`.scm`) files. This removes the complex, fragile, and hard-to-maintain language-specific Rust logic in [extract.rs](file:///home/yahn/litedb/gems/lineage/src/db/extract.rs) and [hazard.rs](file:///home/yahn/litedb/gems/lineage/src/db/hazard.rs).

---

## 1. Unified SCM Schema

Every language query file uses a standardized set of captures that the agnostic Rust runner maps directly to domain models.

### A. Logical Unit Captures (`tags.scm`)
*   `@definition.class` -> Maps to `UnitKind::Class`.
*   `@definition.function` -> Maps to `UnitKind::Function`.
*   `@definition.module` -> Maps to `UnitKind::Module`.
*   `@name` -> Identifies the specific node containing the logical unit's identifier.

### B. Hazard Captures (`hazards.scm`)
Captures match `@hazard.<hazard_type>`, which maps directly to the hazard event name:
*   `@hazard.go_race_goroutine`
*   `@hazard.rust_unsafe_block`
*   `@hazard.zig_unsafe_memory`
*   (and all other hazards defined in [hazard.rs](file:///home/yahn/litedb/gems/lineage/src/db/hazard.rs)).

---

## 2. Refactoring the Rust Query Runner

### Logical Unit Extraction
The current manual recursion is replaced with a single query matcher:

```rust
pub fn extract_via_query(
    language: tree_sitter::Language,
    query_str: &str,
    source: &str,
) -> Result<Vec<Candidate>> {
    let mut parser = Parser::new();
    parser.set_language(&language)?;
    let tree = parser.parse(source, None)
        .ok_or_else(|| anyhow::anyhow!("Failed to parse source"))?;
    
    let query = Query::new(&language, query_str)?;
    let mut cursor = QueryCursor::new();
    
    let mut candidates = Vec::new();
    for m in cursor.matches(&query, tree.root_node(), source.as_bytes()) {
        let mut kind = None;
        let mut name = String::new();
        let mut primary_node = None;

        for capture in m.captures {
            let capture_name = query.capture_names()[capture.index as usize];
            match capture_name {
                "definition.class" => {
                    kind = Some(UnitKind::Class);
                    primary_node = Some(capture.node);
                }
                "definition.function" => {
                    kind = Some(UnitKind::Function);
                    primary_node = Some(capture.node);
                }
                "definition.module" => {
                    kind = Some(UnitKind::Module);
                    primary_node = Some(capture.node);
                }
                "name" => {
                    name = capture.node.utf8_text(source.as_bytes())?.to_string();
                }
                _ => {}
            }
        }

        if let (Some(k), Some(n)) = (kind, primary_node) {
            candidates.push(Candidate {
                name,
                kind: k,
                signature: n.utf8_text(source.as_bytes())?.to_string(),
                line: (n.start_position().row + 1) as u32,
                end_line: Some((n.end_position().row + 1) as u32),
            });
        }
    }
    Ok(candidates)
}
```

---

## 3. Testing Strategy for Query Files

To ensure queries remain correct when grammars or syntaxes change, we write automated unit tests that run query assets against representative code fixtures and assert captures.

### Example Query Unit Test
We test queries by loading the language, compiling the query string, parsing a source snippet, and asserting that the expected number of matches and capture tags are found.

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tree_sitter::{Language, Parser, Query, QueryCursor};

    fn test_helper(
        lang: Language,
        query_text: &str,
        source: &str,
        expected_captures: &[(&str, &str)],
    ) {
        let mut parser = Parser::new();
        parser.set_language(&lang).unwrap();
        let tree = parser.parse(source, None).unwrap();
        let query = Query::new(&lang, query_text).unwrap();
        let mut cursor = QueryCursor::new();

        let mut actual = Vec::new();
        for m in cursor.matches(&query, tree.root_node(), source.as_bytes()) {
            for capture in m.captures {
                let name = query.capture_names()[capture.index as usize];
                let text = capture.node.utf8_text(source.as_bytes()).unwrap();
                actual.push((name, text));
            }
        }

        assert_eq!(actual.len(), expected_captures.len());
        for (i, expected) in expected_captures.iter().enumerate() {
            assert_eq!(actual[i].0, expected.0); // Capture name
            assert_eq!(actual[i].1, expected.1); // Captured text snippet
        }
    }

    #[test]
    fn test_python_logical_units() {
        let query = r#"
            (class_definition
              name: (identifier) @name) @definition.class
            (function_definition
              name: (identifier) @name) @definition.function
        "#;
        let source = "class Foo:\n    def bar(self):\n        pass\n";
        test_helper(
            tree_sitter_python::LANGUAGE.into(),
            query,
            source,
            &[
                ("definition.class", "class Foo:\n    def bar(self):\n        pass\n"),
                ("name", "Foo"),
                ("definition.function", "def bar(self):\n        pass\n"),
                ("name", "bar"),
            ],
        );
    }
}
```

---

## 4. Implementation Steps

1.  **Define Embedded Assets / Direct Paths**: Embed `.scm` query assets into the binary or establish a configuration path (e.g. `queries/`).
2.  **Rewrite [extract.rs](file:///home/yahn/litedb/gems/lineage/src/db/extract.rs)**: Re-route `tree_sitter_candidates` to call the new agnostic query runner.
3.  **Rewrite [hazard.rs](file:///home/yahn/litedb/gems/lineage/src/db/hazard.rs)**: Map the hazard scanning functions to the language-agnostic hazard query runner.
4.  **Validate Tests & Coverage**: Ensure all existing tests in `gems/lineage/` pass and check that Rust's test coverage in `src/db/` remains above 95%.
