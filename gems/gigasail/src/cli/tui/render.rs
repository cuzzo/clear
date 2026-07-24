//! ratatui rendering of the diff review UI: left tree pane, right inline-diff
//! pane with gutters and an info box, and the bottom background-progress box.

use crate::cli::diff::gitdiff::LineOrigin;
use crate::cli::diff::risk::CoverageState;
use crate::cli::diff::tree::NodeKind;
use crate::cli::highlight::{highlight_line, lang_for_path, HlKind, Lang};
use crate::cli::tui::app::{App, InfoBox, PaneBody, PaneLine};
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, Paragraph, Wrap};
use ratatui::Frame;

/// Severity glyph for a node's risk score.
pub fn risk_dot(risk: f64, ascii: bool) -> &'static str {
    let (hi, mid, lo, none) = if ascii {
        ("#", "+", ".", " ")
    } else {
        ("\u{25CF}", "\u{25D0}", "\u{25CB}", " ")
    };
    if risk >= 40.0 {
        hi
    } else if risk >= 10.0 {
        mid
    } else if risk > 0.0 {
        lo
    } else {
        none
    }
}

/// A text progress bar like `▓▓▓▓░░░░` of the given width.
pub fn progress_bar(percent: u8, width: usize, ascii: bool) -> String {
    let filled = (percent as usize * width) / 100;
    let (full, empty) = if ascii {
        ('#', '-')
    } else {
        ('\u{2593}', '\u{2591}')
    };
    let mut bar = String::with_capacity(width);
    for i in 0..width {
        bar.push(if i < filled { full } else { empty });
    }
    bar
}

fn coverage_style(state: CoverageState) -> Style {
    match state {
        CoverageState::CoveredKilled => Style::default().fg(Color::Green),
        CoverageState::Covered => Style::default().fg(Color::LightGreen),
        CoverageState::Partial => Style::default().fg(Color::Yellow),
        CoverageState::Uncovered => Style::default().fg(Color::Red),
        CoverageState::Unknown => Style::default().fg(Color::DarkGray),
    }
}

fn origin_style(origin: LineOrigin) -> Style {
    match origin {
        LineOrigin::Add => Style::default().fg(Color::Green),
        LineOrigin::Del => Style::default().fg(Color::Red),
        LineOrigin::Context => Style::default().fg(Color::Gray),
    }
}

use crate::cli::gutter::GutterKind;
use crate::cli::tui::app::Focus;

/// Render the whole frame.
pub fn render(frame: &mut Frame, app: &App, _now: f64) {
    let area = frame.area();

    // Left/right panes above a one-row legend.
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(3), Constraint::Length(1)])
        .split(area);

    let panes = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(38), Constraint::Min(20)])
        .split(rows[0]);

    render_left(frame, app, panes[0]);
    render_right(frame, app, panes[1]);
    render_legend(frame, app, rows[rows.len() - 1]);
}

/// Border style that highlights the focused pane.
fn focus_border(app: &App, pane: Focus) -> Style {
    if app.focus == pane {
        Style::default()
            .fg(Color::Cyan)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(Color::DarkGray)
    }
}

