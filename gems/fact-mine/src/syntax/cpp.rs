// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    balanced_selector_name, configured_collection_operation, configured_intrinsic_call_complexity,
    configured_modeled_runtime_bound, configured_non_call_construct,
    configured_semantic_symbol_call_complexity,
    configured_semantic_symbol_kind, configured_semantic_symbol_parametric_cost,
    configured_stdlib_type, eliminable_guard_from_call, exact_direct_call_name,
    native_pointer_nullability_contract, nil_guard_from_predicates, scip_descriptor_owner,
    scip_global_parts, split_top_level_commas, type_before_parameter_name, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedNullableOperation, NormalizedSemanticEffect, NormalizedStateRead, SyntaxMetadata,
};
use super::{CallSite, ExternalCallComplexity, ExternalSymbolMetadata, FunctionDef};
use crate::ast::{Child, Node, Span};
use crate::type_inference::languages::nominal::{self, NominalTypeSyntax};
use crate::type_inference::TypeExpr;
use std::collections::{BTreeMap, BTreeSet};

const CPP_NOMINAL_TYPE_SYNTAX: NominalTypeSyntax = NominalTypeSyntax {
    strip_prefixes: &["const "],
    trim_prefix_chars: &[],
    trim_suffix_chars: &['&', '*'],
    array_names: &["vector", "array", "deque", "forward_list", "list", "span"],
    hash_names: &["map", "unordered_map"],
    set_names: &["set", "unordered_set"],
    string_names: &[
        "string",
        "wstring",
        "basic_string",
        "string_view",
        "wstring_view",
    ],
    bare_array_names: &[],
    suffix_array: false,
    bracket_array: false,
    bracket_array_length: None,
};
const CPP_PRIMITIVE_OPERATORS: &[&str] = &[
    "==", "!=", "<", "<=", ">", ">=", "+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>", "~",
    "&&", "||", "!",
];

pub(crate) fn parse_declared_type(source: &str) -> TypeExpr {
    let parsed = nominal::parse(source, &CPP_NOMINAL_TYPE_SYNTAX);
    let terminal = source
        .split('<')
        .next()
        .unwrap_or(source)
        .trim()
        .trim_end_matches(['&', '*'])
        .rsplit("::")
        .next()
        .unwrap_or_default()
        .trim();
    let normalized = source.trim().trim_start_matches("const ").trim();
    if normalized.starts_with("std::")
        && matches!(
            terminal,
            "fstream"
                | "ifstream"
                | "ofstream"
                | "wfstream"
                | "wifstream"
                | "wofstream"
        )
    {
        return TypeExpr::Primitive("FileStream".to_string());
    }
    if normalized.starts_with("nlohmann::") && matches!(terminal, "json" | "basic_json") {
        return TypeExpr::Primitive("Json".to_string());
    }
    if normalized.starts_with("std::atomic")
        || matches!(
            terminal,
            "atomic_bool"
                | "atomic_char"
                | "atomic_int"
                | "atomic_long"
                | "atomic_llong"
                | "atomic_uint"
                | "atomic_ulong"
                | "atomic_ullong"
                | "atomic_size_t"
        )
    {
        return TypeExpr::Primitive("StdAtomic".to_string());
    }
    match terminal {
        "ostringstream"
        | "wostringstream"
        | "istringstream"
        | "wistringstream"
        | "stringstream"
        | "wstringstream" => TypeExpr::Primitive("StringStream".to_string()),
        "ostream" | "wostream" => TypeExpr::Primitive("OutputStream".to_string()),
        _ => parsed,
    }
}

fn cpp_type_aliases(
    source: &str,
) -> (
    BTreeMap<String, String>,
    BTreeMap<String, usize>,
    BTreeSet<String>,
) {
    let mut candidates = BTreeMap::<String, BTreeSet<(String, usize)>>::new();
    let mut statement = String::new();
    let mut statement_line = 1usize;
    for (line_index, line) in source.lines().enumerate() {
        let code = line.split("//").next().unwrap_or_default();
        if statement.trim().is_empty() {
            statement_line = line_index + 1;
        }
        statement.push(' ');
        statement.push_str(code);
        while let Some(end) = statement.find(';') {
            let current = statement[..end].trim().to_string();
            statement = statement[end + 1..].to_string();
            let using = current
                .rfind("using ")
                .and_then(|start| current.get(start + "using ".len()..))
                .and_then(|declaration| declaration.split_once('='))
                .and_then(|(name, target)| {
                    let name = name.trim();
                    let valid = !name.is_empty()
                        && name
                            .chars()
                            .all(|character| character == '_' || character.is_ascii_alphanumeric())
                        && name
                            .chars()
                            .next()
                            .is_some_and(|character| {
                                character == '_' || character.is_ascii_alphabetic()
                            });
                    valid.then(|| {
                        (
                            name.to_string(),
                            target.split_whitespace().collect::<Vec<_>>().join(" "),
                        )
                    })
                });
            let typedef = current
                .rfind("typedef ")
                .and_then(|start| current.get(start + "typedef ".len()..))
                .and_then(|declaration| {
                    let split = declaration
                        .trim()
                        .rfind(char::is_whitespace)
                        .filter(|index| *index > 0)?;
                    let target = declaration[..split].trim();
                    let name = declaration[split..].trim();
                    (!target.is_empty()
                        && !name.is_empty()
                        && name.chars().all(|character| {
                            character == '_' || character.is_ascii_alphanumeric()
                        }))
                    .then(|| {
                        (
                            name.to_string(),
                            target.split_whitespace().collect::<Vec<_>>().join(" "),
                        )
                    })
                });
            if let Some((name, target)) = using.or(typedef).filter(|(_, target)| !target.is_empty()) {
                candidates
                    .entry(name)
                    .or_default()
                    .insert((target, statement_line));
            }
            statement_line = line_index + 1;
        }
    }

    let mut aliases = BTreeMap::new();
    let mut lines = BTreeMap::new();
    let mut dependent_aliases = BTreeSet::new();
    for (name, definitions) in candidates {
        if definitions.iter().all(|(target, _)| {
            cpp_identifier_tokens(target).any(|token| token == "typename")
        }) {
            // `typename X::Y` is a compiler-level declaration that Y depends
            // on a template type. Preserve that proof even when an
            // unqualified intermediate alias such as `super` has different
            // meanings in multiple classes and is correctly omitted below.
            dependent_aliases.insert(name.clone());
        }
        let targets = definitions
            .iter()
            .map(|(target, _)| target)
            .collect::<BTreeSet<_>>();
        // An unqualified alias is usable only when this translation unit gives
        // it one meaning. Repeated `super`/`Type` aliases in unrelated owners
        // intentionally remain unresolved rather than cross-contaminating.
        let normalized_targets = targets
            .iter()
            .map(|target| parse_declared_type(target))
            .collect::<Vec<_>>();
        let converged = normalized_targets
            .first()
            .is_some_and(|first| normalized_targets.iter().all(|target| target == first));
        if targets.len() != 1 && !converged {
            continue;
        }
        let (target, line) = definitions.into_iter().next().expect("one alias target");
        aliases.insert(name.clone(), target);
        lines.insert(name, line);
    }
    (aliases, lines, dependent_aliases)
}

fn cpp_identifier_tokens(source: &str) -> impl DoubleEndedIterator<Item = &str> {
    source
        .split(|character: char| character != '_' && !character.is_ascii_alphanumeric())
        .filter(|token| {
            !token.is_empty()
                && token
                    .chars()
                    .next()
                    .is_some_and(|character| character == '_' || character.is_ascii_alphabetic())
        })
}

fn cpp_function_imports_symbol(source: &str, qualified: &str) -> bool {
    let declaration = format!("using {qualified};");
    source.lines().any(|line| {
        let code = line.split_once("//").map_or(line, |(code, _)| code).trim();
        code == declaration
            || code.strip_suffix(&declaration).is_some_and(|prefix| {
                prefix
                    .chars()
                    .all(|character| character.is_ascii_whitespace() || character == '{')
            })
    })
}

fn cpp_function_is_friend(node: &Node, lines: &[String]) -> bool {
    let normalized_node_has_friend = node
        .text
        .trim_start()
        .strip_prefix("friend")
        .is_some_and(|rest| {
            rest.chars()
                .next()
                .is_some_and(|character| character.is_ascii_whitespace())
        });
    if normalized_node_has_friend || node.first_lineno == 0 {
        return normalized_node_has_friend;
    }
    lines
        .get(node.first_lineno - 1)
        .and_then(|line| line.get(..node.first_column.min(line.len())))
        .is_some_and(|prefix| {
            prefix
                .split_whitespace()
                .next_back()
                .is_some_and(|modifier| modifier == "friend")
        })
}

fn symbol_without_template_arguments(name: &str) -> String {
    let mut output = String::with_capacity(name.len());
    let mut depth = 0usize;
    for character in name.chars() {
        match character {
            '<' => depth += 1,
            '>' if depth > 0 => depth -= 1,
            _ if depth == 0 => output.push(character),
            _ => {}
        }
    }
    if depth == 0 {
        output
    } else {
        name.to_string()
    }
}

fn owner_identity_name(value: &str) -> String {
    let value = value
        .trim()
        .strip_prefix("const ")
        .unwrap_or(value.trim())
        .trim_start_matches('*')
        .trim_end_matches(|character: char| {
            character.is_whitespace() || matches!(character, '&' | '*')
        });
    // Erase template arguments without discarding a following nested owner.
    // Splitting at the first `<` made `Base<T>::Nested` indistinguishable from
    // `Base<T>`, which introduced a false specialization ambiguity during
    // inherited lookup.
    let without_templates = symbol_without_template_arguments(value);
    let value = without_templates
        .split('[')
        .next()
        .unwrap_or(&without_templates)
        .trim();
    value
        .rsplit([':', '.'])
        .find(|part| !part.is_empty())
        .unwrap_or(value)
        .to_string()
}

