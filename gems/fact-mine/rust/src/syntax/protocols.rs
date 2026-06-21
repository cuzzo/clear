use super::{
    CallSite, Document, FunctionDef, ProtocolCall, ProtocolMethodEffect, ProtocolMethodPath,
    RawNode,
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

fn function_body_node(function: &RawNode) -> Option<&RawNode> {
    function
        .children
        .iter()
        .find(|child| child.kind == "body")
        .map(|scope| {
            scope
                .children
                .iter()
                .find(|child| child.kind == "body_statement")
                .unwrap_or(scope)
        })
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

fn protocol_paths_for_raw(
    document: &Document,
    function_def: &FunctionDef,
    node: &RawNode,
) -> Vec<Vec<ProtocolCall>> {
    let statements = if node.kind == "body_statement" {
        node.children.iter().collect::<Vec<_>>()
    } else {
        vec![node]
    };
    protocol_paths_for_statements(document, function_def, &statements)
}

fn protocol_paths_for_statements(
    document: &Document,
    function_def: &FunctionDef,
    statements: &[&RawNode],
) -> Vec<Vec<ProtocolCall>> {
    let mut paths = vec![Vec::new()];
    for statement in statements {
        let next = protocol_paths_for_node(document, function_def, statement);
        if next.is_empty() {
            continue;
        }
        let mut merged = Vec::new();
        for prefix in &paths {
            for suffix in &next {
                let mut path = prefix.clone();
                path.extend(suffix.clone());
                merged.push(path);
            }
        }
        paths = merged;
    }
    paths
}

fn protocol_paths_for_node(
    document: &Document,
    function_def: &FunctionDef,
    node: &RawNode,
) -> Vec<Vec<ProtocolCall>> {
    match node.kind.as_str() {
        "if" | "unless" => {
            let mut out = node
                .children
                .iter()
                .skip(1)
                .filter(|child| child.kind != "identifier")
                .flat_map(|child| protocol_paths_for_node(document, function_def, child))
                .collect::<Vec<_>>();
            out.push(Vec::new());
            out
        }
        "case" => protocol_paths_for_case(document, function_def, node),
        "body_statement" => {
            let children = node.children.iter().collect::<Vec<_>>();
            protocol_paths_for_statements(document, function_def, &children)
        }
        "call" => protocol_call_for_node(document, function_def, node)
            .map(|call| vec![vec![call]])
            .unwrap_or_default(),
        _ => {
            let children = node.children.iter().collect::<Vec<_>>();
            protocol_paths_for_statements(document, function_def, &children)
        }
    }
}

fn protocol_call_for_node(
    document: &Document,
    function_def: &FunctionDef,
    node: &RawNode,
) -> Option<ProtocolCall> {
    document
        .call_sites
        .iter()
        .find(|call| {
            call.owner == function_def.owner
                && call.function == function_def.name
                && call.receiver == "self"
                && call.span == node.span
                && !semantic_effect_call(document, call)
        })
        .map(|call| protocol_call(function_def, call))
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

fn protocol_paths_for_case(
    document: &Document,
    function_def: &FunctionDef,
    node: &RawNode,
) -> Vec<Vec<ProtocolCall>> {
    let Some(first_when) = node.children.iter().find(|child| child.kind == "when") else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut current = Some(first_when);
    let mut fallback = None;

    while let Some(when) = current {
        let (body, next, arm_fallback) = when_body_next_fallback(when);
        out.extend(protocol_paths_for_statements(document, function_def, &body));
        current = next;
        fallback = arm_fallback.or(fallback);
    }

    if let Some(fallback) = fallback {
        out.extend(protocol_paths_for_node(document, function_def, fallback));
    } else {
        out.push(Vec::new());
    }
    out
}

fn when_body_next_fallback<'a>(
    when: &'a RawNode,
) -> (Vec<&'a RawNode>, Option<&'a RawNode>, Option<&'a RawNode>) {
    let mut body = Vec::new();
    let mut next = None;
    let mut fallback = None;
    let mut children = when.children.iter().peekable();

    if children
        .peek()
        .map(|child| child.kind == "argument_list" && raw_span_contains(when.span, child.span))
        .unwrap_or(false)
    {
        children.next();
    }

    for child in children {
        if child.kind == "when" {
            next = Some(child);
            break;
        }
        if !raw_span_contains(when.span, child.span) {
            fallback = Some(child);
            break;
        }
        body.push(child);
    }

    (body, next, fallback)
}

fn raw_span_contains(outer: crate::ast::Span, inner: crate::ast::Span) -> bool {
    (outer[0] < inner[0] || (outer[0] == inner[0] && outer[1] <= inner[1]))
        && (outer[2] > inner[2] || (outer[2] == inner[2] && outer[3] >= inner[3]))
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
