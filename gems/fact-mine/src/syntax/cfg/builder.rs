use super::{
    branches::{self, Branch},
    callbacks::{self, CallbackKind, CallbackRegion},
    cases::{self, Case},
    exceptions::{self, ExceptionRegion, ExceptionRegionKind},
    exits::{self, FunctionExitKind, LoopExitKind},
    loops::{self, Loop},
    short_circuit::{self, ShortCircuitOutcome},
    statements::{
        branch_statement_node, callback_statement_node, case_statement_node, entry_node,
        exception_statement_node, exit_node, loop_statement_node, nested_branch_node,
        nested_callback_node, nested_case_node, nested_exception_node, nested_loop_node,
        nested_statement_node, statement_node,
    },
    validation, ControlFlowEdge, ControlFlowFacts, ControlFlowNode, ControlFlowProfile,
    MethodCursor,
};
use crate::ast::Node;
use crate::syntax::{
    local_flow::{MethodSummary, Statement},
    normalized_behavior::NormalizedLanguageBehavior,
    Span,
};
use std::cmp::Ordering;

pub(crate) fn build(
    methods: &[MethodSummary],
    behavior: &dyn NormalizedLanguageBehavior,
) -> ControlFlowFacts {
    let mut facts = ControlFlowFacts::default();
    let mut ordered_methods = methods.iter().collect::<Vec<_>>();
    ordered_methods.sort_by(|a, b| compare_methods(a, b));

    for method in ordered_methods {
        append_method_graph(method, behavior.cfg_profile(), &mut facts);
    }

    let validation_errors = validation::errors(&facts);
    debug_assert!(
        validation_errors.is_empty(),
        "invalid control-flow graph:\n{}",
        validation_errors.join("\n")
    );

    facts
}

#[derive(Clone, Debug)]
struct PendingEdge {
    from: String,
    kind: String,
    line: usize,
    span: Span,
    target: PendingTarget,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PendingTarget {
    Sequence,
    LoopBreak,
    LoopContinue,
    FunctionExit,
}

#[derive(Clone, Debug)]
struct LoopTarget;

#[derive(Clone, Debug)]
struct SequenceItem<'a> {
    statement: Option<&'a Statement>,
    node: Option<&'a Node>,
    path: String,
}

fn append_method_graph(
    method: &MethodSummary,
    profile: &ControlFlowProfile,
    facts: &mut ControlFlowFacts,
) {
    let cursor = MethodCursor::new(
        &method.file,
        &method.owner,
        &method.name,
        method.line,
        method.span,
        method.statements.len(),
    );

    facts.nodes.push(entry_node(&cursor));

    let items = method
        .statements
        .iter()
        .map(|statement| SequenceItem {
            statement: Some(statement),
            node: branches::find_by_span(&method.node, statement.span),
            path: statement.index.to_string(),
        })
        .collect::<Vec<_>>();
    let exits = append_sequence(
        &items,
        vec![PendingEdge {
            from: cursor.entry_id(),
            kind: if items.is_empty() {
                "fallthrough"
            } else {
                "entry"
            }
            .to_string(),
            line: method.line,
            span: method.span,
            target: PendingTarget::Sequence,
        }],
        &cursor,
        facts,
        &[],
        profile,
    );

    let exit_id = cursor.exit_id();
    connect_pending(exits, &exit_id, &cursor, facts);
    facts.nodes.push(exit_node(&cursor));
}

