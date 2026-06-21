use super::{
    BranchArm, BranchDecision, CallSite, ComparisonUse, DecisionSite, DispatchSite, FunctionDef,
    OwnerDef, PathConditionSite, PredicateAlias, RawNode, SemanticEffectSite, StateDeclaration,
    StateRead, StateWrite,
};
use crate::ast::{self, Child, Node, Span};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::path::Path;

#[derive(Clone, Debug, Default)]
pub(crate) struct NormalizedFacts {
    pub(crate) function_defs: Vec<FunctionDef>,
    pub(crate) owner_defs: Vec<OwnerDef>,
    pub(crate) call_sites: Vec<CallSite>,
    pub(crate) state_declarations: Vec<StateDeclaration>,
    pub(crate) state_reads: Vec<StateRead>,
    pub(crate) state_writes: Vec<StateWrite>,
    pub(crate) decision_sites: Vec<DecisionSite>,
    pub(crate) branch_decisions: Vec<BranchDecision>,
    pub(crate) branch_arms: Vec<BranchArm>,
    pub(crate) dispatch_sites: Vec<DispatchSite>,
    pub(crate) semantic_effect_sites: Vec<SemanticEffectSite>,
    pub(crate) predicate_aliases: Vec<PredicateAlias>,
    pub(crate) comparison_uses: Vec<ComparisonUse>,
    pub(crate) path_condition_sites: Vec<PathConditionSite>,
}

pub(crate) fn extract(file: &Path, root: &Node) -> NormalizedFacts {
    let mut extractor = Extractor::new(file);
    extractor.scan_root(root);
    extractor.finish()
}

struct Extractor {
    file: String,
    file_owner: String,
    owners: Vec<String>,
    functions: Vec<String>,
    controls: Vec<String>,
    facts: NormalizedFacts,
    seen_calls: HashSet<(String, String, String, usize, Span)>,
    seen_reads: HashSet<(String, String, String, String, usize, Span)>,
    seen_writes: HashSet<(String, String, String, String, usize, Span)>,
    seen_effects: HashSet<(String, String, String, usize, Span)>,
}

impl Extractor {
    fn new(file: &Path) -> Self {
        let file = file.to_string_lossy().to_string();
        let file_owner = Path::new(&file)
            .file_stem()
            .and_then(|stem| stem.to_str())
            .unwrap_or("Object")
            .to_string();
        Self {
            file,
            file_owner,
            owners: Vec::new(),
            functions: Vec::new(),
            controls: Vec::new(),
            facts: NormalizedFacts::default(),
            seen_calls: HashSet::new(),
            seen_reads: HashSet::new(),
            seen_writes: HashSet::new(),
            seen_effects: HashSet::new(),
        }
    }

    fn scan_root(&mut self, root: &Node) {
        self.scan(root);
    }

    fn finish(mut self) -> NormalizedFacts {
        dedupe_decision_sites(&mut self.facts.decision_sites);
        self.facts.semantic_effect_sites.sort_by_key(effect_key);
        self.facts
    }

