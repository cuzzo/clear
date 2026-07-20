use crate::syntax::{HazardSite, Language};
use crate::syntax::parser_grammar::grammar_for_language;
use tree_sitter::{Node, Query, QueryCursor};
use streaming_iterator::StreamingIterator;

const C_HAZARDS: &str = include_str!("c_hazards.scm");
const CPP_HAZARDS: &str = include_str!("cpp_hazards.scm");
const CSHARP_HAZARDS: &str = include_str!("csharp_hazards.scm");
const GO_HAZARDS: &str = include_str!("go_hazards.scm");
const RUST_HAZARDS: &str = include_str!("rust_hazards.scm");
const ZIG_HAZARDS: &str = include_str!("zig_hazards.scm");
const RUBY_HAZARDS: &str = include_str!("ruby_hazards.scm");
const PYTHON_HAZARDS: &str = include_str!("python_hazards.scm");

pub fn extract_hazards(
    file_path: &str,
    root: Node,
    source: &str,
    language: Language,
) -> Vec<HazardSite> {
    let source_bytes = source.as_bytes();
    let query_str = match language {
        Language::C => C_HAZARDS,
        Language::Cpp => CPP_HAZARDS,
        Language::CSharp => CSHARP_HAZARDS,
        Language::Go => GO_HAZARDS,
        Language::Rust => RUST_HAZARDS,
        Language::Zig => ZIG_HAZARDS,
        Language::Ruby => RUBY_HAZARDS,
        Language::Python => PYTHON_HAZARDS,
        _ => return Vec::new(),
    };

    let grammar = grammar_for_language(language);
    let query = Query::new(&grammar, query_str).unwrap();

    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(&query, root, source_bytes);
    
    let mut sites = Vec::new();
    let mut recorded_lines = std::collections::HashSet::new();

    while let Some(m) = matches.next() {
        for cap in m.captures {
            let capture_name = query.capture_names()[cap.index as usize];
            
            // In lineage, hazard tags look like `@hazard.zig_loom_atomic`
            // Tree-sitter drops the `@`, so it's `hazard.zig_loom_atomic`
            if !capture_name.starts_with("hazard.") {
                continue;
            }
            
            let hazard_type = capture_name.strip_prefix("hazard.").unwrap().to_string();
            
            let line = (cap.node.start_position().row + 1) as u32;
            let line_text = source
                .lines()
                .nth((line as usize).saturating_sub(1))
                .unwrap_or_default()
                .trim()
                .to_string();

            let required_evidence = if hazard_type.contains("_vopr_") {
                "vopr".to_string()
            } else if hazard_type.contains("_loom_") {
                "loom".to_string()
            } else if hazard_type.contains("_wait_loop") {
                "hammer".to_string()
            } else {
                "".to_string()
            };

            let dedupe_key = (line, hazard_type.clone());
            if !recorded_lines.contains(&dedupe_key) {
                recorded_lines.insert(dedupe_key);
                sites.push(HazardSite {
                    path: file_path.to_string(),
                    line,
                    snippet: line_text,
                    hazard_type,
                    required_evidence,
                });
            }
        }
    }
    
    // Sort to keep deterministic order
    sites.sort_by_key(|s| (s.line, s.hazard_type.clone()));
    sites
}

#[cfg(test)]
mod tests {
    use super::*;
    use tree_sitter::Parser;

    #[test]
    fn test_extract_hazards() {
        let code = "
            const std = @import(\"std\");
            pub fn main() void {
                var atomic = std.atomic.Atomic(u32).init(0);
                _ = atomic.load(.Acquire);
            }
        ";
        let mut parser = Parser::new();
        parser.set_language(&grammar_for_language(Language::Zig)).unwrap();
        let tree = parser.parse(code, None).unwrap();
        
        let hazards = extract_hazards("test.zig", tree.root_node(), code, Language::Zig);
        assert_eq!(hazards.len(), 1);
        assert_eq!(hazards[0].hazard_type, "zig_loom_atomic");
        assert_eq!(hazards[0].required_evidence, "loom");
        assert_eq!(hazards[0].line, 5);
        assert_eq!(hazards[0].snippet, "_ = atomic.load(.Acquire);");
    }

    #[test]
    fn test_extract_hazards_rust() {
        let code = "
            fn main() {
                unsafe {
                    let mut x = 5;
                }
                while true {
                    std::thread::yield_now();
                }
            }
        ";
        let mut parser = Parser::new();
        parser.set_language(&grammar_for_language(Language::Rust)).unwrap();
        let tree = parser.parse(code, None).unwrap();
        
        let hazards = extract_hazards("test.rs", tree.root_node(), code, Language::Rust);
        assert!(!hazards.is_empty());
        let unsafe_hazard = hazards.iter().find(|h| h.hazard_type == "rust_unsafe_block").unwrap();
        assert_eq!(unsafe_hazard.required_evidence, "");
        assert_eq!(unsafe_hazard.snippet, "unsafe {");
    }

    #[test]
    fn test_extract_hazards_ruby() {
        let code = "
            class Foo
              def test
                send(:hello)
                self.send(:hello2)
                instance_variable_get(:@x)
                const_get(:BAR)
              end
              def method_missing(m, *args)
              end
            end
        ";
        let mut parser = Parser::new();
        parser.set_language(&grammar_for_language(Language::Ruby)).unwrap();
        let tree = parser.parse(code, None).unwrap();
        
        let hazards = extract_hazards("test.rb", tree.root_node(), code, Language::Ruby);
        assert_eq!(hazards.len(), 5);
        assert!(hazards.iter().all(|h| h.hazard_type == "ruby_metaprogramming"));
        
        let snippets: Vec<&str> = hazards.iter().map(|h| h.snippet.as_str()).collect();
        assert!(snippets.contains(&"send(:hello)"));
        assert!(snippets.contains(&"self.send(:hello2)"));
        assert!(snippets.contains(&"instance_variable_get(:@x)"));
        assert!(snippets.contains(&"const_get(:BAR)"));
        assert!(snippets.contains(&"def method_missing(m, *args)"));
    }

    #[test]
    fn test_extract_hazards_python() {
        let code = "
class Foo:
    def __getattr__(self, name):
        return getattr(self, '_' + name)
    def test(self):
        setattr(self, 'x', 1)
        eval('1 + 1')
        exec('import os')
        type('Bar', (), {})
        type(self)
        ";
        let mut parser = Parser::new();
        parser.set_language(&grammar_for_language(Language::Python)).unwrap();
        let tree = parser.parse(code, None).unwrap();
        
        let hazards = extract_hazards("test.py", tree.root_node(), code, Language::Python);
        assert_eq!(hazards.len(), 6);
        assert!(hazards.iter().all(|h| h.hazard_type == "python_metaprogramming"));
        
        let snippets: Vec<&str> = hazards.iter().map(|h| h.snippet.as_str()).collect();
        assert!(snippets.contains(&"def __getattr__(self, name):"));
        assert!(snippets.contains(&"return getattr(self, '_' + name)"));
        assert!(snippets.contains(&"setattr(self, 'x', 1)"));
        assert!(snippets.contains(&"eval('1 + 1')"));
        assert!(snippets.contains(&"exec('import os')"));
        assert!(snippets.contains(&"type('Bar', (), {})"));
        assert!(!snippets.contains(&"type(self)"));
    }
}