fn append_sequence(
    items: &[SequenceItem<'_>],
    mut pending: Vec<PendingEdge>,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
    loop_stack: &[LoopTarget],
    profile: &ControlFlowProfile,
) -> Vec<PendingEdge> {
    for item in items {
        let (flow, mut bypass) = split_pending(pending);
        if !flow.is_empty() {
            bypass.extend(append_item(item, flow, cursor, facts, loop_stack, profile));
        }
        pending = bypass;
    }
    pending
}

fn append_item(
    item: &SequenceItem<'_>,
    pending: Vec<PendingEdge>,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
    loop_stack: &[LoopTarget],
    profile: &ControlFlowProfile,
) -> Vec<PendingEdge> {
    if let Some(exception) = item.node.and_then(exceptions::from_node) {
        return append_exception(item, exception, pending, cursor, facts, loop_stack, profile);
    }
    if let Some(cfg_case) = item.node.and_then(cases::from_node) {
        return append_case(item, cfg_case, pending, cursor, facts, loop_stack, profile);
    }
    if let Some(cfg_loop) = item.node.and_then(|node| loops::from_node(node, profile)) {
        return append_loop(item, cfg_loop, pending, cursor, facts, loop_stack, profile);
    }
    if let Some(callback) = item
        .node
        .and_then(|node| callbacks::from_node(node, profile))
    {
        return append_callback(item, callback, pending, cursor, facts, loop_stack, profile);
    }
    if let Some(branch) = item.node.and_then(branches::from_node) {
        return append_branch(item, branch, pending, cursor, facts, loop_stack, profile);
    }
    if let Some(exit_kind) = item.node.and_then(exits::loop_exit) {
        return append_loop_exit(item, exit_kind, pending, cursor, facts, loop_stack);
    }
    if let Some(exit_kind) = item.node.and_then(exits::function_exit) {
        return append_function_exit(item, exit_kind, pending, cursor, facts);
    }

    let node = simple_node(item, cursor);
    let node_id = node.id.clone();
    let line = node.line;
    let span = node.span;
    facts.nodes.push(node);
    connect_pending(pending, &node_id, cursor, facts);

    vec![PendingEdge {
        from: node_id,
        kind: "fallthrough".to_string(),
        line,
        span,
        target: PendingTarget::Sequence,
    }]
}

fn append_function_exit(
    item: &SequenceItem<'_>,
    exit_kind: FunctionExitKind,
    pending: Vec<PendingEdge>,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
) -> Vec<PendingEdge> {
    let node = control_exit_node(item, exit_kind.role(), cursor);
    let node_id = node.id.clone();
    let line = node.line;
    let span = node.span;
    facts.nodes.push(node);
    connect_pending(pending, &node_id, cursor, facts);

    vec![PendingEdge {
        from: node_id,
        kind: exit_kind.edge_kind().to_string(),
        line,
        span,
        target: PendingTarget::FunctionExit,
    }]
}

fn append_exception(
    item: &SequenceItem<'_>,
    exception: ExceptionRegion<'_>,
    pending: Vec<PendingEdge>,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
    loop_stack: &[LoopTarget],
    profile: &ControlFlowProfile,
) -> Vec<PendingEdge> {
    match exception.kind {
        ExceptionRegionKind::Rescue => {
            append_rescue(item, exception, pending, cursor, facts, loop_stack, profile)
        }
        ExceptionRegionKind::Ensure => {
            append_ensure(item, exception, pending, cursor, facts, loop_stack, profile)
        }
    }
}

fn append_rescue(
    item: &SequenceItem<'_>,
    exception: ExceptionRegion<'_>,
    pending: Vec<PendingEdge>,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
    loop_stack: &[LoopTarget],
    profile: &ControlFlowProfile,
) -> Vec<PendingEdge> {
    let node = exception_node(item, exception.kind.role(), cursor);
    let node_id = node.id.clone();
    let line = node.line;
    let span = node.span;
    facts.nodes.push(node);
    connect_pending(pending, &node_id, cursor, facts);

    let mut exits = append_sequence(
        &nested_items(&exception.body, &format!("{}.try", item.path)),
        vec![PendingEdge {
            from: node_id.clone(),
            kind: "try_body".to_string(),
            line,
            span,
            target: PendingTarget::Sequence,
        }],
        cursor,
        facts,
        loop_stack,
        profile,
    );

    for (index, handler) in exception.handlers.iter().enumerate() {
        exits.extend(append_sequence(
            &nested_items(&handler.body, &format!("{}.rescue{index}", item.path)),
            vec![PendingEdge {
                from: node_id.clone(),
                kind: "rescue_handler".to_string(),
                line,
                span,
                target: PendingTarget::Sequence,
            }],
            cursor,
            facts,
            loop_stack,
            profile,
        ));
    }

    if !exception.fallback.is_empty() {
        exits.extend(append_sequence(
            &nested_items(&exception.fallback, &format!("{}.rescue_else", item.path)),
            vec![PendingEdge {
                from: node_id,
                kind: "rescue_else".to_string(),
                line,
                span,
                target: PendingTarget::Sequence,
            }],
            cursor,
            facts,
            loop_stack,
            profile,
        ));
    }

    exits
}

fn append_ensure(
    item: &SequenceItem<'_>,
    exception: ExceptionRegion<'_>,
    pending: Vec<PendingEdge>,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
    loop_stack: &[LoopTarget],
    profile: &ControlFlowProfile,
) -> Vec<PendingEdge> {
    let node = exception_node(item, exception.kind.role(), cursor);
    let node_id = node.id.clone();
    let line = node.line;
    let span = node.span;
    facts.nodes.push(node);
    connect_pending(pending, &node_id, cursor, facts);

    let body_exits = append_sequence(
        &nested_items(&exception.body, &format!("{}.ensure_body", item.path)),
        vec![PendingEdge {
            from: node_id,
            kind: "ensure_body".to_string(),
            line,
            span,
            target: PendingTarget::Sequence,
        }],
        cursor,
        facts,
        loop_stack,
        profile,
    );

    if exception.cleanup.is_empty() {
        return body_exits;
    }

    body_exits
        .into_iter()
        .enumerate()
        .flat_map(|(index, body_exit)| {
            append_cleanup_for_exit(
                item,
                &exception.cleanup,
                body_exit,
                index,
                cursor,
                facts,
                loop_stack,
                profile,
            )
        })
        .collect()
}

fn append_cleanup_for_exit(
    item: &SequenceItem<'_>,
    cleanup: &[&Node],
    body_exit: PendingEdge,
    index: usize,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
    loop_stack: &[LoopTarget],
    profile: &ControlFlowProfile,
) -> Vec<PendingEdge> {
    let cleanup_exits = append_sequence(
        &nested_items(cleanup, &format!("{}.ensure_cleanup{index}", item.path)),
        vec![PendingEdge {
            from: body_exit.from.clone(),
            kind: "ensure_cleanup".to_string(),
            line: body_exit.line,
            span: body_exit.span,
            target: PendingTarget::Sequence,
        }],
        cursor,
        facts,
        loop_stack,
        profile,
    );

    cleanup_exits
        .into_iter()
        .map(|cleanup_exit| match cleanup_exit.target {
            PendingTarget::Sequence => PendingEdge {
                from: cleanup_exit.from,
                kind: body_exit.kind.clone(),
                line: body_exit.line,
                span: body_exit.span,
                target: body_exit.target,
            },
            _ => cleanup_exit,
        })
        .collect()
}

fn append_callback(
    item: &SequenceItem<'_>,
    callback: CallbackRegion<'_>,
    pending: Vec<PendingEdge>,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
    loop_stack: &[LoopTarget],
    profile: &ControlFlowProfile,
) -> Vec<PendingEdge> {
    let node = callback_node(item, callback.kind.role(), cursor);
    let node_id = node.id.clone();
    let line = node.line;
    let span = node.span;
    facts.nodes.push(node);
    connect_pending(pending, &node_id, cursor, facts);

    match callback.kind {
        CallbackKind::Block => {
            let exits = append_sequence(
                &nested_items(&callback.body, &format!("{}.callback", item.path)),
                vec![PendingEdge {
                    from: node_id,
                    kind: "callback_body".to_string(),
                    line,
                    span,
                    target: PendingTarget::Sequence,
                }],
                cursor,
                facts,
                loop_stack,
                profile,
            );
            map_sequence_edge_kind(exits, "callback_return")
        }
        CallbackKind::Yield => vec![PendingEdge {
            from: node_id,
            kind: "yield_return".to_string(),
            line,
            span,
            target: PendingTarget::Sequence,
        }],
    }
}

fn append_branch(
    item: &SequenceItem<'_>,
    branch: Branch<'_>,
    pending: Vec<PendingEdge>,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
    loop_stack: &[LoopTarget],
    profile: &ControlFlowProfile,
) -> Vec<PendingEdge> {
    let node = branch_node(item, branch.kind.role(), cursor);
    let node_id = node.id.clone();
    let line = node.line;
    let span = node.span;
    facts.nodes.push(node);
    connect_pending(pending, &node_id, cursor, facts);

    let mut then_incoming = vec![PendingEdge {
        from: node_id.clone(),
        kind: branch.kind.then_edge_kind().to_string(),
        line,
        span,
        target: PendingTarget::Sequence,
    }];
    let mut else_incoming = vec![PendingEdge {
        from: node_id.clone(),
        kind: branch.kind.else_edge_kind().to_string(),
        line,
        span,
        target: PendingTarget::Sequence,
    }];
    for outcome in short_circuit::outcomes(branch.condition) {
        let target = match outcome {
            ShortCircuitOutcome::ConditionTrue => branch.kind.edge_for_condition_outcome(true),
            ShortCircuitOutcome::ConditionFalse => branch.kind.edge_for_condition_outcome(false),
        };
        let pending = PendingEdge {
            from: node_id.clone(),
            kind: "short_circuit".to_string(),
            line,
            span,
            target: PendingTarget::Sequence,
        };
        if target == branch.kind.then_edge_kind() {
            then_incoming.push(pending);
        } else {
            else_incoming.push(pending);
        }
    }

    let mut exits = append_sequence(
        &nested_items(&branch.then_body, &format!("{}.then", item.path)),
        then_incoming,
        cursor,
        facts,
        loop_stack,
        profile,
    );
    exits.extend(append_sequence(
        &nested_items(&branch.else_body, &format!("{}.else", item.path)),
        else_incoming,
        cursor,
        facts,
        loop_stack,
        profile,
    ));
    exits
}

fn append_case(
    item: &SequenceItem<'_>,
    cfg_case: Case<'_>,
    pending: Vec<PendingEdge>,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
    loop_stack: &[LoopTarget],
    profile: &ControlFlowProfile,
) -> Vec<PendingEdge> {
    let node = case_node(item, cfg_case.kind.role(), cursor);
    let node_id = node.id.clone();
    let line = node.line;
    let span = node.span;
    facts.nodes.push(node);
    connect_pending(pending, &node_id, cursor, facts);

    let mut exits = Vec::new();
    for (index, arm) in cfg_case.arms.iter().enumerate() {
        exits.extend(append_sequence(
            &nested_items(&arm.body, &format!("{}.case{index}", item.path)),
            vec![PendingEdge {
                from: node_id.clone(),
                kind: "case_arm".to_string(),
                line,
                span,
                target: PendingTarget::Sequence,
            }],
            cursor,
            facts,
            loop_stack,
            profile,
        ));
    }
    exits.extend(append_sequence(
        &nested_items(&cfg_case.fallback, &format!("{}.default", item.path)),
        vec![PendingEdge {
            from: node_id,
            kind: "case_default".to_string(),
            line,
            span,
            target: PendingTarget::Sequence,
        }],
        cursor,
        facts,
        loop_stack,
        profile,
    ));
    exits
}

fn append_loop(
    item: &SequenceItem<'_>,
    cfg_loop: Loop<'_>,
    pending: Vec<PendingEdge>,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
    loop_stack: &[LoopTarget],
    profile: &ControlFlowProfile,
) -> Vec<PendingEdge> {
    let _condition = cfg_loop.condition;
    let node = loop_node(item, cfg_loop.kind.role(), cursor);
    let node_id = node.id.clone();
    let line = node.line;
    let span = node.span;
    facts.nodes.push(node);
    connect_pending(pending, &node_id, cursor, facts);

    let mut nested_stack = loop_stack.to_vec();
    nested_stack.push(LoopTarget);
    let body_exits = append_sequence(
        &nested_items(&cfg_loop.body, &format!("{}.loop", item.path)),
        vec![PendingEdge {
            from: node_id.clone(),
            kind: "loop_body".to_string(),
            line,
            span,
            target: PendingTarget::Sequence,
        }],
        cursor,
        facts,
        &nested_stack,
        profile,
    );

    let (normal_exits, loop_jumps) = split_pending(body_exits);
    connect_pending_as(normal_exits, &node_id, "loop_backedge", cursor, facts);
    let (breaks, remaining_jumps): (Vec<_>, Vec<_>) = loop_jumps
        .into_iter()
        .partition(|pending| pending.target == PendingTarget::LoopBreak);
    let (continues, outer_jumps): (Vec<_>, Vec<_>) = remaining_jumps
        .into_iter()
        .partition(|pending| pending.target == PendingTarget::LoopContinue);
    connect_pending_as(continues, &node_id, "continue", cursor, facts);

    let mut exits = vec![PendingEdge {
        from: node_id,
        kind: "loop_exit".to_string(),
        line,
        span,
        target: PendingTarget::Sequence,
    }];
    exits.extend(breaks.into_iter().map(|mut pending| {
        pending.target = PendingTarget::Sequence;
        pending
    }));
    exits.extend(outer_jumps);
    exits
}

fn append_loop_exit(
    item: &SequenceItem<'_>,
    exit_kind: LoopExitKind,
    pending: Vec<PendingEdge>,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
    loop_stack: &[LoopTarget],
) -> Vec<PendingEdge> {
    if loop_stack.is_empty() {
        let node = simple_node(item, cursor);
        let node_id = node.id.clone();
        let line = node.line;
        let span = node.span;
        facts.nodes.push(node);
        connect_pending(pending, &node_id, cursor, facts);
        return vec![PendingEdge {
            from: node_id,
            kind: "fallthrough".to_string(),
            line,
            span,
            target: PendingTarget::Sequence,
        }];
    }

    let node = control_exit_node(item, exit_kind.role(), cursor);
    let node_id = node.id.clone();
    let line = node.line;
    let span = node.span;
    facts.nodes.push(node);
    connect_pending(pending, &node_id, cursor, facts);

    vec![PendingEdge {
        from: node_id,
        kind: exit_kind.edge_kind().to_string(),
        line,
        span,
        target: match exit_kind {
            LoopExitKind::Break => PendingTarget::LoopBreak,
            LoopExitKind::Continue => PendingTarget::LoopContinue,
        },
    }]
}

fn simple_node(item: &SequenceItem<'_>, cursor: &MethodCursor) -> ControlFlowNode {
    if let Some(statement) = item.statement {
        return statement_node(cursor, statement);
    }

    let node = item.node.expect("nested sequence item has a node");
    nested_statement_node(
        cursor,
        cursor.synthetic_id("stmt", &item.path, node.first_lineno, node.first_column),
        node,
    )
}

fn branch_node(
    item: &SequenceItem<'_>,
    branch_role: &str,
    cursor: &MethodCursor,
) -> ControlFlowNode {
    if let Some(statement) = item.statement {
        return branch_statement_node(cursor, statement, branch_role);
    }

    let node = item.node.expect("nested branch item has a node");
    nested_branch_node(
        cursor,
        cursor.synthetic_id("branch", &item.path, node.first_lineno, node.first_column),
        node,
        branch_role,
    )
}

fn case_node(item: &SequenceItem<'_>, case_role: &str, cursor: &MethodCursor) -> ControlFlowNode {
    if let Some(statement) = item.statement {
        return case_statement_node(cursor, statement, case_role);
    }

    let node = item.node.expect("nested case item has a node");
    nested_case_node(
        cursor,
        cursor.synthetic_id("case", &item.path, node.first_lineno, node.first_column),
        node,
        case_role,
    )
}

fn callback_node(
    item: &SequenceItem<'_>,
    callback_role: &str,
    cursor: &MethodCursor,
) -> ControlFlowNode {
    if let Some(statement) = item.statement {
        return callback_statement_node(cursor, statement, callback_role);
    }

    let node = item.node.expect("nested callback item has a node");
    nested_callback_node(
        cursor,
        cursor.synthetic_id("callback", &item.path, node.first_lineno, node.first_column),
        node,
        callback_role,
    )
}

fn exception_node(
    item: &SequenceItem<'_>,
    exception_role: &str,
    cursor: &MethodCursor,
) -> ControlFlowNode {
    if let Some(statement) = item.statement {
        return exception_statement_node(cursor, statement, exception_role);
    }

    let node = item.node.expect("nested exception item has a node");
    nested_exception_node(
        cursor,
        cursor.synthetic_id(
            "exception",
            &item.path,
            node.first_lineno,
            node.first_column,
        ),
        node,
        exception_role,
    )
}

fn loop_node(item: &SequenceItem<'_>, loop_role: &str, cursor: &MethodCursor) -> ControlFlowNode {
    if let Some(statement) = item.statement {
        return loop_statement_node(cursor, statement, loop_role);
    }

    let node = item.node.expect("nested loop item has a node");
    nested_loop_node(
        cursor,
        cursor.synthetic_id("loop", &item.path, node.first_lineno, node.first_column),
        node,
        loop_role,
    )
}

fn control_exit_node(
    item: &SequenceItem<'_>,
    role: &str,
    cursor: &MethodCursor,
) -> ControlFlowNode {
    let node = item.node.expect("control exit item has a node");
    super::statements::control_exit_node(
        cursor,
        cursor.synthetic_id(role, &item.path, node.first_lineno, node.first_column),
        node,
        role,
    )
}

fn nested_items<'a>(nodes: &[&'a Node], prefix: &str) -> Vec<SequenceItem<'a>> {
    nodes
        .iter()
        .enumerate()
        .map(|(index, node)| SequenceItem {
            statement: None,
            node: Some(*node),
            path: format!("{prefix}.{index}"),
        })
        .collect()
}

