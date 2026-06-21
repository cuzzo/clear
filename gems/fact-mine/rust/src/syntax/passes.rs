use super::{
    effects, normalized_extractor, ruby_metadata, visibility, FunctionDef, Language,
    LocalComplexityScore,
};
use crate::ast::Node;
use crate::syntax::complexity::local_complexity_scores;
use std::collections::BTreeMap;
use std::path::Path;

pub(crate) struct StatelessSyntaxPass<'a> {
    file: &'a Path,
    normalized_root: &'a Node,
}

impl<'a> StatelessSyntaxPass<'a> {
    pub(crate) fn normalized(file: &'a Path, normalized_root: &'a Node) -> Self {
        Self {
            file,
            normalized_root,
        }
    }

    pub(crate) fn run(&self) -> normalized_extractor::NormalizedFacts {
        normalized_extractor::extract(self.file, self.normalized_root)
    }
}

#[derive(Clone, Debug, Default)]
pub(crate) struct StatefulSyntaxMetadata {
    pub(crate) local_complexity_scores: BTreeMap<String, LocalComplexityScore>,
    pub(crate) ruby: ruby_metadata::RubyMetadata,
}

pub(crate) struct StatefulSyntaxPass<'a> {
    file: &'a Path,
    source: &'a str,
    language: Language,
}

impl<'a> StatefulSyntaxPass<'a> {
    pub(crate) fn new(file: &'a Path, source: &'a str, language: Language) -> Self {
        Self {
            file,
            source,
            language,
        }
    }

    pub(crate) fn enrich(
        &self,
        facts: &mut normalized_extractor::NormalizedFacts,
    ) -> StatefulSyntaxMetadata {
        visibility::apply_normalized_visibility(&mut facts.function_defs, &facts.call_sites);
        facts
            .semantic_effect_sites
            .extend(effects::semantic_effect_sites_from_calls(
                self.language,
                &facts.call_sites,
                &facts.function_defs,
            ));
        effects::dedup_semantic_effect_sites(&mut facts.semantic_effect_sites);

        StatefulSyntaxMetadata {
            local_complexity_scores: local_complexity_scores(
                &self.file.to_string_lossy(),
                &facts.function_defs,
            ),
            ruby: self.ruby_metadata(&facts.function_defs),
        }
    }

    fn ruby_metadata(&self, functions: &[FunctionDef]) -> ruby_metadata::RubyMetadata {
        if self.language == Language::Ruby {
            ruby_metadata::extract(self.source, functions)
        } else {
            ruby_metadata::RubyMetadata::default()
        }
    }
}
