use std::sync::OnceLock;
use crate::syntax::{HazardSite, Language, Document, FunctionDef};
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

            let required_evidence = if hazard_type.contains("_vopr_") || hazard_type.starts_with("zig_vopr_") {
                "vopr".to_string()
            } else if hazard_type.contains("_loom_") || hazard_type.starts_with("rust_loom_") {
                "loom".to_string()
            } else if hazard_type.contains("_wait_loop") || hazard_type.ends_with("_wait_loop") {
                "hammer".to_string()
            } else if hazard_type.contains("_metaprogramming") || hazard_type.contains("_callback_") {
                "nil-kill".to_string()
            } else if hazard_type.contains("_asan_") || hazard_type.starts_with("c_asan_") {
                "asan".to_string()
            } else if hazard_type.contains("_lsan_") || hazard_type.starts_with("c_lsan_") {
                "lsan".to_string()
            } else if hazard_type.contains("_ubsan_") || hazard_type.starts_with("c_ubsan_") {
                "ubsan".to_string()
            } else if hazard_type.contains("_tsan_") || hazard_type.starts_with("c_tsan_") {
                "tsan".to_string()
            } else if hazard_type.starts_with("go_race_") {
                "race".to_string()
            } else if hazard_type.starts_with("go_concurrency_") {
                "concurrency".to_string()
            } else if hazard_type == "csharp_unsafe_memory" {
                "unsafe".to_string()
            } else if hazard_type.starts_with("rust_unsafe_") {
                "miri".to_string()
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
        || s_lower.starts_with("func(")
        || s_lower.starts_with("func ")
        || s_lower.ends_with("_fn")
        || s_lower.ends_with("_func")
        || s_lower.contains("(*)")
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

/// Per-function value-origin sets derived from the local dataflow facts.
///
/// `param_derived` holds every local name whose value is reachable from a
/// parameter through direct `target = source` assignment edges. Calling such a
/// value is a function-pointer/callback invocation: the callable was supplied
/// by the caller.
///
/// `callable_typed` holds every local name proven to hold a callable by type
/// evidence (declared parameter/local types, adapter callback params, or
/// flow-propagated `declared:` hints), closed over the same assignment edges.
#[derive(Default)]
struct CallbackOrigins {
    param_derived: std::collections::HashSet<String>,
    callable_typed: std::collections::HashSet<String>,
}

fn place_name_from_id(place_id: &str) -> Option<&str> {
    place_id.rsplit(':').next().filter(|name| !name.is_empty())
}

/// The CFG layer names file-level scopes "(top-level)" while the syntax layer
/// uses the file stem as the owner. Collapse both spellings so per-function
/// facts from the two layers join on one key.
fn canonical_owner(owner: &str, file_stem: &str) -> String {
    if owner == "(top-level)" || owner == file_stem {
        String::new()
    } else {
        owner.to_string()
    }
}

fn declared_hint_type(hint: &str) -> &str {
    hint.strip_prefix("declared:").unwrap_or(hint)
}

fn method_type_map<'a>(
    map: &'a std::collections::BTreeMap<String, std::collections::BTreeMap<String, String>>,
    enclosing: &FunctionDef,
) -> Option<&'a std::collections::BTreeMap<String, String>> {
    let key = crate::syntax::normalized_behavior::method_parameter_type_key(
        &enclosing.owner,
        &enclosing.name,
        enclosing.line,
    );
    map.get(&key).or_else(|| map.get(&enclosing.name))
}

