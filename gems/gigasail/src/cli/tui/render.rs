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
        .constraints([Constraint::Length(44), Constraint::Min(20)])
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
            // `arrow` + one space + one space per depth level keeps the tree
            // compact so function rows still show their `+N -N` counts.
            let arrow = if row.has_children {
                if row.open {
                    "\u{25BE}"
                } else {
                    "\u{25B8}"
                }
            } else {
                " "
            };
            let indent = " ".repeat(row.depth);
            let counts = if row.added > 0 || row.removed > 0 {
                format!("  +{} -{}", row.added, row.removed)
            } else {
                String::new()
            };
            // The collapser indents with depth and sits right beside its label.
            let text = format!("{indent}{arrow} {}{counts}", row.label);
            let mut style = Style::default();
            if row.kind == NodeKind::Summary {
                style = style.fg(Color::Cyan).add_modifier(Modifier::BOLD);
            } else if row.kind == NodeKind::PrivateGroup || row.kind == NodeKind::TestGroup {
                style = style.fg(Color::DarkGray);
            } else if row.risk >= 20.0 {
                style = style.fg(Color::Red);
            } else if row.risk >= 5.0 {
                style = style.fg(Color::Yellow);
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
    // The filename/function is already the info box's border title, so it is not
    // repeated here.
    vec![
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

/// Expand tab characters to spaces on 4-column stops. Terminals advance a raw
/// `\t` to the next hardware tab stop, which ratatui cannot account for in its
/// cell buffer; rendering the expanded form keeps the screen and buffer in sync.
fn expand_tabs(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut col = 0usize;
    for ch in text.chars() {
        if ch == '\t' {
            let n = 4 - (col % 4);
            out.extend(std::iter::repeat(' ').take(n));
            col += n;
        } else {
            out.push(ch);
            col += 1;
        }
    }
    out
}

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

/// Render one diff line into one-or-more visual rows: the content wraps to the
/// pane width with a hanging indent (no repeated line number) instead of being
/// truncated. Every row is padded to full width so it overwrites stale cells.
const WRAP_INDENT: usize = 2;

fn pane_line_rows(
    line: &PaneLine,
    ascii: bool,
    truecolor: bool,
    lang: &Lang,
    width: usize,
    cursor: bool,
) -> Vec<Line<'static>> {
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
    let prefix_w = prefix.chars().count();

    // Expand tabs to spaces: a raw `\t` written to the terminal moves the cursor
    // to the next hardware tab stop, desyncing ratatui's cell model.
    let content = expand_tabs(&line.content);

    // Flatten the highlighted content to styled characters for easy wrapping.
    let mut chars: Vec<(char, Style)> = Vec::new();
    for (text, kind) in highlight_line(&content, lang) {
        let style = paint(hl_style(kind));
        for ch in text.chars() {
            chars.push((ch, style));
        }
    }

    let mut rows: Vec<Line> = Vec::new();
    let mut idx = 0;
    let mut first = true;
    loop {
        // First row leads with the gutter/line-number prefix; continuations use
        // a blank prefix of the same width plus a hanging indent, and carry no
        // line number.
        let (lead, lead_w) = if first {
            (
                Span::styled(prefix.clone(), paint(origin_style(line.origin))),
                prefix_w,
            )
        } else {
            let w = prefix_w + WRAP_INDENT;
            (Span::styled(" ".repeat(w), paint(Style::default())), w)
        };
        let cap = width.saturating_sub(lead_w).max(1);
        let end = (idx + cap).min(chars.len());

        let mut spans = vec![lead];
        let mut j = idx;
        while j < end {
            let style = chars[j].1;
            let mut text = String::new();
            while j < end && chars[j].1 == style {
                text.push(chars[j].0);
                j += 1;
            }
            spans.push(Span::styled(text, style));
        }
        let used = lead_w + (end - idx);
        if width > used {
            spans.push(Span::styled(" ".repeat(width - used), paint(Style::default())));
        }
        rows.push(Line::from(spans));

        idx = end;
        first = false;
        if idx >= chars.len() {
            break;
        }
    }
    rows
}

/// The indented SARIF/hazard/dark-arm detail rows shown under a line on Space.
fn detail_lines(line: &PaneLine, ascii: bool, truecolor: bool, width: usize) -> Vec<Line<'static>> {
    let mut out = Vec::new();
    let bg = if truecolor {
        Style::default().bg(Color::Rgb(28, 28, 40))
    } else {
        Style::default()
    };
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
        PaneBody::Funnel(summary) => render_funnel(frame, app, area, &pane.title, summary, border),
    }
}

