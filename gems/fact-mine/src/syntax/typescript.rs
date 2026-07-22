// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::effect_from_call_with_lexicon;
use super::javascript;
use super::normalized_behavior::{
    configured_collection_operation, configured_intrinsic_call_complexity,
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedCollectionOperation, NormalizedLanguageBehavior,
    NormalizedNilGuardFact, NormalizedNullableOperation, NormalizedSemanticEffect,
};
use super::CallSite;
use super::{ExternalCallComplexity, StateDeclaration};
use crate::ast::Child;
use crate::ast::{Node, Span};

const TYPESCRIPT_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const TYPESCRIPT_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const TYPESCRIPT_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

// CFG-SPECIFIC START: TypeScript control-flow vocabulary.
const TYPESCRIPT_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &[
        "every", "filter", "find", "flatMap", "forEach", "map", "reduce", "some",
    ],
    ignored_callback_body_sources: &[],
};
// CFG-SPECIFIC END

pub(crate) struct TypeScriptNormalizedBehavior;

impl NormalizedLanguageBehavior for TypeScriptNormalizedBehavior {
    fn nullable_operation(&self, node: &Node) -> Option<NormalizedNullableOperation> {
        (node.r#type == "CALL")
            .then(|| node.children.first().and_then(crate::ast::node))
            .flatten()
            .filter(|receiver| receiver.r#type == "LVAR")
            .map(|receiver| receiver.text.trim().to_string())
            .filter(|subject| !subject.is_empty())
            .map(|subject| NormalizedNullableOperation {
                subject,
                operation_kind: "receiver_member_access",
                nil_behavior: "type_error",
            })
    }

    fn nested_function_is_local_callable(&self, _function: &Node) -> bool {
        true
    }

    fn external_symbol_call_complexity(
        &self,
        symbol: &str,
        message: &str,
    ) -> Option<ExternalCallComplexity> {
        javascript::external_symbol_call_complexity_for("typescript", symbol, message)
    }

    fn external_symbol_metadata(&self, symbol: &str) -> super::ExternalSymbolMetadata {
        javascript::external_symbol_metadata_for("typescript", symbol)
    }

    fn external_symbol_owner(&self, symbol: &str) -> Option<String> {
        javascript::external_symbol_owner(symbol)
    }

    fn owner_supertypes(&self, node: &Node) -> Vec<String> {
        let header = node.text.split('{').next().unwrap_or(&node.text);
        let mut rows = super::normalized_behavior::declared_supertype_clause(
            header,
            "extends",
            &["implements"],
        )
        .map(super::normalized_behavior::split_declared_supertypes)
        .unwrap_or_default();
        if let Some(clause) =
            super::normalized_behavior::declared_supertype_clause(header, "implements", &[])
        {
            rows.extend(super::normalized_behavior::split_declared_supertypes(
                clause,
            ));
        }
        rows
    }

    fn declared_local_type(&self, source: &str, name: &str) -> Option<String> {
        super::normalized_behavior::type_after_local_colon(source, name)
    }

    fn stdlib_language(&self) -> Option<&'static str> {
        Some("typescript")
    }

    // CFG-SPECIFIC START: expose the TypeScript CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &TYPESCRIPT_CFG_PROFILE
    }
    // CFG-SPECIFIC END

    fn self_member_receiver(&self, message: &str) -> String {
        format!("this.{message}")
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        let text = node.text.trim_start();
        if text.starts_with("private ") || text.starts_with("protected ") {
            "private".to_string()
        } else {
            "public".to_string()
        }
    }

    fn function_dispatch_kind_from_node(&self, _name: &str, node: &Node, owner: &str) -> String {
        javascript::function_dispatch_kind_from_node(node, owner)
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        let mut text = param.split('=').next().unwrap_or(param).trim();
        for prefix in ["public ", "private ", "protected ", "readonly "] {
            text = text.strip_prefix(prefix).unwrap_or(text);
        }
        let before_colon = text.split_once(':')?.0.trim().trim_end_matches('?');
        simple_identifier(before_colon).then(|| before_colon.to_string())
    }

    fn parameter_type_from_signature(&self, param: &str) -> Option<String> {
        let declaration = param.split('=').next().unwrap_or(param).trim();
        let (_, type_name) = declaration.split_once(':')?;
        let type_name = type_name.trim();
        (!type_name.is_empty()).then(|| type_name.to_string())
    }

    fn collection_operation(
        &self,
        receiver_type: &crate::type_inference::TypeExpr,
        message: &str,
    ) -> Option<NormalizedCollectionOperation> {
        configured_collection_operation("typescript", receiver_type, message)
    }