    fn scan(&mut self, node: &Node) {
        match node.r#type.as_str() {
            "CLASS" | "MODULE" => self.scan_owner(node),
            "DEFN" | "DEFS" => self.scan_function(node),
            "HASH" if block_like_hash(node) => {}
            "IF" | "UNLESS" => self.scan_if(node),
            "CASE" | "CASE2" => self.scan_case(node),
            "AND" | "OR" => self.scan_boolean(node),
            "CALL" | "QCALL" | "FCALL" | "VCALL" => self.record_call_node(node, false),
            "ITER" => self.scan_iter(node),
            "YIELD" => self.scan_yield(node),
            "XSTR" => self.scan_command_string(node),
            "SCLASS" => self.scan_singleton_class(node),
            "IASGN" | "GASGN" => self.record_state_write(node),
            "IVAR" | "GVAR" => self.record_state_read_node(node),
            "ATTRASGN" => self.scan_attr_assignment(node),
            "OPCALL" => self.scan_operator_call(node),
            "OP_ASGN1" | "OP_ASGN2" => self.scan_operator_assignment(node),
            _ => self.scan_children(node),
        }
    }

    fn scan_children(&mut self, node: &Node) {
        for child in child_nodes(node) {
            self.scan(child);
        }
    }

    fn scan_owner(&mut self, node: &Node) {
        let name = owner_name(node).unwrap_or_else(|| "(anonymous)".to_string());
        let qualified = if self.owners.is_empty() {
            name
        } else {
            format!("{}::{name}", self.current_owner())
        };
        self.facts.owner_defs.push(OwnerDef {
            file: self.file.clone(),
            name: qualified.clone(),
            kind: node.r#type.to_ascii_lowercase(),
            line: node.first_lineno,
            span: span(node),
        });
        self.owners.push(qualified);
        if let Some(scope) = scope_child(node) {
            self.scan(scope);
        }
        self.owners.pop();
    }

    fn scan_function(&mut self, node: &Node) {
        let name = function_name(node).unwrap_or_else(|| "(anonymous)".to_string());
        let owner = self.current_owner();
        let body = raw_from_normalized(node);
        if matches!(name.as_str(), "method_missing" | "respond_to_missing?") {
            self.record_semantic_effect(node, "metaprogramming", &format!("def {name}"));
        }
        let params = function_params(node);
        self.facts.function_defs.push(FunctionDef {
            file: self.file.clone(),
            name: name.clone(),
            owner,
            line: node.first_lineno,
            span: span(node),
            body,
            visibility: Some("public".to_string()),
            params,
        });
        if let Some(alias) = predicate_alias(node, &self.file, &self.current_owner()) {
            self.facts.predicate_aliases.push(alias);
        }
        self.functions.push(name);
        if let Some(scope) = function_scope(node) {
            if let Some(body) = scope_body(scope) {
                self.scan(body);
            }
        }
        self.functions.pop();
    }

    fn scan_iter(&mut self, node: &Node) {
        if let Some(call) = child_node(node, 0) {
            self.record_call_node(call, true);
        }
        if let Some(scope) = child_node(node, 1) {
            if let Some(body) = scope_body(scope) {
                self.with_control("iterates", |this| this.scan(body));
            }
        }
    }

    fn scan_yield(&mut self, node: &Node) {
        self.record_semantic_effect(node, "dynamic_dispatch", "yield");
        self.scan_children(node);
    }

    fn scan_command_string(&mut self, node: &Node) {
        self.record_semantic_effect(node, "hidden_io", "backtick");
        self.scan_children(node);
    }

    fn scan_singleton_class(&mut self, node: &Node) {
        if let Some(receiver) = child_node(node, 0).map(normalized_text) {
            if receiver != "self" {
                self.record_semantic_effect(
                    node,
                    "metaprogramming",
                    &format!("class << {receiver}"),
                );
            }
        }
        self.scan_children(node);
    }

    fn scan_if(&mut self, node: &Node) {
        let Some(condition) = child_node(node, 0) else {
            self.scan_children(node);
            return;
        };
        self.with_control("conditional", |this| this.scan(condition));
        self.record_branch_decision(node, condition);
        self.record_if_arms(node, condition);

        for child in [child_node(node, 1), child_node(node, 2)]
            .into_iter()
            .flatten()
        {
            self.with_control("conditional", |this| this.scan(child));
        }
    }

    fn scan_case(&mut self, node: &Node) {
        let value_index = if node.r#type == "CASE" { 0 } else { usize::MAX };
        let chain_index = if node.r#type == "CASE" { 1 } else { 0 };
        let value = (value_index != usize::MAX)
            .then(|| child_node(node, value_index))
            .flatten();
        if let Some(value) = value {
            self.with_control("conditional", |this| this.scan(value));
            self.record_branch_decision(node, value);
        }
        let whens = child_node(node, chain_index)
            .map(when_chain)
            .unwrap_or_default();
        let patterns = whens
            .iter()
            .flat_map(|when| when_patterns(when))
            .collect::<Vec<_>>();
        if let Some(value) = value {
            if patterns.len() >= 2 {
                self.facts.decision_sites.push(DecisionSite {
                    kind: "case_dispatch".to_string(),
                    members: patterns.clone(),
                    file: self.file.clone(),
                    function: self.current_function(),
                    line: node.first_lineno,
                    span: span(node),
                    predicate: normalized_text(value),
                    enclosing_span: span(node),
                });
            }
        }
        for when in &whens {
            self.record_case_arm(node, when, value);
            if let Some(body) = child_node(when, 1) {
                self.with_control("conditional", |this| this.scan(body));
            }
        }
        if let Some(fallback) = case_fallback(node) {
            self.with_control("conditional", |this| this.scan(fallback));
        }
        if let Some(value) = value {
            self.record_dispatch_site(node, value, &whens);
        }
    }

    fn scan_boolean(&mut self, node: &Node) {
        if node.r#type == "AND" {
            let members = flatten_and(node)
                .into_iter()
                .map(normalized_text)
                .collect::<Vec<_>>();
            if members.len() >= 2 {
                self.facts.decision_sites.push(DecisionSite {
                    kind: "conjunction".to_string(),
                    members,
                    file: self.file.clone(),
                    function: self.current_function(),
                    line: node.first_lineno,
                    span: span(node),
                    predicate: normalized_text(node),
                    enclosing_span: span(node),
                });
            }
        }
        for child in child_nodes(node) {
            self.scan(child);
        }
    }

    fn scan_attr_assignment(&mut self, node: &Node) {
        let mut effect_detail = "[]=".to_string();
        if let (Some(receiver), Some(field)) = (child_node(node, 0), child_symbol(node, 1)) {
            let field = field.trim_end_matches('=').to_string();
            if field != "[]" {
                effect_detail = format!("{field}=");
                self.record_state_write_target(receiver_text(receiver), field, node);
            }
        } else if let Some(receiver) = child_node(node, 0).map(receiver_text) {
            if let Some(field) = state_receiver_field(&receiver) {
                self.record_state_write_target("self".to_string(), field, node);
            }
        }
        self.record_semantic_effect(node, "hidden_mutation", &effect_detail);
        if let Some(receiver) = child_node(node, 0) {
            self.scan(receiver);
        }
        if let Some(args) = child_node(node, 2) {
            self.scan(args);
        }
    }

    fn scan_operator_call(&mut self, node: &Node) {
        if let Some(operator) = child_symbol(node, 1) {
            if matches!(
                operator.as_str(),
                "==" | "!=" | "===" | "!==" | "<" | "<=" | ">" | ">="
            ) {
                let raw = normalized_text(node);
                self.facts.comparison_uses.push(ComparisonUse {
                    canon_source: normalize_comparison_source(&raw),
                    raw,
                    file: self.file.clone(),
                    function: self.current_function(),
                    line: node.first_lineno,
                    span: span(node),
                    enclosing_span: span(node),
                });
            }
        }
        if child_symbol(node, 1).as_deref() == Some("<<") {
            self.record_semantic_effect(node, "hidden_mutation", "<<");
        }
        self.scan_children(node);
    }

    fn scan_operator_assignment(&mut self, node: &Node) {
        self.record_semantic_effect(node, "hidden_mutation", "op-assign");
        self.scan_children(node);
    }

    fn record_call_node(&mut self, node: &Node, block: bool) {
        let Some(parts) = call_parts(node) else {
            self.scan_children(node);
            return;
        };
        if let Some(receiver) = parts.receiver_node {
            self.scan(receiver);
        }
        if let Some(args) = parts.args_node {
            self.scan(args);
        }

        let conditional = self.conditional_context();
        let call = CallSite {
            receiver: parts.receiver.clone(),
            message: parts.message.clone(),
            file: self.file.clone(),
            function: self.current_function(),
            owner: self.current_owner(),
            line: node.first_lineno,
            span: span(node),
            conditional,
            arguments: parts.arguments,
            control: Some(self.current_control()),
            safe_navigation: node.r#type == "QCALL",
            block,
        };
        let key = (
            call.receiver.clone(),
            call.message.clone(),
            call.function.clone(),
            call.line,
            call.span,
        );
        if self.seen_calls.insert(key) {
            self.record_state_read_for_call(&call);
            self.record_state_write_for_mutating_call(&call);
            if call.receiver == "self" && node.text.contains(".(") {
                self.record_semantic_effect(
                    node,
                    "dynamic_dispatch",
                    &format!("{}.call", call.message),
                );
            }
            self.facts.call_sites.push(call);
        }
    }

    fn record_state_write(&mut self, node: &Node) {
        let field = first_string_or_symbol(node).unwrap_or_else(|| normalized_text(node));
        if node.r#type == "GASGN" {
            self.record_semantic_effect(node, "context_dependency", &field);
        }
        self.record_state_write_target("self".to_string(), field, node);
        if let Some(value) = child_node(node, 1) {
            self.scan(value);
        }
    }

    fn record_state_write_target(&mut self, receiver: String, field: String, node: &Node) {
        let write = StateWrite {
            field,
            receiver,
            file: self.file.clone(),
            function: self.current_function(),
            line: node.first_lineno,
            span: span(node),
            owner: self.current_owner(),
        };
        let key = (
            write.field.clone(),
            write.receiver.clone(),
            write.function.clone(),
            write.owner.clone(),
            write.line,
            write.span,
        );
        if self.seen_writes.insert(key) {
            self.facts.state_writes.push(write);
        }
    }

    fn record_state_read_node(&mut self, node: &Node) {
        let field = first_string_or_symbol(node).unwrap_or_else(|| normalized_text(node));
        if node.r#type == "GVAR" {
            self.record_semantic_effect(node, "context_dependency", &field);
        }
        let read = StateRead {
            field,
            receiver: "self".to_string(),
            file: self.file.clone(),
            function: self.current_function(),
            line: node.first_lineno,
            span: span(node),
            owner: self.current_owner(),
        };
        self.push_state_read(read);
    }

    fn record_state_read_for_call(&mut self, call: &CallSite) {
        if call.receiver == "self"
            || call.receiver.is_empty()
            || constant_receiver(&call.receiver)
            || literal_receiver(&call.receiver)
            || call.receiver.starts_with('@')
            || call.receiver.starts_with('$')
        {
            return;
        }
        if matches!(
            call.message.as_str(),
            "==" | "!=" | "===" | "<" | "<=" | ">" | ">=" | "[]" | "[]=" | "call"
        ) {
            return;
        }
        self.push_state_read(StateRead {
            field: call.message.clone(),
            receiver: call.receiver.clone(),
            file: call.file.clone(),
            function: call.function.clone(),
            line: call.line,
            span: call.span,
            owner: call.owner.clone(),
        });
    }

    fn record_state_write_for_mutating_call(&mut self, call: &CallSite) {
        if !mutating_receiver_message(&call.message) {
            return;
        }
        let Some(field) = state_receiver_field(&call.receiver) else {
            return;
        };
        let write = StateWrite {
            field,
            receiver: "self".to_string(),
            file: call.file.clone(),
            function: call.function.clone(),
            line: call.line,
            span: call.span,
            owner: call.owner.clone(),
        };
        let key = (
            write.field.clone(),
            write.receiver.clone(),
            write.function.clone(),
            write.owner.clone(),
            write.line,
            write.span,
        );
        if self.seen_writes.insert(key) {
            self.facts.state_writes.push(write);
        }
    }

    fn push_state_read(&mut self, read: StateRead) {
        let key = (
            read.field.clone(),
            read.receiver.clone(),
            read.function.clone(),
            read.owner.clone(),
            read.line,
            read.span,
        );
        if self.seen_reads.insert(key) {
            self.facts.state_reads.push(read);
        }
    }

    fn record_semantic_effect(&mut self, node: &Node, kind: &str, detail: &str) {
        self.record_semantic_effect_at(node.first_lineno, span(node), kind, detail);
    }

    fn record_semantic_effect_at(&mut self, line: usize, span: Span, kind: &str, detail: &str) {
        let key = (
            kind.to_string(),
            detail.to_string(),
            self.current_function(),
            line,
            span,
        );
        if !self.seen_effects.insert(key) {
            return;
        }
        self.facts.semantic_effect_sites.push(SemanticEffectSite {
            kind: kind.to_string(),
            detail: detail.to_string(),
            file: self.file.clone(),
            function: self.current_function(),
            line,
            span,
        });
    }

    fn record_branch_decision(&mut self, node: &Node, condition: &Node) {
        if normalized_ternary_if(node) {
            return;
        }
        let mut refs = BTreeSet::new();
        collect_state_refs(condition, &mut refs);
        if refs.is_empty() {
            return;
        }
        self.facts.branch_decisions.push(BranchDecision {
            file: self.file.clone(),
            function: self.current_function(),
            line: node.first_lineno,
            span: span(node),
            predicate: normalized_text(condition),
            state_refs: refs.into_iter().collect(),
        });
    }

    fn record_if_arms(&mut self, node: &Node, condition: &Node) {
        if normalized_ternary_if(node) {
            return;
        }
        let predicate = normalized_text(condition);
        for (index, member) in [(1, "then"), (2, "else")] {
            let Some(arm) = child_node(node, index) else {
                continue;
            };
            self.facts.branch_arms.push(BranchArm {
                file: self.file.clone(),
                function: self.current_function(),
                kind: "if".to_string(),
                line: arm.first_lineno,
                span: span(arm),
                decision_line: node.first_lineno,
                decision_span: span(node),
                predicate: predicate.clone(),
                member: member.to_string(),
                body: normalized_text(arm),
            });
        }
    }

    fn record_case_arm(&mut self, node: &Node, when: &Node, value: Option<&Node>) {
        let Some(value) = value else { return };
        let Some(body) = child_node(when, 1) else {
            return;
        };
        for member in when_patterns(when) {
            self.facts.branch_arms.push(BranchArm {
                file: self.file.clone(),
                function: self.current_function(),
                kind: "case".to_string(),
                line: when.first_lineno,
                span: span(when),
                decision_line: node.first_lineno,
                decision_span: span(node),
                predicate: normalized_text(value),
                member,
                body: normalized_text(body),
            });
        }
    }

    fn record_dispatch_site(&mut self, node: &Node, value: &Node, whens: &[&Node]) {
        let predicate = normalized_text(value);
        if predicate.is_empty() {
            return;
        }
        let function = self.current_function();
        let mut arm_members: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for when in whens {
            let members =
                dispatch_members_inside(&self.facts.call_sites, &predicate, &function, span(when));
            for pattern in when_patterns(when) {
                for variant in dispatch_constant_patterns(&pattern) {
                    arm_members
                        .entry(variant)
                        .or_default()
                        .extend(members.clone());
                }
            }
        }
        if arm_members.len() < 2 {
            return;
        }
        for members in arm_members.values_mut() {
            members.sort();
            members.dedup();
        }
        let mut variant_set = arm_members.keys().cloned().collect::<Vec<_>>();
        variant_set.sort();
        let outside =
            dispatch_members_outside(&self.facts.call_sites, &predicate, &function, span(node));
        let site = DispatchSite {
            variant_set,
            arm_members,
            outside,
            file: self.file.clone(),
            function,
            line: node.first_lineno,
            span: span(node),
        };
        if !self
            .facts
            .dispatch_sites
            .iter()
            .any(|existing| existing == &site)
        {
            self.facts.dispatch_sites.push(site);
        }
    }

    fn current_owner(&self) -> String {
        self.owners
            .last()
            .cloned()
            .unwrap_or_else(|| self.file_owner.clone())
    }

    fn current_function(&self) -> String {
        self.functions
            .last()
            .cloned()
            .unwrap_or_else(|| "(top-level)".to_string())
    }

    fn current_control(&self) -> String {
        self.controls
            .last()
            .cloned()
            .unwrap_or_else(|| "always".to_string())
    }

    fn conditional_context(&self) -> bool {
        self.controls
            .iter()
            .any(|control| matches!(control.as_str(), "conditional" | "iterates"))
    }

    fn with_control(&mut self, control: &str, block: impl FnOnce(&mut Self)) {
        self.controls.push(control.to_string());
        block(self);
        self.controls.pop();
    }
}

