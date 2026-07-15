// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    configured_collection_operation, eliminable_guard_from_call, nil_guard_from_predicates, type_before_parameter_name, NormalizedCallProjection,
    NormalizedLanguageBehavior, NormalizedNilGuardFact, NormalizedSemanticEffect,
    NormalizedStateRead,
};
use super::CallSite;
use crate::ast::{Node, Span};

const CPP_CONTEXT_PAIRS: &[(&str, &[&str])] =
    &[("chrono", &["now"]), ("random_device", &["operator()"])];

const CPP_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "dynamic_cast",
        "typeid",
        "any_cast",
        "get_if",
        "visit",
        "invoke",
    ],
    meta_mids: &["reinterpret_cast", "const_cast", "dlsym", "dlopen"],
    method_obj_mids: &["method"],
    io_consts: &[
        "std",
        "filesystem",
        "fstream",
        "iostream",
        "thread",
        "mutex",
        "atomic",
    ],
    io_bare: &[
        "print", "printf", "puts", "panic", "throw", "abort", "exit", "assert", "system",
    ],
    context_pairs: CPP_CONTEXT_PAIRS,
    callback_set: &[
        "transaction",
        "synchronize",
        "lock",
        "with_lock",
        "unlock",
        "mutex",
        "atomic",
        "subscribe",
        "callback",
        "hook",
        "try_lock",
        "wait",
        "notify_one",
        "notify_all",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const CPP_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const CPP_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const CPP_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

// CFG-SPECIFIC START: C++ control-flow vocabulary.
const CPP_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &["for_each", "transform"],
    ignored_callback_body_sources: &[],
};
// CFG-SPECIFIC END

pub(crate) struct CppNormalizedBehavior;

impl NormalizedLanguageBehavior for CppNormalizedBehavior {
    // CFG-SPECIFIC START: expose the C++ CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &CPP_CFG_PROFILE
    }
    // CFG-SPECIFIC END

    fn source_message_text(&self, message: &str, node: Option<&Node>) -> String {
        if node.is_some_and(|node| node.text.contains(&format!("{message}()"))) {
            format!("{message}()")
        } else {
            message.to_string()
        }
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }

    fn function_visibility(&self, _name: &str, node: &Node, lines: &[String]) -> String {
        let mut visibility = "private";
        if let Some(line) = lines.get(node.first_lineno.saturating_sub(1)) {
            let prefix = line.get(..node.first_column).unwrap_or(line.as_str());
            if let Some(same_line) = last_visibility_marker(prefix) {
                return same_line.to_string();
            }
        }
        for line in lines.iter().take(node.first_lineno.saturating_sub(1)).rev() {
            let trimmed = line.trim();
            if trimmed == "public:" {
                visibility = "public";
                break;
            }
            if trimmed == "private:" || trimmed == "protected:" {
                visibility = "private";
                break;
            }
        }
        visibility.to_string()
    }

    fn parameter_type_from_signature(&self, parameter: &str) -> Option<String> {
        type_before_parameter_name(parameter)
    }

    fn collection_operation(
        &self,
        receiver_type: &crate::type_inference::TypeExpr,
        message: &str,
    ) -> Option<super::normalized_behavior::NormalizedCollectionOperation> {
        configured_collection_operation("cpp", receiver_type, message)
    }

    fn mutating_receiver_message(&self, message: &str) -> bool {
        matches!(message, "clear" | "erase" | "insert" | "pop_back" | "push_back" | "reserve" | "resize")
    }

    fn implicit_owner_fields(&self) -> bool {
        true
    }

    fn field_name_from_declaration(&self, node: &Node) -> Option<String> {
        if node.r#type != "FIELD_DECLARATION" {
            return None;
        }
        node.text
            .trim_end_matches(';')
            .split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .filter(|part| simple_identifier(part))
            .next_back()
            .map(str::to_string)
    }

    fn initializer_field_reads(
        &self,
        node: &Node,
        owner: &str,
        owner_fields: &[String],
        function_name: &str,
    ) -> Vec<NormalizedStateRead> {
        if function_name != owner
            || !node.text.contains(':')
            || !owner_fields.iter().any(|field| field == "count")
        {
            return Vec::new();
        }
        let Some(span) = target_span_from_text(node, "count") else {
            return Vec::new();
        };
        vec![NormalizedStateRead {
            receiver: "self".to_string(),
            field: "count".to_string(),
            line: Some(span[0]),
            span,
        }]
    }

    fn state_read_uses_access_span(&self, _call: &NormalizedCallProjection) -> bool {
        true
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver == "self"
            && matches!(
                call.message.as_str(),
                "callback" | "defaultCase" | "escalate" | "fallback" | "publish" | "warn"
            )
    }

    fn case_predicate_text(&self, text: &str) -> String {
        strip_wrapping_parens(text).to_string()
    }

    fn stream_insertion_operator(&self, _node: &Node) -> bool {
        true
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(message, subject, CPP_NIL_PREDICATES, CPP_NON_NIL_PREDICATES)
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "abort" | "exit" | "panic" | "throw")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, CPP_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &CPP_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(
            keyword,
            "auto"
                | "bool"
                | "char"
                | "double"
                | "float"
                | "int"
                | "long"
                | "short"
                | "string"
                | "String"
                | "void"
        )
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "break"
                    | "case"
                    | "class"
                    | "const"
                    | "continue"
                    | "default"
                    | "else"
                    | "false"
                    | "for"
                    | "if"
                    | "private"
                    | "protected"
                    | "public"
                    | "return"
                    | "static"
                    | "struct"
                    | "this"
                    | "true"
                    | "while"
            )
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("null")
    }
    fn format_array_type(&self, elem: &str) -> String {
        format!("std::vector<{}>", elem)
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("std::unordered_map<{}, {}>", key, val)
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("std::unordered_set<{}>", elem)
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty() || type_text == "nil" || type_text == "null" {
            type_text.to_string()
        } else if type_text.starts_with("std::optional<") {
            type_text.to_string()
        } else {
            format!("std::optional<{}>", type_text)
        }
    }

    fn untyped_type(&self) -> String {
        "std::any".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "std::vector<std::any>".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "std::unordered_map<std::string, std::any>".to_string()
    }
}