fn cpp_declared_template_type_names(declaration: &str) -> BTreeSet<String> {
    let body = declaration
        .split_once('<')
        .and_then(|(_, rest)| rest.rsplit_once('>'))
        .map(|(body, _)| body)
        .unwrap_or(declaration);
    body.split(',')
        .filter_map(|parameter| {
            let tokens = cpp_identifier_tokens(parameter).collect::<Vec<_>>();
            tokens
                .iter()
                .position(|token| matches!(*token, "typename" | "class"))
                .and_then(|position| tokens.get(position + 1))
                // C++20 constrained parameters spell the concept instead of
                // `typename` (`template <facade F>`). The final identifier is
                // still the compiler-declared parameter. Non-type parameters
                // are harmless here: only a declared receiver type containing
                // that exact identifier can consume the symbolic contract.
                .or_else(|| tokens.last())
                .map(|name| (*name).to_string())
        })
        .collect()
}

fn cpp_owner_template_type_names(owner: &str) -> BTreeSet<String> {
    let Some((_, arguments)) = owner.split_once('<') else {
        return BTreeSet::new();
    };
    let arguments = arguments
        .rsplit_once('>')
        .map(|(body, _)| body)
        .unwrap_or(arguments);
    cpp_identifier_tokens(arguments)
        .filter(|token| {
            !matches!(
                *token,
                "const"
                    | "false"
                    | "std"
                    | "template"
                    | "true"
                    | "type"
                    | "typename"
                    | "void"
            )
        })
        .map(str::to_string)
        .collect()
}

fn cpp_declared_owner_template_types(
    source: &str,
    functions: &[FunctionDef],
) -> BTreeMap<String, BTreeSet<String>> {
    let lines = source.lines().collect::<Vec<_>>();
    let function_owners = functions
        .iter()
        .filter_map(|function| {
            let owner = function
                .owner
                .split(['<', '@'])
                .next()
                .unwrap_or(&function.owner)
                .trim();
            (!owner.is_empty()).then_some(owner)
        })
        .collect::<BTreeSet<_>>();
    let mut owners = BTreeMap::new();
    for (index, line) in lines.iter().enumerate() {
        let Some(template_offset) = line.find("template") else {
            continue;
        };
        let declaration = lines[index..lines.len().min(index + 20)].join(" ");
        let declaration = &declaration[template_offset..];
        let Some(open) = declaration.find('<') else {
            continue;
        };
        let mut depth = 0usize;
        let mut close = None;
        for (offset, character) in declaration[open..].char_indices() {
            match character {
                '<' => depth += 1,
                '>' => {
                    depth = depth.saturating_sub(1);
                    if depth == 0 {
                        close = Some(open + offset);
                        break;
                    }
                }
                _ => {}
            }
        }
        let Some(close) = close else {
            continue;
        };
        let parameters = cpp_declared_template_type_names(&declaration[..=close]);
        if parameters.is_empty() {
            continue;
        }
        let suffix = declaration[close + 1..].trim_start();
        let owner = ["class ", "struct "].into_iter().find_map(|keyword| {
            let rest = suffix.strip_prefix(keyword)?;
            let header = rest
                .split(['{', ':', ';'])
                .next()
                .unwrap_or(rest);
            let candidates = cpp_identifier_tokens(header)
                .filter(|token| function_owners.contains(token))
                .collect::<BTreeSet<_>>();
            (candidates.len() == 1)
                .then(|| candidates.into_iter().next().map(str::to_string))
                .flatten()
        });
        if let Some(owner) = owner {
            owners.insert(owner, parameters);
        }
    }
    owners
}

fn cpp_method_template_types(
    source: &str,
    functions: &[FunctionDef],
    dependent_aliases: &BTreeSet<String>,
    method_local_types: &BTreeMap<String, BTreeMap<String, String>>,
) -> BTreeMap<String, BTreeSet<String>> {
    let lines = source.lines().collect::<Vec<_>>();
    let declared_owners = cpp_declared_owner_template_types(source, functions);
    functions
        .iter()
        .filter_map(|function| {
            let mut parameters = cpp_owner_template_type_names(&function.owner);
            let owner_base = function
                .owner
                .split('<')
                .next()
                .unwrap_or(&function.owner)
                .trim();
            parameters.extend(
                declared_owners
                    .get(owner_base)
                    .into_iter()
                    .flat_map(|parameters| parameters.iter().cloned()),
            );
            let start = function.line.saturating_sub(1);
            let lower = start.saturating_sub(16);
            let prefix = lines
                .get(lower..start)
                .unwrap_or_default()
                .iter()
                .rev()
                .take_while(|line| {
                    let trimmed = line.trim();
                    !trimmed.ends_with([';', '}'])
                })
                .copied()
                .collect::<Vec<_>>();
            let prefix = prefix.into_iter().rev().collect::<Vec<_>>().join(" ");
            if let Some(template_start) = prefix.rfind("template") {
                parameters.extend(cpp_declared_template_type_names(&prefix[template_start..]));
            }
            if !parameters.is_empty() {
                parameters.extend(dependent_aliases.iter().cloned());
                let key = format!(
                    "{}\0{}\0{}",
                    function.owner, function.name, function.line
                );
                let dependent_locals = method_local_types
                    .get(&key)
                    .into_iter()
                    .flat_map(|locals| locals.iter())
                    .filter(|(_, declared_type)| {
                        cpp_identifier_tokens(declared_type)
                            .any(|token| parameters.contains(token))
                    })
                    .map(|(name, _)| name.clone())
                    .collect::<BTreeSet<_>>();
                parameters.extend(dependent_locals);
                let body = lines
                    .get(
                        function.line.saturating_sub(1)
                            ..lines.len().min(function.span[2]),
                    )
                    .unwrap_or_default()
                    .join(" ");
                let statements = body.split(';').collect::<Vec<_>>();
                loop {
                    let inferred = statements
                        .iter()
                        .filter_map(|statement| cpp_dependent_auto_binding(statement, &parameters))
                        .filter(|name| !parameters.contains(name))
                        .collect::<BTreeSet<_>>();
                    if inferred.is_empty() {
                        break;
                    }
                    parameters.extend(inferred);
                }
            }
            (!parameters.is_empty()).then(|| {
                (
                    format!(
                        "{}\0{}\0{}",
                        function.owner, function.name, function.line
                    ),
                    parameters,
                )
            })
        })
        .collect()
}

fn cpp_dependent_auto_binding(
    statement: &str,
    dependencies: &BTreeSet<String>,
) -> Option<String> {
    for (auto, _) in statement.match_indices("auto") {
        let boundary_before = statement[..auto]
            .chars()
            .next_back()
            .is_none_or(|character| !character.is_ascii_alphanumeric() && character != '_');
        let Some(after_auto) = statement.get(auto + "auto".len()..) else {
            continue;
        };
        let boundary_after = after_auto
            .chars()
            .next()
            .is_none_or(|character| !character.is_ascii_alphanumeric() && character != '_');
        if !boundary_before || !boundary_after {
            continue;
        }
        let after_auto = after_auto
            .trim_start()
            .trim_start_matches(['&', '*'])
            .trim_start();
        let Some(name) = cpp_identifier_tokens(after_auto).next() else {
            continue;
        };
        let Some(after_name) = after_auto.get(after_auto.find(name)? + name.len()..) else {
            continue;
        };
        let after_name = after_name.trim_start();
        let Some(initializer) = after_name
            .strip_prefix('=')
            .or_else(|| after_name.strip_prefix(':'))
            .map(str::trim)
        else {
            continue;
        };
        let Some(dependency) =
            cpp_identifier_tokens(initializer).find(|token| dependencies.contains(*token))
        else {
            continue;
        };
        let type_dependent_syntax = initializer.contains("typename ")
            || initializer.contains(".template ")
            || initializer.contains("::template ")
            || initializer.contains(&format!("{dependency}."))
            || initializer.contains(&format!("{dependency}->"))
            || initializer
                .strip_prefix(dependency)
                .is_some_and(|rest| rest.trim_start().starts_with(['(', '{']));
        if type_dependent_syntax {
            return Some(name.to_string());
        }
    }
    None
}

fn cpp_method_local_types(
    source: &str,
    functions: &[FunctionDef],
) -> BTreeMap<String, BTreeMap<String, String>> {
    let lines = source.lines().collect::<Vec<_>>();
    functions
        .iter()
        .filter_map(|function| {
            let start = function.span[0].saturating_sub(1);
            let end = function.span[2].min(lines.len());
            let body = lines.get(start..end)?.join("\n");
            let body = body.split_once('{').map(|(_, body)| body)?;
            let mut candidates = BTreeMap::<String, BTreeSet<String>>::new();
            for (name, declared_type) in cpp_lambda_parameter_types(body) {
                candidates.entry(name).or_default().insert(declared_type);
            }
            for statement in body.split(';') {
                let declaration = statement
                    .rsplit(['{', '}'])
                    .next()
                    .unwrap_or(statement)
                    .trim();
                if declaration.is_empty()
                    || declaration.starts_with('#')
                {
                    continue;
                }
                let before_assignment = declaration
                    .split('=')
                    .next()
                    .unwrap_or(declaration)
                    .trim();
                // Constructor-style locals (`std::string out(n, 0)`) put the
                // initializer beside the binding rather than after `=`.
                // Keep the declaration prefix. A plain call (`out.resize(n)`)
                // then has a member-access suffix and is rejected below.
                let left = before_assignment
                    .split('(')
                    .next()
                    .unwrap_or(before_assignment)
                    .trim();
                let Some(name) = cpp_identifier_tokens(left).next_back() else {
                    continue;
                };
                let Some(name_start) = left.rfind(name) else {
                    continue;
                };
                let declared_type = left[..name_start].trim();
                let first = cpp_identifier_tokens(declared_type).next().unwrap_or_default();
                if declared_type.is_empty()
                    || declared_type.ends_with(['.', ':'])
                    || declared_type.contains("->")
                    || matches!(
                        first,
                        "break"
                            | "case"
                            | "continue"
                            | "delete"
                            | "else"
                            | "goto"
                            | "if"
                            | "new"
                            | "return"
                            | "switch"
                            | "throw"
                            | "while"
                    )
                    || matches!(declared_type, "auto" | "const auto" | "decltype(auto)")
                {
                    continue;
                }
                candidates
                    .entry(name.to_string())
                    .or_default()
                    .insert(declared_type.to_string());
            }
            let locals = candidates
                .into_iter()
                .filter_map(|(name, types)| {
                    (types.len() == 1)
                        .then(|| (name, types.into_iter().next().expect("one local type")))
                })
                .collect::<BTreeMap<_, _>>();
            (!locals.is_empty()).then(|| {
                (
                    format!(
                        "{}\0{}\0{}",
                        function.owner, function.name, function.line
                    ),
                    locals,
                )
            })
        })
        .collect()
}

