use crate::extract::BoundaryExtractor;
use crate::model::{Event, EventType, LogicalUnit, UnitKind};
use crate::storage::Storage;
use crate::vcs::VcsProvider;
use anyhow::Result;
use rayon::prelude::*;
use std::collections::{HashMap, HashSet};

const MOVE_SIZE_RATIO_FLOOR: f64 = 0.50;

#[derive(serde::Serialize, serde::Deserialize)]
struct EngineState {
    previous: HashMap<String, LogicalUnit>,
    aliases: HashMap<String, String>,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct EngineStats {
    pub commits: usize,
    pub logical_units: usize,
    pub events: usize,
    pub moves: usize,
    pub fixes: usize,
    pub changes: usize,
}

pub struct LineageEngine<P, E> {
    provider: P,
    extractor: E,
    storage: Storage,
}

impl<P, E> LineageEngine<P, E>
where
    P: VcsProvider + Sync,
    E: BoundaryExtractor + Sync,
{
    pub fn new(provider: P, extractor: E, storage: Storage) -> Self {
        Self {
            provider,
            extractor,
            storage,
        }
    }

    pub fn run(&mut self, max_commits: Option<usize>) -> Result<EngineStats> {
        self.storage.begin_transaction()?;
        match self.run_inner(max_commits) {
            Ok(stats) => {
                self.storage.commit_transaction()?;
                Ok(stats)
            }
            Err(error) => {
                let _ = self.storage.rollback_transaction();
                Err(error)
            }
        }
    }

    fn run_inner(&mut self, max_commits: Option<usize>) -> Result<EngineStats> {
        let mut commits = self.provider.list_commits()?;
        if let Some(max) = max_commits {
            if commits.len() > max {
                commits = commits.split_off(commits.len() - max);
            }
        }

        let mut start_idx = 0;
        let mut previous: HashMap<String, LogicalUnit> = HashMap::new();
        let mut aliases: HashMap<String, String> = HashMap::new();

        for i in (0..commits.len()).rev() {
            if let Ok(Some(state_json)) = self.storage.load_engine_state(&commits[i].hash) {
                if let Ok(state) = serde_json::from_str::<EngineState>(&state_json) {
                    previous = state.previous;
                    aliases = state.aliases;
                    start_idx = i + 1;
                    break;
                }
            }
        }

        let mut previous_by_name: HashMap<(UnitKind, String), Vec<String>> = HashMap::new();
        let mut file_units: HashMap<String, Vec<LogicalUnit>> = HashMap::new();
        if start_idx > 0 {
            for unit in previous.values() {
                previous_by_name
                    .entry((unit.kind, unit.name.clone()))
                    .or_default()
                    .push(unit.id.clone());
                file_units.entry(unit.path.clone()).or_default().push(unit.clone());
            }
        }

        let mut stats = EngineStats::default();

        let provider = &self.provider;
        let extractor = &self.extractor;
        let commits_changes: Result<Vec<_>> = (start_idx..commits.len())
            .into_par_iter()
            .map(|idx| {
                let commit = &commits[idx];
                let prev_commit_hash = if idx == 0 {
                    None
                } else {
                    Some(commits[idx - 1].hash.as_str())
                };
                let path_filter = |path: &str| extractor.supports_path(path);
                provider.changes_at_commit(
                    prev_commit_hash,
                    &commit.hash,
                    &path_filter,
                )
            })
            .collect();
        let commits_changes = commits_changes?;

        let extractor = &self.extractor;
        let parsed_commits_units: Vec<Vec<Vec<LogicalUnit>>> = commits_changes
            .par_iter()
            .map(|changes| {
                changes
                    .added_or_modified
                    .par_iter()
                    .map(|file| extractor.extract_units(file))
                    .collect()
            })
            .collect();

        let mut last_commit_hash = None;
        for (commit_idx, commit) in commits.into_iter().enumerate().skip(start_idx) {
            self.storage.insert_metadata(&commit)?;
            let mut current = HashMap::new();
            let mut claimed_moves = HashSet::new();

            let suffix_idx = commit_idx - start_idx;
            let changes = &commits_changes[suffix_idx];
            let commit_parsed_units = &parsed_commits_units[suffix_idx];

            for (file_idx, file) in changes.added_or_modified.iter().enumerate() {
                let units = commit_parsed_units[file_idx].clone();
                file_units.insert(file.path.clone(), units);
            }

            for path in &changes.deleted {
                file_units.remove(path);
            }

            let extracted_units = file_units
                .values()
                .flatten()
                .cloned()
                .collect::<Vec<_>>();

            let observed_current_ids = extracted_units
                .iter()
                .map(|unit| {
                    aliases
                        .get(&unit.id)
                        .cloned()
                        .unwrap_or_else(|| unit.id.clone())
                })
                .collect::<HashSet<_>>();
            for unit in extracted_units {
                let mut unit = unit;
                let observed_id = unit.id.clone();
                if let Some(canonical_id) = aliases.get(&observed_id).cloned() {
                    unit.id = canonical_id;
                }
                stats.logical_units += 1;

                let mut is_new = false;
                if let Some(prev) = previous.get(&unit.id) {
                    if let Some(event_type) = classify_event(prev, &unit, commit.is_fix()) {
                        let event = Event {
                            unit_id: unit.id.clone(),
                            commit_hash: commit.hash.clone(),
                            event_type,
                            path: unit.path.clone(),
                            name: unit.name.clone(),
                            start_line: unit.start_line,
                            end_line: unit.end_line,
                            semantic_change: event_type != EventType::Move,
                            lines_added: (unit.line_count() - prev.line_count()).max(0),
                            lines_removed: (prev.line_count() - unit.line_count()).max(0),
                            timestamp: commit.timestamp,
                        };
                        self.storage.insert_event(&event)?;
                        stats.events += 1;
                        match event_type {
                            EventType::Move => stats.moves += 1,
                            EventType::Fix => stats.fixes += 1,
                            EventType::Change => stats.changes += 1,
                        }
                    }
                } else if let Some(prev) =
                    find_moved_unit(&previous, &previous_by_name, &claimed_moves, &observed_current_ids, &unit)
                {
                    let previous_id = prev.id.clone();
                    let semantic_change = prev.normalized_hash != unit.normalized_hash;
                    let event = Event {
                        unit_id: previous_id.clone(),
                        commit_hash: commit.hash.clone(),
                        event_type: EventType::Move,
                        path: unit.path.clone(),
                        name: unit.name.clone(),
                        start_line: unit.start_line,
                        end_line: unit.end_line,
                        semantic_change: false,
                        lines_added: 0,
                        lines_removed: 0,
                        timestamp: commit.timestamp,
                    };
                    self.storage.insert_event(&event)?;
                    stats.events += 1;
                    stats.moves += 1;
                    if semantic_change {
                        let event_type = if commit.is_fix() {
                            EventType::Fix
                        } else {
                            EventType::Change
                        };
                        let event = Event {
                            unit_id: previous_id.clone(),
                            commit_hash: commit.hash.clone(),
                            event_type,
                            path: unit.path.clone(),
                            name: unit.name.clone(),
                            start_line: unit.start_line,
                            end_line: unit.end_line,
                            semantic_change: true,
                            lines_added: (unit.line_count() - prev.line_count()).max(0),
                            lines_removed: (prev.line_count() - unit.line_count()).max(0),
                            timestamp: commit.timestamp,
                        };
                        self.storage.insert_event(&event)?;
                        stats.events += 1;
                        match event_type {
                            EventType::Fix => stats.fixes += 1,
                            EventType::Change => stats.changes += 1,
                            EventType::Move => {}
                        }
                    }
                    claimed_moves.insert(previous_id.clone());
                    aliases.insert(observed_id, previous_id.clone());
                    unit.id = previous_id;
                } else {
                    is_new = true;
                }

                if is_new {
                    self.storage.upsert_logical_unit(&unit, commit.timestamp)?;
                }
                current.insert(unit.id.clone(), unit);
            }
            previous = current;
            previous_by_name.clear();
            for unit in previous.values() {
                previous_by_name
                    .entry((unit.kind, unit.name.clone()))
                    .or_default()
                    .push(unit.id.clone());
            }
            stats.commits += 1;
            last_commit_hash = Some(commit.hash.clone());
        }

        if let Some(hash) = last_commit_hash {
            let state = EngineState {
                previous: previous.clone(),
                aliases: aliases.clone(),
            };
            let state_json = serde_json::to_string(&state)?;
            self.storage.save_engine_state(&hash, &state_json)?;
        }

        Ok(stats)
    }
}

fn find_moved_unit<'a>(
    previous: &'a HashMap<String, LogicalUnit>,
    previous_by_name: &'a HashMap<(UnitKind, String), Vec<String>>,
    claimed_moves: &HashSet<String>,
    observed_current_ids: &HashSet<String>,
    current: &LogicalUnit,
) -> Option<&'a LogicalUnit> {
    let candidates = previous_by_name.get(&(current.kind, current.name.clone()))?;
    candidates
        .iter()
        .filter_map(|id| previous.get(id))
        .filter(|prev| {
            !claimed_moves.contains(&prev.id)
                && !observed_current_ids.contains(&prev.id)
                && prev.path != current.path
                && size_ratio(prev, current) >= MOVE_SIZE_RATIO_FLOOR
                && is_valid_cross_file_move(prev, current)
        })
        .filter_map(|prev| {
            let similarity = block_similarity(prev, current);
            let meaningful_len = get_meaningful_lines(prev).len().max(get_meaningful_lines(current).len());
            let threshold = get_similarity_threshold(meaningful_len);
            (similarity >= threshold).then_some((prev, similarity))
        })
        .max_by(|(_, left), (_, right)| left.partial_cmp(right).unwrap_or(std::cmp::Ordering::Equal))
        .map(|(prev, _)| prev)
}

