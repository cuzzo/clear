use super::super::{
    calls::CallShape,
    protocols::{RawCallShape, RawProtocolShape},
    semantic_effects::StaticNodeEffect,
};

pub(crate) const FUNCTION_NODE_KINDS: &[&str] = &["method"];
pub(crate) const CLASS_OWNER_NODE_KINDS: &[&str] = &["class"];
pub(crate) const MODULE_OWNER_NODE_KINDS: &[&str] = &["module"];
pub(crate) const CALL_NODE_KINDS: &[&str] = &["call"];
pub(crate) const PARAMETER_LIST_NODE_KINDS: &[&str] = &["method_parameters"];
pub(crate) const PARAMETER_IDENTIFIER_NODE_KINDS: &[&str] = &["identifier"];
pub(crate) const FUNCTION_BODY_NODE_KINDS: &[&str] = &["body_statement", "do_block"];
pub(crate) const NESTED_STATEMENT_WRAPPER_NODE_KINDS: &[&str] = &["body_statement"];
pub(crate) const IDENTIFIER_NODE_KINDS: &[&str] = &["identifier", "constant"];
pub(crate) const ASSIGNMENT_NODE_KINDS: &[&str] = &["assignment", "operator_assignment"];
pub(crate) const INDEXED_LHS_NODE_KINDS: &[&str] = &["element_assignment", "element_reference"];
pub(crate) const EXPRESSION_LIST_NODE_KINDS: &[&str] = &["left_assignment_list"];
pub(crate) const ASSIGNMENT_OPERATOR_TOKENS: &[&str] =
    &["=", "+=", "-=", "*=", "/=", "%=", "&&=", "||="];
pub(crate) const PATH_ACTION_NODE_KINDS: &[&str] = &["call", "return"];
pub(crate) const SIMPLE_ACTION_WRAPPER_NODE_KINDS: &[&str] = &["body_statement"];
pub(crate) const COMPARISON_NODE_KINDS: &[&str] = &["binary"];
pub(crate) const BRANCH_NODE_KINDS: &[&str] = &[
    "if",
    "unless",
    "if_modifier",
    "unless_modifier",
    "case",
    "while",
    "until",
    "for",
];
pub(crate) const CASE_NODE_KINDS: &[&str] = &["case"];
pub(crate) const CASE_ARM_NODE_KINDS: &[&str] = &["when"];
pub(crate) const CASE_PATTERN_NODE_KINDS: &[&str] = &["pattern"];
pub(crate) const CASE_CONTAINER_STOP_NODE_KINDS: &[&str] = &["method", "class", "module"];
pub(crate) const CASE_SUBJECT_SKIP_NODE_KINDS: &[&str] = &["when", "else", "then", "comment"];
pub(crate) const DEFAULT_CASE_PATTERNS: &[&str] = &["_", "default", "else"];
pub(crate) const BOOLEAN_AND_OPERATORS: &[&str] = &["&&", "and"];
pub(crate) const BOOLEAN_CONTAINER_NODE_KINDS: &[&str] = &["binary"];
pub(crate) const BOOLEAN_WRAPPER_NODE_KINDS: &[&str] =
    &["body_statement", "pattern", "argument_list"];
pub(crate) const ACCESSOR_CALL_NODE_KINDS: &[&str] = &["call"];
pub(crate) const ARGUMENT_LIST_NODE_KINDS: &[&str] = &["argument_list"];
pub(crate) const BLOCK_ARGUMENT_NODE_KINDS: &[&str] = &["do_block", "block"];

pub(crate) const CALL_SHAPE: CallShape = CallShape {
    default_receiver: "self",
    receiver_field: "receiver",
    method_field: "method",
    method_fallback_kinds: &["identifier", "constant"],
};

pub(crate) const RAW_CALL_SHAPE: RawCallShape = RawCallShape {
    call_kind: "call",
    receiver_field: "receiver",
    message_field: "method",
    arguments_field: "arguments",
    default_receiver: "self",
    argument_list_kind: "argument_list",
    message_kinds: &["identifier", "constant"],
};

