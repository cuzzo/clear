use super::super::{named_children, node_text};
use super::base::AstNormalizationAdapter;
use regex::Regex;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct CAstAdapter;

impl AstNormalizationAdapter for CAstAdapter {
    fn preprocessor_callable_names(&self, root: TreeSitterNode<'_>, source: &str) -> Vec<String> {
        preprocessor_callable_names(root, source)
    }

    fn source_preprocessing(&self, source: &str) -> Option<String> {
        Some(strip_native_nullability_annotations(
            &strip_linkage_macros_before_type_name(source),
        ))
    }

    fn case_arm_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "case_statement" {
            return None;
        }
        let body = named_children(node)
            .into_iter()
            .filter(|child| {
                !matches!(
                    child.kind(),
                    "identifier" | "number_literal" | "char_literal" | "break_statement"
                )
            })
            .collect::<Vec<_>>();
        (!body.is_empty()).then_some(body)
    }

    fn custom_function_name(&self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        if node.kind() == "function_definition" {
            if let Some(decl) = node.child_by_field_name("declarator") {
                let mut stack = vec![decl];
                while !stack.is_empty() {
                    let child = stack.remove(0);
                    if child.kind() == "identifier" || child.kind() == "field_identifier" {
                        return Some(super::super::node_text(child, source).to_string());
                    }
                    stack.extend(named_children(child));
                }
            }
        }
        None
    }

    fn assignment_target_name(&self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        if node.kind() != "pointer_declarator" {
            return None;
        }
        named_children(node)
            .into_iter()
            .find(|child| child.kind() == "identifier")
            .map(|child| node_text(child, source).to_string())
    }
}

/// A C/C++ linkage/visibility macro (`class MYLIB_API Foo`, `struct
/// PLOG_LINKAGE Logger`) sits between the `class`/`struct` keyword and the
/// real type name. tree-sitter never expands macros, so it greedily
/// consumes the macro token as the type's own name; the real name that
/// follows derails the grammar into an ERROR-node parse recovery that can
/// swallow the entire class body (methods end up as unrelated top-level
/// declarations, or worse, as a corrupted initializer). Blanking the macro
/// token out (equal-length whitespace, so every later byte offset/span
/// stays valid) before parsing lets tree-sitter see the type declaration it
/// was actually meant to see.
///
/// Scoped to two back-to-back identifiers on the same line where the first
/// is conventionally macro-shaped (all caps/digits/underscore): a
/// legitimate one-word type name never matches (no second identifier before
/// the body/base-clause/`;`), and restricting the gap to `[ \t]` rather
/// than `\s` keeps a match from ever spanning multiple lines. Comments and
/// string/char literals are masked out first so a match can never land
/// inside one - only real code is eligible.
pub(super) fn strip_linkage_macros_before_type_name(source: &str) -> String {
    let masked = mask_comments_and_strings(source);
    let pattern = Regex::new(r"\b(?:class|struct)[ \t]+([A-Z][A-Z0-9_]*)[ \t]+[A-Za-z_]\w*")
        .expect("static regex is valid");
    let mut result = source.as_bytes().to_vec();
    for caps in pattern.captures_iter(&masked) {
        let macro_token = caps
            .get(1)
            .expect("group 1 always matches with the outer match");
        for pos in macro_token.range() {
            result[pos] = b' ';
        }
    }
    String::from_utf8(result).unwrap_or_else(|_| source.to_string())
}

/// tree-sitter-c/cpp do not consistently accept Clang's declaration-only
/// `_Nullable`/`_Nonnull` spelling.  The normalized analysis still needs the
/// original spelling to derive its reviewed contract, so blank only the
/// annotation token in the parser buffer.  This preserves every byte offset;
/// normalizers continue to read the untouched source and retain the type
/// annotation in the emitted declared-type fact.
///
/// Restricting the rewrite to pointer declarators avoids treating an ordinary
/// identifier named `_Nullable` as an annotation.  Comments and literals are
/// masked before matching for the same reason as linkage-macro preprocessing.
pub(super) fn strip_native_nullability_annotations(source: &str) -> String {
    let masked = mask_comments_and_strings(source);
    let pattern = Regex::new(r"\*[ \t]*(?:_Nullable|_Nonnull|__nullable|__nonnull)\b")
        .expect("static regex is valid");
    let mut result = source.as_bytes().to_vec();
    for matched in pattern.find_iter(&masked) {
        let annotation_start = matched
            .as_str()
            .find('_')
            .expect("native annotation match contains an underscore");
        let start = matched.start() + annotation_start;
        for byte in &mut result[start..matched.end()] {
            *byte = b' ';
        }
    }
    String::from_utf8(result).expect("replacing ASCII annotation bytes preserves valid UTF-8")
}

