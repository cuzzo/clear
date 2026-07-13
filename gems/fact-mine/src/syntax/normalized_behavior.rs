use super::{
    c, cpp, csharp, go, java, javascript, kotlin, lua, php, python, ruby, rust, swift, typescript,
    zig, CallSite, FunctionDef, Language, StateDeclaration,
};
use crate::ast::{Node, Span};
use crate::syntax::cfg::ControlFlowProfile;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default)]
pub(crate) struct SyntaxMetadata {
    pub(crate) immutable_struct_readers: BTreeMap<String, Vec<String>>,
    pub(crate) immutable_struct_reader_types: BTreeMap<String, BTreeMap<String, String>>,
    pub(crate) type_aliases: BTreeMap<String, String>,
    pub(crate) method_param_types: BTreeMap<String, BTreeMap<String, String>>,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedCallParts {
    pub(crate) receiver: String,
    pub(crate) message: String,
    pub(crate) arguments: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedCallProjection {
    pub(crate) receiver: String,
    pub(crate) message: String,
    pub(crate) arguments: Vec<String>,
    pub(crate) access_span: Span,
    pub(crate) span: Span,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedOwner {
    pub(crate) name: String,
    pub(crate) kind: String,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedStateRead {
    pub(crate) receiver: String,
    pub(crate) field: String,
    pub(crate) line: Option<usize>,
    pub(crate) span: Span,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedStateWrite {
    pub(crate) receiver: String,
    pub(crate) field: String,
    pub(crate) span: Span,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedSemanticEffect {
    pub(crate) kind: String,
    pub(crate) detail: String,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedVisibilityEvent {
    pub(crate) owner: String,
    pub(crate) visibility: String,
    pub(crate) line: usize,
    pub(crate) target_names: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedNilGuardFact {
    pub(crate) local: String,
    pub(crate) non_nil_when_true: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum BlockCallSemantics {
    Iteration,
    Once,
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CardinalityCallSemantics {
    PreservesReceiver,
    MeasuresReceiver,
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CollectionAllocationSemantics {
    None,
    PreservesReceiver,
    UnknownSize,
}

pub(crate) trait NormalizedLanguageBehavior: Sync {
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        ControlFlowProfile::neutral_ref()
    }

    fn collection_allocation_semantics(&self, _message: &str) -> CollectionAllocationSemantics {
        CollectionAllocationSemantics::None
    }

    fn block_call_semantics(&self, _message: &str) -> BlockCallSemantics {
        BlockCallSemantics::Unknown
    }

    fn cardinality_call_semantics(&self, _message: &str) -> CardinalityCallSemantics {
        CardinalityCallSemantics::Unknown
    }

    fn iteration_bound_argument(&self, _message: &str, _argument_count: usize) -> Option<usize> {
        None
    }

    fn iteration_yields_collection_value(&self, _message: &str) -> bool {
        false
    }

    fn empty_check_call(&self, _message: &str) -> bool { false }
    fn visited_membership_call(&self, _message: &str) -> bool { false }
    fn visited_insert_call(&self, _message: &str) -> bool { false }
    fn empty_collection_constructor(&self, _message: &str) -> bool { false }
    fn collection_parameter_type(&self, _type_name: &str) -> bool { false }
    fn supports_parameter_normalization(&self) -> bool {
        false
    }

    fn yield_semantic_effect(&self, _node: &Node) -> bool {
        true
    }

    fn boolean_decision_members(&self, members: Vec<String>, _node: &Node) -> Vec<String> {
        members
    }

    fn state_write_span(
        &self,
        _receiver: &str,
        _field: &str,
        _node: &Node,
        default_span: Span,
    ) -> Span {
        default_span
    }

    fn call_access_span(&self, _node: &Node, computed_span: Option<Span>, full_span: Span) -> Span {
        computed_span.unwrap_or(full_span)
    }

    fn call_site_span(
        &self,
        _node: &Node,
        parts: &NormalizedCallParts,
        full_span: Span,
        access_span: Span,
        current_function: &str,
    ) -> Span {
        if self.access_span_call_site(&parts.message, current_function) {
            access_span
        } else {
            full_span
        }
    }

    fn call_receiver(&self, parts: &NormalizedCallParts) -> String {
        parts.receiver.clone()
    }

    fn project_call(
        &self,
        _node: &Node,
        call: NormalizedCallProjection,
    ) -> NormalizedCallProjection {
        call
    }

    fn node_call_projections(&self, _node: &Node) -> Vec<NormalizedCallProjection> {
        Vec::new()
    }

    fn suppress_call_site(&self, _node: &Node, _call: &NormalizedCallProjection) -> bool {
        false
    }

    fn preserve_constant_receiver_call(&self, _call: &NormalizedCallProjection) -> bool {
        false
    }

    fn is_type_guard(&self, _message: &str) -> bool {
        false
    }

    fn is_nil_check(&self, _message: &str) -> bool {
        false
    }

    fn is_type_normalizer(&self, _receiver: &str, _message: &str) -> bool {
        false
    }

    fn is_type_cast(&self, _receiver: &str, _message: &str) -> bool {
        false
    }

    fn struct_declaration_fields(&self, _node: &Node) -> Option<Vec<String>> {
        None
    }

    fn static_return_type(&self, _message: &str, _receiver_type: Option<&str>) -> Option<String> {
        None
    }

    fn static_call_return_type(
        &self,
        _node: &Node,
        _message: &str,
        _receiver_type: Option<&str>,
    ) -> Option<String> {
        None
    }

    fn known_return_type(&self, _name: &str) -> Option<String> {
        None
    }

    fn propagated_collection_return_type(
        &self,
        _message: &str,
        _receiver_type: Option<&str>,
    ) -> Option<String> {
        None
    }

    fn is_noreturn_method(&self, _message: &str) -> bool {
        false
    }

    fn emit_index_call_site(&self, _node: &Node, _call: &NormalizedCallProjection) -> bool {
        false
    }

    fn emit_index_assignment_mutation(&self, _node: &Node, _field: Option<&str>) -> bool {
        false
    }

    fn emit_attribute_assignment_mutation(&self, _node: &Node, _field: Option<&str>) -> bool {
        false
    }

    fn local_assignment_writes(
        &self,
        _field: Option<&str>,
        _node: &Node,
        _default_span: Span,
    ) -> Vec<NormalizedStateWrite> {
        Vec::new()
    }

    fn implicit_owner_fields(&self) -> bool {
        false
    }

    fn field_name_from_declaration(&self, _node: &Node) -> Option<String> {
        None
    }

    fn state_declaration_from_node(
        &self,
        _node: &Node,
        _owner: &str,
        _in_method: bool,
    ) -> Option<StateDeclaration> {
        None
    }

    fn embedded_member_reads(&self, _node: &Node) -> Vec<NormalizedStateRead> {
        Vec::new()
    }

    fn literal_state_reads(
        &self,
        _node: &Node,
        _normalized_text: &str,
        _span: Span,
        _source_text: &str,
    ) -> Vec<NormalizedStateRead> {
        Vec::new()
    }

    fn node_state_reads(&self, _node: &Node) -> Vec<NormalizedStateRead> {
        Vec::new()
    }

    fn initializer_field_reads(
        &self,
        _node: &Node,
        _owner: &str,
        _owner_fields: &[String],
        _function_name: &str,
    ) -> Vec<NormalizedStateRead> {
        Vec::new()
    }

    fn suppress_state_read_for_call(
        &self,
        _call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        false
    }

    fn record_method_calls_as_state_reads(&self) -> bool {
        true
    }

    fn suppress_self_call_state_read(&self, _call: &NormalizedCallProjection) -> bool {
        false
    }

    fn state_read_uses_access_span(&self, _call: &NormalizedCallProjection) -> bool {
        false
    }

    fn suppress_branch_decision(&self, _node: &Node) -> bool {
        false
    }

    fn ternary_children_conditional(&self, _node: &Node) -> bool {
        true
    }

    fn ternary_if_node(&self, _node: &Node) -> bool {
        false
    }

    fn normalize_source_text(&self, text: &str) -> String {
        text.to_string()
    }

    fn clean_identifier(&self, token: &str) -> String {
        token.strip_prefix("self.").unwrap_or(token).to_string()
    }

    fn clean_receiver(&self, receiver: &str) -> String {
        receiver.to_string()
    }

    fn source_message_text(&self, message: &str, _node: Option<&Node>) -> String {
        message.to_string()
    }

    fn self_member_receiver(&self, message: &str) -> String {
        message.to_string()
    }

    fn owner_name_span(&self, _name: &str, _node: &Node, _default_span: Span) -> Option<Span> {
        None
    }

    fn owner_name_from_text(&self, _node: &Node) -> Option<String> {
        None
    }

    fn owner_kind(&self, _node: &Node, default_kind: &str) -> String {
        default_kind.to_string()
    }

    fn declarative_owner(&self, _node: &Node, _current_owner: &str) -> Option<NormalizedOwner> {
        None
    }

    fn mutating_receiver_message(&self, _message: &str) -> bool {
        false
    }

    fn syntax_metadata(&self, _source: &str, _functions: &[FunctionDef]) -> SyntaxMetadata {
        SyntaxMetadata::default()
    }

    fn owner_for_function(
        &self,
        _name: &str,
        _node: &Node,
        current_owner: &str,
        _file_owner: &str,
    ) -> String {
        current_owner.to_string()
    }

    fn body_owner_for_function(
        &self,
        _name: &str,
        _node: &Node,
        _current_owner: &str,
        _file_owner: &str,
    ) -> Option<NormalizedOwner> {
        None
    }

    fn receiver_aliases_for_function(&self, _node: &Node) -> BTreeMap<String, String> {
        BTreeMap::new()
    }

    fn function_visibility(&self, _name: &str, _node: &Node, _lines: &[String]) -> String {
        "public".to_string()
    }

    fn function_name_from_text(&self, text: &str) -> Option<String> {
        let source = text.trim();
        let before_paren = source
            .split_once('(')
            .map(|(before, _)| before)
            .unwrap_or(source);
        before_paren
            .split_whitespace()
            .next_back()
            .map(|value| value.trim_start_matches(['*', '&']).to_string())
            .filter(|value| !value.is_empty())
    }

    fn parameter_list_source(&self, source: &str) -> String {
        let Some(open_index) = source.find('(') else {
            return String::new();
        };
        let Some(close_index) = matching_paren_index(source, open_index) else {
            return String::new();
        };
        source[(open_index + 1)..close_index].to_string()
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        let text = param.trim();
        if text.is_empty() {
            return None;
        }
        let text = text.split('=').next().unwrap_or(text).trim();
        text.split(|ch: char| !(ch == '_' || ch == '?' || ch.is_ascii_alphanumeric()))
            .filter(|part| !part.is_empty())
            .next_back()
            .map(|part| part.trim_end_matches('?').to_string())
    }

    fn property_read_call(&self, _node: &Node, _parts: &NormalizedCallParts) -> bool {
        false
    }

    fn case_pattern_values(&self, pattern_values: Vec<String>) -> Vec<String> {
        pattern_values
    }

    fn split_case_source(&self, source: &str) -> Vec<String> {
        source
            .split(',')
            .map(str::trim)
            .filter(|pattern| !pattern.is_empty())
            .map(|pattern| self.case_pattern_display(pattern))
            .collect()
    }

    fn case_pattern_display(&self, pattern: &str) -> String {
        pattern.to_string()
    }

    fn case_predicate_text(&self, text: &str) -> String {
        text.to_string()
    }

    fn access_span_call_site(&self, _message: &str, _current_function: &str) -> bool {
        false
    }

    fn boolean_enclosing_span(
        &self,
        _node: &Node,
        _node_span: Span,
        decision_span: Option<Span>,
    ) -> Span {
        decision_span.unwrap_or(_node_span)
    }

    fn method_state_ref(&self, _node: &Node, _parts: &NormalizedCallParts) -> bool {
        false
    }

    fn initializer_writes(&self, _node: &Node, _source_text: &str, _span: Span) -> Vec<NormalizedStateWrite> {
        Vec::new()
    }

    /// Extract explicit 'this.' or 'self.' bindings
    fn literal_state_writes(&self, _node: &Node, _normalized_text: &str) -> Vec<String> {
        Vec::new()
    }

    fn literal_state_refs(&self, _node: &Node, _normalized_text: &str) -> Vec<String> {
        Vec::new()
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        false
    }

    fn explicit_self_state_ref(&self, _node: &Node, message: &str) -> String {
        message.to_string()
    }

    fn stream_insertion_operator(&self, _node: &Node) -> bool {
        false
    }

    fn branch_state_ref(
        &self,
        _node: &Node,
        parts: &NormalizedCallParts,
        default_ref: String,
    ) -> Option<String> {
        let receiver = parts.receiver.as_str();
        if receiver
            .chars()
            .next()
            .is_some_and(|ch| ch == ':' || ch.is_ascii_uppercase())
            && !receiver.contains('(')
        {
            None
        } else {
            Some(default_ref)
        }
    }

    fn normalize_comparison_source(&self, source: &str) -> String {
        self.normalize_source_text(source.trim())
    }

    fn visibility_events_from_calls(&self, _calls: &[CallSite]) -> Vec<NormalizedVisibilityEvent> {
        Vec::new()
    }

    fn protocol_read_label_from_state(&self, receiver: &str, field: &str) -> Option<String> {
        if receiver.trim().is_empty() || receiver == "self" {
            Some(field.to_string())
        } else {
            Some(format!("{receiver}.{field}"))
        }
    }

    fn protocol_read_label_from_call(&self, receiver: &str, message: &str) -> Option<String> {
        (receiver == "self").then(|| message.to_string())
    }

    fn protocol_write_label(&self, receiver: &str, field: &str) -> Option<String> {
        if receiver.trim().is_empty() || receiver == "self" {
            Some(field.to_string())
        } else {
            Some(format!("{receiver}.{field}"))
        }
    }

    fn nil_guard_fact(&self, _message: &str, _subject: &str) -> Option<NormalizedNilGuardFact> {
        None
    }

    fn terminating_call_message(&self, _message: &str) -> bool {
        false
    }

    fn local_flow_assignment_operator(&self, operator: &str) -> bool {
        operator == "="
    }

    fn local_flow_declaration_keyword(&self, _keyword: &str) -> bool {
        false
    }

    fn local_flow_keyword(&self, _name: &str) -> bool {
        false
    }

    fn suppress_predicate_body_text(&self, _text: &str) -> bool {
        false
    }

    fn predicate_body_language_signal(&self, _text: &str) -> bool {
        false
    }

    fn semantic_effect_for_call(&self, _call: &CallSite) -> Option<NormalizedSemanticEffect> {
        None
    }

    fn core_owner_names(&self) -> &'static [&'static str] {
        &[]
    }

    fn structural_semantic_effects(
        &self,
        _node: &Node,
        _function_name: &str,
    ) -> Vec<NormalizedSemanticEffect> {
        Vec::new()
    }

    fn rescue_semantic_effects(
        &self,
        _body: &Node,
        _resbody: &Node,
    ) -> Vec<NormalizedSemanticEffect> {
        Vec::new()
    }

    fn format_array_type(&self, elem: &str) -> String {
        format!("T::Array[{}]", elem)
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("T::Hash[{}, {}]", key, val)
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("T::Set[{}]", elem)
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty() || type_text == "nil" || type_text == "null" || type_text == "None" {
            return type_text.to_string();
        }
        if type_text == "NilClass" || type_text.starts_with("T.nilable(") {
            type_text.to_string()
        } else {
            format!("T.nilable({})", type_text)
        }
    }

    fn untyped_type(&self) -> String {
        "T.untyped".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "T::Array[T.untyped]".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "T::Hash[T.untyped, T.untyped]".to_string()
    }
}

pub(crate) fn nil_guard_from_predicates(
    message: &str,
    subject: &str,
    nil_predicates: &[&str],
    non_nil_predicates: &[&str],
) -> Option<NormalizedNilGuardFact> {
    if nil_predicates.contains(&message) {
        return Some(NormalizedNilGuardFact {
            local: subject.to_string(),
            non_nil_when_true: false,
        });
    }
    if non_nil_predicates.contains(&message) {
        return Some(NormalizedNilGuardFact {
            local: subject.to_string(),
            non_nil_when_true: true,
        });
    }
    None
}

pub(crate) fn eliminable_guard_from_call(
    call: &CallSite,
    guard_messages: &[&str],
) -> Option<NormalizedSemanticEffect> {
    if call.receiver.is_empty() || !guard_messages.contains(&call.message.as_str()) {
        return None;
    }
    Some(NormalizedSemanticEffect {
        kind: "eliminable_guard".to_string(),
        detail: call.receiver.clone(),
    })
}

pub(crate) fn behavior(language: Language) -> &'static dyn NormalizedLanguageBehavior {
    match language {
        Language::Ruby => ruby::behavior(),
        Language::C => c::behavior(),
        Language::Cpp => cpp::behavior(),
        Language::Go => go::behavior(),
        Language::Java => java::behavior(),
        Language::JavaScript => javascript::behavior(),
        Language::CSharp => csharp::behavior(),
        Language::TypeScript => typescript::behavior(),
        Language::Kotlin => kotlin::behavior(),
        Language::Lua => lua::behavior(),
        Language::Php => php::behavior(),
        Language::Python => python::behavior(),
        Language::Rust => rust::behavior(),
        Language::Swift => swift::behavior(),
        Language::Zig => zig::behavior(),
    }
}

pub(crate) fn matching_paren_index(source: &str, open_index: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (index, ch) in source
        .char_indices()
        .filter(|(index, _)| *index >= open_index)
    {
        if ch == '(' {
            depth += 1;
        } else if ch == ')' {
            depth = depth.saturating_sub(1);
            if depth == 0 {
                return Some(index);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestBehavior;
    impl NormalizedLanguageBehavior for TestBehavior {}

    struct TestBehaviorOverride;
    impl NormalizedLanguageBehavior for TestBehaviorOverride {
        fn access_span_call_site(&self, _message: &str, _current_function: &str) -> bool {
            true
        }
    }

    #[test]
    fn test_default_behavior_methods() {
        let b = TestBehavior;
        let node = Node {
            r#type: "dummy".to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };

        // call_site_span branches
        let parts = NormalizedCallParts {
            receiver: "self".to_string(),
            message: "foo".to_string(),
            arguments: Vec::new(),
        };
        let full = [1, 0, 1, 10];
        let acc = [1, 0, 1, 5];
        assert_eq!(b.call_site_span(&node, &parts, full, acc, "func"), full);

        let bo = TestBehaviorOverride;
        assert_eq!(bo.call_site_span(&node, &parts, full, acc, "func"), acc);

        // other default trait methods with missing lines
        assert!(!b.emit_index_assignment_mutation(&node, None));
        assert_eq!(b.self_member_receiver("m"), "m");
        assert!(b.owner_name_from_text(&node).is_none());
        assert_eq!(b.parameter_list_source("("), "");
        assert!(b.parameter_name_from_signature("").is_none());
        assert!(b.literal_state_refs(&node, "text").is_empty());
        assert!(b.nil_guard_fact("msg", "sub").is_none());
        assert!(!b.local_flow_declaration_keyword("key"));
        assert!(!b.local_flow_keyword("name"));
        assert!(b
            .semantic_effect_for_call(&CallSite {
                receiver: "".to_string(),
                message: "".to_string(),
                file: "".to_string(),
                function: "".to_string(),
                owner: "".to_string(),
                line: 0,
                span: [0, 0, 0, 0],
                conditional: false,
                arguments: Vec::new(),
                control: None,
                safe_navigation: false,
                block: false,
            })
            .is_none());
        assert!(b.core_owner_names().is_empty());
    }

    #[test]
    fn test_matching_paren_index_none() {
        assert!(matching_paren_index("(", 0).is_none());
    }
}