fn get_similarity_threshold(block_size: usize) -> f64 {
    if block_size <= 2 {
        0.95
    } else if block_size == 3 {
        0.80
    } else if block_size == 4 {
        0.72
    } else {
        let raw = 0.75 - (block_size as f64 - 3.0) * 0.02;
        raw.max(0.50)
    }
}

fn is_meaningless_line(line: &str, path: &str) -> bool {
    let ext = path.rsplit_once('.').map(|(_, ext)| ext.to_ascii_lowercase()).unwrap_or_default();
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return true;
    }
    match ext.as_str() {
        "rb" | "lua" => trimmed.eq_ignore_ascii_case("end"),
        "go" | "rs" | "c" | "h" | "cc" | "cpp" | "cxx" | "hh" | "hpp" | "hxx" | "cs" | "java" | "kt" | "kts" | "swift" | "js" | "jsx" | "ts" | "tsx" | "zig" | "php" => {
            matches!(trimmed, "}" | "{" | "};" | "{}")
        }
        _ => false
    }
}

fn is_trivial_line(line: &str) -> bool {
    let clean = line.replace(|c: char| c.is_whitespace(), "");
    if clean.is_empty() {
        return true;
    }
    if clean.len() < 20 {
        let has_chaining = clean.matches('.').count() >= 2 || clean.contains("|>") || clean.contains("->");
        let has_closure = clean.contains("{|") || clean.contains("=>") || clean.contains("->") || clean.contains("||");
        let has_complex_op = clean.contains("&&") || clean.contains("==") || clean.contains("!=");
        if !has_chaining && !has_closure && !has_complex_op {
            return true;
        }
    }
    let lower = clean.to_lowercase();
    if lower == "returntrue" || lower == "returnfalse" || lower == "returnnull" || lower == "return" || lower == "return;" || lower == "return0" || lower == "return1" {
        return true;
    }
    false
}

