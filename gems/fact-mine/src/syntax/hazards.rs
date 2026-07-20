use std::sync::OnceLock;
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
const JAVASCRIPT_HAZARDS: &str = include_str!("javascript_hazards.scm");
const TYPESCRIPT_HAZARDS: &str = include_str!("typescript_hazards.scm");
const LUA_HAZARDS: &str = include_str!("lua_hazards.scm");
const JAVA_HAZARDS: &str = include_str!("java_hazards.scm");
const PHP_HAZARDS: &str = include_str!("php_hazards.scm");
const KOTLIN_HAZARDS: &str = include_str!("kotlin_hazards.scm");
const SWIFT_HAZARDS: &str = include_str!("swift_hazards.scm");

fn get_cached_query(language: Language) -> Option<&'static Query> {
    macro_rules! cached_query {
        ($lang:expr, $query_str:expr) => {{
            static CACHE: OnceLock<Option<Query>> = OnceLock::new();
            CACHE.get_or_init(|| {
                let grammar = grammar_for_language($lang);
                Query::new(&grammar, $query_str).ok()
            }).as_ref()
        }};
    }

    match language {
        Language::C => cached_query!(Language::C, C_HAZARDS),
        Language::Cpp => cached_query!(Language::Cpp, CPP_HAZARDS),
        Language::CSharp => cached_query!(Language::CSharp, CSHARP_HAZARDS),
        Language::Go => cached_query!(Language::Go, GO_HAZARDS),
        Language::Rust => cached_query!(Language::Rust, RUST_HAZARDS),
        Language::Zig => cached_query!(Language::Zig, ZIG_HAZARDS),
        Language::Ruby => cached_query!(Language::Ruby, RUBY_HAZARDS),
        Language::Python => cached_query!(Language::Python, PYTHON_HAZARDS),
        Language::JavaScript => cached_query!(Language::JavaScript, JAVASCRIPT_HAZARDS),
        Language::TypeScript => cached_query!(Language::TypeScript, TYPESCRIPT_HAZARDS),
        Language::Lua => cached_query!(Language::Lua, LUA_HAZARDS),
        Language::Java => cached_query!(Language::Java, JAVA_HAZARDS),
        Language::Php => cached_query!(Language::Php, PHP_HAZARDS),
        Language::Kotlin => cached_query!(Language::Kotlin, KOTLIN_HAZARDS),
        Language::Swift => cached_query!(Language::Swift, SWIFT_HAZARDS),
        _ => None,
    }
}

