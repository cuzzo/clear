use crate::extract::BoundaryExtractor;
use crate::git::GitProvider;
use crate::model::{BlobFile, LogicalUnit, TestExposureEvent};
use crate::stack_trace::LanguageNormalizer;
use crate::storage::Storage;
use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TestExposureRecord {
    pub path: String,
    pub function: Option<String>,
    pub line: Option<u32>,
    pub branch_id: Option<String>,
    pub test_id: String,
    pub test_type: String,
    pub mutation_status: Option<String>,
    pub mutation_kind: Option<String>,
    pub context_line: Option<String>,
    pub payload_json: String,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct TestExposureIngestStats {
    pub records: usize,
    pub events: usize,
    pub mutation_records: usize,
    pub unverified: usize,
    pub skipped_files: usize,
    pub skipped_records: usize,
}

pub fn ingest_test_exposure_json<E>(
    storage: &Storage,
    normalizer: &dyn LanguageNormalizer,
    git: &GitProvider,
    extractor: &E,
    input: &str,
    commit_hash: &str,
    timestamp: Option<i64>,
) -> Result<TestExposureIngestStats>
where
    E: BoundaryExtractor,
{
    if !storage.commit_exists(commit_hash)? {
        anyhow::bail!("commit {commit_hash} is not present in lineage metadata");
    }

    let value: Value = serde_json::from_str(input).context("parse test exposure JSON")?;
    let records = parse_test_exposure_records(&value)?;
    let timestamp = timestamp
        .or(storage.commit_timestamp(commit_hash)?)
        .unwrap_or_default();
    let mut stats = TestExposureIngestStats {
        records: records.len(),
        ..TestExposureIngestStats::default()
    };
    let mut files = HashMap::<String, Option<BlobFile>>::new();
    let mut units = HashMap::<String, Vec<LogicalUnit>>::new();

    storage.begin_transaction()?;
    let result = (|| -> Result<TestExposureIngestStats> {
        for record in records {
            let path = normalizer.normalize_path(&record.path);
            if !files.contains_key(&path) {
                files.insert(path.clone(), file_at_commit(git, commit_hash, &path)?);
            }
            let Some(file) = files.get(&path).and_then(Option::as_ref) else {
                stats.skipped_files += 1;
                continue;
            };
            if !units.contains_key(&path) {
                units.insert(path.clone(), extractor.extract_units(file));
            }
            let Some(unit) = units
                .get(&path)
                .and_then(|file_units| matching_unit(file_units, &record))
            else {
                stats.skipped_records += 1;
                continue;
            };
            let Some(unit_id) = storage.resolve_unit_id(&unit.id, &path, &unit.name)? else {
                stats.skipped_records += 1;
                continue;
            };
            let verified_line = record.line.unwrap_or(unit.start_line);
            let is_verified =
                verify_context_line(file, verified_line, record.context_line.as_deref());
            if !is_verified {
                stats.unverified += 1;
            }
            let is_mutation_verified =
                is_mutation_verified_status(record.mutation_status.as_deref());
            let is_mutation_killed = is_mutation_killed_status(record.mutation_status.as_deref());
            if is_mutation_verified {
                stats.mutation_records += 1;
            }

            if storage.insert_test_exposure_event(&TestExposureEvent {
                unit_id,
                commit_hash: commit_hash.to_string(),
                timestamp,
                path,
                function: record.function.clone(),
                line: record.line,
                branch_id: record.branch_id.clone(),
                test_id: record.test_id.clone(),
                test_type: normalized_test_type(&record.test_type),
                mutation_status: record.mutation_status.clone(),
                mutation_kind: record.mutation_kind.clone(),
                is_mutation_verified,
                is_mutation_killed,
                is_verified,
                payload_json: record.payload_json.clone(),
            })? {
                stats.events += 1;
            }
        }
        Ok(stats)
    })();

    match result {
        Ok(stats) => {
            storage.commit_transaction()?;
            Ok(stats)
        }
        Err(error) => {
            let _ = storage.rollback_transaction();
            Err(error)
        }
    }
}

pub fn parse_test_exposure_records(value: &Value) -> Result<Vec<TestExposureRecord>> {
    let mut records = Vec::new();
    for entry in value
        .get("hits")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        if let Some(record) = flat_record(entry) {
            records.push(record);
        }
    }
    for file_entry in value
        .get("files")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        collect_file_records(file_entry, &mut records);
    }
    if records.is_empty() {
        anyhow::bail!("test exposure JSON contained no records");
    }
    Ok(records)
}