struct CallParts<'a> {
    receiver: String,
    message: String,
    arguments: Vec<String>,
    receiver_node: Option<&'a Node>,
    args_node: Option<&'a Node>,
}

fn call_parts(node: &Node) -> Option<CallParts<'_>> {
    match node.r#type.as_str() {
        "VCALL" => Some(CallParts {
            receiver: "self".to_string(),
            message: child_symbol(node, 0)?,
            arguments: Vec::new(),
            receiver_node: None,
            args_node: None,
        }),
        "FCALL" => {
            let args_node = child_node(node, 1);
            Some(CallParts {
                receiver: "self".to_string(),
                message: child_symbol(node, 0)?,
                arguments: arguments(args_node),
                receiver_node: None,
                args_node,
            })
        }
        "CALL" | "QCALL" => {
            let receiver_node = child_node(node, 0);
            let args_node = child_node(node, 2);
            Some(CallParts {
                receiver: receiver_node
                    .map(receiver_text)
                    .unwrap_or_else(|| "self".to_string()),
                message: child_symbol(node, 1)?,
                arguments: arguments(args_node),
                receiver_node,
                args_node,
            })
        }
        _ => None,
    }
}

fn child_node(node: &Node, index: usize) -> Option<&Node> {
    node.children.get(index).and_then(ast::node)
}

