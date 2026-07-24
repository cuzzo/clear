//! TUI application state, input handling, and right-pane model.
//!
//! All state transitions are pure (no terminal I/O), so navigation, search,
//! and the right-pane snap-to-function logic are unit-tested directly. The
//! crossterm event loop lives in `tui::run`.

use crate::cli::diff::gitdiff::{FileDiff, LineOrigin};
use crate::cli::diff::risk::CoverageState;
use crate::cli::diff::summary::DiffSummary;
use crate::cli::diff::tree::{Node, NodeKind};
use crate::cli::diff::units::{ChangedUnit, FileChange};
use crate::cli::gutter::GutterKind;
use crate::cli::line_evidence::{FindingDetail, HazardDetail, LineEvidence};
use crate::cli::tui::tree_view::{flatten, node_at, node_at_mut, FlatRow};
use crossterm::event::{KeyCode, KeyEvent};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

/// Which pane has keyboard focus.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    Tree,
    Code,
}

pub struct App {
    pub repo: PathBuf,
    pub db: PathBuf,
    pub root: Node,
    /// The changed units, kept so evidence can be re-overlaid as stages finish.
    pub changes: Vec<FileChange>,
    pub files: HashMap<String, FileDiff>,
    /// New-side file source, for rendering the full body of a function.
    pub sources: HashMap<String, String>,
    pub line_ev: HashMap<String, Vec<LineEvidence>>,
    pub rows: Vec<FlatRow>,
    pub selected: usize,
    pub search: String,
    pub searching: bool,
    pub should_quit: bool,
    pub ascii: bool,
    /// Whether the terminal supports 24-bit color (gates the diff row tints).
    pub truecolor: bool,
    pub target_label: String,
    /// The whole-change funnel, shown when the `[SUMMARY]` row is selected.
    pub summary: DiffSummary,
    /// Files with a diff, in display order (for header counts).
    pub file_count: usize,
    pub hazard_count: u32,
    /// Which pane has focus (Left/Right arrows switch).
    pub focus: Focus,
    /// Cursor line index within the right code pane.
    pub code_cursor: usize,
    /// Code-pane line indices whose SARIF detail drop-down is open.
    pub detail_open: HashSet<usize>,
    /// Fold regions (by their first hidden line index) expanded in the code pane.
    pub expanded_folds: HashSet<usize>,
}

/// A visible row in the folded code pane: a real diff line, or a collapsed run
/// of unchanged lines shown as a single `...` marker.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FoldRow {
    Line(usize),
    Fold { id: usize, count: usize },
}

/// Fold unchanged runs (away from any change) into single markers. Lines within
/// `expanded` are shown in full. Changed lines and a few lines of context around
/// them are always shown.
pub fn compute_fold_rows(lines: &[PaneLine], expanded: &HashSet<usize>) -> Vec<FoldRow> {
    const CTX: usize = 3;
    if lines.is_empty() {
        return Vec::new();
    }
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
            out.push(FoldRow::Line(i));
            i += 1;
        } else {
            let start = i;
            while i < lines.len() && !keep[i] {
                i += 1;
            }
            if expanded.contains(&start) {
                out.extend((start..i).map(FoldRow::Line));
            } else {
                out.push(FoldRow::Fold {
                    id: start,
                    count: i - start,
                });
            }
        }
    }
    out
}

/// One rendered line of the right pane (inline diff or private-signature list).
#[derive(Debug, Clone, PartialEq)]
pub struct PaneLine {
    pub origin: LineOrigin,
    pub new_lineno: Option<u32>,
    pub content: String,
    pub gutters: Vec<GutterKind>,
    pub covered: Option<bool>,
    /// SARIF findings / hazards / dark arms on this line, for the Space detail.
    pub findings: Vec<FindingDetail>,
    pub hazards: Vec<HazardDetail>,
    pub dark_arms: Vec<String>,
}