/// One-row legend: gutter glyph meanings + key hints.
fn render_legend(frame: &mut Frame, app: &App, area: Rect) {
    let mut spans: Vec<Span> = Vec::new();
    for kind in GutterKind::all() {
        spans.push(Span::styled(
            format!("{} ", kind.icon(app.ascii)),
            Style::default().fg(Color::Yellow),
        ));
        spans.push(Span::styled(
            format!("{}  ", kind.label()),
            Style::default().fg(Color::Gray),
        ));
    }
    spans.push(Span::styled("\u{2717} ", Style::default().fg(Color::Red)));
    spans.push(Span::styled(
        "uncovered  ",
        Style::default().fg(Color::Gray),
    ));
    spans.push(Span::styled(
        "\u{2502} \u{2190}/\u{2192} pane  \u{2191}\u{2193} move  space fold/detail  / search  q quit",
        Style::default().fg(Color::DarkGray),
    ));
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn render_left(frame: &mut Frame, app: &App, area: Rect) {
    let search = if app.searching {
        format!("search: {}\u{2588}", app.search)
    } else if app.search.is_empty() {
        "/ to search".to_string()
    } else {
        format!("search: {}", app.search)
    };
    let title = format!(
        "giga diff — {}  ({} files, {} hazards)",
        app.target_label, app.file_count, app.hazard_count
    );

    let inner = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Min(1)])
        .split(area);

    frame.render_widget(
        Paragraph::new(search).style(Style::default().fg(Color::Cyan)),
        inner[0],
    );

    let items: Vec<ListItem> = app
        .rows
        .iter()
        .enumerate()
        .map(|(i, row)| {
            let indent = "  ".repeat(row.depth);
            let arrow = if row.has_children {
                if row.open {
                    "\u{25BE} "
                } else {
                    "\u{25B8} "
                }
            } else {
                "  "
            };
            let dot = risk_dot(row.risk, app.ascii);
            let text = format!(
                "{indent}{arrow}{} {}  +{} -{}",
                dot, row.label, row.added, row.removed
            );
            let mut style = Style::default();
            if row.kind == NodeKind::PrivateGroup || row.kind == NodeKind::TestGroup {
                style = style.fg(Color::DarkGray);
            }
            if i == app.selected {
                style = style.add_modifier(Modifier::REVERSED);
            }
            ListItem::new(Line::from(Span::styled(text, style)))
        })
        .collect();

    let list = List::new(items).block(
        Block::default()
            .borders(Borders::ALL)
            .border_style(focus_border(app, Focus::Tree))
            .title(title),
    );
    frame.render_widget(list, inner[1]);
}

fn info_lines(info: &InfoBox) -> Vec<Line<'static>> {
    let header = format!(
        "{} Hazards ({} uncovered)   {} T1  {} T2  {} T3",
        info.hazards_total, info.hazards_uncovered, info.t1, info.t2, info.t3
    );
    let state = format!("coverage: {}", info.coverage.label());
    vec![
        Line::from(Span::styled(
            info.title.clone(),
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(Span::styled(
            header,
            Style::default().fg(if info.hazards_uncovered > 0 {
                Color::Red
            } else {
                Color::Yellow
            }),
        )),
        Line::from(Span::styled(state, coverage_style(info.coverage))),
    ]
}

/// A row to draw in the code pane: a real line or an elision marker for a
/// folded run of unchanged lines.
pub enum DisplayRow<'a> {
    Code(&'a PaneLine),
    Elision,
}

/// Show the whole function when it fits; otherwise keep changed lines (with a
/// little context) and fold unchanged runs into a single elision marker.
pub fn fold_lines(lines: &[PaneLine], max_rows: usize) -> Vec<DisplayRow<'_>> {
    if max_rows == 0 {
        return Vec::new();
    }
    if lines.len() <= max_rows {
        return lines.iter().map(DisplayRow::Code).collect();
    }
    const CTX: usize = 3;
    let mut keep = vec![false; lines.len()];
    for (i, line) in lines.iter().enumerate() {
        if matches!(line.origin, LineOrigin::Add | LineOrigin::Del) {
            let lo = i.saturating_sub(CTX);
            let hi = (i + CTX).min(lines.len() - 1);
            for k in keep.iter_mut().take(hi + 1).skip(lo) {
                *k = true;
            }
        }
    }
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        if keep[i] {
            out.push(DisplayRow::Code(&lines[i]));
            i += 1;
        } else {
            out.push(DisplayRow::Elision);
            while i < lines.len() && !keep[i] {
                i += 1;
            }
        }
    }
    out
}

fn elision_line() -> Line<'static> {
    Line::from(Span::styled(
        "   ...    . . . . . . . . . . . . . . .".to_string(),
        Style::default().fg(Color::DarkGray),
    ))
}

