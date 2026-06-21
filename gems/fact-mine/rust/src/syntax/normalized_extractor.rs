use super::{
    normalized_behavior::{
        NormalizedCallParts, NormalizedCallProjection, NormalizedLanguageBehavior,
        NormalizedStateRead,
    },
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

pub(crate) fn extract(
    file: &Path,
    lines: &[String],
    root: &Node,
    behavior: &dyn NormalizedLanguageBehavior,
) -> NormalizedFacts {
    let mut extractor = Extractor::new(file, lines, behavior);
    extractor.scan_root(root);
    extractor.finish()
}

struct Extractor<'a> {
    file: String,
    lines: Vec<String>,
    behavior: &'a dyn NormalizedLanguageBehavior,
    file_owner: String,
    owners: Vec<String>,
    functions: Vec<String>,
    function_params: Vec<Vec<String>>,
    controls: Vec<String>,
    decision_spans: Vec<Span>,
    receiver_aliases: Vec<BTreeMap<String, String>>,
    owner_fields: BTreeMap<String, Vec<String>>,
    facts: NormalizedFacts,
    seen_calls: HashSet<(String, String, String, usize, Span)>,
    seen_reads: HashSet<(String, String, String, String, usize, Span)>,
    seen_writes: HashSet<(String, String, String, String, usize, Span)>,
    seen_effects: HashSet<(String, String, String, usize, Span)>,
}

impl<'a> Extractor<'a> {
    fn new(file: &Path, lines: &[String], behavior: &'a dyn NormalizedLanguageBehavior) -> Self {
        let file = file.to_string_lossy().to_string();
        let file_owner = Path::new(&file)
            .file_stem()
            .and_then(|stem| stem.to_str())
            .unwrap_or("Object")
            .to_string();
        Self {
            file,
            lines: lines.to_vec(),
            behavior,
            file_owner,
            owners: Vec::new(),
            functions: Vec::new(),
            function_params: Vec::new(),
            controls: Vec::new(),
            decision_spans: Vec::new(),
            receiver_aliases: Vec::new(),
            owner_fields: BTreeMap::new(),
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
        self.record_behavior_node_reads(node);
        match node.r#type.as_str() {
            "CLASS" | "MODULE" => self.scan_owner(node),
            "DEFN" | "DEFS" => self.scan_function(node),
            "HASH" if block_like_hash(node) => {}
            "IF" | "UNLESS" => self.scan_if(node),
            "FOR" | "WHILE" | "UNTIL" => self.scan_loop(node),
            "RESCUE" => self.scan_rescue(node),
            "CASE" | "CASE2" => self.scan_case(node),
            "AND" | "OR" => self.scan_boolean(node),
            "CALL" | "QCALL" | "FCALL" | "VCALL" => self.record_call_node(node, false),
            "ITER" => self.scan_iter(node),
            "YIELD" => self.scan_yield(node),
            "XSTR" => self.scan_command_string(node),
            "SCLASS" => self.scan_singleton_class(node),
            "LASGN" => self.scan_local_assignment(node),
            "FIELD_EXPRESSION" | "RAW_ARGUMENT" => self.scan_literal_expression(node),
            "IASGN" | "GASGN" => self.record_state_write(node),
            "IVAR" | "GVAR" => self.record_state_read_node(node),
            "LVAR" => self.record_bare_state_read_node(node),
            "ATTRASGN" => self.scan_attr_assignment(node),
            "OPCALL" => self.scan_operator_call(node),
            "OP_ASGN1" | "OP_ASGN2" => self.scan_operator_assignment(node),
            _ => {
                if self.behavior.declarative_owner(node, &self.current_owner()).is_some() {
                    self.scan_declarative_owner(node);
                } else {
                    self.scan_children(node);
                }
            }
        }
    }

    fn scan_children(&mut self, node: &Node) {
        for child in child_nodes(node) {
            self.scan(child);
        }
    }

    fn scan_owner(&mut self, node: &Node) {
        let name = owner_name(node)
            .or_else(|| self.behavior.owner_name_from_text(node))
            .or_else(|| owner_name_from_text(node))
            .unwrap_or_else(|| "(anonymous)".to_string());
        let qualified = if self.owners.is_empty() {
            name
        } else {
            format!("{}::{name}", self.current_owner())
        };
        let kind = owner_kind(node, self.behavior);
        self.facts
            .owner_defs
            .push(self.owner_row(&qualified, &kind, node));
        self.owners.push(qualified);
        self.collect_owner_fields_from_children(node);
        if let Some(scope) = scope_child(node) {
            self.scan(scope);
        }
        self.owners.pop();
    }

    fn scan_declarative_owner(&mut self, node: &Node) {
        let Some(owner) = self.behavior.declarative_owner(node, &self.current_owner()) else {
            self.scan_children(node);
            return;
        };
        let row = self.owner_row(&owner.name, &owner.kind, node);
        self.facts.owner_defs.push(row);
        self.owners.push(owner.name);
        self.collect_owner_fields_from_children(node);
        self.scan_children(node);
        self.owners.pop();
    }

