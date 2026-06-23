use super::{
    normalized_behavior::NormalizedLanguageBehavior, CallSite, FunctionDef, ProtocolCall,
    ProtocolMethodEffect, ProtocolMethodPath, SemanticEffectSite, StateRead, StateWrite,
};

pub(crate) fn method_effects_from_facts(
    behavior: &dyn NormalizedLanguageBehavior,
    function_defs: &[FunctionDef],
    state_reads: &[StateRead],
    state_writes: &[StateWrite],
    call_sites: &[CallSite],
    semantic_effect_sites: &[SemanticEffectSite],
) -> Vec<ProtocolMethodEffect> {
    function_defs
        .iter()
        .map(|function_def| {
            let mut reads = state_reads
                .iter()
                .filter(|read| {
                    read.owner == function_def.owner && read.function == function_def.name
                })
                .filter_map(|read| {
                    behavior.protocol_read_label_from_state(&read.receiver, &read.field)
                })
                .collect::<Vec<_>>();
            reads.extend(
                call_sites
                    .iter()
                    .filter(|call| {
                        call.owner == function_def.owner
                            && call.function == function_def.name
                            && !semantic_effect_call(semantic_effect_sites, call)
                    })
                    .filter_map(|call| {
                        behavior.protocol_read_label_from_call(&call.receiver, &call.message)
                    }),
            );
            reads.sort();
            reads.dedup();

            let mut writes = state_writes
                .iter()
                .filter(|write| {
                    write.owner == function_def.owner && write.function == function_def.name
                })
                .filter_map(|write| behavior.protocol_write_label(&write.receiver, &write.field))
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

pub(crate) fn call_paths_from_facts(
    behavior: &dyn NormalizedLanguageBehavior,
    function_defs: &[FunctionDef],
    call_sites: &[CallSite],
    semantic_effect_sites: &[SemanticEffectSite],
) -> Vec<ProtocolMethodPath> {
    let mut out = Vec::new();
    for function_def in function_defs {
        let calls = protocol_self_calls(behavior, function_def, call_sites, semantic_effect_sites);
        let variants = if calls.is_empty() {
            protocol_empty_variants_for_function(function_def).unwrap_or_else(|| vec![Vec::new()])
        } else {
            protocol_call_variants(calls)
        };
        for calls in variants {
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

fn protocol_empty_variants_for_function(
    function_def: &FunctionDef,
) -> Option<Vec<Vec<ProtocolCall>>> {
    if protocol_conditional_body(&function_def.body) {
        Some(vec![Vec::new(), Vec::new()])
    } else {
        None
    }
}

fn protocol_call_variants(calls: Vec<(ProtocolCall, bool)>) -> Vec<Vec<ProtocolCall>> {
    let (conditional_calls, always_calls): (Vec<_>, Vec<_>) =
        calls.into_iter().partition(|(_, conditional)| *conditional);
    let always_calls = always_calls
        .into_iter()
        .map(|(call, _)| call)
        .collect::<Vec<_>>();
    if conditional_calls.is_empty() {
        return vec![always_calls];
    }

    let mut out = conditional_calls
        .into_iter()
        .map(|(conditional_call, _)| {
            let mut path = always_calls.clone();
            path.push(conditional_call);
            path.sort_by_key(|call| call.line);
            path
        })
        .collect::<Vec<_>>();
    let mut always_path = always_calls;
    always_path.sort_by_key(|call| call.line);
    out.push(always_path);
    out
}

fn protocol_method_name(name: &str) -> String {
    name.split(['.', ':'])
        .next_back()
        .unwrap_or(name)
        .trim_end_matches(['?', '!'])
        .to_string()
}

fn protocol_conditional_body(node: &crate::ast::RawNode) -> bool {
    let kind = node.kind.to_ascii_uppercase();
    matches!(kind.as_str(), "IF" | "UNLESS" | "CASE" | "CASE2" | "WHEN")
        || node.children.iter().any(protocol_conditional_body)
}

fn protocol_self_calls(
    behavior: &dyn NormalizedLanguageBehavior,
    function_def: &FunctionDef,
    call_sites: &[CallSite],
    semantic_effect_sites: &[SemanticEffectSite],
) -> Vec<(ProtocolCall, bool)> {
    call_sites
        .iter()
        .filter(|call| {
            call.owner == function_def.owner
                && call.function == function_def.name
                && !semantic_effect_call(semantic_effect_sites, call)
        })
        .filter_map(|call| {
            protocol_call(behavior, function_def, call).map(|row| (row, call.conditional))
        })
        .collect()
}

fn protocol_call(
    behavior: &dyn NormalizedLanguageBehavior,
    function_def: &FunctionDef,
    call: &CallSite,
) -> Option<ProtocolCall> {
    let mid = behavior.protocol_read_label_from_call(&call.receiver, &call.message)?;
    Some(ProtocolCall {
        mid: protocol_method_name(&mid),
        file: function_def.file.clone(),
        owner: function_def.owner.clone(),
        defn: protocol_method_name(&function_def.name),
        line: call.line,
        span: call.span,
    })
}

fn semantic_effect_call(semantic_effect_sites: &[SemanticEffectSite], call: &CallSite) -> bool {
    semantic_effect_sites.iter().any(|effect| {
        effect.function == call.function && effect.line == call.line && effect.span == call.span
    })
}