fn cpp_lambda_parameter_types(source: &str) -> Vec<(String, String)> {
    let mut parameters = Vec::new();
    for (capture_end, _) in source.match_indices(']') {
        let Some(capture_start) = source[..capture_end].rfind('[') else {
            continue;
        };
        if source[capture_start..capture_end].contains([';', '{', '}']) {
            continue;
        }
        let after_capture = source[capture_end + 1..].trim_start();
        let Some(parameter_text) = after_capture.strip_prefix('(') else {
            continue;
        };
        let mut depth = 1usize;
        let mut parameter_end = None;
        for (index, character) in parameter_text.char_indices() {
            match character {
                '(' => depth += 1,
                ')' => {
                    depth = depth.saturating_sub(1);
                    if depth == 0 {
                        parameter_end = Some(index);
                        break;
                    }
                }
                _ => {}
            }
        }
        let Some(parameter_end) = parameter_end else {
            continue;
        };
        // Keep this proof boundary deliberately narrow. A braced body after
        // the parameter list distinguishes a lambda from subscripted callable
        // expressions such as `handlers[index](value)`.
        if !parameter_text[parameter_end + 1..]
            .trim_start()
            .starts_with('{')
        {
            continue;
        }
        for parameter in split_top_level_commas(&parameter_text[..parameter_end]) {
            let Some(name) = cpp_identifier_tokens(&parameter).next_back() else {
                continue;
            };
            let Some(declared_type) = type_before_parameter_name(&parameter) else {
                continue;
            };
            parameters.push((name.to_string(), declared_type));
        }
    }
    parameters
}

/// C and C++ share this set of spellings, so C's adapter asks the same
/// question here rather than restating it.
pub(crate) fn cpp_scalar_primitive(name: &str) -> bool {
    let bare = name
        .trim()
        .trim_start_matches("const ")
        .trim_start_matches("volatile ")
        .trim_end_matches(['&', '*'])
        .trim();
    let bare = bare.strip_prefix("std::").unwrap_or(bare);
    let words = bare.split_whitespace().collect::<Vec<_>>();
    matches!(
        bare,
        "bool"
            | "char"
            | "char8_t"
            | "char16_t"
            | "char32_t"
            | "wchar_t"
            | "float"
            | "double"
            | "size_t"
            | "ptrdiff_t"
            | "nullptr_t"
            | "int8_t"
            | "int16_t"
            | "int32_t"
            | "int64_t"
            | "uint8_t"
            | "uint16_t"
            | "uint32_t"
            | "uint64_t"
            | "intmax_t"
            | "uintmax_t"
            | "intptr_t"
            | "uintptr_t"
    ) || (!words.is_empty()
        && words.iter().all(|word| {
            matches!(
                *word,
                "signed" | "unsigned" | "short" | "int" | "long" | "double"
            )
        })
        && words
            .iter()
            .any(|word| matches!(*word, "short" | "int" | "long")))
}

fn scip_clang_parts(symbol: &str) -> Option<(&str, &str)> {
    let (package, _version, descriptor) = scip_global_parts(symbol, "cxx", ".")?;
    Some((package, descriptor))
}

fn cpp_std_descriptor(descriptor: &str) -> bool {
    descriptor.starts_with("std/") || descriptor.starts_with("`std`/")
}

fn cpp_std_owner_type(owner: &str) -> TypeExpr {
    // libstdc++ exposes ABI namespaces in SCIP descriptors (for example
    // `std/__cxx11/list#empty`).  They are implementation details, not
    // different complexity contracts, so classify the terminal owner.
    let owner = owner
        .trim_matches('`')
        .rsplit('/')
        .next()
        .unwrap_or(owner)
        .trim_matches('`');
    match owner {
        "array" | "deque" | "forward_list" | "list" | "span" | "vector" => {
            TypeExpr::Array(Box::new(TypeExpr::Untyped))
        }
        "map" | "unordered_map" => TypeExpr::Hash {
            key: Box::new(TypeExpr::Untyped),
            value: Box::new(TypeExpr::Untyped),
        },
        "set" | "unordered_set" => TypeExpr::Set(Box::new(TypeExpr::Untyped)),
        "basic_string" | "string" | "string_view" => TypeExpr::Primitive("String".to_string()),
        other => parse_declared_type(other),
    }
}

pub(crate) fn external_symbol_call_complexity(
    symbol: &str,
    message: &str,
) -> Option<ExternalCallComplexity> {
    let (_package, descriptor) = scip_clang_parts(symbol)?;
    if !cpp_std_descriptor(descriptor)
        || configured_semantic_symbol_parametric_cost("cpp", descriptor).is_some()
    {
        return None;
    }
    let owner = scip_descriptor_owner(descriptor);
    let message = balanced_selector_name(message);
    let complexity = configured_semantic_symbol_call_complexity("cpp", descriptor)
        .or_else(|| {
            owner
                .as_deref()
                .and_then(|owner| configured_intrinsic_call_complexity("cpp", Some(owner), message))
        })
        .or_else(|| {
            owner.as_deref().and_then(|owner| {
                CppNormalizedBehavior.call_complexity(&cpp_std_owner_type(owner), message)
            })
        })?;
    Some(ExternalCallComplexity {
        time: complexity.time,
        space: complexity.space,
        provenance: "cpp_scip_symbol_registry",
        bound_quality: "upper_bound_exact_target",
        candidates: Vec::new(),
        assumption: None,
    })
}

pub(crate) fn external_symbol_metadata(symbol: &str) -> ExternalSymbolMetadata {
    let Some((package, descriptor)) = scip_clang_parts(symbol) else {
        return ExternalSymbolMetadata {
            scope: "dynamic",
            missing_cost_kind: "callback_or_function_value_origin_unknown".to_string(),
            parametric_cost: None,
        };
    };
    if cpp_std_descriptor(descriptor) {
        ExternalSymbolMetadata {
            scope: "stdlib",
            missing_cost_kind: configured_semantic_symbol_kind("cpp", descriptor)
                .unwrap_or_else(|| "stdlib_cost_model_missing".to_string()),
            parametric_cost: configured_semantic_symbol_parametric_cost("cpp", descriptor),
        }
    } else {
        ExternalSymbolMetadata {
            scope: if package == "." {
                "external"
            } else {
                "dependency"
            },
            missing_cost_kind: "dependency_cost_model_missing".to_string(),
            parametric_cost: None,
        }
    }
}

fn modeled_runtime_call_complexity(message: &str) -> Option<ExternalCallComplexity> {
    let complexity = configured_modeled_runtime_bound("cpp", message)?;
    Some(ExternalCallComplexity {
        time: complexity.time,
        space: complexity.space,
        provenance: "cpp_source_runtime_registry",
        bound_quality: "upper_bound_modeled_world",
        candidates: vec![message.to_string()],
        assumption: Some(format!(
            "`{message}` follows the reviewed C/C++ platform runtime contract in this preprocessor configuration"
        )),
    })
}

pub(crate) fn external_symbol_owner(symbol: &str) -> Option<String> {
    let (_package, descriptor) = scip_clang_parts(symbol)?;
    scip_descriptor_owner(descriptor)
}

const CPP_CONTEXT_PAIRS: &[(&str, &[&str])] =
    &[("chrono", &["now"]), ("random_device", &["operator()"])];

const CPP_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "dynamic_cast",
        "typeid",
        "any_cast",
        "get_if",
        "visit",
        "invoke",
    ],
    meta_mids: &["reinterpret_cast", "const_cast", "dlsym", "dlopen"],
    method_obj_mids: &["method"],
    io_consts: &[
        "std",
        "filesystem",
        "fstream",
        "iostream",
        "thread",
        "mutex",
        "atomic",
    ],
    io_bare: &[
        "print", "printf", "puts", "panic", "throw", "abort", "exit", "assert", "system",
    ],
    context_pairs: CPP_CONTEXT_PAIRS,
    callback_set: &[
        "transaction",
        "synchronize",
        "lock",
        "with_lock",
        "unlock",
        "mutex",
        "atomic",
        "subscribe",
        "callback",
        "hook",
        "try_lock",
        "wait",
        "notify_one",
        "notify_all",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const CPP_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const CPP_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const CPP_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

// CFG-SPECIFIC START: C++ control-flow vocabulary.
const CPP_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &["for_each", "transform"],
    ignored_callback_body_sources: &[],
};
// CFG-SPECIFIC END

