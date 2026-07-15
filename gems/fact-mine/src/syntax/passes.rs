use super::{
    cfg, clone_similarity, complexity, effects, local_flow,
    normalized_behavior::{NormalizedLanguageBehavior, SyntaxMetadata},
    normalized_extractor, path_condition, protocols, redundant_nil_guard, visibility,
    CloneCandidate, LocalComplexityScore, PathConditionSite, ProtocolMethodEffect,
    ProtocolMethodPath,
};
use crate::ast::Node;
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
    pub(crate) local_methods: Vec<local_flow::MethodSummary>,
    pub(crate) local_complexity_scores: BTreeMap<String, LocalComplexityScore>,
    pub(crate) path_condition_sites: Vec<PathConditionSite>,
    pub(crate) control_flow: cfg::ControlFlowFacts,
    pub(crate) control_flow_metrics: Vec<cfg::ControlFlowMetric>,
    pub(crate) protocol_method_effects: Vec<ProtocolMethodEffect>,
    pub(crate) protocol_call_paths: Vec<ProtocolMethodPath>,
    pub(crate) clone_candidates: Vec<CloneCandidate>,
    pub(crate) redundant_nil_guards: Vec<redundant_nil_guard::RedundantNilGuardRow>,
    pub(crate) syntax: SyntaxMetadata,
}

pub(crate) struct StatefulSyntaxPass<'a> {
    file: &'a Path,
    source: &'a str,
    lines: &'a [String],
    normalized_root: &'a Node,
    behavior: &'a dyn NormalizedLanguageBehavior,
}

impl<'a> StatefulSyntaxPass<'a> {
    pub(crate) fn new(
        file: &'a Path,
        source: &'a str,
        lines: &'a [String],
        normalized_root: &'a Node,
        behavior: &'a dyn NormalizedLanguageBehavior,
    ) -> Self {
        Self {
            file,
            source,
            lines,
            normalized_root,
            behavior,
        }
    }

    pub(crate) fn enrich(
        &self,
        facts: &mut normalized_extractor::NormalizedFacts,
    ) -> StatefulSyntaxMetadata {
        let visibility_events = self
            .behavior
            .visibility_events_from_calls(&facts.call_sites);
        visibility::apply_normalized_visibility(&mut facts.function_defs, &visibility_events);
        facts
            .semantic_effect_sites
            .extend(effects::semantic_effect_sites_from_calls(
                self.behavior,
                &facts.call_sites,
                &facts.function_defs,
            ));
        // The extractor records an opaque aggregate escape before all
        // declarations have been seen. Once the document is complete, remove
        // the conservative marker for a statically known local self-call: its
        // reads are represented by the callee's own facts instead.
        facts.semantic_effect_sites.retain(|site| {
            site.kind != "opaque_state_escape"
                || !facts.call_sites.iter().any(|call| {
                    call.file == site.file
                        && call.function == site.function
                        && call.line == site.line
                        && call.receiver == "self"
                        && facts.function_defs.iter().any(|function| {
                            function.owner == call.owner && function.name == call.message
                        })
                })
        });
        effects::dedup_semantic_effect_sites(&mut facts.semantic_effect_sites);

        let file = self.file.to_string_lossy().to_string();
        let syntax = self
            .behavior
            .syntax_metadata(self.source, &facts.function_defs);
        let local_methods = local_flow::local_methods_from_normalized(
            &file,
            self.lines,
            self.normalized_root,
            &facts.function_defs,
            &syntax.method_param_types,
            self.behavior,
        );
        let path_condition_sites =
            path_condition::normalized_fact_sites(&file, self.lines, self.normalized_root);
        let control_flow = cfg::build(&local_methods, self.behavior);
        let control_flow_metrics = cfg::metrics(&control_flow);
        let protocol_method_effects = protocols::method_effects_from_facts(
            self.behavior,
            &facts.function_defs,
            &facts.state_reads,
            &facts.state_writes,
            &facts.call_sites,
            &facts.semantic_effect_sites,
        );
        let protocol_call_paths = protocols::call_paths_from_facts(
            self.behavior,
            &facts.function_defs,
            &facts.call_sites,
            &facts.semantic_effect_sites,
        );
        let clone_candidates =
            clone_similarity::clone_candidates_from_normalized(&file, self.normalized_root);
        let redundant_nil_guards = redundant_nil_guard::scan_normalized(
            &file,
            self.lines,
            self.normalized_root,
            self.behavior,
        );

        StatefulSyntaxMetadata {
            local_complexity_scores: complexity::local_complexity_scores_from_methods(
                &local_methods,
            ),
            local_methods,
            path_condition_sites,
            control_flow,
            control_flow_metrics,
            protocol_method_effects,
            protocol_call_paths,
            clone_candidates,
            redundant_nil_guards,
            syntax,
        }
    }
}