    fn owner_row(&self, name: &str, kind: &str, node: &Node) -> OwnerDef {
        let owner_span = owner_name_span(name, node, self.behavior);
        OwnerDef {
            file: self.file.clone(),
            name: name.to_string(),
            kind: kind.to_string(),
            line: owner_span[0],
            span: owner_span,
        }
    }

    fn scan_function(&mut self, node: &Node) {
        let name = function_name_with_behavior(node, self.behavior)
            .unwrap_or_else(|| "(anonymous)".to_string());
        let current_owner = self.current_owner();
        let owner = self
            .behavior
            .owner_for_function(&name, node, &current_owner, &self.file_owner);
        let body = raw_from_normalized(node);
        for effect in self.behavior.structural_semantic_effects(node, &name) {
            self.record_semantic_effect(node, &effect.kind, &effect.detail);
        }
        let params = function_params(node, self.behavior);
        let visibility = self.behavior.function_visibility(&name, node, &self.lines);
        self.facts.function_defs.push(FunctionDef {
            file: self.file.clone(),
            name: name.clone(),
            owner: owner.clone(),
            line: node.first_lineno,
            span: span(node),
            body,
            visibility: Some(visibility),
            params: params.clone(),
        });
        if let Some(alias) = predicate_alias(node, &self.file, &owner, self.behavior) {
            self.facts.predicate_aliases.push(alias);
        }
        self.record_initializer_field_reads(node, &owner, &name);
        let owner_pushed = owner != current_owner;
        if owner_pushed {
            self.owners.push(owner);
        }
        self.functions.push(name);
        self.function_params.push(params);
        self.receiver_aliases
            .push(self.behavior.receiver_aliases_for_function(node));
        let body_context = self.current_owner();
        let body_owner = self.behavior.body_owner_for_function(
            self.current_function().as_str(),
            node,
            &body_context,
            &self.file_owner,
        );
        let body_owner_pushed = body_owner.is_some();
        if let Some(body_owner) = body_owner {
            self.facts
                .owner_defs
                .push(self.owner_row(&body_owner.name, &body_owner.kind, node));
            self.owners.push(body_owner.name);
            self.collect_owner_fields_from_children(node);
        }
        if let Some(scope) = function_scope(node) {
            if let Some(body) = scope_body(scope) {
                self.scan(body);
            }
        }
        if body_owner_pushed {
            self.owners.pop();
        }
        self.receiver_aliases.pop();
        self.function_params.pop();
        self.functions.pop();
        if owner_pushed {
            self.owners.pop();
        }
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

    fn scan_rescue(&mut self, node: &Node) {
        let body = child_node(node, 0);
        let resbody = child_node(node, 1);
        if let (Some(body), Some(resbody)) = (body, resbody) {
            for effect in self.behavior.rescue_semantic_effects(body, resbody) {
                self.record_semantic_effect(node, &effect.kind, &effect.detail);
            }
        }
        self.scan_children(node);
    }

    fn scan_yield(&mut self, node: &Node) {
        if self.behavior.yield_semantic_effect(node) {
            self.record_semantic_effect(node, "dynamic_dispatch", "yield");
        }
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
        if normalized_ternary_if(node) {
            if self.behavior.ternary_children_conditional(node) {
                for child in child_nodes(node) {
                    self.with_control("conditional", |this| this.scan(child));
                }
            } else {
                self.scan_children(node);
            }
            return;
        }
        self.decision_spans.push(span(node));
        self.with_control("conditional", |this| this.scan(condition));
        self.decision_spans.pop();
        self.record_branch_decision(node, condition);
        self.record_if_arms(node, condition);

        for child in [child_node(node, 1), child_node(node, 2)]
            .into_iter()
            .flatten()
        {
            self.with_control("conditional", |this| this.scan(child));
        }
    }

    fn scan_loop(&mut self, node: &Node) {
        for child in child_nodes(node) {
            self.with_control("iterates", |this| this.scan(child));
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
        let mut patterns = whens
            .iter()
            .flat_map(|when| self.when_patterns(when))
            .collect::<Vec<_>>();
        patterns.sort();
        if let Some(value) = value {
            if patterns.len() >= 2 {
                self.facts.decision_sites.push(DecisionSite {
                    kind: "case_dispatch".to_string(),
                    members: patterns.clone(),
                    file: self.file.clone(),
                    function: self.current_function(),
                    line: node.first_lineno,
                    span: span(node),
                    predicate: self.case_predicate_text(value),
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
            let members = self.behavior.boolean_decision_members(members, node);
            if members.len() >= 2 {
                self.facts.decision_sites.push(DecisionSite {
                    kind: "conjunction".to_string(),
                    members,
                    file: self.file.clone(),
                    function: self.current_function(),
                    line: node.first_lineno,
                    span: span(node),
                    predicate: normalized_text(node),
                    enclosing_span: self.behavior.boolean_enclosing_span(
                        node,
                        span(node),
                        self.decision_spans.last().copied(),
                    ),
                });
            }
        }
        for child in child_nodes(node) {
            self.scan(child);
        }
    }

    fn scan_attr_assignment(&mut self, node: &Node) {
        let mut effect_detail = "[]=".to_string();
        let mut written_field: Option<String> = None;
        if let (Some(receiver), Some(field)) = (child_node(node, 0), child_symbol(node, 1)) {
            let field = field.trim_end_matches('=').to_string();
            if field != "[]" {
                effect_detail = format!("{field}=");
                let receiver_name = self.receiver_text(receiver);
                if node.text.contains('[') {
                    if let Some(indexed_field) = state_receiver_field(&receiver_name) {
                        effect_detail = "[]=".to_string();
                        self.record_state_write_target("self".to_string(), indexed_field, node);
                    } else {
                        let write_span = self.behavior.state_write_span(
                            &receiver_name,
                            &field,
                            node,
                            span(node),
                        );
                        self.record_state_write_target_span(receiver_name, field.clone(), node, write_span);
                    }
                } else {
                    let write_span =
                        self.behavior
                            .state_write_span(&receiver_name, &field, node, span(node));
                    self.record_state_write_target_span(
                        receiver_name,
                        field.clone(),
                        node,
                        write_span,
                    );
                }
                written_field = Some(field);
            }
        } else if let Some(receiver) = child_node(node, 0).map(|node| self.receiver_text(node)) {
            if let Some(field) = state_receiver_field(&receiver) {
                self.record_state_write_target("self".to_string(), field, node);
            }
        }
        if hidden_assignment_mutation(node, written_field.as_deref(), self.behavior) {
            self.record_semantic_effect(node, "hidden_mutation", &effect_detail);
        }
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
                    canon_source: self.behavior.normalize_comparison_source(&raw),
                    raw,
                    file: self.file.clone(),
                    function: self.current_function(),
                    line: node.first_lineno,
                    span: span(node),
                    enclosing_span: span(node),
                });
            }
        }
        if child_symbol(node, 1).as_deref() == Some("<<")
            && !self.behavior.stream_insertion_operator(node)
        {
            self.record_semantic_effect(node, "hidden_mutation", "<<");
        }
        self.scan_children(node);
    }

    fn scan_operator_assignment(&mut self, node: &Node) {
        self.record_semantic_effect(node, "hidden_mutation", "op-assign");
        self.scan_children(node);
    }

    fn record_call_node(&mut self, node: &Node, block: bool) {
        let Some(parts) = self.call_parts(node) else {
            self.scan_children(node);
            return;
        };
        if let Some(receiver) = parts.receiver_node {
            self.scan(receiver);
        }
        if let Some(args) = parts.args_node {
            self.scan(args);
        }
        self.record_embedded_member_reads(node);

        let conditional = self.conditional_context();
        let behavior_parts = NormalizedCallParts {
            receiver: parts.receiver.clone(),
            message: parts.message.clone(),
            arguments: parts.arguments.clone(),
        };
        let access_span = self.call_access_span(node);
        let call_span = self.behavior.call_site_span(
            node,
            &behavior_parts,
            span(node),
            access_span,
            &self.current_function(),
        );
        let projected = NormalizedCallProjection {
            receiver: self.behavior.call_receiver(&behavior_parts),
            message: parts.message.clone(),
            arguments: parts.arguments,
            access_span,
            span: call_span,
        };
        let projected = self.behavior.project_call(node, projected);
        if projected.message == "[]" {
            if self.behavior.emit_index_call_site(node, &projected) {
                self.append_call_site(projected, node, conditional, block);
            }
            return;
        }
        if self.behavior.property_read_call(node, &behavior_parts) {
            self.record_state_read_for_call(&projected, node);
            return;
        }
        if self.suppress_call_site(node, &projected) {
            return;
        }

        let call = CallSite {
            receiver: projected.receiver.clone(),
            message: projected.message.clone(),
            file: self.file.clone(),
            function: self.current_function(),
            owner: self.current_owner(),
            line: node.first_lineno,
            span: projected.span,
            conditional,
            arguments: projected.arguments.clone(),
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
            self.record_state_read_for_call(&projected, node);
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

    fn append_call_site(
        &mut self,
        projected: NormalizedCallProjection,
        node: &Node,
        conditional: bool,
        block: bool,
    ) {
        let call = CallSite {
            receiver: projected.receiver,
            message: projected.message,
            file: self.file.clone(),
            function: self.current_function(),
            owner: self.current_owner(),
            line: node.first_lineno,
            span: projected.span,
            conditional,
            arguments: projected.arguments,
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

    fn scan_local_assignment(&mut self, node: &Node) {
        let field = first_string_or_symbol(node);
        let writes = self
            .behavior
            .local_assignment_writes(field.as_deref(), node, span(node));
        if !writes.is_empty() {
            for write in writes {
                self.record_state_write_target_span(write.receiver, write.field, node, write.span);
            }
            if let Some(value) = child_node(node, 1) {
                self.scan(value);
            }
            return;
        }

        if self.behavior.implicit_owner_fields()
            && field
                .as_deref()
                .is_some_and(|field| self.owner_field(field))
            && self.current_function() != "(top-level)"
        {
            let field = field.unwrap();
            self.record_state_write_target_span(
                "self".to_string(),
                field.clone(),
                node,
                target_name_span(&field, node),
            );
        }
        if let Some(value) = child_node(node, 1) {
            self.scan(value);
        }
    }

    fn scan_literal_expression(&mut self, node: &Node) {
        self.record_literal_state_reads(node);
        self.scan_children(node);
    }

    fn record_state_write_target(&mut self, receiver: String, field: String, node: &Node) {
        self.record_state_write_target_span(receiver, field, node, span(node));
    }

    fn record_state_write_target_span(
        &mut self,
        receiver: String,
        field: String,
        node: &Node,
        write_span: Span,
    ) {
        let write = StateWrite {
            field,
            receiver,
            file: self.file.clone(),
            function: self.current_function(),
            line: node.first_lineno,
            span: write_span,
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

    fn record_bare_state_read_node(&mut self, node: &Node) {
        let field = first_string_or_symbol(node).unwrap_or_else(|| normalized_text(node));
        if !self.behavior.implicit_owner_fields()
            || !self.owner_field(&field)
            || self.current_function() == "(top-level)"
        {
            return;
        }
        self.push_state_read(StateRead {
            field,
            receiver: "self".to_string(),
            file: self.file.clone(),
            function: self.current_function(),
            line: node.first_lineno,
            span: span(node),
            owner: self.current_owner(),
        });
    }

    fn record_embedded_member_reads(&mut self, node: &Node) {
        for read in self.behavior.embedded_member_reads(node) {
            self.push_behavior_read(read, node);
        }
    }

    fn record_literal_state_reads(&mut self, node: &Node) {
        let node_span = span(node);
        let source = self.span_source(node_span);
        let text = normalized_text_with_behavior(node, self.behavior);
        for read in self
            .behavior
            .literal_state_reads(node, &text, node_span, &source)
        {
            self.push_behavior_read(read, node);
        }
    }

    fn record_behavior_node_reads(&mut self, node: &Node) {
        for read in self.behavior.node_state_reads(node) {
            self.push_behavior_read(read, node);
        }
    }

    fn record_initializer_field_reads(&mut self, node: &Node, owner: &str, function_name: &str) {
        let fields = self
            .owner_fields
            .get(owner)
            .cloned()
            .unwrap_or_default();
        for read in self
            .behavior
            .initializer_field_reads(node, owner, &fields, function_name)
        {
            self.push_behavior_read(read, node);
        }
    }

    fn push_behavior_read(&mut self, read: NormalizedStateRead, fallback_node: &Node) {
        self.push_state_read(StateRead {
            field: read.field,
            receiver: read.receiver,
            file: self.file.clone(),
            function: self.current_function(),
            line: read.line.unwrap_or(fallback_node.first_lineno),
            span: read.span,
            owner: self.current_owner(),
        });
    }

    fn record_state_read_for_call(&mut self, call: &NormalizedCallProjection, node: &Node) {
        if self
            .behavior
            .suppress_state_read_for_call(call, &self.span_source(call.span))
        {
            return;
        }
        if self.behavior.suppress_self_call_state_read(call) {
            return;
        }
        if call.receiver == "self" && call.message.chars().next().is_some_and(|ch| ch.is_ascii_uppercase()) {
            return;
        }
        if call.receiver.is_empty()
            || constant_receiver(&call.receiver)
            || literal_receiver(&call.receiver)
            || call.receiver.starts_with('@')
            || call.receiver.starts_with('$')
        {
            return;
        }
        if call.message.chars().all(|ch| ch.is_ascii_digit()) {
            return;
        }
        if matches!(
            call.message.as_str(),
            "==" | "!=" | "===" | "<" | "<=" | ">" | ">=" | "[]" | "[]=" | "call"
        ) {
            return;
        }
        let read_span = if self.behavior.state_read_uses_access_span(call) {
            call.access_span
        } else {
            call.span
        };
        self.push_state_read(StateRead {
            field: call.message.clone(),
            receiver: call.receiver.clone(),
            file: self.file.clone(),
            function: self.current_function(),
            line: node.first_lineno,
            span: read_span,
            owner: self.current_owner(),
        });
    }

    fn record_state_write_for_mutating_call(&mut self, call: &CallSite) {
        if !self.behavior.mutating_receiver_message(&call.message) {
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
        if normalized_ternary_if(node) || self.behavior.suppress_branch_decision(node) {
            return;
        }
        let mut refs = BTreeSet::new();
        self.collect_state_refs(condition, &mut refs);
        if refs.is_empty() {
            return;
        }
        let predicate = self.branch_predicate_text(node, condition);
        self.facts.branch_decisions.push(BranchDecision {
            file: self.file.clone(),
            function: self.current_function(),
            line: node.first_lineno,
            span: span(node),
            predicate,
            state_refs: refs.into_iter().collect(),
        });
    }

    fn record_if_arms(&mut self, node: &Node, condition: &Node) {
        if normalized_ternary_if(node) || self.behavior.suppress_branch_decision(node) {
            return;
        }
        let predicate = self.normalized_text(condition);
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
        for member in self.when_patterns(when) {
            self.facts.branch_arms.push(BranchArm {
                file: self.file.clone(),
                function: self.current_function(),
                kind: "case".to_string(),
                line: when.first_lineno,
                span: span(when),
                decision_line: node.first_lineno,
                decision_span: span(node),
                predicate: self.normalized_text(value),
                member,
                body: self.normalized_text(body),
            });
        }
    }

    fn record_dispatch_site(&mut self, node: &Node, value: &Node, whens: &[&Node]) {
        let predicate = self.normalized_text(value);
        if predicate.is_empty() {
            return;
        }
        let function = self.current_function();
        let mut arm_members: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for when in whens {
            let members =
                dispatch_members_inside(&self.facts.call_sites, &predicate, &function, span(when));
            for pattern in self.when_patterns(when) {
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

    fn collect_owner_fields_from_children(&mut self, node: &Node) {
        let owner = self.current_owner();
        for child in child_nodes(node) {
            self.collect_owner_fields_from_node(&owner, child);
        }
    }

    fn collect_owner_fields_from_node(&mut self, owner: &str, node: &Node) {
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS" | "CLASS" | "MODULE") {
            return;
        }

        if let Some(mut declaration) = self.behavior.state_declaration_from_node(node, owner) {
            declaration.file = self.file.clone();
            declaration.owner = owner.to_string();
            declaration.line = node.first_lineno;
            declaration.span = span(node);
            self.owner_fields
                .entry(owner.to_string())
                .or_default()
                .push(declaration.field.clone());
            self.facts.state_declarations.push(declaration);
        }

        if matches!(
            node.r#type.as_str(),
            "FIELD_DECLARATION" | "PROPERTY_DECLARATION" | "FIELD_DECLARATION_LIST"
        ) {
            if let Some(name) = self.behavior.field_name_from_declaration(node) {
                self.push_owner_field(owner, name);
            }
            for child in child_nodes(node) {
                self.collect_owner_fields_from_node(owner, child);
                if child.r#type == "LVAR" {
                    if let Some(name) = first_string_or_symbol(child) {
                        if simple_identifier(&name) {
                            self.push_owner_field(owner, name);
                        }
                    }
                }
            }
            return;
        }

        for child in child_nodes(node) {
            self.collect_owner_fields_from_node(owner, child);
        }
    }

    fn push_owner_field(&mut self, owner: &str, field: String) {
        let fields = self.owner_fields.entry(owner.to_string()).or_default();
        if !fields.contains(&field) {
            fields.push(field);
        }
    }

    fn owner_field(&self, field: &str) -> bool {
        self.owner_fields
            .get(&self.current_owner())
            .is_some_and(|fields| fields.iter().any(|candidate| candidate == field))
    }

    fn collect_state_refs(&self, node: &Node, refs: &mut BTreeSet<String>) {
        match node.r#type.as_str() {
            "OPCALL" => {
                for child in child_nodes(node) {
                    self.collect_state_refs(child, refs);
                }
            }
            "IVAR" | "GVAR" => {
                if let Some(name) = first_string_or_symbol(node) {
                    refs.insert(name);
                }
            }
            "CALL" | "QCALL" => {
                if let Some(parts) = self.call_parts(node) {
                    let behavior_parts = NormalizedCallParts {
                        receiver: parts.receiver.clone(),
                        message: parts.message.clone(),
                        arguments: parts.arguments.clone(),
                    };
                    if let Some(reference) = self.branch_state_ref(node, &behavior_parts) {
                        refs.insert(reference);
                    }
                }
                for child in child_nodes(node) {
                    self.collect_state_refs(child, refs);
                }
            }
            "FIELD_EXPRESSION" | "RAW_ARGUMENT" => {
                let text = self.normalized_text(node);
                refs.extend(self.behavior.literal_state_refs(node, &text));
                for child in child_nodes(node) {
                    self.collect_state_refs(child, refs);
                }
            }
            _ => {
                for child in child_nodes(node) {
                    self.collect_state_refs(child, refs);
                }
            }
        }
    }

    fn branch_predicate_text(&self, branch: &Node, condition: &Node) -> String {
        let predicate = self.normalized_text(condition);
        if predicate.starts_with('(') {
            return predicate;
        }
        if self.behavior.wrap_branch_predicate(branch) {
            format!("({predicate})")
        } else {
            predicate
        }
    }

    fn branch_state_ref(&self, node: &Node, parts: &NormalizedCallParts) -> Option<String> {
        if parts.message == "[]" || self.behavior.method_state_ref(node, parts) {
            return None;
        }
        let default_ref = if parts.receiver == "self" {
            self.behavior.explicit_self_state_ref(node, &parts.message)
        } else {
            format!("{}.{}", parts.receiver, parts.message)
        };
        self.behavior.branch_state_ref(node, parts, default_ref)
    }

    fn when_patterns(&mut self, when: &Node) -> Vec<String> {
        let Some(patterns) = child_node(when, 0) else {
            return Vec::new();
        };
        let raw = self.normalized_text(patterns);
        if let Some(case_source) = raw
            .lines()
            .next()
            .and_then(|line| line.trim_start().strip_prefix("case "))
            .and_then(|line| line.split_once(':').map(|(source, _)| source.trim().to_string()))
        {
            if case_source == "default" {
                return Vec::new();
            }
            if case_source.contains(',') {
                return self.behavior.split_case_source(&case_source);
            }
            return vec![self.behavior.case_pattern_display(&case_source)];
        }
        let values = child_nodes(patterns)
            .into_iter()
            .map(|child| {
                self.record_literal_state_reads(child);
                self.normalized_text(child)
            })
            .filter(|pattern| !pattern.is_empty() && pattern != "default")
            .collect::<Vec<_>>();
        self.behavior.case_pattern_values(values)
    }

    fn case_predicate_text(&self, value: &Node) -> String {
        self.behavior
            .case_predicate_text(&self.normalized_text(value))
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

    fn call_parts<'node>(&self, node: &'node Node) -> Option<CallParts<'node>> {
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
                    arguments: self.arguments(args_node),
                    receiver_node: None,
                    args_node,
                })
            }
            "CALL" | "QCALL" => {
                let receiver_node = child_node(node, 0);
                let args_node = child_node(node, 2);
                Some(CallParts {
                    receiver: receiver_node
                        .map(|node| self.receiver_text(node))
                        .unwrap_or_else(|| "self".to_string()),
                    message: child_symbol(node, 1)?,
                    arguments: self.arguments(args_node),
                    receiver_node,
                    args_node,
                })
            }
            _ => None,
        }
    }

    fn receiver_text(&self, node: &Node) -> String {
        let value = match node.r#type.as_str() {
            "SELF" => "self".to_string(),
            "IVAR" | "GVAR" | "LVAR" | "DVAR" | "CONST" => {
                first_string_or_symbol(node).unwrap_or_else(|| self.normalized_text(node))
            }
            "CALL" | "QCALL" => self
                .call_parts(node)
                .map(|parts| self.call_source_text(&parts, Some(node)))
                .unwrap_or_else(|| self.normalized_text(node)),
            _ => self.normalized_text(node),
        };
        self.current_receiver_aliases()
            .get(&value)
            .cloned()
            .unwrap_or(value)
    }

    fn call_source_text(&self, parts: &CallParts<'_>, node: Option<&Node>) -> String {
        if node.is_some_and(|node| node.first_lineno != node.last_lineno && node.text.contains('('))
        {
            return node.map(|node| self.normalized_text(node)).unwrap_or_default();
        }
        let receiver = parts.receiver.as_str();
        let message = self.source_call_message(parts, node);
        let operator = if message.starts_with('[') {
            ""
        } else {
            self.source_member_operator(node)
        };
        if receiver == "self" {
            self.behavior.self_member_receiver(&message)
        } else if receiver.is_empty() {
            message
        } else {
            format!("{receiver}{operator}{message}")
        }
    }

    fn source_call_message(&self, parts: &CallParts<'_>, node: Option<&Node>) -> String {
        let message = self.behavior.source_message_text(&parts.message, node);
        if message != "[]" && !parts.arguments.is_empty() {
            return format!("{}({})", message, parts.arguments.join(", "));
        }
        if message == "[]" && !parts.arguments.is_empty() {
            return format!("[{}]", parts.arguments.join(", "));
        }
        message
    }

    fn source_member_operator(&self, node: Option<&Node>) -> &'static str {
        let text = node.map(|node| node.text.as_str()).unwrap_or_default();
        if text.contains("&.") {
            "&."
        } else if text.contains("?.") || text.contains("?->") {
            "?."
        } else if text.contains("->") {
            "->"
        } else {
            "."
        }
    }

    fn arguments(&self, args_node: Option<&Node>) -> Vec<String> {
        args_node
            .filter(|node| node.r#type != "ZLIST")
            .map(|node| {
                child_nodes(node)
                    .into_iter()
                    .flat_map(|child| self.argument_values(child))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    }

    fn argument_values(&self, node: &Node) -> Vec<String> {
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            let mut out = Vec::new();
            if let Some(name) = function_name(node) {
                out.push(name);
            }
            if let Some(body) = function_scope(node).and_then(scope_body) {
                out.push(self.normalized_text(body));
            }
            return out;
        }
        if matches!(node.r#type.as_str(), "CALL" | "QCALL") {
            if let Some(parts) = self.call_parts(node) {
                if parts.arguments.is_empty() {
                    return vec![self.call_source_text(&parts, Some(node))];
                }
            }
        }
        if quoted_literal_node(node) {
            return vec![quoted_literal_text(node, self.behavior)];
        }
        if matches!(node.r#type.as_str(), "LVAR" | "DVAR" | "CONST" | "IVAR" | "GVAR") {
            if let Some(value) = first_string_or_symbol(node) {
                return vec![value];
            }
        }
        vec![self.normalized_text(node)]
    }

    fn call_access_span(&self, node: &Node) -> Span {
        let text = node.text.as_str();
        let computed = text.rfind('(').and_then(|open_index| {
            (node.first_lineno == node.last_lineno).then(|| {
                if text.starts_with('(') && text.ends_with(')') && open_index == 0 {
                    [
                        node.first_lineno,
                        node.first_column + 1,
                        node.first_lineno,
                        node.last_column.saturating_sub(1),
                    ]
                } else {
                    [
                        node.first_lineno,
                        node.first_column,
                        node.first_lineno,
                        node.first_column + open_index,
                    ]
                }
            })
        });
        self.behavior
            .call_access_span(node, computed, span(node))
    }

    fn suppress_call_site(&self, node: &Node, call: &NormalizedCallProjection) -> bool {
        if call.receiver == "self"
            && call
                .message
                .chars()
                .next()
                .is_some_and(|ch| ch.is_ascii_uppercase())
            && call.arguments.is_empty()
        {
            return true;
        }
        if constant_receiver(&call.receiver)
            && !call.receiver.contains('(')
            && call.arguments.is_empty()
            && !self.behavior.preserve_constant_receiver_call(call)
        {
            return true;
        }
        self.behavior.suppress_call_site(node, call)
    }

    fn normalized_text(&self, node: &Node) -> String {
        normalized_text_with_behavior(node, self.behavior)
    }

    fn current_receiver_aliases(&self) -> BTreeMap<String, String> {
        let mut aliases = BTreeMap::new();
        for entry in &self.receiver_aliases {
            aliases.extend(entry.clone());
        }
        aliases
    }

    fn span_source(&self, source_span: Span) -> String {
        let [first_line, first_column, last_line, last_column] = source_span;
        if first_line == 0 || last_line == 0 {
            return String::new();
        }
        if first_line == last_line {
            return self
                .lines
                .get(first_line - 1)
                .and_then(|line| line.get(first_column..last_column))
                .unwrap_or("")
                .to_string();
        }
        let mut parts = Vec::new();
        if let Some(line) = self.lines.get(first_line - 1) {
            parts.push(line.get(first_column..).unwrap_or("").to_string());
        }
        for line_index in first_line..last_line.saturating_sub(1) {
            if let Some(line) = self.lines.get(line_index) {
                parts.push(line.clone());
            }
        }
        if let Some(line) = self.lines.get(last_line - 1) {
            parts.push(line.get(..last_column).unwrap_or("").to_string());
        }
        parts.join("")
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
                arguments: basic_arguments(args_node),
                receiver_node: None,
                args_node,
            })
        }
        "CALL" | "QCALL" => {
            let receiver_node = child_node(node, 0);
            let args_node = child_node(node, 2);
            Some(CallParts {
                receiver: receiver_node
                    .map(normalized_text)
                    .unwrap_or_else(|| "self".to_string()),
                message: child_symbol(node, 1)?,
                arguments: basic_arguments(args_node),
                receiver_node,
                args_node,
            })
        }
        _ => None,
    }
}

