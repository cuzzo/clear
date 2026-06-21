use super::{normalized_ruby, FunctionDef, Language};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default)]
pub(crate) struct SyntaxMetadata {
    pub(crate) immutable_struct_readers: BTreeMap<String, Vec<String>>,
    pub(crate) immutable_struct_reader_types: BTreeMap<String, BTreeMap<String, String>>,
    pub(crate) type_aliases: BTreeMap<String, String>,
    pub(crate) method_param_types: BTreeMap<String, BTreeMap<String, String>>,
}

pub(crate) trait NormalizedLanguageBehavior: Sync {
    fn mutating_receiver_message(&self, _message: &str) -> bool {
        false
    }

    fn syntax_metadata(&self, _source: &str, _functions: &[FunctionDef]) -> SyntaxMetadata {
        SyntaxMetadata::default()
    }
}

struct BaseNormalizedBehavior;

impl NormalizedLanguageBehavior for BaseNormalizedBehavior {}

static BASE_BEHAVIOR: BaseNormalizedBehavior = BaseNormalizedBehavior;

pub(crate) fn behavior(language: Language) -> &'static dyn NormalizedLanguageBehavior {
    match language {
        Language::Ruby => normalized_ruby::behavior(),
        _ => &BASE_BEHAVIOR,
    }
}
