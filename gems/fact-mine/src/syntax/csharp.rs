// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    configured_collection_operation, configured_intrinsic_call_complexity,
    configured_semantic_symbol_call_complexity, configured_semantic_symbol_kind,
    configured_semantic_symbol_parametric_cost, eliminable_guard_from_call,
    nil_guard_from_predicates, scip_descriptor_owner, scip_global_parts,
    type_before_parameter_name, NormalizedCallParts, NormalizedCallProjection,
    NormalizedLanguageBehavior, NormalizedNilGuardFact, NormalizedNullableOperation,
    NormalizedSemanticEffect,
};
use super::{CallSite, ExternalCallComplexity, ExternalSymbolMetadata, StateDeclaration};
use crate::ast::{Node, Span};
use crate::type_inference::languages::nominal::{self, NominalTypeSyntax};
use crate::type_inference::TypeExpr;

const CSHARP_NOMINAL_TYPE_SYNTAX: NominalTypeSyntax = NominalTypeSyntax {
    strip_prefixes: &["readonly "],
    trim_prefix_chars: &[],
    trim_suffix_chars: &[],
    array_names: &["List", "ArrayList", "Vector"],
    hash_names: &["Dictionary", "HashMap"],
    set_names: &["HashSet"],
    string_names: &["string", "String"],
    bare_array_names: &[],
    suffix_array: true,
    bracket_array: false,
};

pub(crate) fn parse_declared_type(source: &str) -> TypeExpr {
    nominal::parse(source, &CSHARP_NOMINAL_TYPE_SYNTAX)
}

/// Everything before a field/property declarator's own `=` initializer (if
/// any) - never a comparison/lambda-arrow/compound-assignment operator
/// that merely contains `=`, since those can appear inside a declared
/// generic type's default or an expression-bodied member and are not the
/// declarator's own initializer boundary.
fn declarator_before_initializer(text: &str) -> &str {
    let bytes = text.as_bytes();
    for (index, &byte) in bytes.iter().enumerate() {
        if byte != b'=' {
            continue;
        }
        let previous = index.checked_sub(1).and_then(|i| bytes.get(i)).copied();
        let next = bytes.get(index + 1).copied();
        if matches!(
            previous,
            Some(b'=' | b'!' | b'<' | b'>' | b'+' | b'-' | b'*' | b'/')
        ) || matches!(next, Some(b'=' | b'>'))
        {
            continue;
        }
        return &text[..index];
    }
    text
}

fn scip_dotnet_parts(symbol: &str) -> Option<(&str, &str)> {
    let (package, _version, descriptor) = scip_global_parts(symbol, "scip-dotnet", "nuget")?;
    Some((package, descriptor))
}

fn dotnet_framework_package(package: &str) -> bool {
    package == "Microsoft.CSharp"
        || package == "Microsoft.VisualBasic.Core"
        || package.starts_with("System.")
}

fn descriptor_owner(descriptor: &str) -> Option<String> {
    scip_descriptor_owner(descriptor).map(|owner| {
        owner
            .trim_end_matches("Attribute")
            .trim_matches('`')
            .to_string()
    })
}

pub(crate) fn external_symbol_call_complexity(
    symbol: &str,
    message: &str,
) -> Option<ExternalCallComplexity> {
    let (package, descriptor) = scip_dotnet_parts(symbol)?;
    if !dotnet_framework_package(package)
        || configured_semantic_symbol_parametric_cost("csharp", descriptor).is_some()
    {
        return None;
    }
    let owner = descriptor_owner(descriptor);
    let complexity = configured_semantic_symbol_call_complexity("csharp", descriptor)
        .or_else(|| {
            owner.as_deref().and_then(|owner| {
                configured_intrinsic_call_complexity("csharp", Some(owner), message)
            })
        })
        .or_else(|| {
            owner.as_deref().and_then(|owner| {
                CSharpNormalizedBehavior
                    .call_complexity(&TypeExpr::Primitive(owner.to_string()), message)
            })
        })?;
    Some(ExternalCallComplexity {
        time: complexity.time,
        space: complexity.space,
        provenance: "csharp_scip_symbol_registry",
        bound_quality: "upper_bound_exact_target",
        candidates: Vec::new(),
        assumption: None,
    })
}