/// The colored coverage bar. When no coverage was measured (every line
/// `unknown`) it reads `[  NO COVERAGE DATA  ]`. Otherwise: `*` covered+killed
/// (dark green), `+` covered (light green), `-` partial (yellow), a full red
/// block for uncovered, and a gray remainder for any unknown lines.
fn coverage_bar_spans(bar: &crate::cli::diff::summary::CoverageBar, width: usize) -> Vec<Span<'static>> {
    let bracket = Style::default().fg(Color::DarkGray);
    if !bar.has_coverage() {
        let msg = "NO COVERAGE DATA";
        let inner = width.max(msg.len() + 4);
        let pad = inner - msg.len();
        let left = pad / 2;
        return vec![
            Span::styled("[".to_string(), bracket),
            Span::styled(
                format!("{}{}{}", " ".repeat(left), msg, " ".repeat(pad - left)),
                Style::default().fg(Color::DarkGray),
            ),
            Span::styled("]".to_string(), bracket),
        ];
    }
    let total = bar.total().max(1);
    let seg = |count: u32| (count as usize * width) / total as usize;
    let mut spans = vec![Span::styled("[".to_string(), bracket)];
    let mut used = 0usize;
    for (count, ch, style) in [
        (bar.covered_killed, '*', Style::default().fg(Color::Green)),
        (bar.covered, '+', Style::default().fg(Color::LightGreen)),
        (bar.partial, '-', Style::default().fg(Color::Yellow)),
    ] {
        let w = seg(count);
        if w > 0 {
            spans.push(Span::styled(ch.to_string().repeat(w), style));
            used += w;
        }
    }
    // Uncovered: a full red block.
    let uncovered = seg(bar.uncovered);
    if uncovered > 0 {
        spans.push(Span::styled(
            " ".repeat(uncovered),
            Style::default().bg(Color::Red),
        ));
        used += uncovered;
    }
    // Any remaining width (rounding + unknown lines) is neutral gray.
    if width > used {
        spans.push(Span::styled(
            " ".repeat(width - used),
            Style::default().bg(Color::DarkGray),
        ));
    }
    spans.push(Span::styled("]".to_string(), bracket));
    spans
}

/// Compact non-zero findings: `¤×2 T1×2 T2×5 T3×4`, colored, zeros omitted.
/// Returns the spans and their total character width (for column padding).
fn findings_spans(h: &crate::cli::diff::summary::HazardTotals, ascii: bool) -> (Vec<Span<'static>>, usize) {
    let mut spans = Vec::new();
    let mut width = 0usize;
    let mut push = |text: String, color: Color| {
        width += text.chars().count();
        spans.push(Span::styled(text, Style::default().fg(color)));
    };
    if h.hazards > 0 {
        push(
            format!("{}\u{00d7}{} ", GutterKind::Hazard.icon(ascii), h.hazards),
            Color::Red,
        );
    }
    if h.t1 > 0 {
        push(format!("T1\u{00d7}{} ", h.t1), Color::LightRed);
    }
    if h.t2 > 0 {
        push(format!("T2\u{00d7}{} ", h.t2), Color::Yellow);
    }
    if h.t3 > 0 {
        push(format!("T3\u{00d7}{} ", h.t3), Color::Gray);
    }
    (spans, width)
}


fn funnel_row(indent: &str, label: &str, spans: Vec<Span<'static>>) -> Line<'static> {
    let mut out = vec![Span::styled(
        format!("{indent}{label}"),
        Style::default().fg(Color::DarkGray),
    )];
    out.extend(spans);
    Line::from(out)
}

fn count_span(prefix: &str, n: u32, color: Color) -> Span<'static> {
    Span::styled(format!("{prefix}+{n}   "), Style::default().fg(color))
}