fn is_valid_cross_file_move(prev: &LogicalUnit, current: &LogicalUnit) -> bool {
    let prev_lines = get_meaningful_lines(prev);
    let current_lines = get_meaningful_lines(current);

    if prev_lines.len() <= 1 || current_lines.len() <= 1 {
        return false;
    }

    let prev_body_len = prev_lines.len() - 1;
    let current_body_len = current_lines.len() - 1;

    // If it's a single line body statement, we require it to be non-trivial.
    if prev_body_len == 1 && is_trivial_line(prev_lines[1]) {
        return false;
    }
    if current_body_len == 1 && is_trivial_line(current_lines[1]) {
        return false;
    }

    true
}

fn get_meaningful_lines(unit: &LogicalUnit) -> Vec<&str> {
    unit.normalized_source
        .lines()
        .filter(|line| !is_meaningless_line(line, &unit.path))
        .collect()
}

fn classify_event(previous: &LogicalUnit, current: &LogicalUnit, fix_commit: bool) -> Option<EventType> {
    let moved = previous.path != current.path;
    let changed = previous.normalized_hash != current.normalized_hash;

    match (moved, changed, fix_commit) {
        (true, false, _) => Some(EventType::Move),
        (_, true, true) => Some(EventType::Fix),
        (_, true, false) => Some(EventType::Change),
        _ => None,
    }
}