fn compute_callback_origins(
    document: &Document,
) -> std::collections::HashMap<(String, String), CallbackOrigins> {
    let file_stem = std::path::Path::new(&document.file)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("")
        .to_string();
    let mut origins: std::collections::HashMap<(String, String), CallbackOrigins> =
        std::collections::HashMap::new();

    for f in &document.function_defs {
        let entry = origins
            .entry((canonical_owner(&f.owner, &file_stem), f.name.clone()))
            .or_default();
        for p in &f.params {
            entry.param_derived.insert(p.clone());
        }
        for p in &f.callback_params {
            entry.param_derived.insert(p.clone());
            entry.callable_typed.insert(p.clone());
        }
        for map in [
            method_type_map(&document.method_param_types, f),
            method_type_map(&document.method_local_types, f),
        ]
        .into_iter()
        .flatten()
        {
            for (name, type_str) in map {
                if is_cb_type(type_str) {
                    entry.callable_typed.insert(name.clone());
                }
            }
        }
    }

    for fact in &document.flow_types {
        if fact.types.iter().any(|t| is_cb_type(declared_hint_type(t))) {
            if let Some(name) = place_name_from_id(&fact.place_id) {
                origins
                    .entry((canonical_owner(&fact.owner, &file_stem), fact.function.clone()))
                    .or_default()
                    .callable_typed
                    .insert(name.to_string());
            }
        }
    }
    for effect in &document.node_effects {
        for (place_id, hint) in &effect.write_type_hints {
            if is_cb_type(declared_hint_type(hint)) {
                if let Some(name) = place_name_from_id(place_id) {
                    origins
                        .entry((canonical_owner(&effect.owner, &file_stem), effect.function.clone()))
                        .or_default()
                        .callable_typed
                        .insert(name.to_string());
                }
            }
        }
    }

    loop {
        let mut changed = false;
        for effect in &document.node_effects {
            let key = (canonical_owner(&effect.owner, &file_stem), effect.function.clone());
            let Some(entry) = origins.get_mut(&key) else {
                continue;
            };
            for (target, source) in &effect.write_sources {
                let (Some(target_name), Some(source_name)) =
                    (place_name_from_id(target), place_name_from_id(source))
                else {
                    continue;
                };
                if entry.param_derived.contains(source_name)
                    && entry.param_derived.insert(target_name.to_string())
                {
                    changed = true;
                }
                if entry.callable_typed.contains(source_name)
                    && entry.callable_typed.insert(target_name.to_string())
                {
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
    }

    origins
}

pub fn detect_and_append_callback_hazards(document: &mut Document) {
    let file_stem = std::path::Path::new(&document.file)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("")
        .to_string();
    let origins = compute_callback_origins(document);
    let empty_origins = CallbackOrigins::default();

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
        let origin = origins
            .get(&(canonical_owner(&call.owner, &file_stem), call.function.clone()))
            .unwrap_or(&empty_origins);

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
                    let param_type = method_type_map(&document.method_param_types, enclosing_fn)
                        .and_then(|params| params.get(&call.message).cloned());
                    let is_cb = is_callback_type_or_name(&call.message, param_type.as_deref(), document.language)
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
            if !is_var_call
                && (origin.param_derived.contains(&call.message)
                    || origin.callable_typed.contains(&call.message))
                && !fn_map.contains_key(&(call.owner.clone(), call.message.clone()))
            {
                // Aliased or typed callable local: my_cb = cb; my_cb()
                is_var_call = true;
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
            let mut is_cb_receiver = false;
            if call.receiver != "self" && call.receiver != "this" {
                if enclosing_fn.params.contains(&call.receiver)
                    || enclosing_fn.callback_params.contains(&call.receiver)
                    || origin.param_derived.contains(&call.receiver)
                    || origin.callable_typed.contains(&call.receiver)
                {
                    is_cb_receiver = true;
                }
            }

            if is_cb_receiver {
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
                    let type_str = method_type_map(&document.method_param_types, enclosing_fn)
                        .and_then(|params| params.get(&call.receiver).cloned())
                        .or_else(|| {
                            method_type_map(&document.method_local_types, enclosing_fn)
                                .and_then(|locals| locals.get(&call.receiver).cloned())
                        });
                    let is_callback_type = is_callback_type_or_name(&call.receiver, type_str.as_deref(), document.language)
                        || origin.callable_typed.contains(&call.receiver);
                    is_dispatch_name && is_callback_type
                } else {
                    is_invoker
                        || (is_dispatch_name
                            && (is_cb_name(&call.receiver)
                                || origin.callable_typed.contains(&call.receiver)))
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
        assert_eq!(unsafe_hazard.required_evidence, "miri");
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

    #[test]
    fn test_additional_precision_and_composition_edge_cases() {
        let check_all = |code: &str, suffix: &str, language: Language| -> Vec<HazardSite> {
            let mut file = tempfile::Builder::new().suffix(suffix).tempfile().unwrap();
            std::io::Write::write_all(file.as_file_mut(), code.as_bytes()).unwrap();
            let document = crate::syntax::parse_file(file.path().to_path_buf(), language).unwrap();
            document.hazard_sites
        };

        // 1. Go WaitGroup positive and near-miss
        let go_hazards = check_all("
            package main
            func main() {
                var wg sync.WaitGroup
                wg.Wait()
                var d Door
                d.Wait()
            }
        ", ".go", Language::Go);
        let wg_hazards: Vec<_> = go_hazards.iter().filter(|h| h.hazard_type == "go_concurrency_waitgroup").collect();
        assert_eq!(wg_hazards.len(), 1);
        assert_eq!(wg_hazards[0].snippet, "wg.Wait()");

        // 2. Rust Mutex positive and near-miss
        let rust_hazards = check_all("
            fn main() {
                let lock = mutex.lock().unwrap();
                let key = door.lock();
            }
        ", ".rs", Language::Rust);
        let loom_hazards: Vec<_> = rust_hazards.iter().filter(|h| h.hazard_type == "rust_loom_concurrency").collect();
        assert_eq!(loom_hazards.len(), 1);
        assert!(loom_hazards[0].snippet.contains("mutex.lock()"));

        // Safe reference derefs are not unsafe operations; raw-pointer derefs
        // are already covered by the enclosing unsafe block.
        let rust_deref = check_all("
            fn read(x: &i32) -> i32 {
                let v = *x;
                v
            }
        ", ".rs", Language::Rust);
        assert!(rust_deref.iter().all(|h| h.hazard_type != "rust_unsafe_operation"));

        // 3. Kotlin Reflection call vs normal function call
        let kt_hazards = check_all("
            fun test() {
                val res = method.call()
            }
            fun call() {}
        ", ".kt", Language::Kotlin);
        let kt_metaprog: Vec<_> = kt_hazards.iter().filter(|h| h.hazard_type == "kotlin_metaprogramming").collect();
        assert_eq!(kt_metaprog.len(), 1);

        // 4. Java Real Class.forName vs shadowed class Class
        let java_hazards = check_all("
            class Demo {
                void test() {
                    Class.forName(\"Foo\");
                    Class c = new Class();
                    c.forName(\"Bar\");
                }
            }
            class Class {
                void forName(String s) {}
            }
        ", ".java", Language::Java);
        let java_metaprog: Vec<_> = java_hazards.iter().filter(|h| h.hazard_type == "java_metaprogramming").collect();
        assert_eq!(java_metaprog.len(), 1);
        assert_eq!(java_metaprog[0].snippet, "Class.forName(\"Foo\");");

        // 5. C# Reflection type matching vs containing type
        let cs_hazards = check_all("
            class Demo {
                void Test() {
                    typeof(Foo).GetMethod(\"Bar\");
                    TypeHelper typeHelper = new TypeHelper();
                    typeHelper.GetMethod(\"Bar\");
                }
            }
            class TypeHelper {
                public void GetMethod(string s) {}
            }
        ", ".cs", Language::CSharp);
        let cs_metaprog: Vec<_> = cs_hazards.iter().filter(|h| h.hazard_type == "csharp_metaprogramming").collect();
        assert_eq!(cs_metaprog.len(), 1);

        // Reflection-info receivers flag on Invoke; ordinary identifiers that
        // merely contain \"mi\"/\"fi\"/\"pi\" as substrings do not.
        let cs_invoke = check_all("
            class Demo {
                void Test() {
                    mi.Invoke(null, null);
                    methodInfo.Invoke(null, null);
                    admin.Invoke();
                    family.GetValue(null);
                }
            }
        ", ".cs", Language::CSharp);
        let cs_invoke_metaprog: Vec<_> = cs_invoke.iter().filter(|h| h.hazard_type == "csharp_metaprogramming").collect();
        assert_eq!(cs_invoke_metaprog.len(), 2);

        // 6. Callback compositions: neutral name, aliasing, hops, multiline, struct function pointers
        let compositions_code = "
            class Demo {
                void test(Runnable cb, MyListener listener) {
                    // Callback type with neutral parameter name
                    cb.run();

                    // Typed callable local with neutral name
                    Runnable r2 = cb;
                    r2.run();

                    // Callback aliasing and multiple assignment hops
                    Runnable r3 = r2;
                    r3.run();

                    // Same method name in two different owners
                    listener.onEvent();

                    // Multiline call
                    r3.run(
                    );

                    // Two hazards on one line
                    cb.run(); r2.run();
                }
            }
            interface MyListener {
                void onEvent();
            }
        ";
        let doc_hazards = check_all(compositions_code, ".java", Language::Java);
        
        let mut file = tempfile::Builder::new().suffix(".java").tempfile().unwrap();
        std::io::Write::write_all(file.as_file_mut(), compositions_code.as_bytes()).unwrap();
        let doc = crate::syntax::parse_file(file.path().to_path_buf(), Language::Java).unwrap();
        let java_callbacks: Vec<_> = doc.hazard_sites.iter().filter(|h| h.hazard_type == "java_callback_invocation").collect();
        assert!(java_callbacks.len() >= 6);

        // 7. C struct function-pointer members / complex targets
        let mut c_file = tempfile::Builder::new().suffix(".c").tempfile().unwrap();
        std::io::Write::write_all(c_file.as_file_mut(), "
            struct Handler {
                void (*cb)(void);
            };
            void test(struct Handler* h) {
                (*h->cb)();
            }
        ".as_bytes()).unwrap();
        let c_doc = crate::syntax::parse_file(c_file.path().to_path_buf(), Language::C).unwrap();
        let c_callbacks: Vec<_> = c_doc.hazard_sites.iter().filter(|h| h.hazard_type == "c_callback_invocation").collect();
        assert_eq!(c_callbacks.len(), 1);

        // 8. C++ functor / std::function policy test
        let cpp_compositions = check_all("
            void test(std::function<void()> cb) {
                cb();
            }
        ", ".cpp", Language::Cpp);
        let cpp_callbacks: Vec<_> = cpp_compositions.iter().filter(|h| h.hazard_type == "cpp_callback_invocation").collect();
        assert_eq!(cpp_callbacks.len(), 1);
    }

    #[test]
    fn test_dfg_backed_callback_aliasing_and_precision() {
        let check = |code: &str, suffix: &str, language: Language| -> Vec<HazardSite> {
            let mut file = tempfile::Builder::new().suffix(suffix).tempfile().unwrap();
            std::io::Write::write_all(file.as_file_mut(), code.as_bytes()).unwrap();
            let document = crate::syntax::parse_file(file.path().to_path_buf(), language).unwrap();
            document
                .hazard_sites
                .into_iter()
                .filter(|h| h.hazard_type.ends_with("_callback_invocation"))
                .collect()
        };

        // Gap 3 (fp-hazard-gaps.md): parameter aliased through a local, then invoked.
        let go_alias = check(
            "package main\nfunc test(cb func()) {\n  my_cb := cb\n  my_cb()\n}",
            ".go",
            Language::Go,
        );
        assert_eq!(go_alias.len(), 1);
        assert_eq!(go_alias[0].line, 4);

        let rb_alias = check(
            "def test(cb)\n  my_cb = cb\n  my_cb.call\nend",
            ".rb",
            Language::Ruby,
        );
        assert_eq!(rb_alias.len(), 1);
        assert_eq!(rb_alias[0].line, 3);

        let py_alias = check(
            "def test(cb):\n    f = cb\n    f()\n",
            ".py",
            Language::Python,
        );
        assert_eq!(py_alias.len(), 1);
        assert_eq!(py_alias[0].line, 3);

        // Aliasing a local bound to a named function is NOT caller-supplied: stay quiet.
        let go_local_fn = check(
            "package main\nfunc helper() {}\nfunc test() {\n  f := helper\n  f()\n}",
            ".go",
            Language::Go,
        );
        assert_eq!(go_local_fn.len(), 0);

        // Static dispatch on a constructed receiver must NOT be flagged
        // (the shape that produced false positives on real code).
        let rb_new_run = check(
            "class Runner\n  def dispatch\n    Command.new(@argv).run\n  end\nend",
            ".rb",
            Language::Ruby,
        );
        assert_eq!(rb_new_run.len(), 0);

        let rb_chain = check(
            "class Runner\n  def dispatch(config)\n    config.value.call_count\n  end\nend",
            ".rb",
            Language::Ruby,
        );
        assert_eq!(rb_chain.len(), 0);

        // Gap 1 (fp-hazard-gaps.md): C member calls always dispatch through a
        // function-pointer field.
        let c_member = check(
            "struct Handler {\n  void (*cb)(void);\n};\nvoid test(struct Handler* h) {\n  h->cb();\n}",
            ".c",
            Language::C,
        );
        assert_eq!(c_member.len(), 1);
    }

}