fn child_nodes(node: &Node) -> Vec<&Node> {
    node.children.iter().filter_map(ast::node).collect()
}

fn child_symbol(node: &Node, index: usize) -> Option<String> {
    match node.children.get(index)? {
        Child::Symbol(value) | Child::String(value) => Some(value.clone()),
        _ => None,
    }
}

fn first_string_or_symbol(node: &Node) -> Option<String> {
    node.children.iter().find_map(|child| match child {
        Child::Symbol(value) | Child::String(value) => Some(value.clone()),
        _ => None,
    })
}

fn span(node: &Node) -> Span {
    [
        node.first_lineno,
        node.first_column,
        node.last_lineno,
        node.last_column,
    ]
}

fn normalized_text(node: &Node) -> String {
    crate::ast::normalize_text(&node.text)
}

fn receiver_text(node: &Node) -> String {
    match node.r#type.as_str() {
        "SELF" => "self".to_string(),
        "IVAR" | "GVAR" | "LVAR" | "DVAR" | "CONST" => {
            first_string_or_symbol(node).unwrap_or_else(|| normalized_text(node))
        }
        _ => normalized_text(node),
    }
}

fn arguments(args_node: Option<&Node>) -> Vec<String> {
    args_node
        .filter(|node| node.r#type != "ZLIST")
        .map(|node| {
            child_nodes(node)
                .into_iter()
                .flat_map(argument_values)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

fn argument_values(node: &Node) -> Vec<String> {
    if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
        let mut out = Vec::new();
        if let Some(name) = function_name(node) {
            out.push(name);
        }
        if let Some(body) = function_scope(node).and_then(scope_body) {
            out.push(normalized_text(body));
        }
        return out;
    }
    vec![normalized_text(node)]
}

fn owner_name(node: &Node) -> Option<String> {
    child_node(node, 0).map(normalized_text)
}

fn function_name(node: &Node) -> Option<String> {
    if node.r#type == "DEFS" {
        let receiver = child_node(node, 0).map(receiver_text)?;
        let name = child_symbol(node, 1)?;
        return Some(format!("{receiver}.{name}"));
    }
    child_symbol(node, 0)
}

fn function_scope(node: &Node) -> Option<&Node> {
    child_node(node, if node.r#type == "DEFS" { 2 } else { 1 })
}

fn scope_child(node: &Node) -> Option<&Node> {
    child_nodes(node)
        .into_iter()
        .find(|child| child.r#type == "SCOPE")
}

fn scope_body(scope: &Node) -> Option<&Node> {
    child_node(scope, 2)
}

fn scope_args(scope: &Node) -> Option<&Node> {
    child_node(scope, 1)
}

fn function_params(node: &Node) -> Vec<String> {
    function_scope(node)
        .and_then(scope_args)
        .map(|args| {
            child_nodes(args)
                .into_iter()
                .filter(|child| child.r#type == "LASGN")
                .filter_map(first_string_or_symbol)
                .collect()
        })
        .unwrap_or_default()
}

fn predicate_alias(node: &Node, file: &str, owner: &str) -> Option<PredicateAlias> {
    let name = function_name(node)?;
    let body = function_scope(node).and_then(scope_body)?;
    let body = single_expression(body)?;
    let text = predicate_body_text(&normalized_text(body))?;
    Some(PredicateAlias {
        name: name.clone(),
        body: text,
        file: file.to_string(),
        defn: name,
        owner: owner.to_string(),
        line: node.first_lineno,
        span: span(node),
    })
}

fn single_expression(node: &Node) -> Option<&Node> {
    if node.r#type == "BLOCK" {
        let children = child_nodes(node);
        if children.len() == 1 {
            return children.first().copied();
        }
        return None;
    }
    Some(node)
}

fn predicate_body_text(source: &str) -> Option<String> {
    let text = source
        .strip_prefix("return ")
        .unwrap_or(source)
        .trim_end_matches(';')
        .trim()
        .to_string();
    if text.is_empty() || text == "nil" || text.len() > 200 || assignment_like_predicate_body(&text)
    {
        return None;
    }
    predicate_like_body(&text).then_some(text)
}

fn assignment_like_predicate_body(text: &str) -> bool {
    text.contains("||=")
        || text.contains("&&=")
        || text.contains("+=")
        || text.contains("-=")
        || text.contains("*=")
        || text.contains("/=")
        || text.contains("%=")
        || text
            .chars()
            .collect::<Vec<_>>()
            .windows(3)
            .any(|window| matches!(window, [left, '=', right] if !matches!(left, '=' | '!' | '<' | '>') && *right != '='))
}

fn predicate_like_body(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    matches!(lower.as_str(), "true" | "false")
        || lower.contains("true")
        || lower.contains("false")
        || lower.contains("null")
        || lower.contains("nil")
        || text.contains("==")
        || text.contains("!=")
        || text.contains("&&")
        || text.contains("||")
        || lower.contains(" and ")
        || lower.contains(" or ")
}

fn flatten_and(node: &Node) -> Vec<&Node> {
    if node.r#type != "AND" {
        return vec![node];
    }
    child_nodes(node)
        .into_iter()
        .flat_map(flatten_and)
        .collect()
}

fn when_chain(node: &Node) -> Vec<&Node> {
    let mut out = Vec::new();
    let mut current = Some(node);
    while let Some(when) = current {
        if when.r#type != "WHEN" {
            break;
        }
        out.push(when);
        current = child_node(when, 2).filter(|child| child.r#type == "WHEN");
    }
    out
}

fn when_patterns(when: &Node) -> Vec<String> {
    child_node(when, 0)
        .map(|patterns| {
            child_nodes(patterns)
                .into_iter()
                .map(normalized_text)
                .filter(|text| !text.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

fn case_fallback(node: &Node) -> Option<&Node> {
    let chain = child_node(node, if node.r#type == "CASE" { 1 } else { 0 })?;
    let whens = when_chain(chain);
    whens
        .last()
        .and_then(|when| child_node(when, 2).filter(|child| child.r#type != "WHEN"))
}

fn collect_state_refs(node: &Node, refs: &mut BTreeSet<String>) {
    match node.r#type.as_str() {
        "IVAR" | "GVAR" => {
            if let Some(name) = first_string_or_symbol(node) {
                refs.insert(name);
            }
        }
        "CALL" | "QCALL" => {
            if let Some(parts) = call_parts(node) {
                if parts.receiver != "self" {
                    refs.insert(format!("{}.{}", parts.receiver, parts.message));
                }
            }
            for child in child_nodes(node) {
                collect_state_refs(child, refs);
            }
        }
        _ => {
            for child in child_nodes(node) {
                collect_state_refs(child, refs);
            }
        }
    }
}

fn constant_receiver(receiver: &str) -> bool {
    receiver
        .chars()
        .next()
        .map(|ch| ch.is_ascii_uppercase() || ch == ':')
        .unwrap_or(false)
}

fn literal_receiver(receiver: &str) -> bool {
    receiver.starts_with('%')
        || receiver.starts_with('"')
        || receiver.starts_with('\'')
        || receiver.starts_with('[')
        || receiver.starts_with('{')
}

fn state_receiver_field(receiver: &str) -> Option<String> {
    let receiver = receiver.trim();
    if let Some(field) = receiver.strip_prefix('@') {
        return (!field.is_empty()).then(|| field.to_string());
    }
    if let Some(field) = receiver.strip_prefix('$') {
        return (!field.is_empty()).then(|| field.to_string());
    }
    if let Some(field) = receiver.strip_prefix("self.") {
        return simple_identifier(field).then(|| field.to_string());
    }
    None
}

fn mutating_receiver_message(message: &str) -> bool {
    matches!(
        message,
        "<<" | "[]="
            | "add"
            | "append"
            | "clear"
            | "collect!"
            | "compact!"
            | "concat"
            | "delete"
            | "delete_if"
            | "fill"
            | "filter!"
            | "keep_if"
            | "merge!"
            | "move"
            | "push"
            | "reject!"
            | "replace"
            | "shift"
            | "store"
            | "unshift"
            | "update"
            | "write"
    ) || (message.ends_with('!') && !matches!(message, "!=" | "!~"))
}

fn block_like_hash(node: &Node) -> bool {
    let text = node.text.trim();
    text.starts_with('{') && !text.contains("=>") && !text.contains(':')
}

fn normalized_ternary_if(node: &Node) -> bool {
    node.r#type == "IF" && node.text.contains(" ? ") && node.text.contains(" : ")
}

fn normalize_comparison_source(source: &str) -> String {
    let mut text = source.trim().to_string();
    if let Some(stripped) = text.strip_prefix('!') {
        text = stripped
            .trim_start_matches('(')
            .trim_end_matches(')')
            .trim()
            .to_string();
    }
    if let Some(stripped) = text.strip_prefix("self.") {
        text = stripped.to_string();
    }
    if let Some(stripped) = text.strip_prefix('@') {
        text = stripped.to_string();
    }
    if let Some(dot_index) = text.find('.') {
        let receiver = &text[..dot_index];
        let rest = &text[dot_index + 1..];
        if simple_identifier(receiver)
            && (rest.contains(" == ") || rest.contains(" != ") || rest.contains('.'))
        {
            text = rest.to_string();
        }
    }
    crate::ast::normalize_text(&text)
}

pub(crate) fn raw_from_normalized(node: &Node) -> RawNode {
    RawNode {
        kind: raw_kind(node).to_string(),
        text: node.text.clone(),
        span: span(node),
        named: true,
        field_name: None,
        children: node.children.iter().filter_map(raw_child).collect(),
    }
}

fn raw_child(child: &Child) -> Option<RawNode> {
    match child {
        Child::Node(node) => Some(raw_from_normalized(node)),
        Child::Symbol(value) | Child::String(value) => Some(RawNode {
            kind: "identifier".to_string(),
            text: value.clone(),
            span: [1, 0, 1, 0],
            named: true,
            field_name: None,
            children: Vec::new(),
        }),
        _ => None,
    }
}

fn raw_kind(node: &Node) -> &str {
    match node.r#type.as_str() {
        "ROOT" => "program",
        "SCOPE" => "body",
        "ARGS" => "parameters",
        "CLASS" => "class",
        "MODULE" => "module",
        "DEFN" | "DEFS" => "method",
        "IF" => "if",
        "UNLESS" => "unless",
        "CASE" | "CASE2" => "case",
        "WHEN" => "when",
        "AND" | "OR" | "OPCALL" => "binary",
        "LASGN" | "IASGN" | "GASGN" | "ATTRASGN" | "OP_ASGN1" | "OP_ASGN2" => "assignment",
        "LVAR" | "DVAR" | "CONST" => "identifier",
        "IVAR" => "instance_variable",
        "GVAR" => "global_variable",
        "LIST" | "ZLIST" => "argument_list",
        "ITER" => "block",
        "BLOCK" => "body_statement",
        "CALL" | "QCALL" | "FCALL" | "VCALL" => "call",
        "TRUE" => "true",
        "FALSE" => "false",
        "NIL" => "nil",
        "STR" | "DSTR" => "string",
        _ => node.r#type.as_str(),
    }
}

fn dispatch_members_inside(
    call_sites: &[CallSite],
    predicate: &str,
    function: &str,
    outer: Span,
) -> Vec<String> {
    let mut members = dispatch_member_calls(call_sites, predicate, function)
        .into_iter()
        .filter(|call| span_contains(outer, call.span))
        .map(dispatch_member_name)
        .collect::<Vec<_>>();
    members.sort();
    members.dedup();
    members
}

fn dispatch_members_outside(
    call_sites: &[CallSite],
    predicate: &str,
    function: &str,
    decision_span: Span,
) -> Vec<String> {
    let mut members = dispatch_member_calls(call_sites, predicate, function)
        .into_iter()
        .filter(|call| !span_contains(decision_span, call.span))
        .map(dispatch_member_name)
        .collect::<Vec<_>>();
    members.sort();
    members.dedup();
    members
}

fn dispatch_member_calls<'a>(
    call_sites: &'a [CallSite],
    predicate: &str,
    function: &str,
) -> Vec<&'a CallSite> {
    call_sites
        .iter()
        .filter(|call| {
            call.function == function && call.receiver == predicate && !call.message.is_empty()
        })
        .collect()
}

fn dispatch_member_name(call: &CallSite) -> String {
    call.message.trim_end_matches('=').to_string()
}

fn dispatch_constant_patterns(member: &str) -> Vec<String> {
    member
        .split(',')
        .map(|pattern| pattern.trim())
        .filter(|pattern| dispatch_constant_pattern(pattern))
        .map(ToString::to_string)
        .collect()
}

fn dispatch_constant_pattern(pattern: &str) -> bool {
    if pattern.is_empty() {
        return false;
    }
    pattern.replace("::", ".").split(['.', '_']).all(|part| {
        let mut chars = part.chars();
        matches!(chars.next(), Some(first) if first.is_ascii_uppercase())
            && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
    })
}

fn span_contains(outer: Span, inner: Span) -> bool {
    (outer[0] < inner[0] || (outer[0] == inner[0] && outer[1] <= inner[1]))
        && (outer[2] > inner[2] || (outer[2] == inner[2] && outer[3] >= inner[3]))
}

fn simple_identifier(value: &str) -> bool {
    let mut chars = value.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric())
}

fn dedupe_decision_sites(sites: &mut Vec<DecisionSite>) {
    let mut seen = BTreeSet::new();
    sites.retain(|site| {
        seen.insert((
            site.kind.clone(),
            site.members.clone(),
            site.file.clone(),
            site.function.clone(),
            site.line,
            site.span,
            site.predicate.clone(),
            site.enclosing_span,
        ))
    });
}

fn effect_key(site: &SemanticEffectSite) -> (String, String, String, usize, Span) {
    (
        site.kind.clone(),
        site.detail.clone(),
        site.function.clone(),
        site.line,
        site.span,
    )
}
