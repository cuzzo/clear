#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::{Document, Language};
    use serde_json::json;

    fn dummy_doc() -> Document {
        serde_json::from_str(r#"{"file":"test.rb","language":"ruby"}"#).unwrap()
    }

    #[test]
    fn test_unquote_edge_cases() {
        assert_eq!(unquote("\"a\""), "a");
        assert_eq!(unquote("'b'"), "b");
        assert_eq!(unquote("\""), "\"");
        assert_eq!(unquote("'"), "'");
        assert_eq!(unquote(""), "");
    }

    #[test]
    fn test_extract_call_args_edge_cases() {
        assert_eq!(extract_call_args("foo((bar))", "foo"), Some("(bar)".to_string()));
        assert_eq!(extract_call_args("foo(bar", "foo"), None);
    }

    #[test]
    fn test_static_sorbet_type_noreturn() {
        assert_eq!(static_sorbet_type(&["T.noreturn".to_string()]), "T.noreturn");
        assert_eq!(static_sorbet_type(&["T.noreturn".to_string(), "NilClass".to_string()]), "NilClass");
        assert_eq!(static_sorbet_type(&["T.noreturn".to_string(), "Integer".to_string()]), "Integer");
        assert_eq!(extract_return_type("sig { returns(Integer) }"), Some("Integer".to_string()));
        assert_eq!(static_sorbet_type(&["T.nilable(Integer)".to_string()]), "T.nilable(Integer)");
    }

    #[test]
    fn test_merge_types_full() {
        assert_eq!(merge_types("Int", "Int"), "Int");
        assert_eq!(merge_types("T.untyped", "Int"), "Int");
        assert_eq!(merge_types("Int", "T.untyped"), "Int");
        assert_eq!(merge_types("NilClass", "T.nilable(Int)"), "T.nilable(Int)");
        assert_eq!(merge_types("NilClass", "Int"), "T.nilable(Int)");
        assert_eq!(merge_types("T.nilable(Int)", "NilClass"), "T.nilable(Int)");
        assert_eq!(merge_types("Int", "NilClass"), "T.nilable(Int)");
        assert_eq!(merge_types("T.nilable(Int)", "Int"), "T.nilable(Int)");
        assert_eq!(merge_types("Int", "T.nilable(Int)"), "T.nilable(Int)");
        assert_eq!(merge_types("Int", "String"), "T.untyped");
    }

    #[test]
    fn test_node_symbol_vcall_fcall() {
        let node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "VCALL",
            "children": [],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "my_vcall_method(args)"
        }"#).unwrap();
        assert_eq!(node_symbol(&node), Some("my_vcall_method".to_string()));

        let node2: crate::ast::Node = serde_json::from_str(r#"{
            "type": "FCALL",
            "children": [],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "my_fcall_method"
        }"#).unwrap();
        assert_eq!(node_symbol(&node2), Some("my_fcall_method".to_string()));
    }

    #[test]
    fn test_match_call_fallbacks() {
        let node1: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": ["Nil"],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "foo.bar"
        }"#).unwrap();
        assert!(match_call(&node1).is_none());

        let node2: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "SELF",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 10,
                    "text": "self"
                }},
                "Nil"
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "self.nil"
        }"#).unwrap();
        assert!(match_call(&node2).is_none());
    }

    #[test]
    fn test_compare_literal_values() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec![],
            param_types: BTreeMap::new(),
            local_types: BTreeMap::new(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        let l_int = LiteralStaticValue::Integer(10);
        let r_int = LiteralStaticValue::Integer(5);
        let r_int_same = LiteralStaticValue::Integer(10);

        assert_eq!(visitor.compare_literal_values(&l_int, &r_int, "!="), Some(true));
        assert_eq!(visitor.compare_literal_values(&l_int, &r_int_same, "!="), Some(false));
        assert_eq!(visitor.compare_literal_values(&l_int, &r_int, ">"), Some(true));
        assert_eq!(visitor.compare_literal_values(&l_int, &r_int, ">="), Some(true));
        assert_eq!(visitor.compare_literal_values(&l_int, &r_int, "<"), Some(false));
        assert_eq!(visitor.compare_literal_values(&l_int, &r_int, "<="), Some(false));
        assert_eq!(visitor.compare_literal_values(&l_int, &r_int, "invalid_op"), None);

        // literal_values_equal other branches
        assert!(visitor.literal_values_equal(&LiteralStaticValue::String("a".to_string()), &LiteralStaticValue::String("a".to_string())));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::String("a".to_string()), &LiteralStaticValue::String("b".to_string())));
        assert!(visitor.literal_values_equal(&LiteralStaticValue::Symbol("a".to_string()), &LiteralStaticValue::Symbol("a".to_string())));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::Symbol("a".to_string()), &LiteralStaticValue::Symbol("b".to_string())));
        assert!(visitor.literal_values_equal(&LiteralStaticValue::Float("1.5".to_string()), &LiteralStaticValue::Float("1.5".to_string())));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::Float("1.5".to_string()), &LiteralStaticValue::Float("2.5".to_string())));
        assert!(visitor.literal_values_equal(&LiteralStaticValue::Bool(true), &LiteralStaticValue::Bool(true)));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::Bool(true), &LiteralStaticValue::Bool(false)));
        assert!(visitor.literal_values_equal(&LiteralStaticValue::Nil, &LiteralStaticValue::Nil));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::Nil, &LiteralStaticValue::Bool(false)));
    }

    #[test]
    fn test_visitor_edge_cases() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();

        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec!["MyClass".to_string()],
            current_method: Some("foo".to_string()),
            current_method_kind: "instance".to_string(),
            current_method_line: 1,
            current_method_end_line: 10,
            current_params: vec!["param1".to_string()],
            param_types: [("param1".to_string(), "Integer".to_string())].into_iter().collect(),
            local_types: [("local1".to_string(), "String".to_string())].into_iter().collect(),
            in_conditional: false,
            ivar_tlet_types: [
                (("MyClass".to_string(), "ivar1".to_string()), "Float".to_string()),
                (("MyClass".to_string(), "ivar_empty".to_string()), "".to_string()),
            ].into_iter().collect(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        assert!(visitor.known_disjoint_guard_classes("Integer", "String"));
        assert!(!visitor.known_disjoint_guard_classes("TrueClass", "T::Boolean"));
        assert!(!visitor.known_disjoint_guard_classes("T::Boolean", "TrueClass"));
        assert!(visitor.known_disjoint_guard_classes("T::Boolean", "Integer"));
        assert!(visitor.known_disjoint_guard_classes("Integer", "T::Boolean"));

        assert_eq!(visitor.ivar_expression_type("ivar1"), Some("Float".to_string()));
        assert_eq!(visitor.ivar_expression_type("ivar_empty"), None);
        assert_eq!(visitor.ivar_expression_type("ivar_missing"), None);

        assert_eq!(visitor.literal_numeric_value(&LiteralStaticValue::Integer(42)), Some(42.0));
        assert_eq!(visitor.literal_numeric_value(&LiteralStaticValue::Float("3.14".to_string())), Some(3.14));
        assert_eq!(visitor.literal_numeric_value(&LiteralStaticValue::Nil), None);

        assert!(visitor.literal_values_equal(&LiteralStaticValue::Integer(1), &LiteralStaticValue::Integer(1)));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::Integer(1), &LiteralStaticValue::Integer(2)));
        assert!(visitor.literal_values_equal(&LiteralStaticValue::Nil, &LiteralStaticValue::Nil));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::Nil, &LiteralStaticValue::Integer(1)));

        let self_node = crate::ast::Node {
            r#type: "SELF".to_string(),
            children: vec![],
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 4,
            text: "self".to_string(),
        };
        assert!(visitor.provably_non_nil(&self_node));
    }

    #[test]
    fn test_literal_static_value() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec![],
            param_types: BTreeMap::new(),
            local_types: BTreeMap::new(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        let sym_node = crate::ast::Node {
            r#type: "SYMBOL".to_string(),
            children: vec![],
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: ":my_sym".to_string(),
        };
        assert_eq!(visitor.literal_static_value(&sym_node), LiteralStaticValue::Symbol("my_sym".to_string()));

        let lit_sym = crate::ast::Node {
            r#type: "LIT".to_string(),
            children: vec![],
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: ":lit_sym".to_string(),
        };
        assert_eq!(visitor.literal_static_value(&lit_sym), LiteralStaticValue::Symbol("lit_sym".to_string()));

        let lit_int = crate::ast::Node {
            r#type: "LIT".to_string(),
            children: vec![],
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "123".to_string(),
        };
        assert_eq!(visitor.literal_static_value(&lit_int), LiteralStaticValue::Integer(123));

        let lit_float = crate::ast::Node {
            r#type: "LIT".to_string(),
            children: vec![],
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "12.34".to_string(),
        };
        assert_eq!(visitor.literal_static_value(&lit_float), LiteralStaticValue::Float("12.34".to_string()));

        let lit_unknown = crate::ast::Node {
            r#type: "LIT".to_string(),
            children: vec![],
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "unknown_lit".to_string(),
        };
        assert_eq!(visitor.literal_static_value(&lit_unknown), LiteralStaticValue::Unknown);
    }

    #[test]
    fn test_predicate_origins() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec!["param_x".to_string()],
            param_types: BTreeMap::new(),
            local_types: BTreeMap::new(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        let node_param = crate::ast::Node {
            r#type: "LVAR".to_string(),
            children: [Child::Symbol("param_x".to_string())].to_vec(),
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "param_x".to_string(),
        };
        assert_eq!(visitor.predicate_origin(&node_param), (Some("param".to_string()), Some("param_x".to_string())));

        let node_local = crate::ast::Node {
            r#type: "LVAR".to_string(),
            children: [Child::Symbol("local_x".to_string())].to_vec(),
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "local_x".to_string(),
        };
        assert_eq!(visitor.predicate_origin(&node_local), (Some("local".to_string()), Some("local_x".to_string())));

        let node_ivar = crate::ast::Node {
            r#type: "IVAR".to_string(),
            children: [Child::Symbol("@ivar".to_string())].to_vec(),
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "@ivar".to_string(),
        };
        assert_eq!(visitor.predicate_origin(&node_ivar), (Some("ivar".to_string()), Some("@ivar".to_string())));

        let node_vcall = crate::ast::Node {
            r#type: "VCALL".to_string(),
            children: [Child::Symbol("vcall_m".to_string())].to_vec(),
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "vcall_m".to_string(),
        };
        assert_eq!(visitor.predicate_origin(&node_vcall), (Some("attr".to_string()), Some("vcall_m".to_string())));

        let node_fcall = crate::ast::Node {
            r#type: "FCALL".to_string(),
            children: [Child::Symbol("fcall_m".to_string())].to_vec(),
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "fcall_m".to_string(),
        };
        assert_eq!(visitor.predicate_origin(&node_fcall), (Some("call".to_string()), Some("fcall_m".to_string())));

        let node_call_args: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "SELF",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 10,
                    "text": "self"
                }},
                {"Symbol": "my_method"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {
                            "type": "LIT",
                            "children": [],
                            "first_lineno": 1,
                            "first_column": 1,
                            "last_lineno": 1,
                            "last_column": 2,
                            "text": "1"
                        }}
                    ],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 10,
                    "text": "1"
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "self.my_method(1)"
        }"#).unwrap();
        assert_eq!(visitor.predicate_origin(&node_call_args), (Some("call".to_string()), Some("my_method".to_string())));
    }

    #[test]
    fn test_deterministic_nil_predicate() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec!["x".to_string()],
            param_types: [("x".to_string(), "String".to_string())].into_iter().collect(),
            local_types: [
                ("y".to_string(), "NilClass".to_string()),
                ("z".to_string(), "T.nilable(Integer)".to_string())
            ].into_iter().collect(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        let call_nil_check: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "LVAR",
                    "children": [{"Symbol": "x"}],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": "x"
                }},
                {"Symbol": "nil?"},
                {"Node": {
                    "type": "LIST",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": ""
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "x.nil?"
        }"#).unwrap();

        let res = visitor.deterministic_nil_predicate_result(&call_nil_check);
        assert!(res.is_some());
        let res_val = res.unwrap();
        assert_eq!(res_val.get("truth_value").and_then(Value::as_bool), Some(false));

        let call_nil_check_y: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "LVAR",
                    "children": [{"Symbol": "y"}],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": "y"
                }},
                {"Symbol": "nil?"},
                {"Node": {
                    "type": "LIST",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": ""
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "y.nil?"
        }"#).unwrap();

        let res = visitor.deterministic_nil_predicate_result(&call_nil_check_y);
        assert!(res.is_some());
        let res_val = res.unwrap();
        assert_eq!(res_val.get("truth_value").and_then(Value::as_bool), Some(true));

        let call_nil_check_z: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "LVAR",
                    "children": [{"Symbol": "z"}],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": "z"
                }},
                {"Symbol": "nil?"},
                {"Node": {
                    "type": "LIST",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": ""
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "z.nil?"
        }"#).unwrap();

        let res_z = visitor.deterministic_nil_predicate_result(&call_nil_check_z);
        assert!(res_z.is_none());

        // class_guard_truth tests
        assert_eq!(visitor.class_guard_truth("Integer", "String", true), Some(false));

        // known_disjoint_guard_classes tests
        assert!(!visitor.known_disjoint_guard_classes("T::Boolean", "TrueClass"));
        assert!(!visitor.known_disjoint_guard_classes("FalseClass", "T::Boolean"));
    }

    #[test]
    fn test_hash_shape_for_value_readonly() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec![],
            param_types: BTreeMap::new(),
            local_types: BTreeMap::new(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        let hash_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "HASH",
            "children": [
                {"Node": {
                    "type": "pair",
                    "children": [
                        {"Node": {
                            "type": "SYMBOL",
                            "children": [],
                            "first_lineno": 1,
                            "first_column": 1,
                            "last_lineno": 1,
                            "last_column": 5,
                            "text": ":a"
                        }},
                        {"Node": {
                            "type": "INTEGER",
                            "children": [],
                            "first_lineno": 1,
                            "first_column": 1,
                            "last_lineno": 1,
                            "last_column": 5,
                            "text": "1"
                        }}
                    ],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 10,
                    "text": ":a => 1"
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "{:a => 1}"
        }"#).unwrap();

        let extra_hash_shapes = BTreeMap::new();
        let shape = visitor.hash_shape_for_value_readonly(&hash_node, &extra_hash_shapes);
        assert!(shape.is_some());
        let val = shape.unwrap();
        assert_eq!(val.get("keys").unwrap().get("a").unwrap().as_array().unwrap().get(0).unwrap().as_str().unwrap(), "Integer");

        let array_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ARRAY",
            "children": [
                {"Node": {
                    "type": "HASH",
                    "children": [
                        {"Node": {
                            "type": "pair",
                            "children": [
                                {"Node": {
                                    "type": "SYMBOL",
                                    "children": [],
                                    "first_lineno": 1,
                                    "first_column": 1,
                                    "last_lineno": 1,
                                    "last_column": 5,
                                    "text": ":x"
                                }},
                                {"Node": {
                                    "type": "STRING",
                                    "children": [],
                                    "first_lineno": 1,
                                    "first_column": 1,
                                    "last_lineno": 1,
                                    "last_column": 5,
                                    "text": "\"hello\""
                                }}
                            ],
                            "first_lineno": 1,
                            "first_column": 1,
                            "last_lineno": 1,
                            "last_column": 10,
                            "text": ":x => \"hello\""
                        }}
                    ],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 10,
                    "text": "{:x => \"hello\"}"
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "[{:x => \"hello\"}]"
        }"#).unwrap();

        let shape_arr = visitor.array_element_shape_for_value_readonly(&array_node, &extra_hash_shapes);
        assert!(shape_arr.is_some());
    }

    #[test]
    fn test_expression_type_with_locals_and_shapes() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec![],
            param_types: BTreeMap::new(),
            local_types: BTreeMap::new(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        let lvar_node = crate::ast::Node {
            r#type: "LVAR".to_string(),
            children: [Child::Symbol("v".to_string())].to_vec(),
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "v".to_string(),
        };

        let mut extra_locals = BTreeMap::new();
        extra_locals.insert("v".to_string(), "String".to_string());

        assert_eq!(
            visitor.expression_type_with_locals(&lvar_node, &extra_locals),
            Some("String".to_string())
        );

        let or_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "OR",
            "children": [
                {"Node": {
                    "type": "INTEGER",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": "1"
                }},
                {"Node": {
                    "type": "INTEGER",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": "2"
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "1 || 2"
        }"#).unwrap();

        assert_eq!(
            visitor.expression_type(&or_node),
            Some("Integer".to_string())
        );
    }

    fn create_visitor<'a>(
        doc: &'a Document,
        lines: &'a [String],
        tlet_sites: &'a mut Vec<serde_json::Value>,
        dead_nil_checks: &'a mut Vec<serde_json::Value>,
        deterministic_guards: &'a mut Vec<serde_json::Value>,
        return_origins: &'a mut Vec<serde_json::Value>,
        noreturn_methods: &'a mut Vec<serde_json::Value>,
        collection_index_lookups: &'a mut Vec<serde_json::Value>,
        hash_record_blockers: &'a mut Vec<serde_json::Value>,
        type_normalizers: &'a mut Vec<serde_json::Value>,
        rescue_handlers: &'a mut Vec<serde_json::Value>,
        return_usage_sites: &'a mut Vec<serde_json::Value>,
        return_direct_usage_sites: &'a mut Vec<serde_json::Value>,
        hash_record_escape_sites: &'a mut Vec<serde_json::Value>,
        hidden_enum_observations: &'a mut Vec<serde_json::Value>,
        dispatcher_inferences: &'a mut Vec<serde_json::Value>,
        hash_record_member_calls: &'a mut Vec<serde_json::Value>,
        param_origins: &'a mut Vec<serde_json::Value>,
        struct_declarations: &'a mut Vec<StructDeclaration>,
        state_type_records: &'a mut Vec<StateTypeRecord>,
        hash_shapes: &'a mut Vec<HashShape>,
        tuple_arrays: &'a mut Vec<serde_json::Value>,
        pre_registered_noreturns: &'a std::collections::HashSet<String>,
    ) -> TypeInferenceVisitor<'a> {
        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);
        TypeInferenceVisitor {
            behavior,
            document: doc,
            lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec![],
            param_types: BTreeMap::new(),
            local_types: BTreeMap::new(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites,
            dead_nil_checks,
            deterministic_guards,
            return_origins,
            noreturn_methods,
            collection_index_lookups,
            hash_record_blockers,
            type_normalizers,
            rescue_handlers,
            return_usage_sites,
            return_direct_usage_sites,
            hash_record_escape_sites,
            hidden_enum_observations,
            dispatcher_inferences,
            hash_record_member_calls,
            param_origins,
            struct_declarations,
            state_type_records,
            hash_shapes,
            tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        }
    }

    #[test]
    fn test_noreturn_detection() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let visitor = create_visitor(
            &doc,
            &lines,
            &mut tlet_sites,
            &mut dead_nil_checks,
            &mut deterministic_guards,
            &mut return_origins,
            &mut noreturn_methods,
            &mut collection_index_lookups,
            &mut hash_record_blockers,
            &mut type_normalizers,
            &mut rescue_handlers,
            &mut return_usage_sites,
            &mut return_direct_usage_sites,
            &mut hash_record_escape_sites,
            &mut hidden_enum_observations,
            &mut dispatcher_inferences,
            &mut hash_record_member_calls,
            &mut param_origins,
            &mut struct_declarations,
            &mut state_type_records,
            &mut hash_shapes,
            &mut tuple_arrays,
            &pre_registered_noreturns,
        );

        let call_absurd: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "CONST",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": "T"
                }},
                {"Symbol": "absurd"},
                {"Node": {
                    "type": "LIST",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": ""
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "T.absurd(x)"
        }"#).unwrap();

        assert!(visitor.noreturn_body(&call_absurd));
    }

    #[test]
    fn test_inference_expansion() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let mut visitor = create_visitor(
            &doc,
            &lines,
            &mut tlet_sites,
            &mut dead_nil_checks,
            &mut deterministic_guards,
            &mut return_origins,
            &mut noreturn_methods,
            &mut collection_index_lookups,
            &mut hash_record_blockers,
            &mut type_normalizers,
            &mut rescue_handlers,
            &mut return_usage_sites,
            &mut return_direct_usage_sites,
            &mut hash_record_escape_sites,
            &mut hidden_enum_observations,
            &mut dispatcher_inferences,
            &mut hash_record_member_calls,
            &mut param_origins,
            &mut struct_declarations,
            &mut state_type_records,
            &mut hash_shapes,
            &mut tuple_arrays,
            &pre_registered_noreturns,
        );

        // 1. collect_prepass_facts
        // LASGN / CASGN with Struct.new
        let struct_new_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CASGN",
            "children": [
                {"Symbol": "MyStruct"},
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":"Struct"}},
                        {"Symbol": "new"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "Struct.new"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "MyStruct = Struct.new"
        }"#).unwrap();
        let mut owners = vec![];
        let mut ivar_tlet = BTreeMap::new();
        collect_prepass_facts(&struct_new_node, Language::Ruby, &mut owners, &mut ivar_tlet);

        // CLASS / MODULE
        let class_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CLASS",
            "children": [
                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":"Klass"}},
                "Nil",
                {"Node": {
                    "type": "IASGN",
                    "children": [
                        {"Symbol": "@ivar"},
                        {"Node": {
                            "type": "CALL",
                            "children": [
                                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"T"}},
                                {"Symbol": "let"},
                                {"Node": {
                                    "type": "LIST",
                                    "children": [
                                        {"Node": {"type": "IVAR", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"@ivar"}},
                                        {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":8, "text":"String"}}
                                    ],
                                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ""
                                }}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "T.let(@ivar, String)"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "@ivar = T.let(@ivar, String)"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "class Klass; @ivar = T.let(@ivar, String); end"
        }"#).unwrap();
        collect_prepass_facts(&class_node, Language::Ruby, &mut owners, &mut ivar_tlet);
        assert_eq!(ivar_tlet.get(&("Klass".to_string(), "@ivar".to_string())), Some(&"String".to_string()));

        // 2. return_control_shape / branching_return_expression
        let explicit_ret: crate::ast::Node = serde_json::from_str(r#"{
            "type": "RETURN",
            "children": [
                {"Node": {
                    "type": "IF",
                    "children": [
                        {"Node": {"type": "TRUE", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"true"}},
                        {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}},
                        "Nil"
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "1 if true"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "return 1 if true"
        }"#).unwrap();
        let explicit_nodes = vec![&explicit_ret];
        assert_eq!(return_control_shape(&explicit_nodes, None, false), "branching");

        // 3. IF/UNLESS local type merging with None (branching merges)
        visitor.local_types.insert("my_var".to_string(), "Integer".to_string());
        // We will visit an IF statement manually
        let if_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {"type": "TRUE", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"true"}},
                {"Node": {
                    "type": "LASGN",
                    "children": [
                        {"Symbol": "my_var"},
                        {"Node": {"type": "STRING", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"\"hi\""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "my_var = \"hi\""
                }},
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "if true; my_var = \"hi\"; end"
        }"#).unwrap();
        visitor.visit(&if_node);
        assert_eq!(visitor.local_types.get("my_var").cloned(), Some("Integer".to_string()));

        // Also test IF where the else branch assigns and then doesn't
        visitor.local_types.insert("my_var2".to_string(), "Integer".to_string());
        let if_node2: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {"type": "TRUE", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"true"}},
                "Nil",
                {"Node": {
                    "type": "LASGN",
                    "children": [
                        {"Symbol": "my_var2"},
                        {"Node": {"type": "STRING", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"\"hi\""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "my_var2 = \"hi\""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "if true; else my_var2 = \"hi\"; end"
        }"#).unwrap();
        visitor.visit(&if_node2);
        assert_eq!(visitor.local_types.get("my_var2").cloned(), Some("Integer".to_string()));

        // Test uninitialized variable assigned in then branch (merges to T.nilable)
        let if_node3: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {"type": "TRUE", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"true"}},
                {"Node": {
                    "type": "LASGN",
                    "children": [
                        {"Symbol": "my_var3"},
                        {"Node": {"type": "STRING", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"\"hi\""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "my_var3 = \"hi\""
                }},
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "if true; my_var3 = \"hi\"; end"
        }"#).unwrap();
        visitor.visit(&if_node3);
        assert_eq!(visitor.local_types.get("my_var3").cloned(), Some("T.nilable(String)".to_string()));

        // 4. AND / OR / WHILE / UNTIL / CASE
        let case_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CASE",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"}},
                {"Node": {
                    "type": "WHEN",
                    "children": [
                        {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":7, "text":"Integer"}},
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "when Integer; x; end"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "case x; when Integer; x; end"
        }"#).unwrap();
        visitor.visit(&case_node);

        // 5. ITER on a Hash and Array
        visitor.local_types.insert("my_hash".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let iter_hash_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "my_hash"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":7, "text":"my_hash"}},
                        {"Symbol": "each"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":7, "text":""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 12, "text": "my_hash.each"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "k"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"k"}},
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "v"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"v"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "k, v"
                        }},
                        {"Node": {
                            "type": "STATEMENTS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "k"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"k"}},
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "v"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"v"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "k; v"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "my_hash.each { |k, v| k; v }"
        }"#).unwrap();
        visitor.visit(&iter_hash_node);

        // ITER on Array
        visitor.local_types.insert("my_array".to_string(), "T::Array[String]".to_string());
        let iter_array_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "my_array"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":8, "text":"my_array"}},
                        {"Symbol": "each"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":8, "text":""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 13, "text": "my_array.each"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "item"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"item"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 6, "text": "item"
                        }},
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "item"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"item"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "my_array.each { |item| item }"
        }"#).unwrap();
        visitor.visit(&iter_array_node);

        // 6. Mutation type tracking
        // array append: arr << val
        visitor.local_types.insert("my_array2".to_string(), "T::Array[String]".to_string());
        let append_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "my_array2"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":9, "text":"my_array2"}},
                {"Symbol": "<<"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "1"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_array2 << 1"
        }"#).unwrap();
        visitor.visit(&append_node);
        assert_eq!(visitor.local_types.get("my_array2").cloned(), Some("T::Array[T.untyped]".to_string()));
 
        // hash assignment: hash[key] = val
        visitor.local_types.insert("my_hash2".to_string(), "T::Hash[Symbol, String]".to_string());
        let hash_set_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "my_hash2"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":8, "text":"my_hash2"}},
                {"Symbol": "[]="},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":a"}},
                        {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":a, 1"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_hash2[:a] = 1"
        }"#).unwrap();
        visitor.visit(&hash_set_node);
        assert_eq!(visitor.local_types.get("my_hash2").cloned(), Some("T::Hash[Symbol, T.untyped]".to_string()));
 
        // hash merge!: hash.merge!(other)
        visitor.local_types.insert("my_hash3".to_string(), "T::Hash[Symbol, String]".to_string());
        visitor.local_types.insert("other_hash".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let merge_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "my_hash3"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":8, "text":"my_hash3"}},
                {"Symbol": "merge!"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "other_hash"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":10, "text":"other_hash"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 12, "text": "other_hash"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "my_hash3.merge!(other_hash)"
        }"#).unwrap();
        visitor.visit(&merge_node);
        assert_eq!(visitor.local_types.get("my_hash3").cloned(), Some("T::Hash[Symbol, T.untyped]".to_string()));

        // 7. provably_non_nil and guards
        visitor.local_types.insert("non_nil_v".to_string(), "String".to_string());
        let non_nil_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "LVAR",
            "children": [{"Symbol": "non_nil_v"}],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 9, "text": "non_nil_v"
        }"#).unwrap();
        assert!(visitor.provably_non_nil(&non_nil_node));

        // nil check guard
        let unless_nil_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "UNLESS",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "non_nil_v"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":9, "text":"non_nil_v"}},
                        {"Symbol": "nil?"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":9, "text":""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "non_nil_v.nil?"
                }},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}},
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "unless non_nil_v.nil?; 1; end"
        }"#).unwrap();
        visitor.visit(&unless_nil_node);
        assert!(!visitor.dead_nil_checks.is_empty());

        // Class guards and subclass/disjointness
        visitor.local_types.insert("my_int".to_string(), "Integer".to_string());
        let class_guard_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "my_int"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":"my_int"}},
                        {"Symbol": "is_a?"},
                        {"Node": {
                            "type": "LIST",
                            "children": [
                                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":"String"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 8, "text": "String"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_int.is_a?(String)"
                }},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}},
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "if my_int.is_a?(String); 1; end"
        }"#).unwrap();
        visitor.visit(&class_guard_node);
        assert!(!visitor.deterministic_guards.is_empty());

        // Subclass guard Numeric
        let class_guard_sub_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "my_int"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":"my_int"}},
                        {"Symbol": "is_a?"},
                        {"Node": {
                            "type": "LIST",
                            "children": [
                                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":7, "text":"Numeric"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 9, "text": "Numeric"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_int.is_a?(Numeric)"
                }},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}},
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "if my_int.is_a?(Numeric); 1; end"
        }"#).unwrap();
        visitor.visit(&class_guard_sub_node);
    }

    #[test]
    fn test_readonly_shapes() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let mut visitor = create_visitor(
            &doc,
            &lines,
            &mut tlet_sites,
            &mut dead_nil_checks,
            &mut deterministic_guards,
            &mut return_origins,
            &mut noreturn_methods,
            &mut collection_index_lookups,
            &mut hash_record_blockers,
            &mut type_normalizers,
            &mut rescue_handlers,
            &mut return_usage_sites,
            &mut return_direct_usage_sites,
            &mut hash_record_escape_sites,
            &mut hidden_enum_observations,
            &mut dispatcher_inferences,
            &mut hash_record_member_calls,
            &mut param_origins,
            &mut struct_declarations,
            &mut state_type_records,
            &mut hash_shapes,
            &mut tuple_arrays,
            &pre_registered_noreturns,
        );

        let extra_hash_shapes = BTreeMap::new();

        // 1. ATTRASGN / IASGN / CASGN etc.
        let iasgn_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IASGN",
            "children": [
                {"Symbol": "@x"},
                {"Node": {
                    "type": "HASH",
                    "children": [],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{}"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "@x = {}"
        }"#).unwrap();
        let shape = visitor.hash_shape_for_value_readonly(&iasgn_node, &extra_hash_shapes);
        assert!(shape.is_some());

        let attr_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ATTRASGN",
            "children": [
                {"Node": {"type": "SELF", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"self"}},
                {"Symbol": "x="},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "HASH", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"{}"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "{}"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "self.x = {}"
        }"#).unwrap();
        let shape_attr = visitor.hash_shape_for_value_readonly(&attr_node, &extra_hash_shapes);
        assert!(shape_attr.is_some());

        // 2. HASH with keys, values, and poisoned case
        let hash_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "HASH",
            "children": [
                {"Node": {
                    "type": "pair",
                    "children": [
                        {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":a"}},
                        {"Node": {"type": "HASH", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"{}"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":a => {}"
                }},
                {"Node": {
                    "type": "pair",
                    "children": [
                        {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":b"}},
                        {"Node": {
                            "type": "ARRAY",
                            "children": [
                                {"Node": {"type": "HASH", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"{}"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "[{}]"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":b => [{}]"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "{:a => {}, :b => [{}]}"
        }"#).unwrap();
        let shape_hash = visitor.hash_shape_for_value_readonly(&hash_node, &extra_hash_shapes);
        assert!(shape_hash.is_some());
        let sh_val = shape_hash.unwrap();
        assert!(!sh_val.get("value_hash_shapes").unwrap().get("a").is_none());
        assert!(!sh_val.get("value_array_element_shapes").unwrap().get("b").is_none());

        // Poisoned HASH
        let poisoned_hash: crate::ast::Node = serde_json::from_str(r#"{
            "type": "HASH",
            "children": [
                {"Node": {
                    "type": "pair",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"}},
                        {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "x => 1"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "{x => 1}"
        }"#).unwrap();
        let shape_poisoned = visitor.hash_shape_for_value_readonly(&poisoned_hash, &extra_hash_shapes).unwrap();
        assert_eq!(shape_poisoned.get("poisoned").and_then(Value::as_bool), Some(true));

        // 3. LVAR / DVAR extra / local shapes
        let lvar_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "LVAR",
            "children": [{"Symbol": "var_a"}],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "var_a"
        }"#).unwrap();
        let mut extra_locals_shapes = BTreeMap::new();
        extra_locals_shapes.insert("var_a".to_string(), json!({"keys": {}}));
        let shape_lvar = visitor.hash_shape_for_value_readonly(&lvar_node, &extra_locals_shapes);
        assert!(shape_lvar.is_some());

        // 4. CALL / QCALL / OPCALL
        // Type normalizer cast case: T.cast(x, Type)
        let cast_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"T"}},
                {"Symbol": "cast"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "HASH", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"{}"}},
                        {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"Hash"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "{}, Hash"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "T.cast({}, Hash)"
        }"#).unwrap();
        let shape_cast = visitor.hash_shape_for_value_readonly(&cast_node, &extra_hash_shapes);
        assert!(shape_cast.is_some());

        // Array index/first/last cases: arr.first
        let first_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "LVAR",
                    "children": [{"Symbol": "my_arr"}],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 7, "text": "my_arr"
                }},
                {"Symbol": "first"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_arr.first"
        }"#).unwrap();
        visitor.local_array_shapes.insert("my_arr".to_string(), json!({"keys": {}}));
        let shape_first = visitor.hash_shape_for_value_readonly(&first_node, &extra_hash_shapes);
        assert!(shape_first.is_some());

        // Method return shapes
        visitor.method_return_hash_shapes.insert(("MyClass".to_string(), "my_method".to_string()), json!({"keys": {}}));
        let method_call_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":8, "text":"MyClass"}},
                {"Symbol": "my_method"},
                {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "MyClass.my_method"
        }"#).unwrap();
        let shape_method = visitor.hash_shape_for_value_readonly(&method_call_node, &extra_hash_shapes);
        assert!(shape_method.is_some());

        // Struct field shapes
        visitor.struct_field_hash_shapes.insert(("MyStructClass".to_string(), "field_a".to_string()), json!({"keys": {}}));
        visitor.local_types.insert("my_struct_inst".to_string(), "MyStructClass".to_string());
        let struct_field_call_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "my_struct_inst"}], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_struct_inst"}},
                {"Symbol": "field_a"},
                {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 25, "text": "my_struct_inst.field_a"
        }"#).unwrap();
        let shape_struct_field = visitor.hash_shape_for_value_readonly(&struct_field_call_node, &extra_hash_shapes);
        assert!(shape_struct_field.is_some());

        // 5. ARRAY / LIST of hash element shapes
        let array_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ARRAY",
            "children": [
                {"Node": {"type": "HASH", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{}"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "[{}]"
        }"#).unwrap();
        let shape_arr = visitor.array_element_shape_for_value_readonly(&array_node, &extra_hash_shapes);
        assert!(shape_arr.is_some());

        // 6. ITER map/collect element shapes
        let map_iter_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "my_arr2"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":7, "text":"my_arr2"}},
                        {"Symbol": "map"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_arr2.map"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "item"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"item"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 6, "text": "item"
                        }},
                        {"Node": {"type": "HASH", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{}"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "my_arr2.map { |item| {} }"
        }"#).unwrap();
        visitor.local_array_shapes.insert("my_arr2".to_string(), json!({"keys": {}}));
        let shape_map = visitor.array_element_shape_for_value_readonly(&map_iter_node, &extra_hash_shapes);
        assert!(shape_map.is_some());
    }

    #[test]
    fn test_additional_uncovered_paths() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let mut visitor = create_visitor(
            &doc,
            &lines,
            &mut tlet_sites,
            &mut dead_nil_checks,
            &mut deterministic_guards,
            &mut return_origins,
            &mut noreturn_methods,
            &mut collection_index_lookups,
            &mut hash_record_blockers,
            &mut type_normalizers,
            &mut rescue_handlers,
            &mut return_usage_sites,
            &mut return_direct_usage_sites,
            &mut hash_record_escape_sites,
            &mut hidden_enum_observations,
            &mut dispatcher_inferences,
            &mut hash_record_member_calls,
            &mut param_origins,
            &mut struct_declarations,
            &mut state_type_records,
            &mut hash_shapes,
            &mut tuple_arrays,
            &pre_registered_noreturns,
        );

        let extra_hash_shapes = BTreeMap::new();

        // 1. empty text VCALL node for node_symbol
        let node_empty_vcall: crate::ast::Node = serde_json::from_str(r#"{
            "type": "VCALL",
            "children": [],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 1, "text": ""
        }"#).unwrap();
        assert_eq!(node_symbol(&node_empty_vcall), None);

        // 2. collect_prepass_facts CLASS module qualified formatting with empty current_owners
        let mut current_owners = vec![];
        let mut ivar_tlet_types = BTreeMap::new();
        let class_node_simple: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CLASS",
            "children": [
                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"Foo"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "class Foo; end"
        }"#).unwrap();
        collect_prepass_facts(&class_node_simple, Language::Ruby, &mut current_owners, &mut ivar_tlet_types);

        // 3. IASGN prepass cases:
        // - ivar_name is None
        let iasgn_no_sym: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IASGN",
            "children": [],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 1, "text": ""
        }"#).unwrap();
        collect_prepass_facts(&iasgn_no_sym, Language::Ruby, &mut current_owners, &mut ivar_tlet_types);

        // - val_node is None
        let iasgn_no_val: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IASGN",
            "children": [{"Symbol": "@foo"}],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 1, "text": "@foo"
        }"#).unwrap();
        collect_prepass_facts(&iasgn_no_val, Language::Ruby, &mut current_owners, &mut ivar_tlet_types);

        // - not "let" or receiver not "T"
        let iasgn_not_t_let: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IASGN",
            "children": [
                {"Symbol": "@foo"},
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"X"}},
                        {"Symbol": "let"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "X.let"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "@foo = X.let"
        }"#).unwrap();
        collect_prepass_facts(&iasgn_not_t_let, Language::Ruby, &mut current_owners, &mut ivar_tlet_types);

        // 4. hash_shape_for_value HASH with empty pair elements to hit continue branches
        let hash_empty_pair: crate::ast::Node = serde_json::from_str(r#"{
            "type": "HASH",
            "children": [
                {"Node": {"type": "pair", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 1, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "{}"
        }"#).unwrap();
        let shape_empty_pair = visitor.hash_shape_for_value_readonly(&hash_empty_pair, &extra_hash_shapes);
        assert!(shape_empty_pair.is_some());

        // 5. array_element_shape_for_value_readonly LVAR/DVAR, and QCALL/OPCALL methods
        let dvar_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "DVAR",
            "children": [{"Symbol": "var_d"}],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "var_d"
        }"#).unwrap();
        visitor.local_array_shapes.insert("var_d".to_string(), json!({"keys": {}}));
        let shape_dvar = visitor.array_element_shape_for_value_readonly(&dvar_node, &extra_hash_shapes);
        assert!(shape_dvar.is_some());

        let qcall_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "QCALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "var_d"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"var_d"}},
                {"Symbol": "first"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "var_d?.first"
        }"#).unwrap();
        let shape_qcall = visitor.array_element_shape_for_value_readonly(&qcall_node, &extra_hash_shapes);
        assert!(shape_qcall.is_some());

        // 6. array_element_shape_for_receiver_readonly select/reject/compact/filter_map methods
        let select_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "var_d"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"var_d"}},
                {"Symbol": "select"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "var_d.select"
        }"#).unwrap();
        let shape_select = visitor.array_element_shape_for_receiver_readonly(Some(&select_node), &extra_hash_shapes);
        assert!(shape_select.is_some());

        // 7. provably_non_nil with literal node & SELF
        let self_node = crate::ast::Node {
            r#type: "SELF".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 4, text: "self".to_string(),
        };
        assert!(visitor.provably_non_nil(&self_node));

        let true_node = crate::ast::Node {
            r#type: "TRUE".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 4, text: "true".to_string(),
        };
        assert!(visitor.provably_non_nil(&true_node));

        // 8. inspect_branch_guard with no children
        let guard_no_child = crate::ast::Node {
            r#type: "IF".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 1, text: "if".to_string(),
        };
        visitor.inspect_branch_guard(&guard_no_child, false);

        // 9. deterministic_predicate_result PAREN node with no children
        let paren_no_child = crate::ast::Node {
            r#type: "PAREN".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 1, text: "()".to_string(),
        };
        assert!(visitor.deterministic_predicate_result(&paren_no_child).is_none());

        // 10. deterministic_class_predicate_result checks:
        // - class predicate has not 1 argument
        let class_guard_0_args: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"}},
                {"Symbol": "is_a?"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "x.is_a?"
        }"#).unwrap();
        assert!(visitor.deterministic_class_predicate_result(&class_guard_0_args).is_none());

        // - empty class name
        let class_guard_empty_arg: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"}},
                {"Symbol": "is_a?"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "STR", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "x.is_a?('')"
        }"#).unwrap();
        assert!(visitor.deterministic_class_predicate_result(&class_guard_empty_arg).is_none());

        // 11. class_guard_truth edge cases:
        assert_eq!(visitor.class_guard_truth("T.untyped", "String", false), None);
        assert_eq!(visitor.class_guard_truth("T.nilable(String)", "String", false), None);
        assert_eq!(visitor.class_guard_truth("", "String", false), None);
        // normalized empty case:
        assert_eq!(visitor.class_guard_truth("T.nilable()", "String", false), None);

        // 12. bare_class_name
        assert_eq!(visitor.bare_class_name("T::Array[String]"), "Array");
        assert_eq!(visitor.bare_class_name("Array"), "Array");
        assert_eq!(visitor.bare_class_name("T::Hash[Symbol, Integer]"), "Hash");
        assert_eq!(visitor.bare_class_name("T::Set[Integer]"), "Set");
        assert_eq!(visitor.bare_class_name("T::Boolean"), "T::Boolean");
        assert_eq!(visitor.bare_class_name("::A::B"), "B");

        // 13. known_disjoint_guard_classes with T::Boolean
        assert!(!visitor.known_disjoint_guard_classes("T::Boolean", "TrueClass"));
        assert!(!visitor.known_disjoint_guard_classes("TrueClass", "T::Boolean"));

        // 14. deterministic_literal_comparison_result with comparison method not 1 argument
        let compare_0_args: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}},
                {"Symbol": "=="},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "1.=="
        }"#).unwrap();
        assert!(visitor.deterministic_literal_comparison_result(&compare_0_args).is_none());

        // 15. predicate_origin with CALL node having 0 arguments
        let call_0_args: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "SELF", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"self"}},
                {"Symbol": "foo"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "self.foo"
        }"#).unwrap();
        let origin = visitor.predicate_origin(&call_0_args);
        assert_eq!(origin, (Some("attr".to_string()), Some("foo".to_string())));

        let origin_fallback = visitor.predicate_origin(&true_node);
        assert_eq!(origin_fallback, (None, None));

        // 16. hash_shape_index_type_readonly_with_shapes poisoned shape or empty types
        let idx_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":":a"
        }"#).unwrap();
        let mut poisoned_shapes = BTreeMap::new();
        poisoned_shapes.insert("x".to_string(), json!({"poisoned": true}));
        let receiver_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"
        }"#).unwrap();
        assert_eq!(visitor.hash_shape_index_type_readonly_with_shapes(&receiver_node, &idx_node, &poisoned_shapes), None);

        let mut empty_key_shapes = BTreeMap::new();
        empty_key_shapes.insert("x".to_string(), json!({"keys": {"a": []}}));
        assert_eq!(visitor.hash_shape_index_type_readonly_with_shapes(&receiver_node, &idx_node, &empty_key_shapes), None);

        // 17. static_expression_type_with_locals_and_shapes with OPCALL callee, collection type details, and []/fetch
        let opcall_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "OPCALL",
            "children": [
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}},
                {"Symbol": "+"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"2"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "2"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "1 + 2"
        }"#).unwrap();
        assert_eq!(visitor.static_expression_type(&opcall_node), Some("Integer".to_string()));

        // Collection iteration types (each/map details)
        let iter_untyped_rec: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "c"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"c"}},
                        {"Symbol": "each"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "c.each"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "k"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"k"}},
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "v"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"v"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "k, v"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "c.each { |k, v| }"
        }"#).unwrap();
        let mut extra_locals = BTreeMap::new();
        extra_locals.insert("c".to_string(), "T::Hash[Symbol, String]".to_string());
        assert!(visitor.static_expression_type_with_locals(&iter_untyped_rec, &extra_locals).is_some());

        // Array element type iteration details
        let iter_arr: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "a"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"a"}},
                        {"Symbol": "each"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "a.each"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "elem"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"elem"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "elem"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "a.each { |elem| }"
        }"#).unwrap();
        let mut extra_locals_arr = BTreeMap::new();
        extra_locals_arr.insert("a".to_string(), "T::Array[String]".to_string());
        assert!(visitor.static_expression_type_with_locals(&iter_arr, &extra_locals_arr).is_some());

        // 18. expression_type on empty array / empty hash
        let empty_arr: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ARRAY",
            "children": [],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "[]"
        }"#).unwrap();
        assert_eq!(visitor.expression_type(&empty_arr), Some("T::Array[T.untyped]".to_string()));

        // 19. literal_type on LIT float value
        let float_lit: crate::ast::Node = serde_json::from_str(r#"{
            "type": "LIT",
            "children": [],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "3.14"
        }"#).unwrap();
        assert_eq!(visitor.expression_type(&float_lit), Some("Float".to_string()));

        // 20. noreturn_body with empty branches (IF/UNLESS)
        let noreturn_if_empty: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {"type": "TRUE", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 4, "text": "true"}},
                "Nil",
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "if true; end"
        }"#).unwrap();
        assert!(!visitor.noreturn_body(&noreturn_if_empty));

        // 21. noreturn_call with non-call node or absurd call
        let absurd_call: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"T"}},
                {"Symbol": "absurd"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "T.absurd"
        }"#).unwrap();
        assert!(visitor.noreturn_call(&absurd_call));
        assert!(!visitor.noreturn_call(&true_node));

        // 22. return_sources_for with empty BLOCK, implicit else, empty CASE
        let return_empty_block: crate::ast::Node = serde_json::from_str(r#"{
            "type": "BLOCK",
            "children": [],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": ""
        }"#).unwrap();
        let mut blockers = BTreeSet::new();
        let res_sources = visitor.return_sources_for(&return_empty_block, None, &mut blockers);
        assert_eq!(res_sources.len(), 1);

        let if_implicit_else: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {"type": "TRUE", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 4, "text": "true"}},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "1"}},
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "1 if true"
        }"#).unwrap();
        let res_sources_if = visitor.return_sources_for(&if_implicit_else, None, &mut blockers);
        assert!(!res_sources_if.is_empty());

        let case_empty: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CASE",
            "children": [],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "case; end"
        }"#).unwrap();
        let res_sources_case = visitor.return_sources_for(&case_empty, None, &mut blockers);
        assert!(res_sources_case.is_empty());

        // 23. classify_origin with GVAR, VCALL, etc.
        let gvar_node = crate::ast::Node {
            r#type: "GVAR".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 5, text: "$g".to_string(),
        };
        let param_names_set = BTreeSet::new();
        let assigns_map = BTreeMap::new();
        let origin_gvar = visitor.classify_origin(&gvar_node, &param_names_set, &assigns_map, 0);
        assert_eq!(origin_gvar, ("local".to_string(), Value::Null));

        let vcall_node = crate::ast::Node {
            r#type: "VCALL".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 5, text: "v".to_string(),
        };
        let origin_vcall = visitor.classify_origin(&vcall_node, &param_names_set, &assigns_map, 0);
        assert_eq!(origin_vcall, ("attr".to_string(), json!("v")));

        // 24. current_params_json optional/keyword params default values
        let defn_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "DEFN",
            "children": [
                {"Symbol": "my_method"},
                {"Node": {
                    "type": "parameters",
                    "children": [
                        {"Node": {
                            "type": "optional_parameter",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 4, "text": "opt"}},
                                {"Node": {"type": "NIL", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 3, "text": "nil"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "opt = nil"
                        }},
                        {"Node": {
                            "type": "keyword_parameter",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 4, "text": "key"}},
                                {"Node": {"type": "INTEGER", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "1"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "key: 1"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "(opt = nil, key: 1)"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 30, "text": "def my_method(opt = nil, key: 1); end"
        }"#).unwrap();
        visitor.current_params = vec!["opt".to_string(), "key".to_string()];
        let params_json = visitor.current_params_json(&defn_node);
        assert_eq!(params_json.len(), 2);

        // 25. collect_hidden_enum_observations_node: include?/member?/key? method calls, and IVAR/CVAR receiver
        let record = json!({
            "path": "test.rb",
            "class": "MyClass",
            "kind": "instance",
            "method": "foo",
            "line": 1,
            "params": []
        });
        let include_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "IVAR", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"@arr"}},
                {"Symbol": "include?"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "x"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "@arr.include?(x)"
        }"#).unwrap();
        let params_map = BTreeMap::new();
        visitor.collect_hidden_enum_observations_node(&include_node, &record, &params_map);

        // 26. inspect_dead_nil_check nil check and safe_nav on a non-nil receiver
        visitor.local_types.insert("nn".to_string(), "String".to_string());
        let nil_check_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "nn"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":"nn"}},
                {"Symbol": "nil?"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "nn.nil?"
        }"#).unwrap();
        visitor.inspect_call_node(&nil_check_node);
        assert!(!visitor.dead_nil_checks.is_empty());

        let safe_nav_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "QCALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "nn"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":"nn"}},
                {"Symbol": "upcase"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "nn?.upcase"
        }"#).unwrap();
        visitor.inspect_call_node(&safe_nav_node);

        // 27. update_local_fact / inspect_local_container_origin / inspect_ivar_container_origin / inspect_struct_declaration
        let lasgn_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "LASGN",
            "children": [
                {"Symbol": "var_lasgn"},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "var_lasgn = 1"
        }"#).unwrap();
        visitor.update_local_fact(&lasgn_node);
        visitor.inspect_local_container_origin(&lasgn_node);
        visitor.inspect_ivar_container_origin(&lasgn_node);
        visitor.inspect_struct_declaration(&lasgn_node);

        // CASGN to run inspect_ivar_container_origin / inspect_struct_declaration
        let casgn_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CASGN",
            "children": [
                {"Symbol": "MyConst"},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "1"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "MyConst = 1"
        }"#).unwrap();
        visitor.visit(&casgn_node);

        // OP_ASGN1 and OP_ASGN2 return sources
        let op_asgn1_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "OP_ASGN1",
            "children": [
                "Nil", "Nil", "Nil",
                {"Node": {"type": "INTEGER", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "5"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "x[0] += 5"
        }"#).unwrap();
        let res_op1 = visitor.return_sources_for(&op_asgn1_node, None, &mut blockers);
        assert!(!res_op1.is_empty());

        let op_asgn2_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "OP_ASGN2",
            "children": [
                "Nil", "Nil", "Nil", "Nil",
                {"Node": {"type": "INTEGER", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "6"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "x.y += 6"
        }"#).unwrap();
        let res_op2 = visitor.return_sources_for(&op_asgn2_node, None, &mut blockers);
        assert!(!res_op2.is_empty());

        // 28. hash_shape_index_type_readonly
        let hash_idx_recv: crate::ast::Node = serde_json::from_str(r#"{
            "type": "LVAR", "children": [{"Symbol": "h_idx"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":"h_idx"
        }"#).unwrap();
        let hash_idx_key: crate::ast::Node = serde_json::from_str(r#"{
            "type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":":a"
        }"#).unwrap();
        visitor.local_hash_shapes.insert("h_idx".to_string(), json!({"keys": {"a": ["String"]}}));
        assert_eq!(visitor.hash_shape_index_type_readonly(&hash_idx_recv, &hash_idx_key), Some("T.nilable(String)".to_string()));

        // 29. GVASGN inspect_ivar_container_origin / inspect_struct_declaration
        let gvasgn_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "GVASGN",
            "children": [
                {"Symbol": "$gvar"},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "$gvar = 1"
        }"#).unwrap();
        visitor.visit(&gvasgn_node);

        // 30. shadow existing array shape variable in ITER block param to cover line 1013
        visitor.local_array_shapes.insert("elem".to_string(), json!({"keys": {}}));
        visitor.visit(&iter_arr);
    }

    #[test]
    fn test_uncovered_method_visitation() {
        let doc_json = r#"{
            "file": "test.rb",
            "language": "ruby",
            "function_defs": [
                {
                    "file": "test.rb",
                    "name": "my_method",
                    "owner": "MyClass",
                    "line": 1,
                    "span": [1, 1, 5, 5],
                    "body": {
                        "kind": "body",
                        "text": "",
                        "span": [1, 1, 5, 5],
                        "named": true,
                        "field_name": null,
                        "children": []
                    },
                    "visibility": "public",
                    "params": [],
                    "signature": ""
                },
                {
                    "file": "test.rb",
                    "name": "self.my_class_method",
                    "owner": "MyClass",
                    "line": 1,
                    "span": [1, 1, 5, 5],
                    "body": {
                        "kind": "body",
                        "text": "",
                        "span": [1, 1, 5, 5],
                        "named": true,
                        "field_name": null,
                        "children": []
                    },
                    "visibility": "public",
                    "params": [],
                    "signature": ""
                }
            ]
        }"#;
        let doc: Document = serde_json::from_str(doc_json).unwrap();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let mut visitor = create_visitor(
            &doc,
            &lines,
            &mut tlet_sites,
            &mut dead_nil_checks,
            &mut deterministic_guards,
            &mut return_origins,
            &mut noreturn_methods,
            &mut collection_index_lookups,
            &mut hash_record_blockers,
            &mut type_normalizers,
            &mut rescue_handlers,
            &mut return_usage_sites,
            &mut return_direct_usage_sites,
            &mut hash_record_escape_sites,
            &mut hidden_enum_observations,
            &mut dispatcher_inferences,
            &mut hash_record_member_calls,
            &mut param_origins,
            &mut struct_declarations,
            &mut state_type_records,
            &mut hash_shapes,
            &mut tuple_arrays,
            &pre_registered_noreturns,
        );

        // 31. DEFN node with multiple returns to hit lines 672 and 687
        let defn_multi_returns: crate::ast::Node = serde_json::from_str(r#"{
            "type": "DEFN",
            "children": [
                {"Symbol": "my_method"},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "RETURN",
                            "children": [
                                {"Node": {"type": "HASH", "children": [
                                    {"Node": {
                                        "type": "pair",
                                        "children": [
                                            {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":a"}},
                                            {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
                                        ],
                                        "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":a => 1"
                                    }}
                                ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{:a => 1}"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "return {:a => 1}"
                        }},
                        {"Node": {
                            "type": "RETURN",
                            "children": [
                                {"Node": {"type": "HASH", "children": [
                                    {"Node": {
                                        "type": "pair",
                                        "children": [
                                            {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":b"}},
                                            {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"2"}}
                                        ],
                                        "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":b => 2"
                                    }}
                                ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{:b => 2}"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "return {:b => 2}"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 30, "text": "def my_method; return {:a=>1}; return {:b=>2}; end"
        }"#).unwrap();

        visitor.current_owners = vec!["MyClass".to_string()];
        visitor.visit(&defn_multi_returns);

        let defn_array_multi_returns: crate::ast::Node = serde_json::from_str(r#"{
            "type": "DEFN",
            "children": [
                {"Symbol": "my_method"},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "RETURN",
                            "children": [
                                {"Node": {"type": "ARRAY", "children": [
                                    {"Node": {"type": "HASH", "children": [
                                        {"Node": {
                                            "type": "pair",
                                            "children": [
                                                {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":a"}},
                                                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
                                            ],
                                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":a => 1"
                                        }}
                                    ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{:a => 1}"}}
                                ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "[{:a => 1}]"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "return [{:a => 1}]"
                        }},
                        {"Node": {
                            "type": "RETURN",
                            "children": [
                                {"Node": {"type": "ARRAY", "children": [
                                    {"Node": {"type": "HASH", "children": [
                                        {"Node": {
                                            "type": "pair",
                                            "children": [
                                                {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":b"}},
                                                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"2"}}
                                            ],
                                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":b => 2"
                                        }}
                                    ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{:b => 2}"}}
                                ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "[{:b => 2}]"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "return [{:b => 2}]"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 30, "text": "def my_method; return [{:a=>1}]; return [{:b=>2}]; end"
        }"#).unwrap();

        visitor.visit(&defn_array_multi_returns);

        // 32. DEFS node with multiple returns to hit lines 672 and 687
        let defs_multi_returns: crate::ast::Node = serde_json::from_str(r#"{
            "type": "DEFS",
            "children": [
                {"Symbol": "self"},
                {"Symbol": "my_class_method"},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "RETURN",
                            "children": [
                                {"Node": {"type": "HASH", "children": [
                                    {"Node": {
                                        "type": "pair",
                                        "children": [
                                            {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":a"}},
                                            {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
                                        ],
                                        "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":a => 1"
                                    }}
                                ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{:a => 1}"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "return {:a => 1}"
                        }},
                        {"Node": {
                            "type": "RETURN",
                            "children": [
                                {"Node": {"type": "HASH", "children": [
                                    {"Node": {
                                        "type": "pair",
                                        "children": [
                                            {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":b"}},
                                            {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"2"}}
                                        ],
                                        "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":b => 2"
                                    }}
                                ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{:b => 2}"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "return {:b => 2}"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 30, "text": "def self.my_class_method; return {:a=>1}; return {:b=>2}; end"
        }"#).unwrap();

        visitor.visit(&defs_multi_returns);
    }

    #[test]
    fn test_uncovered_type_inference_helpers() {
        fn make_node(r#type: &str, children: Vec<crate::ast::Child>, text: &str) -> crate::ast::Node {
            crate::ast::Node {
                r#type: r#type.to_string(),
                children,
                first_lineno: 1,
                first_column: 1,
                last_lineno: 1,
                last_column: 1,
                text: text.to_string(),
            }
        }
        
        fn make_symbol(symbol: &str) -> crate::ast::Child {
            crate::ast::Child::Symbol(symbol.to_string())
        }
        
        fn make_child_node(node: crate::ast::Node) -> crate::ast::Child {
            crate::ast::Child::Node(Box::new(node))
        }

        let doc = dummy_doc();
        let extra_hash_shapes = std::collections::BTreeMap::new();
        let true_node = crate::ast::Node {
            r#type: "TRUE".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 4, text: "true".to_string(),
        };
        let hash_idx_key: crate::ast::Node = serde_json::from_str(r#"{
            "type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":":a"
        }"#).unwrap();
        let iter_arr: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "a"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"a"}},
                        {"Symbol": "each"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "a.each"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "elem"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"elem"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "elem"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "a.each { |elem| }"
        }"#).unwrap();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let mut visitor = create_visitor(
            &doc,
            &lines,
            &mut tlet_sites,
            &mut dead_nil_checks,
            &mut deterministic_guards,
            &mut return_origins,
            &mut noreturn_methods,
            &mut collection_index_lookups,
            &mut hash_record_blockers,
            &mut type_normalizers,
            &mut rescue_handlers,
            &mut return_usage_sites,
            &mut return_direct_usage_sites,
            &mut hash_record_escape_sites,
            &mut hidden_enum_observations,
            &mut dispatcher_inferences,
            &mut hash_record_member_calls,
            &mut param_origins,
            &mut struct_declarations,
            &mut state_type_records,
            &mut hash_shapes,
            &mut tuple_arrays,
            &pre_registered_noreturns,
        );

        // 1. nilable_type
        assert_eq!(nilable_type("NilClass"), "NilClass");
        assert_eq!(nilable_type("T.nilable(Integer)"), "T.nilable(Integer)");
        assert_eq!(nilable_type("Integer"), "T.nilable(Integer)");

        // 2. extract_param_entries
        let entries = extract_param_entries("params(a: Integer, b: String)");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0], ("a".to_string(), "Integer".to_string()));
        assert_eq!(entries[1], ("b".to_string(), "String".to_string()));

        // 3. collection_index_status
        assert_eq!(collection_index_status(Some("T.untyped"), None), "weak collection receiver");
        assert_eq!(collection_index_status(Some("Array<Integer>"), None), "typed collection receiver");
        assert_eq!(collection_index_status(Some("Hash<Symbol, String>"), None), "typed collection receiver");
        assert_eq!(collection_index_status(Some("T::Array[Integer]"), None), "typed collection receiver");
        assert_eq!(collection_index_status(Some("T::Hash[Symbol, String]"), None), "typed collection receiver");
        assert_eq!(collection_index_status(Some("String"), None), "non-collection or unresolved receiver");

        // 4. dispatch_helper_call
        let node_fcall = make_node(
            "WHEN",
            vec![make_child_node(make_node(
                "FCALL",
                vec![
                    make_symbol("is_a?"),
                    make_child_node(make_node(
                        "ARGUMENT_LIST",
                        vec![make_child_node(make_node("LVAR", vec![], "my_param"))],
                        "my_param"
                    ))
                ],
                "is_a?(my_param)"
            ))],
            ""
        );
        assert_eq!(dispatch_helper_call(&node_fcall, "my_param"), Some("is_a?".to_string()));

        let node_call = make_node(
            "WHEN",
            vec![make_child_node(make_node(
                "CALL",
                vec![
                    make_child_node(make_node("self", vec![], "self")),
                    make_symbol("is_a?"),
                    make_child_node(make_node(
                        "ARGUMENT_LIST",
                        vec![make_child_node(make_node("DVAR", vec![], "my_param"))],
                        "my_param"
                    ))
                ],
                "self.is_a?(my_param)"
            ))],
            ""
        );
        assert_eq!(dispatch_helper_call(&node_call, "my_param"), Some("is_a?".to_string()));

        // 5. collect_prepass_facts CLASS owner
        let class_node = make_node(
            "CLASS",
            vec![
                make_symbol("MyClass"),
                crate::ast::Child::Nil,
                make_child_node(make_node(
                    "IASGN",
                    vec![
                        make_symbol("@my_ivar"),
                        make_child_node(make_node(
                            "CALL",
                            vec![
                                make_child_node(make_node("CONST", vec![], "T")),
                                make_symbol("let"),
                                make_child_node(make_node(
                                    "ARGUMENT_LIST",
                                    vec![
                                        make_child_node(make_node("IDENTIFIER", vec![], "val")),
                                        make_child_node(make_node("CONST", vec![], "Integer"))
                                    ],
                                    "val, Integer"
                                ))
                            ],
                            "T.let(val, Integer)"
                        ))
                    ],
                    "@my_ivar = T.let(val, Integer)"
                ))
            ],
            ""
        );
        let mut current_owners = vec![];
        let mut ivar_tlet_types = std::collections::BTreeMap::new();
        collect_prepass_facts(&class_node, Language::Ruby, &mut current_owners, &mut ivar_tlet_types);
        assert_eq!(ivar_tlet_types.get(&("MyClass".to_string(), "@my_ivar".to_string())), Some(&"Integer".to_string()));

        // 6. collect_return_usage_site_context direct_usage variants
        let node_arg_list = make_node(
            "ARGUMENT_LIST",
            vec![make_child_node(make_node("IDENTIFIER", vec![], "x"))],
            "x"
        );
        visitor.collect_return_usage_site_context(&node_arg_list, "value", None, None, false);

        let node_opasgn_el = make_node(
            "OPASGN",
            vec![
                make_child_node(make_node(
                    "element_reference",
                    vec![
                        make_child_node(make_node("IDENTIFIER", vec![], "arr")),
                        make_child_node(make_node(
                            "ARGUMENT_LIST",
                            vec![make_child_node(make_node("INTEGER", vec![], "0"))],
                            "0"
                        ))
                    ],
                    "arr[0]"
                )),
                make_symbol("arr"),
                make_child_node(make_node("INTEGER", vec![], "1"))
            ],
            "arr[0] += 1"
        );
        visitor.collect_return_usage_site_context(&node_opasgn_el, "value", None, None, false);
        visitor.collect_return_usage_site_context(&node_opasgn_el, "value", None, None, true);

        // OPASGN LHS Const cases for ||= and other
        let node_opasgn_const_or = make_node(
            "OPASGN",
            vec![
                make_child_node(make_node("CONST", vec![], "ConstName")),
                make_child_node(make_node("INTEGER", vec![], "1"))
            ],
            "ConstName ||= 1"
        );
        visitor.collect_return_usage_site_context(&node_opasgn_const_or, "special_context", None, None, false);

        let node_opasgn_const_other = make_node(
            "OPASGN",
            vec![
                make_child_node(make_node("CONST", vec![], "ConstName")),
                make_child_node(make_node("INTEGER", vec![], "1"))
            ],
            "ConstName += 1"
        );
        visitor.collect_return_usage_site_context(&node_opasgn_const_other, "value", None, None, false);

        let node_opasgn_id = make_node(
            "OPASGN",
            vec![
                make_child_node(make_node("identifier", vec![], "x")),
                make_child_node(make_node("INTEGER", vec![], "1"))
            ],
            "x += 1"
        );
        visitor.collect_return_usage_site_context(&node_opasgn_id, "value", None, None, false);

        let node_else = make_node(
            "ELSE",
            vec![make_child_node(make_node("IDENTIFIER", vec![], "x"))],
            "else x"
        );
        visitor.collect_return_usage_site_context(&node_else, "value", None, None, false);

        // 7. classify_origin variants
        let param_names = std::collections::BTreeSet::from(["my_param".to_string()]);
        let mut assigns = std::collections::BTreeMap::new();
        
        let node_rhs = make_node("INTEGER", vec![], "42");
        assigns.insert("x".to_string(), &node_rhs);
        let node_lvar = make_node("LVAR", vec![], "x");
        let res1 = visitor.classify_origin(&node_lvar, &param_names, &assigns, 0);
        assert_eq!(res1.0, "local");
        
        let node_call_index = make_node(
            "CALL",
            vec![
                make_child_node(make_node("IDENTIFIER", vec![], "my_hash")),
                make_symbol("[]"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("SYMBOL", vec![], ":key"))],
                    ":key"
                ))
            ],
            "my_hash[:key]"
        );
        let res2 = visitor.classify_origin(&node_call_index, &param_names, &assigns, 0);
        assert_eq!(res2.0, "hashkey");

        let node_call_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("IDENTIFIER", vec![], "obj")),
                make_symbol("foo"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "obj.foo(1)"
        );
        let res3 = visitor.classify_origin(&node_call_args, &param_names, &assigns, 0);
        assert_eq!(res3.0, "call");

        let node_call_no_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("IDENTIFIER", vec![], "obj")),
                make_symbol("bar"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "obj.bar"
        );
        let res4 = visitor.classify_origin(&node_call_no_args, &param_names, &assigns, 0);
        assert_eq!(res4.0, "attr");

        let node_call_fail = make_node("CALL", vec![], "bad_call");
        let res5 = visitor.classify_origin(&node_call_fail, &param_names, &assigns, 0);
        assert_eq!(res5.0, "call");

        // 8. hidden_enum_slot_for
        let record = json!({
            "path": "test.rb",
            "class": "MyClass",
            "kind": "instance",
            "method": "my_method",
            "line": 10
        });
        let params_map = std::collections::BTreeMap::new();
        let node_ivar = make_node("IVAR", vec![], "@x");
        let slot = visitor.hidden_enum_slot_for(&node_ivar, &record, &params_map);
        assert!(slot.is_some());

        // 9. value_in_collection_append_or_index_write
        let col_push = make_node(
            "CALL",
            vec![
                make_child_node(make_node("IDENTIFIER", vec![], "col")),
                make_symbol("push"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("IDENTIFIER", vec![], "target_val"))],
                    "target_val"
                ))
            ],
            "col.push(target_val)"
        );
        let actual_target = child_node(child_node(&col_push, 2).unwrap(), 0).unwrap();
        assert!(visitor.value_in_collection_append_or_index_write(&col_push, actual_target));

        let col_assign = make_node(
            "CALL",
            vec![
                make_child_node(make_node("IDENTIFIER", vec![], "col")),
                make_symbol("[]="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![
                        make_child_node(make_node("INTEGER", vec![], "0")),
                        make_child_node(make_node("IDENTIFIER", vec![], "target_val"))
                    ],
                    "0, target_val"
                ))
            ],
            "col[0] = target_val"
        );
        let actual_target_2 = child_nodes(child_node(&col_assign, 2).unwrap())[1];
        assert!(visitor.value_in_collection_append_or_index_write(&col_assign, actual_target_2));

        let col_opasgn = make_node(
            "OPASGN",
            vec![
                make_child_node(make_node(
                    "element_reference",
                    vec![
                        make_child_node(make_node("IDENTIFIER", vec![], "col")),
                        make_child_node(make_node(
                            "ARGUMENT_LIST",
                            vec![make_child_node(make_node("INTEGER", vec![], "0"))],
                            "0"
                        ))
                    ],
                    "col[0]"
                )),
                make_child_node(make_node("IDENTIFIER", vec![], "target_val"))
            ],
            "col[0] += target_val"
        );
        let actual_target_3 = child_node(&col_opasgn, 1).unwrap();
        assert!(visitor.value_in_collection_append_or_index_write(&col_opasgn, actual_target_3));

        // 10. hash_record_escapes recursive check
        visitor.current_method = Some("my_method".to_string());
        let root_node = make_node(
            "CALL",
            vec![
                make_child_node(make_node("self", vec![], "self")),
                make_symbol("my_method"),
                make_child_node(make_node(
                    "ARRAY",
                    vec![make_child_node(make_node("LVAR", vec![], "my_var"))],
                    "my_var"
                ))
            ],
            "self.my_method([my_var])"
        );
        assert!(!visitor.escape_uses_of_local(&root_node, "my_var"));

        // 11. array_element_shape_for_value ITER mapping
        let mock_shape = json!({"a": "Integer"});
        visitor.local_array_shapes.insert("my_array".to_string(), mock_shape.clone());
        let iter_node = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![], "my_array")),
                        make_symbol("map"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_array.map"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node(
                        "ARGS",
                        vec![make_child_node(make_node("LVAR", vec![], "x"))],
                        "x"
                    ))],
                    "|x|"
                )),
                make_child_node(make_node(
                    "HASH",
                    vec![make_child_node(make_node(
                        "pair",
                        vec![
                            make_child_node(make_node("SYMBOL", vec![], ":b")),
                            make_child_node(make_node("INTEGER", vec![], "2"))
                        ],
                        ":b => 2"
                    ))],
                    "{:b => 2}"
                ))
            ],
            "my_array.map { |x| {:b => 2} }"
        );
        let res_iter = visitor.array_element_shape_for_value(&iter_node);
        assert!(res_iter.is_some());

        // 12. IF merge (None, Some(e)) branches
        let node_if = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node("NilClass", vec![], "nil")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("else_var"),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    "else_var = 1"
                ))
            ],
            "if true; nil; else; else_var = 1; end"
        );
        visitor.visit(&node_if);
        assert_eq!(visitor.local_types.get("else_var").unwrap(), "T.nilable(Integer)");

        visitor.unconditional_vars.insert("else_var_uncond".to_string());
        let node_if_uncond = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node("NilClass", vec![], "nil")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("else_var_uncond"),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    "else_var_uncond = 1"
                ))
            ],
            "if true; nil; else; else_var_uncond = 1; end"
        );
        visitor.visit(&node_if_uncond);
        assert_eq!(visitor.local_types.get("else_var_uncond").unwrap(), "T.nilable(Integer)");

        // 13. collect_prepass_facts empty owners IASGN
        let mut empty_owners = vec![];
        let mut ivar_tlet_types_empty = std::collections::BTreeMap::new();
        let iasgn_node = make_node(
            "IASGN",
            vec![
                make_symbol("@my_ivar"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("let"),
                        make_child_node(make_node(
                            "ARGUMENT_LIST",
                            vec![
                                make_child_node(make_node("IDENTIFIER", vec![], "val")),
                                make_child_node(make_node("CONST", vec![], "Integer"))
                            ],
                            "val, Integer"
                        ))
                    ],
                    "T.let(val, Integer)"
                ))
            ],
            "@my_ivar = T.let(val, Integer)"
        );
        collect_prepass_facts(&iasgn_node, Language::Ruby, &mut empty_owners, &mut ivar_tlet_types_empty);
        assert!(ivar_tlet_types_empty.is_empty());

        // 14. DEFN with no body
        let defn_no_body = make_node(
            "DEFN",
            vec![make_symbol("my_empty_method")],
            "def my_empty_method; end"
        );
        visitor.visit(&defn_no_body);

        // 15. Empty children for AND, CASE
        let node_and_empty = make_node("AND", vec![], "");
        visitor.visit(&node_and_empty);

        let node_case_empty = make_node("CASE", vec![], "");
        visitor.visit(&node_case_empty);

        // 16. ITER block with no ARGS
        let node_iter_no_args = make_node(
            "ITER",
            vec![
                make_child_node(make_node("CALL", vec![], "foo")),
                make_child_node(make_node("BLOCK", vec![], ""))
            ],
            "foo {}"
        );
        visitor.visit(&node_iter_no_args);

        // 17. Collection iteration zero params or invalid collection types
        visitor.local_types.insert("my_hash_zero".to_string(), "T::Hash[Symbol, Integer]".to_string());
        visitor.local_types.insert("my_array_zero".to_string(), "T::Array[String]".to_string());
        visitor.local_types.insert("my_string_each".to_string(), "String".to_string());

        let iter_hash_zero = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_hash_zero")], "my_hash_zero")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_hash_zero.each"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node("ARGS", vec![], ""))],
                    ""
                ))
            ],
            "my_hash_zero.each {}"
        );
        visitor.visit(&iter_hash_zero);

        let iter_array_zero = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_array_zero")], "my_array_zero")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_array_zero.each"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node("ARGS", vec![], ""))],
                    ""
                ))
            ],
            "my_array_zero.each {}"
        );
        visitor.visit(&iter_array_zero);

        let iter_string = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_string_each")], "my_string_each")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_string_each.each"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node(
                        "ARGS",
                        vec![make_child_node(make_node("LVAR", vec![make_symbol("x")], "x"))],
                        "x"
                    ))],
                    "|x|"
                ))
            ],
            "my_string_each.each { |x| }"
        );
        visitor.visit(&iter_string);

        // 17.5 iteration with untyped collection elements (none type)
        visitor.local_types.insert("my_hash_none".to_string(), "T::Hash".to_string());
        let iter_hash_none = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_hash_none")], "my_hash_none")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_hash_none.each"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node(
                        "ARGS",
                        vec![
                            make_child_node(make_node("LVAR", vec![make_symbol("k")], "k")),
                            make_child_node(make_node("LVAR", vec![make_symbol("v")], "v"))
                        ],
                        "k, v"
                    ))],
                    "|k, v|"
                ))
            ],
            "my_hash_none.each { |k, v| }"
        );
        visitor.visit(&iter_hash_none);

        visitor.local_types.insert("my_array_none".to_string(), "T::Array".to_string());
        let iter_array_none = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_array_none")], "my_array_none")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_array_none.each"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node(
                        "ARGS",
                        vec![make_child_node(make_node("LVAR", vec![make_symbol("x")], "x"))],
                        "x"
                    ))],
                    "|x|"
                ))
            ],
            "my_array_none.each { |x| }"
        );
        visitor.visit(&iter_array_none);

        // 18. CALL parameter type update (merge!)
        visitor.param_types.insert("my_param_hash".to_string(), "T::Hash[Symbol, Integer]".to_string());
        visitor.local_types.insert("other_hash".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let node_merge_param = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_param_hash")], "my_param_hash")),
                make_symbol("merge!"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("other_hash")], "other_hash"))],
                    "other_hash"
                ))
            ],
            "my_param_hash.merge!(other_hash)"
        );
        visitor.visit(&node_merge_param);
        assert_eq!(visitor.param_types.get("my_param_hash").unwrap(), "T::Hash[Symbol, Integer]");

        // 19. CALL push edge cases
        visitor.local_types.insert("push_no_args".to_string(), "T::Array[String]".to_string());
        let node_push_no_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("push_no_args")], "push_no_args")),
                make_symbol("push"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "push_no_args.push"
        );
        visitor.visit(&node_push_no_args);

        let node_push_no_type = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("push_no_type")], "push_no_type")),
                make_symbol("push"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "push_no_type.push(1)"
        );
        visitor.visit(&node_push_no_type);

        visitor.local_types.insert("push_non_col".to_string(), "String".to_string());
        let node_push_non_col = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("push_non_col")], "push_non_col")),
                make_symbol("push"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "push_non_col.push(1)"
        );
        visitor.visit(&node_push_non_col);

        visitor.local_types.insert("push_hash".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let node_push_hash = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("push_hash")], "push_hash")),
                make_symbol("push"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "push_hash.push(1)"
        );
        visitor.visit(&node_push_hash);

        // 20. CALL []= edge cases
        visitor.local_types.insert("bracket_few_args".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let node_bracket_few_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("bracket_few_args")], "bracket_few_args")),
                make_symbol("[]="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "bracket_few_args[1]"
        );
        visitor.visit(&node_bracket_few_args);

        visitor.local_types.insert("bracket_non_col".to_string(), "String".to_string());
        let node_bracket_non_col = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("bracket_non_col")], "bracket_non_col")),
                make_symbol("[]="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![
                        make_child_node(make_node("INTEGER", vec![], "1")),
                        make_child_node(make_node("INTEGER", vec![], "2"))
                    ],
                    "1, 2"
                ))
            ],
            "bracket_non_col[1] = 2"
        );
        visitor.visit(&node_bracket_non_col);

        // 21. CALL merge! edge cases
        visitor.local_types.insert("merge_no_args".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let node_merge_no_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("merge_no_args")], "merge_no_args")),
                make_symbol("merge!"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "merge_no_args.merge!"
        );
        visitor.visit(&node_merge_no_args);

        visitor.local_types.insert("merge_arg_non_hash".to_string(), "T::Hash[Symbol, Integer]".to_string());
        visitor.local_types.insert("non_hash_arg".to_string(), "String".to_string());
        let node_merge_arg_non_hash = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("merge_arg_non_hash")], "merge_arg_non_hash")),
                make_symbol("merge!"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("non_hash_arg")], "non_hash_arg"))],
                    "non_hash_arg"
                ))
            ],
            "merge_arg_non_hash.merge!(non_hash_arg)"
        );
        visitor.visit(&node_merge_arg_non_hash);

        let node_merge_no_type = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("merge_no_type")], "merge_no_type")),
                make_symbol("merge!"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("other_hash")], "other_hash"))],
                    "other_hash"
                ))
            ],
            "merge_no_type.merge!(other_hash)"
        );
        visitor.visit(&node_merge_no_type);

        visitor.local_types.insert("merge_non_col".to_string(), "String".to_string());
        let node_merge_non_col = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("merge_non_col")], "merge_non_col")),
                make_symbol("merge!"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("other_hash")], "other_hash"))],
                    "other_hash"
                ))
            ],
            "merge_non_col.merge!(other_hash)"
        );
        visitor.visit(&node_merge_non_col);

        // 22. merge! where receiver is Array (not Hash)
        visitor.local_types.insert("merge_rec_array".to_string(), "T::Array[Integer]".to_string());
        let node_merge_rec_array = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("merge_rec_array")], "merge_rec_array")),
                make_symbol("merge!"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("other_hash")], "other_hash"))],
                    "other_hash"
                ))
            ],
            "merge_rec_array.merge!(other_hash)"
        );
        visitor.visit(&node_merge_rec_array);

        // 23. merge! where argument is Array (not Hash)
        visitor.local_types.insert("some_array".to_string(), "T::Array[Integer]".to_string());
        let node_merge_arg_array = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("merge_no_args")], "merge_no_args")),
                make_symbol("merge!"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("some_array")], "some_array"))],
                    "some_array"
                ))
            ],
            "merge_no_args.merge!(some_array)"
        );
        visitor.visit(&node_merge_arg_array);

        // 24. LASGN with no RHS value
        let lasgn_no_val = make_node(
            "LASGN",
            vec![make_symbol("x")],
            "x ="
        );
        visitor.visit(&lasgn_no_val);

        // 25. nil? call with no type
        let node_nil_check = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("x")], "x")),
                make_symbol("nil?"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "x.nil?"
        );
        visitor.visit(&node_nil_check);

        // 26. nil? call with non-nil type (dead check)
        visitor.local_types.insert("y".to_string(), "Integer".to_string());
        let node_nil_check_dead = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("y")], "y")),
                make_symbol("nil?"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "y.nil?"
        );
        visitor.visit(&node_nil_check_dead);

        // 27. qualified prepass nested owner when current_owners is not empty
        let mut nested_owners = vec!["Outer".to_string()];
        let mut nested_ivar_types = std::collections::BTreeMap::new();
        collect_prepass_facts(&class_node, Language::Ruby, &mut nested_owners, &mut nested_ivar_types);

        // 28. prepass IASGN where T.let has no second argument
        let iasgn_no_type_arg = make_node(
            "IASGN",
            vec![
                make_symbol("@my_ivar"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("let"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![make_child_node(make_node("IDENTIFIER", vec![], "val"))], "val"))
                    ],
                    "T.let(val)"
                ))
            ],
            "@my_ivar = T.let(val)"
        );
        let mut owners_tmp = vec!["MyClass".to_string()];
        collect_prepass_facts(&iasgn_no_type_arg, Language::Ruby, &mut owners_tmp, &mut nested_ivar_types);

        // 29. prepass IASGN where type is empty or T.untyped
        let iasgn_untyped = make_node(
            "IASGN",
            vec![
                make_symbol("@my_ivar"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("let"),
                        make_child_node(make_node(
                            "ARGUMENT_LIST",
                            vec![
                                make_child_node(make_node("IDENTIFIER", vec![], "val")),
                                make_child_node(make_node("CONST", vec![], "T.untyped"))
                            ],
                            "val, T.untyped"
                        ))
                    ],
                    "T.let(val, T.untyped)"
                ))
            ],
            "@my_ivar = T.let(val, T.untyped)"
        );
        collect_prepass_facts(&iasgn_untyped, Language::Ruby, &mut owners_tmp, &mut nested_ivar_types);

        // 30. collect_explicit_returns with bare RETURN node
        let bare_return_node = make_node("RETURN", vec![], "return");
        let mut returns_vec = Vec::new();
        collect_explicit_returns(&bare_return_node, &mut returns_vec);
        assert_eq!(returns_vec.len(), 1);

        // 31. return_syntax direct test
        assert_eq!(return_syntax(false, true), "mixed");

        // 32. static_sorbet_type edge cases
        // - starts_with T.nilable( but ends with unmatched paren to hit line 72 in strip_nilable_type
        assert_eq!(strip_nilable_type("T.nilable(foo(bar)"), "T.nilable(foo(bar)");
        assert_eq!(strip_nilable_type("T.nilable(Int)"), "Int");
        // - static_sorbet_type has_nil but no others to hit line 126
        assert_eq!(static_sorbet_type(&["NilClass".to_string()]), "NilClass");
        // - static_sorbet_type others.len() > 1 to hit line 139 and 142
        assert_eq!(static_sorbet_type(&["Integer".to_string(), "String".to_string()]), "T.untyped");

        // 33. visit CLASS/MODULE qualified name when current_owners is not empty to hit line 486
        visitor.current_owners = vec!["Outer".to_string()];
        let module_node = make_node(
            "MODULE",
            vec![make_symbol("Inner")],
            "module Inner; end"
        );
        visitor.visit(&module_node);
        visitor.current_owners.clear();

        // 34. declarative owner casing to hit line 1131, 1132, 1187
        let casgn_struct = make_node(
            "CASGN",
            vec![
                make_symbol("MyStruct"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "Struct")),
                        make_symbol("new"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "Struct.new"
                ))
            ],
            "MyStruct = Struct.new"
        );
        visitor.visit(&casgn_struct);

        // 35. local / param type updates on Set receiver, param types check, concat call
        // Set receiver, is param, update_type format_set_type (line 1051, 1056)
        visitor.param_types.insert("my_set_param".to_string(), "T::Set[Integer]".to_string());
        let node_set_push = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_set_param")], "my_set_param")),
                make_symbol("<<"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "my_set_param << 1"
        );
        visitor.visit(&node_set_push);

        // concat method call (line 1044)
        visitor.local_types.insert("my_arr_local".to_string(), "T::Array[Integer]".to_string());
        visitor.local_types.insert("other_arr_local".to_string(), "T::Array[String]".to_string());
        let node_concat = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_arr_local")], "my_arr_local")),
                make_symbol("concat"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("other_arr_local")], "other_arr_local"))],
                    "other_arr_local"
                ))
            ],
            "my_arr_local.concat(other_arr_local)"
        );
        visitor.visit(&node_concat);

        // append method where argument is a hash literal to hit line 1034
        visitor.local_types.insert("my_arr_for_hash".to_string(), "T::Array[T.untyped]".to_string());
        let node_push_hash_lit = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_arr_for_hash")], "my_arr_for_hash")),
                make_symbol("push"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node(
                        "HASH",
                        vec![make_child_node(make_node(
                            "pair",
                            vec![
                                make_child_node(make_node("SYMBOL", vec![], ":a")),
                                make_child_node(make_node("INTEGER", vec![], "1"))
                            ],
                            ":a => 1"
                        ))],
                        "{:a => 1}"
                    ))],
                    "{:a => 1}"
                ))
            ],
            "my_arr_for_hash.push({:a => 1})"
        );
        visitor.visit(&node_push_hash_lit);

        // 36. []= method where receiver is in param_types to hit line 1082, 1086, 1088
        visitor.param_types.insert("my_hash_param".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let node_hash_assign = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_hash_param")], "my_hash_param")),
                make_symbol("[]="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![
                        make_child_node(make_node("SYMBOL", vec![], ":b")),
                        make_child_node(make_node("INTEGER", vec![], "2"))
                    ],
                    ":b, 2"
                ))
            ],
            "my_hash_param[:b] = 2"
        );
        visitor.visit(&node_hash_assign);

        // 37. conditional assignment with existing T.nilable( to hit line 1155
        visitor.local_types.insert("cond_var".to_string(), "T.nilable(Integer)".to_string());
        let node_cond_assign = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("cond_var"),
                        make_child_node(make_node("INTEGER", vec![], "2"))
                    ],
                    "cond_var = 2"
                )),
                crate::ast::Child::Nil
            ],
            "if true; cond_var = 2; end"
        );
        visitor.visit(&node_cond_assign);

        // 38. conditional assignment where a variable has a hash/array shape in both branches (merging) to hit line 847-851 and 859-865
        let node_cond_shapes = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("shape_var"),
                        make_child_node(make_node(
                            "HASH",
                            vec![make_child_node(make_node(
                                "pair",
                                vec![
                                    make_child_node(make_node("SYMBOL", vec![], ":a")),
                                    make_child_node(make_node("INTEGER", vec![], "1"))
                                ],
                                ":a => 1"
                            ))],
                            "{:a => 1}"
                        ))
                    ],
                    "shape_var = {:a => 1}"
                )),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("shape_var"),
                        make_child_node(make_node(
                            "HASH",
                            vec![make_child_node(make_node(
                                "pair",
                                vec![
                                    make_child_node(make_node("SYMBOL", vec![], ":b")),
                                    make_child_node(make_node("INTEGER", vec![], "2"))
                                ],
                                ":b => 2"
                            ))],
                            "{:b => 2}"
                        ))
                    ],
                    "shape_var = {:b => 2}"
                ))
            ],
            "if true; shape_var = {:a => 1}; else; shape_var = {:b => 2}; end"
        );
        visitor.visit(&node_cond_shapes);

        // 39. (Some(t), None) path of conditional merge to hit line 826
        let node_cond_some_none = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("some_none_var"),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    "some_none_var = 1"
                )),
                crate::ast::Child::Nil
            ],
            "if true; some_none_var = 1; end"
        );
        visitor.visit(&node_cond_some_none);

        // 40. shadow hash / array / container origin parameter restore to hit line 1000 and 1010
        // We set receiver origin and shape for "a"
        visitor.local_container_origins.insert("a".to_string(), json!({
            "kind": "method parameter",
            "name": "a",
            "path": "test.rb",
            "line": 1
        }));
        visitor.local_hash_shapes.insert("elem".to_string(), json!({"keys": {}}));
        visitor.local_container_origins.insert("elem".to_string(), json!({"kind": "method parameter"}));
        // visiting iter_arr (receiver "a", param "elem") will shadow elem, and then restore it.
        // It also checks receiver shape lookup to hit line 977 and container origin to hit line 982.
        visitor.visit(&iter_arr);

        // 41. ITER block with no block_node to hit line 921
        let iter_no_block = make_node(
            "ITER",
            vec![make_child_node(make_node("CALL", vec![], "foo"))],
            "foo"
        );
        visitor.visit(&iter_no_block);

        // 42. hash_shape_index_type_readonly keys only untyped to hit line 1719
        let hash_idx_recv_untyped = make_node("LVAR", vec![make_symbol("h_idx_untyped")], "h_idx_untyped");
        visitor.local_hash_shapes.insert("h_idx_untyped".to_string(), json!({"keys": {"a": ["T.untyped"]}}));
        assert_eq!(visitor.hash_shape_index_type_readonly(&hash_idx_recv_untyped, &hash_idx_key), None);

        // 43. hash_shape_for_value_readonly pair with exactly 1 child to hit line 1748
        let hash_pair_1_child = make_node(
            "HASH",
            vec![make_child_node(make_node(
                "pair",
                vec![make_child_node(make_node("SYMBOL", vec![], ":a"))],
                ":a =>"
            ))],
            "{:a =>}"
        );
        let _ = visitor.hash_shape_for_value(&hash_pair_1_child);

        // 44. hash_shape_for_value_readonly untyped value to hit line 1758 and 1777
        let hash_untyped_val = make_node(
            "HASH",
            vec![make_child_node(make_node(
                "pair",
                vec![
                    make_child_node(make_node("SYMBOL", vec![], ":a")),
                    make_child_node(make_node("LVAR", vec![make_symbol("untyped_val")], "untyped_val"))
                ],
                ":a => untyped_val"
            ))],
            "{:a => untyped_val}"
        );
        let _ = visitor.hash_shape_for_value(&hash_untyped_val);

        // 45. hash_shape_for_value_readonly non-static key to hit line 1781
        let hash_non_static_key = make_node(
            "HASH",
            vec![make_child_node(make_node(
                "pair",
                vec![
                    make_child_node(make_node("LVAR", vec![make_symbol("x")], "x")),
                    make_child_node(make_node("INTEGER", vec![], "1"))
                ],
                "x => 1"
            ))],
            "{x => 1}"
        );
        let _ = visitor.hash_shape_for_value(&hash_non_static_key);

        // 46. hash_shape_for_value_readonly call fallbacks for VCALL to hit line 1816
        let fcall_node = make_node("FCALL", vec![make_symbol("foo")], "foo()");
        assert_eq!(visitor.hash_shape_for_value(&fcall_node), None);

        // 47. hash_shape_for_value_readonly get_call_info None to hit line 1819
        let call_node_invalid = make_node("CALL", vec![], "invalid");
        assert_eq!(visitor.hash_shape_for_value(&call_node_invalid), None);

        // 48. array_element_shape_for_value_readonly cast / normalizer to hit lines 1863-1866
        let cast_node = make_node(
            "CALL",
            vec![
                make_child_node(make_node("CONST", vec![], "T")),
                make_symbol("cast"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_arr")], "my_arr")),
                        make_child_node(make_node("CONST", vec![], "Array"))
                    ],
                    "my_arr, Array"
                ))
            ],
            "T.cast(my_arr, Array)"
        );
        let _ = visitor.array_element_shape_for_value(&cast_node);

        // 49. array_element_shape_for_value_readonly method return shape / fallback to hit 1872, 1877
        visitor.method_return_array_shapes.insert(("".to_string(), "my_arr_method".to_string()), json!({"keys": {}}));
        let call_arr_shape = make_node(
            "CALL",
            vec![
                make_child_node(make_node("self", vec![], "self")),
                make_symbol("my_arr_method"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "my_arr_method"
        );
        let _ = visitor.array_element_shape_for_value(&call_arr_shape);

        // 50. array_element_shape_for_value_readonly ITER None path to hit 1909, 1910
        let map_iter_node_no_shape: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "no_shape"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":7, "text":"no_shape"}},
                        {"Symbol": "map"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "no_shape.map"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "item"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"item"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 6, "text": "item"
                        }},
                        {"Node": {"type": "HASH", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{}"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "no_shape.map { |item| {} }"
        }"#).unwrap();
        let _ = visitor.array_element_shape_for_value(&map_iter_node_no_shape);

        // 51. array_element_shape_for_value_readonly ITER else branches to hit 1919, 1922, 1925
        let iter_each_node = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_arr")], "my_arr")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_arr.each"
                )),
                make_child_node(make_node("BLOCK", vec![], ""))
            ],
            "my_arr.each {}"
        );
        let _ = visitor.array_element_shape_for_value(&iter_each_node);

        let iter_bad_call = make_node(
            "ITER",
            vec![
                make_child_node(make_node("CALL", vec![], "bad_call")),
                make_child_node(make_node("BLOCK", vec![], ""))
            ],
            "bad_call {}"
        );
        let _ = visitor.array_element_shape_for_value(&iter_bad_call);

        let iter_no_call = make_node(
            "ITER",
            vec![],
            "{}"
        );
        let _ = visitor.array_element_shape_for_value(&iter_no_call);

        // 52. array_element_shape_for_receiver_readonly ITER cases to hit 1941-1945 and 1949
        let iter_map_rec = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_arr")], "my_arr")),
                        make_symbol("map"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_arr.map"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![
                        make_child_node(make_node("ARGS", vec![], "")),
                        make_child_node(make_node("HASH", vec![], "{}"))
                    ],
                    ""
                ))
            ],
            "my_arr.map {}"
        );
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&iter_map_rec), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&iter_each_node), &extra_hash_shapes);

        // 53. array_element_shape_for_receiver_readonly CALL cases to hit 1966-1969, 1972-1973, 1975-1976, 1980, 1983, 1986
        let select_call = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_arr")], "my_arr")),
                make_symbol("select"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "my_arr.select"
        );
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&select_call), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&cast_node), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&call_arr_shape), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&fcall_node), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&call_node_invalid), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&true_node), &extra_hash_shapes);

        // 54. array_element_shape_for_value_readonly empty array to hit 1846
        let arr_empty_node = make_node("ARRAY", vec![], "[]");
        let _ = visitor.array_element_shape_for_value(&arr_empty_node);

        // 55. deterministic_class_predicate_result / class_guard_truth edge cases to hit 1346, 1347, 1415, 1466, 1473, 1474
        // valid class guard returning Some
        visitor.local_types.insert("guard_x".to_string(), "Integer".to_string());
        let class_guard_node = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("guard_x")], "guard_x")),
                make_symbol("is_a?"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("CONST", vec![], "Integer"))],
                    "Integer"
                ))
            ],
            "guard_x.is_a?(Integer)"
        );
        assert!(visitor.deterministic_predicate_result(&class_guard_node).is_some());

        // comparison node returning Some
        let comp_node = make_node(
            "CALL",
            vec![
                make_child_node(make_node("INTEGER", vec![], "1")),
                make_symbol("=="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "2"))],
                    "2"
                ))
            ],
            "1 == 2"
        );
        assert!(visitor.deterministic_predicate_result(&comp_node).is_some());

        // not type guard to hit 1415
        let non_type_guard_node = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("guard_x")], "guard_x")),
                make_symbol("foo"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("CONST", vec![], "Integer"))],
                    "Integer"
                ))
            ],
            "guard_x.foo(Integer)"
        );
        assert!(visitor.deterministic_class_predicate_result(&non_type_guard_node).is_none());

        // class_guard_truth edge cases
        assert_eq!(visitor.class_guard_truth("Integer", "Integer", true), None); // exact true disjoint false -> 1466
        assert_eq!(visitor.class_guard_truth("Integer", "String", false), Some(false)); // disjoint true -> 1473
        assert_eq!(visitor.class_guard_truth("MyClass", "OtherClass", false), None); // disjoint false -> 1474

        // 56. deterministic_literal_comparison_result edge cases to hit 1526, 1531, 1534-1538
        let comp_bad_method = make_node(
            "CALL",
            vec![
                make_child_node(make_node("INTEGER", vec![], "1")),
                make_symbol("foo"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "2"))],
                    "2"
                ))
            ],
            "1.foo(2)"
        );
        assert!(visitor.deterministic_literal_comparison_result(&comp_bad_method).is_none());

        let comp_bad_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("INTEGER", vec![], "1")),
                make_symbol("=="),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "1 =="
        );
        assert!(visitor.deterministic_literal_comparison_result(&comp_bad_args).is_none());

        let comp_unknown = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("unknown_var")], "unknown_var")),
                make_symbol("=="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "2"))],
                    "2"
                ))
            ],
            "unknown_var == 2"
        );
        assert!(visitor.deterministic_literal_comparison_result(&comp_unknown).is_none());

        // 57. deterministic_guard_subject_type IVAR, fallback to static_expression_type to hit 1561-1563, 1565
        visitor.current_owners = vec!["MyClass".to_string()];
        visitor.ivar_tlet_types.insert(("MyClass".to_string(), "@my_ivar".to_string()), "String".to_string());
        let ivar_node = make_node("IVAR", vec![make_symbol("@my_ivar")], "@my_ivar");
        assert_eq!(visitor.deterministic_guard_subject_type(&ivar_node), Some("String".to_string()));
        assert_eq!(visitor.deterministic_guard_subject_type(&true_node), Some("T::Boolean".to_string()));

        // 58. literal_static_value for fallback nodes to hit 1587-1596
        let node_int = make_node("INTEGER", vec![], "123");
        assert!(matches!(visitor.literal_static_value(&node_int), LiteralStaticValue::Integer(123)));
        let node_float = make_node("FLOAT", vec![], "1.23");
        assert!(matches!(visitor.literal_static_value(&node_float), LiteralStaticValue::Float(_)));
        let node_true = make_node("TRUE", vec![], "true");
        assert!(matches!(visitor.literal_static_value(&node_true), LiteralStaticValue::Bool(true)));
        let node_false = make_node("FALSE", vec![], "false");
        assert!(matches!(visitor.literal_static_value(&node_false), LiteralStaticValue::Bool(false)));
        let node_nil = make_node("NIL", vec![], "nil");
        assert!(matches!(visitor.literal_static_value(&node_nil), LiteralStaticValue::Nil));
        let node_other_val = make_node("OTHER", vec![], "other");
        assert!(matches!(visitor.literal_static_value(&node_other_val), LiteralStaticValue::Unknown));

        // 59. method matched but has no body / return type confidence is weak to hit 662
        // We define a FunctionDef and its corresponding method in method_param_types,
        // and visit a DEFN node whose body is empty or returns something that triggers weak confidence
        let doc_json_weak = r#"{
            "file": "test.rb",
            "language": "ruby",
            "function_defs": [
                {
                    "file": "test.rb",
                    "name": "my_empty_method",
                    "owner": "MyClass",
                    "line": 1,
                    "span": [1, 1, 5, 5],
                    "body": {
                        "kind": "body",
                        "text": "",
                        "span": [1, 1, 5, 5],
                        "named": true,
                        "field_name": null,
                        "children": []
                    },
                    "visibility": "public",
                    "params": [],
                    "signature": ""
                },
                {
                    "file": "test.rb",
                    "name": "my_weak_method",
                    "owner": "MyClass",
                    "line": 1,
                    "span": [1, 1, 5, 5],
                    "body": {
                        "kind": "body",
                        "text": "",
                        "span": [1, 1, 5, 5],
                        "named": true,
                        "field_name": null,
                        "children": []
                    },
                    "visibility": "public",
                    "params": ["x"],
                    "signature": ""
                },
                {
                    "file": "test.rb",
                    "name": "my_top_method",
                    "owner": "",
                    "line": 1,
                    "span": [1, 1, 5, 5],
                    "body": {
                        "kind": "body",
                        "text": "",
                        "span": [1, 1, 5, 5],
                        "named": true,
                        "field_name": null,
                        "children": []
                    },
                    "visibility": "public",
                    "params": [],
                    "signature": ""
                },
                {
                    "file": "test.rb",
                    "name": "my_qcall_untyped",
                    "owner": "MyClass",
                    "line": 1,
                    "span": [1, 1, 5, 5],
                    "body": {
                        "kind": "body",
                        "text": "",
                        "span": [1, 1, 5, 5],
                        "named": true,
                        "field_name": null,
                        "children": []
                    },
                    "visibility": "public",
                    "params": [],
                    "signature": ""
                }
            ]
        }"#;
        let doc_weak: Document = serde_json::from_str(doc_json_weak).unwrap();
        let mut tlet_sites_weak = Vec::new();
        let mut dead_nil_checks_weak = Vec::new();
        let mut deterministic_guards_weak = Vec::new();
        let mut return_origins_weak = Vec::new();
        let mut noreturn_methods_weak = Vec::new();
        let mut collection_index_lookups_weak = Vec::new();
        let mut hash_record_blockers_weak = Vec::new();
        let mut type_normalizers_weak = Vec::new();
        let mut rescue_handlers_weak = Vec::new();
        let mut return_usage_sites_weak = Vec::new();
        let mut return_direct_usage_sites_weak = Vec::new();
        let mut hash_record_escape_sites_weak = Vec::new();
        let mut hidden_enum_observations_weak = Vec::new();
        let mut dispatcher_inferences_weak = Vec::new();
        let mut hash_record_member_calls_weak = Vec::new();
        let mut param_origins_weak = Vec::new();
        let mut struct_declarations_weak = Vec::new();
        let mut state_type_records_weak = Vec::new();
        let mut hash_shapes_weak = Vec::new();
        let mut tuple_arrays_weak = Vec::new();
        let mut visitor_weak = create_visitor(
            &doc_weak,
            &lines,
            &mut tlet_sites_weak,
            &mut dead_nil_checks_weak,
            &mut deterministic_guards_weak,
            &mut return_origins_weak,
            &mut noreturn_methods_weak,
            &mut collection_index_lookups_weak,
            &mut hash_record_blockers_weak,
            &mut type_normalizers_weak,
            &mut rescue_handlers_weak,
            &mut return_usage_sites_weak,
            &mut return_direct_usage_sites_weak,
            &mut hash_record_escape_sites_weak,
            &mut hidden_enum_observations_weak,
            &mut dispatcher_inferences_weak,
            &mut hash_record_member_calls_weak,
            &mut param_origins_weak,
            &mut struct_declarations_weak,
            &mut state_type_records_weak,
            &mut hash_shapes_weak,
            &mut tuple_arrays_weak,
            &pre_registered_noreturns,
        );
        visitor_weak.method_param_hash_shapes.insert(
            ("MyClass".to_string(), "my_weak_method".to_string(), "x".to_string()),
            json!({"keys": {}})
        );
        visitor_weak.method_param_array_shapes.insert(
            ("MyClass".to_string(), "my_weak_method".to_string(), "x".to_string()),
            json!({"keys": {}})
        );
        visitor_weak.current_owners = vec!["MyClass".to_string()];

        // empty body -> expressions empty -> blockers has "no return expression found" -> line 628
        let defn_empty_matched = make_node(
            "DEFN",
            vec![make_symbol("my_empty_method")],
            "def my_empty_method; end"
        );
        visitor_weak.visit(&defn_empty_matched);

        // weak method: returns untyped ivar + 1 -> candidate is "Integer" (useful), blockers is not empty -> confidence is "weak" -> line 662
        let defn_weak_matched = make_node(
            "DEFN",
            vec![
                make_symbol("my_weak_method"),
                make_child_node(make_node(
                    "BLOCK",
                    vec![
                        make_child_node(make_node(
                            "RETURN",
                            vec![make_child_node(make_node("IVAR", vec![], "@untyped_ivar"))],
                            "return @untyped_ivar"
                        )),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    "return @untyped_ivar; 1"
                ))
            ],
            "def my_weak_method; return @untyped_ivar; 1; end"
        );
        visitor_weak.visit(&defn_weak_matched);

        // top method: owner is empty -> line 540
        let defn_top_method = make_node(
            "DEFN",
            vec![make_symbol("my_top_method")],
            "def my_top_method; end"
        );
        visitor_weak.current_owners.clear();
        visitor_weak.visit(&defn_top_method);
        visitor_weak.current_owners = vec!["MyClass".to_string()];

        // DEFN with no children -> line 748
        let defn_no_name = make_node("DEFN", vec![], "");
        visitor_weak.visit(&defn_no_name);

        // qcall untyped: returns x?.foo -> sources has "call_untyped" -> candidate becomes "T.untyped" -> line 642, 649
        let defn_qcall_untyped = make_node(
            "DEFN",
            vec![
                make_symbol("my_qcall_untyped"),
                make_child_node(make_node(
                    "QCALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("x")], "x")),
                        make_symbol("foo"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "x?.foo"
                ))
            ],
            "def my_qcall_untyped; x?.foo; end"
        );
        visitor_weak.visit(&defn_qcall_untyped);

        // --- Extra coverage additions ---

        // 60. []= on a receiver variable with no type to hit line 1088
        let node_bracket_no_type_rec = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("no_type_var")], "no_type_var")),
                make_symbol("[]="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![
                        make_child_node(make_node("SYMBOL", vec![], ":b")),
                        make_child_node(make_node("INTEGER", vec![], "2"))
                    ],
                    ":b, 2"
                ))
            ],
            "no_type_var[:b] = 2"
        );
        visitor.visit(&node_bracket_no_type_rec);

        // 61. x = T.let(val) with no type argument to hit line 1145
        let node_tlet_no_type = make_node(
            "LASGN",
            vec![
                make_symbol("tlet_no_type_var"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("let"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![make_child_node(make_node("IDENTIFIER", vec![], "val"))], "val"))
                    ],
                    "T.let(val)"
                ))
            ],
            "tlet_no_type_var = T.let(val)"
        );
        visitor.visit(&node_tlet_no_type);
        assert_eq!(visitor.local_types.get("tlet_no_type_var"), None);

        // x = obj.foo assignment (not T.let) to cover the false path of method == "let" && receiver.text == "T"
        let node_call_assign = make_node(
            "LASGN",
            vec![
                make_symbol("call_assign_var"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![], "obj")),
                        make_symbol("foo"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "obj.foo"
                ))
            ],
            "call_assign_var = obj.foo"
        );
        visitor.visit(&node_call_assign);

        // 62. conditional assignment with nilable resolved type to hit line 1155
        let node_cond_assign_nilable = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("cond_var_nilable"),
                        make_child_node(make_node(
                            "CALL",
                            vec![
                                make_child_node(make_node("CONST", vec![], "T")),
                                make_symbol("let"),
                                make_child_node(make_node(
                                    "ARGUMENT_LIST",
                                    vec![
                                        make_child_node(make_node("IDENTIFIER", vec![], "val")),
                                        make_child_node(make_node("CONST", vec![], "T.nilable(Integer)"))
                                    ],
                                    "val, T.nilable(Integer)"
                                ))
                            ],
                            "T.let(val, T.nilable(Integer))"
                        ))
                    ],
                    "cond_var_nilable = T.let(val, T.nilable(Integer))"
                )),
                crate::ast::Child::Nil
            ],
            "if true; cond_var_nilable = T.let(val, T.nilable(Integer)); end"
        );
        visitor.visit(&node_cond_assign_nilable);

        // 63. conditional assignment with untyped resolved type to hit line 1168
        let node_untyped_assign = make_node(
            "LASGN",
            vec![
                make_symbol("untyped_assign_var"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("let"),
                        make_child_node(make_node(
                            "ARGUMENT_LIST",
                            vec![
                                make_child_node(make_node("IDENTIFIER", vec![], "val")),
                                make_child_node(make_node("CONST", vec![], "T.untyped"))
                            ],
                            "val, T.untyped"
                        ))
                    ],
                    "T.let(val, T.untyped)"
                ))
            ],
            "untyped_assign_var = T.let(val, T.untyped)"
        );
        visitor.visit(&node_untyped_assign);

        // 64. LASGN/DASGN nodes with empty symbol names to hit line 1171
        let lasgn_no_symbol = make_node("LASGN", vec![], "");
        visitor.visit(&lasgn_no_symbol);

        // 65. provably_non_nil on an LVAR node with no symbol child to hit line 1281
        let lvar_no_sym = make_node("LVAR", vec![], "");
        assert!(!visitor.provably_non_nil(&lvar_no_sym));

        // 66. provably_non_nil on a fallback node to hit line 1286
        let fallback_node = make_node("FOO", vec![], "");
        assert!(!visitor.provably_non_nil(&fallback_node));

        // 67. Insert "some_none_var" into visitor.unconditional_vars before visiting node_cond_some_none to hit line 826
        visitor.local_types.remove("some_none_var");
        visitor.unconditional_vars.insert("some_none_var".to_string());
        visitor.visit(&node_cond_some_none);

        // 68. Visit an UNLESS node to hit line 870
        let node_unless = make_node(
            "UNLESS",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("unless_var"),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    "unless_var = 1"
                )),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("unless_var"),
                        make_child_node(make_node("INTEGER", vec![], "2"))
                    ],
                    "unless_var = 2"
                ))
            ],
            "unless true; unless_var = 1; else; unless_var = 2; end"
        );
        visitor.visit(&node_unless);

        let node_if_empty = make_node("IF", vec![], "");
        visitor.visit(&node_if_empty);

        // []= on a receiver variable with an Array type to hit line 1086
        visitor.local_types.insert("bracket_arr_rec".to_string(), "T::Array[Integer]".to_string());
        let node_bracket_arr_rec = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("bracket_arr_rec")], "bracket_arr_rec")),
                make_symbol("[]="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![
                        make_child_node(make_node("INTEGER", vec![], "0")),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    "0, 1"
                ))
            ],
            "bracket_arr_rec[0] = 1"
        );
        visitor.visit(&node_bracket_arr_rec);

        // 69. Insert "a" into visitor.local_array_shapes before visitor.visit(&iter_arr) to hit line 977
        visitor.local_array_shapes.insert("a".to_string(), json!({"keys": {}}));
        visitor.visit(&iter_arr);

        // 70. Visit iter_no_call using the main visitor to hit line 988
        let iter_no_call = make_node("ITER", vec![], "{}");
        visitor.visit(&iter_no_call);

        // 71. Call read-only shape functions to cover lines 1745, 1755, 1773, 1777, etc.
        let _ = visitor.hash_shape_for_value_readonly(&hash_pair_1_child, &extra_hash_shapes);
        let _ = visitor.hash_shape_for_value_readonly(&hash_untyped_val, &extra_hash_shapes);
        let _ = visitor.hash_shape_for_value_readonly(&hash_non_static_key, &extra_hash_shapes);
        let _ = visitor.hash_shape_for_value_readonly(&fcall_node, &extra_hash_shapes);
        let _ = visitor.hash_shape_for_value_readonly(&call_node_invalid, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&cast_node, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&call_arr_shape, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&map_iter_node_no_shape, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&iter_each_node, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&iter_bad_call, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&iter_no_call, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&arr_empty_node, &extra_hash_shapes);

        let _ = visitor.array_element_shape_for_receiver(Some(&iter_map_rec));
        let _ = visitor.array_element_shape_for_receiver(Some(&iter_each_node));
        let _ = visitor.array_element_shape_for_receiver(Some(&select_call));
        let _ = visitor.array_element_shape_for_receiver(Some(&cast_node));
        let _ = visitor.array_element_shape_for_receiver(Some(&call_arr_shape));
        let _ = visitor.array_element_shape_for_receiver(Some(&fcall_node));
        let _ = visitor.array_element_shape_for_receiver(Some(&call_node_invalid));
        let _ = visitor.array_element_shape_for_receiver(Some(&true_node));

        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&iter_map_rec), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&iter_each_node), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&select_call), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&cast_node), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&call_arr_shape), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&fcall_node), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&call_node_invalid), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&true_node), &extra_hash_shapes);

        // 72. LVAR has local hash shape but no type in expression_type_with_locals_and_shapes to hit line 2039
        visitor.local_hash_shapes.insert("no_type_hash".to_string(), json!({"keys": {}}));
        let no_type_hash_node = make_node("LVAR", vec![make_symbol("no_type_hash")], "no_type_hash");
        assert_eq!(
            visitor.expression_type_with_locals_and_shapes(&no_type_hash_node, &BTreeMap::new(), &BTreeMap::new()),
            Some(visitor.behavior.untyped_hash_type())
        );

        // 73. OR / AND left == right == Some("NilClass") in expression_type_with_locals_and_shapes to hit line 2078
        let node_or_nil = make_node(
            "OR",
            vec![
                make_child_node(make_node("NIL", vec![], "nil")),
                make_child_node(make_node("NIL", vec![], "nil"))
            ],
            "nil || nil"
        );
        assert_eq!(
            visitor.expression_type_with_locals_and_shapes(&node_or_nil, &BTreeMap::new(), &BTreeMap::new()),
            Some("NilClass".to_string())
        );

        // 74. ITER node read-only expression_type lookup to hit lines 2125-2204
        visitor.local_types.insert("a".to_string(), "T::Array[Integer]".to_string());
        visitor.static_expression_type(&iter_arr);

        // 75. ITER map node read-only expression_type lookup to hit lines 2172-2197
        let iter_map: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "a"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"a"}},
                        {"Symbol": "map"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "a.map"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "elem"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"elem"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "elem"
                        }},
                        {"Node": {"type": "INTEGER", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "1"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "a.map { |elem| 1 }"
        }"#).unwrap();
        visitor.static_expression_type(&iter_map);

        // 76. ITER filter_map node with nilable return to hit lines 2187-2191
        let iter_filter_map_nilable: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "a"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"a"}},
                        {"Symbol": "filter_map"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "a.filter_map"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "elem"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"elem"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "elem"
                        }},
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "elem"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"elem"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "a.filter_map { |elem| elem }"
        }"#).unwrap();
        visitor.local_types.insert("a".to_string(), "T::Array[T.nilable(Integer)]".to_string());
        assert_eq!(
            visitor.static_expression_type(&iter_filter_map_nilable),
            Some("T::Array[Integer]".to_string())
        );

        // 77. ITER each node with a hash receiver to hit lines 2146-2159
        let iter_hash: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "h"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"h"}},
                        {"Symbol": "each"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "h.each"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "k"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"k"}},
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "v"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"v"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "k, v"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "h.each { |k, v| }"
        }"#).unwrap();
        visitor.local_types.insert("h".to_string(), "T::Hash[Symbol, Integer]".to_string());
        visitor.static_expression_type(&iter_hash);

        // 78. CALL [] with shapes lookup to hit line 2211
        let node_bracket_lookup = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("no_type_hash")], "no_type_hash")),
                make_symbol("[]"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("SYMBOL", vec![], ":a"))],
                    ":a"
                ))
            ],
            "no_type_hash[:a]"
        );
        visitor.static_expression_type(&node_bracket_lookup);

        // 79. inferred_return_types lookup in static_expression_type to hit line 2225
        visitor.inferred_return_types.insert(("MyClass".to_string(), "my_inferred_method".to_string()), "String".to_string());
        visitor.current_owners = vec!["MyClass".to_string()];
        let call_inferred = make_node(
            "VCALL",
            vec![make_symbol("my_inferred_method")],
            "my_inferred_method"
        );
        assert_eq!(visitor.static_expression_type(&call_inferred), Some("String".to_string()));

        // 80. static_call_return_type lookup to hit line 2229
        let call_array_index = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_arr_local")], "my_arr_local")),
                make_symbol("[]"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "0"))],
                    "0"
                ))
            ],
            "my_arr_local[0]"
        );
        visitor.local_types.insert("my_arr_local".to_string(), "T::Array[Integer]".to_string());
        assert_eq!(visitor.static_expression_type(&call_array_index), Some("T.nilable(Integer)".to_string()));

        // 81. propagated_collection_return_type lookup to hit line 2235
        let call_concat = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_arr_local")], "my_arr_local")),
                make_symbol("concat"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("other_arr_local")], "other_arr_local"))],
                    "other_arr_local"
                ))
            ],
            "my_arr_local.concat(other_arr_local)"
        );
        assert_eq!(visitor.static_expression_type(&call_concat), Some("T::Array[Integer]".to_string()));

        // 82. Flat hash elements lookup to hit lines 2307-2333 and HASH literal type case (line 2371)
        let flat_hash_node = make_node(
            "HASH",
            vec![
                make_child_node(make_node("label", vec![], "my_key:")),
                make_child_node(make_node("INTEGER", vec![], "1"))
            ],
            "{my_key: 1}"
        );
        let _ = visitor.static_expression_type(&flat_hash_node);

        // 83. Foo.new literal type to hit lines 2379 and 2381
        let call_new_node = make_node(
            "CALL",
            vec![
                make_child_node(make_node("CONST", vec![], "Foo")),
                make_symbol("new"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "Foo.new"
        );
        assert_eq!(visitor.literal_type(&call_new_node), Some("Foo".to_string()));

        // 84. signatures return type extraction in known_return_type to hit lines 2395-2397
        visitor.signatures.insert("MyClass\u{0}my_sig_method".to_string(), "sig { returns(Integer) }".to_string());
        assert_eq!(visitor.known_return_type("my_sig_method"), Some("Integer".to_string()));

        // 85. IF node where both then and else are noreturn to hit lines 2416-2418
        let node_noreturn_if = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("absurd"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "T.absurd"
                )),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("absurd"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "T.absurd"
                ))
            ],
            "if true; T.absurd; else; T.absurd; end"
        );
        assert!(visitor.noreturn_body(&node_noreturn_if));

        // 86. CASE node where all arms are noreturn to hit lines 2421-2452
        let node_noreturn_case = make_node(
            "CASE",
            vec![
                make_child_node(make_node(
                    "WHEN",
                    vec![
                        make_child_node(make_node("INTEGER", vec![], "1")),
                        make_child_node(make_node(
                            "CALL",
                            vec![
                                make_child_node(make_node("CONST", vec![], "T")),
                                make_symbol("absurd"),
                                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                            ],
                            "T.absurd"
                        ))
                    ],
                    ""
                )),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("absurd"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "T.absurd"
                ))
            ],
            ""
        );
        assert!(visitor.noreturn_body(&node_noreturn_case));

        // 87. call absurd on non-T receiver to hit lines 2479-2480
        let call_absurd_not_t = make_node(
            "CALL",
            vec![
                make_child_node(make_node("CONST", vec![], "Foo")),
                make_symbol("absurd"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "Foo.absurd"
        );
        assert!(!visitor.noreturn_call(&call_absurd_not_t));

        // 88. HASH with other child node type to hit line 1771
        let hash_with_other_child = make_node(
            "HASH",
            vec![
                make_child_node(make_node(
                    "pair",
                    vec![
                        make_child_node(make_node("SYMBOL", vec![], ":a")),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    ":a => 1"
                )),
                make_child_node(make_node("COMMENT", vec![], "# comment"))
            ],
            "{:a => 1, # comment}"
        );
        let _ = visitor.hash_shape_for_value_readonly(&hash_with_other_child, &extra_hash_shapes);

        // 89. CALL with no receiver node (match_call returns None) to cover lines 1799, 1860, 1963
        let call_no_rec_node = make_node(
            "CALL",
            vec![
                crate::ast::Child::Nil,
                make_symbol("foo"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "foo"
        );
        let _ = visitor.hash_shape_for_value_readonly(&call_no_rec_node, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&call_no_rec_node, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&call_no_rec_node), &extra_hash_shapes);

        // 90. array_element_shape_for_value_readonly with ATTRASGN / LASGN to cover lines 1823-1828
        let attr_asgn_node = make_node(
            "ATTRASGN",
            vec![
                make_child_node(make_node("LVAR", vec![], "obj")),
                make_symbol("x="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("my_arr")], "my_arr"))],
                    "my_arr"
                ))
            ],
            "obj.x = my_arr"
        );
        let _ = visitor.array_element_shape_for_value_readonly(&attr_asgn_node, &extra_hash_shapes);

        let lasgn_arr_node = make_node(
            "LASGN",
            vec![
                make_symbol("x"),
                make_child_node(make_node("LVAR", vec![make_symbol("my_arr")], "my_arr"))
            ],
            "x = my_arr"
        );
        let _ = visitor.array_element_shape_for_value_readonly(&lasgn_arr_node, &extra_hash_shapes);

        // 91. array_element_shape_for_value_readonly call_node_invalid to cover line 1870
        let _ = visitor.array_element_shape_for_value_readonly(&call_node_invalid, &extra_hash_shapes);

        // 92. array_element_shape_for_value_readonly obj_foo_call and fcall_foo to cover lines 1864, 1865, 1867
        let obj_foo_call = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![], "obj")),
                make_symbol("foo"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "obj.foo"
        );
        let _ = visitor.array_element_shape_for_value_readonly(&obj_foo_call, &extra_hash_shapes);

        let fcall_foo = make_node("FCALL", vec![make_symbol("foo")], "foo()");
        let _ = visitor.array_element_shape_for_value_readonly(&fcall_foo, &extra_hash_shapes);

        // 93. ITER map with no ARGS to cover line 1884 & 1891
        let iter_map_no_args = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![], "my_array")),
                        make_symbol("map"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_array.map"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "my_array.map { 1 }"
        );
        let _ = visitor.array_element_shape_for_value_readonly(&iter_map_no_args, &extra_hash_shapes);

        // 94. ITER map with no block to cover line 1892 & 1899
        let iter_map_no_block = make_node(
            "ITER",
            vec![make_child_node(make_node(
                "CALL",
                vec![
                    make_child_node(make_node("LVAR", vec![], "my_array")),
                    make_symbol("map"),
                    make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                ],
                "my_array.map"
            ))],
            "my_array.map"
        );
        let _ = visitor.array_element_shape_for_value_readonly(&iter_map_no_block, &extra_hash_shapes);
        visitor.static_expression_type(&iter_map_no_block);

        // 95. ITER map as FCALL (no receiver) to cover line 1899 & 2174
        let iter_fcall_map = make_node(
            "ITER",
            vec![
                make_child_node(make_node("FCALL", vec![make_symbol("map")], "map()")),
                make_child_node(make_node(
                    "BLOCK",
                    vec![
                        make_child_node(make_node("ARGS", vec![make_child_node(make_node("LVAR", vec![], "x"))], "x")),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    ""
                ))
            ],
            "map { |x| 1 }"
        );
        let _ = visitor.array_element_shape_for_value_readonly(&iter_fcall_map, &extra_hash_shapes);
        visitor.static_expression_type(&iter_fcall_map);

        // 96. ITER with no receiver node for match_call to cover lines 1937, 1938
        let iter_fcall = make_node(
            "ITER",
            vec![
                make_child_node(make_node("FCALL", vec![make_symbol("foo")], "foo")),
                make_child_node(make_node("BLOCK", vec![], ""))
            ],
            "foo {}"
        );
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&iter_fcall), &extra_hash_shapes);

        let iter_each = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![], "my_arr")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_arr.each"
                )),
                make_child_node(make_node("BLOCK", vec![], ""))
            ],
            "my_arr.each {}"
        );
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&iter_each), &extra_hash_shapes);

        // 97. static_expression_type for iter_no_block to cover line 2128
        visitor.static_expression_type(&iter_no_block);

        // 98. static_expression_type for iter_hash_none and iter_array_none to cover lines 2143, 2144, 2150, 2151, 2158, 2159, 2161
        visitor.static_expression_type(&iter_hash_none);
        visitor.static_expression_type(&iter_array_none);

        // 99. ITER map return no type to cover line 2187
        let iter_map_no_type_return: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "a"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"a"}},
                        {"Symbol": "map"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "a.map"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "elem"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"elem"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "elem"
                        }},
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "no_type_var_ret"}], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "no_type_var_ret"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "a.map { |elem| no_type_var_ret }"
        }"#).unwrap();
        visitor.static_expression_type(&iter_map_no_type_return);

        // 100. ITER fcall select to cover line 2194
        let iter_fcall_select = make_node(
            "ITER",
            vec![
                make_child_node(make_node("FCALL", vec![make_symbol("select")], "select")),
                make_child_node(make_node(
                    "BLOCK",
                    vec![
                        make_child_node(make_node("ARGS", vec![make_child_node(make_node("LVAR", vec![], "x"))], "x")),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    ""
                ))
            ],
            "select { |x| 1 }"
        );
        visitor.static_expression_type(&iter_fcall_select);

        // 101. static_expression_type with bracket lookups to cover lines 2203 and 2206
        visitor.local_hash_shapes.insert("no_type_hash_with_key".to_string(), json!({"keys": {"a": ["Integer"]}}));
        let node_bracket_lookup_with_key = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("no_type_hash_with_key")], "no_type_hash_with_key")),
                make_symbol("[]"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("SYMBOL", vec![], ":a"))],
                    ":a"
                ))
            ],
            "no_type_hash_with_key[:a]"
        );
        assert_eq!(visitor.static_expression_type(&node_bracket_lookup_with_key), Some("T.nilable(Integer)".to_string()));

        let fcall_bracket = make_node(
            "FCALL",
            vec![
                make_symbol("[]"),
                make_child_node(make_node("ARGUMENT_LIST", vec![make_child_node(make_node("INTEGER", vec![], "1"))], "1"))
            ],
            "[](1)"
        );
        visitor.static_expression_type(&fcall_bracket);

        let node_bracket_no_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("no_type_hash")], "no_type_hash")),
                make_symbol("[]"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "no_type_hash[]"
        );
        visitor.static_expression_type(&node_bracket_no_args);
    }
}
