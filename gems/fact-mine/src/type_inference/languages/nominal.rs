use super::super::TypeExpr;

/// Conservative storage-shape parsing for nominal, C-family type spellings.
/// This recognizes only standard collection declarations; every unrecognized
/// nominal type remains a primitive instead of being guessed as a collection.
pub(super) fn parse(source: &str) -> TypeExpr {
    let source = source.trim();
    let source = source
        .strip_prefix("const ")
        .or_else(|| source.strip_prefix("readonly "))
        .unwrap_or(source)
        .trim_end_matches('&')
        .trim_end_matches('*')
        .trim();
    if let Some(inner) = source.strip_suffix("[]") {
        return TypeExpr::Array(Box::new(parse(inner)));
    }
    let Some((base, arguments)) = generic_parts(source) else {
        return primitive(source);
    };
    let arguments = split_top_level(arguments);
    match base.rsplit("::").next().unwrap_or(base).rsplit('.').next().unwrap_or(base) {
        "List" | "IList" | "ICollection" | "IEnumerable" | "Collection" | "Iterable"
        | "Vector" | "vector" | "array" | "span" | "basic_string" => {
            TypeExpr::Array(Box::new(arguments.first().map(|value| parse(value)).unwrap_or(TypeExpr::Untyped)))
        }
        "Map" | "HashMap" | "LinkedHashMap" | "Dictionary" | "unordered_map" | "map" => {
            TypeExpr::Hash {
                key: Box::new(arguments.first().map(|value| parse(value)).unwrap_or(TypeExpr::Untyped)),
                value: Box::new(arguments.get(1).map(|value| parse(value)).unwrap_or(TypeExpr::Untyped)),
            }
        }
        "Set" | "HashSet" | "TreeSet" | "unordered_set" | "set" => {
            TypeExpr::Set(Box::new(arguments.first().map(|value| parse(value)).unwrap_or(TypeExpr::Untyped)))
        }
        _ => primitive(source),
    }
}

fn primitive(source: &str) -> TypeExpr {
    let short = source.rsplit("::").next().unwrap_or(source).rsplit('.').next().unwrap_or(source);
    match short {
        "String" | "string" | "basic_string" => TypeExpr::Primitive("String".to_string()),
        _ => TypeExpr::Primitive(source.to_string()),
    }
}

fn generic_parts(source: &str) -> Option<(&str, &str)> {
    let open = source.find('<')?;
    let close = source.rfind('>')?;
    (close > open).then_some((&source[..open], &source[(open + 1)..close]))
}

fn split_top_level(source: &str) -> Vec<&str> {
    let mut depth = 0usize;
    let mut start = 0usize;
    let mut parts = Vec::new();
    for (index, character) in source.char_indices() {
        match character {
            '<' => depth += 1,
            '>' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                parts.push(source[start..index].trim());
                start = index + 1;
            }
            _ => {}
        }
    }
    let final_part = source[start..].trim();
    if !final_part.is_empty() {
        parts.push(final_part);
    }
    parts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_common_nominal_collection_shapes_without_guessing_custom_types() {
        assert!(matches!(parse("List<String>"), TypeExpr::Array(_)));
        assert!(matches!(parse("Dictionary<String, List<int>>"), TypeExpr::Hash { .. }));
        assert!(matches!(parse("std::unordered_set<int>"), TypeExpr::Set(_)));
        assert!(matches!(parse("const std::vector<int> &"), TypeExpr::Array(_)));
        assert_eq!(parse("Widget"), TypeExpr::Primitive("Widget".to_string()));
    }
}