    fn intrinsic_call_complexity(
        &self,
        receiver: Option<&str>,
        message: &str,
    ) -> Option<super::normalized_behavior::NormalizedCallComplexity> {
        configured_intrinsic_call_complexity("typescript", receiver, message)
    }

    fn mutating_receiver_message(&self, message: &str) -> bool {
        matches!(
            message,
            "add"
                | "delete"
                | "pop"
                | "push"
                | "reverse"
                | "set"
                | "shift"
                | "sort"
                | "splice"
                | "unshift"
        )
    }

    fn treats_object_literal_binding_as_owner(&self) -> bool {
        true
    }

    fn wrap_branch_predicate(&self, branch: &Node) -> bool {
        let _ = branch;
        true
    }

    fn explicit_self_state_ref(&self, node: &Node, message: &str) -> String {
        let _ = node;
        format!("this.{message}")
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        javascript::property_read_call(node, parts)
    }

    fn state_read_uses_access_span(&self, call: &NormalizedCallProjection) -> bool {
        call.receiver == "console" || call.receiver == "this.sink" || call.receiver == "self"
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver == "self" && call.message == "callback"
    }

    // call_parts defaults every receiver-less call's receiver to "self" (a
    // Ruby-implicit-dispatch convention); TS has no implicit self dispatch,
    // so that default would otherwise read as a phantom field access on the
    // called name.
    fn suppress_method_call_state_read(&self, call: &NormalizedCallProjection) -> bool {
        call.receiver == "self"
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS" || node.r#type == "INTERFACE_DECLARATION").then_some(default_span)
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(
            message,
            subject,
            TYPESCRIPT_NIL_PREDICATES,
            TYPESCRIPT_NON_NIL_PREDICATES,
        )
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, TYPESCRIPT_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &javascript::JAVASCRIPT_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(keyword, "const" | "let" | "var")
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "as" | "break"
                    | "case"
                    | "class"
                    | "continue"
                    | "default"
                    | "else"
                    | "false"
                    | "for"
                    | "function"
                    | "if"
                    | "in"
                    | "null"
                    | "private"
                    | "protected"
                    | "public"
                    | "return"
                    | "this"
                    | "true"
                    | "while"
            )
    }

    fn suppress_predicate_body_text(&self, text: &str) -> bool {
        text.contains("undefined")
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("null") || text.contains("??")
    }

    fn state_declaration_from_node(
        &self,
        node: &Node,
        _owner: &str,
        in_method: bool,
    ) -> Option<StateDeclaration> {
        let has_modifier = node.children.iter().any(|c| match c {
            Child::Node(n) => {
                let text = n.text.trim();
                matches!(
                    text,
                    "public" | "private" | "protected" | "readonly" | "static"
                )
            }
            _ => false,
        });

        // `constructor(private readonly foo: Foo)`: a parameter-property
        // (TypeScript's own version of the identically-shaped Kotlin
        // primary-constructor-property gap already fixed this session)
        // normalizes as REQUIRED_PARAMETER/OPTIONAL_PARAMETER, only when it
        // actually carries an accessibility/readonly modifier (a plain
        // parameter with none is just a parameter, not state). Checked
        // ahead of the in_method branching below: a constructor's own
        // parameters live inside its DEFN subtree, so this walk visits them
        // with in_method already true, even though they are a declaration
        // site, not a use inside the method body.
        let is_parameter_property = has_modifier
            && matches!(
                node.r#type.as_str(),
                "REQUIRED_PARAMETER" | "OPTIONAL_PARAMETER"
            );

        if is_parameter_property {
            // fall through to the shared structured-children extraction below
        } else if in_method {
            if node.r#type != "ATTRASGN" && node.r#type != "IASGN" {
                return None;
            }
            let starts_with_this = node
                .children
                .first()
                .and_then(|c| match c {
                    Child::Node(n) => Some(n.text.trim().starts_with("this.")),
                    _ => None,
                })
                .unwrap_or(false);
            if !has_modifier && !starts_with_this {
                return None;
            }
        } else {
            if node.r#type != "PUBLIC_FIELD_DEFINITION" && node.r#type != "PROPERTY_SIGNATURE" {
                return None;
            }
        }

        // Try structured children first: [name, type?, value?]
        let mut child_nodes: Vec<&Node> = node
            .children
            .iter()
            .filter_map(|c| match c {
                Child::Node(n) => Some(n.as_ref()),
                _ => None,
            })
            .collect();

        // Skip any leading modifiers
        while !child_nodes.is_empty() {
            let text = child_nodes[0].text.trim();
            if matches!(
                text,
                "public"
                    | "private"
                    | "protected"
                    | "readonly"
                    | "static"
                    | "declare"
                    | "override"
                    | "abstract"
                    | "accessor"
            ) {
                child_nodes.remove(0);
            } else {
                break;
            }
        }

        // An initializer collapses `name[: Type] = value` into a single
        // LASGN child carrying the whole thing as one blob (no separate
        // type_annotation sibling survives), so it must be parsed from its
        // own text instead of split across child_nodes.
        if let Some(lasgn) = child_nodes.iter().find(|c| c.r#type == "LASGN") {
            let before_eq = lasgn.text.split('=').next().unwrap_or(&lasgn.text).trim();
            let (raw_name, type_text) = before_eq
                .split_once(':')
                .map(|(n, t)| {
                    (
                        n.trim(),
                        Some(t.trim().to_string()).filter(|t| !t.is_empty()),
                    )
                })
                .unwrap_or((before_eq, None));
            let name = raw_name.strip_prefix("this.").unwrap_or(raw_name);
            if is_simple_name(name) {
                return Some(StateDeclaration {
                    field: name.to_string(),
                    owner: String::new(),
                    r#type: type_text,
                    immutable: false,
                    file: String::new(),
                    line: node.first_lineno,
                    span: span(node),
                });
            }
        }

        if child_nodes.len() >= 2 {
            let raw_name = child_nodes[0].text.trim();
            let name = raw_name.strip_prefix("this.").unwrap_or(raw_name);
            if is_simple_name(name) {
                let mut type_text = child_nodes[1].text.trim().to_string();
                if type_text.starts_with(':') {
                    type_text = type_text[1..].trim().to_string();
                }
                if !type_text.is_empty()
                    && type_text != ":"
                    && !type_text.starts_with('=')
                    && !type_text.starts_with('(')
                {
                    return Some(StateDeclaration {
                        field: name.to_string(),
                        owner: String::new(),
                        r#type: Some(type_text),
                        immutable: false,
                        file: String::new(),
                        line: node.first_lineno,
                        span: span(node),
                    });
                }
            }
        }
        // Fallback: text-based (`name: Type`)
        let text = node.text.trim();
        if let Some((raw_name, rest)) = text.split_once(':') {
            let mut name = raw_name.trim();
            name = name.strip_prefix("this.").unwrap_or(name);
            loop {
                let mut stripped = false;
                for modifier in [
                    "public",
                    "private",
                    "protected",
                    "readonly",
                    "static",
                    "declare",
                    "override",
                    "abstract",
                    "accessor",
                ] {
                    if let Some(rest_name) = name.strip_prefix(modifier) {
                        name = rest_name.trim();
                        stripped = true;
                        break;
                    }
                }
                if !stripped {
                    break;
                }
            }
            if is_simple_name(name) {
                let type_text = rest
                    .split('=')
                    .next()
                    .unwrap_or(rest)
                    .trim()
                    .trim_end_matches(',')
                    .trim_end_matches(';')
                    .to_string();
                if !type_text.is_empty() && type_text != ":" && !type_text.starts_with('(') {
                    return Some(StateDeclaration {
                        field: name.to_string(),
                        owner: String::new(),
                        r#type: Some(type_text),
                        immutable: false,
                        file: String::new(),
                        line: node.first_lineno,
                        span: span(node),
                    });
                }
            }
        }
        None
    }

    fn suppress_state_write(&self, receiver: &str, _field: &str, node: &Node) -> bool {
        receiver == "self" && node.text.contains(".bind(this)") && node.text.contains('=')
    }

    fn format_array_type(&self, elem: &str) -> String {
        format!("{elem}[]")
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("Record<{key}, {val}>")
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("Set<{elem}>")
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty() || type_text == "nil" || type_text == "null" || type_text == "None"
        {
            return type_text.to_string();
        }
        if type_text.contains(" | null") {
            type_text.to_string()
        } else {
            format!("{type_text} | null")
        }
    }

    fn untyped_type(&self) -> String {
        "any".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "any[]".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "Record<any, any>".to_string()
    }
}