impl PaneLine {
    pub fn has_detail(&self) -> bool {
        !self.findings.is_empty() || !self.hazards.is_empty() || !self.dark_arms.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct InfoBox {
    pub title: String,
    pub hazards_total: u32,
    pub hazards_uncovered: u32,
    pub t1: u32,
    pub t2: u32,
    pub t3: u32,
    pub coverage: CoverageState,
}

/// Coverage breakdown of the units under a container node.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SummaryStats {
    pub covered_killed: u32,
    pub covered: u32,
    pub partial: u32,
    pub uncovered: u32,
    pub unknown: u32,
}

/// One child row in a container summary (a class in a file view, a file in a
/// directory view, etc.) with condensed findings.
#[derive(Debug, Clone, PartialEq)]
pub struct SummaryRow {
    pub label: String,
    pub kind: NodeKind,
    pub risk: f64,
    pub changed_loc: u32,
    pub added: u32,
    pub removed: u32,
    pub uncovered_hazards: u32,
    pub t1_unkilled: u32,
    pub t2_unkilled: u32,
    pub t3_unkilled: u32,
    /// Coverage of this child's added lines.
    pub bar: crate::cli::diff::summary::CoverageBar,
}

impl SummaryRow {
    pub fn has_findings(&self) -> bool {
        self.uncovered_hazards + self.t1_unkilled + self.t2_unkilled + self.t3_unkilled > 0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SummaryView {
    pub stats: SummaryStats,
    pub rows: Vec<SummaryRow>,
}

/// The right pane is a level-appropriate view of the selected tree node.
#[derive(Debug, Clone, PartialEq)]
pub enum PaneBody {
    /// A function: full body inline diff with per-line detail.
    Code {
        info: InfoBox,
        lines: Vec<PaneLine>,
    },
    /// A container: coverage stats + riskiest children with condensed findings.
    Summary(SummaryView),
    /// The top-level language funnel (the `[SUMMARY]` row).
    Funnel(DiffSummary),
    Empty(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct RightPane {
    pub title: String,
    pub body: PaneBody,
    /// File path of the shown unit, for syntax-highlight language selection.
    pub path: Option<String>,
}

fn count_hazards(changes: &[FileChange]) -> u32 {
    changes
        .iter()
        .flat_map(|c| &c.units)
        .map(|u| u.evidence.hazards_total)
        .sum()
}

impl App {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        repo: PathBuf,
        db: PathBuf,
        root: Node,
        changes: Vec<FileChange>,
        files: Vec<FileDiff>,
        sources: HashMap<String, String>,
        line_ev: HashMap<String, Vec<LineEvidence>>,
        target_label: String,
    ) -> Self {
        let files_by_path = files.into_iter().map(|f| (f.path.clone(), f)).collect();
        let mut app = App {
            repo,
            db,
            root,
            file_count: changes.len(),
            hazard_count: count_hazards(&changes),
            changes,
            files: files_by_path,
            sources,
            line_ev,
            rows: Vec::new(),
            selected: 0,
            search: String::new(),
            searching: false,
            should_quit: false,
            ascii: false,
            truecolor: true,
            target_label,
            summary: DiffSummary::default(),
            focus: Focus::Tree,
            code_cursor: 0,
            detail_open: HashSet::new(),
            expanded_folds: HashSet::new(),
        };
        app.refresh_rows();
        app.select_riskiest_file();
        app
    }

    /// Start focused on the riskiest file (its summary), not a function. Rows are
    /// risk-sorted, so the first File row on the opened max-risk path is it.
    fn select_riskiest_file(&mut self) {
        if let Some(idx) = self.rows.iter().position(|r| r.kind == NodeKind::File) {
            self.selected = idx;
        }
    }

    pub fn refresh_rows(&mut self) {
        // The synthetic `[SUMMARY]` row always leads the list; it carries the
        // whole-change totals and, when selected, shows the funnel.
        let mut rows = vec![FlatRow {
            path: Vec::new(),
            depth: 0,
            label: "[SUMMARY]".into(),
            kind: NodeKind::Summary,
            added: self.summary.total_added,
            removed: self.summary.total_removed,
            risk: 0.0,
            has_children: false,
            open: false,
        }];
        rows.extend(flatten(&self.root, &self.search));
        self.rows = rows;
        if self.selected >= self.rows.len() {
            self.selected = self.rows.len().saturating_sub(1);
        }
    }

    /// Whether the selected row is the synthetic summary row.
    fn summary_selected(&self) -> bool {
        self.selected_row().map(|r| r.kind) == Some(NodeKind::Summary)
    }

    pub fn selected_row(&self) -> Option<&FlatRow> {
        self.rows.get(self.selected)
    }

    pub fn selected_node(&self) -> Option<&Node> {
        if self.summary_selected() {
            return None;
        }
        let path = &self.selected_row()?.path;
        node_at(&self.root, path)
    }

    /// Reset the right pane when the selected function changes.
    fn on_selection_changed(&mut self) {
        self.code_cursor = 0;
        self.detail_open.clear();
        self.expanded_folds.clear();
    }

    /// The folded, navigable rows of the current code pane (empty for non-code).
    pub fn code_fold_rows(&self) -> Vec<FoldRow> {
        match self.right_pane().body {
            PaneBody::Code { lines, .. } => compute_fold_rows(&lines, &self.expanded_folds),
            _ => Vec::new(),
        }
    }

    fn move_down(&mut self) {
        if !self.rows.is_empty() {
            self.selected = (self.selected + 1).min(self.rows.len() - 1);
        }
        self.on_selection_changed();
    }

    fn move_up(&mut self) {
        self.selected = self.selected.saturating_sub(1);
        self.on_selection_changed();
    }

    fn set_open(&mut self, open: bool) {
        if let Some(row) = self.rows.get(self.selected) {
            let path = row.path.clone();
            if let Some(node) = node_at_mut(&mut self.root, &path) {
                if !node.children.is_empty() {
                    node.open = open;
                }
            }
            self.refresh_rows();
        }
    }

    /// Toggle the selected container open/closed (Space in the tree pane).
    fn toggle_open(&mut self) {
        let open = self
            .selected_row()
            .and_then(|row| node_at(&self.root, &row.path))
            .map(|node| !node.open)
            .unwrap_or(true);
        self.set_open(open);
    }

    /// Number of visible (folded) rows in the code pane (0 for summary views).
    fn code_len(&self) -> usize {
        self.code_fold_rows().len()
    }

    fn move_code_cursor(&mut self, delta: isize) {
        let len = self.code_len();
        if len == 0 {
            self.code_cursor = 0;
            return;
        }
        let next = self.code_cursor as isize + delta;
        self.code_cursor = next.clamp(0, len as isize - 1) as usize;
    }

    /// Space in the code pane: expand/collapse a `...` fold under the cursor,
    /// otherwise toggle that line's SARIF/hazard detail drop-down.
    fn toggle_code_row(&mut self) {
        match self.code_fold_rows().get(self.code_cursor).copied() {
            Some(FoldRow::Fold { id, .. }) => {
                if self.expanded_folds.contains(&id) {
                    self.expanded_folds.remove(&id);
                } else {
                    self.expanded_folds.insert(id);
                }
            }
            Some(FoldRow::Line(idx)) => {
                if self.detail_open.contains(&idx) {
                    self.detail_open.remove(&idx);
                } else {
                    self.detail_open.insert(idx);
                }
            }
            None => {}
        }
    }

    /// Handle a key press. Returns nothing; mutates state (including quit).
    pub fn handle_key(&mut self, key: KeyEvent) {
        if self.searching {
            match key.code {
                KeyCode::Esc | KeyCode::Enter => self.searching = false,
                KeyCode::Backspace => {
                    self.search.pop();
                    self.refresh_rows();
                }
                KeyCode::Char(c) => {
                    self.search.push(c);
                    self.selected = 0;
                    self.on_selection_changed();
                    self.refresh_rows();
                }
                _ => {}
            }
            return;
        }
        // Global keys.
        match key.code {
            KeyCode::Char('q') | KeyCode::Esc => {
                self.should_quit = true;
                return;
            }
            KeyCode::Char('/') => {
                self.searching = true;
                return;
            }
            // Left/Right switch panes.
            KeyCode::Left => {
                self.focus = Focus::Tree;
                return;
            }
            KeyCode::Right => {
                self.focus = Focus::Code;
                return;
            }
            _ => {}
        }
        match self.focus {
            Focus::Tree => match key.code {
                KeyCode::Down | KeyCode::Char('j') => self.move_down(),
                KeyCode::Up | KeyCode::Char('k') => self.move_up(),
                KeyCode::Char('l') | KeyCode::Enter => self.set_open(true),
                KeyCode::Char('h') => self.set_open(false),
                KeyCode::Char(' ') => self.toggle_open(),
                _ => {}
            },
            Focus::Code => match key.code {
                KeyCode::Down | KeyCode::Char('j') => self.move_code_cursor(1),
                KeyCode::Up | KeyCode::Char('k') => self.move_code_cursor(-1),
                KeyCode::Char(' ') | KeyCode::Enter => self.toggle_code_row(),
                _ => {}
            },
        }
    }

    /// The first changed unit under a node (the node itself if it is a unit),
    /// All changed units at or under a node.
    fn collect_units<'a>(node: &'a Node, out: &mut Vec<&'a ChangedUnit>) {
        if let Some(unit) = &node.unit {
            out.push(unit);
        }
        for child in &node.children {
            Self::collect_units(child, out);
        }
    }

    /// Coverage buckets over a set of units.
    fn summary_stats(units: &[&ChangedUnit]) -> SummaryStats {
        let mut stats = SummaryStats::default();
        for unit in units {
            match unit.evidence.coverage {
                CoverageState::CoveredKilled => stats.covered_killed += 1,
                CoverageState::Covered => stats.covered += 1,
                CoverageState::Partial => stats.partial += 1,
                CoverageState::Uncovered => stats.uncovered += 1,
                CoverageState::Unknown => stats.unknown += 1,
            }
        }
        stats
    }

    /// Condense a child node's descendant units into a summary row. "Unkilled"
    /// tiers exclude units already covered by a killed mutant.
    fn summary_row(child: &Node) -> SummaryRow {
        let mut units = Vec::new();
        Self::collect_units(child, &mut units);
        let mut row = SummaryRow {
            label: child.label.clone(),
            kind: child.kind,
            risk: child.risk.0,
            changed_loc: child.changed_loc(),
            added: child.added,
            removed: child.removed,
            uncovered_hazards: 0,
            t1_unkilled: 0,
            t2_unkilled: 0,
            t3_unkilled: 0,
            bar: crate::cli::diff::summary::CoverageBar::default(),
        };
        for unit in &units {
            let ev = &unit.evidence;
            row.uncovered_hazards += ev.hazards_uncovered;
            if ev.coverage != CoverageState::CoveredKilled {
                row.t1_unkilled += ev.t1_findings;
                row.t2_unkilled += ev.t2_findings;
                row.t3_unkilled += ev.t3_findings;
            }
            row.bar.covered_killed += ev.cov_killed;
            row.bar.covered += ev.cov_covered;
            row.bar.partial += ev.cov_partial;
            row.bar.uncovered += ev.cov_uncovered;
            row.bar.unknown += ev.cov_unknown;
        }
        row
    }

    /// Index a file's diff: which new-side lines were added, and which removed
    /// lines to interleave before each surviving new-side line. Boundaries come
    /// from the extractor (unit spans); this only overlays add/remove state onto
    /// the raw source, it does not re-parse structure.
    fn file_change_index(&self, path: &str) -> (HashSet<u32>, HashMap<u32, Vec<String>>) {
        let mut added = HashSet::new();
        let mut dels: HashMap<u32, Vec<String>> = HashMap::new();
        let file = match self.files.get(path) {
            Some(file) => file,
            None => return (added, dels),
        };
        for hunk in &file.hunks {
            let mut last_new = hunk.new_start;
            let mut pending: Vec<String> = Vec::new();
            for line in &hunk.lines {
                match line.origin {
                    LineOrigin::Add => {
                        let n = line.new_lineno.unwrap_or(last_new);
                        added.insert(n);
                        if !pending.is_empty() {
                            dels.entry(n).or_default().append(&mut pending);
                        }
                        last_new = n;
                    }
                    LineOrigin::Context => {
                        let n = line.new_lineno.unwrap_or(last_new);
                        if !pending.is_empty() {
                            dels.entry(n).or_default().append(&mut pending);
                        }
                        last_new = n;
                    }
                    LineOrigin::Del => pending.push(line.content.clone()),
                }
            }
            if !pending.is_empty() {
                dels.entry(last_new + 1).or_default().append(&mut pending);
            }
        }
        (added, dels)
    }

    fn del_line(content: &str) -> PaneLine {
        PaneLine {
            origin: LineOrigin::Del,
            new_lineno: None,
            content: content.to_string(),
            gutters: Vec::new(),
            covered: None,
            findings: Vec::new(),
            hazards: Vec::new(),
            dark_arms: Vec::new(),
        }
    }

    /// Build a code/context pane line, attaching this line's evidence detail.
    fn code_line(&self, path: &str, origin: LineOrigin, lineno: u32, content: String) -> PaneLine {
        let ev = self
            .line_ev
            .get(path)
            .and_then(|lines| lines.iter().find(|l| l.line == lineno));
        PaneLine {
            origin,
            new_lineno: Some(lineno),
            content,
            gutters: ev.map(|e| e.gutters.clone()).unwrap_or_default(),
            // Only surface a coverage mark where coverage was actually measured.
            covered: ev.and_then(|e| e.covered_known.then_some(e.covered)),
            findings: ev.map(|e| e.findings.clone()).unwrap_or_default(),
            hazards: ev.map(|e| e.hazards.clone()).unwrap_or_default(),
            dark_arms: ev.map(|e| e.dark_arms.clone()).unwrap_or_default(),
        }
    }

    /// Render a unit's FULL body (span start..=end) from the new-side source,
    /// with added lines marked and removed lines interleaved. Falls back to the
    /// raw hunk lines when the source is unavailable (e.g. a deleted file).
    fn full_unit_lines(&self, unit: &ChangedUnit) -> Vec<PaneLine> {
        if self.sources.contains_key(&unit.path) {
            self.full_span_lines(&unit.path, unit.start_line, unit.end_line)
        } else {
            self.hunk_pane_lines(unit)
        }
    }

    /// Build the inline-diff pane lines for a `[start, end]` line span of a
    /// file: every source line in the span (added lines marked, unchanged lines
    /// as context), with removed lines interleaved before the new-side line they
    /// preceded. Used for functions, structs/types, and whole files alike.
    fn full_span_lines(&self, path: &str, start: u32, end: u32) -> Vec<PaneLine> {
        let (added, dels_before) = self.file_change_index(path);
        let source = match self.sources.get(path) {
            Some(source) => source,
            None => return Vec::new(),
        };
        let lines: Vec<&str> = source.lines().collect();
        let mut out = Vec::new();
        for n in start..=end {
            if let Some(dels) = dels_before.get(&n) {
                out.extend(dels.iter().map(|d| Self::del_line(d)));
            }
            if let Some(text) = lines.get((n as usize).saturating_sub(1)) {
                let origin = if added.contains(&n) {
                    LineOrigin::Add
                } else {
                    LineOrigin::Context
                };
                out.push(self.code_line(path, origin, n, (*text).to_string()));
            }
        }
        if let Some(dels) = dels_before.get(&(end + 1)) {
            out.extend(dels.iter().map(|d| Self::del_line(d)));
        }
        out
    }

    /// The inline diff of an entire file (for file/doc nodes with no functions).
    fn full_file_lines(&self, path: &str) -> Vec<PaneLine> {
        let end = self
            .sources
            .get(path)
            .map(|s| s.lines().count() as u32)
            .unwrap_or(0);
        self.full_span_lines(path, 1, end)
    }

    /// An info box for a whole-file view: aggregate the file's unit evidence.
    fn file_info(&self, path: &str) -> InfoBox {
        let mut info = InfoBox {
            title: path.to_string(),
            hazards_total: 0,
            hazards_uncovered: 0,
            t1: 0,
            t2: 0,
            t3: 0,
            coverage: CoverageState::Unknown,
        };
        for change in self.changes.iter().filter(|c| c.path == path) {
            for unit in &change.units {
                let ev = &unit.evidence;
                info.hazards_total += ev.hazards_total;
                info.hazards_uncovered += ev.hazards_uncovered;
                info.t1 += ev.t1_findings;
                info.t2 += ev.t2_findings;
                info.t3 += ev.t3_findings;
            }
        }
        info
    }

    /// Fallback: the raw hunk lines within a unit's span (no full source).
    fn hunk_pane_lines(&self, unit: &ChangedUnit) -> Vec<PaneLine> {
        let file = match self.files.get(&unit.path) {
            Some(file) => file,
            None => return Vec::new(),
        };
        let mut out = Vec::new();
        for hunk in &file.hunks {
            let mut last_new = hunk.new_start;
            for line in &hunk.lines {
                let in_span = match line.origin {
                    LineOrigin::Add | LineOrigin::Context => {
                        let n = line.new_lineno.unwrap_or(last_new);
                        last_new = n;
                        n >= unit.start_line && n <= unit.end_line
                    }
                    LineOrigin::Del => last_new >= unit.start_line && last_new <= unit.end_line,
                };
                if in_span {
                    match line.new_lineno {
                        Some(n) => out.push(self.code_line(
                            &unit.path,
                            line.origin,
                            n,
                            line.content.clone(),
                        )),
                        None => out.push(Self::del_line(&line.content)),
                    }
                }
            }
        }
        out
    }

    fn info_for(unit: &ChangedUnit) -> InfoBox {
        let ev = &unit.evidence;
        InfoBox {
            title: format!("{} :: {}", unit.path, unit.name),
            hazards_total: ev.hazards_total,
            hazards_uncovered: ev.hazards_uncovered,
            t1: ev.t1_findings,
            t2: ev.t2_findings,
            t3: ev.t3_findings,
            coverage: ev.coverage,
        }
    }

    /// Minimum risk for a child to appear in a container summary.
    const SUMMARY_RISK_THRESHOLD: f64 = 1.0;

    /// Build the right pane for the current selection: a function shows its
    /// code; a container shows a level-appropriate risk summary.
    pub fn right_pane(&self) -> RightPane {
        if self.summary_selected() {
            return RightPane {
                title: "Change summary".into(),
                body: PaneBody::Funnel(self.summary.clone()),
                path: None,
            };
        }
        let node = match self.selected_node() {
            Some(node) => node,
            None => {
                return RightPane {
                    title: String::new(),
                    body: PaneBody::Empty("No changes.".into()),
                    path: None,
                }
            }
        };

        // Function leaf -> full code view.
        if node.kind == NodeKind::Function {
            if let Some(unit) = &node.unit {
                return RightPane {
                    title: format!("{} :: {}", unit.path, unit.name),
                    body: PaneBody::Code {
                        info: Self::info_for(unit),
                        lines: self.full_unit_lines(unit),
                    },
                    path: Some(unit.path.clone()),
                };
            }
        }

        // Container with changed children -> a risk summary of those children.
        let mut units = Vec::new();
        Self::collect_units(node, &mut units);
        let stats = Self::summary_stats(&units);
        let mut rows: Vec<SummaryRow> = node
            .children
            .iter()
            .map(Self::summary_row)
            .filter(|r| r.changed_loc > 0)
            .collect();
        rows.sort_by(|a, b| {
            b.risk
                .partial_cmp(&a.risk)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(b.changed_loc.cmp(&a.changed_loc))
                .then(a.label.cmp(&b.label))
        });
        if !rows.is_empty() {
            // Keep only the risk-bearing children when any clear the threshold.
            if rows.iter().any(|r| r.risk >= Self::SUMMARY_RISK_THRESHOLD) {
                rows.retain(|r| r.risk >= Self::SUMMARY_RISK_THRESHOLD);
            }
            return RightPane {
                title: node.path.clone().unwrap_or_else(|| node.label.clone()),
                body: PaneBody::Summary(SummaryView { stats, rows }),
                path: node.path.clone(),
            };
        }

        // No changed children (a struct/type, a docs/config file, ...): show the
        // inline diff of this node's own span, GitHub-style, instead of an empty
        // table. A node that carries a changed unit shows that unit's span; a
        // file node shows the whole file.
        if let Some(unit) = &node.unit {
            return RightPane {
                title: format!("{} :: {}", unit.path, unit.name),
                body: PaneBody::Code {
                    info: Self::info_for(unit),
                    lines: self.full_unit_lines(unit),
                },
                path: Some(unit.path.clone()),
            };
        }
        if let Some(path) = &node.path {
            if self.sources.contains_key(path) {
                return RightPane {
                    title: path.clone(),
                    body: PaneBody::Code {
                        info: self.file_info(path),
                        lines: self.full_file_lines(path),
                    },
                    path: Some(path.clone()),
                };
            }
        }

        RightPane {
            title: node.path.clone().unwrap_or_else(|| node.label.clone()),
            body: PaneBody::Empty("no changes to show".into()),
            path: node.path.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli::diff::gitdiff::{ChangeStatus, DiffLine, Hunk};
    use crate::cli::diff::risk::Evidence;
    use crate::cli::diff::tree::build_tree;
    use crate::cli::diff::visibility::Visibility;
    use crate::cli::project_root_of;
    use crate::model::UnitKind;
    use crossterm::event::KeyModifiers;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn code(pane: &RightPane) -> (InfoBox, Vec<PaneLine>) {
        match &pane.body {
            PaneBody::Code { info, lines } => (info.clone(), lines.clone()),
            other => panic!("expected code view, got {other:?}"),
        }
    }

    fn summary(pane: &RightPane) -> SummaryView {
        match &pane.body {
            PaneBody::Summary(s) => s.clone(),
            other => panic!("expected summary view, got {other:?}"),
        }
    }

    fn unit(name: &str, vis: Visibility, start: u32, end: u32, added: u32) -> ChangedUnit {
        ChangedUnit {
            name: name.into(),
            kind: UnitKind::Function,
            path: "proj/a.rs".into(),
            start_line: start,
            end_line: end,
            signature: format!("fn {name}()"),
            visibility: vis,
            is_test: false,
            added,
            removed: 0,
            added_lines: vec![],
            evidence: Evidence {
                t1_findings: added,
                hazards_total: if vis == Visibility::Public { 1 } else { 0 },
                ..Default::default()
            },
        }
    }

    fn sample_app() -> App {
        let units = vec![
            unit("alpha", Visibility::Public, 1, 5, 4),
            unit("beta", Visibility::Public, 10, 14, 2),
            unit("secret", Visibility::Private, 20, 22, 1),
        ];
        let change = FileChange {
            path: "proj/a.rs".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            is_test: false,
            units,
            file_added: 7,
            file_removed: 0,
            unattributed_added: 0,
            unattributed_removed: 0,
        };
        let file = FileDiff {
            path: "proj/a.rs".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            hunks: vec![Hunk {
                old_start: 1,
                old_lines: 1,
                new_start: 1,
                new_lines: 5,
                lines: vec![
                    DiffLine {
                        origin: LineOrigin::Context,
                        old_lineno: Some(1),
                        new_lineno: Some(1),
                        content: "fn alpha() {".into(),
                    },
                    DiffLine {
                        origin: LineOrigin::Add,
                        old_lineno: None,
                        new_lineno: Some(2),
                        content: "  let x = 1;".into(),
                    },
                    DiffLine {
                        origin: LineOrigin::Add,
                        old_lineno: None,
                        new_lineno: Some(3),
                        content: "  let y = 2;".into(),
                    },
                ],
            }],
        };
        let source = "fn alpha() {\n  let x = 1;\n  let y = 2;\n  ok()\n}\n\n\n\n\nfn beta() {\n  b1\n  b2\n  b3\n}\n\n\n\n\nfn secret() {\n  s1\n  s2\n}\n";
        let mut sources = HashMap::new();
        sources.insert("proj/a.rs".to_string(), source.to_string());
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

    #[test]
    fn navigation_moves_selection() {
        let mut app = sample_app();
        app.selected = 0; // start from the top regardless of initial file focus
        app.handle_key(key(KeyCode::Char('j')));
        assert_eq!(app.selected, 1);
        app.handle_key(key(KeyCode::Char('k')));
        assert_eq!(app.selected, 0);
        // Cannot move above the top.
        app.handle_key(key(KeyCode::Char('k')));
        assert_eq!(app.selected, 0);
    }

    #[test]
    fn quit_keys_set_flag() {
        let mut app = sample_app();
        app.handle_key(key(KeyCode::Char('q')));
        assert!(app.should_quit);
    }

    #[test]
    fn collapse_and_expand_change_visible_rows() {
        let mut app = sample_app();
        // Row 0 is the [SUMMARY] row; select the first collapsible container.
        app.selected = app.rows.iter().position(|r| r.has_children).unwrap();
        // h collapses, l expands (arrows now switch panes).
        let before = app.rows.len();
        app.handle_key(key(KeyCode::Char('h')));
        let after = app.rows.len();
        assert!(after < before);
        app.handle_key(key(KeyCode::Char('l')));
        assert!(app.rows.len() > after);
    }

    #[test]
    fn arrows_switch_pane_focus() {
        let mut app = sample_app();
        assert_eq!(app.focus, Focus::Tree);
        app.handle_key(key(KeyCode::Right));
        assert_eq!(app.focus, Focus::Code);
        app.handle_key(key(KeyCode::Left));
        assert_eq!(app.focus, Focus::Tree);
    }

    #[test]
    fn space_toggles_directory_in_tree_pane() {
        let mut app = sample_app();
        app.selected = app.rows.iter().position(|r| r.has_children).unwrap();
        let open_rows = app.rows.len();
        app.handle_key(key(KeyCode::Char(' '))); // collapse
        assert!(app.rows.len() < open_rows);
        app.handle_key(key(KeyCode::Char(' '))); // expand
        assert_eq!(app.rows.len(), open_rows);
    }

    #[test]
    fn space_toggles_detail_in_code_pane() {
        let mut app = sample_app();
        select(&mut app, "alpha()");
        app.focus = Focus::Code;
        app.code_cursor = 0;
        app.handle_key(key(KeyCode::Char(' ')));
        assert!(app.detail_open.contains(&0));
        app.handle_key(key(KeyCode::Char(' ')));
        assert!(!app.detail_open.contains(&0));
    }

    #[test]
    fn code_cursor_moves_and_clamps() {
        let mut app = sample_app();
        select(&mut app, "alpha()");
        app.focus = Focus::Code;
        app.handle_key(key(KeyCode::Down));
        assert_eq!(app.code_cursor, 1);
        // Up past the top clamps at 0.
        app.handle_key(key(KeyCode::Up));
        app.handle_key(key(KeyCode::Up));
        assert_eq!(app.code_cursor, 0);
    }

    #[test]
    fn search_filters_rows() {
        let mut app = sample_app();
        app.handle_key(key(KeyCode::Char('/')));
        assert!(app.searching);
        for c in "alpha".chars() {
            app.handle_key(key(KeyCode::Char(c)));
        }
        assert!(app.rows.iter().any(|r| r.label.contains("alpha")));
        assert!(!app.rows.iter().any(|r| r.label.contains("beta")));
        // Enter exits search but keeps the filter.
        app.handle_key(key(KeyCode::Enter));
        assert!(!app.searching);
        assert_eq!(app.search, "alpha");
        // Backspace re-broadens once back in search mode.
        app.handle_key(key(KeyCode::Char('/')));
        app.handle_key(key(KeyCode::Backspace));
        assert_eq!(app.search, "alph");
    }

    fn select(app: &mut App, label: &str) {
        app.selected = app.rows.iter().position(|r| r.label == label).unwrap();
    }

    #[test]
    fn function_view_shows_code_and_info() {
        let mut app = sample_app();
        select(&mut app, "alpha()");
        let (info, lines) = code(&app.right_pane());
        assert!(info.title.contains("alpha"));
        assert_eq!(info.hazards_total, 1);
        // The two added lines within alpha's span are in the pane.
        let added = lines.iter().filter(|l| l.origin == LineOrigin::Add).count();
        assert_eq!(added, 2);
    }

    #[test]
    fn function_view_shows_full_body_not_just_hunk() {
        let mut app = sample_app();
        select(&mut app, "alpha()");
        let (_, lines) = code(&app.right_pane());
        // alpha spans lines 1..=5: the whole body is shown, including context
        // lines the hunk never touched ("ok()", closing brace).
        assert_eq!(lines.len(), 5);
        assert!(lines
            .iter()
            .any(|l| l.origin == LineOrigin::Context && l.content.contains("fn alpha")));
        assert!(lines
            .iter()
            .any(|l| l.origin == LineOrigin::Context && l.content.contains("ok()")));
    }

    #[test]
    fn file_view_shows_summary_with_stats_and_child_rows() {
        let mut app = sample_app();
        select(&mut app, "a.rs");
        let s = summary(&app.right_pane());
        // Three changed functions (alpha, beta public; secret private) -> the
        // coverage buckets total the units.
        let total = s.stats.covered_killed
            + s.stats.covered
            + s.stats.partial
            + s.stats.uncovered
            + s.stats.unknown;
        assert!(total >= 3);
        // The riskiest public function is listed by name with its findings.
        assert!(s.rows.iter().any(|r| r.label == "alpha()"));
    }

    #[test]
    fn initial_focus_is_riskiest_file() {
        let app = sample_app();
        // Not row 0 (the project); the File row is selected.
        assert_eq!(app.selected_row().unwrap().kind, NodeKind::File);
    }

    #[test]
    fn full_body_interleaves_deletions() {
        use crate::cli::diff::gitdiff::{ChangeStatus, DiffLine, Hunk};
        let u = unit("f", Visibility::Public, 1, 3, 0);
        let change = FileChange {
            path: "proj/a.rs".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            is_test: false,
            units: vec![u],
            file_added: 0,
            file_removed: 1,
            unattributed_added: 0,
            unattributed_removed: 0,
        };
        let file = FileDiff {
            path: "proj/a.rs".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            hunks: vec![Hunk {
                old_start: 1,
                old_lines: 4,
                new_start: 1,
                new_lines: 3,
                lines: vec![
                    DiffLine {
                        origin: LineOrigin::Context,
                        old_lineno: Some(1),
                        new_lineno: Some(1),
                        content: "keep1".into(),
                    },
                    DiffLine {
                        origin: LineOrigin::Del,
                        old_lineno: Some(2),
                        new_lineno: None,
                        content: "removed".into(),
                    },
                    DiffLine {
                        origin: LineOrigin::Context,
                        old_lineno: Some(3),
                        new_lineno: Some(2),
                        content: "keep2".into(),
                    },
                    DiffLine {
                        origin: LineOrigin::Context,
                        old_lineno: Some(4),
                        new_lineno: Some(3),
                        content: "keep3".into(),
                    },
                ],
            }],
        };
        let mut sources = HashMap::new();
        sources.insert("proj/a.rs".to_string(), "keep1\nkeep2\nkeep3\n".to_string());
        let root = build_tree(std::slice::from_ref(&change), project_root_of);
        let mut app = App::new(
            PathBuf::from("."),
            PathBuf::from("/nonexistent/gigasail.db"),
            root,
            vec![change],
            vec![file],
            sources,
            HashMap::new(),
            "x".into(),
        );
        app.selected = app.rows.iter().position(|r| r.label == "f()").unwrap();
        let (_, lines) = code(&app.right_pane());
        let content: Vec<_> = lines
            .iter()
            .map(|l| (l.origin, l.content.as_str()))
            .collect();
        // The removed line appears between keep1 and keep2.
        assert_eq!(
            content,
            vec![
                (LineOrigin::Context, "keep1"),
                (LineOrigin::Del, "removed"),
                (LineOrigin::Context, "keep2"),
                (LineOrigin::Context, "keep3"),
            ]
        );
    }

    #[test]
    fn private_group_summarizes_its_functions() {
        let mut app = sample_app();
        app.search = "PRIVATE".into();
        app.refresh_rows();
        app.selected = app
            .rows
            .iter()
            .position(|r| r.kind == NodeKind::PrivateGroup)
            .unwrap();
        let s = summary(&app.right_pane());
        assert!(s.rows.iter().any(|r| r.label == "secret()"));
    }

    #[test]
    fn header_counts_files_and_hazards() {
        let app = sample_app();
        assert_eq!(app.file_count, 1);
        // alpha + beta each carry one hazard (public); secret none.
        assert_eq!(app.hazard_count, 2);
    }

    #[test]
    fn right_pane_empty_when_no_rows() {
        let mut app = sample_app();
        app.rows.clear();
        let pane = app.right_pane();
        assert_eq!(pane.body, PaneBody::Empty("No changes.".into()));
    }

    #[test]
    fn search_backspace_on_empty_is_safe() {
        let mut app = sample_app();
        app.handle_key(key(KeyCode::Char('/')));
        app.handle_key(key(KeyCode::Backspace));
        assert_eq!(app.search, "");
    }

    #[test]
    fn compute_fold_rows_collapses_and_expands_unchanged_runs() {
        let mk = |origin| PaneLine {
            origin,
            new_lineno: Some(1),
            content: "x".into(),
            gutters: vec![],
            covered: None,
            findings: vec![],
            hazards: vec![],
            dark_arms: vec![],
        };
        let mut lines: Vec<PaneLine> = (0..20).map(|_| mk(LineOrigin::Context)).collect();
        lines[2].origin = LineOrigin::Add;

        let mut expanded = HashSet::new();
        let rows = compute_fold_rows(&lines, &expanded);
        // The change near the top keeps a few lines; the long tail folds.
        let fold = rows.iter().find_map(|r| match r {
            FoldRow::Fold { id, .. } => Some(*id),
            _ => None,
        });
        assert!(fold.is_some(), "unchanged tail should fold to a marker");

        // Expanding that region shows every line.
        expanded.insert(fold.unwrap());
        let rows = compute_fold_rows(&lines, &expanded);
        assert!(
            rows.iter().all(|r| matches!(r, FoldRow::Line(_))),
            "expanded fold shows all lines"
        );
    }
}
