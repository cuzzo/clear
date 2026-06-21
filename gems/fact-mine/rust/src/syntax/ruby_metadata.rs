use super::FunctionDef;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Default)]
pub(crate) struct RubyMetadata {
    pub(crate) immutable_struct_readers: BTreeMap<String, Vec<String>>,
    pub(crate) immutable_struct_reader_types: BTreeMap<String, BTreeMap<String, String>>,
    pub(crate) type_aliases: BTreeMap<String, String>,
    pub(crate) method_param_types: BTreeMap<String, BTreeMap<String, String>>,
}

pub(crate) fn extract(source: &str, functions: &[FunctionDef]) -> RubyMetadata {
    RubyMetadata {
        immutable_struct_readers: reader_sets_to_vecs(immutable_struct_reader_sets(source)),
        immutable_struct_reader_types: immutable_struct_reader_types(source),
        type_aliases: type_aliases(source),
        method_param_types: method_param_types(source, functions),
    }
}

pub(crate) fn immutable_struct_reader_sets(source: &str) -> BTreeMap<String, BTreeSet<String>> {
    let mut readers: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut class_stack = Vec::new();
    for line in source.lines() {
        let stripped = line.trim();
        if let Some(name) = stripped
            .strip_prefix("class ")
            .and_then(|rest| rest.split_once("< T::Struct").map(|(name, _)| name.trim()))
            .filter(|name| constant_path(name))
        {
            class_stack.push(name.to_string());
            continue;
        }
        if let Some(owner) = class_stack.last() {
            if let Some(field) = stripped
                .strip_prefix("const :")
                .and_then(|rest| {
                    rest.split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_')
                        .next()
                })
                .filter(|field| !field.is_empty())
            {
                readers
                    .entry(owner.clone())
                    .or_default()
                    .insert(field.to_string());
                continue;
            }
        }
        if !class_stack.is_empty() && stripped.trim_end_matches(';') == "end" {
            class_stack.pop();
        }
    }
    readers
}

fn reader_sets_to_vecs(
    readers: BTreeMap<String, BTreeSet<String>>,
) -> BTreeMap<String, Vec<String>> {
    readers
        .into_iter()
        .map(|(owner, fields)| (owner, fields.into_iter().collect()))
        .collect()
}

fn immutable_struct_reader_types(source: &str) -> BTreeMap<String, BTreeMap<String, String>> {
    let mut reader_types: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    let mut class_stack = Vec::new();
    for line in source.lines() {
        let stripped = line.trim();
        if let Some(name) = stripped
            .strip_prefix("class ")
            .and_then(|rest| rest.split_once("< T::Struct").map(|(name, _)| name.trim()))
            .filter(|name| constant_path(name))
        {
            class_stack.push(name.to_string());
            continue;
        }
        if let Some(owner) = class_stack.last() {
            if let Some((field, type_name)) = stripped
                .strip_prefix("const :")
                .and_then(|rest| rest.split_once(','))
                .map(|(field, type_name)| {
                    (
                        field
                            .split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_')
                            .next()
                            .unwrap_or("")
                            .trim(),
                        type_name
                            .trim()
                            .split(|ch: char| !matches!(ch, ':' | '_' | 'A'..='Z' | 'a'..='z' | '0'..='9'))
                            .next()
                            .unwrap_or("")
                            .trim(),
                    )
                })
                .filter(|(field, type_name)| !field.is_empty() && constant_path(type_name))
            {
                reader_types
                    .entry(owner.clone())
                    .or_default()
                    .insert(field.to_string(), type_name.to_string());
                continue;
            }
        }
        if !class_stack.is_empty() && stripped.trim_end_matches(';') == "end" {
            class_stack.pop();
        }
    }
    reader_types
}

fn type_aliases(source: &str) -> BTreeMap<String, String> {
    let mut aliases = BTreeMap::new();
    for line in source.lines() {
        let stripped = line.trim();
        if let Some((name, rest)) = stripped.split_once('=') {
            let name = name.trim();
            if !constant_path(name) {
                continue;
            }
            let rest = rest.trim();
            let target = if let Some(inner) = rest
                .strip_prefix("T.type_alias")
                .and_then(|value| value.split_once('{').map(|(_, right)| right))
                .and_then(|value| value.split_once('}').map(|(left, _)| left.trim()))
            {
                inner
            } else {
                rest.split_whitespace().next().unwrap_or("")
            };
            if constant_path(target) {
                aliases.insert(name.to_string(), target.to_string());
            }
        }
    }
    aliases
}

fn method_param_types(
    source: &str,
    functions: &[FunctionDef],
) -> BTreeMap<String, BTreeMap<String, String>> {
    functions
        .iter()
        .map(|function| {
            (
                function.name.clone(),
                sig_param_types(source, function.line),
            )
        })
        .filter(|(_, param_types)| !param_types.is_empty())
        .collect()
}

pub(crate) fn sig_param_types(source: &str, function_line: usize) -> BTreeMap<String, String> {
    let lines = source.lines().collect::<Vec<_>>();
    let mut sig_lines = Vec::new();
    let mut cursor = function_line.saturating_sub(2);
    while let Some(line) = lines.get(cursor) {
        let stripped = line.trim();
        if !stripped.is_empty() {
            sig_lines.push(*line);
        }
        if stripped.starts_with("sig") {
            break;
        }
        if cursor == 0 || sig_lines.len() >= 12 {
            break;
        }
        cursor -= 1;
    }
    sig_lines.reverse();
    let sig = sig_lines.join("\n");
    if !sig.trim_start().starts_with("sig") {
        return BTreeMap::new();
    }
    let Some(params_start) = sig.find("params(").map(|index| index + "params(".len()) else {
        return BTreeMap::new();
    };
    let rest = &sig[params_start..];
    let Some(params_end) = rest.find(')') else {
        return BTreeMap::new();
    };
    rest[..params_end]
        .split(',')
        .filter_map(|part| {
            let (name, type_name) = part.split_once(':')?;
            let name = name.trim();
            let type_name = type_name.trim();
            (identifier(name) && constant_path(type_name))
                .then(|| (name.to_string(), type_name.to_string()))
        })
        .collect()
}

fn identifier(value: &str) -> bool {
    let mut chars = value.chars();
    matches!(chars.next(), Some(ch) if ch == '_' || ch.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn constant_path(value: &str) -> bool {
    value.split("::").all(|part| {
        let mut chars = part.chars();
        matches!(chars.next(), Some(ch) if ch.is_ascii_uppercase())
            && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
    })
}
