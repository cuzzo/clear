use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, NormalizedCallParts, NormalizedCallProjection,
    NormalizedLanguageBehavior, NormalizedNilGuardFact, NormalizedSemanticEffect,
    NormalizedVisibilityEvent, SyntaxMetadata,
};
use super::{CallSite, FunctionDef};
use crate::ast::{self, Node, Span};
use std::collections::{BTreeMap, BTreeSet};

const RUBY_CONTEXT_PAIRS: &[(&str, &[&str])] = &[
    ("Dir", &["pwd", "getwd", "home"]),
    ("Time", &["now", "current"]),
    ("Date", &["today", "current"]),
    ("DateTime", &["now", "current"]),
    ("Process", &["pid", "ppid", "uid", "gid", "euid"]),
    ("Thread", &["current", "list", "main"]),
    ("Fiber", &["current"]),
    ("Random", &["rand", "bytes"]),
    ("GC", &["stat", "count"]),
    ("ObjectSpace", &["each_object", "count_objects"]),
];

const RUBY_CALLBACK_SET: &[&str] = &[
    "transaction",
    "synchronize",
    "lock",
    "with_lock",
    "unlock",
    "mutex",
    "atomic",
    "reentrant",
    "subscribe",
    "callback",
    "hook",
];

const RUBY_CORE_CONSTS: &[&str] = &[
    "String",
    "Symbol",
    "Integer",
    "Float",
    "Numeric",
    "Rational",
    "Complex",
    "Array",
    "Hash",
    "Set",
    "Range",
    "Struct",
    "Object",
    "BasicObject",
    "Kernel",
    "Module",
    "Class",
    "Comparable",
    "Enumerable",
    "Enumerator",
    "Proc",
    "Method",
    "UnboundMethod",
    "NilClass",
    "TrueClass",
    "FalseClass",
    "Exception",
    "StandardError",
    "RuntimeError",
    "ArgumentError",
    "TypeError",
    "NameError",
    "NoMethodError",
    "IO",
    "File",
    "Dir",
    "Time",
    "Date",
    "DateTime",
    "Regexp",
    "MatchData",
    "Thread",
    "Mutex",
    "Fiber",
    "Process",
    "Math",
    "GC",
    "ObjectSpace",
    "Marshal",
    "Random",
    "Encoding",
];
const RUBY_GUARD_MIDS: &[&str] = &["is_a?", "kind_of?", "instance_of?", "nil?", "respond_to?"];

const RUBY_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "send",
        "__send__",
        "public_send",
        "const_get",
        "constantize",
        "instance_variable_get",
    ],
    meta_mids: &[
        "define_method",
        "define_singleton_method",
        "alias_method",
        "class_eval",
        "module_eval",
        "instance_eval",
        "class_exec",
        "module_exec",
        "instance_exec",
        "eval",
        "const_set",
        "instance_variable_set",
        "remove_method",
        "undef_method",
        "prepend",
        "singleton_class",
        "binding",
    ],
    method_obj_mids: &["method", "public_method", "instance_method"],
    io_consts: &[
        "File",
        "IO",
        "Dir",
        "FileUtils",
        "Open3",
        "Socket",
        "TCPSocket",
        "UDPSocket",
        "TCPServer",
        "UNIXSocket",
        "Tempfile",
        "Pathname",
        "Marshal",
    ],
    io_pairs: &[("URI", &["open"])],
    io_receiver_prefixes: &["Net::"],
    io_bare: &[
        "puts",
        "print",
        "warn",
        "gets",
        "readline",
        "readlines",
        "system",
        "exec",
        "spawn",
        "fork",
        "sleep",
        "open",
        "abort",
        "exit",
        "exit!",
    ],
    context_pairs: RUBY_CONTEXT_PAIRS,
    context_consts: &["ENV"],
    context_bare: &["rand", "srand"],
    callback_set: RUBY_CALLBACK_SET,
    callback_requires_block: false,
    bang_mutation: true,
};

pub(crate) struct RubyNormalizedBehavior;

