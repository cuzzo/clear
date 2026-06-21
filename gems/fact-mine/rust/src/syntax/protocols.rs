use super::{
    CallSite, Document, FunctionDef, ProtocolCall, ProtocolMethodEffect, ProtocolMethodPath,
};

pub(crate) fn method_effects_from_document_facts(document: &Document) -> Vec<ProtocolMethodEffect> {
    document
        .function_defs
        .iter()
        .map(|function_def| {
            let mut reads = document
                .state_reads
                .iter()
                .filter(|read| {
                    read.owner == function_def.owner && read.function == function_def.name
                })
                .map(|read| normalize_protocol_state_ref(&read.receiver, &read.field))
                .collect::<Vec<_>>();
            reads.extend(
                document
                    .call_sites
                    .iter()
                    .filter(|call| {
                        call.owner == function_def.owner
                            && call.function == function_def.name
                            && call.receiver == "self"
                            && !semantic_effect_call(document, call)
                    })
                    .map(|call| normalize_protocol_state(&call.message)),
            );
            reads.sort();
            reads.dedup();

            let mut writes = document
                .state_writes
                .iter()
                .filter(|write| {
                    write.owner == function_def.owner && write.function == function_def.name
                })
                .map(|write| normalize_protocol_state_ref(&write.receiver, &write.field))
                .collect::<Vec<_>>();
            writes.sort();
            writes.dedup();

            ProtocolMethodEffect {
                file: function_def.file.clone(),
                owner: function_def.owner.clone(),
                name: protocol_method_name(&function_def.name),
                line: function_def.line,
                reads,
                writes,
            }
        })
        .collect()
}

pub(crate) fn call_paths_from_document_facts(document: &Document) -> Vec<ProtocolMethodPath> {
    let mut out = Vec::new();
    for function_def in &document.function_defs {
        let paths = vec![simple_protocol_calls(document, function_def)];
        let paths = if paths.is_empty() {
            vec![Vec::new()]
        } else {
            paths
        };
        for calls in paths {
            out.push(ProtocolMethodPath {
                file: function_def.file.clone(),
                owner: function_def.owner.clone(),
                name: protocol_method_name(&function_def.name),
                line: function_def.line,
                calls,
            });
        }
    }
    out
}

fn protocol_method_name(name: &str) -> String {
    name.split(['.', ':'])
        .next_back()
        .unwrap_or(name)
        .trim_end_matches(['?', '!'])
        .to_string()
}

fn normalize_protocol_state(name: &str) -> String {
    name.trim_start_matches('@')
        .trim_start_matches('$')
        .trim_end_matches(['?', '!'])
        .to_string()
}

fn simple_protocol_calls(document: &Document, function_def: &FunctionDef) -> Vec<ProtocolCall> {
    document
        .call_sites
        .iter()
        .filter(|call| {
            call.owner == function_def.owner
                && call.function == function_def.name
                && call.receiver == "self"
                && !semantic_effect_call(document, call)
        })
        .map(|call| protocol_call(function_def, call))
        .collect()
}

fn protocol_call(function_def: &FunctionDef, call: &CallSite) -> ProtocolCall {
    ProtocolCall {
        mid: protocol_method_name(&call.message),
        file: function_def.file.clone(),
        owner: function_def.owner.clone(),
        defn: protocol_method_name(&function_def.name),
        line: call.line,
        span: call.span,
    }
}

fn semantic_effect_call(document: &Document, call: &CallSite) -> bool {
    document.semantic_effect_sites.iter().any(|effect| {
        effect.function == call.function && effect.line == call.line && effect.span == call.span
    })
}

fn normalize_protocol_state_ref(receiver: &str, field: &str) -> String {
    let normalized_field = normalize_protocol_state(field);
    let receiver = receiver.trim();
    if receiver.is_empty() || receiver == "self" {
        normalized_field
    } else {
        format!(
            "{}.{}",
            normalize_protocol_state(receiver),
            normalized_field
        )
    }
}