fn basic_arguments(args_node: Option<&Node>) -> Vec<String> {
    args_node
        .filter(|node| node.r#type != "ZLIST")
        .map(|node| {
            child_nodes(node)
                .into_iter()
                .map(normalized_text)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
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

fn normalized_text_with_behavior(node: &Node, behavior: &dyn NormalizedLanguageBehavior) -> String {
    let text = if quoted_literal_node(node) {
        quoted_literal_text(node, behavior)
    } else {
        normalized_text(node)
    };
    behavior.normalize_source_text(&text)
}

fn quoted_literal_node(node: &Node) -> bool {
    matches!(
        node.r#type.as_str(),
        "STR" | "STRING" | "STRING_LITERAL" | "STRING_LITERAL_CONTENT" | "STRING_CONTENT"
            | "LINE_STR_TEXT"
    )
}

fn quoted_literal_text(node: &Node, behavior: &dyn NormalizedLanguageBehavior) -> String {
    let text = behavior.normalize_source_text(&normalized_text(node));
    if text.starts_with('"') || text.starts_with('\'') {
        text
    } else {
        format!("\"{text}\"")
    }
}

fn owner_name(node: &Node) -> Option<String> {
    child_node(node, 0).map(normalized_text)
}

fn owner_name_from_text(node: &Node) -> Option<String> {
    let text = node.text.as_str();
    ["class ", "module "].into_iter().find_map(|keyword| {
        let index = text.find(keyword)?;
        text[(index + keyword.len())..]
            .split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .find(|part| !part.is_empty())
            .map(str::to_string)
    })
}

fn owner_kind(node: &Node, behavior: &dyn NormalizedLanguageBehavior) -> String {
    let default_kind = if node.r#type == "MODULE" {
        "module"
    } else {
        "class"
    };
    behavior.owner_kind(node, default_kind)
}

fn owner_name_span(
    name: &str,
    node: &Node,
    behavior: &dyn NormalizedLanguageBehavior,
) -> Span {
    if let Some(owner_span) = behavior.owner_name_span(name, node, span(node)) {
        return owner_span;
    }
    if name.is_empty() {
        return span(node);
    }
    for (offset, line) in node.text.lines().enumerate() {
        if let Some(index) = line.find(name) {
            let line_number = node.first_lineno + offset;
            let column = if offset == 0 { node.first_column } else { 0 } + index;
            return [line_number, column, node.last_lineno, node.last_column];
        }
    }
    span(node)
}

fn function_name(node: &Node) -> Option<String> {
    if node.r#type == "DEFS" {
        let receiver = child_node(node, 0).map(normalized_text)?;
        let name = child_symbol(node, 1)?;
        return Some(format!("{receiver}.{name}"));
    }
    child_symbol(node, 0)
}

fn function_name_with_behavior(
    node: &Node,
    behavior: &dyn NormalizedLanguageBehavior,
) -> Option<String> {
    let name = function_name(node);
    match name.as_deref() {
        Some("") | None => behavior.function_name_from_text(&node.text),
        Some(name) if name.contains(':') => name.split_once(':').map(|(_, tail)| tail.to_string()),
        Some(_) => name,
    }
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

fn function_params(node: &Node, behavior: &dyn NormalizedLanguageBehavior) -> Vec<String> {
    let params: Vec<String> = function_scope(node)
        .and_then(scope_args)
        .map(|args| {
            child_nodes(args)
                .into_iter()
                .filter(|child| child.r#type == "LASGN")
                .filter_map(first_string_or_symbol)
                .collect()
        })
        .unwrap_or_default();
    if params.is_empty() {
        function_params_from_signature(&node.text, behavior)
    } else {
        params
    }
}

fn function_params_from_signature(
    source: &str,
    behavior: &dyn NormalizedLanguageBehavior,
) -> Vec<String> {
    let params_source = behavior.parameter_list_source(source);
    if params_source.is_empty() {
        return Vec::new();
    }
    split_parameters(&params_source)
        .into_iter()
        .filter_map(|param| behavior.parameter_name_from_signature(&param))
        .collect()
}

fn split_parameters(source: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut depth = 0usize;
    for ch in source.chars() {
        if matches!(ch, '(' | '[' | '{' | '<') {
            depth += 1;
        } else if matches!(ch, ')' | ']' | '}' | '>') && depth > 0 {
            depth -= 1;
        }

        if ch == ',' && depth == 0 {
            let param = current.trim();
            if !param.is_empty() {
                out.push(param.to_string());
            }
            current.clear();
        } else {
            current.push(ch);
        }
    }
    let param = current.trim();
    if !param.is_empty() {
        out.push(param.to_string());
    }
    out
}

fn predicate_alias(
    node: &Node,
    file: &str,
    owner: &str,
    behavior: &dyn NormalizedLanguageBehavior,
) -> Option<PredicateAlias> {
    let name = function_name_with_behavior(node, behavior)?;
    let body = function_scope(node).and_then(scope_body)?;
    let body = predicate_expression(body, behavior)?;
    let text = predicate_body_text(&normalized_text_with_behavior(body, behavior))?;
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

fn predicate_expression<'a>(
    node: &'a Node,
    behavior: &dyn NormalizedLanguageBehavior,
) -> Option<&'a Node> {
    if node.r#type == "BLOCK" {
        if let Some(single) = single_expression(node) {
            return Some(single);
        }
    }
    if !predicate_container_node(node)
        && predicate_body_text(&normalized_text_with_behavior(node, behavior)).is_some()
    {
        return Some(node);
    }
    if child_nodes(node).is_empty() {
        return Some(node);
    }
    tail_return(node)
}

fn tail_return(node: &Node) -> Option<&Node> {
    if node.r#type == "RETURN" {
        return Some(node);
    }
    if !predicate_container_node(node) {
        return None;
    }
    for child in child_nodes(node).into_iter().rev() {
        if child.r#type == "RETURN" {
            return Some(child);
        }
        if predicate_container_node(child) {
            return tail_return(child);
        }
        return None;
    }
    None
}

