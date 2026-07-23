//! Public vs private classification for changed units.
//!
//! The gigasail DB stores no visibility field, so we detect it best-effort from
//! the unit's declaration signature (and, for Ruby, the enclosing `private`
//! section). Unknown languages default to Public so nothing is hidden by
//! accident.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Visibility {
    Public,
    Private,
}

impl Visibility {
    pub fn is_private(self) -> bool {
        self == Visibility::Private
    }
}

fn extension(path: &str) -> &str {
    path.rsplit('.').next().unwrap_or("")
}

/// Classify a unit's visibility from its path, name, declaration signature, and
/// (for languages that need lexical context) the surrounding file lines.
pub fn classify(
    path: &str,
    name: &str,
    signature: &str,
    start_line: u32,
    lines: &[&str],
) -> Visibility {
    let sig = signature.trim_start();
    // The unqualified leaf of a possibly-qualified name (`Store.open` -> `open`).
    // Split only on qualified-name separators; a leading `#` is a JS privacy
    // marker, not a separator, so it must survive.
    let leaf = name.rsplit(['.', ':']).next().unwrap_or(name);
    match extension(path) {
        "rs" => rust(sig),
        "go" => go(leaf),
        "py" | "pyi" => python(leaf),
        "js" | "jsx" | "ts" | "tsx" | "mjs" | "cjs" => javascript(leaf),
        "rb" => ruby(sig, start_line, lines),
        _ => Visibility::Public,
    }
}

fn rust(sig: &str) -> Visibility {
    if sig.starts_with("pub") {
        Visibility::Public
    } else {
        Visibility::Private
    }
}

fn go(leaf: &str) -> Visibility {
    match leaf.chars().next() {
        Some(c) if c.is_uppercase() => Visibility::Public,
        _ => Visibility::Private,
    }
}

fn python(leaf: &str) -> Visibility {
    if leaf.starts_with("__") && leaf.ends_with("__") {
        Visibility::Public
    } else if leaf.starts_with('_') {
        Visibility::Private
    } else {
        Visibility::Public
    }
}

fn javascript(leaf: &str) -> Visibility {
    // `#name` and `_name` are private; everything else (including `export`ed
    // and plain top-level functions) is treated as public.
    if leaf.starts_with('#') || leaf.starts_with('_') {
        Visibility::Private
    } else {
        Visibility::Public
    }
}

/// Ruby: `def self.x` is a public class method; otherwise look upward for the
/// nearest bare `private` / `protected` / `public` marker within the enclosing
/// scope. Markers reset at a `class`/`module` boundary.
fn ruby(sig: &str, start_line: u32, lines: &[&str]) -> Visibility {
    if sig.starts_with("def self.") {
        return Visibility::Public;
    }
    // start_line is 1-based; scan the lines strictly above the definition.
    let start_idx = (start_line as usize).min(lines.len());
    for line in lines[..start_idx.saturating_sub(1)].iter().rev() {
        let trimmed = line.trim();
        match trimmed {
            "private" | "private_class_method" => return Visibility::Private,
            "protected" => return Visibility::Private,
            "public" => return Visibility::Public,
            _ => {
                if trimmed.starts_with("class ") || trimmed.starts_with("module ") {
                    return Visibility::Public;
                }
            }
        }
    }
    Visibility::Public
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rust_pub_is_public() {
        assert_eq!(
            classify("a.rs", "run", "pub fn run() {}", 1, &[]),
            Visibility::Public
        );
        assert_eq!(
            classify("a.rs", "run", "pub(crate) fn run() {}", 1, &[]),
            Visibility::Public
        );
        assert_eq!(
            classify("a.rs", "run", "fn run() {}", 1, &[]),
            Visibility::Private
        );
    }

    #[test]
    fn go_capitalization_rule() {
        assert_eq!(
            classify("a.go", "Run", "func Run() {}", 1, &[]),
            Visibility::Public
        );
        assert_eq!(
            classify("a.go", "run", "func run() {}", 1, &[]),
            Visibility::Private
        );
    }

    #[test]
    fn python_underscore_rule() {
        assert_eq!(
            classify("a.py", "run", "def run():", 1, &[]),
            Visibility::Public
        );
        assert_eq!(
            classify("a.py", "_run", "def _run():", 1, &[]),
            Visibility::Private
        );
        assert_eq!(
            classify("a.py", "__init__", "def __init__(self):", 1, &[]),
            Visibility::Public
        );
    }

    #[test]
    fn javascript_private_markers() {
        assert_eq!(
            classify("a.ts", "#secret", "#secret() {}", 1, &[]),
            Visibility::Private
        );
        assert_eq!(
            classify("a.js", "_helper", "_helper() {}", 1, &[]),
            Visibility::Private
        );
        assert_eq!(
            classify("a.ts", "run", "export function run() {}", 1, &[]),
            Visibility::Public
        );
        assert_eq!(
            classify("a.js", "run", "function run() {}", 1, &[]),
            Visibility::Public
        );
    }

    #[test]
    fn ruby_self_method_is_public() {
        assert_eq!(
            classify("a.rb", "self.build", "def self.build", 1, &[]),
            Visibility::Public
        );
    }

    #[test]
    fn ruby_private_section() {
        let lines = vec![
            "class Foo", // 1
            "  def a",   // 2
            "  end",     // 3
            "  private", // 4
            "",          // 5
            "  def b",   // 6
            "  end",     // 7
        ];
        assert_eq!(
            classify("a.rb", "a", "def a", 2, &lines),
            Visibility::Public
        );
        assert_eq!(
            classify("a.rb", "b", "def b", 6, &lines),
            Visibility::Private
        );
    }

    #[test]
    fn ruby_public_resets_private() {
        let lines = vec![
            "class Foo", // 1
            "  private", // 2
            "  def a",   // 3
            "  end",     // 4
            "  public",  // 5
            "  def b",   // 6
        ];
        assert_eq!(
            classify("a.rb", "a", "def a", 3, &lines),
            Visibility::Private
        );
        assert_eq!(
            classify("a.rb", "b", "def b", 6, &lines),
            Visibility::Public
        );
    }

    #[test]
    fn ruby_marker_stops_at_class_boundary() {
        let lines = vec![
            "class Outer", // 1
            "  private",   // 2
            "end",         // 3
            "class Inner", // 4
            "  def a",     // 5
        ];
        // The `private` belongs to Outer; Inner's method is public.
        assert_eq!(
            classify("a.rb", "a", "def a", 5, &lines),
            Visibility::Public
        );
    }

    #[test]
    fn unknown_language_defaults_public() {
        assert_eq!(
            classify("a.zig", "run", "pub fn run() void {}", 1, &[]),
            Visibility::Public
        );
        assert_eq!(classify("a.txt", "x", "x", 1, &[]), Visibility::Public);
    }
}