static BEHAVIOR: TypeScriptNormalizedBehavior = TypeScriptNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn span(node: &Node) -> Span {
    [
        node.first_lineno,
        node.first_column,
        node.last_lineno,
        node.last_column,
    ]
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn is_simple_name(name: &str) -> bool {
    !name.is_empty()
        && !name.contains(' ')
        && !name.contains('.')
        && !name.contains('[')
        && !name.contains('<')
        && !name.contains('(')
        && name
            .chars()
            .next()
            .map_or(false, |c| c == '_' || c.is_ascii_alphabetic())
        && name
            .chars()
            .all(|ch| ch == '_' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(kind: &str, text: &str) -> Node {
        Node {
            r#type: kind.to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 2,
            last_lineno: 10,
            last_column: 20,
            text: text.to_string(),
        }
    }

    #[test]
    fn test_typescript_behavior_comprehensive() {
        let b = TypeScriptNormalizedBehavior;
        assert_eq!(b.self_member_receiver("Foo"), "this.Foo");
        assert_eq!(
            b.function_visibility("Foo", &node("DEFN", "private void Foo()"), &[]),
            "private"
        );
        assert_eq!(
            b.function_visibility("Foo", &node("DEFN", "protected void Foo()"), &[]),
            "private"
        );
        assert_eq!(
            b.function_visibility("Foo", &node("DEFN", "public void Foo()"), &[]),
            "public"
        );

        assert_eq!(
            b.parameter_name_from_signature("public x: number"),
            Some("x".to_string())
        );
        assert_eq!(
            b.parameter_name_from_signature("readonly value: number = 1"),
            Some("value".to_string())
        );
        assert_eq!(b.parameter_name_from_signature("invalid name"), None);
        assert_eq!(
            b.parameter_type_from_signature("value: number = 1"),
            Some("number".to_string())
        );
        assert_eq!(b.parameter_type_from_signature("value"), None);

        let array = crate::type_inference::TypeExpr::Array(Box::new(
            crate::type_inference::TypeExpr::Primitive("string".to_string()),
        ));
        let hash = crate::type_inference::TypeExpr::Hash {
            key: Box::new(crate::type_inference::TypeExpr::Primitive(
                "string".to_string(),
            )),
            value: Box::new(crate::type_inference::TypeExpr::Primitive(
                "number".to_string(),
            )),
        };
        let set = crate::type_inference::TypeExpr::Set(Box::new(
            crate::type_inference::TypeExpr::Primitive("string".to_string()),
        ));
        let string = crate::type_inference::TypeExpr::Primitive("string".to_string());
        assert_eq!(
            b.collection_operation(&array, "at"),
            Some(NormalizedCollectionOperation::Constant)
        );
        assert_eq!(
            b.collection_operation(&array, "includes"),
            Some(NormalizedCollectionOperation::LinearScan)
        );
        assert_eq!(
            b.collection_operation(&array, "map"),
            Some(NormalizedCollectionOperation::LinearMaterialize)
        );
        assert_eq!(
            b.collection_operation(&array, "sort"),
            Some(NormalizedCollectionOperation::Sort)
        );
        assert_eq!(
            b.collection_operation(&hash, "get"),
            Some(NormalizedCollectionOperation::LinearScan)
        );
        assert_eq!(
            b.collection_operation(&hash, "entries"),
            Some(NormalizedCollectionOperation::LinearMaterialize)
        );
        assert_eq!(
            b.collection_operation(&set, "has"),
            Some(NormalizedCollectionOperation::LinearScan)
        );
        assert_eq!(
            b.collection_operation(&string, "search"),
            Some(NormalizedCollectionOperation::LinearScan)
        );
        assert_eq!(
            b.collection_operation(&string, "split"),
            Some(NormalizedCollectionOperation::LinearMaterialize)
        );
        assert_eq!(
            b.collection_operation(&string, "length"),
            Some(NormalizedCollectionOperation::Constant)
        );
        assert_eq!(b.collection_operation(&array, "unknown"), None);

        assert!(b.wrap_branch_predicate(&node("IF", "")));
        assert_eq!(
            b.explicit_self_state_ref(&node("LVAR", ""), "Foo"),
            "this.Foo"
        );
        assert!(b.property_read_call(
            &node("CALL", "x.y"),
            &NormalizedCallParts {
                receiver: "x".to_string(),
                message: "y".to_string(),
                arguments: Vec::new(),
            }
        ));

        assert!(b.state_read_uses_access_span(&NormalizedCallProjection {
            receiver: "console".to_string(),
            message: "log".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }));

        assert!(b.suppress_state_read_for_call(
            &NormalizedCallProjection {
                receiver: "self".to_string(),
                message: "callback".to_string(),
                arguments: Vec::new(),
                access_span: [1, 2, 3, 4],
                span: [1, 2, 3, 4],
            },
            ""
        ));

        assert!(b
            .owner_name_span("A", &node("CLASS", "class A {}"), [1, 2, 3, 4])
            .is_some());
        assert!(b
            .owner_name_span("A", &node("INTERFACE_DECLARATION", ""), [1, 2, 3, 4])
            .is_some());

        assert!(b.nil_guard_fact("isNull", "x").is_some());

        assert!(b
            .semantic_effect_for_call(&CallSite {
                receiver: "x".to_string(),
                message: "isNull".to_string(),
                file: "".to_string(),
                function: "".to_string(),
                owner: "".to_string(),
                line: 1,
                span: [1, 2, 3, 4],
                conditional: false,
                arguments: Vec::new(),
                control: None,
                safe_navigation: false,
                block: false,
            })
            .is_some());

        assert!(b.local_flow_declaration_keyword("let"));
        assert!(b.local_flow_keyword("let"));
        assert!(b.local_flow_keyword("if"));
        assert!(!b.local_flow_keyword("foo"));

        assert!(b.suppress_predicate_body_text("undefined"));
        assert!(!b.suppress_predicate_body_text("foo"));

        assert!(b.predicate_body_language_signal("null"));
        assert!(!b.predicate_body_language_signal("foo"));

        assert_eq!(b.format_array_type("number"), "number[]");
        assert_eq!(
            b.format_hash_type("string", "number"),
            "Record<string, number>"
        );
        assert_eq!(b.format_set_type("number"), "Set<number>");

        assert_eq!(b.format_nilable_type(""), "");
        assert_eq!(b.format_nilable_type("nil"), "nil");
        assert_eq!(b.format_nilable_type("number | null"), "number | null");
        assert_eq!(b.format_nilable_type("number"), "number | null");

        assert_eq!(b.untyped_type(), "any");
        assert_eq!(b.untyped_array_type(), "any[]");
        assert_eq!(b.untyped_hash_type(), "Record<any, any>");

        // Test state_declaration_from_node
        let mut field_decl = node("PUBLIC_FIELD_DEFINITION", "public readonly x: number = 1");
        field_decl.children = vec![
            Child::String("not_a_node".to_string()), // Cover Child::String filter branch in state_declaration_from_node
            Child::Node(Box::new(node("MODIFIER", "public"))),
            Child::Node(Box::new(node("MODIFIER", "readonly"))),
            Child::Node(Box::new(node("IDENTIFIER", "x"))),
            Child::Node(Box::new(node("TYPE", ": number"))),
        ];
        let decl = b.state_declaration_from_node(&field_decl, "MyClass", false);
        assert!(decl.is_some());
        assert_eq!(decl.as_ref().unwrap().field, "x");
        assert_eq!(decl.as_ref().unwrap().r#type, Some("number".to_string()));

        // Test fallback split text branch in state_declaration_from_node with modifier stripping
        let fallback_decl = node(
            "PUBLIC_FIELD_DEFINITION",
            "public readonly myField: string = 'hello';",
        );
        let fallback_res = b.state_declaration_from_node(&fallback_decl, "MyClass", false);
        assert!(fallback_res.is_some());
        assert_eq!(fallback_res.as_ref().unwrap().field, "myField");
        assert_eq!(
            fallback_res.as_ref().unwrap().r#type,
            Some("string".to_string())
        );

        // Test fallback split text branch with 'this.' prefix stripping
        let fallback_this_decl = node("PUBLIC_FIELD_DEFINITION", "this.myField: string = 'hello';");
        let fallback_this_res =
            b.state_declaration_from_node(&fallback_this_decl, "MyClass", false);
        assert!(fallback_this_res.is_some());
        assert_eq!(fallback_this_res.as_ref().unwrap().field, "myField");
        assert_eq!(
            fallback_this_res.as_ref().unwrap().r#type,
            Some("string".to_string())
        );

        // Test in_method = true with ATTRASGN
        let mut in_method_decl = node("ATTRASGN", "this.field: number = 2");
        let mut lhs_node = node("IDENTIFIER", "this.field");
        lhs_node.text = "this.field".to_string();
        in_method_decl.children = vec![Child::Node(Box::new(lhs_node))];
        let in_method_res = b.state_declaration_from_node(&in_method_decl, "MyClass", true);
        assert!(in_method_res.is_some());
        assert_eq!(in_method_res.as_ref().unwrap().field, "field");
        assert_eq!(
            in_method_res.as_ref().unwrap().r#type,
            Some("number".to_string())
        );

        // Test in_method = true none branch (first child not a Node)
        let mut in_method_decl_none = node("ATTRASGN", "field = 2");
        in_method_decl_none.children = vec![Child::String("not_a_node".to_string())];
        assert!(b
            .state_declaration_from_node(&in_method_decl_none, "MyClass", true)
            .is_none());
    }
}
