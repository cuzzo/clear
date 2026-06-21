use super::super::Language;
use super::base::LanguageProfile;
use tree_sitter::Language as TreeSitterLanguage;

pub(crate) struct RubyProfile;

impl LanguageProfile for RubyProfile {
    fn language(&self) -> Language {
        Language::Ruby
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_ruby::LANGUAGE.into()
    }
}
