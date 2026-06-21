use super::normalized_behavior::{NormalizedLanguageBehavior, SyntaxMetadata};
use super::{ruby_metadata, FunctionDef};

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
}

static RUBY_BEHAVIOR: RubyNormalizedBehavior = RubyNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &RUBY_BEHAVIOR
}
