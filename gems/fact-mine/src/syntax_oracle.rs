use crate::syntax::{self, Document, Language};
use anyhow::Result;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

pub const FORMAT: &str = "decomplex.syntax-facts.v1";
pub const CFG_SCHEMA: &str = "fact-mine.cfg.v1";

pub fn project_files(files: &[PathBuf], language: Language) -> Result<Value> {
    let documents = syntax::parse_files(files, language)?;
    let metadata = SyntaxFactMetadata::from_documents(&documents);
    Ok(json!({
        "format": FORMAT,
        "cfg_schema": CFG_SCHEMA,
        "documents": documents
            .iter()
            .map(|document| project_document_with_metadata(document, &metadata))
            .collect::<Vec<_>>(),
    }))
}

pub fn project_document(document: &Document) -> Value {
    let metadata = SyntaxFactMetadata::from_documents(std::slice::from_ref(document));
    project_document_with_metadata(document, &metadata)
}

fn project_document_with_metadata(document: &Document, metadata: &SyntaxFactMetadata) -> Value {
    let protocol_method_effects = syntax::protocol_method_effects(document);
    let protocol_call_paths = syntax::protocol_call_paths(document);
    json!({
        "file": logical_file(&document.file),
        "language": document.language.as_str(),
        "source_digest": document.source_digest,
        "functions": sorted(document.function_defs.iter().map(|function| json!({
            "name": function.name,
            "owner": function.owner,
            "line": function.line,
            "span": function.span,
            "visibility": function.visibility,
            "params": function.params,
        })).collect()),
        "owners": sorted(document.owner_defs.iter().map(|owner| json!({
            "name": owner.name,
            "kind": owner.kind,
            "line": owner.line,
            "span": owner.span,
        })).collect()),
        "calls": sorted(document.call_sites.iter().map(|call| json!({
            "receiver": call.receiver,
            "message": call.message,
            "function": call.function,
            "owner": call.owner,
            "line": call.line,
            "span": call.span,
            "conditional": call.conditional,
            "arguments": call.arguments,
            "control": call.control,
            "safe_navigation": call.safe_navigation,
            "block": call.block,
        })).collect()),
        "state_declarations": sorted(document.state_declarations.iter().map(|declaration| json!({
            "field": declaration.field,
            "owner": declaration.owner,
            "type": declaration.r#type,
            "line": declaration.line,
            "span": declaration.span,
        })).collect()),
        "state_param_origins": Vec::<Value>::new(),
        "state_reads": sorted(document.state_reads.iter().map(|read| json!({
            "field": read.field,
            "receiver": read.receiver,
            "function": read.function,
            "owner": read.owner,
            "line": read.line,
            "span": read.span,
        })).collect()),
        "state_writes": sorted(document.state_writes.iter().map(|write| json!({
            "field": write.field,
            "receiver": write.receiver,
            "function": write.function,
            "owner": write.owner,
            "line": write.line,
            "span": write.span,
        })).collect()),
        "decisions": sorted(document.decision_sites.iter().map(|decision| json!({
            "kind": decision.kind,
            "members": decision.members,
            "function": decision.function,
            "line": decision.line,
            "span": decision.span,
            "predicate": decision.predicate,
            "enclosing_span": decision.enclosing_span,
        })).collect()),
        "branch_decisions": sorted(document.branch_decisions.iter().filter_map(|decision| {
            let state_refs = decision.state_refs.iter()
                .filter(|state_ref| !metadata.immutable_state_ref(document, &decision.function, state_ref))
                .cloned()
                .collect::<Vec<_>>();
            (!state_refs.is_empty()).then(|| json!({
                "function": decision.function,
                "line": decision.line,
                "span": decision.span,
                "predicate": decision.predicate,
                "state_refs": state_refs,
            }))
        }).collect()),
        "branch_arms": sorted(document.branch_arms.iter().map(|arm| json!({
            "function": arm.function,
            "kind": arm.kind,
            "line": arm.line,
            "span": arm.span,
            "decision_line": arm.decision_line,
            "decision_span": arm.decision_span,
            "predicate": arm.predicate,
            "member": arm.member,
            "body": arm.body,
        })).collect()),
        "dispatch_sites": sorted(document.dispatch_sites.iter().map(|site| json!({
            "variant_set": site.variant_set,
            "arm_members": site.arm_members,
            "outside": site.outside,
            "function": site.function,
            "line": site.line,
            "span": site.span,
        })).collect()),
        "semantic_effects": sorted(document.semantic_effect_sites.iter().map(|site| json!({
            "kind": site.kind,
            "detail": site.detail,
            "receiver_scope": site.receiver_scope,
            "function": site.function,
            "line": site.line,
            "span": site.span,
        })).collect()),
        "predicate_bodies": sorted(document.predicate_aliases.iter().map(|predicate| json!({
            "name": predicate.name,
            "owner": predicate.owner,
            "body": predicate.body,
            "line": predicate.line,
            "span": predicate.span,
        })).collect()),
        "comparisons": sorted(document.comparison_uses.iter().map(|comparison| json!({
            "source": comparison.raw,
            "raw": comparison.raw,
            "canon_source": comparison.canon_source,
            "operator": comparison_operator(&comparison.raw),
            "function": comparison.function,
            "line": comparison.line,
            "span": comparison.span,
        })).collect()),
        "path_conditions": sorted(syntax::path_condition::fact_sites_for_document(document).iter().map(|site| json!({
            "guards": site.guards,
            "action": site.action,
            "function": site.function,
            "line": site.line,
            "span": site.span,
        })).collect()),
        "hazard_sites": sorted(document.hazard_sites.iter().map(|site| json!({
            "path": site.path,
            "line": site.line,
            "source": site.snippet,
            "hazard_type": site.hazard_type,
            "required_evidence": site.required_evidence,
            "hazard_kind": site.hazard_kind,
            "evidence_claim": site.evidence_claim,
            "coverage_required": site.coverage_required,
            "report_required": site.report_required,
            "label": site.label,
            "mitigation": site.mitigation,
            "start_column": site.start_column,
            "end_line": site.end_line,
            "end_column": site.end_column,
        })).collect()),
        "imports": sorted(document.imports.iter().map(|import| json!({
            "alias": import.alias,
            "target": import.target,
            "kind": import.kind,
            "line": import.line,
        })).collect()),
        "control_flow_nodes": sorted(syntax::cfg::projection::project_nodes(&document.control_flow_nodes)),
        "control_flow_edges": sorted(syntax::cfg::projection::project_edges(&document.control_flow_edges)),
        "control_flow_metrics": sorted(document.control_flow_metrics.iter().map(|metric| json!({
            "function": metric.function,
            "owner": metric.owner,
            "line": metric.line,
            "span": metric.span,
            "cyclomatic_complexity": metric.cyclomatic_complexity,
            "path_pressure": metric.path_pressure,
            "decision_points": metric.decision_points,
            "branch_points": metric.branch_points,
            "loop_points": metric.loop_points,
            "case_points": metric.case_points,
            "exception_points": metric.exception_points,
            "callback_points": metric.callback_points,
            "terminal_edges": metric.terminal_edges,
            "disconnected_nodes": metric.disconnected_nodes,
        })).collect()),
        "places": sorted(document.places.iter().map(|place| json!({
            "id": place.id,
            "function": place.function,
            "owner": place.owner,
            "kind": place.kind,
            "name": place.name,
            "declaration_span": place.declaration_span,
        })).collect()),
        "node_effects": sorted(document.node_effects.iter().map(|effect| json!({
            "node_id": effect.node_id,
            "function": effect.function,
            "owner": effect.owner,
            "reads": effect.reads,
            "writes": effect.writes,
            "mutations": effect.mutations,
            "write_type_hints": effect.write_type_hints,
            "write_value_hints": effect.write_value_hints,
            "unknown_call": effect.unknown_call,
            "complete": effect.complete,
            "unknown_reasons": effect.unknown_reasons,
        })).collect()),
        "reachability": sorted(document.reachability.iter().map(|fact| json!({
            "node_id": fact.node_id,
            "function": fact.function,
            "owner": fact.owner,
            "reachable": fact.reachable,
        })).collect()),
        "dominators": sorted(document.dominators.iter().map(|fact| json!({
            "node_id": fact.node_id,
            "function": fact.function,
            "owner": fact.owner,
            "immediate_dominator": fact.immediate_dominator,
        })).collect()),
        "reaching_definitions": sorted(document.reaching_definitions.iter().map(|fact| json!({
            "node_id": fact.node_id,
            "function": fact.function,
            "owner": fact.owner,
            "place_id": fact.place_id,
            "definitions": fact.definitions,
        })).collect()),
        "def_use": sorted(document.def_use.iter().map(|fact| json!({
            "definition_node_id": fact.definition_node_id,
            "function": fact.function,
            "owner": fact.owner,
            "place_id": fact.place_id,
            "uses": fact.uses,
        })).collect()),
        "liveness": sorted(document.liveness.iter().map(|fact| json!({
            "node_id": fact.node_id,
            "function": fact.function,
            "owner": fact.owner,
            "live_in": fact.live_in,
            "live_out": fact.live_out,
        })).collect()),
        "flow_types": sorted(document.flow_types.iter().map(|fact| json!({
            "node_id": fact.node_id,
            "function": fact.function,
            "owner": fact.owner,
            "place_id": fact.place_id,
            "types": fact.types,
            "complete": fact.complete,
        })).collect()),
        "protocol_method_effects": sorted(protocol_method_effects.iter().map(|effect| json!({
            "owner": effect.owner,
            "name": effect.name,
            "line": effect.line,
            "reads": effect.reads,
            "writes": effect.writes,
        })).collect()),
        "protocol_call_paths": sorted(protocol_call_paths.iter().map(|path| json!({
            "owner": path.owner,
            "name": path.name,
            "line": path.line,
            "calls": path.calls.iter().map(|call| json!({
                "mid": call.mid,
                "line": call.line,
                "span": call.span,
            })).collect::<Vec<_>>(),
        })).collect()),
        "immutable_struct_readers": &document.immutable_struct_readers,
        "immutable_struct_reader_types": &document.immutable_struct_reader_types,
        "type_aliases": &document.type_aliases,
        "type_alias_lines": &document.type_alias_lines,
        "method_param_types": &document.method_param_types,
        "clone_candidates": sorted(syntax::clone_candidates(document).iter().map(|candidate| json!({
            "line": candidate.line,
            "span": candidate.span,
            "method_name": candidate.method_name,
            "node_name": candidate.node_name,
            "mass": candidate.mass,
            "fingerprint": candidate.fingerprint,
            "raw": candidate.raw,
            "child_fingerprints": candidate.child_fingerprints,
            "child_masses": candidate.child_masses,
        })).collect()),
        "redundant_nil_guards": sorted(syntax::redundant_nil_guard::scan_documents(std::slice::from_ref(document)).iter().map(|finding| json!({
            "defn": finding.defn,
            "line": finding.line,
            "span": finding.span,
            "local": finding.local,
            "guard": finding.guard,
            "proof": finding.proof,
        })).collect()),
        "local_methods": sorted(syntax::local_flow::scan_documents(std::slice::from_ref(document)).iter().map(|method| json!({
            "id": method.id,
            "owner": method.owner,
            "name": method.name,
            "line": method.line,
            "span": method.span,
            "statements": method.statements.iter().map(|statement| json!({
                "index": statement.index,
                "line": statement.line,
                "end_line": statement.end_line,
                "span": statement.span,
                "source": statement.source,
                "reads": statement.reads,
                "writes": statement.writes,
                "dependencies": statement.dependencies,
                "co_uses": statement.co_uses,
            })).collect::<Vec<_>>(),
            "boundaries": method.boundaries.iter().map(|boundary| json!({
                "before_index": boundary.before_index,
                "after_index": boundary.after_index,
                "line": boundary.line,
                "kind": boundary.kind,
                "text": boundary.text,
            })).collect::<Vec<_>>(),
            "local_contract_assignments": syntax::local_flow::local_contract_assignments(method),
        })).collect()),
        "local_complexity_scores": sorted(document.local_complexity_scores.iter().map(|(id, score)| json!({
            "id": id,
            "score": score.score,
            "signals": score.signals,
        })).collect()),
    })
}

