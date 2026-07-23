//! Gutter icon taxonomy shared by the evidence layer and the TUI renderer.
//!
//! Mirrors the web UI's finding-tool -> icon mapping: bomb=hazard, knot=
//! complexity, tree=architectural, class=nil-kill.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GutterKind {
    Hazard,
    Complexity,
    Architecture,
    NilKill,
    DarkArm,
    Sarif,
}

/// Route a SARIF finding to a gutter category by its tool/category strings.
pub fn tool_gutter(tool: &str, category: &str) -> GutterKind {
    let hay = format!("{} {}", tool.to_lowercase(), category.to_lowercase());
    if hay.contains("decomplex")
        || hay.contains("complex")
        || hay.contains("sql-cov")
        || hay.contains("sqlcov")
    {
        GutterKind::Complexity
    } else if hay.contains("espalier") || hay.contains("architect") {
        GutterKind::Architecture
    } else if hay.contains("nil") {
        GutterKind::NilKill
    } else {
        GutterKind::Sarif
    }
}

impl GutterKind {
    /// The gutter glyph — all single terminal columns so line numbers stay
    /// aligned. `ascii` degrades to plain characters for non-UTF-8 terminals.
    pub fn icon(self, ascii: bool) -> &'static str {
        match (self, ascii) {
            (GutterKind::Hazard, false) => "\u{00A4}", // ¤ currency (hazard)
            (GutterKind::Complexity, false) => "\u{2021}", // ‡ double dagger
            (GutterKind::Architecture, false) => "\u{2302}", // ⌂ house
            (GutterKind::NilKill, false) => "\u{00F8}", // ø slashed o (nil)
            (GutterKind::DarkArm, false) => "\u{25D1}", // ◑ half circle
            (GutterKind::Sarif, false) => "\u{25C6}",  // ◆ diamond
            (GutterKind::Hazard, true) => "!",
            (GutterKind::Complexity, true) => "%",
            (GutterKind::Architecture, true) => "#",
            (GutterKind::NilKill, true) => "@",
            (GutterKind::DarkArm, true) => "?",
            (GutterKind::Sarif, true) => "*",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            GutterKind::Hazard => "hazard",
            GutterKind::Complexity => "complexity",
            GutterKind::Architecture => "architectural",
            GutterKind::NilKill => "nil-kill",
            GutterKind::DarkArm => "dark-arm",
            GutterKind::Sarif => "finding",
        }
    }

    /// Priority for de-duplicating a line's gutter (most severe first).
    pub fn order(self) -> u8 {
        match self {
            GutterKind::Hazard => 0,
            GutterKind::Complexity => 1,
            GutterKind::Architecture => 2,
            GutterKind::NilKill => 3,
            GutterKind::DarkArm => 4,
            GutterKind::Sarif => 5,
        }
    }

    /// All kinds, for the legend.
    pub fn all() -> [GutterKind; 6] {
        [
            GutterKind::Hazard,
            GutterKind::Complexity,
            GutterKind::Architecture,
            GutterKind::NilKill,
            GutterKind::DarkArm,
            GutterKind::Sarif,
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes_tools_to_categories() {
        assert_eq!(tool_gutter("Decomplex", ""), GutterKind::Complexity);
        assert_eq!(tool_gutter("sql-cov", ""), GutterKind::Complexity);
        assert_eq!(tool_gutter("Espalier", ""), GutterKind::Architecture);
        assert_eq!(tool_gutter("x", "architecture"), GutterKind::Architecture);
        assert_eq!(tool_gutter("Nil-Kill", ""), GutterKind::NilKill);
        assert_eq!(tool_gutter("rubocop", "style"), GutterKind::Sarif);
    }

    #[test]
    fn icons_have_ascii_fallbacks() {
        for kind in [
            GutterKind::Hazard,
            GutterKind::Complexity,
            GutterKind::Architecture,
            GutterKind::NilKill,
            GutterKind::DarkArm,
            GutterKind::Sarif,
        ] {
            assert_eq!(kind.icon(true).len(), 1); // single ascii char
            assert!(!kind.icon(false).is_empty());
            assert!(!kind.label().is_empty());
        }
    }
}
