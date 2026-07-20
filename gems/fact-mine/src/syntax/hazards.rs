use std::sync::OnceLock;
use crate::syntax::{HazardSite, Language, Document};
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
                let q = Query::new(&grammar, $query_str)
                    .unwrap_or_else(|e| panic!("Failed to compile bundled tree-sitter query for {:?}: {}", $lang, e));
                Some(q)
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
                    provider: language.as_str().to_string(),
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

fn supports_interfaces(language: Language) -> bool {
    matches!(
        language,
        Language::Java
            | Language::Kotlin
            | Language::TypeScript
            | Language::CSharp
            | Language::Go
            | Language::Rust
            | Language::Swift
    )
}

fn is_cb_name(s: &str) -> bool {
    let s_lower = s.to_lowercase();
    s_lower == "cb"
        || s_lower == "fp"
        || s_lower == "fn"
        || s_lower == "func"
        || s_lower.ends_with("_cb")
        || s_lower.ends_with("_fp")
        || s_lower.ends_with("_fn")
        || s_lower.ends_with("_func")
        || s_lower.contains("callback")
        || s_lower.contains("listener")
        || s_lower.contains("handler")
        || s_lower.contains("observer")
        || s_lower.contains("executor")
        || s_lower.contains("consumer")
        || s_lower.contains("supplier")
        || s_lower.contains("predicate")
        || s_lower.contains("runnable")
        || s_lower.contains("callable")
}

fn is_cb_type(s: &str) -> bool {
    let s_lower = s.to_lowercase();
    s_lower.contains("callback")
        || s_lower.contains("listener")
        || s_lower.contains("handler")
        || s_lower.contains("observer")
        || s_lower.contains("executor")
        || s_lower.contains("consumer")
        || s_lower.contains("supplier")
        || s_lower.contains("predicate")
        || s_lower.contains("runnable")
        || s_lower.contains("callable")
        || s_lower == "fn"
        || s_lower == "func"
        || s_lower == "function"
        || s_lower.starts_with("fn(")
        || s_lower.starts_with("fn ")
        || s_lower.ends_with("_fn")
        || s_lower.ends_with("_func")
        || s_lower.contains("->")
        || s_lower.contains("=>")
}

fn is_callback_type_or_name(name: &str, type_str: Option<&str>, language: Language) -> bool {
    if !supports_interfaces(language) {
        return false;
    }

    if is_cb_name(name) {
        return true;
    }
    if let Some(t) = type_str {
        if is_cb_type(t) {
            return true;
        }
    }
    false
}