#[derive(Default)]
struct SyntaxFactMetadata {
    immutable_readers: BTreeMap<String, BTreeSet<String>>,
    immutable_reader_types: BTreeMap<String, BTreeMap<String, String>>,
    type_aliases: BTreeMap<String, String>,
}

impl SyntaxFactMetadata {
    fn from_documents(documents: &[Document]) -> Self {
        let mut metadata = Self::default();
        for document in documents {
            for (owner, readers) in &document.immutable_struct_readers {
                metadata
                    .immutable_readers
                    .entry(owner.clone())
                    .or_default()
                    .extend(readers.iter().cloned());
            }
            for (owner, reader_types) in &document.immutable_struct_reader_types {
                metadata
                    .immutable_reader_types
                    .entry(owner.clone())
                    .or_default()
                    .extend(reader_types.clone());
            }
            metadata.type_aliases.extend(document.type_aliases.clone());
        }
        metadata
    }

    fn immutable_state_ref(&self, document: &Document, function: &str, state_ref: &str) -> bool {
        let mut parts = state_ref.split('.').collect::<Vec<_>>();
        if parts.len() < 2 {
            return false;
        }
        let param = parts.remove(0);
        let Some(mut type_name) = document
            .method_param_types
            .get(function)
            .and_then(|params| params.get(param))
            .cloned()
        else {
            return false;
        };

        while parts.len() > 1 {
            let reader = parts.remove(0);
            let Some(next_type) = self.immutable_reader_result_type(&type_name, reader) else {
                return false;
            };
            type_name = next_type;
        }

        self.immutable_reader(&type_name, parts[0])
    }