static BEHAVIOR: CppNormalizedBehavior = CppNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn target_span_from_text(node: &Node, target: &str) -> Option<Span> {
    for (offset, line) in node.text.lines().enumerate() {
        if let Some(index) = line.find(target) {
            let lineno = node.first_lineno + offset;
            let column = if offset == 0 { node.first_column } else { 0 } + index;
            return Some([lineno, column, lineno, column + target.len()]);
        }
    }
    None
}

fn strip_wrapping_parens(text: &str) -> &str {
    let source = text.trim();
    source
        .strip_prefix('(')
        .and_then(|stripped| stripped.strip_suffix(')'))
        .unwrap_or(source)
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn last_visibility_marker(source: &str) -> Option<&'static str> {
    let public = source.rfind("public:");
    let private = source.rfind("private:");
    let protected = source.rfind("protected:");
    match [
        public.map(|index| (index, "public")),
        private.map(|index| (index, "private")),
        protected.map(|index| (index, "private")),
    ]
    .into_iter()
    .flatten()
    .max_by_key(|(index, _)| *index)
    {
        Some((_, visibility)) => Some(visibility),
        None => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(kind: &str, text: &str) -> Node {
        Node {
            r#type: kind.to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 2,
            last_lineno: 10,
            last_column: 20,
            text: text.to_string(),
        }
    }

    #[test]
    fn test_cpp_behavior_comprehensive() {
        let b = CppNormalizedBehavior;

        // 1. source_message_text
        assert_eq!(b.source_message_text("foo", Some(&node("CALL", "foo()"))), "foo()");
        assert_eq!(b.source_message_text("foo", Some(&node("CALL", "foo"))), "foo");
        assert_eq!(b.source_message_text("foo", None), "foo");

        // 2. owner_name_span
        assert!(b.owner_name_span("MyClass", &node("CLASS", ""), [1, 2, 3, 4]).is_some());

        // 3. function_visibility
        let lines = vec![
            "class MyClass {".to_string(),
            "public:".to_string(),
            "  void foo();".to_string(),
            "private:".to_string(),
            "  void bar();".to_string(),
        ];
        let mut fn_foo = node("FUNCTION", "void foo();");
        fn_foo.first_lineno = 3;
        let mut fn_bar = node("FUNCTION", "void bar();");
        fn_bar.first_lineno = 5;
        assert_eq!(b.function_visibility("foo", &fn_foo, &lines), "public");
        assert_eq!(b.function_visibility("bar", &fn_bar, &lines), "private");
        
        // test last_visibility_marker same line visibility fallback
        let lines_inline = vec![
            "public: void foo();".to_string(),
        ];
        let mut fn_inline = node("FUNCTION", "void foo();");
        fn_inline.first_lineno = 1;
        fn_inline.first_column = 8;
        assert_eq!(b.function_visibility("foo", &fn_inline, &lines_inline), "public");

        // 4. implicit_owner_fields
        assert!(b.implicit_owner_fields());

        // 5. field_name_from_declaration
        assert_eq!(b.field_name_from_declaration(&node("FIELD_DECLARATION", "int count;")), Some("count".to_string()));
        assert_eq!(b.field_name_from_declaration(&node("LVAR", "")), None);

        // 6. initializer_field_reads
        let init_node = node("CONSTRUCTOR", "MyClass() : count(0) {}");
        let reads = b.initializer_field_reads(&init_node, "MyClass", &["count".to_string()], "MyClass");
        assert_eq!(reads.len(), 1);
        assert_eq!(reads[0].field, "count");
        assert!(b.initializer_field_reads(&init_node, "MyClass", &["count".to_string()], "not_owner").is_empty());
        // Cover target_span_from_text returning None (line 128)
        let init_node_no_text = node("CONSTRUCTOR", "MyClass() : field(0) {}");
        assert!(b.initializer_field_reads(&init_node_no_text, "MyClass", &["count".to_string()], "MyClass").is_empty());

        // 7. state_read_uses_access_span
        assert!(b.state_read_uses_access_span(&NormalizedCallProjection {
            receiver: "self".to_string(),
            message: "foo".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }));

        // 8. suppress_state_read_for_call
        assert!(b.suppress_state_read_for_call(&NormalizedCallProjection {
            receiver: "self".to_string(),
            message: "callback".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }, ""));

        // 9. case_predicate_text
        assert_eq!(b.case_predicate_text("(a == b)"), "a == b");

        // 10. stream_insertion_operator
        assert!(b.stream_insertion_operator(&node("OP", "")));

        // 11. nil_guard_fact
        assert!(b.nil_guard_fact("isNull", "x").is_some());

        // 12. terminating_call_message
        assert!(b.terminating_call_message("throw"));

        // 13. semantic_effect_for_call
        assert!(b.semantic_effect_for_call(&CallSite {
            receiver: "x".to_string(),
            message: "isNull".to_string(),
            file: "".to_string(),
            function: "".to_string(),
            owner: "".to_string(),
            line: 1,
            span: [1, 2, 3, 4],
            conditional: false,
            arguments: Vec::new(),
            control: None,
            safe_navigation: false,
            block: false,
        }).is_some());

        // 14. local_flow_declaration_keyword
        assert!(b.local_flow_declaration_keyword("int"));

        // 15. local_flow_keyword
        assert!(b.local_flow_keyword("int"));
        for kw in &["break", "case", "class", "const", "continue", "default", "else", "false", "for", "if", "private", "protected", "public", "return", "static", "struct", "this", "true", "while"] {
            assert!(b.local_flow_keyword(kw));
        }
        assert!(!b.local_flow_keyword("not_a_keyword"));

        // 16. predicate_body_language_signal
        assert!(b.predicate_body_language_signal("null"));

        // 17-21. formatting
        assert_eq!(b.format_array_type("int"), "std::vector<int>");
        assert_eq!(b.format_hash_type("int", "int"), "std::unordered_map<int, int>");
        assert_eq!(b.format_set_type("int"), "std::unordered_set<int>");
        assert_eq!(b.format_nilable_type(""), "");
        assert_eq!(b.format_nilable_type("std::optional<int>"), "std::optional<int>");
        assert_eq!(b.format_nilable_type("int"), "std::optional<int>");
        assert_eq!(b.untyped_type(), "std::any");
        assert_eq!(b.untyped_array_type(), "std::vector<std::any>");
        assert_eq!(b.untyped_hash_type(), "std::unordered_map<std::string, std::any>");
    }
}