impl NormalizedLanguageBehavior for RubyNormalizedBehavior {
    fn mutating_receiver_message(&self, message: &str) -> bool {
        matches!(
            message,
            "<<" | "[]="
                | "add"
                | "append"
                | "clear"
                | "collect!"
                | "compact!"
                | "concat"
                | "delete"
                | "delete_if"
                | "fill"
                | "filter!"
                | "keep_if"
                | "merge!"
                | "move"
                | "push"
                | "reject!"
                | "replace"
                | "shift"
                | "store"
                | "unshift"
                | "update"
                | "write"
        ) || (message.ends_with('!') && !matches!(message, "!=" | "!~"))
    }

    fn syntax_metadata(&self, source: &str, functions: &[FunctionDef]) -> SyntaxMetadata {
        let metadata = ruby_metadata(source, functions);
        SyntaxMetadata {
            immutable_struct_readers: metadata.immutable_struct_readers,
            immutable_struct_reader_types: metadata.immutable_struct_reader_types,
            type_aliases: metadata.type_aliases,
            method_param_types: metadata.method_param_types,
        }
    }

    fn suppress_self_call_state_read(&self, call: &NormalizedCallProjection) -> bool {
        call.receiver == "self"
    }

    fn self_member_receiver(&self, message: &str) -> String {
        format!("self.{message}")
    }

    fn emit_index_call_site(&self, _node: &Node, _call: &NormalizedCallProjection) -> bool {
        true
    }

    fn emit_index_assignment_mutation(&self, _node: &Node, _field: Option<&str>) -> bool {
        true
    }

    fn emit_attribute_assignment_mutation(&self, _node: &Node, field: Option<&str>) -> bool {
        field != Some("[]")
    }

    fn preserve_constant_receiver_call(&self, call: &NormalizedCallProjection) -> bool {
        let base = call
            .receiver
            .trim_start_matches("::")
            .split("::")
            .next()
            .unwrap_or("");
        (call.receiver == "ENV")
            || RUBY_EFFECT_LEXICON
                .context_pairs
                .iter()
                .any(|(name, mids)| *name == base && mids.contains(&call.message.as_str()))
            || RUBY_EFFECT_LEXICON.io_consts.contains(&base)
            || RUBY_EFFECT_LEXICON
                .io_pairs
                .iter()
                .any(|(name, mids)| *name == base && mids.contains(&call.message.as_str()))
            || RUBY_EFFECT_LEXICON
                .io_receiver_prefixes
                .iter()
                .any(|prefix| call.receiver.starts_with(prefix))
            || (call.receiver == "T" && call.message == "type_alias")
            || RUBY_CORE_CONSTS.contains(&base)
    }

    fn branch_state_ref(
        &self,
        _node: &Node,
        _parts: &NormalizedCallParts,
        default_ref: String,
    ) -> Option<String> {
        Some(default_ref)
    }

    fn normalize_comparison_source(&self, source: &str) -> String {
        let mut text = source.trim().to_string();
        if let Some(rest) = text.strip_prefix('!') {
            text = rest
                .trim_start_matches('(')
                .trim_end_matches(')')
                .trim()
                .to_string();
        }
        if let Some(rest) = text.strip_prefix("self.") {
            text = rest.to_string();
        }
        if let Some(rest) = text.strip_prefix('@') {
            text = rest.to_string();
        }
        if let Some(dot_index) = text.find('.') {
            let receiver = &text[..dot_index];
            let rest = &text[(dot_index + 1)..];
            if simple_identifier(receiver)
                && (rest.contains(" == ") || rest.contains(" != ") || rest.contains('.'))
            {
                text = rest.to_string();
            }
        }
        crate::ast::normalize_text(&text)
    }

    fn visibility_events_from_calls(
        &self,
        calls: &[super::CallSite],
    ) -> Vec<NormalizedVisibilityEvent> {
        calls
            .iter()
            .filter(|call| {
                call.receiver == "self"
                    && matches!(call.message.as_str(), "public" | "protected" | "private")
            })
            .map(|call| NormalizedVisibilityEvent {
                owner: call.owner.clone(),
                visibility: call.message.clone(),
                line: call.line,
                target_names: call
                    .arguments
                    .iter()
                    .map(|argument| visibility_argument_name(argument))
                    .filter(|argument| !argument.is_empty())
                    .collect(),
            })
            .collect()
    }