fn render_funnel(
    frame: &mut Frame,
    app: &App,
    area: Rect,
    title: &str,
    summary: &crate::cli::diff::summary::DiffSummary,
    border: Style,
) {
    let bar_w = (area.width as usize).saturating_sub(28).clamp(10, 40);
    let mut body: Vec<Line> = Vec::new();

    // Funnel: total -> code/other -> prod/test -> visibility.
    body.push(Line::from(vec![
        Span::styled(
            format!("+{} ", summary.total_added),
            Style::default().fg(Color::Green).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("-{} ", summary.total_removed),
            Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
        ),
        Span::styled("lines changed".to_string(), Style::default().fg(Color::Gray)),
    ]));
    body.push(funnel_row(
        "├ ",
        "",
        vec![
            count_span("code ", summary.code_added, Color::LightGreen),
            count_span("md/other ", summary.other_added, Color::Gray),
        ],
    ));
    body.push(funnel_row(
        "├ ",
        "",
        vec![
            count_span("prod ", summary.prod_code, Color::LightGreen),
            count_span("tests ", summary.test_code, Color::Cyan),
        ],
    ));
    body.push(funnel_row(
        "│   ",
        "",
        vec![
            count_span("public ", summary.public, Color::White),
            count_span("private ", summary.private, Color::Gray),
            count_span("other ", summary.other_vis, Color::DarkGray),
        ],
    ));
    body.push(Line::from(""));

    // Per-language table: language | public | private | findings | coverage.
    // (Aggregate coverage/hazards are intentionally omitted here — they are
    // shown per language in the table below.)
    const FIND_W: usize = 22;
    body.push(Line::from(Span::styled(
        format!(
            " {:<10} {:>8} {:>9}  {:<width$}coverage",
            "language",
            "public",
            "private",
            "findings",
            width = FIND_W
        ),
        Style::default().fg(Color::Gray).add_modifier(Modifier::BOLD),
    )));
    let lang_bar_w = (bar_w / 2).max(12);
    for lang in &summary.langs {
        let mut spans = vec![
            Span::styled(
                format!(" {:<10} ", truncate(&lang.language, 10)),
                Style::default().fg(Color::Cyan),
            ),
            Span::styled(
                format!("{:>8} ", format!("+{}", lang.public)),
                Style::default().fg(Color::White),
            ),
            Span::styled(
                format!("{:>9}  ", format!("+{}", lang.private)),
                Style::default().fg(Color::Gray),
            ),
        ];
        let (find_spans, find_w) = findings_spans(&lang.hazards, app.ascii);
        spans.extend(find_spans);
        spans.push(Span::raw(" ".repeat(FIND_W.saturating_sub(find_w))));
        spans.extend(coverage_bar_spans(&lang.bar, lang_bar_w));
        body.push(Line::from(spans));
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
        .constraints([Constraint::Length(4), Constraint::Min(1)])
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
            out.extend(pane_line_rows(
                line,
                app.ascii,
                app.truecolor,
                &lang,
                width,
                i == app.code_cursor,
            ));
            if app.detail_open.contains(&i) {
                out.extend(detail_lines(line, app.ascii, app.truecolor, width));
            }
        }
        let h = code_area.height.saturating_sub(2);
        let scroll = cursor_row.saturating_sub(h / 2);
        (out, scroll)
    } else {
        // Overview mode: fold unchanged runs.
        let max_rows = code_area.height.saturating_sub(2) as usize;
        let mut out: Vec<Line> = Vec::new();
        for row in fold_lines(lines, max_rows) {
            match row {
                DisplayRow::Code(l) => {
                    out.extend(pane_line_rows(l, app.ascii, app.truecolor, &lang, width, false))
                }
                DisplayRow::Elision => out.push(elision_line()),
            }
        }
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
    use crate::cli::diff::summary::HazardTotals;
    use crate::cli::tui::app::SummaryRow;
    const NAME_W: usize = 30;
    const DELTA_W: usize = 12;
    const FIND_W: usize = 20;
    let mut body: Vec<Line> = Vec::new();

    // Header row: function | delta | findings | coverage.
    body.push(Line::from(Span::styled(
        format!(
            " {:<nw$} {:<dw$} {:<fw$}coverage",
            "function",
            "delta",
            "findings",
            nw = NAME_W,
            dw = DELTA_W,
            fw = FIND_W
        ),
        Style::default().fg(Color::Gray).add_modifier(Modifier::BOLD),
    )));

    let bar_w = (area.width as usize).saturating_sub(NAME_W + DELTA_W + FIND_W + 6).clamp(10, 30);
    let row_line = |row: &SummaryRow| -> Line<'static> {
        let mut spans = vec![
            Span::styled(
                format!(" {:<nw$} ", truncate(&row.label, NAME_W), nw = NAME_W),
                Style::default().add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("{:<dw$} ", format!("+{} -{}", row.added, row.removed), dw = DELTA_W),
                Style::default().fg(Color::Gray),
            ),
        ];
        // Findings, matching the funnel's compact form (zeros omitted).
        let (find_spans, find_w) = findings_spans(
            &HazardTotals {
                hazards: row.uncovered_hazards,
                t1: row.t1_unkilled,
                t2: row.t2_unkilled,
                t3: row.t3_unkilled,
            },
            app.ascii,
        );
        if find_spans.is_empty() {
            spans.push(Span::styled(
                format!("{:<fw$}", "clean", fw = FIND_W),
                Style::default().fg(Color::Green),
            ));
        } else {
            spans.extend(find_spans);
            spans.push(Span::raw(" ".repeat(FIND_W.saturating_sub(find_w))));
        }
        spans.extend(coverage_bar_spans(&row.bar, bar_w));
        Line::from(spans)
    };

    if summary.rows.is_empty() {
        body.push(Line::from(Span::styled(
            " no changed children.".to_string(),
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
    fn expand_tabs_uses_four_column_stops() {
        assert_eq!(expand_tabs("\tx"), "    x");
        assert_eq!(expand_tabs("ab\tc"), "ab  c");
        assert_eq!(expand_tabs("abc\td"), "abc d");
        assert_eq!(expand_tabs("no tabs"), "no tabs");
    }

    #[test]
    fn tab_indented_code_renders_without_raw_tabs() {
        // Go/Rust code indented with tabs must not leak a raw `\t` into the
        // rendered cells (it would drift the terminal cursor and garble rows).
        let mut app = app_no_evidence();
        app.sources.insert(
            "src/app.rs".to_string(),
            "pub fn handler() {\n\tlet a = 1;\n\tlet b = 2;\n\tlet c = 3;\n\ta + b\n}\n".to_string(),
        );
        select(&mut app, "handler()");
        app.focus = crate::cli::tui::app::Focus::Code;
        let term = draw(&app, 0.0);
        let buf = term.backend().buffer();
        for y in 0..buf.area.height {
            for x in 0..buf.area.width {
                assert_ne!(
                    buf.cell((x, y)).unwrap().symbol(),
                    "\t",
                    "raw tab leaked into the render buffer at ({x},{y})"
                );
            }
        }
        // The indented body is still present (expanded).
        assert!(buffer_text(&term).contains("let b = 2;"));
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
    fn long_lines_wrap_with_a_hanging_indent() {
        let mut app = app_no_evidence();
        let long = format!("    let x = \"{}\";", "abcdefgh ".repeat(20));
        app.sources.insert(
            "src/app.rs".to_string(),
            format!("pub fn handler() {{\n{long}\n    let b = 2;\n}}\n"),
        );
        // Widen the unit so the long line is inside it.
        app.changes[0].units[0].end_line = 4;
        select(&mut app, "handler()");
        app.focus = crate::cli::tui::app::Focus::Code;
        let term = draw(&app, 0.0);
        let text = buffer_text(&term);
        // The tail of the long line is present (it wrapped rather than being cut).
        assert!(text.contains("abcdefgh"), "wrapped content should be visible");
        // No raw tab, and the line number 2 appears exactly once (continuation
        // rows carry no line number).
        let twos = text.matches("    2 +").count() + text.matches("    2  ").count();
        assert!(twos <= 1, "line number must not repeat on wrapped rows");
    }

    #[test]
    fn summary_row_renders_the_funnel() {
        use crate::cli::diff::summary::{CoverageBar, DiffSummary, HazardTotals, LangRow};
        let mut app = app_no_evidence();
        app.summary = DiffSummary {
            total_added: 9000,
            total_removed: 50,
            code_added: 8000,
            other_added: 1000,
            prod_code: 3000,
            test_code: 5000,
            public: 800,
            private: 1800,
            other_vis: 400,
            bar: CoverageBar {
                covered_killed: 40,
                covered: 30,
                partial: 10,
                uncovered: 20,
                unknown: 0,
            },
            hazards: HazardTotals {
                hazards: 4,
                t1: 10,
                t2: 3,
                t3: 1,
            },
            langs: vec![LangRow {
                language: "ruby".into(),
                public: 400,
                private: 700,
                other: 200,
                bar: CoverageBar {
                    covered_killed: 5,
                    covered: 3,
                    partial: 1,
                    uncovered: 1,
                    unknown: 0,
                },
                hazards: HazardTotals {
                    hazards: 2,
                    t1: 2,
                    t2: 5,
                    t3: 4,
                },
            }],
        };
        app.refresh_rows();
        app.selected = 0; // the [SUMMARY] row
        let text = buffer_text(&draw(&app, 0.0));
        assert!(text.contains("[SUMMARY]"), "left pane lists the summary row");
        assert!(text.contains("+9000"), "funnel shows total added");
        assert!(text.contains("code +8000"), "code vs other split");
        assert!(text.contains("public +800"), "visibility split");
        assert!(text.contains("language") && text.contains("ruby"));
        assert!(text.contains("T1"), "hazard tier row");
        // The coverage bar drew colored segment glyphs.
        assert!(text.contains('*') && text.contains('+') && text.contains('-'));
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
        // The container view is a table; verify() has one hazard and one T1.
        assert!(text.contains("function") && text.contains("findings"));
        assert!(text.contains("verify"));
        assert!(text.contains("T1"));
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