    fn immutable_reader(&self, type_name: &str, field: &str) -> bool {
        let resolved = self.resolve_type_alias(type_name);
        let short = resolved.split("::").last().unwrap_or(&resolved);
        let field = field.trim_end_matches('?');
        self.immutable_readers
            .get(&resolved)
            .or_else(|| self.immutable_readers.get(short))
            .map(|readers| readers.contains(field))
            .unwrap_or(false)
    }

    fn immutable_reader_result_type(&self, type_name: &str, field: &str) -> Option<String> {
        let resolved = self.resolve_type_alias(type_name);
        let short = resolved.split("::").last().unwrap_or(&resolved);
        let field = field.trim_end_matches('?');
        self.immutable_reader_types
            .get(&resolved)
            .or_else(|| self.immutable_reader_types.get(short))
            .and_then(|reader_types| reader_types.get(field))
            .cloned()
    }

    fn resolve_type_alias(&self, type_name: &str) -> String {
        let mut seen = BTreeSet::new();
        let mut current = type_name.to_string();
        loop {
            if !seen.insert(current.clone()) {
                return current;
            }
            let short = current.split("::").last().unwrap_or(&current);
            let Some(next) = self
                .type_aliases
                .get(&current)
                .or_else(|| self.type_aliases.get(short))
            else {
                return current;
            };
            current = next.clone();
        }
    }
}