fn size_ratio(previous: &LogicalUnit, current: &LogicalUnit) -> f64 {
    let left = get_meaningful_lines(previous).len().max(1) as f64;
    let right = get_meaningful_lines(current).len().max(1) as f64;
    left.min(right) / left.max(right)
}

fn block_similarity(previous: &LogicalUnit, current: &LogicalUnit) -> f64 {
    if previous.normalized_hash == current.normalized_hash {
        return 1.0;
    }

    let left = get_meaningful_lines(previous);
    let right = get_meaningful_lines(current);
    let max_len = left.len().max(right.len());
    if max_len == 0 {
        return 1.0;
    }

    let distance = levenshtein_lines(&left, &right);
    1.0 - (distance as f64 / max_len as f64)
}

fn levenshtein_lines(left: &[&str], right: &[&str]) -> usize {
    if left.is_empty() {
        return right.len();
    }
    if right.is_empty() {
        return left.len();
    }

    let mut previous: Vec<usize> = (0..=right.len()).collect();
    let mut current = vec![0; right.len() + 1];
    for (left_index, left_line) in left.iter().enumerate() {
        current[0] = left_index + 1;
        for (right_index, right_line) in right.iter().enumerate() {
            let substitution = previous[right_index] + usize::from(left_line != right_line);
            let insertion = current[right_index] + 1;
            let deletion = previous[right_index + 1] + 1;
            current[right_index + 1] = substitution.min(insertion).min(deletion);
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[right.len()]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{BlobFile, CommitMetadata, UnitKind};

    struct MemoryProvider {
        commits: Vec<CommitMetadata>,
        files: HashMap<String, Vec<BlobFile>>,
    }

    impl VcsProvider for MemoryProvider {
        fn list_commits(&self) -> Result<Vec<CommitMetadata>> {
            Ok(self.commits.clone())
        }

        fn files_at_commit(
            &self,
            commit_hash: &str,
            path_filter: &dyn Fn(&str) -> bool,
        ) -> Result<Vec<BlobFile>> {
            Ok(self
                .files
                .get(commit_hash)
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter(|file| path_filter(&file.path))
                .collect())
        }
    }

    #[test]
    fn classifies_moves_without_counting_them_as_changes() {
        let unit_a = LogicalUnit::new("run", UnitKind::Function, "src/a.rb", 1, 1, 3, "def run", "def run\n1\nend");
        let unit_b = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/b.rb",
            1,
            10,
            12,
            "def run",
            "def run\n1\nend",
        );

        assert_eq!(classify_event(&unit_a, &unit_b, false), Some(EventType::Move));
    }

    #[test]
    fn runs_against_provider_snapshots() {
        let commits = vec![
            CommitMetadata {
                hash: "c1".into(),
                message: "initial".into(),
                timestamp: 1,
            },
            CommitMetadata {
                hash: "c2".into(),
                message: "fix run".into(),
                timestamp: 2,
            },
        ];
        let mut files = HashMap::new();
        files.insert(
            "c1".into(),
            vec![BlobFile {
                path: "src/a.rb".into(),
                contents: "def run\n1\nend\n".into(),
            }],
        );
        files.insert(
            "c2".into(),
            vec![BlobFile {
                path: "src/a.rb".into(),
                contents: "def run\n2\nend\n".into(),
            }],
        );

        let provider = MemoryProvider { commits, files };
        let storage = Storage::open_memory().unwrap();
        let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
        let stats = engine.run(None).unwrap();

        assert_eq!(stats.commits, 2);
        assert_eq!(stats.events, 1);
        assert_eq!(stats.fixes, 1);
    }

    #[test]
    fn capped_runs_keep_latest_commits() {
        let commits = vec![
            CommitMetadata {
                hash: "c1".into(),
                message: "initial".into(),
                timestamp: 1,
            },
            CommitMetadata {
                hash: "c2".into(),
                message: "middle".into(),
                timestamp: 2,
            },
            CommitMetadata {
                hash: "c3".into(),
                message: "head".into(),
                timestamp: 3,
            },
        ];
        let mut files = HashMap::new();
        for commit in &commits {
            files.insert(
                commit.hash.clone(),
                vec![BlobFile {
                    path: "src/a.rb".into(),
                    contents: "def run\n1\nend\n".into(),
                }],
            );
        }

        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("lineage.db");
        let provider = MemoryProvider { commits, files };
        let storage = Storage::open(&db).unwrap();
        let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
        let stats = engine.run(Some(2)).unwrap();
        let storage = Storage::open_existing(&db).unwrap();

        assert_eq!(stats.commits, 2);
        assert!(!storage.commit_exists("c1").unwrap());
        assert!(storage.commit_exists("c2").unwrap());
        assert!(storage.commit_exists("c3").unwrap());
    }

    #[test]
    fn ignores_comment_only_changes_inside_a_function() {
        let commits = vec![
            CommitMetadata {
                hash: "c1".into(),
                message: "initial".into(),
                timestamp: 1,
            },
            CommitMetadata {
                hash: "c2".into(),
                message: "fix docs near run".into(),
                timestamp: 2,
            },
        ];
        let mut files = HashMap::new();
        files.insert(
            "c1".into(),
            vec![BlobFile {
                path: "src/a.rb".into(),
                contents: "def run\n1\nend\n".into(),
            }],
        );
        files.insert(
            "c2".into(),
            vec![BlobFile {
                path: "src/a.rb".into(),
                contents: "def run\n# explain the invariant\n1\nend\n".into(),
            }],
        );

        let provider = MemoryProvider { commits, files };
        let storage = Storage::open_memory().unwrap();
        let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
        let stats = engine.run(None).unwrap();

        assert_eq!(stats.events, 0);
        assert_eq!(stats.fixes, 0);
        assert_eq!(stats.changes, 0);
    }

    #[test]
    fn preserves_unit_identity_for_pure_file_moves() {
        let commits = vec![
            CommitMetadata {
                hash: "c1".into(),
                message: "initial".into(),
                timestamp: 1,
            },
            CommitMetadata {
                hash: "c2".into(),
                message: "move run".into(),
                timestamp: 2,
            },
        ];
        let mut files = HashMap::new();
        files.insert(
            "c1".into(),
            vec![BlobFile {
                path: "src/a.rb".into(),
                contents: "def run\n  foo.bar.baz.map { |x| x.to_s }\nend\n".into(),
            }],
        );
        files.insert(
            "c2".into(),
            vec![BlobFile {
                path: "src/b.rb".into(),
                contents: "def run\n  foo.bar.baz.map { |x| x.to_s }\nend\n".into(),
            }],
        );

        let provider = MemoryProvider { commits, files };
        let storage = Storage::open_memory().unwrap();
        let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
        let stats = engine.run(None).unwrap();

        assert_eq!(stats.events, 1);
        assert_eq!(stats.moves, 1);
        assert_eq!(stats.fixes, 0);
        assert_eq!(stats.changes, 0);
    }

    #[test]
    fn does_not_count_same_file_line_drift_as_a_move() {
        let commits = vec![
            CommitMetadata {
                hash: "c1".into(),
                message: "initial".into(),
                timestamp: 1,
            },
            CommitMetadata {
                hash: "c2".into(),
                message: "add helper above run".into(),
                timestamp: 2,
            },
        ];
        let mut files = HashMap::new();
        files.insert(
            "c1".into(),
            vec![BlobFile {
                path: "src/a.rb".into(),
                contents: "def run\n1\nend\n".into(),
            }],
        );
        files.insert(
            "c2".into(),
            vec![BlobFile {
                path: "src/a.rb".into(),
                contents: "def helper\n0\nend\n\ndef run\n1\nend\n".into(),
            }],
        );

        let provider = MemoryProvider { commits, files };
        let storage = Storage::open_memory().unwrap();
        let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
        let stats = engine.run(None).unwrap();

        assert_eq!(stats.moves, 0);
        assert_eq!(stats.fixes, 0);
        assert_eq!(stats.changes, 0);
        assert_eq!(stats.events, 0);
    }

    #[test]
    fn records_move_and_fix_for_similar_moved_block() {
        let commits = vec![
            CommitMetadata {
                hash: "c1".into(),
                message: "initial".into(),
                timestamp: 1,
            },
            CommitMetadata {
                hash: "c2".into(),
                message: "fix moved run".into(),
                timestamp: 2,
            },
        ];
        let mut files = HashMap::new();
        files.insert(
            "c1".into(),
            vec![BlobFile {
                path: "src/a.rb".into(),
                contents: "def run\nalpha\nbeta\ngamma\nend\n".into(),
            }],
        );
        files.insert(
            "c2".into(),
            vec![BlobFile {
                path: "src/b.rb".into(),
                contents: "def run\nalpha\nbeta\ndelta\nend\n".into(),
            }],
        );

        let provider = MemoryProvider { commits, files };
        let storage = Storage::open_memory().unwrap();
        let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
        let stats = engine.run(None).unwrap();

        assert_eq!(stats.moves, 1);
        assert_eq!(stats.fixes, 1);
        assert_eq!(stats.changes, 0);
        assert_eq!(stats.events, 2);
    }

    #[test]
    fn does_not_treat_same_named_rewrite_as_move() {
        let commits = vec![
            CommitMetadata {
                hash: "c1".into(),
                message: "initial".into(),
                timestamp: 1,
            },
            CommitMetadata {
                hash: "c2".into(),
                message: "fix replacement".into(),
                timestamp: 2,
            },
        ];
        let mut files = HashMap::new();
        files.insert(
            "c1".into(),
            vec![BlobFile {
                path: "src/a.rb".into(),
                contents: "def run\nalpha\nbeta\ngamma\nend\n".into(),
            }],
        );
        files.insert(
            "c2".into(),
            vec![BlobFile {
                path: "src/b.rb".into(),
                contents: "def run(a, b, c)\nnetwork\nsocket\nretry\nfallback\nmetrics\nend\n".into(),
            }],
        );

        let provider = MemoryProvider { commits, files };
        let storage = Storage::open_memory().unwrap();
        let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
        let stats = engine.run(None).unwrap();

        assert_eq!(stats.events, 0);
        assert_eq!(stats.moves, 0);
        assert_eq!(stats.fixes, 0);
    }

    #[test]
    fn does_not_treat_added_same_named_block_as_a_move_when_original_remains() {
        let commits = vec![
            CommitMetadata {
                hash: "c1".into(),
                message: "initial".into(),
                timestamp: 1,
            },
            CommitMetadata {
                hash: "c2".into(),
                message: "fix add second run".into(),
                timestamp: 2,
            },
        ];
        let mut files = HashMap::new();
        files.insert(
            "c1".into(),
            vec![BlobFile {
                path: "src/a.rb".into(),
                contents: "def run\nalpha\nbeta\ngamma\nend\n".into(),
            }],
        );
        files.insert(
            "c2".into(),
            vec![
                BlobFile {
                    path: "src/a.rb".into(),
                    contents: "def run\nalpha\nbeta\ngamma\nend\n".into(),
                },
                BlobFile {
                    path: "src/b.rb".into(),
                    contents: "def run\nalpha\nbeta\ndelta\nend\n".into(),
                },
            ],
        );

        let provider = MemoryProvider { commits, files };
        let storage = Storage::open_memory().unwrap();
        let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
        let stats = engine.run(None).unwrap();

        assert_eq!(stats.events, 0);
        assert_eq!(stats.moves, 0);
        assert_eq!(stats.fixes, 0);
    }

    #[test]
    fn does_not_track_meaningless_line_moves() {
        let commits = vec![
            CommitMetadata { hash: "c1".into(), message: "init".into(), timestamp: 1 },
            CommitMetadata { hash: "c2".into(), message: "move".into(), timestamp: 2 },
        ];
        let mut files = HashMap::new();
        files.insert("c1".into(), vec![BlobFile {
            path: "src/a.rb".into(),
            contents: "def run\nend\n".into(),
        }]);
        files.insert("c2".into(), vec![BlobFile {
            path: "src/b.rb".into(),
            contents: "def run\nend\n".into(),
        }]);

        let provider = MemoryProvider { commits, files };
        let storage = Storage::open_memory().unwrap();
        let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
        let stats = engine.run(None).unwrap();

        assert_eq!(stats.moves, 0);
    }

    #[test]
    fn does_not_track_trivial_single_line_moves() {
        let commits = vec![
            CommitMetadata { hash: "c1".into(), message: "init".into(), timestamp: 1 },
            CommitMetadata { hash: "c2".into(), message: "move".into(), timestamp: 2 },
        ];
        let mut files = HashMap::new();
        files.insert("c1".into(), vec![BlobFile {
            path: "src/a.rb".into(),
            contents: "def run\n  run()\nend\n".into(),
        }]);
        files.insert("c2".into(), vec![BlobFile {
            path: "src/b.rb".into(),
            contents: "def run\n  run()\nend\n".into(),
        }]);

        let provider = MemoryProvider { commits, files };
        let storage = Storage::open_memory().unwrap();
        let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
        let stats = engine.run(None).unwrap();

        assert_eq!(stats.moves, 0);
    }

    #[test]
    fn tracks_meaningful_single_line_moves() {
        let commits = vec![
            CommitMetadata { hash: "c1".into(), message: "init".into(), timestamp: 1 },
            CommitMetadata { hash: "c2".into(), message: "move".into(), timestamp: 2 },
        ];
        let mut files = HashMap::new();
        files.insert("c1".into(), vec![BlobFile {
            path: "src/a.rb".into(),
            contents: "def run\n  foo.bar.baz.map { |x| x.to_s }\nend\n".into(),
        }]);
        files.insert("c2".into(), vec![BlobFile {
            path: "src/b.rb".into(),
            contents: "def run\n  foo.bar.baz.map { |x| x.to_s }\nend\n".into(),
        }]);

        let provider = MemoryProvider { commits, files };
        let storage = Storage::open_memory().unwrap();
        let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
        let stats = engine.run(None).unwrap();

        assert_eq!(stats.moves, 1);
    }

    #[test]
    fn tracks_block_moves_even_with_trivial_lines() {
        let commits = vec![
            CommitMetadata { hash: "c1".into(), message: "init".into(), timestamp: 1 },
            CommitMetadata { hash: "c2".into(), message: "move".into(), timestamp: 2 },
        ];
        let mut files = HashMap::new();
        files.insert("c1".into(), vec![BlobFile {
            path: "src/a.rb".into(),
            contents: "def run\n  foo();\n  bar();\n  baz();\nend\n".into(),
        }]);
        files.insert("c2".into(), vec![BlobFile {
            path: "src/b.rb".into(),
            contents: "def run\n  foo();\n  bar();\n  baz();\nend\n".into(),
        }]);

        let provider = MemoryProvider { commits, files };
        let storage = Storage::open_memory().unwrap();
        let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
        let stats = engine.run(None).unwrap();

        assert_eq!(stats.moves, 1);
    }

    #[test]
    fn incremental_indexing_resumes_state() {
        let commits1 = vec![
            CommitMetadata { hash: "c1".into(), message: "init".into(), timestamp: 1 },
        ];
        let mut files1 = HashMap::new();
        files1.insert("c1".into(), vec![BlobFile {
            path: "src/a.rb".into(),
            contents: "def run\n  foo.bar.baz.map { |x| x.to_s }\nend\n".into(),
        }]);

        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("lineage.db");

        // Run 1: process c1
        {
            let provider = MemoryProvider { commits: commits1, files: files1 };
            let storage = Storage::open(&db_path).unwrap();
            let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
            let stats = engine.run(None).unwrap();
            assert_eq!(stats.commits, 1);
            assert_eq!(stats.moves, 0);
        }

        // Run 2: process c1 and c2 (incremental)
        let commits2 = vec![
            CommitMetadata { hash: "c1".into(), message: "init".into(), timestamp: 1 },
            CommitMetadata { hash: "c2".into(), message: "move".into(), timestamp: 2 },
        ];
        let mut files2 = HashMap::new();
        files2.insert("c1".into(), vec![BlobFile {
            path: "src/a.rb".into(),
            contents: "def run\n  foo.bar.baz.map { |x| x.to_s }\nend\n".into(),
        }]);
        files2.insert("c2".into(), vec![BlobFile {
            path: "src/b.rb".into(),
            contents: "def run\n  foo.bar.baz.map { |x| x.to_s }\nend\n".into(),
        }]);

        {
            let provider = MemoryProvider { commits: commits2, files: files2 };
            let storage = Storage::open_existing(&db_path).unwrap();
            let mut engine = LineageEngine::new(provider, crate::extract::HeuristicExtractor::default(), storage);
            let stats = engine.run(None).unwrap();
            // Should skip c1, and only process c2 (1 commit)
            assert_eq!(stats.commits, 1);
            // It should successfully track the move from a.rb to b.rb!
            assert_eq!(stats.moves, 1);
        }
    }
}
