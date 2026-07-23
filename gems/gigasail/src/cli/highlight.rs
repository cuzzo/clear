//! Lightweight lexer-based syntax highlighting for the right pane.
//!
//! Full tree-sitter highlighting needs per-language `highlights.scm` queries the
//! crate does not ship. For the diff view a coarse single-line lexer
//! (keywords / strings / comments / numbers) is enough and self-contained: no
//! external editor, no new dependency. Diff add/remove coloring composes on top
//! (the renderer only highlights context lines).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HlKind {
    Plain,
    Keyword,
    Str,
    Comment,
    Number,
}

pub struct Lang {
    keywords: &'static [&'static str],
    line_comments: &'static [&'static str],
}

const RUST_KW: &[&str] = &[
    "fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "for", "in", "if", "else",
    "match", "while", "loop", "return", "use", "mod", "self", "Self", "crate", "super", "as",
    "const", "static", "ref", "move", "where", "type", "dyn", "async", "await", "unsafe",
];
const RUBY_KW: &[&str] = &[
    "def",
    "end",
    "class",
    "module",
    "if",
    "elsif",
    "else",
    "unless",
    "while",
    "until",
    "do",
    "begin",
    "rescue",
    "ensure",
    "return",
    "yield",
    "self",
    "nil",
    "true",
    "false",
    "require",
    "attr_accessor",
    "private",
    "public",
    "protected",
];
const PY_KW: &[&str] = &[
    "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "with",
    "try", "except", "finally", "lambda", "yield", "None", "True", "False", "self", "pass",
    "raise", "in", "not", "and", "or",
];
const JS_KW: &[&str] = &[
    "function",
    "const",
    "let",
    "var",
    "if",
    "else",
    "for",
    "while",
    "return",
    "class",
    "extends",
    "import",
    "export",
    "from",
    "async",
    "await",
    "new",
    "this",
    "super",
    "try",
    "catch",
    "finally",
    "throw",
    "typeof",
    "interface",
    "type",
];
const GO_KW: &[&str] = &[
    "func",
    "var",
    "const",
    "type",
    "struct",
    "interface",
    "if",
    "else",
    "for",
    "range",
    "return",
    "package",
    "import",
    "go",
    "defer",
    "chan",
    "map",
    "switch",
    "case",
    "default",
    "nil",
    "true",
    "false",
];
const C_KW: &[&str] = &[
    "int", "char", "void", "float", "double", "long", "short", "struct", "union", "enum", "if",
    "else", "for", "while", "return", "switch", "case", "default", "const", "static", "typedef",
    "sizeof", "unsigned", "signed", "break", "continue",
];
const ZIG_KW: &[&str] = &[
    "fn", "pub", "const", "var", "if", "else", "while", "for", "return", "struct", "enum", "union",
    "comptime", "try", "catch", "defer", "errdefer", "switch", "test", "and", "or",
];

fn extension(path: &str) -> &str {
    path.rsplit('.').next().unwrap_or("")
}

/// Pick a language table from a file path.
pub fn lang_for_path(path: &str) -> Lang {
    match extension(path) {
        "rs" => Lang {
            keywords: RUST_KW,
            line_comments: &["//"],
        },
        "rb" => Lang {
            keywords: RUBY_KW,
            line_comments: &["#"],
        },
        "py" | "pyi" => Lang {
            keywords: PY_KW,
            line_comments: &["#"],
        },
        "js" | "jsx" | "ts" | "tsx" | "mjs" | "cjs" => Lang {
            keywords: JS_KW,
            line_comments: &["//"],
        },
        "go" => Lang {
            keywords: GO_KW,
            line_comments: &["//"],
        },
        "c" | "h" | "cc" | "cpp" | "cxx" | "hpp" | "hh" | "cs" => Lang {
            keywords: C_KW,
            line_comments: &["//"],
        },
        "zig" => Lang {
            keywords: ZIG_KW,
            line_comments: &["//"],
        },
        "sql" | "lua" => Lang {
            keywords: &[],
            line_comments: &["--"],
        },
        _ => Lang {
            keywords: &[],
            line_comments: &["//", "#"],
        },
    }
}

fn is_ident_start(c: char) -> bool {
    c.is_alphabetic() || c == '_'
}

