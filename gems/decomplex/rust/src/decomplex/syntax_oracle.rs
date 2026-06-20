use crate::decomplex::syntax::adapters::language_profile;
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
    let clone_candidates = language_profile(document.language).clone_candidates(document);

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
            "owner": "",
            "body": predicate.body,
            "line": predicate.line,
            "span": predicate.span,
        })).collect()),
        "local_complexity": document.local_complexity_scores.iter().map(|(id, score)| json!({
            "id": id,
            "score": score.score,
            "signals": score.signals,
        })).collect::<Vec<_>>(),
        "clone_candidates": sorted(clone_candidates.iter().map(|candidate| json!({
            "method_name": candidate.method_name,
            "node_name": candidate.node_name,
            "line": candidate.line,
            "span": candidate.span,
            "mass": candidate.mass,
            "fingerprint": candidate.fingerprint,
            "child_fingerprints": candidate.child_fingerprints,
            "child_masses": candidate.child_masses,
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
