//! Reading a Sorbet signature well enough to decide whether the runtime needs
//! to watch a value.
//!
//! The collector traces what the types do not already pin down. A parameter
//! annotated `String` needs no runtime sample; one annotated `T.untyped`, or
//! `T::Array[T.untyped]`, tells you nothing and has to be observed. That
//! judgement drives the trace plan, so it decides how much work every traced
//! process does.
//!
//! Ported from nil-kill's `util.rb`, whose behaviour these tests pin. The
//! scanning is bracket-depth counting rather than parsing: a signature is an
//! ordinary Ruby method call, and the only structure that matters is where the
//! top-level commas fall.

/// The argument text of `name(...)` within `source`, respecting nesting.
///
/// Returns `None` when the call is absent or its parentheses never close, so a
/// truncated signature reads as "no annotation" rather than as an empty one.
pub fn call_args<'a>(source: &'a str, name: &str) -> Option<&'a str> {
    let needle = format!("{name}(");
    let idx = source.find(&needle)?;
    let start = idx + needle.len();
    let mut depth = 1usize;
    for (offset, ch) in source[start..].char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    return Some(&source[start..start + offset]);
                }
            }
            _ => {}
        }
    }
    None
}

/// Split on commas that are not inside brackets, dropping empties.
pub fn split_top_level(source: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut depth = 0usize;
    let mut start = 0usize;
    for (idx, ch) in source.char_indices() {
        match ch {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                parts.push(source[start..idx].trim());
                start = idx + 1;
            }
            _ => {}
        }
    }
    parts.push(source[start..].trim());
    parts.into_iter().filter(|part| !part.is_empty()).collect()
}

/// Each `name: Type` pair declared in the signature's `params(...)`.
pub fn param_entries(sig: &str) -> Vec<(String, String)> {
    let Some(params) = call_args(sig, "params") else {
        return Vec::new();
    };
    split_top_level(params)
        .into_iter()
        .filter_map(|entry| {
            // `name: Type` -- the first colon separates them, and the type may
            // itself contain colons (`T::Array[...]`).
            let colon = entry.find(':')?;
            let name = entry[..colon].trim();
            let type_text = entry[colon + 1..].trim();
            if name.is_empty() || type_text.is_empty() {
                return None;
            }
            Some((name.to_string(), type_text.to_string()))
        })
        .collect()
}

pub fn return_type(sig: &str) -> Option<&str> {
    call_args(sig, "returns")
}

pub fn useful_type(type_text: &str) -> bool {
    !type_text.is_empty() && type_text != "T.untyped"
}

/// A type that names a container but leaves its contents untyped tells the
/// runtime nothing about what flows through it.
pub fn weak_type(type_text: &str) -> bool {
    if type_text.contains("T.untyped") {
        // Only the parametric-container form is weak by shape; a bare
        // `T.untyped` anywhere is weak outright.
        if !type_text.starts_with("T::") {
            return true;
        }
    }
    for container in ["Array", "Hash", "Enumerable", "Set"] {
        let prefix = format!("T::{container}");
        if type_text.starts_with(&prefix) {
            let rest = &type_text[prefix.len()..];
            // `\b` in the original: the container name must end here.
            if rest.starts_with(|c: char| c.is_alphanumeric() || c == '_') {
                continue;
            }
            if let Some(open) = rest.find('[') {
                if rest[open..].starts_with("[T.untyped") {
                    return true;
                }
            }
        }
    }
    type_text.contains("T.untyped")
}

/// Whether the static type is specific enough that the runtime need not sample.
pub fn strong_trace_type(type_text: &str) -> bool {
    useful_type(type_text) && !weak_type(type_text)
}

#[cfg(test)]
#[path = "sorbet_sig_parity.rs"]
mod parity;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_are_read_to_the_matching_paren_not_the_first() {
        let sig = "sig { params(a: T::Hash[String, Integer], b: String).returns(T.nilable(Foo)) }";
        assert_eq!(
            call_args(sig, "params"),
            Some("a: T::Hash[String, Integer], b: String")
        );
        assert_eq!(call_args(sig, "returns"), Some("T.nilable(Foo)"));
    }

    #[test]
    fn an_unclosed_call_reads_as_no_annotation() {
        assert_eq!(call_args("params(a: String", "params"), None);
        assert_eq!(call_args("sig {}", "params"), None);
    }

    #[test]
    fn splitting_ignores_commas_inside_brackets() {
        assert_eq!(
            split_top_level("a: T::Hash[String, Integer], b: T.any(A, B), c: Int"),
            vec!["a: T::Hash[String, Integer]", "b: T.any(A, B)", "c: Int"]
        );
        assert_eq!(split_top_level(""), Vec::<&str>::new());
        assert_eq!(split_top_level("a, , b"), vec!["a", "b"]);
    }

    #[test]
    fn parameters_keep_the_colons_inside_their_types() {
        let sig = "sig { params(rows: T::Array[T::Hash[Symbol, String]], n: Integer).void }";
        assert_eq!(
            param_entries(sig),
            vec![
                ("rows".to_string(), "T::Array[T::Hash[Symbol, String]]".to_string()),
                ("n".to_string(), "Integer".to_string()),
            ]
        );
    }

    #[test]
    fn a_signature_without_params_yields_none() {
        assert!(param_entries("sig { returns(String) }").is_empty());
        assert!(param_entries("").is_empty());
    }

    #[test]
    fn an_untyped_annotation_is_never_worth_trusting() {
        assert!(!strong_trace_type("T.untyped"));
        assert!(!strong_trace_type(""));
        assert!(!strong_trace_type("T.nilable(T.untyped)"));
    }

    #[test]
    fn a_container_of_untyped_is_weak_but_a_typed_one_is_not() {
        assert!(weak_type("T::Array[T.untyped]"));
        assert!(weak_type("T::Hash[T.untyped, String]"));
        assert!(!weak_type("T::Array[String]"));
        assert!(strong_trace_type("T::Array[String]"));
        assert!(strong_trace_type("String"));
    }

    #[test]
    fn a_class_whose_name_merely_starts_with_a_container_name_is_not_a_container() {
        assert!(!weak_type("T::ArrayLike[String]"));
        assert!(strong_trace_type("T::SetLike[Foo]"));
    }
}
