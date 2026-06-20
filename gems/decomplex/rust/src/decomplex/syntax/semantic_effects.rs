use super::{FunctionDef, SemanticEffectSite, StateRead, StateWrite};
use crate::decomplex::ast::span;
use tree_sitter::Node;

pub(crate) struct StaticNodeEffect {
    pub(crate) node_kind: &'static str,
    pub(crate) kind: &'static str,
    pub(crate) detail: &'static str,
}

pub(crate) fn external_state_mutation_effects(
    state_writes: &[StateWrite],
) -> Vec<SemanticEffectSite> {
    state_writes
        .iter()
        .filter(|write| write.receiver != "self")
        .filter(|write| !write.field.starts_with('@') && !write.field.starts_with('$'))
        .map(|write| SemanticEffectSite {
            kind: "hidden_mutation".to_string(),
            detail: format!("{}=", write.field),
            file: write.file.clone(),
            function: write.function.clone(),
            line: write.line,
            span: write.span,
        })
        .collect()
}

pub(crate) fn state_read_context_dependencies<F>(
    state_reads: &[StateRead],
    context_read: F,
) -> Vec<SemanticEffectSite>
where
    F: Fn(&StateRead) -> bool,
{
    state_reads
        .iter()
        .filter(|read| context_read(read))
        .map(|read| SemanticEffectSite {
            kind: "context_dependency".to_string(),
            detail: read.field.clone(),
            file: read.file.clone(),
            function: read.function.clone(),
            line: read.line,
            span: read.span,
        })
        .collect()
}

pub(crate) fn method_hook_effects(
    functions: &[FunctionDef],
    hook_names: &[&str],
) -> Vec<SemanticEffectSite> {
    functions
        .iter()
        .filter_map(|function| {
            let name = function
                .name
                .split('.')
                .last()
                .unwrap_or(function.name.as_str());
            hook_names.contains(&name).then(|| SemanticEffectSite {
                kind: "metaprogramming".to_string(),
                detail: format!("def {name}"),
                file: function.file.clone(),
                function: function.name.clone(),
                line: function.line,
                span: function.span,
            })
        })
        .collect()
}

pub(crate) fn collect_structural_effect_nodes<F>(
    root: Node<'_>,
    source: &str,
    file: &str,
    functions: &[FunctionDef],
    effect_for_node: F,
) -> Vec<SemanticEffectSite>
where
    F: Fn(Node<'_>, &str, &str, &[FunctionDef]) -> Vec<SemanticEffectSite>,
{
    let mut out = Vec::new();
    collect_structural_effect_nodes_into(root, source, file, functions, &effect_for_node, &mut out);
    out
}

fn collect_structural_effect_nodes_into<F>(
    node: Node<'_>,
    source: &str,
    file: &str,
    functions: &[FunctionDef],
    effect_for_node: &F,
    out: &mut Vec<SemanticEffectSite>,
) where
    F: Fn(Node<'_>, &str, &str, &[FunctionDef]) -> Vec<SemanticEffectSite>,
{
    out.extend(effect_for_node(node, source, file, functions));
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_structural_effect_nodes_into(child, source, file, functions, effect_for_node, out);
    }
}

pub(crate) fn static_node_effect(
    node: Node<'_>,
    file: &str,
    functions: &[FunctionDef],
    effects: &[StaticNodeEffect],
) -> Option<SemanticEffectSite> {
    effects
        .iter()
        .find(|effect| effect.node_kind == node.kind())
        .map(|effect| site(node, file, functions, effect.kind, effect.detail))
}

pub(crate) fn site(
    node: Node<'_>,
    file: &str,
    functions: &[FunctionDef],
    kind: &str,
    detail: &str,
) -> SemanticEffectSite {
    let site_span = span(node);
    SemanticEffectSite {
        kind: kind.to_string(),
        detail: detail.to_string(),
        file: file.to_string(),
        function: effect_function(functions, site_span),
        line: site_span[0],
        span: site_span,
    }
}

fn effect_function(functions: &[FunctionDef], site_span: [usize; 4]) -> String {
    functions
        .iter()
        .filter(|function| span_contains(function.span, site_span))
        .min_by_key(|function| span_width(function.span))
        .map(|function| function.name.clone())
        .unwrap_or_else(|| "(top-level)".to_string())
}

fn span_contains(outer: [usize; 4], inner: [usize; 4]) -> bool {
    (outer[0] < inner[0] || (outer[0] == inner[0] && outer[1] <= inner[1]))
        && (outer[2] > inner[2] || (outer[2] == inner[2] && outer[3] >= inner[3]))
}

fn span_width(span: [usize; 4]) -> usize {
    span[2].saturating_sub(span[0]) * 10_000 + span[3].saturating_sub(span[1])
}