fn hl_style(kind: HlKind) -> Style {
    match kind {
        HlKind::Keyword => Style::default().fg(Color::Magenta),
        HlKind::Str => Style::default().fg(Color::Green),
        HlKind::Comment => Style::default()
            .fg(Color::DarkGray)
            .add_modifier(Modifier::ITALIC),
        HlKind::Number => Style::default().fg(Color::Cyan),
        HlKind::Plain => Style::default().fg(Color::Gray),
    }
}

const GUTTER_W: usize = 3;

/// Fixed-width gutter column of single-column glyphs (already de-duplicated).
fn gutter_str(line: &PaneLine, ascii: bool) -> String {
    let mut s = String::new();
    for kind in line.gutters.iter().take(GUTTER_W) {
        s.push_str(kind.icon(ascii));
    }
    while s.chars().count() < GUTTER_W {
        s.push(' ');
    }
    s
}

/// GitHub-style subtle row tint for added/removed lines. Only on truecolor
/// terminals: without 24-bit color the terminal downsamples these to a loud
/// bright green/red, so we drop the tint and let the `+`/`-` gutter carry the
/// diff instead.
fn origin_bg(origin: LineOrigin, truecolor: bool) -> Option<Color> {
    if !truecolor {
        return None;
    }
    match origin {
        LineOrigin::Add => Some(Color::Rgb(22, 48, 28)),
        LineOrigin::Del => Some(Color::Rgb(58, 26, 26)),
        LineOrigin::Context => None,
    }
}

fn pane_line_spans(
    line: &PaneLine,
    ascii: bool,
    truecolor: bool,
    lang: &Lang,
    width: usize,
    cursor: bool,
) -> Line<'static> {
    // Cursor tint overrides the diff tint; otherwise diff add/remove tint.
    // On non-truecolor terminals a reversed-video cursor replaces the RGB tint.
    let bg = if cursor && truecolor {
        Some(Color::Rgb(48, 48, 84))
    } else {
        origin_bg(line.origin, truecolor)
    };
    let paint = move |style: Style| {
        let style = match bg {
            Some(color) => style.bg(color),
            None => style,
        };
        if cursor {
            let style = style.add_modifier(Modifier::BOLD);
            if truecolor {
                style
            } else {
                style.add_modifier(Modifier::REVERSED)
            }
        } else {
            style
        }
    };

    let cover = match line.covered {
        Some(false) => "\u{2717}",
        _ => " ",
    };
    let num = line
        .new_lineno
        .map(|n| format!("{n:>5}"))
        .unwrap_or_else(|| "     ".to_string());
    let sign = match line.origin {
        LineOrigin::Add => "+",
        LineOrigin::Del => "-",
        LineOrigin::Context => " ",
    };
    let prefix = format!("{cover}{}{num} {sign} ", gutter_str(line, ascii));

    let mut spans = vec![Span::styled(
        prefix.clone(),
        paint(origin_style(line.origin)),
    )];
    // Syntax-highlight the content for every origin; the tint conveys add/remove.
    for (text, kind) in highlight_line(&line.content, lang) {
        spans.push(Span::styled(text, paint(hl_style(kind))));
    }
    // Pad to full width so the row tint fills the pane (GitHub-like).
    let used = prefix.chars().count() + line.content.chars().count();
    if (bg.is_some()) && width > used {
        spans.push(Span::styled(
            " ".repeat(width - used),
            paint(Style::default()),
        ));
    }
    Line::from(spans)
}