pub(crate) const VISIBILITY_DIRECTIVES: &[&str] = &["public", "protected", "private"];
pub(crate) const REQUIRE_MESSAGES: &[&str] = &["require", "require_relative"];
pub(crate) const METHOD_HOOKS: &[&str] = &["method_missing", "respond_to_missing?"];
pub(crate) const STATIC_SEMANTIC_EFFECTS: &[StaticNodeEffect] = &[
    StaticNodeEffect {
        node_kind: "yield",
        kind: "dynamic_dispatch",
        detail: "yield",
    },
    StaticNodeEffect {
        node_kind: "subshell",
        kind: "hidden_io",
        detail: "backtick",
    },
];
pub(crate) const BARE_BODY_NON_CALL_MESSAGES: &[&str] = &["true", "false", "nil", "self"];
pub(crate) const EMBEDDED_TEXT_NODE_KINDS: &[&str] = &[
    "string",
    "string_content",
    "heredoc_body",
    "simple_symbol",
    "symbol",
    "delimited_symbol",
];

pub(crate) const PROTOCOL_IGNORED_MIDS: &[&str] = &[
    "abstract!",
    "alias_method",
    "any",
    "attr_accessor",
    "attr_reader",
    "attr_writer",
    "bind",
    "cast",
    "checked",
    "enum",
    "extend",
    "final",
    "include",
    "interface!",
    "let",
    "must",
    "must_because",
    "nilable",
    "override",
    "overridable",
    "params",
    "prepend",
    "private",
    "private_class_method",
    "protected",
    "public",
    "require",
    "require_relative",
    "requires_ancestor",
    "sealed!",
    "sig",
    "type_member",
    "type_template",
    "untyped",
    "unsafe",
    "void",
    "a_kind_of",
    "after",
    "around",
    "before",
    "be",
    "be_a",
    "be_an",
    "be_empty",
    "be_falsey",
    "be_nil",
    "be_truthy",
    "change",
    "contain_exactly",
    "context",
    "describe",
    "eq",
    "eql",
    "equal",
    "expect",
    "have_attributes",
    "have_key",
    "have_received",
    "it",
    "match",
    "not_to",
    "raise_error",
    "receive",
    "subject",
    "to",
];
pub(crate) const PROTOCOL_MUTATING_MIDS: &[&str] = &[
    "<<",
    "[]=",
    "add",
    "append",
    "clear",
    "collect!",
    "compact!",
    "concat",
    "declare",
    "delete",
    "delete_if",
    "each_key=",
    "fill",
    "filter!",
    "keep_if",
    "mark",
    "merge!",
    "move",
    "push",
    "reject!",
    "replace",
    "resolve",
    "shift",
    "stamp",
    "store",
    "unshift",
    "update",
    "write",
];
pub(crate) const PROTOCOL_NON_MUTATING_OPERATOR_MIDS: &[&str] = &["!", "!=", "!~"];

pub(crate) const PROTOCOL_SHAPE: RawProtocolShape = RawProtocolShape {
    assignment_kinds: &["assignment"],
    operator_assignment_kinds: &["operator_assignment"],
    local_binding_lhs_kinds: &["identifier"],
    local_binding_container_kinds: &["block_parameters", "method_parameters"],
    local_binding_name_kinds: &["identifier"],
    direct_state_read_kinds: &["instance_variable"],
    nested_boundary_kinds: &["class", "module", "method", "singleton_method", "lambda"],
    nested_boundary_wrapper_kinds: &["body_statement"],
    nested_boundary_first_child_kinds: &["def", "class", "module"],
    method_body_wrapper_kinds: &["method", "singleton_method", "argument_list"],
    method_body_kind: "body_statement",
    branch_kinds: &["if", "unless", "if_modifier", "unless_modifier"],
    branch_wrapper_kinds: &["expression_statement", "block", "body_statement"],
    branch_wrapper_first_child_kinds: &["if", "unless"],
    modifier_branch_kinds: &["if_modifier", "unless_modifier"],
    then_body_kinds: &["then"],
    else_body_kinds: &["else", "elsif"],
    case_kinds: &["case"],
    case_wrapper_kinds: &["body_statement", "block_body", "argument_list"],
    case_wrapper_first_child_kinds: &["case"],
    case_subject_skip_kinds: &["when", "else"],
    case_branch_body_kinds: &["when", "else"],
    statement_body_kinds: &["then", "else", "body_statement", "block", "block_body"],
    path_call_kinds: &["call"],
    path_call_child_kinds: &["argument_list", "block", "do_block"],
    ignored_child_kinds: &["comment"],
    terminal_kinds: &["return", "break", "next", "redo", "retry"],
};