    fn protocol_read_label_from_state(&self, receiver: &str, field: &str) -> Option<String> {
        let field = field
            .trim_start_matches('@')
            .trim_start_matches('$')
            .trim_end_matches(['?', '!']);
        if receiver.trim().is_empty() || receiver == "self" {
            Some(field.to_string())
        } else {
            Some(format!(
                "{}.{}",
                receiver.trim_start_matches('@').trim_start_matches('$'),
                field
            ))
        }
    }

    fn protocol_read_label_from_call(&self, receiver: &str, message: &str) -> Option<String> {
        (receiver == "self").then(|| message.trim_end_matches(['?', '!']).to_string())
    }

    fn protocol_write_label(&self, receiver: &str, field: &str) -> Option<String> {
        self.protocol_read_label_from_state(receiver, field)
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        (message == "nil?").then(|| NormalizedNilGuardFact {
            local: subject.to_string(),
            non_nil_when_true: false,
        })
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "raise" | "fail" | "abort" | "exit" | "exit!")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, RUBY_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &RUBY_EFFECT_LEXICON))
    }

    fn core_owner_names(&self) -> &'static [&'static str] {
        RUBY_CORE_CONSTS
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        matches!(
            name,
            "break"
                | "case"
                | "class"
                | "def"
                | "do"
                | "else"
                | "elsif"
                | "end"
                | "false"
                | "for"
                | "if"
                | "in"
                | "module"
                | "nil"
                | "private"
                | "protected"
                | "public"
                | "return"
                | "self"
                | "true"
                | "unless"
                | "while"
        )
    }

    fn suppress_predicate_body_text(&self, text: &str) -> bool {
        text == "nil"
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        let lower = text.to_ascii_lowercase();
        lower.contains("nil") || lower.contains(" and ") || lower.contains(" or ")
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        matches!(node.r#type.as_str(), "CLASS" | "MODULE").then_some(default_span)
    }

    fn boolean_enclosing_span(
        &self,
        _node: &Node,
        node_span: Span,
        _decision_span: Option<Span>,
    ) -> Span {
        node_span
    }

    fn structural_semantic_effects(
        &self,
        _node: &Node,
        function_name: &str,
    ) -> Vec<NormalizedSemanticEffect> {
        if matches!(function_name, "method_missing" | "respond_to_missing?") {
            vec![NormalizedSemanticEffect {
                kind: "metaprogramming".to_string(),
                detail: format!("def {function_name}"),
            }]
        } else {
            Vec::new()
        }
    }

    fn rescue_semantic_effects(
        &self,
        body: &Node,
        resbody: &Node,
    ) -> Vec<NormalizedSemanticEffect> {
        if ruby_nil_rescue_fallback(resbody) {
            vec![NormalizedSemanticEffect {
                kind: "eliminable_guard".to_string(),
                detail: ast::normalize_text(&body.text),
            }]
        } else {
            Vec::new()
        }
    }
}

static RUBY_BEHAVIOR: RubyNormalizedBehavior = RubyNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &RUBY_BEHAVIOR
}

fn ruby_nil_rescue_fallback(node: &Node) -> bool {
    if node.r#type == "NIL" {
        return true;
    }
    let children = node
        .children
        .iter()
        .filter_map(ast::node)
        .collect::<Vec<_>>();
    if node.r#type == "RESBODY" {
        if let Some(child) = children.get(1) {
            return ruby_nil_rescue_fallback(child);
        }
    }
    children.len() == 1 && ruby_nil_rescue_fallback(children[0])
}