pub(crate) fn external_symbol_metadata(symbol: &str) -> ExternalSymbolMetadata {
    let Some((package, descriptor)) = scip_dotnet_parts(symbol) else {
        return ExternalSymbolMetadata {
            scope: "dynamic",
            missing_cost_kind: "callback_or_function_value_origin_unknown".to_string(),
            parametric_cost: None,
        };
    };
    if dotnet_framework_package(package) {
        ExternalSymbolMetadata {
            scope: "stdlib",
            missing_cost_kind: configured_semantic_symbol_kind("csharp", descriptor)
                .unwrap_or_else(|| "stdlib_cost_model_missing".to_string()),
            parametric_cost: configured_semantic_symbol_parametric_cost("csharp", descriptor),
        }
    } else {
        ExternalSymbolMetadata {
            scope: "dependency",
            missing_cost_kind: "dependency_cost_model_missing".to_string(),
            parametric_cost: None,
        }
    }
}

pub(crate) fn external_symbol_owner(symbol: &str) -> Option<String> {
    let (_package, descriptor) = scip_dotnet_parts(symbol)?;
    descriptor_owner(descriptor)
}

const CSHARP_CONTEXT_PAIRS: &[(&str, &[&str])] = &[
    ("DateTime", &["Now", "UtcNow", "Today"]),
    ("Guid", &["NewGuid"]),
    ("Random", &["Next", "NextDouble"]),
];

const CSHARP_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "Invoke",
        "GetMethod",
        "GetProperty",
        "GetField",
        "Activator",
        "CreateInstance",
    ],
    meta_mids: &["Invoke", "GetType", "Reflection", "Emit", "DynamicMethod"],
    method_obj_mids: &["method"],
    io_consts: &[
        "Console",
        "File",
        "Directory",
        "Path",
        "Process",
        "Socket",
        "HttpClient",
        "Environment",
    ],
    io_bare: &["print", "println", "printf", "puts", "panic", "throw"],
    context_pairs: CSHARP_CONTEXT_PAIRS,
    callback_set: &[
        "transaction",
        "synchronize",
        "lock",
        "with_lock",
        "unlock",
        "mutex",
        "atomic",
        "subscribe",
        "callback",
        "hook",
        "Lock",
        "Monitor",
        "Enter",
        "Exit",
        "Wait",
        "Pulse",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const CSHARP_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const CSHARP_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const CSHARP_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

// CFG-SPECIFIC START: C# control-flow vocabulary.
const CSHARP_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &["Aggregate", "All", "Any", "ForEach", "Select", "Where"],
    ignored_callback_body_sources: &[],
};
// CFG-SPECIFIC END

pub(crate) struct CSharpNormalizedBehavior;

impl NormalizedLanguageBehavior for CSharpNormalizedBehavior {
    fn nested_function_is_local_callable(&self, _function: &Node) -> bool {
        true
    }

    fn declared_callable_cost(&self, declared_type: &str) -> Option<String> {
        let nominal = declared_type
            .trim()
            .trim_start_matches("readonly ")
            .trim_start_matches("static ")
            .trim_end_matches('?')
            .rsplit('.')
            .next()
            .unwrap_or(declared_type);
        (nominal == "Action"
            || nominal.starts_with("Action<")
            || nominal.starts_with("Func<"))
        .then(|| "callback_once".to_string())
        .or_else(|| {
            super::normalized_behavior::configured_callable_type_cost("csharp", declared_type)
        })
    }

