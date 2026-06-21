use super::{
    normalized_c, normalized_csharp, normalized_go, normalized_java, normalized_javascript,
    normalized_kotlin, normalized_lua, normalized_php, normalized_python, normalized_ruby,
    normalized_rust, normalized_swift, normalized_typescript, normalized_zig, FunctionDef,
    Language, StateDeclaration,
};
use crate::ast::{Node, Span};
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

pub(crate) trait NormalizedLanguageBehavior: Sync {
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

    fn call_access_span(
        &self,
        _node: &Node,
        computed_span: Option<Span>,
        full_span: Span,
    ) -> Span {
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

    fn project_call(&self, _node: &Node, call: NormalizedCallProjection) -> NormalizedCallProjection {
        call
    }

    fn suppress_call_site(&self, _node: &Node, _call: &NormalizedCallProjection) -> bool {
        false
    }

    fn preserve_constant_receiver_call(&self, _call: &NormalizedCallProjection) -> bool {
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

    fn normalize_source_text(&self, text: &str) -> String {
        text.to_string()
    }

    fn source_message_text(&self, message: &str, _node: Option<&Node>) -> String {
        message.to_string()
    }

    fn self_member_receiver(&self, message: &str) -> String {
        message.to_string()
    }

    fn owner_name_span(
        &self,
        _name: &str,
        _node: &Node,
        _default_span: Span,
    ) -> Option<Span> {
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
        let before_paren = source.split_once('(').map(|(before, _)| before).unwrap_or(source);
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
}

struct BaseNormalizedBehavior;

impl NormalizedLanguageBehavior for BaseNormalizedBehavior {}

static BASE_BEHAVIOR: BaseNormalizedBehavior = BaseNormalizedBehavior;

pub(crate) fn behavior(language: Language) -> &'static dyn NormalizedLanguageBehavior {
    match language {
        Language::Ruby => normalized_ruby::behavior(),
        Language::C => normalized_c::behavior(),
        Language::Go => normalized_go::behavior(),
        Language::Java => normalized_java::behavior(),
        Language::JavaScript => normalized_javascript::behavior(),
        Language::CSharp => normalized_csharp::behavior(),
        Language::TypeScript => normalized_typescript::behavior(),
        Language::Kotlin => normalized_kotlin::behavior(),
        Language::Lua => normalized_lua::behavior(),
        Language::Php => normalized_php::behavior(),
        Language::Python => normalized_python::behavior(),
        Language::Rust => normalized_rust::behavior(),
        Language::Swift => normalized_swift::behavior(),
        Language::Zig => normalized_zig::behavior(),
        _ => &BASE_BEHAVIOR,
    }
}

fn matching_paren_index(source: &str, open_index: usize) -> Option<usize> {
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
