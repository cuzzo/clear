use super::super::TypeExpr;
use crate::profile::split_top_level_params;

pub(super) fn parse(source: &str) -> TypeExpr {
    if source == "T.untyped" || source == "untyped" {
        return TypeExpr::Untyped;
    }
    if source == "NilClass" || source == "nil" {
        return TypeExpr::NilClass;
    }
    if source.starts_with("T.nilable(") && source.ends_with(')') {
        let inner = &source["T.nilable(".len()..source.len() - 1];
        if TypeExpr::has_balanced_delimiters(inner, '(', ')') {
            return TypeExpr::Nilable(Box::new(parse(inner)));
        }
    }
    if (source.starts_with("T::Array[") || source.starts_with("Array[")) && source.ends_with(']') {
        let prefix_len = if source.starts_with("T::") {
            "T::Array[".len()
        } else {
            "Array[".len()
        };
        return TypeExpr::Array(Box::new(parse(&source[prefix_len..source.len() - 1])));
    }
    if (source.starts_with("T::Hash[") || source.starts_with("Hash[")) && source.ends_with(']') {
        let prefix_len = if source.starts_with("T::") {
            "T::Hash[".len()
        } else {
            "Hash[".len()
        };
        let parts = split_top_level_params(&source[prefix_len..source.len() - 1]);
        if parts.len() == 2 {
            return TypeExpr::Hash {
                key: Box::new(parse(&parts[0])),
                value: Box::new(parse(&parts[1])),
            };
        }
    }
    if (source.starts_with("T::Set[") || source.starts_with("Set[")) && source.ends_with(']') {
        let prefix_len = if source.starts_with("T::") {
            "T::Set[".len()
        } else {
            "Set[".len()
        };
        return TypeExpr::Set(Box::new(parse(&source[prefix_len..source.len() - 1])));
    }
    if source.starts_with("T.any(") && source.ends_with(')') {
        let inner = &source["T.any(".len()..source.len() - 1];
        if TypeExpr::has_balanced_delimiters(inner, '(', ')') {
            return TypeExpr::Union(
                split_top_level_params(inner)
                    .iter()
                    .map(|part| parse(part))
                    .collect(),
            );
        }
    }
    TypeExpr::Primitive(source.to_string())
}

pub(super) fn flow_hint(hint: &str) -> Option<TypeExpr> {
    match hint {
        "nil" => Some(TypeExpr::NilClass),
        "string" => Some(TypeExpr::Primitive("String".to_string())),
        "integer" => Some(TypeExpr::Primitive("Integer".to_string())),
        "float" => Some(TypeExpr::Primitive("Float".to_string())),
        "boolean" => Some(TypeExpr::Primitive("T::Boolean".to_string())),
        "symbol" => Some(TypeExpr::Primitive("Symbol".to_string())),
        "array" => Some(TypeExpr::Array(Box::new(TypeExpr::Untyped))),
        "hash" => Some(TypeExpr::Hash {
            key: Box::new(TypeExpr::Untyped),
            value: Box::new(TypeExpr::Untyped),
        }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_sorbet_types_and_flow_hints() {
        assert_eq!(parse("untyped"), TypeExpr::Untyped);
        assert_eq!(parse("nil"), TypeExpr::NilClass);
        assert!(matches!(parse("T.nilable(String)"), TypeExpr::Nilable(_)));
        assert!(matches!(parse("T::Array[String]"), TypeExpr::Array(_)));
        assert!(matches!(parse("Array[String]"), TypeExpr::Array(_)));
        assert!(matches!(
            parse("T::Hash[Symbol, T::Array[String]]"),
            TypeExpr::Hash { .. }
        ));
        assert!(matches!(
            parse("Hash[Symbol, String]"),
            TypeExpr::Hash { .. }
        ));
        assert!(matches!(parse("T::Set[String]"), TypeExpr::Set(_)));
        assert!(matches!(parse("Set[String]"), TypeExpr::Set(_)));
        assert!(matches!(
            parse("T.any(String, Integer)"),
            TypeExpr::Union(_)
        ));
        assert_eq!(parse("Widget"), TypeExpr::Primitive("Widget".into()));
        for hint in [
            "nil", "string", "integer", "float", "boolean", "symbol", "array", "hash",
        ] {
            assert!(flow_hint(hint).is_some(), "missing Ruby flow hint {hint}");
        }
        assert_eq!(flow_hint("object"), None);
    }
}
