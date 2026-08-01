//! A digest of what a file *says*, not how it is written.
//!
//! An incremental collect asks one question of every source file: is this the
//! same code it was last time. Digesting the bytes answers a different
//! question, because reindenting a file, rewrapping a line or editing a comment
//! would each retrace the shards that file feeds -- and none of them can change
//! what the program does.
//!
//! So the digest is taken over the parse tree instead: node kinds and the token
//! text that carries meaning, with positions and comments left out. Two files
//! that parse the same have the same fingerprint however they are laid out.
//!
//! Magic comments are the exception that has to be read as code. A
//! `# frozen_string_literal: true` is a comment to the grammar and a directive
//! to the VM, so the leading ones are digested verbatim.

use crate::syntax::{parser_grammar::grammar_for_language, Language};
use sha2::{Digest, Sha256};
use std::path::Path;
use tree_sitter::{Node, Parser};

/// Bump when the digest of unchanged source would change. Every stored
/// snapshot then invalidates and the next incremental collect is a full one,
/// which is correct and one-time -- silently reusing digests from another
/// scheme would skip shards that needed rerunning.
pub const SCHEME: &str = "fact-mine-normalized-tree-v1";

/// Comment-like grammar nodes, whose content cannot change behaviour.
fn is_comment(kind: &str) -> bool {
    kind.contains("comment")
}

/// Leading `# key: value` lines, which the VM reads as directives.
fn magic_comments(source: &str) -> Vec<&str> {
    source
        .lines()
        .take(2)
        .filter(|line| {
            let trimmed = line.trim_start();
            trimmed.starts_with('#')
                && trimmed[1..]
                    .split_once(':')
                    .is_some_and(|(key, _)| {
                        let key = key.trim();
                        !key.is_empty()
                            && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
                    })
        })
        .collect()
}

fn walk(node: Node<'_>, source: &[u8], into: &mut Vec<u8>) {
    let kind = node.kind();
    if is_comment(kind) {
        return;
    }
    if node.child_count() == 0 {
        // A leaf carries its own text: an identifier, a literal, an operator.
        // Two trees of identical shape over different names are different
        // programs.
        into.extend_from_slice(kind.as_bytes());
        into.push(0);
        into.extend_from_slice(node.utf8_text(source).unwrap_or_default().as_bytes());
        into.push(0);
        return;
    }
    into.extend_from_slice(kind.as_bytes());
    into.push(b'(');
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        walk(child, source, into);
    }
    into.push(b')');
}

/// The fingerprint of a file's source, or `None` where it cannot be parsed --
/// an unknown language, an unreadable file. The caller digests the bytes then,
/// which is stricter and never wrong, only noisier.
pub fn of_source(source: &str, language: Language) -> Option<String> {
    let mut parser = Parser::new();
    parser.set_language(&grammar_for_language(language)).ok()?;
    let tree = parser.parse(crate::ast::parse_buffer(source, language), None)?;

    let mut shape = Vec::new();
    for line in magic_comments(source) {
        shape.extend_from_slice(line.trim().as_bytes());
        shape.push(b'\n');
    }
    shape.push(0);
    walk(tree.root_node(), source.as_bytes(), &mut shape);
    Some(format!("{:x}", Sha256::digest(&shape)))
}

/// The fingerprint of a file on disk. Falls back to the byte digest where the
/// file's language has no grammar here.
pub fn of_file(path: &Path) -> Option<String> {
    let source = std::fs::read_to_string(path).ok()?;
    match Language::for_path(path).and_then(|language| of_source(&source, language)) {
        Some(fingerprint) => Some(fingerprint),
        None => Some(format!("{:x}", Sha256::digest(source.as_bytes()))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ruby(source: &str) -> String {
        of_source(source, Language::Ruby).expect("ruby fingerprint")
    }

    #[test]
    fn reformatting_is_not_an_edit() {
        let original = "class App\n  def value\n    1 + 2\n  end\nend\n";
        let reformatted = "class App\n\n    def value\n      1   +   2\n    end\n\nend\n";

        assert_eq!(ruby(original), ruby(reformatted));
    }

    #[test]
    fn a_comment_is_not_an_edit() {
        let bare = "def value\n  1\nend\n";
        let commented = "# explains the value\ndef value\n  1 # inline\nend\n";

        assert_eq!(ruby(bare), ruby(commented));
    }

    #[test]
    fn a_magic_comment_is_an_edit() {
        // It is a comment to the grammar and a directive to the VM.
        let plain = "def value\n  \"a\"\nend\n";
        let frozen = "# frozen_string_literal: true\ndef value\n  \"a\"\nend\n";

        assert_ne!(ruby(plain), ruby(frozen));
        // ... and only where the VM reads it, which is the top of the file.
        let late = "def value\n  \"a\"\nend\n# frozen_string_literal: true\n";
        assert_eq!(ruby(plain), ruby(late));
    }

    #[test]
    fn changing_what_the_code_does_is_an_edit() {
        let before = "def value\n  1 + 2\nend\n";
        assert_ne!(ruby(before), ruby("def value\n  1 - 2\nend\n"));
        assert_ne!(ruby(before), ruby("def value\n  1 + 3\nend\n"));
        // A rename is a change: the tree shape is identical and the names
        // are not.
        assert_ne!(ruby(before), ruby("def other\n  1 + 2\nend\n"));
    }

    #[test]
    fn a_file_that_cannot_be_parsed_still_has_a_fingerprint() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("notes.txt");
        std::fs::write(&path, "not source at all").expect("write");

        let first = of_file(&path).expect("fingerprint");
        assert_eq!(first, of_file(&path).expect("fingerprint"));
        std::fs::write(&path, "different").expect("write");
        assert_ne!(first, of_file(&path).expect("fingerprint"));
    }
}