fn simple_identifier(value: &str) -> bool {
    let mut chars = value.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn visibility_argument_name(argument: &str) -> String {
    argument
        .trim()
        .trim_start_matches(':')
        .trim_matches('"')
        .trim_matches('\'')
        .split_whitespace()
        .next()
        .unwrap_or("")
        .to_string()
}

#[derive(Clone, Debug, Default)]
struct RubyMetadata {
    immutable_struct_readers: BTreeMap<String, Vec<String>>,
    immutable_struct_reader_types: BTreeMap<String, BTreeMap<String, String>>,
    type_aliases: BTreeMap<String, String>,
    method_param_types: BTreeMap<String, BTreeMap<String, String>>,
}

fn ruby_metadata(source: &str, functions: &[FunctionDef]) -> RubyMetadata {
    RubyMetadata {
        immutable_struct_readers: reader_sets_to_vecs(immutable_struct_reader_sets(source)),
        immutable_struct_reader_types: immutable_struct_reader_types(source),
        type_aliases: type_aliases(source),
        method_param_types: method_param_types(source, functions),
    }
}

fn immutable_struct_reader_sets(source: &str) -> BTreeMap<String, BTreeSet<String>> {
    let mut readers: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut class_stack = Vec::new();
    for line in source.lines() {
        let stripped = line.trim();
        if let Some(name) = stripped
            .strip_prefix("class ")
            .and_then(|rest| rest.split_once("< T::Struct").map(|(name, _)| name.trim()))
            .filter(|name| constant_path(name))
        {
            class_stack.push(name.to_string());
            continue;
        }
        if let Some(owner) = class_stack.last() {
            if let Some(field) = stripped
                .strip_prefix("const :")
                .and_then(|rest| {
                    rest.split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_')
                        .next()
                })
                .filter(|field| !field.is_empty())
            {
                readers
                    .entry(owner.clone())
                    .or_default()
                    .insert(field.to_string());
                continue;
            }
        }
        if !class_stack.is_empty() && stripped.trim_end_matches(';') == "end" {
            class_stack.pop();
        }
    }
    readers
}

fn reader_sets_to_vecs(
    readers: BTreeMap<String, BTreeSet<String>>,
) -> BTreeMap<String, Vec<String>> {
    readers
        .into_iter()
        .map(|(owner, fields)| (owner, fields.into_iter().collect()))
        .collect()
}

fn immutable_struct_reader_types(source: &str) -> BTreeMap<String, BTreeMap<String, String>> {
    let mut reader_types: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    let mut class_stack = Vec::new();
    for line in source.lines() {
        let stripped = line.trim();
        if let Some(name) = stripped
            .strip_prefix("class ")
            .and_then(|rest| rest.split_once("< T::Struct").map(|(name, _)| name.trim()))
            .filter(|name| constant_path(name))
        {
            class_stack.push(name.to_string());
            continue;
        }
        if let Some(owner) = class_stack.last() {
            if let Some((field, type_name)) = stripped
                .strip_prefix("const :")
                .and_then(|rest| rest.split_once(','))
                .map(|(field, type_name)| {
                    (
                        field
                            .split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_')
                            .next()
                            .unwrap_or("")
                            .trim(),
                        type_name
                            .trim()
                            .split(|ch: char| {
                                !matches!(ch, ':' | '_' | 'A'..='Z' | 'a'..='z' | '0'..='9')
                            })
                            .next()
                            .unwrap_or("")
                            .trim(),
                    )
                })
                .filter(|(field, type_name)| !field.is_empty() && constant_path(type_name))
            {
                reader_types
                    .entry(owner.clone())
                    .or_default()
                    .insert(field.to_string(), type_name.to_string());
                continue;
            }
        }
        if !class_stack.is_empty() && stripped.trim_end_matches(';') == "end" {
            class_stack.pop();
        }
    }
    reader_types
}

fn type_aliases(source: &str) -> BTreeMap<String, String> {
    let mut aliases = BTreeMap::new();
    let lines: Vec<&str> = source.lines().map(|l| l.trim()).collect();
    let mut owner_stack: Vec<String> = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if line.is_empty() || line.starts_with('#') {
            i += 1;
            continue;
        }

        if line.starts_with("class ") || line.starts_with("module ") {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() > 1 {
                let name = parts[1].trim_end_matches('<');
                let name = name.split('<').next().unwrap_or(name).trim();
                let qualified = if let Some(parent) = owner_stack.last() {
                    if name.contains("::") {
                        name.to_string()
                    } else {
                        format!("{}::{}", parent, name)
                    }
                } else {
                    name.to_string()
                };
                owner_stack.push(qualified);
            }
            i += 1;
            continue;
        }

        if line == "end" {
            owner_stack.pop();
            i += 1;
            continue;
        }

        if let Some((name, rest)) = line.split_once('=') {
            let name = name.trim();
            if constant_path(name) {
                let rest = rest.trim();
                if rest.starts_with("T.type_alias") {
                    let mut target = String::new();
                    if rest.contains('{') {
                        let mut depth = 0;
                        let mut found_start = false;
                        let mut current_line = i;
                        let mut block_text = String::new();
                        while current_line < lines.len() {
                            let text = if current_line == i { rest } else { lines[current_line] };
                            for ch in text.chars() {
                                if ch == '{' {
                                    depth += 1;
                                    found_start = true;
                                    if depth == 1 {
                                        continue;
                                    }
                                } else if ch == '}' {
                                    depth -= 1;
                                    if depth == 0 {
                                        break;
                                    }
                                }
                                if found_start {
                                    block_text.push(ch);
                                }
                            }
                            if found_start && depth == 0 {
                                break;
                            }
                            current_line += 1;
                        }
                        target = block_text.trim().to_string();
                    } else if rest.contains(" do") || rest.ends_with(" do") || (i + 1 < lines.len() && lines[i+1].starts_with("do")) {
                        let mut current_line = i;
                        let mut block_lines = Vec::new();
                        let mut started = false;
                        while current_line < lines.len() {
                            let text = if current_line == i { rest } else { lines[current_line] };
                            if !started {
                                if let Some((_, right)) = text.split_once("do") {
                                    let right_trimmed = right.trim();
                                    if !right_trimmed.is_empty() {
                                        block_lines.push(right_trimmed);
                                    }
                                    started = true;
                                }
                            } else {
                                if text == "end" || text.starts_with("end ") || text.ends_with(" end") {
                                    if let Some((left, _)) = text.split_once("end") {
                                        let left_trimmed = left.trim();
                                        if !left_trimmed.is_empty() {
                                            block_lines.push(left_trimmed);
                                        }
                                    }
                                    break;
                                }
                                block_lines.push(text);
                            }
                            current_line += 1;
                        }
                        target = block_lines.join(" ").trim().to_string();
                    } else {
                        let parts: Vec<&str> = rest.split_whitespace().collect();
                        if parts.len() > 1 {
                            target = parts[1..].join(" ").trim().to_string();
                        }
                    }

                    if !target.is_empty() {
                        let qualified_name = if let Some(parent) = owner_stack.last() {
                            format!("{}::{}", parent, name)
                        } else {
                            name.to_string()
                        };
                        aliases.insert(qualified_name, target);
                    }
                }
            }
        }
        i += 1;
    }
    aliases
}