/// The indented SARIF/hazard/dark-arm detail rows shown under a line on Space.
fn detail_lines(line: &PaneLine, ascii: bool, width: usize) -> Vec<Line<'static>> {
    let mut out = Vec::new();
    let bg = Style::default().bg(Color::Rgb(28, 28, 40));
    let pad = |text: String| {
        let used = text.chars().count();
        if width > used {
            format!("{text}{}", " ".repeat(width - used))
        } else {
            text
        }
    };
    for hazard in &line.hazards {
        let state = if hazard.verified { "verified" } else { "OPEN" };
        let text = pad(format!(
            "      {} hazard: {} [{}] needs {}",
            GutterKind::Hazard.icon(ascii),
            hazard.hazard_type,
            state,
            hazard.required_evidence
        ));
        let color = if hazard.verified {
            Color::Yellow
        } else {
            Color::Red
        };
        out.push(Line::from(Span::styled(text, bg.fg(color))));
    }
    for finding in &line.findings {
        let tier = finding.tier.map(|t| format!(" (T{t})")).unwrap_or_default();
        let text = pad(format!(
            "      {} [{}] {}: {}{}",
            finding.gutter.icon(ascii),
            finding.tool,
            finding.rule,
            finding.message,
            tier
        ));
        out.push(Line::from(Span::styled(text, bg.fg(Color::Gray))));
    }
    for arm in &line.dark_arms {
        let text = pad(format!(
            "      {} dark-arm: {}",
            GutterKind::DarkArm.icon(ascii),
            arm
        ));
        out.push(Line::from(Span::styled(text, bg.fg(Color::Magenta))));
    }
    out
}

fn render_right(frame: &mut Frame, app: &App, area: Rect) {
    let pane = app.right_pane();
    let border = focus_border(app, Focus::Code);
    match &pane.body {
        PaneBody::Empty(hint) => {
            frame.render_widget(
                Paragraph::new(hint.clone())
                    .block(Block::default().borders(Borders::ALL).border_style(border)),
                area,
            );
        }
        PaneBody::Summary(summary) => {
            render_summary(frame, app, area, &pane.title, summary, border)
        }
        PaneBody::Code { info, lines } => render_code(frame, app, area, &pane, info, lines, border),
    }
}

#[allow(clippy::too_many_arguments)]
fn render_code(
    frame: &mut Frame,
    app: &App,
    area: Rect,
    pane: &crate::cli::tui::app::RightPane,
    info: &InfoBox,
    lines: &[PaneLine],
    border: Style,
) {
    let layout = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(5), Constraint::Min(1)])
        .split(area);
    let info_widget = Paragraph::new(info_lines(info))
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(border)
                .title(pane.title.clone()),
        )
        .wrap(Wrap { trim: true });
    frame.render_widget(info_widget, layout[0]);

    let code_area = layout[1];
    let width = code_area.width.saturating_sub(2) as usize;
    let lang = lang_for_path(pane.path.as_deref().unwrap_or(""));
    let focused = app.focus == Focus::Code;

    let (rendered, scroll) = if focused {
        // Cursor mode: full body + inline detail drop-downs, scrolled to cursor.
        let mut out: Vec<Line> = Vec::new();
        let mut cursor_row = 0u16;
        for (i, line) in lines.iter().enumerate() {
            if i == app.code_cursor {
                cursor_row = out.len() as u16;
            }
            out.push(pane_line_spans(
                line,
                app.ascii,
                app.truecolor,
                &lang,
                width,
                i == app.code_cursor,
            ));
            if app.detail_open.contains(&i) {
                out.extend(detail_lines(line, app.ascii, width));
            }
        }
        let h = code_area.height.saturating_sub(2);
        let scroll = cursor_row.saturating_sub(h / 2);
        (out, scroll)
    } else {
        // Overview mode: fold unchanged runs.
        let max_rows = code_area.height.saturating_sub(2) as usize;
        let out = fold_lines(lines, max_rows)
            .iter()
            .map(|row| match row {
                DisplayRow::Code(l) => {
                    pane_line_spans(l, app.ascii, app.truecolor, &lang, width, false)
                }
                DisplayRow::Elision => elision_line(),
            })
            .collect();
        (out, 0)
    };

    let code = Paragraph::new(rendered).scroll((scroll, 0)).block(
        Block::default()
            .borders(Borders::ALL)
            .border_style(border)
            .title("changes"),
    );
    frame.render_widget(code, code_area);
}