fn split_pending(pending: Vec<PendingEdge>) -> (Vec<PendingEdge>, Vec<PendingEdge>) {
    pending
        .into_iter()
        .partition(|pending| pending.target == PendingTarget::Sequence)
}

fn map_sequence_edge_kind(pending: Vec<PendingEdge>, kind: &str) -> Vec<PendingEdge> {
    pending
        .into_iter()
        .map(|mut pending| {
            if pending.target == PendingTarget::Sequence {
                pending.kind = kind.to_string();
            }
            pending
        })
        .collect()
}

fn connect_pending(
    pending: Vec<PendingEdge>,
    to: &str,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
) {
    facts.edges.extend(pending.into_iter().map(|pending| {
        edge(
            cursor,
            pending.from,
            to.to_string(),
            &pending.kind,
            pending.line,
            pending.span,
        )
    }));
}

fn connect_pending_as(
    pending: Vec<PendingEdge>,
    to: &str,
    kind: &str,
    cursor: &MethodCursor,
    facts: &mut ControlFlowFacts,
) {
    facts.edges.extend(pending.into_iter().map(|pending| {
        edge(
            cursor,
            pending.from,
            to.to_string(),
            kind,
            pending.line,
            pending.span,
        )
    }));
}

fn edge(
    cursor: &MethodCursor,
    from: String,
    to: String,
    kind: &str,
    line: usize,
    span: Span,
) -> ControlFlowEdge {
    ControlFlowEdge {
        file: cursor.file().to_string(),
        function: cursor.function().to_string(),
        owner: cursor.owner().to_string(),
        from,
        to,
        kind: kind.to_string(),
        line,
        span,
    }
}

