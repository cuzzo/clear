mod go;
mod python;
mod ruby;
mod typescript;

use super::TypeExpr;

pub(super) fn parse(source: &str, language: &str) -> TypeExpr {
    let source = source.trim();
    if source.is_empty() {
        return TypeExpr::Untyped;
    }

    match language {
        "ruby" => ruby::parse(source),
        "python" => python::parse(source),
        "typescript" | "javascript" => typescript::parse(source),
        "go" => go::parse(source),
        // FactMine's legacy generic syntax is Sorbet-shaped. Keeping that
        // fallback explicit here prevents the shared engine from silently
        // accumulating another language's grammar.
        _ => ruby::parse(source),
    }
}

pub(super) fn flow_hint(hint: &str, language: &str) -> Option<TypeExpr> {
    match language {
        "ruby" => ruby::flow_hint(hint),
        "python" => python::flow_hint(hint),
        _ => collection_flow_hint(hint),
    }
}

fn collection_flow_hint(hint: &str) -> Option<TypeExpr> {
    match hint {
        "nil" => Some(TypeExpr::NilClass),
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
    fn dispatches_language_parsers_and_conservative_flow_fallbacks() {
        assert_eq!(
            parse("String", "ruby"),
            TypeExpr::Primitive("String".into())
        );
        assert_eq!(
            parse("list[str]", "python"),
            TypeExpr::Array(Box::new(TypeExpr::Primitive("str".into())))
        );
        assert_eq!(
            parse("string[]", "javascript"),
            TypeExpr::Array(Box::new(TypeExpr::Primitive("string".into())))
        );
        assert_eq!(
            parse("[]int", "go"),
            TypeExpr::Array(Box::new(TypeExpr::Primitive("int".into())))
        );
        assert_eq!(parse("", "ruby"), TypeExpr::Untyped);
        assert_eq!(parse("T.untyped", "unknown"), TypeExpr::Untyped);
        assert_eq!(
            flow_hint("array", "go"),
            Some(TypeExpr::Array(Box::new(TypeExpr::Untyped)))
        );
        assert!(matches!(
            flow_hint("hash", "typescript"),
            Some(TypeExpr::Hash { .. })
        ));
        assert_eq!(flow_hint("nil", "go"), Some(TypeExpr::NilClass));
        assert_eq!(flow_hint("string", "go"), None);
    }
}