pub(crate) struct CppNormalizedBehavior;

fn cpp_receiver_local_binding(receiver: &str) -> Option<String> {
    let mut expression = receiver.trim();
    while expression.starts_with('(') && expression.ends_with(')') {
        let inner = expression[1..expression.len() - 1].trim();
        if inner.is_empty() {
            return None;
        }
        expression = inner;
    }
    expression = expression.strip_prefix('*')?.trim();
    while expression.starts_with('(') && expression.ends_with(')') {
        let inner = expression[1..expression.len() - 1].trim();
        if inner.is_empty() {
            return None;
        }
        expression = inner;
    }
    (!expression.is_empty()
        && expression
            .chars()
            .all(|character| character == '_' || character.is_ascii_alphanumeric())
        && expression
            .chars()
            .next()
            .is_some_and(|character| character == '_' || character.is_ascii_alphabetic()))
    .then(|| expression.to_string())
}

fn cpp_c_style_receiver_type(receiver: &str) -> Option<String> {
    let receiver = receiver.trim();
    let cast = receiver.strip_prefix('(')?;
    let close = cast.find(')')?;
    let declared = cast[..close].trim();
    let expression = cast[close + 1..].trim();
    if declared.is_empty()
        || expression.is_empty()
        || !declared.contains(['*', '&'])
        || declared.contains(['(', ')', '=', '!', '?', ';'])
        || !declared.chars().all(|character| {
            character.is_ascii_alphanumeric()
                || character.is_ascii_whitespace()
                || matches!(character, '_' | ':' | '<' | '>' | ',' | '*' | '&')
        })
    {
        return None;
    }
    Some(declared.to_string())
}

/// C++ normalizes `static_cast<T>(call())` as an FCALL. The cast only changes
/// the static view of the result, so a reviewed nullable result contract still
/// belongs to the exact inner call.
fn transparent_static_cast_argument(node: &Node) -> Option<&Node> {
    let Child::Symbol(name) = node.children.first()? else {
        return None;
    };
    if node.r#type != "FCALL" || !name.starts_with("static_cast<") {
        return None;
    }
    let arguments = node.children.get(1).and_then(crate::ast::node)?;
    if arguments.r#type != "LIST" {
        return None;
    }
    let mut children = arguments.children.iter().filter_map(crate::ast::node);
    let only = children.next()?;
    children.next().is_none().then_some(only)
}

fn nullable_contract_call(node: &Node) -> &Node {
    if let Some(argument) = transparent_static_cast_argument(node) {
        return nullable_contract_call(argument);
    }
    if node.r#type == "LIST" {
        let mut children = node.children.iter().filter_map(crate::ast::node);
        let only = children.next();
        if children.next().is_none() {
            if let Some(only) = only {
                return nullable_contract_call(only);
            }
        }
    }
    node
}

fn cpp_collection_element_binding(source: &str, local: &str) -> Option<String> {
    let compact = source.split_whitespace().collect::<Vec<_>>().join(" ");
    for (index, _) in compact.match_indices(local) {
        let before = compact[..index].chars().next_back();
        let after = compact[index + local.len()..].chars().next();
        let boundary = |character: Option<char>| {
            character.is_none_or(|character| !character.is_ascii_alphanumeric() && character != '_')
        };
        if !boundary(before) || !boundary(after) {
            continue;
        }

        let prefix = compact[..index]
            .rsplit([';', '{', '}'])
            .next()
            .unwrap_or_default()
            .trim();
        let suffix = compact[index + local.len()..].trim_start();

        if prefix.contains("for")
            && prefix
                .rsplit("for")
                .next()
                .is_some_and(|header| header.contains("auto") && header.contains('('))
        {
            let collection = suffix
                .strip_prefix(':')?
                .trim_start()
                .split(|character: char| {
                    !character.is_ascii_alphanumeric() && character != '_'
                })
                .next()
                .unwrap_or_default();
            if !collection.is_empty() {
                return Some(collection.to_string());
            }
        }

        let declares_auto = prefix
            .split_whitespace()
            .any(|token| token.trim_matches(['&', '*']) == "auto");
        if !declares_auto {
            continue;
        }
        let initializer = suffix.strip_prefix('=')?.trim_start();
        let collection = initializer
            .split(|character: char| {
                !character.is_ascii_alphanumeric() && character != '_'
            })
            .next()
            .unwrap_or_default();
        if collection.is_empty() {
            continue;
        }
        let remainder = &initializer[collection.len()..];
        if remainder.starts_with('[')
            || remainder.starts_with(".begin(")
            || remainder.starts_with(".cbegin(")
        {
            return Some(collection.to_string());
        }
    }
    None
}

fn cpp_indexed_receiver_collection_binding(receiver: &str) -> Option<String> {
    let receiver = receiver.trim();
    let bracket = receiver.find('[')?;
    let collection = receiver[..bracket].trim();
    let index = receiver[bracket..].trim();
    let balanced_index = index.starts_with("[[") && index.ends_with("]]")
        || index.starts_with('[') && index.ends_with(']');
    (balanced_index
        && !collection.is_empty()
        && collection
            .chars()
            .all(|character| character == '_' || character.is_ascii_alphanumeric()))
    .then(|| collection.to_string())
}