fn sorted(mut rows: Vec<Value>) -> Vec<Value> {
    rows.sort_by_key(|row| row.to_string());
    rows
}

fn logical_file(file: &str) -> String {
    let path = file.replace('\\', "/");
    let marker = "gems/fact-mine/examples/";
    if let Some(index) = path.find(marker) {
        return path[index..].to_string();
    }
    path
}

fn comparison_operator(source: &str) -> &str {
    for operator in ["!==", "===", "!=", "==", ">=", "<=", ">", "<"] {
        if source.contains(operator) {
            return operator;
        }
    }
    ""
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_logical_file() {
        assert_eq!(
            logical_file("gems/fact-mine/examples/foo.rb"),
            "gems/fact-mine/examples/foo.rb"
        );
        assert_eq!(logical_file("foo.rb"), "foo.rb");
    }

    #[test]
    fn test_comparison_operator() {
        assert_eq!(comparison_operator("a == b"), "==");
        assert_eq!(comparison_operator("a + b"), "");
    }

    #[test]
    fn test_project_document() {
        let doc = Document {
            file: "gems/fact-mine/examples/test.rb".to_string(),
            language: Language::Ruby,
            source_digest: String::new(),
            raw_call_spans: Vec::new(),
            symbol_scope: crate::syntax::SymbolScope::default(),
            function_defs: Vec::new(),
            owner_defs: Vec::new(),
            call_sites: Vec::new(),
            call_receiver_projections: Vec::new(),
            state_declarations: Vec::new(),
            state_reads: Vec::new(),
            state_writes: Vec::new(),
            chained_self_reads: Vec::new(),
            decision_sites: Vec::new(),
            branch_decisions: Vec::new(),
            branch_arms: Vec::new(),
            dispatch_sites: Vec::new(),
            semantic_effect_sites: Vec::new(),
            local_complexity_scores: BTreeMap::new(),
            local_methods: Vec::new(),
            predicate_aliases: Vec::new(),
            comparison_uses: Vec::new(),
            path_condition_sites: Vec::new(),
            control_flow_nodes: Vec::new(),
            control_flow_edges: Vec::new(),
            control_flow_metrics: Vec::new(),
            places: Vec::new(),
            node_effects: Vec::new(),
            reachability: Vec::new(),
            dominators: Vec::new(),
            reaching_definitions: Vec::new(),
            def_use: Vec::new(),
            liveness: Vec::new(),
            flow_types: Vec::new(),
            protocol_method_effects: Vec::new(),
            protocol_call_paths: Vec::new(),
            clone_candidates: Vec::new(),
            redundant_nil_guards: Vec::new(),
            nullable_refinements: Vec::new(),
            nullable_states: Vec::new(),
            nullable_summaries: Vec::new(),
            nullable_operations: Vec::new(),
            presence_correlations: Vec::new(),
            immutable_struct_readers: BTreeMap::new(),
            immutable_struct_reader_types: BTreeMap::new(),
            type_aliases: BTreeMap::new(),
            type_alias_lines: BTreeMap::new(),
            method_param_types: BTreeMap::new(),
            method_local_types: BTreeMap::new(),
            state_param_origins: Vec::new(),
            hazard_sites: Vec::new(),
            imports: Vec::new(),
        };
        let projected = project_document(&doc);
        assert_eq!(projected["file"], "gems/fact-mine/examples/test.rb");
    }

    #[test]
    fn test_immutable_state_ref() {
        let mut doc = Document {
            file: "foo.rb".to_string(),
            language: Language::Ruby,
            source_digest: String::new(),
            raw_call_spans: Vec::new(),
            symbol_scope: crate::syntax::SymbolScope::default(),
            function_defs: Vec::new(),
            owner_defs: Vec::new(),
            call_sites: Vec::new(),
            call_receiver_projections: Vec::new(),
            state_declarations: Vec::new(),
            state_reads: Vec::new(),
            state_writes: Vec::new(),
            chained_self_reads: Vec::new(),
            decision_sites: Vec::new(),
            branch_decisions: Vec::new(),
            branch_arms: Vec::new(),
            dispatch_sites: Vec::new(),
            semantic_effect_sites: Vec::new(),
            local_complexity_scores: BTreeMap::new(),
            local_methods: Vec::new(),
            predicate_aliases: Vec::new(),
            comparison_uses: Vec::new(),
            path_condition_sites: Vec::new(),
            control_flow_nodes: Vec::new(),
            control_flow_edges: Vec::new(),
            control_flow_metrics: Vec::new(),
            places: Vec::new(),
            node_effects: Vec::new(),
            reachability: Vec::new(),
            dominators: Vec::new(),
            reaching_definitions: Vec::new(),
            def_use: Vec::new(),
            liveness: Vec::new(),
            flow_types: Vec::new(),
            protocol_method_effects: Vec::new(),
            protocol_call_paths: Vec::new(),
            clone_candidates: Vec::new(),
            redundant_nil_guards: Vec::new(),
            nullable_refinements: Vec::new(),
            nullable_states: Vec::new(),
            nullable_summaries: Vec::new(),
            nullable_operations: Vec::new(),
            presence_correlations: Vec::new(),
            immutable_struct_readers: vec![("OtherType".to_string(), vec!["b".to_string()])]
                .into_iter()
                .collect(),
            immutable_struct_reader_types: vec![(
                "MyType".to_string(),
                vec![("a".to_string(), "OtherType".to_string())]
                    .into_iter()
                    .collect(),
            )]
            .into_iter()
            .collect(),
            type_aliases: vec![
                ("AliasType".to_string(), "MyType".to_string()),
                // loop alias to test resolve_type_alias safety loop
                ("Loop1".to_string(), "Loop2".to_string()),
                ("Loop2".to_string(), "Loop1".to_string()),
            ]
            .into_iter()
            .collect(),
            type_alias_lines: BTreeMap::new(),
            method_param_types: vec![(
                "foo".to_string(),
                vec![("obj".to_string(), "AliasType".to_string())]
                    .into_iter()
                    .collect(),
            )]
            .into_iter()
            .collect(),
            method_local_types: BTreeMap::new(),
            state_param_origins: Vec::new(),
            hazard_sites: Vec::new(),
            imports: Vec::new(),
        };

        let metadata = SyntaxFactMetadata::from_documents(&[doc.clone()]);

        // len < 2
        assert!(!metadata.immutable_state_ref(&doc, "foo", "obj"));

        // param not found
        assert!(!metadata.immutable_state_ref(&doc, "foo", "missing.field"));

        // valid simple path
        // obj has type AliasType -> resolved to MyType
        // MyType has reader field `a`? No, `a` has type OtherType
        // OtherType has reader field `b`
        assert!(metadata.immutable_state_ref(&doc, "foo", "obj.a.b"));

        // middle field doesn't have reader type
        assert!(!metadata.immutable_state_ref(&doc, "foo", "obj.unknown.b"));

        // last field not a reader
        assert!(!metadata.immutable_state_ref(&doc, "foo", "obj.a.unknown"));

        // test type alias resolution loop
        doc.method_param_types.insert(
            "loop_fn".to_string(),
            vec![("obj".to_string(), "Loop1".to_string())]
                .into_iter()
                .collect(),
        );
        let metadata_loop = SyntaxFactMetadata::from_documents(&[doc.clone()]);
        assert!(!metadata_loop.immutable_state_ref(&doc, "loop_fn", "obj.a"));
    }
}
