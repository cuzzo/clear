use super::super::TypeExpr;

pub(super) fn parse(source: &str) -> TypeExpr {
    if let Some(inner) = source.strip_prefix('*') {
        return TypeExpr::Nilable(Box::new(parse(inner)));
    }
    if let Some(inner) = source.strip_prefix("[]") {
        return TypeExpr::Array(Box::new(parse(inner)));
    }
    if source.starts_with("map[") {
        let mut depth = 0;
        let mut close = None;
        for (index, character) in source.char_indices() {
            match character {
                '[' => depth += 1,
                ']' => {
                    depth -= 1;
                    if depth == 0 {
                        close = Some(index);
                        break;
                    }
                }
                _ => {}
            }
        }
        if let Some(close) = close {
            return TypeExpr::Hash {
                key: Box::new(parse(&source[4..close])),
                value: Box::new(parse(&source[close + 1..])),
            };
        }
    }
    TypeExpr::Primitive(source.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_go_storage_types() {
        assert!(matches!(parse("*Widget"), TypeExpr::Nilable(_)));
        assert!(matches!(parse("[]string"), TypeExpr::Array(_)));
        assert!(matches!(parse("map[string][]int"), TypeExpr::Hash { .. }));
        assert_eq!(
            parse("map[string"),
            TypeExpr::Primitive("map[string".into())
        );
        assert_eq!(parse("Widget"), TypeExpr::Primitive("Widget".into()));
    }
}