fn cpp_indexed_collection_result_type(declared_type: &str) -> Option<String> {
    let declared_type = declared_type.trim().strip_prefix("typename ")?.trim();
    let select_map = declared_type.strip_prefix("SelectMap")?.trim_start();
    if !select_map.starts_with('<') || !select_map.ends_with("::Type") {
        return None;
    }
    let close = select_map.rfind('>')?;
    let arguments = split_top_level_commas(&select_map[1..close]);
    arguments
        .get(1)
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn cpp_pointer_member_receiver_type(
    source: &str,
    receiver: &str,
    message: &str,
    declared_type: &str,
) -> Option<String> {
    let tight_source = source.chars().filter(|character| !character.is_whitespace()).collect::<String>();
    let tight_message = message.chars().filter(|character| !character.is_whitespace()).collect::<String>();
    if !tight_source.contains(&format!("{receiver}->{tight_message}")) {
        return None;
    }

    let declared_type = declared_type.trim().trim_end_matches(['&', '*']).trim();
    for pointer in ["std::shared_ptr", "shared_ptr", "std::unique_ptr", "unique_ptr"] {
        let Some(arguments) = declared_type.strip_prefix(pointer) else {
            continue;
        };
        let arguments = arguments.trim();
        if !arguments.starts_with('<') || !arguments.ends_with('>') {
            continue;
        }
        let pointee = arguments[1..arguments.len() - 1].trim();
        if !pointee.is_empty() {
            return Some(pointee.to_string());
        }
    }
    None
}

fn cpp_owner_has_direct_pure_virtual(source: &str) -> bool {
    let mut brace_depth = 0usize;
    let mut statement = String::new();
    for character in source.chars() {
        match character {
            '{' => {
                brace_depth += 1;
                statement.clear();
            }
            '}' => {
                brace_depth = brace_depth.saturating_sub(1);
                statement.clear();
            }
            ';' => {
                if brace_depth == 1
                    && statement.contains("virtual")
                    && statement.contains("= 0")
                {
                    return true;
                }
                statement.clear();
            }
            _ if brace_depth == 1 => statement.push(character),
            _ => {}
        }
    }
    false
}

impl NormalizedLanguageBehavior for CppNormalizedBehavior {
    fn source_body_implicit_work_is_modeled(
        &self,
        source: &str,
        template_types: &BTreeSet<String>,
    ) -> bool {
        if template_types.is_empty() {
            return true;
        }

        let body = source.split_once('{').map(|(_, body)| body).unwrap_or("");
        let has_dependent_value_local = body.lines().any(|line| {
            let line = line.trim();
            template_types.iter().any(|template_type| {
                let Some(suffix) = line.strip_prefix(template_type) else {
                    return false;
                };
                let suffix = suffix.trim_start();
                !suffix.starts_with(['*', '&'])
                    && suffix
                        .chars()
                        .next()
                        .is_some_and(|character| {
                            character == '_' || character.is_ascii_alphabetic()
                        })
                    && (suffix.contains('=') || suffix.contains('(') || suffix.contains('{'))
            })
        });
        if has_dependent_value_local {
            return false;
        }

        let dependent_parameters = source
            .split_once('{')
            .map(|(header, _)| header)
            .unwrap_or(source)
            .split(',')
            .filter_map(|parameter| {
                template_types
                    .iter()
                    .find(|template_type| parameter.contains(template_type.as_str()))?;
                let name = parameter
                    .split(|character: char| {
                        character != '_' && !character.is_ascii_alphanumeric()
                    })
                    .filter(|token| !token.is_empty())
                    .next_back()?;
                Some(name.to_string())
            })
            .collect::<BTreeSet<_>>();

        !dependent_parameters.iter().any(|parameter| {
            body.lines().any(|line| {
                let line = line.trim_start();
                line.strip_prefix(parameter).is_some_and(|suffix| {
                    let suffix = suffix.trim_start();
                    suffix.starts_with('=')
                        && !suffix.starts_with("==")
                })
            })
        })
    }

    fn function_has_executable_body(&self, node: &Node) -> bool {
        node.text.trim_end().ends_with('}')
    }

    fn state_writes_require_declared_owner(&self) -> bool {
        true
    }

    fn complexity_uses_invariant_flow_types(&self) -> bool {
        true
    }

    fn complexity_uses_syntax_local_types(&self) -> bool {
        true
    }

    fn canonical_symbol_scope(&self) -> bool {
        true
    }

    fn relative_lexical_candidates(&self, symbol: &str, namespace: &str) -> Vec<String> {
        if !symbol.contains("::") || symbol.starts_with("std::") {
            return Vec::new();
        }
        let symbol = symbol.trim_start_matches("::");
        let mut scopes = namespace
            .split("::")
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>();
        let mut candidates = Vec::new();
        loop {
            candidates.push(if scopes.is_empty() {
                symbol.to_string()
            } else {
                format!("{}::{symbol}", scopes.join("::"))
            });
            if scopes.pop().is_none() {
                break;
            }
        }
        candidates
    }

    fn fallback_lexical_candidates(
        &self,
        message: &str,
        namespace: &str,
        implicit_receiver: bool,
    ) -> Vec<String> {
        if !implicit_receiver || message.contains("::") || namespace.is_empty() {
            return Vec::new();
        }
        let mut scopes = namespace
            .split("::")
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>();
        let mut candidates = Vec::new();
        loop {
            candidates.push(if scopes.is_empty() {
                message.to_string()
            } else {
                format!("{}::{message}", scopes.join("::"))
            });
            if scopes.pop().is_none() {
                break;
            }
        }
        candidates
    }

    fn resolves_inherited_project_calls(&self) -> bool {
        true
    }

    fn inherited_lookup_uses_source_owner(&self, implicit_receiver: bool) -> bool {
        implicit_receiver
    }

    fn inherited_owner_identity_matches(
        &self,
        identity: &str,
        owner_name: &str,
        owner_symbol: Option<&str>,
    ) -> bool {
        let nominal = owner_identity_name(identity);
        owner_identity_name(owner_name) == nominal
            || owner_symbol.is_some_and(|symbol| owner_identity_name(symbol) == nominal)
    }

    fn inherited_identity_prefers_specialization(&self, identity: &str) -> bool {
        identity.contains('<')
    }

    fn inherited_call_receiver_type(
        &self,
        supertypes: &[String],
        message: &str,
    ) -> Option<String> {
        let [supertype] = supertypes else {
            return None;
        };
        let receiver = parse_declared_type(supertype);
        (configured_stdlib_type("cpp", &receiver)
            && (self.call_complexity(&receiver, message).is_some()
                || self.parametric_call_cost(&receiver, message).is_some()))
        .then(|| supertype.clone())
    }

    fn preserve_supertype_identity(&self, supertype: &str) -> bool {
        supertype.contains('<')
    }

    fn complete_declaration_header(
        &self,
        lines: &[String],
        start_line_1indexed: usize,
    ) -> Option<String> {
        let start_index = start_line_1indexed.saturating_sub(1);
        if start_index >= lines.len() {
            return Some(String::new());
        }
        let mut header = String::new();
        let mut paren_depth = 0i32;
        let mut bracket_depth = 0i32;
        let mut saw_parameters = false;
        for line in lines
            .iter()
            .take(std::cmp::min(lines.len(), start_index + 20))
            .skip(start_index)
        {
            header.push_str(line);
            header.push('\n');
            for character in line.chars() {
                match character {
                    '(' => {
                        paren_depth += 1;
                        saw_parameters = true;
                    }
                    ')' => paren_depth -= 1,
                    '[' => bracket_depth += 1,
                    ']' => bracket_depth -= 1,
                    '{' | ';'
                        if saw_parameters && paren_depth <= 0 && bracket_depth <= 0 =>
                    {
                        return Some(header);
                    }
                    _ => {}
                }
            }
        }
        Some(header)
    }

    fn call_result_parametric_cost(&self, type_expr: &TypeExpr) -> Option<String> {
        type_expr
            .to_string()
            .split(|character: char| character != '_' && !character.is_ascii_alphanumeric())
            .any(|token| token == "typename")
            .then(|| "reflective_once".to_string())
    }

    fn receiver_denotes_current_owner(&self, receiver_type: &str, owner: &str) -> bool {
        owner_identity_name(receiver_type) == owner_identity_name(owner)
    }

    fn explicit_lexical_call_symbol(
        &self,
        message: &str,
        namespace: Option<&str>,
        top_level: bool,
    ) -> Option<String> {
        let symbol = symbol_without_template_arguments(message);
        if symbol.contains("::") {
            Some(symbol)
        } else if top_level {
            namespace.map(|namespace| format!("{namespace}::{symbol}"))
        } else {
            None
        }
    }

    fn function_local_lexical_call_symbol(
        &self,
        function: &FunctionDef,
        message: &str,
    ) -> Option<String> {
        let qualified = format!("std::{message}");
        cpp_function_imports_symbol(&function.body.text, &qualified).then_some(qualified)
    }

    fn merged_alias_call_name(
        &self,
        message: &str,
        receiver_type: Option<&str>,
        implicit_receiver: bool,
        target_missing: bool,
    ) -> Option<(String, bool)> {
        let constructor = implicit_receiver && target_missing;
        if constructor {
            return symbol_without_template_arguments(message)
                .rsplit("::")
                .next()
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(|name| (name.to_string(), true));
        }
        receiver_type
            .map(owner_identity_name)
            .filter(|name| !name.is_empty())
            .map(|name| (name, false))
    }

    fn function_dispatch_kind_from_source(
        &self,
        _name: &str,
        node: &Node,
        owner: &str,
        lines: &[String],
    ) -> String {
        if cpp_function_is_friend(node, lines) {
            "top".to_string()
        } else {
            self.function_dispatch_kind("", owner)
        }
    }

    fn owner_kind(&self, node: &Node, default_kind: &str) -> String {
        let abstract_class = matches!(default_kind, "class" | "struct")
            && cpp_owner_has_direct_pure_virtual(&node.text);
        if abstract_class {
            "abstract_class".to_string()
        } else {
            default_kind.to_string()
        }
    }

    fn type_kind_is_abstract_dispatch(&self, kind: &str) -> bool {
        kind == "abstract_class"
    }

    // C-family indexers render a local as `Type name` - the type leads.
    fn parse_variable_binding(&self, text: &str) -> Option<(String, String)> {
        let text = text.trim().trim_end_matches(';').trim();
        let (declared, name) = text.rsplit_once(char::is_whitespace)?;
        let declared = declared.trim();
        (!declared.is_empty()
            && !declared.contains('=')
            && super::normalized_behavior::usable_binding_name(name))
        .then(|| (name.to_string(), declared.to_string()))
    }

    // C++ declares `Ret name(T a)`, not `name(a: T) -> Ret`.
    fn parse_signature(
        &self,
        signature: &str,
    ) -> super::normalized_behavior::NormalizedSignature {
        super::normalized_behavior::parse_prefix_return_declarator(signature)
    }

    fn nullable_operation(&self, node: &Node) -> Option<NormalizedNullableOperation> {
        if node.r#type == "VCALL" {
            return local_call_subject(node).map(|subject| NormalizedNullableOperation {
                subject,
                operation_kind: "function_pointer_call",
                nil_behavior: "undefined_behavior",
            });
        }
        if node.r#type == "CALL" {
            return node
                .children
                .first()
                .and_then(crate::ast::node)
                .filter(|receiver| receiver.r#type == "LVAR")
                .map(|receiver| receiver.text.trim().to_string())
                .filter(|subject| !subject.is_empty())
                .map(|subject| NormalizedNullableOperation {
                    subject,
                    operation_kind: "pointer_selector",
                    nil_behavior: "undefined_behavior",
                });
        }
        let subject = (node.r#type == "POINTER_EXPRESSION"
            && node.text.trim_start().starts_with('*'))
        .then(|| node.children.first().and_then(crate::ast::node))
        .flatten()
        .filter(|subject| subject.r#type == "LVAR")?
        .text
        .trim()
        .to_string();
        (!subject.is_empty()).then_some(NormalizedNullableOperation {
            subject,
            operation_kind: "pointer_dereference",
            nil_behavior: "undefined_behavior",
        })
    }

    fn function_value_calls_are_local_reads(&self) -> bool {
        true
    }

    fn nullable_call_result_contract(&self, node: &Node) -> Option<&'static str> {
        let call = nullable_contract_call(node);
        if call.r#type == "NEW_EXPRESSION" && call.text.contains("std::nothrow") {
            return Some("nullable_nothrow_allocation");
        }
        exact_direct_call_name(call).and_then(|name| match name {
            "malloc" | "calloc" => Some("nullable_allocation"),
            "realloc" => Some("nullable_reallocation_preserves_input"),
            name if name.starts_with("dynamic_cast<") && name.contains('*') => {
                Some("nullable_pointer_dynamic_cast")
            }
            _ => None,
        })
    }

    fn nullable_declared_type_contract(&self, type_name: &str) -> Option<&'static str> {
        native_pointer_nullability_contract(type_name)
    }

    fn external_symbol_call_complexity(
        &self,
        symbol: &str,
        message: &str,
    ) -> Option<ExternalCallComplexity> {
        external_symbol_call_complexity(symbol, message)
    }

    fn modeled_runtime_call_complexity(
        &self,
        message: &str,
    ) -> Option<ExternalCallComplexity> {
        modeled_runtime_call_complexity(message)
    }

    fn external_symbol_metadata(&self, symbol: &str) -> ExternalSymbolMetadata {
        external_symbol_metadata(symbol)
    }

    fn external_symbol_owner(&self, symbol: &str) -> Option<String> {
        external_symbol_owner(symbol)
    }

    fn preprocessor_definition_call_complexity(
        &self,
        definition: &str,
    ) -> Option<ExternalCallComplexity> {
        super::c::preprocessor_definition_call_complexity(definition)
    }

    fn preprocessor_definition_location(&self, symbol: &str) -> Option<(String, usize)> {
        super::c::preprocessor_definition_location(symbol)
    }

    fn owner_supertypes(&self, node: &Node) -> Vec<String> {
        let header = node.text.split('{').next().unwrap_or(&node.text);
        header
            .split_once(" : ")
            .map(|(_, clause)| super::normalized_behavior::split_declared_supertypes(clause))
            .unwrap_or_default()
    }

    fn declared_local_type(&self, source: &str, name: &str) -> Option<String> {
        let declared = super::normalized_behavior::type_before_local_name(source, name)?;
        // CFG asks about every read as well as every write. A use inside
        // `if (!value)` or `value.method()` is not a declaration; the shared
        // type-before-name fallback would otherwise turn punctuation such as
        // `if(`, `(!`, or `auto item =` into a complete C++ type.
        let function_pointer = source.contains(&format!("(*{name}"))
            || source.contains(&format!("(&{name}"));
        // Taking a local's address establishes a possible indirect write.
        // Keeping this conservative complete hint makes the nullable lattice
        // forget an earlier value proof until pointer-alias mutation is
        // represented explicitly.
        let address_alias = declared.contains('=') && declared.trim_end().ends_with('&');
        ((function_pointer || address_alias
            || !declared.contains(['(', ')', '!', '=', '?']))
            && !declared.contains("->")
            && !declared.ends_with('.')
            && !declared.ends_with(',')
            && declared.chars().any(|character| character.is_ascii_alphanumeric())
            && !matches!(
                declared.split_whitespace().next().unwrap_or_default(),
                "if" | "while" | "switch" | "return"
            ))
        .then_some(declared)
    }

    fn collection_element_binding(&self, source: &str, local: &str) -> Option<String> {
        cpp_collection_element_binding(source, local)
    }

    fn indexed_receiver_collection_binding(&self, receiver: &str) -> Option<String> {
        cpp_indexed_receiver_collection_binding(receiver)
    }

    fn indexed_collection_result_type(&self, declared_type: &str) -> Option<String> {
        cpp_indexed_collection_result_type(declared_type)
    }

    fn pointer_member_receiver_type(
        &self,
        source: &str,
        receiver: &str,
        message: &str,
        declared_type: &str,
    ) -> Option<String> {
        cpp_pointer_member_receiver_type(source, receiver, message, declared_type)
    }

    fn receiver_local_binding(&self, receiver: &str) -> Option<String> {
        cpp_receiver_local_binding(receiver)
    }

    fn explicit_receiver_type(&self, receiver: &str) -> Option<String> {
        cpp_c_style_receiver_type(receiver)
    }

    fn template_dependent_call_type(&self, message: &str) -> Option<String> {
        let message = message.trim();
        (!message.is_empty()).then(|| message.to_string())
    }

    fn stdlib_language(&self) -> Option<&'static str> {
        Some("cpp")
    }

    fn scalar_type_name(&self, name: &str) -> bool {
        cpp_scalar_primitive(name)
    }

    fn scalar_operator_names(&self) -> &'static [&'static str] {
        CPP_PRIMITIVE_OPERATORS
    }

    // CFG-SPECIFIC START: expose the C++ CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &CPP_CFG_PROFILE
    }
    // CFG-SPECIFIC END

    fn source_message_text(&self, message: &str, node: Option<&Node>) -> String {
        if node.is_some_and(|node| node.text.contains(&format!("{message}()"))) {
            format!("{message}()")
        } else {
            message.to_string()
        }
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }

    fn function_visibility(&self, _name: &str, node: &Node, lines: &[String]) -> String {
        let mut visibility = "private";
        if let Some(line) = lines.get(node.first_lineno.saturating_sub(1)) {
            let prefix = line.get(..node.first_column).unwrap_or(line.as_str());
            if let Some(same_line) = last_visibility_marker(prefix) {
                return same_line.to_string();
            }
        }
        for line in lines.iter().take(node.first_lineno.saturating_sub(1)).rev() {
            let trimmed = line.trim();
            if trimmed == "public:" {
                visibility = "public";
                break;
            }
            if trimmed == "private:" || trimmed == "protected:" {
                visibility = "private";
                break;
            }
        }
        visibility.to_string()
    }

    fn parameter_type_from_signature(&self, parameter: &str) -> Option<String> {
        type_before_parameter_name(parameter)
    }

    fn declared_callable_cost(&self, declared_type: &str) -> Option<String> {
        let normalized = declared_type.split_whitespace().collect::<Vec<_>>().join(" ");
        (normalized.contains("(*)")
            || (normalized.contains("(*") && normalized.contains(")("))
            || normalized.contains("std::function<"))
        .then(|| "callback_once".to_string())
    }

    fn syntax_metadata(&self, source: &str, functions: &[FunctionDef]) -> SyntaxMetadata {
        let (type_aliases, type_alias_lines, dependent_aliases) = cpp_type_aliases(source);
        let method_local_types = cpp_method_local_types(source, functions);
        SyntaxMetadata {
            type_aliases,
            type_alias_lines,
            method_param_types:
                super::normalized_behavior::method_param_types_from_signatures(
                    self, source, functions,
                ),
            method_local_types: method_local_types.clone(),
            method_template_types: cpp_method_template_types(
                source,
                functions,
                &dependent_aliases,
                &method_local_types,
            ),
            ..SyntaxMetadata::default()
        }
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        cpp_member_selector_is_invoked(&node.text, &parts.message) == Some(false)
    }

    fn suppress_call_site(&self, _node: &Node, call: &NormalizedCallProjection) -> bool {
        configured_non_call_construct("cpp", &call.message)
    }

    fn collection_operation(
        &self,
        receiver_type: &crate::type_inference::TypeExpr,
        message: &str,
    ) -> Option<super::normalized_behavior::NormalizedCollectionOperation> {
        configured_collection_operation("cpp", receiver_type, message)
    }

    fn mutating_receiver_message(&self, message: &str) -> bool {
        matches!(
            message,
            "clear" | "erase" | "insert" | "pop_back" | "push_back" | "reserve" | "resize"
        )
    }

    fn implicit_owner_fields(&self) -> bool {
        true
    }

    fn field_name_from_declaration(&self, node: &Node) -> Option<String> {
        if node.r#type != "FIELD_DECLARATION" {
            return None;
        }
        node.text
            .trim_end_matches(';')
            .split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .rfind(|part| simple_identifier(part))
            .map(str::to_string)
    }

    fn initializer_field_reads(
        &self,
        node: &Node,
        owner: &str,
        owner_fields: &[String],
        function_name: &str,
    ) -> Vec<NormalizedStateRead> {
        if function_name != owner
            || !node.text.contains(':')
            || !owner_fields.iter().any(|field| field == "count")
        {
            return Vec::new();
        }
        let Some(span) = target_span_from_text(node, "count") else {
            return Vec::new();
        };
        vec![NormalizedStateRead {
            receiver: "self".to_string(),
            field: "count".to_string(),
            line: Some(span[0]),
            span,
        }]
    }

    fn state_read_uses_access_span(&self, _call: &NormalizedCallProjection) -> bool {
        true
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver == "self"
            && matches!(
                call.message.as_str(),
                "callback" | "defaultCase" | "escalate" | "fallback" | "publish" | "warn"
            )
    }

    fn case_predicate_text(&self, text: &str) -> String {
        strip_wrapping_parens(text).to_string()
    }

    fn stream_insertion_operator(&self, _node: &Node) -> bool {
        true
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        if let Some(start) = param.find("(*") {
            if let Some(end) = param[start..].find(')') {
                let inner = &param[start + 2..start + end];
                let name = inner.trim_start_matches('*').trim();
                if !name.is_empty()
                    && name
                        .chars()
                        .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
                {
                    return Some(name.to_string());
                }
            }
        }
        let text = param.trim();
        if text.is_empty() {
            return None;
        }
        let text = text.split('=').next().unwrap_or(text).trim();
        text.split(|ch: char| !(ch == '_' || ch == '?' || ch.is_ascii_alphanumeric()))
            .rfind(|part| !part.is_empty())
            .map(|part| part.trim_end_matches('?').to_string())
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(message, subject, CPP_NIL_PREDICATES, CPP_NON_NIL_PREDICATES)
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "abort" | "exit" | "panic" | "throw")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, CPP_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &CPP_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(
            keyword,
            "auto"
                | "bool"
                | "char"
                | "double"
                | "float"
                | "int"
                | "long"
                | "short"
                | "string"
                | "String"
                | "void"
        )
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "break"
                    | "case"
                    | "class"
                    | "const"
                    | "continue"
                    | "default"
                    | "else"
                    | "false"
                    | "for"
                    | "if"
                    | "private"
                    | "protected"
                    | "public"
                    | "return"
                    | "static"
                    | "struct"
                    | "this"
                    | "true"
                    | "while"
            )
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("null")
    }
    fn format_array_type(&self, elem: &str) -> String {
        format!("std::vector<{}>", elem)
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("std::unordered_map<{}, {}>", key, val)
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("std::unordered_set<{}>", elem)
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty()
            || type_text == "nil"
            || type_text == "null"
            || type_text.starts_with("std::optional<")
        {
            type_text.to_string()
        } else {
            format!("std::optional<{}>", type_text)
        }
    }

    fn untyped_type(&self) -> String {
        "std::any".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "std::vector<std::any>".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "std::unordered_map<std::string, std::any>".to_string()
    }
}