fn collect_file_records(file_entry: &Value, records: &mut Vec<TestExposureRecord>) {
    let Some(path) = string_at(file_entry, &["file", "path", "filename"]) else {
        return;
    };
    for function in file_entry
        .get("functions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let name = string_at(function, &["name", "function", "method", "defn"])
            .map(str::to_string);
        let line = u32_at(function, &["line", "start_line"]);
        let context_line = string_at(function, &["context_line"]).map(str::to_string);
        for test in function
            .get("tests")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(record) = nested_record(path, name.clone(), line, None, context_line.clone(), test) {
                records.push(record);
            }
        }
    }
    for line_entry in file_entry
        .get("lines")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let line = u32_at(line_entry, &["line"]);
        let context_line = string_at(line_entry, &["context_line"]).map(str::to_string);
        for test in line_entry
            .get("tests")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(record) = nested_record(path, None, line, None, context_line.clone(), test) {
                records.push(record);
            }
        }
    }
    for branch_entry in file_entry
        .get("branches")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let branch_id = string_at(branch_entry, &["branch_id", "id"]).map(str::to_string);
        let line = u32_at(branch_entry, &["line"]);
        let context_line = string_at(branch_entry, &["context_line"]).map(str::to_string);
        for test in branch_entry
            .get("tests")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(record) =
                nested_record(path, None, line, branch_id.clone(), context_line.clone(), test)
            {
                records.push(record);
            }
        }
    }
}

fn flat_record(entry: &Value) -> Option<TestExposureRecord> {
    let path = string_at(entry, &["file", "path", "filename"])?.to_string();
    let test_id = string_at(entry, &["test_id", "id"])?.to_string();
    if test_id.is_empty() {
        return None;
    }
    let test_type = string_at(entry, &["test_type", "type"])
        .unwrap_or("unknown")
        .to_string();
    let mutation_status = optional_string_at(entry, &["mutation_status", "mutant_status", "mutation"]);
    let mutation_kind = normalized_mutation_kind(
        optional_string_at(
            entry,
            &["mutation_kind", "mutation_type", "mutant_kind", "mutant_type"],
        )
        .as_deref(),
        mutation_status.as_deref(),
        &test_type,
        &test_id,
    );
    Some(TestExposureRecord {
        path,
        function: optional_string_at(entry, &["function", "method", "defn"]),
        line: u32_at(entry, &["line"]),
        branch_id: optional_string_at(entry, &["branch_id"]),
        test_id,
        test_type,
        mutation_status,
        mutation_kind,
        context_line: optional_string_at(entry, &["context_line"]),
        payload_json: serde_json::to_string(entry).unwrap_or_else(|_| "{}".to_string()),
    })
}

fn nested_record(
    path: &str,
    function: Option<String>,
    line: Option<u32>,
    branch_id: Option<String>,
    context_line: Option<String>,
    test: &Value,
) -> Option<TestExposureRecord> {
    let test_id = string_at(test, &["test_id", "id"])?.to_string();
    if test_id.is_empty() {
        return None;
    }
    let mutation_status = optional_string_at(test, &["mutation_status", "mutant_status", "mutation"]);
    let test_type = string_at(test, &["test_type", "type"])
        .unwrap_or("unknown")
        .to_string();
    let mutation_kind = normalized_mutation_kind(
        optional_string_at(
            test,
            &["mutation_kind", "mutation_type", "mutant_kind", "mutant_type"],
        )
        .as_deref(),
        mutation_status.as_deref(),
        &test_type,
        &test_id,
    );
    let payload = json!({
        "file": path,
        "function": function.clone(),
        "line": line,
        "branch_id": branch_id.clone(),
        "test": test,
    });
    Some(TestExposureRecord {
        path: path.to_string(),
        function,
        line,
        branch_id,
        test_id,
        test_type,
        mutation_status,
        mutation_kind,
        context_line,
        payload_json: serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string()),
    })
}