fn compare_methods(left: &MethodSummary, right: &MethodSummary) -> Ordering {
    left.file
        .cmp(&right.file)
        .then_with(|| left.line.cmp(&right.line))
        .then_with(|| left.span.cmp(&right.span))
        .then_with(|| left.owner.cmp(&right.owner))
        .then_with(|| left.name.cmp(&right.name))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{Child, Node};
    use std::collections::BTreeSet;

    struct TestBehavior;

    const TEST_PROFILE: ControlFlowProfile = ControlFlowProfile {
        iterator_messages: &["each"],
        ignored_callback_body_sources: &["do end", "{}"],
    };

    impl NormalizedLanguageBehavior for TestBehavior {
        fn cfg_profile(&self) -> &'static ControlFlowProfile {
            &TEST_PROFILE
        }
    }

    fn build_for_test(methods: &[MethodSummary]) -> ControlFlowFacts {
        build(methods, &TestBehavior)
    }

    #[test]
    fn empty_body_connects_entry_to_exit() {
        let facts = build_for_test(&[method("empty", 3, Vec::new())]);

        assert_eq!(node_kinds(&facts), ["entry", "exit"]);
        assert_eq!(facts.edges.len(), 1);
        assert_eq!(facts.edges[0].kind, "fallthrough");
        assert_eq!(facts.edges[0].from, facts.nodes[0].id);
        assert_eq!(facts.edges[0].to, facts.nodes[1].id);
    }

    #[test]
    fn single_statement_has_entry_and_exit_edges() {
        let facts = build_for_test(&[method("run", 3, vec![statement(0, 4, "work()")])]);

        assert_eq!(node_kinds(&facts), ["entry", "statement", "exit"]);
        assert_eq!(edge_kinds(&facts), ["entry", "fallthrough"]);
        assert_eq!(facts.nodes[1].source, "work()");
        assert_eq!(facts.edges[0].from, facts.nodes[0].id);
        assert_eq!(facts.edges[0].to, facts.nodes[1].id);
        assert_eq!(facts.edges[1].from, facts.nodes[1].id);
        assert_eq!(facts.edges[1].to, facts.nodes[2].id);
    }

    #[test]
    fn multi_statement_body_has_linear_fallthrough() {
        let facts = build_for_test(&[method(
            "run",
            3,
            vec![statement(0, 4, "a = 1"), statement(1, 5, "b = a")],
        )]);

        assert_eq!(
            node_kinds(&facts),
            ["entry", "statement", "statement", "exit"]
        );
        assert_eq!(edge_kinds(&facts), ["entry", "fallthrough", "fallthrough"]);
        assert_eq!(facts.edges[1].from, facts.nodes[1].id);
        assert_eq!(facts.edges[1].to, facts.nodes[2].id);
        assert_eq!(facts.edges[2].from, facts.nodes[2].id);
        assert_eq!(facts.edges[2].to, facts.nodes[3].id);
    }

    #[test]
    fn if_statement_splits_and_joins() {
        let if_node = if_node(
            "IF",
            condition("ready?"),
            vec![call_node(5, 6, "publish(input)")],
            vec![call_node(7, 6, "warn(input)")],
        );
        let after = statement(1, 9, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &if_node), after.clone()],
            tree(vec![if_node, node_for_statement(&after)]),
        )]);

        let branch = node_with_source(&facts, "if ready? publish(input) else warn(input) end");
        let then_node = node_with_source(&facts, "publish(input)");
        let else_node = node_with_source(&facts, "warn(input)");
        let after_node = node_with_source(&facts, "finish()");

        assert_eq!(branch.kind, "branch");
        assert_edge(&facts, &branch.id, &then_node.id, "branch_true");
        assert_edge(&facts, &branch.id, &else_node.id, "branch_false");
        assert_edge(&facts, &then_node.id, &after_node.id, "fallthrough");
        assert_edge(&facts, &else_node.id, &after_node.id, "fallthrough");
    }

    #[test]
    fn missing_else_false_edge_joins_next_statement() {
        let if_node = if_node(
            "IF",
            condition("ready?"),
            vec![call_node(5, 6, "publish(input)")],
            Vec::new(),
        );
        let after = statement(1, 7, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &if_node), after.clone()],
            tree(vec![if_node, node_for_statement(&after)]),
        )]);

        let branch = node_with_source(&facts, "if ready? publish(input) end");
        let after_node = node_with_source(&facts, "finish()");

        assert_edge(&facts, &branch.id, &after_node.id, "branch_false");
    }

    #[test]
    fn unless_statement_flips_branch_edges() {
        let unless_node = if_node(
            "UNLESS",
            condition("ready?"),
            vec![call_node(5, 6, "publish(input)")],
            Vec::new(),
        );
        let after = statement(1, 7, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &unless_node), after.clone()],
            tree(vec![unless_node, node_for_statement(&after)]),
        )]);

        let branch = node_with_source(&facts, "unless ready? publish(input) end");
        let then_node = node_with_source(&facts, "publish(input)");
        let after_node = node_with_source(&facts, "finish()");

        assert_edge(&facts, &branch.id, &then_node.id, "branch_false");
        assert_edge(&facts, &branch.id, &after_node.id, "branch_true");
    }

    #[test]
    fn nested_branch_exits_join_after_outer_branch() {
        let nested_if = if_node(
            "IF",
            condition("allowed?"),
            vec![call_node(6, 8, "publish(input)")],
            Vec::new(),
        );
        let outer_if = if_node(
            "IF",
            condition("ready?"),
            vec![nested_if],
            vec![call_node(9, 6, "warn(input)")],
        );
        let after = statement(1, 11, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &outer_if), after.clone()],
            tree(vec![outer_if, node_for_statement(&after)]),
        )]);

        let nested = node_with_source(&facts, "if allowed? publish(input) end");
        let published = node_with_source(&facts, "publish(input)");
        let after_node = node_with_source(&facts, "finish()");

        assert_edge(&facts, &nested.id, &published.id, "branch_true");
        assert_edge(&facts, &nested.id, &after_node.id, "branch_false");
        assert_edge(&facts, &published.id, &after_node.id, "fallthrough");
    }

    #[test]
    fn boolean_and_adds_short_circuit_edge_to_false_outcome() {
        let if_node = if_node(
            "IF",
            node(
                "AND",
                4,
                7,
                4,
                25,
                "ready? && allowed?",
                vec![condition("ready?"), condition("allowed?")],
            ),
            vec![call_node(5, 6, "publish(input)")],
            Vec::new(),
        );
        let after = statement(1, 7, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &if_node), after.clone()],
            tree(vec![if_node, node_for_statement(&after)]),
        )]);

        let branch = node_with_source(&facts, "if ready? && allowed? publish(input) end");
        let after_node = node_with_source(&facts, "finish()");

        assert_edge(&facts, &branch.id, &after_node.id, "short_circuit");
    }

    #[test]
    fn while_loop_has_body_exit_and_backedge() {
        let while_node = loop_node(
            "WHILE",
            condition("ready?"),
            vec![call_node(5, 6, "work()")],
        );
        let after = statement(1, 8, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &while_node), after.clone()],
            tree(vec![while_node, node_for_statement(&after)]),
        )]);

        let loop_node = node_with_source(&facts, "while ready? work() end");
        let body_node = node_with_source(&facts, "work()");
        let after_node = node_with_source(&facts, "finish()");

        assert_eq!(loop_node.kind, "loop");
        assert_eq!(loop_node.role, "while_loop");
        assert_edge(&facts, &loop_node.id, &body_node.id, "loop_body");
        assert_edge(&facts, &body_node.id, &loop_node.id, "loop_backedge");
        assert_edge(&facts, &loop_node.id, &after_node.id, "loop_exit");
    }

    #[test]
    fn break_exits_current_loop_and_skips_later_body() {
        let while_node = loop_node(
            "WHILE",
            condition("ready?"),
            vec![
                call_node(5, 6, "work()"),
                jump_node("BREAK", 6, 6, "break"),
                call_node(7, 6, "unreachable()"),
            ],
        );
        let after = statement(1, 9, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &while_node), after.clone()],
            tree(vec![while_node, node_for_statement(&after)]),
        )]);

        let break_node = node_with_source(&facts, "break");
        let after_node = node_with_source(&facts, "finish()");

        assert_eq!(break_node.kind, "jump");
        assert_eq!(break_node.role, "break");
        assert_edge(&facts, &break_node.id, &after_node.id, "break");
        assert!(facts
            .nodes
            .iter()
            .all(|node| node.source != "unreachable()"));
    }

    #[test]
    fn continue_targets_current_loop_and_skips_later_body() {
        let while_node = loop_node(
            "WHILE",
            condition("ready?"),
            vec![
                call_node(5, 6, "work()"),
                jump_node("NEXT", 6, 6, "next"),
                call_node(7, 6, "unreachable()"),
            ],
        );
        let after = statement(1, 9, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &while_node), after.clone()],
            tree(vec![while_node, node_for_statement(&after)]),
        )]);

        let loop_node = node_with_source(&facts, "while ready? work() next unreachable() end");
        let continue_node = node_with_source(&facts, "next");

        assert_eq!(continue_node.kind, "jump");
        assert_eq!(continue_node.role, "continue");
        assert_edge(&facts, &continue_node.id, &loop_node.id, "continue");
        assert!(facts
            .nodes
            .iter()
            .all(|node| node.source != "unreachable()"));
    }

    #[test]
    fn nested_loop_break_targets_inner_loop_only() {
        let inner_loop = loop_node(
            "WHILE",
            condition("allowed?"),
            vec![jump_node("BREAK", 6, 8, "break")],
        );
        let outer_loop = loop_node(
            "WHILE",
            condition("ready?"),
            vec![inner_loop, call_node(8, 6, "after_inner()")],
        );
        let after = statement(1, 11, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &outer_loop), after.clone()],
            tree(vec![outer_loop, node_for_statement(&after)]),
        )]);

        let break_node = node_with_source(&facts, "break");
        let after_inner = node_with_source(&facts, "after_inner()");
        let outer = node_with_source(
            &facts,
            "while ready? while allowed? break end after_inner() end",
        );

        assert_edge(&facts, &break_node.id, &after_inner.id, "break");
        assert_edge(&facts, &after_inner.id, &outer.id, "loop_backedge");
    }

    #[test]
    fn case_statement_routes_arms_and_default_to_join() {
        let cfg_case = case_node(
            "CASE",
            Some(condition("role")),
            vec![
                vec![call_node(6, 6, "publish(user)")],
                vec![call_node(8, 6, "escalate(user)")],
            ],
            Some(vec![call_node(10, 6, "ignore(user)")]),
        );
        let case_source = crate::ast::normalize_text(&cfg_case.text);
        let after = statement(1, 12, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &cfg_case), after.clone()],
            tree(vec![cfg_case, node_for_statement(&after)]),
        )]);

        let case_node = node_with_source(&facts, &case_source);
        let first_arm = node_with_source(&facts, "publish(user)");
        let second_arm = node_with_source(&facts, "escalate(user)");
        let fallback = node_with_source(&facts, "ignore(user)");
        let after_node = node_with_source(&facts, "finish()");

        assert_eq!(case_node.kind, "case");
        assert_eq!(case_node.role, "case_dispatch");
        assert_edge(&facts, &case_node.id, &first_arm.id, "case_arm");
        assert_edge(&facts, &case_node.id, &second_arm.id, "case_arm");
        assert_edge(&facts, &case_node.id, &fallback.id, "case_default");
        assert_edge(&facts, &first_arm.id, &after_node.id, "fallthrough");
        assert_edge(&facts, &second_arm.id, &after_node.id, "fallthrough");
        assert_edge(&facts, &fallback.id, &after_node.id, "fallthrough");
    }

    #[test]
    fn case_without_default_routes_default_edge_to_join() {
        let cfg_case = case_node(
            "CASE",
            Some(condition("role")),
            vec![vec![call_node(6, 6, "publish(user)")]],
            None,
        );
        let case_source = crate::ast::normalize_text(&cfg_case.text);
        let after = statement(1, 8, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &cfg_case), after.clone()],
            tree(vec![cfg_case, node_for_statement(&after)]),
        )]);

        let case_node = node_with_source(&facts, &case_source);
        let after_node = node_with_source(&facts, "finish()");

        assert_edge(&facts, &case_node.id, &after_node.id, "case_default");
    }

    #[test]
    fn empty_case_arm_routes_arm_edge_to_join() {
        let cfg_case = case_node("CASE", Some(condition("role")), vec![Vec::new()], None);
        let case_source = crate::ast::normalize_text(&cfg_case.text);
        let after = statement(1, 8, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &cfg_case), after.clone()],
            tree(vec![cfg_case, node_for_statement(&after)]),
        )]);

        let case_node = node_with_source(&facts, &case_source);
        let after_node = node_with_source(&facts, "finish()");

        assert_edge(&facts, &case_node.id, &after_node.id, "case_arm");
    }

    #[test]
    fn case2_statement_uses_match_role() {
        let cfg_case = case_node(
            "CASE2",
            None,
            vec![vec![call_node(6, 6, "ready()")]],
            Some(vec![call_node(8, 6, "fallback()")]),
        );
        let case_source = crate::ast::normalize_text(&cfg_case.text);
        let after = statement(1, 10, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &cfg_case), after.clone()],
            tree(vec![cfg_case, node_for_statement(&after)]),
        )]);

        let case_node = node_with_source(&facts, &case_source);
        let arm = node_with_source(&facts, "ready()");
        let fallback = node_with_source(&facts, "fallback()");

        assert_eq!(case_node.kind, "case");
        assert_eq!(case_node.role, "case_match");
        assert_edge(&facts, &case_node.id, &arm.id, "case_arm");
        assert_edge(&facts, &case_node.id, &fallback.id, "case_default");
    }

    #[test]
    fn case_arm_break_inside_loop_exits_loop() {
        let cfg_case = case_node(
            "CASE",
            Some(condition("status")),
            vec![vec![jump_node("BREAK", 6, 8, "break")]],
            Some(vec![call_node(8, 8, "keep_working()")]),
        );
        let while_node = loop_node("WHILE", condition("ready?"), vec![cfg_case]);
        let after = statement(1, 11, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &while_node), after.clone()],
            tree(vec![while_node, node_for_statement(&after)]),
        )]);

        let break_node = node_with_source(&facts, "break");
        let work_node = node_with_source(&facts, "keep_working()");
        let loop_node = node_with_source(
            &facts,
            "while ready? case status when :value break else keep_working() end end",
        );
        let after_node = node_with_source(&facts, "finish()");

        assert_edge(&facts, &break_node.id, &after_node.id, "break");
        assert_edge(&facts, &work_node.id, &loop_node.id, "loop_backedge");
    }

    #[test]
    fn return_statement_edges_to_function_exit_and_skips_later_statement() {
        let return_node = jump_node("RETURN", 4, 4, "return result");
        let after = statement(1, 5, "unreachable()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &return_node), after.clone()],
            tree(vec![return_node, node_for_statement(&after)]),
        )]);

        let return_node = node_with_source(&facts, "return result");
        let exit_node = exit_node_for(&facts);

        assert_eq!(return_node.kind, "jump");
        assert_eq!(return_node.role, "return");
        assert_edge(&facts, &return_node.id, &exit_node.id, "return");
        assert!(facts
            .nodes
            .iter()
            .all(|node| node.source != "unreachable()"));
    }

    #[test]
    fn return_inside_branch_only_terminates_that_arm() {
        let if_node = if_node(
            "IF",
            condition("ready?"),
            vec![jump_node("RETURN", 5, 6, "return result")],
            Vec::new(),
        );
        let after = statement(1, 7, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &if_node), after.clone()],
            tree(vec![if_node, node_for_statement(&after)]),
        )]);

        let branch = node_with_source(&facts, "if ready? return result end");
        let return_node = node_with_source(&facts, "return result");
        let after_node = node_with_source(&facts, "finish()");
        let exit_node = exit_node_for(&facts);

        assert_edge(&facts, &branch.id, &return_node.id, "branch_true");
        assert_edge(&facts, &branch.id, &after_node.id, "branch_false");
        assert_edge(&facts, &return_node.id, &exit_node.id, "return");
        assert_no_edge(&facts, &return_node.id, &after_node.id, "fallthrough");
    }

    #[test]
    fn return_inside_loop_exits_function_without_loop_backedge() {
        let while_node = loop_node(
            "WHILE",
            condition("ready?"),
            vec![jump_node("RETURN", 5, 6, "return result")],
        );
        let after = statement(1, 8, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &while_node), after.clone()],
            tree(vec![while_node, node_for_statement(&after)]),
        )]);

        let loop_node = node_with_source(&facts, "while ready? return result end");
        let return_node = node_with_source(&facts, "return result");
        let after_node = node_with_source(&facts, "finish()");
        let exit_node = exit_node_for(&facts);

        assert_edge(&facts, &return_node.id, &exit_node.id, "return");
        assert_edge(&facts, &loop_node.id, &after_node.id, "loop_exit");
        assert_no_edge(&facts, &return_node.id, &loop_node.id, "loop_backedge");
    }

    #[test]
    fn rescue_handler_joins_after_region() {
        let rescue_node = rescue_node(
            vec![call_node(5, 6, "work()")],
            vec![Some(vec![call_node(7, 6, "recover()")])],
            None,
        );
        let rescue_source = crate::ast::normalize_text(&rescue_node.text);
        let after = statement(1, 9, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &rescue_node), after.clone()],
            tree(vec![rescue_node, node_for_statement(&after)]),
        )]);

        let rescue_node = node_with_source(&facts, &rescue_source);
        let body_node = node_with_source(&facts, "work()");
        let handler_node = node_with_source(&facts, "recover()");
        let after_node = node_with_source(&facts, "finish()");

        assert_eq!(rescue_node.kind, "exception");
        assert_eq!(rescue_node.role, "rescue_region");
        assert_edge(&facts, &rescue_node.id, &body_node.id, "try_body");
        assert_edge(&facts, &rescue_node.id, &handler_node.id, "rescue_handler");
        assert_edge(&facts, &body_node.id, &after_node.id, "fallthrough");
        assert_edge(&facts, &handler_node.id, &after_node.id, "fallthrough");
    }

    #[test]
    fn missing_rescue_handler_body_routes_handler_edge_to_join() {
        let rescue_node = rescue_node(vec![call_node(5, 6, "work()")], vec![None], None);
        let rescue_source = crate::ast::normalize_text(&rescue_node.text);
        let after = statement(1, 8, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &rescue_node), after.clone()],
            tree(vec![rescue_node, node_for_statement(&after)]),
        )]);

        let rescue_node = node_with_source(&facts, &rescue_source);
        let after_node = node_with_source(&facts, "finish()");

        assert_edge(&facts, &rescue_node.id, &after_node.id, "rescue_handler");
    }

    #[test]
    fn ensure_cleanup_runs_on_normal_exit_before_join() {
        let ensure_node = ensure_node(
            vec![call_node(5, 6, "work()")],
            vec![call_node(7, 6, "close()")],
        );
        let ensure_source = crate::ast::normalize_text(&ensure_node.text);
        let after = statement(1, 9, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &ensure_node), after.clone()],
            tree(vec![ensure_node, node_for_statement(&after)]),
        )]);

        let ensure_node = node_with_source(&facts, &ensure_source);
        let body_node = node_with_source(&facts, "work()");
        let cleanup_node = node_with_source(&facts, "close()");
        let after_node = node_with_source(&facts, "finish()");

        assert_eq!(ensure_node.kind, "exception");
        assert_eq!(ensure_node.role, "ensure_region");
        assert_edge(&facts, &ensure_node.id, &body_node.id, "ensure_body");
        assert_edge(&facts, &body_node.id, &cleanup_node.id, "ensure_cleanup");
        assert_edge(&facts, &cleanup_node.id, &after_node.id, "fallthrough");
    }

    #[test]
    fn ensure_cleanup_runs_after_return_before_function_exit() {
        let ensure_node = ensure_node(
            vec![jump_node("RETURN", 5, 6, "return result")],
            vec![call_node(7, 6, "close()")],
        );
        let after = statement(1, 9, "unreachable()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &ensure_node), after.clone()],
            tree(vec![ensure_node, node_for_statement(&after)]),
        )]);

        let return_node = node_with_source(&facts, "return result");
        let cleanup_node = node_with_source(&facts, "close()");
        let exit_node = exit_node_for(&facts);

        assert_edge(&facts, &return_node.id, &cleanup_node.id, "ensure_cleanup");
        assert_edge(&facts, &cleanup_node.id, &exit_node.id, "return");
        assert_no_edge(&facts, &return_node.id, &exit_node.id, "return");
        assert!(facts
            .nodes
            .iter()
            .all(|node| node.source != "unreachable()"));
    }

    #[test]
    fn ensure_cleanup_runs_after_break_before_loop_exit() {
        let ensure_node = ensure_node(
            vec![jump_node("BREAK", 5, 6, "break")],
            vec![call_node(7, 6, "close()")],
        );
        let while_node = loop_node("WHILE", condition("ready?"), vec![ensure_node]);
        let after = statement(1, 9, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &while_node), after.clone()],
            tree(vec![while_node, node_for_statement(&after)]),
        )]);

        let break_node = node_with_source(&facts, "break");
        let cleanup_node = node_with_source(&facts, "close()");
        let after_node = node_with_source(&facts, "finish()");

        assert_edge(&facts, &break_node.id, &cleanup_node.id, "ensure_cleanup");
        assert_edge(&facts, &cleanup_node.id, &after_node.id, "break");
        assert_no_edge(&facts, &break_node.id, &after_node.id, "break");
    }

    #[test]
    fn callback_block_routes_body_and_returns_to_join() {
        let callback = iter_callback_node("transaction", vec![call_node(5, 6, "audit(user)")]);
        let callback_source = crate::ast::normalize_text(&callback.text);
        let after = statement(1, 7, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &callback), after.clone()],
            tree(vec![callback, node_for_statement(&after)]),
        )]);

        let callback = node_with_source(&facts, &callback_source);
        let body_node = node_with_source(&facts, "audit(user)");
        let after_node = node_with_source(&facts, "finish()");

        assert_eq!(callback.kind, "callback");
        assert_eq!(callback.role, "callback_region");
        assert_edge(&facts, &callback.id, &body_node.id, "callback_body");
        assert_edge(&facts, &body_node.id, &after_node.id, "callback_return");
    }

    #[test]
    fn empty_callback_routes_to_join() {
        let callback = iter_callback_node("transaction", Vec::new());
        let callback_source = crate::ast::normalize_text(&callback.text);
        let after = statement(1, 5, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &callback), after.clone()],
            tree(vec![callback, node_for_statement(&after)]),
        )]);

        let callback = node_with_source(&facts, &callback_source);
        let after_node = node_with_source(&facts, "finish()");

        assert_edge(&facts, &callback.id, &after_node.id, "callback_return");
    }

    #[test]
    fn yield_site_falls_through_with_yield_return() {
        let yield_node = yield_node(4, 4, "yield user");
        let after = statement(1, 5, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &yield_node), after.clone()],
            tree(vec![yield_node, node_for_statement(&after)]),
        )]);

        let yield_node = node_with_source(&facts, "yield user");
        let after_node = node_with_source(&facts, "finish()");

        assert_eq!(yield_node.kind, "callback");
        assert_eq!(yield_node.role, "yield_site");
        assert_edge(&facts, &yield_node.id, &after_node.id, "yield_return");
    }

    #[test]
    fn lambda_argument_callback_routes_body_and_returns_to_join() {
        let callback = call_with_lambda_arg("callback", vec![call_node(5, 6, "audit(user)")]);
        let callback_source = crate::ast::normalize_text(&callback.text);
        let after = statement(1, 7, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &callback), after.clone()],
            tree(vec![callback, node_for_statement(&after)]),
        )]);

        let callback = node_with_source(&facts, &callback_source);
        let body_node = node_with_source(&facts, "audit(user)");
        let after_node = node_with_source(&facts, "finish()");

        assert_eq!(callback.kind, "callback");
        assert_eq!(callback.role, "callback_region");
        assert_edge(&facts, &callback.id, &body_node.id, "callback_body");
        assert_edge(&facts, &body_node.id, &after_node.id, "callback_return");
    }

    #[test]
    fn nested_callbacks_return_to_outer_join() {
        let inner = iter_callback_node("around_hook", vec![call_node(6, 8, "audit(user)")]);
        let outer = iter_callback_node("transaction", vec![inner]);
        let outer_source = crate::ast::normalize_text(&outer.text);
        let after = statement(1, 8, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &outer), after.clone()],
            tree(vec![outer, node_for_statement(&after)]),
        )]);

        let outer = node_with_source(&facts, &outer_source);
        let inner = node_with_source(&facts, "around_hook do audit(user) end");
        let body_node = node_with_source(&facts, "audit(user)");
        let after_node = node_with_source(&facts, "finish()");

        assert_edge(&facts, &outer.id, &inner.id, "callback_body");
        assert_edge(&facts, &inner.id, &body_node.id, "callback_body");
        assert_edge(&facts, &body_node.id, &after_node.id, "callback_return");
    }

    #[test]
    fn return_inside_callback_propagates_to_function_exit() {
        let callback = iter_callback_node(
            "transaction",
            vec![jump_node("RETURN", 5, 6, "return result")],
        );
        let after = statement(1, 7, "unreachable()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &callback), after.clone()],
            tree(vec![callback, node_for_statement(&after)]),
        )]);

        let callback = node_with_source(&facts, "transaction do return result end");
        let return_node = node_with_source(&facts, "return result");
        let exit_node = exit_node_for(&facts);

        assert_edge(&facts, &callback.id, &return_node.id, "callback_body");
        assert_edge(&facts, &return_node.id, &exit_node.id, "return");
        assert!(facts
            .nodes
            .iter()
            .all(|node| node.source != "unreachable()"));
    }

    #[test]
    fn break_outside_loop_falls_through_without_loop_target() {
        let break_node = jump_node("BREAK", 4, 4, "break");
        let after = statement(1, 5, "finish()");
        let facts = build_for_test(&[method_with_node(
            "run",
            3,
            vec![statement_for_node(0, &break_node), after.clone()],
            tree(vec![break_node, node_for_statement(&after)]),
        )]);

        let break_node = node_with_source(&facts, "break");
        let after_node = node_with_source(&facts, "finish()");

        assert_eq!(break_node.kind, "statement");
        assert_edge(&facts, &break_node.id, &after_node.id, "fallthrough");
    }

    #[test]
    fn method_ordering_is_deterministic() {
        let facts = build_for_test(&[
            method("zeta", 20, vec![statement(0, 21, "z()")]),
            method("alpha", 3, vec![statement(0, 4, "a()")]),
        ]);

        let functions = facts
            .nodes
            .iter()
            .filter(|node| node.kind == "entry")
            .map(|node| node.function.as_str())
            .collect::<Vec<_>>();
        assert_eq!(functions, ["alpha", "zeta"]);
    }

    fn method(name: &str, line: usize, statements: Vec<Statement>) -> MethodSummary {
        let body_nodes = statements
            .iter()
            .map(node_for_statement)
            .collect::<Vec<_>>();
        method_with_node(name, line, statements, tree(body_nodes))
    }

    fn method_with_node(
        name: &str,
        line: usize,
        statements: Vec<Statement>,
        body: Node,
    ) -> MethodSummary {
        MethodSummary {
            id: format!("Example#{name}"),
            owner: "Example".to_string(),
            name: name.to_string(),
            file: "test.rb".to_string(),
            line,
            span: [line, 2, line + statements.len() + 1, 5],
            node: body,
            statements,
            boundaries: Vec::new(),
            param_types: std::collections::BTreeMap::new(),
        }
    }

    fn statement(index: usize, line: usize, source: &str) -> Statement {
        Statement {
            index,
            line,
            end_line: line,
            span: [line, 4, line, 4 + source.len()],
            source: source.to_string(),
            reads: BTreeSet::new(),
            writes: BTreeSet::new(),
            dependencies: Vec::new(),
            co_uses: Vec::new(),
        }
    }

    fn statement_for_node(index: usize, node: &Node) -> Statement {
        Statement {
            index,
            line: node.first_lineno,
            end_line: node.last_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
            source: crate::ast::normalize_text(&node.text),
            reads: BTreeSet::new(),
            writes: BTreeSet::new(),
            dependencies: Vec::new(),
            co_uses: Vec::new(),
        }
    }

    fn tree(children: Vec<Node>) -> Node {
        node("ROOT", 1, 0, 20, 0, "", children)
    }

    fn if_node(kind: &str, condition: Node, then_body: Vec<Node>, else_body: Vec<Node>) -> Node {
        let keyword = if kind == "UNLESS" { "unless" } else { "if" };
        let text = if else_body.is_empty() {
            format!(
                "{keyword} {} {} end",
                condition.text,
                source_text(&then_body)
            )
        } else {
            format!(
                "{keyword} {} {} else {} end",
                condition.text,
                source_text(&then_body),
                source_text(&else_body)
            )
        };
        let mut children = vec![
            condition,
            node("BLOCK", 5, 6, 6, 7, &source_text(&then_body), then_body),
        ];
        if !else_body.is_empty() {
            children.push(node(
                "BLOCK",
                7,
                6,
                8,
                7,
                &source_text(&else_body),
                else_body,
            ));
        }
        node(kind, 4, 4, 10, 7, &text, children)
    }

    fn loop_node(kind: &str, condition: Node, body: Vec<Node>) -> Node {
        let keyword = match kind {
            "UNTIL" => "until",
            "FOR" => "for",
            "ITER" => "iter",
            _ => "while",
        };
        let text = format!("{keyword} {} {} end", condition.text, source_text(&body));
        node(
            kind,
            4,
            4,
            10,
            7,
            &text,
            vec![
                condition,
                node("BLOCK", 5, 6, 9, 7, &source_text(&body), body),
            ],
        )
    }

    fn case_node(
        kind: &str,
        subject: Option<Node>,
        arms: Vec<Vec<Node>>,
        fallback: Option<Vec<Node>>,
    ) -> Node {
        let chain = when_chain(arms, fallback);
        let text = case_text(kind, subject.as_ref(), chain.as_ref());
        let mut children = Vec::new();
        if kind == "CASE" {
            children.push(optional_child(subject));
        }
        children.push(optional_child(chain));
        node_with_children(kind, 4, 4, 10, 7, &text, children)
    }

    fn when_chain(arms: Vec<Vec<Node>>, fallback: Option<Vec<Node>>) -> Option<Node> {
        let mut tail = fallback.map(|body| block_node(body, 8, 6));
        for body in arms.into_iter().rev() {
            tail = Some(when_node(body, tail));
        }
        tail
    }

    fn when_node(body: Vec<Node>, tail: Option<Node>) -> Node {
        let tail_text = tail
            .as_ref()
            .map(|tail| {
                if tail.r#type == "WHEN" {
                    format!(" {}", tail.text)
                } else {
                    format!(" else {}", tail.text)
                }
            })
            .unwrap_or_default();
        let body_text = source_text(&body);
        let text = if body_text.is_empty() {
            format!("when :value{tail_text}")
        } else {
            format!("when :value {body_text}{tail_text}")
        };

        node_with_children(
            "WHEN",
            5,
            4,
            7,
            7,
            &text,
            vec![
                optional_child(Some(node("LIST", 5, 9, 5, 15, ":value", Vec::new()))),
                optional_child(Some(block_node(body, 6, 6))),
                optional_child(tail),
            ],
        )
    }

    fn block_node(body: Vec<Node>, line: usize, column: usize) -> Node {
        node(
            "BLOCK",
            line,
            column,
            line + body.len(),
            column,
            &source_text(&body),
            body,
        )
    }

    fn case_text(kind: &str, subject: Option<&Node>, chain: Option<&Node>) -> String {
        let subject = match (kind, subject) {
            ("CASE", Some(subject)) => format!(" {}", subject.text),
            _ => String::new(),
        };
        let body = chain.map(|node| node.text.as_str()).unwrap_or_default();
        if body.is_empty() {
            format!("case{subject} end")
        } else if body.starts_with("when ") {
            format!("case{subject} {body} end")
        } else {
            format!("case{subject} else {body} end")
        }
    }

    fn rescue_node(
        body: Vec<Node>,
        handlers: Vec<Option<Vec<Node>>>,
        fallback: Option<Vec<Node>>,
    ) -> Node {
        let body_text = source_text(&body);
        let handler_text = handlers
            .iter()
            .map(|handler| {
                let body = handler
                    .as_ref()
                    .map(|body| source_text(body))
                    .unwrap_or_default();
                if body.is_empty() {
                    "rescue".to_string()
                } else {
                    format!("rescue {body}")
                }
            })
            .collect::<Vec<_>>()
            .join(" ");
        let fallback_text = fallback
            .as_ref()
            .map(|body| {
                let body = source_text(body);
                if body.is_empty() {
                    " else".to_string()
                } else {
                    format!(" else {body}")
                }
            })
            .unwrap_or_default();
        let text = format!("begin {body_text} {handler_text}{fallback_text} end");
        let fallback = fallback.map(|body| block_node(body, 8, 6));
        node_with_children(
            "RESCUE",
            4,
            4,
            10,
            7,
            &text,
            vec![
                optional_child(Some(block_node(body, 5, 6))),
                optional_child(resbody_chain(handlers)),
                optional_child(fallback),
            ],
        )
    }

    fn resbody_chain(handlers: Vec<Option<Vec<Node>>>) -> Option<Node> {
        let mut tail = None;
        for body in handlers.into_iter().rev() {
            tail = Some(resbody_node(body, tail));
        }
        tail
    }

    fn resbody_node(body: Option<Vec<Node>>, tail: Option<Node>) -> Node {
        let body_text = body
            .as_ref()
            .map(|body| source_text(body))
            .unwrap_or_default();
        let tail_text = tail
            .as_ref()
            .map(|tail| format!(" {}", tail.text))
            .unwrap_or_default();
        let text = if body_text.is_empty() {
            format!("rescue{tail_text}")
        } else {
            format!("rescue {body_text}{tail_text}")
        };
        node_with_children(
            "RESBODY",
            6,
            4,
            7,
            7,
            &text,
            vec![
                Child::Nil,
                optional_child(body.map(|body| block_node(body, 7, 6))),
                optional_child(tail),
            ],
        )
    }

    fn ensure_node(body: Vec<Node>, cleanup: Vec<Node>) -> Node {
        let text = format!(
            "begin {} ensure {} end",
            source_text(&body),
            source_text(&cleanup)
        );
        node_with_children(
            "ENSURE",
            4,
            4,
            10,
            7,
            &text,
            vec![
                optional_child(Some(block_node(body, 5, 6))),
                optional_child(Some(block_node(cleanup, 7, 6))),
            ],
        )
    }

    fn iter_callback_node(message: &str, body: Vec<Node>) -> Node {
        let body_text = source_text(&body);
        let text = if body_text.is_empty() {
            format!("{message} do end")
        } else {
            format!("{message} do {body_text} end")
        };
        node_with_children(
            "ITER",
            4,
            4,
            8,
            7,
            &text,
            vec![
                optional_child(Some(normalized_fcall(message, 4, 4))),
                optional_child(Some(scope_node(body))),
            ],
        )
    }

    fn scope_node(body: Vec<Node>) -> Node {
        node(
            "SCOPE",
            4,
            4,
            8,
            7,
            "",
            vec![
                node("ARGS", 4, 4, 4, 4, "", Vec::new()),
                node("BLOCK", 4, 4, 4, 4, "", Vec::new()),
                block_node(body, 5, 6),
            ],
        )
    }

    fn normalized_fcall(message: &str, line: usize, column: usize) -> Node {
        node_with_children(
            "FCALL",
            line,
            column,
            line,
            column + message.len(),
            message,
            vec![Child::Symbol(message.to_string()), Child::Nil],
        )
    }

    fn yield_node(line: usize, column: usize, source: &str) -> Node {
        node_with_children(
            "YIELD",
            line,
            column,
            line,
            column + source.len(),
            source,
            vec![Child::Nil],
        )
    }

    fn call_with_lambda_arg(message: &str, body: Vec<Node>) -> Node {
        let text = format!("{message}(lambda)");
        node_with_children(
            "FCALL",
            4,
            4,
            8,
            7,
            &text,
            vec![
                Child::Symbol(message.to_string()),
                optional_child(Some(node(
                    "LIST",
                    4,
                    13,
                    8,
                    7,
                    "lambda",
                    vec![lambda_node(body)],
                ))),
            ],
        )
    }

    fn lambda_node(body: Vec<Node>) -> Node {
        node("LAMBDA", 4, 13, 8, 7, "lambda", vec![scope_node(body)])
    }

    fn condition(source: &str) -> Node {
        node("VCALL", 4, 7, 4, 7 + source.len(), source, Vec::new())
    }

    fn jump_node(kind: &str, line: usize, column: usize, source: &str) -> Node {
        node(
            kind,
            line,
            column,
            line,
            column + source.len(),
            source,
            Vec::new(),
        )
    }

    fn call_node(line: usize, column: usize, source: &str) -> Node {
        node(
            "FCALL",
            line,
            column,
            line,
            column + source.len(),
            source,
            Vec::new(),
        )
    }

    fn node_for_statement(statement: &Statement) -> Node {
        node(
            "FCALL",
            statement.line,
            statement.span[1],
            statement.end_line,
            statement.span[3],
            &statement.source,
            Vec::new(),
        )
    }

    fn node(
        kind: &str,
        first_line: usize,
        first_column: usize,
        last_line: usize,
        last_column: usize,
        text: &str,
        children: Vec<Node>,
    ) -> Node {
        node_with_children(
            kind,
            first_line,
            first_column,
            last_line,
            last_column,
            text,
            children
                .into_iter()
                .map(|child| Child::Node(Box::new(child)))
                .collect(),
        )
    }

    fn node_with_children(
        kind: &str,
        first_line: usize,
        first_column: usize,
        last_line: usize,
        last_column: usize,
        text: &str,
        children: Vec<Child>,
    ) -> Node {
        Node {
            r#type: kind.to_string(),
            children,
            first_lineno: first_line,
            first_column,
            last_lineno: last_line,
            last_column,
            text: text.to_string(),
        }
    }

    fn optional_child(node: Option<Node>) -> Child {
        node.map(|node| Child::Node(Box::new(node)))
            .unwrap_or(Child::Nil)
    }

    fn source_text(nodes: &[Node]) -> String {
        nodes
            .iter()
            .map(|node| node.text.clone())
            .collect::<Vec<_>>()
            .join(" ")
    }

    fn node_with_source<'a>(facts: &'a ControlFlowFacts, source: &str) -> &'a ControlFlowNode {
        facts
            .nodes
            .iter()
            .find(|node| node.source == source)
            .unwrap_or_else(|| panic!("missing node with source {source:?}"))
    }

    fn assert_edge(facts: &ControlFlowFacts, from: &str, to: &str, kind: &str) {
        assert!(
            facts
                .edges
                .iter()
                .any(|edge| edge.from == from && edge.to == to && edge.kind == kind),
            "missing edge {from} -{kind}-> {to}; edges: {:?}",
            facts.edges
        );
    }

    fn assert_no_edge(facts: &ControlFlowFacts, from: &str, to: &str, kind: &str) {
        assert!(
            !facts
                .edges
                .iter()
                .any(|edge| edge.from == from && edge.to == to && edge.kind == kind),
            "unexpected edge {from} -{kind}-> {to}; edges: {:?}",
            facts.edges
        );
    }

    fn exit_node_for(facts: &ControlFlowFacts) -> &ControlFlowNode {
        facts
            .nodes
            .iter()
            .find(|node| node.kind == "exit")
            .expect("exit node")
    }

    fn node_kinds(facts: &ControlFlowFacts) -> Vec<&str> {
        facts.nodes.iter().map(|node| node.kind.as_str()).collect()
    }

    fn edge_kinds(facts: &ControlFlowFacts) -> Vec<&str> {
        facts.edges.iter().map(|edge| edge.kind.as_str()).collect()
    }
}