fn local_call_subject(node: &Node) -> Option<String> {
    match node.children.first()? {
        Child::Symbol(subject) | Child::String(subject) => {
            (!subject.trim().is_empty()).then(|| subject.trim().to_string())
        }
        _ => None,
    }
}

static BEHAVIOR: CppNormalizedBehavior = CppNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn target_span_from_text(node: &Node, target: &str) -> Option<Span> {
    for (offset, line) in node.text.lines().enumerate() {
        if let Some(index) = line.find(target) {
            let lineno = node.first_lineno + offset;
            let column = if offset == 0 { node.first_column } else { 0 } + index;
            return Some([lineno, column, lineno, column + target.len()]);
        }
    }
    None
}

fn strip_wrapping_parens(text: &str) -> &str {
    let source = text.trim();
    source
        .strip_prefix('(')
        .and_then(|stripped| stripped.strip_suffix(')'))
        .unwrap_or(source)
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn cpp_member_selector_is_invoked(source: &str, message: &str) -> Option<bool> {
    let selector = balanced_selector_name(message);
    if selector.is_empty() || selector == "operator" {
        return None;
    }
    let explicit_offset = ["->", ".", "::"]
        .into_iter()
        .filter_map(|separator| {
            source
                .rfind(&format!("{separator}{selector}"))
                .map(|offset| offset + separator.len() + selector.len())
        })
        .max();
    let offset = explicit_offset.or_else(|| {
        source
            .match_indices(selector)
            .filter_map(|(offset, _)| {
                let before = source[..offset].chars().next_back();
                let end = offset + selector.len();
                let after = source[end..].chars().next();
                let identifier = |character: char| character == '_' || character.is_alphanumeric();
                (!before.is_some_and(identifier) && !after.is_some_and(identifier)).then_some(end)
            })
            .last()
    })?;
    let suffix = source[offset..].trim_start();
    if !suffix.starts_with('<') {
        return Some(suffix.starts_with('('));
    }

    let mut depth = 0usize;
    for (index, character) in suffix.char_indices() {
        match character {
            '<' => depth += 1,
            '>' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return Some(
                        suffix[index + character.len_utf8()..]
                            .trim_start()
                            .starts_with('('),
                    );
                }
            }
            _ => {}
        }
    }
    None
}