fn method_param_types(
    source: &str,
    functions: &[FunctionDef],
) -> BTreeMap<String, BTreeMap<String, String>> {
    functions
        .iter()
        .map(|function| {
            (
                function.name.clone(),
                sig_param_types(source, function.line),
            )
        })
        .filter(|(_, param_types)| !param_types.is_empty())
        .collect()
}

fn sig_param_types(source: &str, function_line: usize) -> BTreeMap<String, String> {
    let lines = source.lines().collect::<Vec<_>>();
    let mut sig_lines = Vec::new();
    let mut cursor = function_line.saturating_sub(2);
    while let Some(line) = lines.get(cursor) {
        let stripped = line.trim();
        if !stripped.is_empty() {
            sig_lines.push(*line);
        }
        if stripped.starts_with("sig") {
            break;
        }
        if cursor == 0 || sig_lines.len() >= 12 {
            break;
        }
        cursor -= 1;
    }
    sig_lines.reverse();
    let sig = sig_lines.join("\n");
    if !sig.trim_start().starts_with("sig") {
        return BTreeMap::new();
    }
    let Some(params_start) = sig.find("params(").map(|index| index + "params(".len()) else {
        return BTreeMap::new();
    };
    let rest = &sig[params_start..];
    let Some(params_end) = rest.find(')') else {
        return BTreeMap::new();
    };
    rest[..params_end]
        .split(',')
        .filter_map(|part| {
            let (name, type_name) = part.split_once(':')?;
            let name = name.trim();
            let type_name = type_name.trim();
            (identifier(name) && constant_path(type_name))
                .then(|| (name.to_string(), type_name.to_string()))
        })
        .collect()
}

fn identifier(value: &str) -> bool {
    let mut chars = value.chars();
    matches!(chars.next(), Some(ch) if ch == '_' || ch.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn constant_path(value: &str) -> bool {
    value.split("::").all(|part| {
        let mut chars = part.chars();
        matches!(chars.next(), Some(ch) if ch.is_ascii_uppercase())
            && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
    })
}