fn matching_unit<'a>(
    units: &'a [LogicalUnit],
    record: &TestExposureRecord,
) -> Option<&'a LogicalUnit> {
    if let Some(line) = record.line {
        if let Some(unit) = units
            .iter()
            .find(|unit| unit.start_line <= line && line <= unit.end_line)
        {
            return Some(unit);
        }
    }
    record.function.as_ref().and_then(|function| {
        units
            .iter()
            .find(|unit| function_aliases(function).iter().any(|name| name == &unit.name))
    })
}

fn function_aliases(function: &str) -> Vec<String> {
    let mut aliases = vec![function.to_string()];
    for separator in ["#", ".", "::"] {
        if function.contains(separator) {
            if let Some(name) = function.rsplit(separator).next() {
                aliases.push(name.to_string());
            }
        }
    }
    aliases.sort();
    aliases.dedup();
    aliases
}

fn file_at_commit(git: &GitProvider, commit_hash: &str, path: &str) -> Result<Option<BlobFile>> {
    if let Some(contents) = git.file_contents_at_commit(commit_hash, path)? {
        Ok(Some(BlobFile {
            path: path.to_string(),
            contents,
        }))
    } else {
        Ok(None)
    }
}

fn verify_context_line(file: &BlobFile, line: u32, context_line: Option<&str>) -> bool {
    let Some(context) = context_line else {
        return true;
    };
    let Some(actual) = file.contents.lines().nth(line.saturating_sub(1) as usize) else {
        return false;
    };
    actual.trim() == context.trim()
}

fn is_mutation_verified_status(status: Option<&str>) -> bool {
    let normalized = status.unwrap_or_default().trim().to_ascii_lowercase();
    !normalized.is_empty()
        && !matches!(
            normalized.as_str(),
            "none" | "no" | "false" | "unverified" | "unknown"
        )
}

fn is_mutation_killed_status(status: Option<&str>) -> bool {
    matches!(
        status.unwrap_or_default().trim().to_ascii_lowercase().as_str(),
        "killed" | "kill" | "pass" | "passed" | "hard" | "hard-gated"
    )
}

fn normalized_mutation_kind(
    kind: Option<&str>,
    status: Option<&str>,
    test_type: &str,
    test_id: &str,
) -> Option<String> {
    let explicit = kind.unwrap_or_default().trim().to_ascii_lowercase();
    if !explicit.is_empty() && !matches!(explicit.as_str(), "none" | "unknown" | "false") {
        return Some(match explicit.as_str() {
            "contract" | "contracts" | "invariant" | "invariants" | "property" | "properties"
            | "property-based" | "fuzz" | "fuzzer" | "fuzzing" => "invariant".to_string(),
            "stochastic" | "random" | "mutation" | "mutant" | "ruby-mutant" | "ruby_mutant"
            | "cargo-mutant" | "cargo-mutants" | "cargo_mutant" | "cargo_mutants" => {
                "stochastic".to_string()
            }
            other => other.to_string(),
        });
    }

    if !is_mutation_verified_status(status) {
        return None;
    }

    let inferred_from = format!(
        "{} {}",
        test_type.to_ascii_lowercase(),
        test_id.to_ascii_lowercase()
    );
    if inferred_from.contains("invariant")
        || inferred_from.contains("contract")
        || inferred_from.contains("property")
        || inferred_from.contains("fuzz")
    {
        Some("invariant".to_string())
    } else {
        Some("stochastic".to_string())
    }
}

fn normalized_test_type(test_type: &str) -> String {
    let normalized = test_type.trim();
    if normalized.is_empty() {
        "unknown".to_string()
    } else {
        normalized.to_string()
    }
}

fn string_at<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| value.get(*key).and_then(Value::as_str))
}