pub(crate) fn extract_hazards(
    file_path: &str,
    root: Node,
    source: &str,
    language: Language,
) -> Vec<HazardSite> {
    let query = match get_cached_query(language) {
        Some(q) => q,
        None => return Vec::new(),
    };

    let source_bytes = source.as_bytes();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(query, root, source_bytes);
    
    let mut sites = Vec::new();
    let mut recorded_lines = std::collections::HashSet::new();

    let source_lines: Vec<&str> = source.lines().collect();

    while let Some(m) = matches.next() {
        for cap in m.captures {
            let capture_name = query.capture_names()[cap.index as usize];
            
            if !capture_name.starts_with("hazard.") {
                continue;
            }
            
            let hazard_type = capture_name.strip_prefix("hazard.").unwrap_or("").to_string();
            
            let line = (cap.node.start_position().row + 1) as u32;
            let line_text = source_lines
                .get((line as usize).saturating_sub(1))
                .unwrap_or(&"")
                .trim()
                .to_string();

            let required_evidence = if hazard_type.contains("_vopr_") {
                "vopr".to_string()
            } else if hazard_type.contains("_loom_") {
                "loom".to_string()
            } else if hazard_type.contains("_wait_loop") {
                "hammer".to_string()
            } else if hazard_type.contains("_metaprogramming") {
                "nil-kill".to_string()
            } else {
                "".to_string()
            };

            let start_col = cap.node.start_position().column as u32;
            let end_line = (cap.node.end_position().row + 1) as u32;
            let end_col = cap.node.end_position().column as u32;

            let dedupe_key = (line, start_col, end_line, end_col, hazard_type.clone());
            if !recorded_lines.contains(&dedupe_key) {
                recorded_lines.insert(dedupe_key);
                sites.push(HazardSite {
                    path: file_path.to_string(),
                    line,
                    snippet: line_text,
                    hazard_type,
                    required_evidence,
                    start_column: Some(start_col),
                    end_line: Some(end_line),
                    end_column: Some(end_col),
                });
            }
        }
    }
    
    sites.sort_by_key(|s| (s.line, s.start_column, s.end_line, s.end_column, s.hazard_type.clone()));
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
                $1
                $~
                $&
                $+
              end
              def method_missing(m, *args)
              end
            end
        ";
        let mut parser = Parser::new();
        parser.set_language(&grammar_for_language(Language::Ruby)).unwrap();
        let tree = parser.parse(code, None).unwrap();
        
        let hazards = extract_hazards("test.rb", tree.root_node(), code, Language::Ruby);
        assert_eq!(hazards.len(), 9);
        assert!(hazards.iter().all(|h| h.hazard_type == "ruby_metaprogramming"));
        
        let snippets: Vec<&str> = hazards.iter().map(|h| h.snippet.as_str()).collect();
        assert!(snippets.contains(&"send(:hello)"));
        assert!(snippets.contains(&"self.send(:hello2)"));
        assert!(snippets.contains(&"instance_variable_get(:@x)"));
        assert!(snippets.contains(&"const_get(:BAR)"));
        assert!(snippets.contains(&"def method_missing(m, *args)"));
        assert!(snippets.contains(&"$1"));
        assert!(snippets.contains(&"$~"));
        assert!(snippets.contains(&"$&"));
        assert!(snippets.contains(&"$+"));
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

    #[test]
    fn test_extract_hazards_javascript() {
        let code = "
eval('1 + 1');
new Function('a', 'b', 'return a + b');
new Proxy(target, {
  get: function(obj, prop) {
    return obj[prop];
  }
});
Reflect.get(obj, 'prop');
Reflect.set(obj, 'prop', 1);
Reflect.apply(func, thisArg, args);
RegExp.$1;
        ";
        let mut parser = Parser::new();
        parser.set_language(&grammar_for_language(Language::JavaScript)).unwrap();
        let tree = parser.parse(code, None).unwrap();
        
        let hazards = extract_hazards("test.js", tree.root_node(), code, Language::JavaScript);
        assert_eq!(hazards.len(), 7);
        assert!(hazards.iter().all(|h| h.hazard_type == "javascript_metaprogramming"));
        
        let snippets: Vec<&str> = hazards.iter().map(|h| h.snippet.as_str()).collect();
        assert!(snippets.contains(&"eval('1 + 1');"));
        assert!(snippets.contains(&"new Function('a', 'b', 'return a + b');"));
        assert!(snippets.contains(&"new Proxy(target, {"));
        assert!(snippets.contains(&"Reflect.get(obj, 'prop');"));
        assert!(snippets.contains(&"Reflect.set(obj, 'prop', 1);"));
        assert!(snippets.contains(&"Reflect.apply(func, thisArg, args);"));
        assert!(snippets.contains(&"RegExp.$1;"));
    }

    #[test]
    fn test_extract_hazards_typescript() {
        let code = "
eval('1 + 1');
new Function('a', 'b', 'return a + b');
new Proxy(target, {
  get: function(obj, prop) {
    return obj[prop];
  }
});
Reflect.get(obj, 'prop');
Reflect.set(obj, 'prop', 1);
Reflect.apply(func, thisArg, args);
RegExp.$2;
        ";
        let mut parser = Parser::new();
        parser.set_language(&grammar_for_language(Language::TypeScript)).unwrap();
        let tree = parser.parse(code, None).unwrap();
        
        let hazards = extract_hazards("test.ts", tree.root_node(), code, Language::TypeScript);
        assert_eq!(hazards.len(), 7);
        assert!(hazards.iter().all(|h| h.hazard_type == "typescript_metaprogramming"));
    }

    #[test]
    fn test_extract_hazards_lua() {
        let code = "
load('x = 1')
loadstring('y = 2')
loadfile('test.lua')
dofile('test.lua')
setmetatable(t, mt)
getmetatable(t)
rawget(t, k)
rawset(t, k, v)
rawequal(a, b)
local mt = {
  __index = function(t, k) return rawget(t, k) end,
  __newindex = function(t, k, v) rawset(t, k, v) end,
  __call = function() end
}
        ";
        let mut parser = Parser::new();
        parser.set_language(&grammar_for_language(Language::Lua)).unwrap();
        let tree = parser.parse(code, None).unwrap();
        
        let hazards = extract_hazards("test.lua", tree.root_node(), code, Language::Lua);
        assert_eq!(hazards.len(), 14);
        assert!(hazards.iter().all(|h| h.hazard_type == "lua_metaprogramming"));
        
        let snippets: Vec<&str> = hazards.iter().map(|h| h.snippet.as_str()).collect();
        assert!(snippets.contains(&"load('x = 1')"));
        assert!(snippets.contains(&"loadstring('y = 2')"));
        assert!(snippets.contains(&"loadfile('test.lua')"));
        assert!(snippets.contains(&"dofile('test.lua')"));
        assert!(snippets.contains(&"setmetatable(t, mt)"));
        assert!(snippets.contains(&"getmetatable(t)"));
        assert!(snippets.contains(&"rawget(t, k)"));
        assert!(snippets.contains(&"rawset(t, k, v)"));
        assert!(snippets.contains(&"rawequal(a, b)"));
        assert!(snippets.contains(&"__index = function(t, k) return rawget(t, k) end,"));
        assert!(snippets.contains(&"__newindex = function(t, k, v) rawset(t, k, v) end,"));
        assert!(snippets.contains(&"__call = function() end"));
    }

    #[test]
    fn test_extract_hazards_java() {
        let code = "
            class Foo {
                void test() throws Exception {
                    Class.forName(\"Bar\");
                    Foo.class.getMethod(\"test\");
                }
            }
        ";
        let mut parser = Parser::new();
        parser.set_language(&grammar_for_language(Language::Java)).unwrap();
        let tree = parser.parse(code, None).unwrap();
        
        let hazards = extract_hazards("test.java", tree.root_node(), code, Language::Java);
        assert_eq!(hazards.len(), 2);
        assert!(hazards.iter().all(|h| h.hazard_type == "java_metaprogramming"));
    }

    #[test]
    fn test_extract_hazards_php() {
        let code = "<?php
            eval('1+1');
            $f = 'bar';
            $$f = 1;
            class B {
                function __get($name) {}
            }
        ";
        let mut parser = Parser::new();
        parser.set_language(&grammar_for_language(Language::Php)).unwrap();
        let tree = parser.parse(code, None).unwrap();
        
        let hazards = extract_hazards("test.php", tree.root_node(), code, Language::Php);
        assert_eq!(hazards.len(), 3);
        assert!(hazards.iter().all(|h| h.hazard_type == "php_metaprogramming"));
    }

    #[test]
    fn test_extract_hazards_csharp_metaprogramming() {
        let code = "
            class Foo {
                void Test() {
                    System.Type.GetType(\"Bar\");
                    dynamic x = 1;
                }
            }
        ";
        let mut parser = Parser::new();
        parser.set_language(&grammar_for_language(Language::CSharp)).unwrap();
        let tree = parser.parse(code, None).unwrap();
        
        let hazards = extract_hazards("test.cs", tree.root_node(), code, Language::CSharp);
        let metaprog_hazards: Vec<_> = hazards.iter().filter(|h| h.hazard_type == "csharp_metaprogramming").collect();
        assert_eq!(metaprog_hazards.len(), 2);
    }

    #[test]
    fn test_extract_hazards_kotlin() {
        let code = "
            fun test() {
                Class.forName(\"Bar\")
                val prop = Foo::class.memberProperties
            }
        ";
        let mut parser = Parser::new();
        parser.set_language(&grammar_for_language(Language::Kotlin)).unwrap();
        let tree = parser.parse(code, None).unwrap();
        
        let hazards = extract_hazards("test.kt", tree.root_node(), code, Language::Kotlin);
        assert_eq!(hazards.len(), 2);
        assert!(hazards.iter().all(|h| h.hazard_type == "kotlin_metaprogramming"));
    }

    #[test]
    fn test_extract_hazards_swift() {
        let code = "
            func test() {
                let m = Mirror(reflecting: self)
                let c = NSClassFromString(\"Bar\")
            }
        ";
        let mut parser = Parser::new();
        parser.set_language(&grammar_for_language(Language::Swift)).unwrap();
        let tree = parser.parse(code, None).unwrap();
        
        let hazards = extract_hazards("test.swift", tree.root_node(), code, Language::Swift);
        assert_eq!(hazards.len(), 2);
        assert!(hazards.iter().all(|h| h.hazard_type == "swift_metaprogramming"));
    }
}