pub fn detect_and_append_callback_hazards(document: &mut Document) {
    let mut callback_hazards = Vec::new();
    
    let mut fn_map = std::collections::HashMap::new();
    for f in &document.function_defs {
        fn_map.insert((f.owner.clone(), f.name.clone()), f);
    }
    
    for call in &document.call_sites {
        let enclosing_fn = match fn_map.get(&(call.owner.clone(), call.function.clone())) {
            Some(f) => f,
            None => continue,
        };
        
        let mut is_callback = false;
        
        let is_direct = call.receiver.is_empty() || call.receiver == "self" || call.receiver == "this";

        if is_direct {
            // E.g., cb(), fp(), arr[10](), (*fp)()
            let mut is_var_call = false;
            if enclosing_fn.params.contains(&call.message) 
                || enclosing_fn.callback_params.contains(&call.message) 
            {
                if call.receiver.is_empty() {
                    is_var_call = true;
                } else {
                    let param_type = document.method_param_types
                        .get(&call.function)
                        .and_then(|params| params.get(&call.message))
                        .map(|s| s.as_str());
                    let is_cb = is_callback_type_or_name(&call.message, param_type, document.language)
                        || is_cb_name(&call.message)
                        || matches!(
                            call.message.as_str(),
                            "blk" | "block"
                                | "work"
                                | "mapper"
                                | "runner"
                        );
                    if is_cb {
                        is_var_call = true;
                    }
                }
            }
            if !is_var_call {
                if let Some(locals) = document.method_local_types.get(&call.function) {
                    if let Some(t) = locals.get(&call.message) {
                        if is_cb_type(t) {
                            is_var_call = true;
                        }
                    }
                }
            }
            if !is_var_call {
                let is_complex_target = (call.message.contains('[') && call.message != "[]")
                    || call.message.contains('(')
                    || call.message.contains('*')
                    || call.message.contains("->")
                    || (document.language == Language::Php && call.message.starts_with('$'));
                if is_complex_target {
                    is_var_call = true;
                }
            }
            if is_var_call {
                is_callback = true;
            }
        } else {
            // E.g., cb.call() or listener.onEvent()
            if call.receiver != "self" && call.receiver != "this" 
                && (enclosing_fn.params.contains(&call.receiver) 
                    || enclosing_fn.callback_params.contains(&call.receiver)) 
            {
                let is_dispatch_name = matches!(
                    call.message.as_str(),
                    "call"
                        | "invoke"
                        | "apply"
                        | "run"
                        | "perform"
                        | "execute"
                        | "accept"
                        | "get"
                        | "callback"
                        | "handle"
                        | "dispatch"
                        | "trigger"
                        | "fire"
                        | "notify"
                        | "emit"
                ) || call.message.starts_with("on_")
                  || (call.message.starts_with("on")
                      && call.message.chars().nth(2).map_or(false, |c| c.is_ascii_uppercase()));

                let is_invoker = matches!(call.message.as_str(), "call" | "invoke" | "apply" | "run" | "perform");

                let is_cb = if supports_interfaces(document.language) {
                    let param_type = document.method_param_types
                        .get(&call.function)
                        .and_then(|params| params.get(&call.receiver))
                        .map(|s| s.as_str());
                    let is_callback_type = is_callback_type_or_name(&call.receiver, param_type, document.language);
                    is_dispatch_name && is_callback_type
                } else {
                    is_invoker || (is_dispatch_name && is_cb_name(&call.receiver))
                };

                if is_cb {
                    is_callback = true;
                }
            }
        }
        
        if is_callback {
            let snippet = if call.receiver.is_empty() {
                format!("{}(...)", call.message)
            } else {
                format!("{}.{}(...)", call.receiver, call.message)
            };
            
            let hazard_type = format!("{}_callback_invocation", document.language.as_str());
            
            callback_hazards.push(HazardSite {
                path: call.file.clone(),
                line: call.line as u32,
                snippet,
                hazard_type,
                required_evidence: "nil-kill".to_string(),
                provider: document.language.as_str().to_string(),
                start_column: Some(call.span[1] as u32),
                end_line: Some(call.span[2] as u32),
                end_column: Some(call.span[3] as u32),
            });
        }
    }
    
    document.hazard_sites.extend(callback_hazards);
    document.hazard_sites.sort_by_key(|s| (s.line, s.start_column, s.end_line, s.end_column, s.hazard_type.clone()));
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

    #[test]
    fn test_callback_invocation_hazards_all_languages() {
        let check = |code: &str, suffix: &str, language: Language| -> Vec<HazardSite> {
            let mut file = tempfile::Builder::new().suffix(suffix).tempfile().unwrap();
            std::io::Write::write_all(file.as_file_mut(), code.as_bytes()).unwrap();
            let document = crate::syntax::parse_file(file.path().to_path_buf(), language).unwrap();
            document.hazard_sites.into_iter().filter(|h| h.hazard_type.ends_with("_callback_invocation")).collect()
        };

        // 1. Ruby
        let rb_pos = check("def test(cb)\n  cb.call\nend", ".rb", Language::Ruby);
        assert_eq!(rb_pos.len(), 1);
        assert_eq!(rb_pos[0].hazard_type, "ruby_callback_invocation");
        let rb_neg = check("def test(user)\n  user.to_s\nend", ".rb", Language::Ruby);
        assert_eq!(rb_neg.len(), 0);

        // 2. Python
        let py_pos = check("def test(cb):\n    cb()\n", ".py", Language::Python);
        assert_eq!(py_pos.len(), 1);
        assert_eq!(py_pos[0].hazard_type, "python_callback_invocation");
        let py_neg = check("def test(user):\n    user.get_name()\n", ".py", Language::Python);
        assert_eq!(py_neg.len(), 0);

        // 3. Go
        let go_pos = check("package main\nfunc test(cb func()) {\n  cb()\n}", ".go", Language::Go);
        assert_eq!(go_pos.len(), 1);
        assert_eq!(go_pos[0].hazard_type, "go_callback_invocation");
        let go_neg = check("package main\nfunc helper() {}\nfunc test() {\n  helper()\n}", ".go", Language::Go);
        assert_eq!(go_neg.len(), 0);

        // 4. Rust
        let rust_pos = check("fn test(cb: fn()) {\n  cb();\n}", ".rs", Language::Rust);
        assert_eq!(rust_pos.len(), 1);
        assert_eq!(rust_pos[0].hazard_type, "rust_callback_invocation");
        let rust_neg = check("fn helper() {}\nfn test() {\n  helper();\n}", ".rs", Language::Rust);
        assert_eq!(rust_neg.len(), 0);

        // 5. PHP
        let php_pos = check("<?php function test($cb) {\n  $cb();\n}", ".php", Language::Php);
        assert_eq!(php_pos.len(), 1);
        assert_eq!(php_pos[0].hazard_type, "php_callback_invocation");
        let php_neg = check("<?php function helper() {}\nfunction test() {\n  helper();\n}", ".php", Language::Php);
        assert_eq!(php_neg.len(), 0);

        // 6. Java
        let java_pos = check("class Foo {\n  void test(Runnable cb, MyListener listener) {\n    cb.run();\n    listener.onEvent();\n  }\n}", ".java", Language::Java);
        assert_eq!(java_pos.len(), 2);
        assert_eq!(java_pos[0].hazard_type, "java_callback_invocation");
        assert_eq!(java_pos[1].hazard_type, "java_callback_invocation");
        let java_neg = check("class Foo {\n  void test(User user) {\n    user.getName();\n  }\n}", ".java", Language::Java);
        assert_eq!(java_neg.len(), 0);

        // 7. Kotlin
        let kt_pos = check("fun test(cb: () -> Unit) {\n  cb()\n}", ".kt", Language::Kotlin);
        assert_eq!(kt_pos.len(), 1);
        assert_eq!(kt_pos[0].hazard_type, "kotlin_callback_invocation");
        let kt_neg = check("fun test(user: User) {\n  user.getName()\n}", ".kt", Language::Kotlin);
        assert_eq!(kt_neg.len(), 0);

        // 8. Swift
        let swift_pos = check("func test(cb: () -> Void) {\n  cb()\n}", ".swift", Language::Swift);
        assert_eq!(swift_pos.len(), 1);
        assert_eq!(swift_pos[0].hazard_type, "swift_callback_invocation");
        let swift_neg = check("func test(user: User) {\n  user.getName()\n}", ".swift", Language::Swift);
        assert_eq!(swift_neg.len(), 0);

        // 9. JavaScript
        let js_pos = check("function test(cb) {\n  cb();\n}", ".js", Language::JavaScript);
        assert_eq!(js_pos.len(), 1);
        assert_eq!(js_pos[0].hazard_type, "javascript_callback_invocation");
        let js_neg = check("function test(user) {\n  user.getName();\n}", ".js", Language::JavaScript);
        assert_eq!(js_neg.len(), 0);

        // 10. Lua
        let lua_pos = check("function test(cb)\n  cb()\nend", ".lua", Language::Lua);
        assert_eq!(lua_pos.len(), 1);
        assert_eq!(lua_pos[0].hazard_type, "lua_callback_invocation");
        let lua_neg = check("function test(user)\n  user.getName()\nend", ".lua", Language::Lua);
        assert_eq!(lua_neg.len(), 0);

        // 11. C
        let c_pos = check("void test(void (*cb)(void)) {\n  cb();\n}", ".c", Language::C);
        assert_eq!(c_pos.len(), 1);
        assert_eq!(c_pos[0].hazard_type, "c_callback_invocation");
        let c_neg = check("void helper() {}\nvoid test() {\n  helper();\n}", ".c", Language::C);
        assert_eq!(c_neg.len(), 0);

        // 12. C++
        let cpp_pos = check("void test(std::function<void()> cb) {\n  cb();\n}", ".cpp", Language::Cpp);
        assert_eq!(cpp_pos.len(), 1);
        assert_eq!(cpp_pos[0].hazard_type, "cpp_callback_invocation");
        let cpp_neg = check("void helper() {}\nvoid test() {\n  helper();\n}", ".cpp", Language::Cpp);
        assert_eq!(cpp_neg.len(), 0);

        // 13. C#
        let csharp_pos = check("class Foo {\n  void Test(Action cb) {\n    cb();\n  }\n}", ".cs", Language::CSharp);
        assert_eq!(csharp_pos.len(), 1);
        assert_eq!(csharp_pos[0].hazard_type, "csharp_callback_invocation");
        let csharp_neg = check("class Foo {\n  void Helper() {}\n  void Test() {\n    Helper();\n  }\n}", ".cs", Language::CSharp);
        assert_eq!(csharp_neg.len(), 0);

        // 14. TypeScript
        let ts_pos = check("function test(cb: () => void) {\n  cb();\n}", ".ts", Language::TypeScript);
        assert_eq!(ts_pos.len(), 1);
        assert_eq!(ts_pos[0].hazard_type, "typescript_callback_invocation");
        let ts_neg = check("function test(user: User) {\n  user.getName();\n}", ".ts", Language::TypeScript);
        assert_eq!(ts_neg.len(), 0);

        // 15. Zig
        let zig_pos = check("fn test(cb: fn() void) void {\n  cb();\n}", ".zig", Language::Zig);
        assert_eq!(zig_pos.len(), 1);
        assert_eq!(zig_pos[0].hazard_type, "zig_callback_invocation");
        let zig_neg = check("fn helper() void {}\nfn test() void {\n  helper();\n}", ".zig", Language::Zig);
        assert_eq!(zig_neg.len(), 0);
    }
}