    // C-family indexers render a local as `Type name` - the type leads.
    fn parse_variable_declaration(&self, text: &str) -> Option<String> {
        let text = text.trim().trim_end_matches(';').trim();
        let (declared, _name) = text.rsplit_once(char::is_whitespace)?;
        let declared = declared.trim();
        (!declared.is_empty() && !declared.contains('=')).then(|| declared.to_string())
    }

    // C# declares `Ret name(T a)`, not `name(a: T) -> Ret`.
    fn parse_signature(
        &self,
        signature: &str,
    ) -> super::normalized_behavior::NormalizedSignature {
        super::normalized_behavior::parse_c_family_declarator(signature)
    }

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
                nil_behavior: "null_reference_exception",
            })
    }

    fn external_symbol_call_complexity(
        &self,
        symbol: &str,
        message: &str,
    ) -> Option<ExternalCallComplexity> {
        external_symbol_call_complexity(symbol, message)
    }

    fn external_symbol_metadata(&self, symbol: &str) -> ExternalSymbolMetadata {
        external_symbol_metadata(symbol)
    }

    fn external_symbol_owner(&self, symbol: &str) -> Option<String> {
        external_symbol_owner(symbol)
    }

    fn scip_noncall_access_is_callable(&self, symbol: &str) -> bool {
        scip_dotnet_parts(symbol)
            .is_some_and(|(_, descriptor)| descriptor.ends_with('.') && !descriptor.ends_with(")."))
    }

    fn owner_supertypes(&self, node: &Node) -> Vec<String> {
        let header = node.text.split('{').next().unwrap_or(&node.text);
        let before_constraints = header.split(" where ").next().unwrap_or(header);
        before_constraints
            .split_once(" : ")
            .map(|(_, clause)| super::normalized_behavior::split_declared_supertypes(clause))
            .unwrap_or_default()
    }

    fn declared_local_type(&self, source: &str, name: &str) -> Option<String> {
        super::normalized_behavior::type_before_local_name(source, name)
    }

    fn stdlib_language(&self) -> Option<&'static str> {
        Some("csharp")
    }

    // CFG-SPECIFIC START: expose the C# CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &CSHARP_CFG_PROFILE
    }
    // CFG-SPECIFIC END

    fn self_member_receiver(&self, message: &str) -> String {
        message.to_string()
    }

    fn explicit_self_state_ref(&self, _node: &Node, message: &str) -> String {
        format!("this.{message}")
    }

    #[allow(clippy::never_loop)] // The nested AST walk may emit multiple writes despite sparse mock-node shapes.
    fn initializer_writes(
        &self,
        node: &Node,
        _source_text: &str,
        span: Span,
    ) -> Vec<crate::syntax::normalized_behavior::NormalizedStateWrite> {
        let mut writes = Vec::new();
        if let Some(field) = interlocked_ref_argument_field(node) {
            writes.push(crate::syntax::normalized_behavior::NormalizedStateWrite {
                receiver: "self".to_string(),
                field,
                span,
            });
        }
        if node.r#type == "OBJECT_CREATION_EXPRESSION" {
            let mut type_name = ".literal".to_string();
            for child in &node.children {
                if let crate::ast::Child::Node(child) = child {
                    if child.r#type == "IDENTIFIER"
                        || child.r#type == "TYPE_IDENTIFIER"
                        || child.r#type == "LVAR"
                    {
                        type_name = child.text.clone();
                    }
                    if child.r#type == "INITIALIZER_EXPRESSION" {
                        for grand_child in &child.children {
                            if let crate::ast::Child::Node(grand_child) = grand_child {
                                if grand_child.r#type == "LASGN"
                                    || grand_child.r#type == "ASSIGNMENT_EXPRESSION"
                                    || grand_child.r#type == "ASSIGNMENT"
                                {
                                    for key in &grand_child.children {
                                        if let crate::ast::Child::String(key_text) = key {
                                            writes.push(crate::syntax::normalized_behavior::NormalizedStateWrite {
                                                receiver: type_name.clone(),
                                                field: key_text.clone(),
                                                span,
                                            });
                                        } else if let crate::ast::Child::Node(key_node) = key {
                                            writes.push(crate::syntax::normalized_behavior::NormalizedStateWrite {
                                                receiver: type_name.clone(),
                                                field: key_node.text.clone(),
                                                span,
                                            });
                                        }
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        writes
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        let header = node.text.split('(').next().unwrap_or("");
        let tokens: Vec<&str> = header.split_whitespace().take(8).collect();
        if tokens.contains(&"internal") {
            return "internal".to_string();
        }
        for token in &tokens {
            match *token {
                "public" => return "public".to_string(),
                "protected" => return "protected".to_string(),
                "private" => return "private".to_string(),
                _ => {}
            }
        }
        "private".to_string()
    }

    fn parameter_type_from_signature(&self, parameter: &str) -> Option<String> {
        type_before_parameter_name(parameter)
    }

    fn collection_operation(
        &self,
        receiver_type: &crate::type_inference::TypeExpr,
        message: &str,
    ) -> Option<super::normalized_behavior::NormalizedCollectionOperation> {
        configured_collection_operation("csharp", receiver_type, message)
    }

    fn mutating_receiver_message(&self, message: &str) -> bool {
        matches!(message, "Add" | "Clear" | "Remove" | "Reverse" | "Sort")
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        node.r#type != "VCALL" && parts.arguments.is_empty() && !node.text.contains('(')
    }

    fn state_read_uses_access_span(&self, _call: &NormalizedCallProjection) -> bool {
        true
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver == "self" && !call.arguments.is_empty()
    }

    fn implicit_owner_fields(&self) -> bool {
        true
    }

    fn field_name_from_declaration(&self, node: &Node) -> Option<String> {
        if node.r#type != "FIELD_DECLARATION" && node.r#type != "PROPERTY_DECLARATION" {
            return None;
        }
        // A field with an initializer that contains no literal `{` at all
        // (`static readonly Lazy<T> _x = new Lazy<T>(..., Mode.Value);`)
        // was not truncated by the existing brace-split, so the "last
        // identifier" grab reached all the way into the initializer
        // expression and returned its trailing token instead of the
        // field's own name. Truncate at the declarator's own `=` first -
        // an initializer is never part of the name/type being declared.
        let decl_part = declarator_before_initializer(&node.text)
            .split('{')
            .next()
            .unwrap_or(&node.text);
        decl_part
            .trim_end_matches(';')
            .split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .rfind(|part| !part.is_empty())
            .map(str::to_string)
    }

    fn state_declaration_from_function(
        &self,
        node: &Node,
        owner: &str,
    ) -> Option<StateDeclaration> {
        // C# properties are normalized as functions so their getter body is
        // analyzable. An auto-property also declares a real storage slot.
        // Limit this to semicolon accessors; a computed property with a
        // custom getter is a read-only function, not independent storage.
        let source = node.text.trim();
        let body_start = source.find('{')?;
        let body = &source[body_start..];
        if !body.contains("get;") && !body.contains("set;") && !body.contains("init;") {
            return None;
        }

        let mut parts = source[..body_start]
            .split_whitespace()
            .filter(|part| {
                !matches!(
                    *part,
                    "public"
                        | "private"
                        | "protected"
                        | "internal"
                        | "static"
                        | "virtual"
                        | "override"
                        | "sealed"
                        | "abstract"
                        | "required"
                )
            })
            .collect::<Vec<_>>();
        let field = parts.pop()?.to_string();
        let r#type = parts.join(" ");
        (!r#type.is_empty()).then(|| StateDeclaration {
            field,
            owner: owner.to_string(),
            r#type: Some(r#type),
            immutable: false,
            file: String::new(),
            line: 0,
            span: [0, 0, 0, 0],
        })
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        false
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(
            message,
            subject,
            CSHARP_NIL_PREDICATES,
            CSHARP_NON_NIL_PREDICATES,
        )
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "throw" | "Exit")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, CSHARP_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &CSHARP_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(
            keyword,
            "bool"
                | "boolean"
                | "char"
                | "double"
                | "float"
                | "int"
                | "long"
                | "short"
                | "string"
                | "String"
                | "var"
                | "void"
        )
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "as" | "break"
                    | "case"
                    | "class"
                    | "const"
                    | "continue"
                    | "default"
                    | "else"
                    | "false"
                    | "for"
                    | "if"
                    | "in"
                    | "private"
                    | "protected"
                    | "public"
                    | "return"
                    | "static"
                    | "this"
                    | "true"
                    | "while"
            )
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("null")
    }
    fn format_array_type(&self, elem: &str) -> String {
        format!("List<{}>", elem)
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("Dictionary<{}, {}>", key, val)
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("HashSet<{}>", elem)
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty()
            || type_text == "nil"
            || type_text == "null"
            || type_text.ends_with('?')
        {
            type_text.to_string()
        } else {
            format!("{}?", type_text)
        }
    }

    fn untyped_type(&self) -> String {
        "object".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "List<object>".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "Dictionary<string, object>".to_string()
    }
}

// Interlocked.Increment/Decrement take their operand by `ref`, mutating the
// caller's variable directly - unlike an ordinary call argument, this is a
// write to whatever field is passed, not a read.
fn interlocked_ref_argument_field(node: &Node) -> Option<String> {
    if node.r#type != "CALL" {
        return None;
    }
    let method = node.children.iter().find_map(|c| match c {
        crate::ast::Child::Symbol(s) => Some(s.as_str()),
        _ => None,
    })?;
    if !matches!(method, "Increment" | "Decrement") {
        return None;
    }
    let receiver_matches = node.children.iter().any(|c| match c {
        crate::ast::Child::Node(n) if n.r#type == "CALL" || n.r#type == "LVAR" => {
            n.text == "Interlocked" || n.text.ends_with(".Interlocked")
        }
        _ => false,
    });
    if !receiver_matches {
        return None;
    }
    let argument = node.children.iter().find_map(|c| match c {
        crate::ast::Child::Node(n) if n.r#type == "LIST" => {
            n.children.iter().find_map(|a| match a {
                crate::ast::Child::Node(a) if a.r#type == "ARGUMENT" => Some(a.text.trim()),
                _ => None,
            })
        }
        _ => None,
    })?;
    let reference = argument
        .strip_prefix("ref ")
        .or_else(|| argument.strip_prefix("out "))?
        .trim();
    let field = reference.strip_prefix("this.").unwrap_or(reference);
    field
        .starts_with('_')
        .then_some(field)
        .filter(|field| field.len() > 1)
        .map(str::to_string)
}

