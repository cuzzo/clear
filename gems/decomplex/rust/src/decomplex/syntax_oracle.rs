use crate::decomplex::syntax::{self, Document, Language};
use anyhow::Result;
use serde_json::{json, Value};
use std::path::PathBuf;

pub const FORMAT: &str = "decomplex.syntax-facts.v1";

pub fn project_files(files: &[PathBuf], language: Language) -> Result<Value> {
    let documents = syntax::parse_files(files, language)?;
    Ok(json!({
        "format": FORMAT,
        "documents": documents.iter().map(project_document).collect::<Vec<_>>(),
    }))
}

pub fn project_document(document: &Document) -> Value {
    json!({
        "file": logical_file(&document.file),
        "language": document.language.as_str(),
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
        "branch_decisions": sorted(document.branch_decisions.iter().map(|decision| json!({
            "function": decision.function,
            "line": decision.line,
            "span": decision.span,
            "predicate": decision.predicate,
            "state_refs": decision.state_refs,
        })).collect()),
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
        "protocol_method_effects": sorted(document.protocol_method_effects.iter().map(|effect| json!({
            "owner": effect.owner,
            "name": effect.name,
            "line": effect.line,
            "reads": effect.reads,
            "writes": effect.writes,
        })).collect()),
        "protocol_call_paths": sorted(document.protocol_call_paths.iter().map(|path| json!({
            "owner": path.owner,
            "name": path.name,
            "line": path.line,
            "calls": path.calls.iter().map(|call| json!({
                "mid": call.mid,
                "line": call.line,
                "span": call.span,
            })).collect::<Vec<_>>(),
        })).collect()),
        "clone_candidates": sorted(syntax::clone_candidates(document).iter().map(|candidate| json!({
            "line": candidate.line,
            "span": candidate.span,
            "method_name": candidate.method_name,
            "node_name": candidate.node_name,
            "mass": candidate.mass,
            "fingerprint": candidate.fingerprint,
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

fn sorted(mut rows: Vec<Value>) -> Vec<Value> {
    rows.sort_by_key(|row| row.to_string());
    rows
}

fn logical_file(file: &str) -> String {
    let path = file.replace('\\', "/");
    let marker = "gems/decomplex/examples/";
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