fn predicate_container_node(node: &Node) -> bool {
    matches!(
        node.r#type.as_str(),
        "BLOCK" | "SCOPE" | "ROOT" | "RETURN" | "COMPOUND_STATEMENT" | "DECLARATION_LIST"
    )
}

fn predicate_body_text(source: &str) -> Option<String> {
    let text = source
        .strip_prefix("return ")
        .unwrap_or(source)
        .trim_end_matches(';')
        .trim()
        .to_string();
    if text.contains("undefined")
        || text.is_empty()
        || text == "nil"
        || text.len() > 200
        || assignment_like_predicate_body(&text)
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
        || text.contains("??")
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

fn target_name_span(name: &str, node: &Node) -> Span {
    if node.first_lineno == node.last_lineno {
        if let Some(index) = node.text.find(name) {
            return [
                node.first_lineno,
                node.first_column + index,
                node.first_lineno,
                node.first_column + index + name.len(),
            ];
        }
    }
    span(node)
}

fn hidden_assignment_mutation(
    node: &Node,
    field: Option<&str>,
    behavior: &dyn NormalizedLanguageBehavior,
) -> bool {
    if node.text.contains('[') || field == Some("[]") {
        behavior.emit_index_assignment_mutation(node, field)
    } else {
        behavior.emit_attribute_assignment_mutation(node, field)
    }
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
        "ITER" => "ITER",
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