fn render_summary(
    frame: &mut Frame,
    app: &App,
    area: Rect,
    title: &str,
    summary: &crate::cli::tui::app::SummaryView,
    border: Style,
) {
    use crate::cli::tui::app::SummaryRow;
    let s = &summary.stats;
    let mut body: Vec<Line> = Vec::new();
    body.push(Line::from(Span::styled(
        format!(
            "covered+killed {}   covered {}   partial {}   uncovered {}   unknown {}",
            s.covered_killed, s.covered, s.partial, s.uncovered, s.unknown
        ),
        Style::default().add_modifier(Modifier::BOLD),
    )));
    body.push(Line::from(Span::styled(
        format!("{} changed, riskiest first:", summary.rows.len()),
        Style::default().fg(Color::DarkGray),
    )));
    body.push(Line::from(""));

    let row_line = |row: &SummaryRow| -> Line<'static> {
        let mut spans = vec![Span::styled(
            format!("{:<34}", truncate(&row.label, 34)),
            Style::default().add_modifier(Modifier::BOLD),
        )];
        let mut findings: Vec<Span> = Vec::new();
        if row.uncovered_hazards > 0 {
            findings.push(Span::styled(
                format!(
                    "{} {} uncovered hazards  ",
                    GutterKind::Hazard.icon(app.ascii),
                    row.uncovered_hazards
                ),
                Style::default().fg(Color::Red),
            ));
        }
        if row.t1_unkilled > 0 {
            findings.push(Span::styled(
                format!("{} T1 unkilled  ", row.t1_unkilled),
                Style::default().fg(Color::LightRed),
            ));
        }
        if row.t2_unkilled > 0 {
            findings.push(Span::styled(
                format!("{} T2  ", row.t2_unkilled),
                Style::default().fg(Color::Yellow),
            ));
        }
        if row.t3_unkilled > 0 {
            findings.push(Span::styled(
                format!("{} T3  ", row.t3_unkilled),
                Style::default().fg(Color::Gray),
            ));
        }
        if findings.is_empty() {
            findings.push(Span::styled(
                "clean".to_string(),
                Style::default().fg(Color::Green),
            ));
        }
        spans.extend(findings);
        Line::from(spans)
    };

    if summary.rows.is_empty() {
        body.push(Line::from(Span::styled(
            "no changed children.".to_string(),
            Style::default().fg(Color::DarkGray),
        )));
    } else {
        for row in &summary.rows {
            body.push(row_line(row));
        }
    }

    let widget = Paragraph::new(body)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(border)
                .title(title.to_string()),
        )
        .wrap(Wrap { trim: false });
    frame.render_widget(widget, area);
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
        out.push('\u{2026}');
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli::diff::gitdiff::{ChangeStatus, DiffLine, FileDiff, Hunk};
    use crate::cli::diff::risk::Evidence;
    use crate::cli::diff::tree::build_tree;
    use crate::cli::diff::units::{ChangedUnit, FileChange};
    use crate::cli::diff::visibility::Visibility;
    use crate::cli::project_root_of;
    use crate::model::UnitKind;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;
    use std::collections::HashMap;
    use std::path::PathBuf;

    fn buffer_text(terminal: &Terminal<TestBackend>) -> String {
        let buffer = terminal.backend().buffer();
        buffer
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>()
    }

    fn app_with_change() -> App {
        let unit = ChangedUnit {
            name: "verify".into(),
            kind: UnitKind::Function,
            path: "proj/token.rs".into(),
            start_line: 1,
            end_line: 3,
            signature: "pub fn verify()".into(),
            visibility: Visibility::Public,
            is_test: false,
            added: 2,
            removed: 0,
            added_lines: vec![],
            evidence: Evidence {
                hazards_total: 1,
                hazards_uncovered: 1,
                t1_findings: 1,
                coverage: CoverageState::Uncovered,
                ..Default::default()
            },
        };
        let change = FileChange {
            path: "proj/token.rs".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            is_test: false,
            units: vec![unit],
            file_added: 2,
            file_removed: 0,
            unattributed_added: 0,
            unattributed_removed: 0,
        };
        let file = FileDiff {
            path: "proj/token.rs".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            hunks: vec![Hunk {
                old_start: 1,
                old_lines: 1,
                new_start: 1,
                new_lines: 3,
                lines: vec![
                    DiffLine {
                        origin: LineOrigin::Context,
                        old_lineno: Some(1),
                        new_lineno: Some(1),
                        content: "pub fn verify() {".into(),
                    },
                    DiffLine {
                        origin: LineOrigin::Add,
                        old_lineno: None,
                        new_lineno: Some(2),
                        content: "  decode();".into(),
                    },
                ],
            }],
        };
        let mut sources = HashMap::new();
        sources.insert(
            "proj/token.rs".to_string(),
            "pub fn verify() {\n  decode();\n}\n".to_string(),
        );
        let root = build_tree(std::slice::from_ref(&change), project_root_of);
        App::new(
            PathBuf::from("."),
            PathBuf::from("/nonexistent/gigasail.db"),
            root,
            vec![change],
            vec![file],
            sources,
            HashMap::new(),
            "staged vs HEAD".into(),
        )
    }

    fn draw(app: &App, now: f64) -> Terminal<TestBackend> {
        let backend = TestBackend::new(120, 30);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|f| render(f, app, now)).unwrap();
        terminal
    }

    fn app_no_evidence() -> App {
        // A 6-line function where only line 3 was added; no coverage/hazard
        // evidence (as for a freshly built repo).
        let unit = ChangedUnit {
            name: "handler".into(),
            kind: UnitKind::Function,
            path: "src/app.rs".into(),
            start_line: 1,
            end_line: 6,
            signature: "pub fn handler()".into(),
            visibility: Visibility::Public,
            is_test: false,
            added: 1,
            removed: 0,
            added_lines: vec![3],
            evidence: Evidence::default(),
        };
        let change = FileChange {
            path: "src/app.rs".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            is_test: false,
            units: vec![unit],
            file_added: 1,
            file_removed: 0,
            unattributed_added: 0,
            unattributed_removed: 0,
        };
        let file = FileDiff {
            path: "src/app.rs".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            hunks: vec![Hunk {
                old_start: 1,
                old_lines: 5,
                new_start: 1,
                new_lines: 6,
                lines: vec![
                    DiffLine { origin: LineOrigin::Context, old_lineno: Some(1), new_lineno: Some(1), content: "pub fn handler() {".into() },
                    DiffLine { origin: LineOrigin::Context, old_lineno: Some(2), new_lineno: Some(2), content: "    let a = 1;".into() },
                    DiffLine { origin: LineOrigin::Add, old_lineno: None, new_lineno: Some(3), content: "    let b = 2;".into() },
                    DiffLine { origin: LineOrigin::Context, old_lineno: Some(3), new_lineno: Some(4), content: "    let c = 3;".into() },
                    DiffLine { origin: LineOrigin::Context, old_lineno: Some(4), new_lineno: Some(5), content: "    a + b".into() },
                    DiffLine { origin: LineOrigin::Context, old_lineno: Some(5), new_lineno: Some(6), content: "}".into() },
                ],
            }],
        };
        let mut sources = HashMap::new();
        sources.insert("src/app.rs".to_string(),
            "pub fn handler() {\n    let a = 1;\n    let b = 2;\n    let c = 3;\n    a + b\n}\n".to_string());
        let root = build_tree(std::slice::from_ref(&change), project_root_of);
        App::new(PathBuf::from("."), PathBuf::from("/nonexistent/gigasail.db"),
            root, vec![change], vec![file], sources, HashMap::new(), "HEAD".into())
    }

    fn green_bg_cells(app: &App) -> usize {
        let term = draw(app, 0.0);
        let buf = term.backend().buffer();
        let mut greens = 0;
        for y in 0..buf.area.height {
            for x in 0..buf.area.width {
                if let ratatui::style::Color::Rgb(r, g, b) = buf.cell((x, y)).unwrap().bg {
                    if g > r && g > b {
                        greens += 1;
                    }
                }
            }
        }
        greens
    }

    #[test]
    fn diff_row_tint_is_gated_on_truecolor() {
        let mut app = app_no_evidence();
        select(&mut app, "handler()");
        // Truecolor: the added line carries the subtle green background tint.
        app.truecolor = true;
        assert!(
            green_bg_cells(&app) > 0,
            "truecolor terminals should show the added-line tint"
        );
        // Non-truecolor: no RGB tint (the terminal would downsample it to a loud
        // bright green); the +/- gutter carries the diff instead.
        app.truecolor = false;
        assert_eq!(
            green_bg_cells(&app),
            0,
            "non-truecolor terminals must not emit RGB background tints"
        );
    }

    #[test]
    fn container_lists_changed_children_without_evidence() {
        // A repo built without coverage/hazard evidence yields zero-risk units.
        // Container (project/dir/file) views must still list their changed
        // children rather than collapsing to an empty "no children" message.
        let mut app = app_no_evidence();
        select(&mut app, "app.rs");
        let text = buffer_text(&draw(&app, 0.0));
        assert!(
            text.contains("handler()"),
            "file container must list its changed function; got:\n{text}"
        );
        assert!(
            !text.contains("no changed children"),
            "container must not be empty when children changed"
        );
        // The riskiest-child summary for the whole project also lists the file.
        select(&mut app, "src");
        let dir_text = buffer_text(&draw(&app, 0.0));
        assert!(dir_text.contains("app.rs"), "dir container lists changed file");
    }

    #[test]
    fn risk_dot_thresholds() {
        assert_eq!(risk_dot(50.0, true), "#");
        assert_eq!(risk_dot(20.0, true), "+");
        assert_eq!(risk_dot(1.0, true), ".");
        assert_eq!(risk_dot(0.0, true), " ");
    }

    #[test]
    fn progress_bar_fills_proportionally() {
        assert_eq!(progress_bar(0, 4, true), "----");
        assert_eq!(progress_bar(50, 4, true), "##--");
        assert_eq!(progress_bar(100, 4, true), "####");
    }

    fn select(app: &mut App, label: &str) {
        app.selected = app.rows.iter().position(|r| r.label == label).unwrap();
    }

    #[test]
    fn renders_tree_and_file_summary() {
        // Default focus is the riskiest file -> its summary lists children.
        let app = app_with_change();
        let terminal = draw(&app, 0.0);
        let text = buffer_text(&terminal);
        assert!(text.contains("giga diff"));
        assert!(text.contains("token.rs"));
        assert!(text.contains("verify"));
        // The summary shows coverage buckets and condensed findings.
        assert!(text.contains("uncovered"));
    }

    #[test]
    fn function_selection_renders_info_box() {
        let mut app = app_with_change();
        select(&mut app, "verify()");
        let text = buffer_text(&draw(&app, 0.0));
        assert!(text.contains("Hazards"));
        assert!(text.contains("uncovered"));
    }

    #[test]
    fn legend_is_always_visible() {
        let app = app_with_change();
        let text = buffer_text(&draw(&app, 0.0));
        assert!(text.contains("hazard"));
        assert!(text.contains("pane"));
    }

    #[test]
    fn file_summary_lists_condensed_findings() {
        let app = app_with_change();
        let text = buffer_text(&draw(&app, 0.0));
        // verify() has one uncovered hazard and one T1 finding.
        assert!(text.contains("uncovered hazards"));
        assert!(text.contains("T1 unkilled"));
    }

    #[test]
    fn space_detail_dropdown_renders_finding_text() {
        use crate::cli::gutter::GutterKind;
        use crate::cli::line_evidence::{FindingDetail, HazardDetail, LineEvidence};
        let mut app = app_with_change();
        // Attach a finding + hazard to line 2 (the added `decode();` line).
        app.line_ev.insert(
            "proj/token.rs".into(),
            vec![LineEvidence {
                line: 2,
                covered: false,
                findings: vec![FindingDetail {
                    gutter: GutterKind::Complexity,
                    tool: "Decomplex".into(),
                    rule: "cyclomatic".into(),
                    message: "too branchy".into(),
                    tier: Some(1),
                }],
                hazards: vec![HazardDetail {
                    hazard_type: "null-deref".into(),
                    verified: false,
                    required_evidence: "loom".into(),
                }],
                gutters: vec![GutterKind::Hazard, GutterKind::Complexity],
                ..Default::default()
            }],
        );
        select(&mut app, "verify()");
        app.focus = crate::cli::tui::app::Focus::Code;
        // Cursor onto the added line (line 2 -> pane index 1) and open detail.
        app.code_cursor = 1;
        app.detail_open.insert(1);
        let text = buffer_text(&draw(&app, 0.0));
        assert!(text.contains("too branchy"));
        assert!(text.contains("null-deref"));
    }

    #[test]
    fn ascii_mode_uses_ascii_glyphs() {
        let mut app = app_with_change();
        app.ascii = true;
        let terminal = draw(&app, 0.0);
        let text = buffer_text(&terminal);
        // No emoji bomb; ascii risk dots instead.
        assert!(!text.contains('\u{1F4A3}'));
    }

    fn app_without_units() -> App {
        let change = FileChange {
            path: "proj/notes.txt".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            is_test: false,
            units: vec![],
            file_added: 2,
            file_removed: 0,
            unattributed_added: 2,
            unattributed_removed: 0,
        };
        let file = FileDiff {
            path: "proj/notes.txt".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            hunks: vec![Hunk {
                old_start: 1,
                old_lines: 0,
                new_start: 1,
                new_lines: 2,
                lines: vec![DiffLine {
                    origin: LineOrigin::Add,
                    old_lineno: None,
                    new_lineno: Some(1),
                    content: "note".into(),
                }],
            }],
        };
        let root = build_tree(std::slice::from_ref(&change), project_root_of);
        // Select the file node (its subtree has no unit -> empty hint pane).
        let mut app = App::new(
            PathBuf::from("."),
            PathBuf::from("/nonexistent/gigasail.db"),
            root,
            vec![change],
            vec![file],
            HashMap::new(),
            HashMap::new(),
            "staged vs HEAD".into(),
        );
        app.selected = app
            .rows
            .iter()
            .position(|r| r.label == "notes.txt")
            .unwrap();
        app
    }

    #[test]
    fn unitless_file_shows_empty_summary() {
        let app = app_without_units();
        let terminal = draw(&app, 0.0);
        let text = buffer_text(&terminal);
        assert!(text.contains("notes.txt"));
        // No logical units -> a summary with no changed children to list.
        assert!(text.contains("no changed children"));
    }

    fn pane_line(origin: LineOrigin, n: u32) -> PaneLine {
        PaneLine {
            origin,
            new_lineno: Some(n),
            content: format!("line{n}"),
            gutters: vec![],
            covered: None,
            findings: vec![],
            hazards: vec![],
            dark_arms: vec![],
        }
    }

    #[test]
    fn fold_shows_all_lines_when_they_fit() {
        let lines: Vec<PaneLine> = (1..=5).map(|n| pane_line(LineOrigin::Context, n)).collect();
        let rows = fold_lines(&lines, 10);
        assert_eq!(rows.len(), 5);
        assert!(rows.iter().all(|r| matches!(r, DisplayRow::Code(_))));
    }

    #[test]
    fn fold_elides_unchanged_runs_when_too_tall() {
        // 20 lines, a single change in the middle; must fold with an elision and
        // keep the changed line visible.
        let mut lines: Vec<PaneLine> = (1..=20)
            .map(|n| pane_line(LineOrigin::Context, n))
            .collect();
        lines[10].origin = LineOrigin::Add;
        let rows = fold_lines(&lines, 8);
        assert!(rows.iter().any(|r| matches!(r, DisplayRow::Elision)));
        let kept: Vec<u32> = rows
            .iter()
            .filter_map(|r| match r {
                DisplayRow::Code(l) => l.new_lineno,
                DisplayRow::Elision => None,
            })
            .collect();
        assert!(kept.contains(&11)); // the changed line (index 10 -> line 11)
        assert!(!kept.contains(&1)); // far-away unchanged lines are folded away
    }

    #[test]
    fn fold_zero_rows_is_empty() {
        let lines = vec![pane_line(LineOrigin::Context, 1)];
        assert!(fold_lines(&lines, 0).is_empty());
    }
}