fn is_ident_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Tokenize a single line into styled spans.
pub fn highlight_line(line: &str, lang: &Lang) -> Vec<(String, HlKind)> {
    let chars: Vec<char> = line.chars().collect();
    let mut out: Vec<(String, HlKind)> = Vec::new();
    let mut plain = String::new();
    let mut i = 0;

    let flush = |plain: &mut String, out: &mut Vec<(String, HlKind)>| {
        if !plain.is_empty() {
            out.push((std::mem::take(plain), HlKind::Plain));
        }
    };

    while i < chars.len() {
        // Line comment: matches any configured prefix -> rest of line.
        let rest: String = chars[i..].iter().collect();
        if let Some(prefix) = lang.line_comments.iter().find(|p| rest.starts_with(**p)) {
            flush(&mut plain, &mut out);
            out.push((rest.clone(), HlKind::Comment));
            let _ = prefix;
            break;
        }

        let c = chars[i];
        if c == '"' || c == '\'' || c == '`' {
            flush(&mut plain, &mut out);
            let quote = c;
            let mut s = String::new();
            s.push(c);
            i += 1;
            while i < chars.len() {
                let ch = chars[i];
                s.push(ch);
                i += 1;
                if ch == '\\' && i < chars.len() {
                    s.push(chars[i]);
                    i += 1;
                    continue;
                }
                if ch == quote {
                    break;
                }
            }
            out.push((s, HlKind::Str));
            continue;
        }

        if c.is_ascii_digit() {
            flush(&mut plain, &mut out);
            let mut n = String::new();
            while i < chars.len()
                && (chars[i].is_ascii_alphanumeric() || chars[i] == '.' || chars[i] == '_')
            {
                n.push(chars[i]);
                i += 1;
            }
            out.push((n, HlKind::Number));
            continue;
        }

        if is_ident_start(c) {
            let mut word = String::new();
            while i < chars.len() && is_ident_char(chars[i]) {
                word.push(chars[i]);
                i += 1;
            }
            if lang.keywords.contains(&word.as_str()) {
                flush(&mut plain, &mut out);
                out.push((word, HlKind::Keyword));
            } else {
                plain.push_str(&word);
            }
            continue;
        }

        plain.push(c);
        i += 1;
    }
    flush(&mut plain, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(spans: &[(String, HlKind)]) -> Vec<(&str, HlKind)> {
        spans.iter().map(|(s, k)| (s.as_str(), *k)).collect()
    }

    #[test]
    fn highlights_keyword_and_ident() {
        let lang = lang_for_path("a.rs");
        let spans = highlight_line("let x = y", &lang);
        assert_eq!(spans[0], ("let".to_string(), HlKind::Keyword));
        // The rest is plain.
        assert!(spans
            .iter()
            .any(|(s, k)| s.contains('x') && *k == HlKind::Plain));
    }

    #[test]
    fn highlights_strings() {
        let lang = lang_for_path("a.rs");
        let spans = highlight_line("let s = \"hi there\";", &lang);
        assert!(spans
            .iter()
            .any(|(s, k)| s == "\"hi there\"" && *k == HlKind::Str));
    }

    #[test]
    fn highlights_line_comment_to_eol() {
        let lang = lang_for_path("a.rs");
        let spans = highlight_line("code // trailing note", &lang);
        let comment = spans.last().unwrap();
        assert_eq!(comment.1, HlKind::Comment);
        assert!(comment.0.contains("trailing note"));
    }

    #[test]
    fn ruby_uses_hash_comments() {
        let lang = lang_for_path("a.rb");
        let spans = highlight_line("def foo # note", &lang);
        assert_eq!(spans[0], ("def".to_string(), HlKind::Keyword));
        assert_eq!(spans.last().unwrap().1, HlKind::Comment);
    }

    #[test]
    fn highlights_numbers() {
        let lang = lang_for_path("a.rs");
        let spans = highlight_line("let n = 42;", &lang);
        assert!(spans.iter().any(|(s, k)| s == "42" && *k == HlKind::Number));
    }

    #[test]
    fn string_with_escaped_quote_stays_one_span() {
        let lang = lang_for_path("a.rs");
        let spans = highlight_line("\"a\\\"b\"", &lang);
        assert_eq!(kinds(&spans), vec![("\"a\\\"b\"", HlKind::Str)]);
    }

    #[test]
    fn unknown_extension_still_lexes_strings() {
        let lang = lang_for_path("a.unknownext");
        let spans = highlight_line("x = \"v\"", &lang);
        assert!(spans.iter().any(|(_, k)| *k == HlKind::Str));
    }

    #[test]
    fn empty_line_yields_no_spans() {
        let lang = lang_for_path("a.rs");
        assert!(highlight_line("", &lang).is_empty());
    }
}