/// Replaces the body of `//`/`/* */` comments and `"..."`/`'...'` literals
/// with `#` (byte-for-byte, preserving length and line/column layout) so a
/// textual heuristic scanning the result can never mistake commented-out or
/// quoted code for the real thing. Delimiters themselves are left in place;
/// only the content between them is masked.
fn mask_comments_and_strings(source: &str) -> String {
    #[derive(Clone, Copy, PartialEq)]
    enum State {
        Normal,
        LineComment,
        BlockComment,
        StringLit(u8),
    }

    let bytes = source.as_bytes();
    let mut out = bytes.to_vec();
    let mut state = State::Normal;
    let mut i = 0;
    while i < bytes.len() {
        match state {
            State::Normal => {
                if bytes[i] == b'/' && bytes.get(i + 1) == Some(&b'/') {
                    state = State::LineComment;
                    i += 2;
                } else if bytes[i] == b'/' && bytes.get(i + 1) == Some(&b'*') {
                    state = State::BlockComment;
                    i += 2;
                } else if bytes[i] == b'"' || bytes[i] == b'\'' {
                    state = State::StringLit(bytes[i]);
                    i += 1;
                } else {
                    i += 1;
                }
            }
            State::LineComment => {
                if bytes[i] == b'\n' {
                    state = State::Normal;
                } else {
                    out[i] = b'#';
                }
                i += 1;
            }
            State::BlockComment => {
                if bytes[i] == b'*' && bytes.get(i + 1) == Some(&b'/') {
                    state = State::Normal;
                    i += 2;
                } else {
                    out[i] = b'#';
                    i += 1;
                }
            }
            State::StringLit(quote) => {
                if bytes[i] == b'\\' && i + 1 < bytes.len() {
                    out[i] = b'#';
                    out[i + 1] = b'#';
                    i += 2;
                } else if bytes[i] == quote {
                    state = State::Normal;
                    i += 1;
                } else {
                    out[i] = b'#';
                    i += 1;
                }
            }
        }
    }
    String::from_utf8(out).unwrap_or_else(|_| source.to_string())
}

pub(super) fn preprocessor_callable_names(root: TreeSitterNode<'_>, source: &str) -> Vec<String> {
    fn visit(node: TreeSitterNode<'_>, source: &str, names: &mut Vec<String>) {
        if node.kind() == "preproc_function_def" {
            if let Some(name) = node.child_by_field_name("name") {
                let name = super::super::node_text(name, source).trim();
                if !name.is_empty() {
                    names.push(name.to_string());
                }
            }
        }
        for child in named_children(node) {
            visit(child, source, names);
        }
    }
    let mut names = Vec::new();
    visit(root, source, &mut names);
    names.sort();
    names.dedup();
    names
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_linkage_macro_and_preserves_byte_length_and_positions() {
        let source =
            "class PLOG_LINKAGE Logger : public IAppender {\npublic:\n    void write() {}\n};\n";
        let stripped = strip_linkage_macros_before_type_name(source);
        assert_eq!(
            stripped.len(),
            source.len(),
            "must preserve total byte length"
        );
        assert!(
            stripped.contains(&format!(
                "class {} Logger : public IAppender {{",
                " ".repeat("PLOG_LINKAGE".len())
            )),
            "expected the macro token blanked with equal-length spaces, got {stripped:?}"
        );
        // Everything after the macro token keeps its original byte offset.
        let real_name_pos = source.find("Logger").unwrap();
        assert_eq!(stripped.find("Logger"), Some(real_name_pos));
    }

    #[test]
    fn does_not_strip_a_legitimate_one_word_type_name() {
        let source = "class URL {\npublic:\n    void parse() {}\n};\n";
        assert_eq!(strip_linkage_macros_before_type_name(source), source);
    }

    #[test]
    fn does_not_strip_inside_a_string_literal_or_comment() {
        let source = "const char* fake = \"class API Fake {}\";\n// class COMMENTED Bogus {}\nclass EXPORT Real {};\n";
        let stripped = strip_linkage_macros_before_type_name(source);
        assert!(
            stripped.contains("\"class API Fake {}\""),
            "a string literal must never be rewritten, got {stripped:?}"
        );
        assert!(
            stripped.contains("// class COMMENTED Bogus {}"),
            "a comment must never be rewritten, got {stripped:?}"
        );
        assert!(
            stripped.contains("class        Real {};"),
            "the real declaration outside any string/comment must still be stripped, got {stripped:?}"
        );
    }

    #[test]
    fn does_not_strip_across_a_line_break() {
        let source = "class\nMYLIB_API\nFoo {\n};\n";
        assert_eq!(
            strip_linkage_macros_before_type_name(source),
            source,
            "the macro-before-name pattern must only match on a single line"
        );
    }

    #[test]
    fn strips_pointer_nullability_annotations_and_preserves_offsets() {
        let source = "Widget * _Nullable value; Widget * __nonnull other;\n";
        let stripped = strip_native_nullability_annotations(source);
        assert_eq!(stripped.len(), source.len());
        assert_eq!(stripped.find("value"), source.find("value"));
        assert_eq!(stripped.find("other"), source.find("other"));
        assert!(!stripped.contains("_Nullable"));
        assert!(!stripped.contains("__nonnull"));
    }

    #[test]
    fn does_not_strip_annotation_words_outside_pointer_declarations() {
        let source = "const char *label = \"_Nullable\"; // _Nonnull\nint _Nullable = 1;\n";
        assert_eq!(strip_native_nullability_annotations(source), source);
    }

    #[test]
    fn uses_pointer_declarator_identifier_as_assignment_target() {
        let source = "Widget * _Nullable value = load_widget();";
        let mut parser = tree_sitter::Parser::new();
        parser
            .set_language(&tree_sitter_c::LANGUAGE.into())
            .unwrap();
        let buffer = strip_native_nullability_annotations(source);
        let tree = parser.parse(&buffer, None).unwrap();
        fn find_pointer(node: TreeSitterNode<'_>) -> Option<TreeSitterNode<'_>> {
            (node.kind() == "pointer_declarator")
                .then_some(node)
                .or_else(|| named_children(node).into_iter().find_map(find_pointer))
        }
        let pointer = find_pointer(tree.root_node()).expect("pointer declarator");
        assert_eq!(
            CAstAdapter.assignment_target_name(pointer, source),
            Some("value".to_string())
        );
    }
}
