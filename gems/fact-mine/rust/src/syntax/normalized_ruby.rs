use super::normalized_behavior::{
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedSemanticEffect,
    SyntaxMetadata,
};
use super::{ruby_metadata, FunctionDef};
use crate::ast::{self, Node};

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
        let metadata = ruby_metadata::extract(source, functions);
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
    let children = node.children.iter().filter_map(ast::node).collect::<Vec<_>>();
    if node.r#type == "RESBODY" {
        if let Some(child) = children.get(1) {
            return ruby_nil_rescue_fallback(child);
        }
    }
    children.len() == 1 && ruby_nil_rescue_fallback(children[0])
}
