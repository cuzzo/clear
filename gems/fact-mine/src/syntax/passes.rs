use super::{
    cfg, clone_similarity, complexity, effects, local_flow,
    normalized_behavior::{NormalizedLanguageBehavior, SyntaxMetadata},
    normalized_extractor, nullable, path_condition, protocols, redundant_nil_guard, visibility,
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
    pub(crate) nullable_refinements: Vec<nullable::NullableRefinement>,
    pub(crate) nullable_states: Vec<nullable::NullableState>,
    pub(crate) nullable_summaries: Vec<nullable::NullableSummary>,
    pub(crate) nullable_operations: Vec<nullable::NullableOperation>,
    pub(crate) presence_correlations: Vec<nullable::PresenceCorrelation>,
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
        synthesize_accessor_functions(self.behavior, facts);
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
        let nil_guard_facts = redundant_nil_guard::normalized_facts_from_normalized(
            &file,
            self.lines,
            self.normalized_root,
            self.behavior,
        );
        let raw_nullable_states = nullable::project_states(&control_flow);
        let nullable_refinements = nullable::project_refinements(
            &nil_guard_facts.refinements,
            &control_flow,
            &raw_nullable_states,
        );
        let nullable_states =
            nullable::apply_refinements(&raw_nullable_states, &nullable_refinements, &control_flow);
        let nullable_summaries = nullable::project_summaries(&control_flow, &nullable_states);
        let nullable_operations = nullable::project_operations(
            &facts.nullable_operation_seeds,
            &control_flow,
            &nullable_states,
        );
        let presence_correlations = nullable::project_presence_correlations(
            &facts.presence_correlation_seeds,
            &control_flow,
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
            redundant_nil_guards: nil_guard_facts.redundant_guards,
            nullable_refinements,
            nullable_states,
            nullable_summaries,
            nullable_operations,
            presence_correlations,
            syntax,
        }
    }
}

/// Synthesize function definitions for accessor-declaration macro calls
/// (Ruby attr_reader/attr_writer/attr_accessor). Without these, generated
/// getters and setters are invisible to visibility and call-target facts.
fn synthesize_accessor_functions(
    behavior: &dyn NormalizedLanguageBehavior,
    facts: &mut normalized_extractor::NormalizedFacts,
) {
    let declarations = behavior.accessor_declaration_methods();
    if declarations.is_empty() {
        return;
    }

    let existing = facts
        .function_defs
        .iter()
        .map(|function| (function.owner.clone(), function.name.clone()))
        .collect::<std::collections::BTreeSet<_>>();

    let mut synthesized = Vec::new();
    for call in &facts.call_sites {
        let Some((_, reader, writer)) = declarations
            .iter()
            .find(|(message, _, _)| *message == call.message)
        else {
            continue;
        };
        if !(call.receiver.is_empty() || call.receiver == "self") {
            continue;
        }
        for argument in &call.arguments {
            let name = argument
                .trim()
                .trim_start_matches(':')
                .trim_matches(|c| c == '"' || c == '\'');
            if name.is_empty() || !name.chars().all(|c| c.is_alphanumeric() || c == '_') {
                continue;
            }
            let mut emit = |method_name: String, params: Vec<String>| {
                if existing.contains(&(call.owner.clone(), method_name.clone())) {
                    return;
                }
                synthesized.push(super::FunctionDef::synthetic_accessor(
                    call.file.clone(),
                    method_name,
                    call.owner.clone(),
                    call.line,
                    call.span,
                    params.clone(),
                ));
            };
            if *reader {
                emit(name.to_string(), Vec::new());
            }
            if *writer {
                emit(format!("{name}="), vec!["value".to_string()]);
            }
        }
    }
    facts.function_defs.extend(synthesized);
}
