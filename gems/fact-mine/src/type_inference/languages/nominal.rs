use super::super::TypeExpr;

/// Generic machinery for language adapters that use angle-bracket nominal
/// types. It deliberately knows no language spellings: every concrete
/// library name belongs in the corresponding `syntax/<language>.rs` adapter.
pub(crate) struct NominalTypeSyntax {
    pub(crate) strip_prefixes: &'static [&'static str],
    pub(crate) trim_prefix_chars: &'static [char],
    pub(crate) trim_suffix_chars: &'static [char],
    pub(crate) array_names: &'static [&'static str],
    pub(crate) hash_names: &'static [&'static str],
    pub(crate) set_names: &'static [&'static str],
    pub(crate) string_names: &'static [&'static str],
    pub(crate) bare_array_names: &'static [&'static str],
    pub(crate) suffix_array: bool,
    pub(crate) bracket_array: bool,
}

pub(crate) fn parse(source: &str, syntax: &NominalTypeSyntax) -> TypeExpr {
    let source = strip_decorators(source, syntax);
    if syntax.bracket_array {
        if let Some(inner) = source.strip_prefix('[').and_then(|value| value.strip_suffix(']')) {
            return TypeExpr::Array(Box::new(parse(inner, syntax)));
        }
    }
    if syntax.suffix_array {
        if let Some(inner) = source.strip_suffix("[]") {
            return TypeExpr::Array(Box::new(parse(inner, syntax)));
        }
    }
    let Some((base, arguments)) = generic_parts(source) else {
        return primitive(source, syntax);
    };
    let arguments = split_top_level(arguments);
    let argument = |index: usize| {
        Box::new(
            arguments
                .get(index)
                .map(|value| parse(value, syntax))
                .unwrap_or(TypeExpr::Untyped),
        )
    };
    let base = short_name(base);
    if syntax.array_names.contains(&base) {
        TypeExpr::Array(argument(0))
    } else if syntax.hash_names.contains(&base) {
        TypeExpr::Hash {
            key: argument(0),
            value: argument(1),
        }
    } else if syntax.set_names.contains(&base) {
        TypeExpr::Set(argument(0))
    } else {
        TypeExpr::Primitive(source.to_string())
    }
}

fn strip_decorators<'a>(source: &'a str, syntax: &NominalTypeSyntax) -> &'a str {
    let mut source = source.trim();
    for prefix in syntax.strip_prefixes {
        if let Some(rest) = source.strip_prefix(prefix) {
            source = rest.trim_start();
        }
    }
    source
        .trim_start_matches(|ch| syntax.trim_prefix_chars.contains(&ch))
        .trim_end_matches(|ch| syntax.trim_suffix_chars.contains(&ch))
        .trim()
}

fn primitive(source: &str, syntax: &NominalTypeSyntax) -> TypeExpr {
    let short = short_name(source);
    if syntax.string_names.contains(&short) {
        TypeExpr::Primitive("String".to_string())
    } else if syntax.bare_array_names.contains(&short) {
        TypeExpr::Array(Box::new(TypeExpr::Untyped))
    } else {
        TypeExpr::Primitive(source.to_string())
    }
}

fn short_name(source: &str) -> &str {
    source
        .rsplit("::")
        .next()
        .unwrap_or(source)
        .rsplit('.')
        .next()
        .unwrap_or(source)
}

fn generic_parts(source: &str) -> Option<(&str, &str)> {
    let open = source.find('<')?;
    let close = source.rfind('>')?;
    // `Option::then_some` evaluates its argument eagerly. Guard before slicing
    // so malformed external source can become an unknown nominal type instead
    // of crashing Fact-Mine.
    if close > open {
        Some((&source[..open], &source[(open + 1)..close]))
    } else {
        None
    }
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

    const TEST_SYNTAX: NominalTypeSyntax = NominalTypeSyntax {
        strip_prefixes: &["qual "],
        trim_prefix_chars: &[],
        trim_suffix_chars: &[],
        array_names: &["Dense"],
        hash_names: &["Table"],
        set_names: &["Unique"],
        string_names: &["Text"],
        bare_array_names: &["sequence"],
        suffix_array: true,
        bracket_array: true,
    };

    #[test]
    fn parses_adapter_supplied_normalized_families_only() {
        assert!(matches!(parse("Dense<Text>", &TEST_SYNTAX), TypeExpr::Array(_)));
        assert!(matches!(parse("Table<Text, Dense<int>>", &TEST_SYNTAX), TypeExpr::Hash { .. }));
        assert!(matches!(parse("Unique<int>", &TEST_SYNTAX), TypeExpr::Set(_)));
        assert!(matches!(parse("[Text]", &TEST_SYNTAX), TypeExpr::Array(_)));
        assert!(matches!(parse("sequence", &TEST_SYNTAX), TypeExpr::Array(_)));
        assert_eq!(parse("Widget", &TEST_SYNTAX), TypeExpr::Primitive("Widget".to_string()));
    }

    #[test]
    fn malformed_generic_order_is_not_sliced_or_guessed() {
        let source = "value > other < \u{00e9}";
        assert_eq!(parse(source, &TEST_SYNTAX), TypeExpr::Primitive(source.to_string()));
    }
}
