use super::{
    effects,
    normalized_behavior::{NormalizedLanguageBehavior, SyntaxMetadata},
    normalized_extractor, visibility, Language, LocalComplexityScore,
};
use crate::ast::Node;
use crate::syntax::complexity::local_complexity_scores;
use std::collections::BTreeMap;
use std::path::Path;

pub(crate) struct StatelessSyntaxPass<'a> {
    file: &'a Path,
    lines: &'a [String],
    normalized_root: &'a Node,
    behavior: &'a dyn NormalizedLanguageBehavior,
}

impl<'a> StatelessSyntaxPass<'a> {
    pub(crate) fn normalized(
        file: &'a Path,
        lines: &'a [String],
        normalized_root: &'a Node,
        behavior: &'a dyn NormalizedLanguageBehavior,
    ) -> Self {
        Self {
            file,
            lines,
            normalized_root,
            behavior,
        }
    }

    pub(crate) fn run(&self) -> normalized_extractor::NormalizedFacts {
        normalized_extractor::extract(self.file, self.lines, self.normalized_root, self.behavior)
    }
}

#[derive(Clone, Debug, Default)]
pub(crate) struct StatefulSyntaxMetadata {
    pub(crate) local_complexity_scores: BTreeMap<String, LocalComplexityScore>,
    pub(crate) syntax: SyntaxMetadata,
}

pub(crate) struct StatefulSyntaxPass<'a> {
    file: &'a Path,
    source: &'a str,
    language: Language,
    behavior: &'a dyn NormalizedLanguageBehavior,
}

impl<'a> StatefulSyntaxPass<'a> {
    pub(crate) fn new(
        file: &'a Path,
        source: &'a str,
        language: Language,
        behavior: &'a dyn NormalizedLanguageBehavior,
    ) -> Self {
        Self {
            file,
            source,
            language,
            behavior,
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
            syntax: self
                .behavior
                .syntax_metadata(self.source, &facts.function_defs),
        }
    }
}