fn optional_string_at(value: &Value, keys: &[&str]) -> Option<String> {
    string_at(value, keys)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn u32_at(value: &Value, keys: &[&str]) -> Option<u32> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_u64))
        .and_then(|value| u32::try_from(value).ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_flat_and_nested_test_exposure_records() {
        let value = json!({
          "schema": "test-exposure/v1",
          "hits": [{
            "file": "src/demo.rb",
            "function": "Worker#call",
            "line": 10,
            "branch_id": "b1",
            "test_id": "spec/demo_spec.rb:1",
            "test_type": "unit",
            "mutation_status": "killed",
            "mutation_kind": "ruby-mutant"
          }],
          "files": [{
            "file": "src/demo.rb",
            "lines": [{
              "line": 11,
              "tests": [{ "id": "spec/integration_spec.rb:2", "type": "integration" }]
            }],
            "branches": [{
              "id": "b2",
              "line": 12,
              "tests": [{ "id": "spec/demo_spec.rb:3", "type": "unit", "mutation": "survived" }]
            }]
          }]
        });

        let records = parse_test_exposure_records(&value).unwrap();

        assert_eq!(records.len(), 3);
        assert_eq!(records[0].function.as_deref(), Some("Worker#call"));
        assert_eq!(records[0].branch_id.as_deref(), Some("b1"));
        assert!(is_mutation_killed_status(records[0].mutation_status.as_deref()));
        assert_eq!(records[0].mutation_kind.as_deref(), Some("stochastic"));
        assert_eq!(records[1].test_type, "integration");
        assert_eq!(records[2].mutation_status.as_deref(), Some("survived"));
        assert_eq!(records[2].mutation_kind.as_deref(), Some("stochastic"));
    }

    #[test]
    fn function_aliases_match_common_qualified_names() {
        assert!(function_aliases("Worker#call").contains(&"call".to_string()));
        assert!(function_aliases("Type::with").contains(&"with".to_string()));
        assert!(function_aliases("mod.fn").contains(&"fn".to_string()));
    }

    use tempfile::tempdir;
    use crate::storage::Storage;
    use crate::git::GitProvider;
    use crate::extract::HeuristicExtractor;
    use crate::stack_trace::RepoPathNormalizer;
    use std::fs;
    use std::path::Path;

    fn create_commit(
        repo: &git2::Repository,
        message: &str,
        files: &[(&str, &str)],
    ) -> Result<String, git2::Error> {
        let mut index = repo.index()?;
        let workdir = repo.workdir().ok_or_else(|| git2::Error::from_str("no workdir"))?;
        for (path, content) in files {
            let file_path = workdir.join(path);
            if let Some(parent_dir) = file_path.parent() {
                fs::create_dir_all(parent_dir).unwrap();
            }
            fs::write(&file_path, content).unwrap();
            index.add_path(Path::new(path))?;
        }
        index.write()?;
        let tree_oid = index.write_tree()?;
        let tree = repo.find_tree(tree_oid)?;
        
        let signature = git2::Signature::now("Test User", "test@example.com")?;
        
        let parent = match repo.head() {
            Ok(head_ref) => {
                let target = head_ref.target().unwrap();
                Some(repo.find_commit(target)?)
            }
            Err(_) => None,
        };
        
        let mut parents = Vec::new();
        if let Some(ref p) = parent {
            parents.push(p);
        }
        
        let oid = repo.commit(
            Some("HEAD"),
            &signature,
            &signature,
            message,
            &tree,
            &parents,
        )?;
        Ok(oid.to_string())
    }

    #[test]
    fn test_ingest_test_exposure_json_flow() {
        let dir = tempdir().unwrap();
        let repo = git2::Repository::init(dir.path()).unwrap();
        
        // Write file and commit
        let content = "def foo\n  puts 'hello'\nend\n";
        let c1 = create_commit(&repo, "init", &[("src/foo.rb", content)]).unwrap();
        
        let storage = Storage::open_memory().unwrap();
        
        let provider = GitProvider::open(dir.path()).unwrap();
        let normalizer = RepoPathNormalizer::new(dir.path());
        let extractor = HeuristicExtractor::default();
        
        let input_json = json!({
            "hits": [{
                "file": "src/foo.rb",
                "function": "foo",
                "test_id": "some_test",
                "test_type": "unit",
            }]
        });
        
        let err = ingest_test_exposure_json(
            &storage,
            &normalizer,
            &provider,
            &extractor,
            &input_json.to_string(),
            &c1,
            None,
        );
        assert!(err.is_err());
        
        storage.insert_metadata(&crate::model::CommitMetadata {
            hash: c1.clone(),
            message: "init".to_string(),
            timestamp: 123456,
        }).unwrap();
        
        let units = extractor.extract_units(&crate::model::BlobFile {
            path: "src/foo.rb".to_string(),
            contents: content.to_string(),
        });
        for unit in &units {
            storage.upsert_logical_unit(unit, 123456).unwrap();
        }
        
        let stats = ingest_test_exposure_json(
            &storage,
            &normalizer,
            &provider,
            &extractor,
            &input_json.to_string(),
            &c1,
            None,
        ).unwrap();
        
        assert_eq!(stats.records, 1);
        assert_eq!(stats.events, 1);
        
        let err_json = ingest_test_exposure_json(
            &storage,
            &normalizer,
            &provider,
            &extractor,
            "invalid json",
            &c1,
            None,
        );
        assert!(err_json.is_err());

        let empty_json = json!({ "hits": [] });
        let err_empty = ingest_test_exposure_json(
            &storage,
            &normalizer,
            &provider,
            &extractor,
            &empty_json.to_string(),
            &c1,
            None,
        );
        assert!(err_empty.is_err());
    }

    #[test]
    fn test_ingest_test_exposure_nested_flow() {
        let dir = tempdir().unwrap();
        let repo = git2::Repository::init(dir.path()).unwrap();
        
        let content = "def foo\n  puts 'hello'\nend\n";
        let c1 = create_commit(&repo, "init", &[("src/foo.rb", content)]).unwrap();
        
        let storage = Storage::open_memory().unwrap();
        storage.insert_metadata(&crate::model::CommitMetadata {
            hash: c1.clone(),
            message: "init".to_string(),
            timestamp: 123456,
        }).unwrap();
        
        let provider = GitProvider::open(dir.path()).unwrap();
        let normalizer = RepoPathNormalizer::new(dir.path());
        let extractor = HeuristicExtractor::default();
        
        let units = extractor.extract_units(&crate::model::BlobFile {
            path: "src/foo.rb".to_string(),
            contents: content.to_string(),
        });
        for unit in &units {
            storage.upsert_logical_unit(unit, 123456).unwrap();
        }

        // Nested file format JSON with context line matching & mismatching
        let nested_json = json!({
            "files": [{
                "file": "src/foo.rb",
                "functions": [{
                    "name": "foo",
                    "line": 1,
                    "context_line": "def foo",
                    "tests": [{
                        "id": "my_test_fuzz",
                        "type": "property-based",
                        "mutation_status": "killed",
                        "mutation_kind": "fuzz"
                    }, {
                        "id": "my_test_random",
                        "type": "unit",
                        "mutation_status": "survived",
                        "mutation_kind": "random"
                    }]
                }],
                "lines": [{
                    "line": 2,
                    "context_line": "  puts 'hello'",
                    "tests": [{
                        "id": "my_line_test",
                        "type": "integration",
                    }]
                }, {
                    "line": 2,
                    "context_line": "wrong context line",
                    "tests": [{
                        "id": "my_mismatch_test",
                        "type": "integration",
                    }]
                }],
                "branches": [{
                    "branch_id": "b1",
                    "line": 2,
                    "tests": [{
                        "id": "my_branch_test",
                        "type": "integration",
                    }]
                }]
            }]
        });

        let stats = ingest_test_exposure_json(
            &storage,
            &normalizer,
            &provider,
            &extractor,
            &nested_json.to_string(),
            &c1,
            None,
        ).unwrap();

        assert_eq!(stats.records, 5);
        assert_eq!(stats.events, 5);
        assert_eq!(stats.mutation_records, 2);
        assert_eq!(stats.unverified, 1); // 1 mismatched context line
    }
}