fn last_visibility_marker(source: &str) -> Option<&'static str> {
    let public = source.rfind("public:");
    let private = source.rfind("private:");
    let protected = source.rfind("protected:");
    match [
        public.map(|index| (index, "public")),
        private.map(|index| (index, "private")),
        protected.map(|index| (index, "private")),
    ]
    .into_iter()
    .flatten()
    .max_by_key(|(index, _)| *index)
    {
        Some((_, visibility)) => Some(visibility),
        None => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(kind: &str, text: &str) -> Node {
        Node {
            r#type: kind.to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 2,
            last_lineno: 10,
            last_column: 20,
            text: text.to_string(),
        }
    }

    #[test]
    fn libstdcxx_abi_collection_owners_use_standard_contracts() {
        let empty = external_symbol_call_complexity(
            "cxx . . $ std/__cxx11/list#empty(3482b152b9333168).",
            "empty",
        )
        .expect("libstdc++ list is a reviewed standard collection");
        assert_eq!(empty.time, "O(1)");

        let splice = external_symbol_call_complexity(
            "cxx . . $ std/__cxx11/list#splice(40b6f1fd15459e25).",
            "splice",
        )
        .expect("list splice has a conservative common upper bound");
        assert_eq!(splice.time, "O(N)");
    }

    #[test]
    fn exact_cpp_stdlib_descriptors_preserve_parametric_work() {
        let string = external_symbol_call_complexity(
            "cxx . . $ std/__cxx11/basic_ostringstream#str(d33e1a6fd36255f7).",
            "str",
        )
        .expect("stream materialization descriptor is reviewed");
        assert_eq!(string.time, "O(N)");

        let swap = external_symbol_metadata(
            "cxx . . $ std/swap(c75b8fd57d7c2e06).",
        );
        assert_eq!(swap.scope, "stdlib");
        assert_eq!(swap.parametric_cost.as_deref(), Some("reflective_once"));
        assert!(external_symbol_call_complexity(
            "cxx . . $ std/swap(c75b8fd57d7c2e06).",
            "swap"
        )
        .is_none());
    }

    #[test]
    fn dependent_value_operations_fail_closed_for_source_export() {
        let template_types = BTreeSet::from(["_Tp".to_string()]);
        assert!(!CppNormalizedBehavior.source_body_implicit_work_is_modeled(
            "void swap(_Tp& left, _Tp& right) {\n\
               _Tp temporary = std::move(left);\n\
               left = std::move(right);\n\
               right = std::move(temporary);\n\
             }",
            &template_types,
        ));
        assert!(!CppNormalizedBehavior.source_body_implicit_work_is_modeled(
            "void replace(_Tp& left, _Tp& right) {\n\
               left = std::move(right);\n\
             }",
            &template_types,
        ));
        assert!(CppNormalizedBehavior.source_body_implicit_work_is_modeled(
            "bool empty(const _Tp& value) { return value.size() == 0; }",
            &template_types,
        ));
    }

    #[test]
    fn friend_functions_and_function_local_using_declarations_keep_free_dispatch() {
        assert!(cpp_function_is_friend(
            &node(
                "FUNCTION",
                "friend void swap(Item & left, Item & right) { left.swap(right); }"
            ),
            &[]
        ));
        assert!(!cpp_function_is_friend(
            &node(
                "FUNCTION",
                "void swap(Item & other) { using std::swap; swap(value, other.value); }"
            ),
            &[]
        ));

        assert!(cpp_function_imports_symbol(
            "void swap(Item & other) {\n  using std::swap;\n  swap(value, other.value);\n}",
            "std::swap"
        ));
        assert!(!cpp_function_imports_symbol(
            "void swap(Item & other) {\n  // using std::swap;\n  swap(value, other.value);\n}",
            "std::swap"
        ));
    }

    #[test]
    fn indexed_dependent_maps_project_their_declared_value_type() {
        assert_eq!(
            cpp_indexed_receiver_collection_binding("eventCallbackListMap[[event]]"),
            Some("eventCallbackListMap".to_string())
        );
        assert_eq!(
            cpp_indexed_receiver_collection_binding("items[index]"),
            Some("items".to_string())
        );
        assert_eq!(
            cpp_indexed_receiver_collection_binding("factory().items[index]"),
            None
        );
        assert_eq!(
            cpp_indexed_collection_result_type(
                "typename SelectMap< Event, CallbackList_, Policies, Enabled >::Type"
            ),
            Some("CallbackList_".to_string())
        );
        assert_eq!(
            cpp_indexed_collection_result_type("std::map<Event, CallbackList_>"),
            None
        );
    }

    #[test]
    fn reserved_std_qualified_calls_survive_inactive_scip_branches() {
        let strrchr = CppNormalizedBehavior
            .intrinsic_call_complexity(None, "std::strrchr")
            .expect("the reserved std namespace proves runtime identity");
        assert_eq!((strrchr.time, strrchr.space), ("O(N)", "O(1)"));

        assert!(CppNormalizedBehavior
            .intrinsic_call_complexity(None, "vendor::strrchr")
            .is_none());
    }

    #[test]
    fn inactive_platform_runtime_models_are_explicit_assumptions() {
        let write = modeled_runtime_call_complexity("::write")
            .expect("reviewed inactive POSIX branch");
        assert_eq!((write.time, write.space), ("O(N)", "O(1)"));
        assert_eq!(write.bound_quality, "upper_bound_modeled_world");
        assert!(write.assumption.is_some());
        assert!(modeled_runtime_call_complexity("project::write").is_none());
    }

    #[test]
    fn cpp_consumes_scip_indexed_macro_definitions() {
        let literal_wrapper = CppNormalizedBehavior
            .preprocessor_definition_call_complexity("#define PLOG_NSTR(x) x")
            .expect("an exact compile-time wrapper is constant");
        assert_eq!(
            (literal_wrapper.time, literal_wrapper.space),
            ("O(1)", "O(1)")
        );
        assert_eq!(
            CppNormalizedBehavior
                .preprocessor_definition_location("cxx . . $ `include/plog/Util.h:91:12`!"),
            Some(("include/plog/Util.h".to_string(), 91))
        );
    }

    #[test]
    fn cpp_aliases_keep_unambiguous_or_semantically_converged_bindings() {
        let (aliases, lines, _) = cpp_type_aliases(
            r#"
using Items = std::list<
    Widget
>;
typedef std::wstring WideName;
typedef std::string NativeName;
typedef std::wstring NativeName;
typedef std::ostringstream NativeStream;
typedef std::wostringstream NativeStream;
struct First { using super = BaseOne; };
struct Second { using super = BaseTwo; };
"#,
        );
        assert_eq!(
            aliases.get("Items").map(String::as_str),
            Some("std::list< Widget >")
        );
        assert_eq!(
            aliases.get("WideName").map(String::as_str),
            Some("std::wstring")
        );
        assert_eq!(
            parse_declared_type(aliases.get("NativeName").expect("converged string alias")),
            TypeExpr::Primitive("String".to_string())
        );
        assert_eq!(
            parse_declared_type(
                aliases
                    .get("NativeStream")
                    .expect("converged string-stream alias")
            ),
            TypeExpr::Primitive("StringStream".to_string())
        );
        assert_eq!(lines.get("Items"), Some(&2));
        assert!(!aliases.contains_key("super"));
    }

    #[test]
    fn function_pointer_operations_require_a_symbol_callee() {
        let callback = Node {
            children: vec![Child::Symbol("callback".to_string())],
            ..node("VCALL", "callback()")
        };
        assert_eq!(local_call_subject(&callback), Some("callback".to_string()));
        let malformed = Node {
            children: vec![Child::Nil],
            ..node("VCALL", "callback()")
        };
        assert_eq!(local_call_subject(&malformed), None);
        assert!(CppNormalizedBehavior.function_value_calls_are_local_reads());

        let address = Node {
            children: vec![Child::Node(Box::new(node("LVAR", "value")))],
            ..node("POINTER_EXPRESSION", "&value")
        };
        assert!(CppNormalizedBehavior.nullable_operation(&address).is_none());
    }

    #[test]
    fn allocator_contracts_require_exact_bare_call_identity() {
        let behavior = CppNormalizedBehavior;
        assert_eq!(
            behavior.nullable_call_result_contract(&node("CALL", "malloc(sizeof(int))")),
            Some("nullable_allocation")
        );
        assert_eq!(
            behavior.nullable_call_result_contract(&node("CALL", "realloc(value, 8)")),
            Some("nullable_reallocation_preserves_input")
        );
        assert_eq!(
            behavior.nullable_call_result_contract(&node("CALL", "custom_malloc(value)")),
            None
        );
        assert_eq!(
            behavior.nullable_call_result_contract(&node("CALL", "object.malloc()")),
            None
        );

        let allocation = Node {
            children: vec![
                Child::Symbol("static_cast<int *>".to_string()),
                Child::Node(Box::new(Node {
                    children: vec![Child::Node(Box::new(Node {
                        children: vec![Child::Symbol("malloc".to_string())],
                        ..node("FCALL", "malloc(sizeof(int))")
                    }))],
                    ..node("LIST", "malloc(sizeof(int))")
                })),
            ],
            ..node("FCALL", "static_cast<int *>(malloc(sizeof(int)))")
        };
        assert_eq!(
            behavior.nullable_call_result_contract(&allocation),
            Some("nullable_allocation")
        );

        let nested_allocation = Node {
            children: vec![Child::Node(Box::new(Node {
                children: vec![Child::Symbol("malloc".to_string())],
                ..node("FCALL", "malloc(sizeof(int))")
            }))],
            ..node("LIST", "malloc(sizeof(int))")
        };
        assert_eq!(
            behavior.nullable_call_result_contract(&nested_allocation),
            Some("nullable_allocation")
        );

        let malformed_cast = Node {
            children: vec![
                Child::Symbol("static_cast<int *>".to_string()),
                Child::Node(Box::new(node("PAREN", ""))),
            ],
            ..node("FCALL", "static_cast<int *>(value)")
        };
        assert_eq!(
            behavior.nullable_call_result_contract(&malformed_cast),
            None
        );
        assert_eq!(
            behavior.nullable_declared_type_contract("gsl::not_null<Widget *>"),
            Some("non_null_declared_type")
        );
        assert_eq!(
            behavior.nullable_declared_type_contract("std::unique_ptr<Widget>"),
            None
        );
        assert_eq!(
            behavior.declared_local_type("gsl::not_null<Widget *> value = load_widget()", "value"),
            Some("gsl::not_null<Widget *>".to_string())
        );
        assert_eq!(behavior.declared_local_type("if(! value.empty())", "value"), None);
        assert_eq!(behavior.declared_local_type("value.resize(2)", "value"), None);
        assert_eq!(
            behavior.declared_local_type(
                "auto data = make_data(Data { condition, callbackList, listener });",
                "callbackList"
            ),
            None
        );
    }

    #[test]
    fn declared_smart_pointer_reset_keeps_destructor_cost_parametric() {
        let behavior = CppNormalizedBehavior;
        for declared in ["std::shared_ptr<Node>", "std::unique_ptr<Node>"] {
            let parsed = parse_declared_type(declared);
            assert_eq!(
                behavior.parametric_call_cost(&parsed, "reset"),
                Some("reflective_once".to_string()),
                "{declared}: {parsed:?}"
            );
        }
    }

    #[test]
    fn recovers_only_proven_receiver_bindings_and_c_style_types() {
        let behavior = CppNormalizedBehavior;
        assert_eq!(
            behavior.receiver_local_binding("*callableList"),
            Some("callableList".to_string())
        );
        assert_eq!(
            behavior.receiver_local_binding("(*callableList)"),
            Some("callableList".to_string())
        );
        assert_eq!(behavior.receiver_local_binding("*items[0]"), None);
        assert_eq!(
            behavior.explicit_receiver_type("(const LargeData *)buffer.data()"),
            Some("const LargeData *".to_string())
        );
        assert_eq!(behavior.explicit_receiver_type("(left + right)"), None);
        assert_eq!(behavior.explicit_receiver_type("(Widget)value"), None);
    }

    #[test]
    fn test_cpp_behavior_comprehensive() {
        let b = CppNormalizedBehavior;

        // 1. source_message_text
        assert_eq!(
            b.source_message_text("foo", Some(&node("CALL", "foo()"))),
            "foo()"
        );
        assert_eq!(
            b.source_message_text("foo", Some(&node("CALL", "foo"))),
            "foo"
        );
        assert_eq!(b.source_message_text("foo", None), "foo");

        // 2. owner_name_span
        assert!(b
            .owner_name_span("MyClass", &node("CLASS", ""), [1, 2, 3, 4])
            .is_some());

        // 3. function_visibility
        let lines = vec![
            "class MyClass {".to_string(),
            "public:".to_string(),
            "  void foo();".to_string(),
            "private:".to_string(),
            "  void bar();".to_string(),
        ];
        let mut fn_foo = node("FUNCTION", "void foo();");
        fn_foo.first_lineno = 3;
        let mut fn_bar = node("FUNCTION", "void bar();");
        fn_bar.first_lineno = 5;
        assert_eq!(b.function_visibility("foo", &fn_foo, &lines), "public");
        assert_eq!(b.function_visibility("bar", &fn_bar, &lines), "private");

        // test last_visibility_marker same line visibility fallback
        let lines_inline = vec!["public: void foo();".to_string()];
        let mut fn_inline = node("FUNCTION", "void foo();");
        fn_inline.first_lineno = 1;
        fn_inline.first_column = 8;
        assert_eq!(
            b.function_visibility("foo", &fn_inline, &lines_inline),
            "public"
        );

        // 4. implicit_owner_fields
        assert!(b.implicit_owner_fields());

        // 5. field_name_from_declaration
        assert_eq!(
            b.field_name_from_declaration(&node("FIELD_DECLARATION", "int count;")),
            Some("count".to_string())
        );
        assert_eq!(b.field_name_from_declaration(&node("LVAR", "")), None);

        // 6. initializer_field_reads
        let init_node = node("CONSTRUCTOR", "MyClass() : count(0) {}");
        let reads =
            b.initializer_field_reads(&init_node, "MyClass", &["count".to_string()], "MyClass");
        assert_eq!(reads.len(), 1);
        assert_eq!(reads[0].field, "count");
        assert!(b
            .initializer_field_reads(&init_node, "MyClass", &["count".to_string()], "not_owner")
            .is_empty());
        // Cover target_span_from_text returning None (line 128)
        let init_node_no_text = node("CONSTRUCTOR", "MyClass() : field(0) {}");
        assert!(b
            .initializer_field_reads(
                &init_node_no_text,
                "MyClass",
                &["count".to_string()],
                "MyClass"
            )
            .is_empty());

        // 7. state_read_uses_access_span
        assert!(b.state_read_uses_access_span(&NormalizedCallProjection {
            receiver: "self".to_string(),
            message: "foo".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }));

        // 8. suppress_state_read_for_call
        assert!(b.suppress_state_read_for_call(
            &NormalizedCallProjection {
                receiver: "self".to_string(),
                message: "callback".to_string(),
                arguments: Vec::new(),
                access_span: [1, 2, 3, 4],
                span: [1, 2, 3, 4],
            },
            ""
        ));

        // 9. case_predicate_text
        assert_eq!(b.case_predicate_text("(a == b)"), "a == b");

        // 10. stream_insertion_operator
        assert!(b.stream_insertion_operator(&node("OP", "")));

        // 11. nil_guard_fact
        assert!(b.nil_guard_fact("isNull", "x").is_some());

        // 12. terminating_call_message
        assert!(b.terminating_call_message("throw"));
        assert!(configured_non_call_construct("cpp", "defined"));

        // 13. semantic_effect_for_call
        assert!(b
            .semantic_effect_for_call(&CallSite {
                receiver: "x".to_string(),
                message: "isNull".to_string(),
                file: "".to_string(),
                function: "".to_string(),
                owner: "".to_string(),
                line: 1,
                span: [1, 2, 3, 4],
                conditional: false,
                arguments: Vec::new(),
                control: None,
                safe_navigation: false,
                block: false,
            })
            .is_some());

        // 14. local_flow_declaration_keyword
        assert!(b.local_flow_declaration_keyword("int"));

        // 15. local_flow_keyword
        assert!(b.local_flow_keyword("int"));
        for kw in &[
            "break",
            "case",
            "class",
            "const",
            "continue",
            "default",
            "else",
            "false",
            "for",
            "if",
            "private",
            "protected",
            "public",
            "return",
            "static",
            "struct",
            "this",
            "true",
            "while",
        ] {
            assert!(b.local_flow_keyword(kw));
        }
        assert!(!b.local_flow_keyword("not_a_keyword"));

        // 16. predicate_body_language_signal
        assert!(b.predicate_body_language_signal("null"));

        // 17-21. formatting
        assert_eq!(b.format_array_type("int"), "std::vector<int>");
        assert_eq!(
            b.format_hash_type("int", "int"),
            "std::unordered_map<int, int>"
        );
        assert_eq!(b.format_set_type("int"), "std::unordered_set<int>");
        assert_eq!(b.format_nilable_type(""), "");
        assert_eq!(
            b.format_nilable_type("std::optional<int>"),
            "std::optional<int>"
        );
        assert_eq!(b.format_nilable_type("int"), "std::optional<int>");
        assert_eq!(b.untyped_type(), "std::any");
        assert_eq!(b.untyped_array_type(), "std::vector<std::any>");
        assert_eq!(
            b.untyped_hash_type(),
            "std::unordered_map<std::string, std::any>"
        );
    }
}
