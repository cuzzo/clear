use super::super::TypeExpr;
use crate::profile::split_top_level_params;

pub(super) fn parse(source: &str) -> TypeExpr {
    if source == "Any" || source == "any" {
        return TypeExpr::Untyped;
    }
    if source == "None" {
        return TypeExpr::NilClass;
    }
    if source.starts_with("Optional[") && source.ends_with(']') {
        return TypeExpr::Nilable(Box::new(parse(
            &source["Optional[".len()..source.len() - 1],
        )));
    }
    if (source.starts_with("List[") || source.starts_with("list[")) && source.ends_with(']') {
        let prefix_len = if source.starts_with('L') {
            "List[".len()
        } else {
            "list[".len()
        };
        return TypeExpr::Array(Box::new(parse(&source[prefix_len..source.len() - 1])));
    }
    if (source.starts_with("Dict[") || source.starts_with("dict[")) && source.ends_with(']') {
        let prefix_len = if source.starts_with('D') {
            "Dict[".len()
        } else {
            "dict[".len()
        };
        let parts = split_top_level_params(&source[prefix_len..source.len() - 1]);
        if parts.len() == 2 {
            return TypeExpr::Hash {
                key: Box::new(parse(&parts[0])),
                value: Box::new(parse(&parts[1])),
            };
        }
    }
    if (source.starts_with("Set[") || source.starts_with("set[")) && source.ends_with(']') {
        let prefix_len = if source.starts_with('S') {
            "Set[".len()
        } else {
            "set[".len()
        };
        return TypeExpr::Set(Box::new(parse(&source[prefix_len..source.len() - 1])));
    }
    if source.starts_with("Union[") && source.ends_with(']') {
        return union_with_none(split_top_level_params(
            &source["Union[".len()..source.len() - 1],
        ));
    }
    if source.contains('|') {
        return union_with_none(
            source
                .split('|')
                .map(str::trim)
                .map(str::to_string)
                .collect(),
        );
    }
    TypeExpr::Primitive(source.to_string())
}

fn union_with_none(parts: Vec<String>) -> TypeExpr {
    let mut has_none = false;
    let mut present = Vec::new();
    for part in parts {
        let parsed = parse(&part);
        if parsed == TypeExpr::NilClass {
            has_none = true;
        } else {
            present.push(parsed);
        }
    }
    let base = match present.len() {
        0 => TypeExpr::Untyped,
        1 => present.pop().expect("one union member"),
        _ => TypeExpr::Union(present),
    };
    if has_none {
        TypeExpr::Nilable(Box::new(base))
    } else {
        base
    }
}

pub(super) fn flow_hint(hint: &str) -> Option<TypeExpr> {
    match hint {
        "nil" => Some(TypeExpr::NilClass),
        "string" | "symbol" => Some(TypeExpr::Primitive("str".to_string())),
        "integer" => Some(TypeExpr::Primitive("int".to_string())),
        "float" => Some(TypeExpr::Primitive("float".to_string())),
        "boolean" => Some(TypeExpr::Primitive("bool".to_string())),
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
    fn parses_python_types_and_flow_hints() {
        assert_eq!(parse("Any"), TypeExpr::Untyped);
        assert_eq!(parse("None"), TypeExpr::NilClass);
        assert!(matches!(parse("Optional[str]"), TypeExpr::Nilable(_)));
        assert!(matches!(parse("List[str]"), TypeExpr::Array(_)));
        assert!(matches!(parse("list[str]"), TypeExpr::Array(_)));
        assert!(matches!(parse("Dict[str, int]"), TypeExpr::Hash { .. }));
        assert!(matches!(parse("dict[str, int]"), TypeExpr::Hash { .. }));
        assert!(matches!(parse("Set[str]"), TypeExpr::Set(_)));
        assert!(matches!(parse("set[str]"), TypeExpr::Set(_)));
        assert!(matches!(parse("Union[str, int]"), TypeExpr::Union(_)));
        assert!(matches!(parse("Union[str, None]"), TypeExpr::Nilable(_)));
        assert!(matches!(parse("str | None"), TypeExpr::Nilable(_)));
        assert_eq!(parse("Widget"), TypeExpr::Primitive("Widget".into()));
        for hint in [
            "nil", "string", "integer", "float", "boolean", "symbol", "array", "hash",
        ] {
            assert!(flow_hint(hint).is_some(), "missing Python flow hint {hint}");
        }
        assert_eq!(flow_hint("object"), None);
    }
}