static BEHAVIOR: CSharpNormalizedBehavior = CSharpNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
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
    fn test_csharp_behavior_comprehensive() {
        let b = CSharpNormalizedBehavior;
        assert_eq!(b.self_member_receiver("Foo"), "Foo");
        assert_eq!(
            b.explicit_self_state_ref(&node("LVAR", "x"), "Foo"),
            "this.Foo"
        );
        assert!(b
            .initializer_writes(&node("LVAR", "x"), "", [1, 2, 3, 4])
            .is_empty());

        // Test initializer_writes with nested children representing OBJECT_CREATION_EXPRESSION
        let mut child1 = node("IDENTIFIER", "MyClass");
        child1.text = "MyClass".to_string();
        let mut key_node = node("IDENTIFIER", "MyField");
        key_node.text = "MyField".to_string();
        let grand_child1 = Node {
            r#type: "ASSIGNMENT".to_string(),
            children: vec![crate::ast::Child::String("MyStringField".to_string())],
            first_lineno: 10,
            first_column: 2,
            last_lineno: 10,
            last_column: 20,
            text: "MyStringField = 1".to_string(),
        };
        let grand_child2 = Node {
            r#type: "ASSIGNMENT".to_string(),
            children: vec![crate::ast::Child::Node(Box::new(key_node))],
            first_lineno: 10,
            first_column: 2,
            last_lineno: 10,
            last_column: 20,
            text: "MyField = 1".to_string(),
        };
        let init_expr = Node {
            r#type: "INITIALIZER_EXPRESSION".to_string(),
            children: vec![
                crate::ast::Child::Node(Box::new(grand_child1)),
                crate::ast::Child::Node(Box::new(grand_child2)),
            ],
            first_lineno: 10,
            first_column: 2,
            last_lineno: 10,
            last_column: 20,
            text: "{ MyStringField = 1, MyField = 1 }".to_string(),
        };
        let new_expr = Node {
            r#type: "OBJECT_CREATION_EXPRESSION".to_string(),
            children: vec![
                crate::ast::Child::Node(Box::new(child1)),
                crate::ast::Child::Node(Box::new(init_expr)),
            ],
            first_lineno: 10,
            first_column: 2,
            last_lineno: 10,
            last_column: 20,
            text: "new MyClass { MyField = 1 }".to_string(),
        };
        let writes = b.initializer_writes(&new_expr, "", [10, 2, 10, 20]);
        assert_eq!(writes.len(), 2);
        assert_eq!(writes[0].receiver, "MyClass");
        assert_eq!(writes[0].field, "MyStringField");
        assert_eq!(writes[1].receiver, "MyClass");
        assert_eq!(writes[1].field, "MyField");

        assert_eq!(
            b.function_visibility("Foo", &node("DEFN", "public void Foo()"), &[]),
            "public"
        );
        assert_eq!(
            b.function_visibility("Foo", &node("DEFN", "protected void Foo()"), &[]),
            "protected"
        );
        assert_eq!(
            b.function_visibility("Foo", &node("DEFN", "void Foo()"), &[]),
            "private"
        );
        assert_eq!(
            b.function_visibility("Foo", &node("DEFN", "internal void Foo()"), &[]),
            "internal"
        );
        assert_eq!(
            b.function_visibility("Foo", &node("DEFN", "protected internal void Foo()"), &[]),
            "internal"
        );

        assert!(b.property_read_call(
            &node("CALL", "x.Foo"),
            &NormalizedCallParts {
                receiver: "x".to_string(),
                message: "Foo".to_string(),
                arguments: Vec::new(),
            }
        ));
        assert!(!b.property_read_call(
            &node("VCALL", "Foo"),
            &NormalizedCallParts {
                receiver: "".to_string(),
                message: "Foo".to_string(),
                arguments: Vec::new(),
            }
        ));

        assert!(b.state_read_uses_access_span(&NormalizedCallProjection {
            receiver: "x".to_string(),
            message: "Foo".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }));

        assert!(b.suppress_state_read_for_call(
            &NormalizedCallProjection {
                receiver: "self".to_string(),
                message: "Foo".to_string(),
                arguments: vec!["a".to_string()],
                access_span: [1, 2, 3, 4],
                span: [1, 2, 3, 4],
            },
            ""
        ));

        assert!(b.implicit_owner_fields());

        let field_node = node("FIELD_DECLARATION", "private int _myField;");
        assert_eq!(
            b.field_name_from_declaration(&field_node),
            Some("_myField".to_string())
        );
        assert_eq!(b.field_name_from_declaration(&node("LVAR", "x")), None);
        let property = b
            .state_declaration_from_function(
                &node("DEFN", "public string Name { get; set; }"),
                "Worker",
            )
            .expect("auto-property declaration");
        assert_eq!(property.field, "Name");
        assert_eq!(property.r#type.as_deref(), Some("string"));
        assert!(b
            .state_declaration_from_function(
                &node("DEFN", "public string Name { get { return _name; } }"),
                "Worker",
            )
            .is_none());

        assert!(!b.wrap_branch_predicate(&node("IF", "if (a)")));
        assert!(b
            .owner_name_span("A", &node("CLASS", "class A"), [1, 2, 3, 4])
            .is_some());

        assert!(b.nil_guard_fact("isNull", "x").is_some());

        assert!(b.terminating_call_message("throw"));
        assert!(b.terminating_call_message("Exit"));
        assert!(!b.terminating_call_message("Foo"));

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

        assert!(b.local_flow_declaration_keyword("int"));
        assert!(b.local_flow_keyword("int"));
        assert!(b.local_flow_keyword("if"));
        assert!(!b.local_flow_keyword("foo"));

        assert!(b.predicate_body_language_signal("null"));
        assert!(!b.predicate_body_language_signal("foo"));

        assert_eq!(b.format_array_type("int"), "List<int>");
        assert_eq!(
            b.format_hash_type("string", "int"),
            "Dictionary<string, int>"
        );
        assert_eq!(b.format_set_type("int"), "HashSet<int>");

        assert_eq!(b.format_nilable_type(""), "");
        assert_eq!(b.format_nilable_type("null"), "null");
        assert_eq!(b.format_nilable_type("int?"), "int?");
        assert_eq!(b.format_nilable_type("int"), "int?");

        assert_eq!(b.untyped_type(), "object");
        assert_eq!(b.untyped_array_type(), "List<object>");
        assert_eq!(b.untyped_hash_type(), "Dictionary<string, object>");
    }

    #[test]
    fn scip_dotnet_symbols_use_reviewed_exact_and_parametric_costs() {
        let symbol = |descriptor: &str| {
            format!("scip-dotnet nuget System.Runtime 10.0.0.0 {descriptor}")
        };
        for (descriptor, message, expected) in [
            ("IO/TextWriter#Write(+1).", "Write", "O(1)"),
            ("IO/TextWriter#Write(+11).", "Write", "O(N)"),
            ("System/Span#Slice(+1).", "Slice", "O(1)"),
            (
                "Reflection/MethodBase#GetParameters().",
                "GetParameters",
                "O(N)",
            ),
            ("Collections/Hashtable#Clear().", "Clear", "O(N)"),
            ("System/Array#GetLength().", "GetLength", "O(1)"),
            ("System/Array#GetValue(+3).", "GetValue", "O(1)"),
        ] {
            let cost = external_symbol_call_complexity(&symbol(descriptor), message)
                .unwrap_or_else(|| panic!("missing exact cost for {descriptor}"));
            assert_eq!(cost.time, expected, "descriptor={descriptor}");
            assert_eq!(cost.provenance, "csharp_scip_symbol_registry");
        }

        let callback =
            "scip-dotnet nuget System.Linq 10.0.0.0 Linq/Enumerable#Where().";
        assert!(external_symbol_call_complexity(callback, "Where").is_none());
        let metadata = external_symbol_metadata(callback);
        assert_eq!(metadata.scope, "stdlib");
        assert_eq!(
            metadata.parametric_cost.as_deref(),
            Some("callback_linear")
        );

        let action = external_symbol_metadata(
            "scip-dotnet nuget System.Runtime 10.0.0.0 System/Action#Invoke().",
        );
        assert_eq!(action.parametric_cost.as_deref(), Some("callback_once"));
        let virtual_object = external_symbol_metadata(
            "scip-dotnet nuget System.Runtime 10.0.0.0 System/Object#Equals(+1).",
        );
        assert_eq!(
            virtual_object.parametric_cost.as_deref(),
            Some("callback_once")
        );
        assert_eq!(
            CSharpNormalizedBehavior
                .intrinsic_call_complexity(None, "nameof")
                .map(|cost| cost.time),
            Some("O(1)")
        );
    }
}
