use super::super::TypeExpr;
use crate::profile::split_top_level_params;

pub(super) fn parse(source: &str) -> TypeExpr {
    if source == "any" || source == "unknown" {
        return TypeExpr::Untyped;
    }
    if source == "null" || source == "undefined" {
        return TypeExpr::NilClass;
    }
    if source.starts_with("Array<") && source.ends_with('>') {
        return TypeExpr::Array(Box::new(parse(&source["Array<".len()..source.len() - 1])));
    }
    if source.starts_with("Record<") && source.ends_with('>') {
        let parts = split_top_level_params(&source["Record<".len()..source.len() - 1]);
        if parts.len() == 2 {
            return TypeExpr::Hash {
                key: Box::new(parse(&parts[0])),
                value: Box::new(parse(&parts[1])),
            };
        }
    }
    if source.starts_with("Set<") && source.ends_with('>') {
        return TypeExpr::Set(Box::new(parse(&source["Set<".len()..source.len() - 1])));
    }
    if let Some(inner) = source.strip_suffix("[]") {
        return TypeExpr::Array(Box::new(parse(inner)));
    }
    if source.contains('|') {
        let mut has_null = false;
        let mut present = Vec::new();
        for part in source.split('|').map(str::trim) {
            let parsed = parse(part);
            if parsed == TypeExpr::NilClass {
                has_null = true;
            } else {
                present.push(parsed);
            }
        }
        let base = match present.len() {
            0 => TypeExpr::Untyped,
            1 => present.pop().expect("one union member"),
            _ => TypeExpr::Union(present),
        };
        return if has_null {
            TypeExpr::Nilable(Box::new(base))
        } else {
            base
        };
    }
    TypeExpr::Primitive(source.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_typescript_and_javascript_types() {
        assert_eq!(parse("unknown"), TypeExpr::Untyped);
        assert_eq!(parse("undefined"), TypeExpr::NilClass);
        assert!(matches!(parse("Array<string>"), TypeExpr::Array(_)));
        assert!(matches!(
            parse("Record<string, number>"),
            TypeExpr::Hash { .. }
        ));
        assert!(matches!(parse("Set<string>"), TypeExpr::Set(_)));
        assert!(matches!(parse("string[]"), TypeExpr::Array(_)));
        assert!(matches!(parse("string | number"), TypeExpr::Union(_)));
        assert!(matches!(parse("string | null"), TypeExpr::Nilable(_)));
        assert_eq!(parse("Widget"), TypeExpr::Primitive("Widget".into()));
    }
}
