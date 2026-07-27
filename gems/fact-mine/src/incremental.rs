//! Content-addressed, file-local FactMine cache.
//!
//! The cache deliberately stores [`LocalFactShard`] values only. Every run
//! rebuilds the project result through `ProjectFactFinalizer`, so a declaration
//! change can never leave a stale target or candidate set in an unchanged
//! caller.

use crate::parallel;
use crate::profile::{
    self, ArtifactScope, IncrementalMetrics, LocalFactShard, Profile, ProfileOutput,
    ProjectFactFinalizer,
};
use crate::syntax::{self, Language};
use anyhow::{Context, Result};
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::Instant;

const CACHE_SCHEMA_VERSION: u32 = 1;
const FACT_SCHEMA_VERSION: &str = "fact-mine-local-facts-v1";
const EXTRACTOR_VERSION: &str = "normalized-extractor-v1";
const NORMALIZED_IR_VERSION: &str = "normalized-ir-v1";
const GRAMMAR_ADAPTER_VERSION: &str = "tree-sitter-adapters-v1";

/// Settings for the standalone cache at `.lineage/cache/fact-mine/`.
#[derive(Clone, Debug)]
pub struct CacheConfig {
    pub root: PathBuf,
    pub directory: PathBuf,
}

impl CacheConfig {
    pub fn new(root: PathBuf, directory: PathBuf) -> Self {
        Self { root, directory }
    }
}

/// Complete output and measurements from a cache-aware run.
#[derive(Clone, Debug)]
pub struct IncrementalRun {
    pub output: ProfileOutput,
    pub metrics: IncrementalMetrics,
}

/// Locates a ready-to-serve compact JSON artifact for an exact project input.
/// This deliberately performs only source/configuration hashing; it never
/// opens, decompresses, or deserializes the typed project snapshot.
pub fn served_artifact_path(
    files: &[PathBuf],
    language_override: Option<Language>,
    profile: Profile,
    config: &CacheConfig,
) -> Result<Option<PathBuf>> {
    let registry_digest = stdlib_registry_digest()?;
    let configuration_digest = configuration_digest()?;
    let candidates = files
        .iter()
        .map(|path| {
            candidate(
                path,
                language_override,
                profile,
                &config.root,
                &registry_digest,
                &configuration_digest,
            )
        })
        .collect::<Result<Vec<_>>>()?;
    let path = ShardCache::new(config.directory.clone())
        .served_artifact_path(&project_cache_key(profile, &candidates)?);
    Ok(path.exists().then_some(path))
}

pub fn served_artifact_destination(
    files: &[PathBuf],
    language_override: Option<Language>,
    profile: Profile,
    config: &CacheConfig,
) -> Result<PathBuf> {
    let registry_digest = stdlib_registry_digest()?;
    let configuration_digest = configuration_digest()?;
    let candidates = files
        .iter()
        .map(|path| {
            candidate(
                path,
                language_override,
                profile,
                &config.root,
                &registry_digest,
                &configuration_digest,
            )
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(ShardCache::new(config.directory.clone())
        .served_artifact_path(&project_cache_key(profile, &candidates)?))
}

#[derive(Clone, Debug, Serialize)]
struct CacheIdentity<'a> {
    source_digest: &'a str,
    path: &'a str,
    language: &'a str,
    profile: &'a str,
    fact_schema: &'static str,
    extractor_version: &'static str,
    normalized_ir_version: &'static str,
    grammar_adapter_version: &'static str,
    stdlib_registry_digest: &'a str,
    configuration_digest: &'a str,
}

#[derive(Clone, Debug)]
struct Candidate {
    path: PathBuf,
    language: Language,
    profile: &'static str,
    path_identity: String,
    source_digest: String,
    cache_key: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct CachedShard {
    schema_version: u32,
    cache_key: String,
    source_digest: String,
    path: String,
    language: String,
    profile: String,
    shard: LocalFactShard,
}

#[derive(Debug, Serialize, Deserialize)]
struct CachedProject {
    schema_version: u32,
    project_key: String,
    output: ProfileOutput,
}

impl CachedShard {
    fn matches_candidate(&self, candidate: &Candidate) -> bool {
        self.schema_version == CACHE_SCHEMA_VERSION
            && self.cache_key == candidate.cache_key
            && self.source_digest == candidate.source_digest
            && self.path == candidate.path_identity
            && self.language == candidate.language.as_str()
            && self.profile == candidate.profile
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct RevisionManifest {
    schema_version: u32,
    revision: String,
    files: BTreeMap<String, String>,
}

enum CacheRead {
    Hit(Box<LocalFactShard>, u64),
    Miss,
    Corrupt(String),
}

enum ProjectCacheRead {
    Hit(Box<ProfileOutput>, u64),
    Miss,
    Corrupt(String),
}

enum ShardSource {
    Hit {
        bytes: u64,
    },
    Miss {
        bytes_written: u64,
    },
    CorruptMiss {
        diagnostic: String,
        bytes_written: u64,
    },
}

struct ShardResult {
    shard: LocalFactShard,
    source: ShardSource,
    recovery: Option<profile::ParseRecovery>,
    cache_load_millis: u128,
    local_extraction_millis: u128,
    cache_write_millis: u128,
}

/// Builds a project profile while reusing valid file-local cache entries.
///
/// With `partial` enabled, `files` are deliberately treated as a changed-file
/// preview and the result is labelled incomplete. A partial preview never
/// rewrites the complete-corpus manifest.
pub fn build_profile(
    files: &[PathBuf],
    language_override: Option<Language>,
    profile: Profile,
    config: &CacheConfig,
    partial: bool,
) -> Result<IncrementalRun> {
    let hashing_started = Instant::now();
    let registry_digest = stdlib_registry_digest()?;
    let configuration_digest = configuration_digest()?;
    let candidates = files
        .iter()
        .map(|path| {
            candidate(
                path,
                language_override,
                profile,
                &config.root,
                &registry_digest,
                &configuration_digest,
            )
        })
        .collect::<Result<Vec<_>>>()?;
    let hashing_millis = hashing_started.elapsed().as_millis();

    let cache = ShardCache::new(config.directory.clone());
    let project_key = project_cache_key(profile, &candidates)?;
    if !partial {
        match cache.load_project(&project_key)? {
            ProjectCacheRead::Hit(output, bytes) => {
                let mut output = *output;
                let metrics = IncrementalMetrics {
                    files_considered: files.len(),
                    hashing_millis,
                    project_snapshot_hits: 1,
                    project_snapshot_bytes_loaded: bytes,
                    peak_resident_bytes: peak_resident_bytes(),
                    ..IncrementalMetrics::default()
                };
                output.artifact_scope = Some(ArtifactScope {
                    kind: "complete".to_string(),
                    complete: true,
                    selected_files: files.len(),
                });
                output.incremental_metrics = Some(metrics.clone());
                return Ok(IncrementalRun { output, metrics });
            }
            ProjectCacheRead::Miss => {}
            ProjectCacheRead::Corrupt(diagnostic) => {
                std::eprintln!("FactMine incremental project cache miss: {diagnostic}");
            }
        }
    }
    let shard_results = parallel::map_ordered(&candidates, |candidate| {
        let cache_load_started = Instant::now();
        let read = cache.load(candidate)?;
        let cache_load_millis = cache_load_started.elapsed().as_millis();
        let corrupt_diagnostic = match read {
            CacheRead::Hit(shard, bytes) => {
                return Ok(ShardResult {
                    shard: *shard,
                    source: ShardSource::Hit { bytes },
                    recovery: None,
                    cache_load_millis,
                    local_extraction_millis: 0,
                    cache_write_millis: 0,
                });
            }
            CacheRead::Miss => None,
            CacheRead::Corrupt(diagnostic) => Some(diagnostic),
        };

        let extraction_started = Instant::now();
        let document = syntax::parse_file(candidate.path.clone(), candidate.language)?;
        let recovery = document.parse_recovered.then(|| profile::ParseRecovery {
            path: candidate.path.to_string_lossy().to_string(),
            spans: document.parse_recovery_spans.clone(),
        });
        let shard = profile::extract_local(&document, profile);
        let local_extraction_millis = extraction_started.elapsed().as_millis();
        let cache_write_started = Instant::now();
        let bytes_written = cache.store(candidate, &shard)?;
        let cache_write_millis = cache_write_started.elapsed().as_millis();
        let source = match corrupt_diagnostic {
            Some(diagnostic) => ShardSource::CorruptMiss {
                diagnostic,
                bytes_written,
            },
            None => ShardSource::Miss { bytes_written },
        };
        Ok(ShardResult {
            shard,
            source,
            recovery,
            cache_load_millis,
            local_extraction_millis,
            cache_write_millis,
        })
    })?;

    let mut metrics = IncrementalMetrics {
        files_considered: files.len(),
        hashing_millis,
        project_snapshot_misses: usize::from(!partial),
        ..IncrementalMetrics::default()
    };
    let mut recoveries = Vec::new();
    let mut shards = Vec::with_capacity(shard_results.len());
    for result in shard_results {
        metrics.cache_load_millis += result.cache_load_millis;
        metrics.local_extraction_millis += result.local_extraction_millis;
        metrics.cache_write_millis += result.cache_write_millis;
        if let Some(recovery) = result.recovery {
            recoveries.push(recovery);
        }
        match result.source {
            ShardSource::Hit { bytes } => {
                metrics.shard_hits += 1;
                metrics.bytes_loaded += bytes;
            }
            ShardSource::Miss { bytes_written } => {
                metrics.shard_misses += 1;
                metrics.bytes_written += bytes_written;
            }
            ShardSource::CorruptMiss {
                diagnostic,
                bytes_written,
            } => {
                metrics.shard_misses += 1;
                metrics.corrupt_entries += 1;
                metrics.bytes_written += bytes_written;
                std::eprintln!("FactMine incremental cache miss: {diagnostic}");
            }
        }
        shards.push(result.shard);
    }

    if !partial {
        let manifest_write_started = Instant::now();
        metrics.invalidated_files = cache.update_manifest(&candidates)?;
        metrics.cache_write_millis += manifest_write_started.elapsed().as_millis();
    }

    let finalization_started = Instant::now();
    let mut output = ProjectFactFinalizer::new(profile).finalize(shards);
    metrics.project_finalization_millis = finalization_started.elapsed().as_millis();
    output.input_coverage = profile::InputCoverage {
        selected_files: files.len(),
        parsed_files: files.len(),
        parse_recovery_files: recoveries
            .iter()
            .map(|recovery| recovery.path.clone())
            .collect(),
        parse_recoveries: recoveries,
    };
    output.artifact_scope = Some(ArtifactScope {
        kind: if partial {
            "changed_file_preview".to_string()
        } else {
            "complete".to_string()
        },
        complete: !partial,
        selected_files: files.len(),
    });
    if !partial {
        let project_write_started = Instant::now();
        let mut cacheable = output.clone();
        cacheable.artifact_scope = None;
        cacheable.incremental_metrics = None;
        metrics.project_snapshot_bytes_written = cache.store_project(&project_key, &cacheable)?;
        metrics.cache_write_millis += project_write_started.elapsed().as_millis();
    }
    metrics.peak_resident_bytes = peak_resident_bytes();
    output.incremental_metrics = Some(metrics.clone());

    Ok(IncrementalRun { output, metrics })
}

fn peak_resident_bytes() -> Option<u64> {
    let status = fs::read_to_string("/proc/self/status").ok()?;
    status.lines().find_map(|line| {
        let value = line.strip_prefix("VmHWM:")?.split_whitespace().next()?;
        value.parse::<u64>().ok().map(|kibibytes| kibibytes * 1024)
    })
}

fn candidate(
    path: &Path,
    language_override: Option<Language>,
    profile: Profile,
    root: &Path,
    registry_digest: &str,
    configuration_digest: &str,
) -> Result<Candidate> {
    let original_path = path.to_path_buf();
    let absolute_path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        root.join(path)
    };
    let language = language_override
        .or_else(|| Language::for_path(&absolute_path))
        .with_context(|| format!("cannot detect language for {}", absolute_path.display()))?;
    let source = fs::read(&absolute_path)
        .with_context(|| format!("failed to read {}", absolute_path.display()))?;
    let source_digest = format!("sha256:{:x}", Sha256::digest(source));
    let path_identity = absolute_path
        .strip_prefix(root)
        .unwrap_or(&absolute_path)
        .to_string_lossy()
        .replace('\\', "/");
    let profile_name = profile_name(profile);
    let identity = CacheIdentity {
        source_digest: &source_digest,
        path: &path_identity,
        language: language.as_str(),
        profile: profile_name,
        fact_schema: FACT_SCHEMA_VERSION,
        extractor_version: EXTRACTOR_VERSION,
        normalized_ir_version: NORMALIZED_IR_VERSION,
        grammar_adapter_version: GRAMMAR_ADAPTER_VERSION,
        stdlib_registry_digest: registry_digest,
        configuration_digest,
    };
    let cache_key = digest_json(&identity)?;
    Ok(Candidate {
        path: original_path,
        language,
        profile: profile_name,
        path_identity,
        source_digest,
        cache_key,
    })
}

fn profile_name(profile: Profile) -> &'static str {
    match profile {
        Profile::Espalier => "espalier",
        Profile::NilKill => "nil-kill",
        Profile::TracePlan => "trace-plan",
    }
}

fn project_cache_key(profile: Profile, candidates: &[Candidate]) -> Result<String> {
    digest_json(&serde_json::json!({
        "schema": "fact-mine-project-v1",
        "profile": profile_name(profile),
        "files": candidates.iter().map(|candidate| serde_json::json!({
            "path": candidate.path_identity,
            "shard": candidate.cache_key,
        })).collect::<Vec<_>>(),
    }))
}

fn configuration_digest() -> Result<String> {
    let global_shapes = std::env::var_os("FACT_MINE_GLOBAL_SHAPES_FILE")
        .map(PathBuf::from)
        .map(|path| {
            let contents = fs::read(&path).with_context(|| {
                format!("failed to read configured global shapes {}", path.display())
            })?;
            Ok::<_, anyhow::Error>((path.to_string_lossy().to_string(), digest_bytes(&contents)))
        })
        .transpose()?;
    digest_json(&serde_json::json!({
        "FACT_MINE_NORETURN_METHODS": std::env::var("FACT_MINE_NORETURN_METHODS").ok(),
        "FACT_MINE_GLOBAL_SHAPES_FILE": global_shapes,
        "DECOMPLEX_RUST_PROFILE": std::env::var("DECOMPLEX_RUST_PROFILE").ok(),
    }))
}

fn stdlib_registry_digest() -> Result<String> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("config");
    let mut files = Vec::new();
    collect_files(&root.join("stdlib_complexity"), &mut files)?;
    collect_files(&root.join("complexity_summaries"), &mut files)?;
    files.sort();
    let mut hasher = Sha256::new();
    for file in files {
        hasher.update(
            file.strip_prefix(&root)
                .unwrap_or(&file)
                .to_string_lossy()
                .as_bytes(),
        );
        hasher.update([0]);
        hasher.update(fs::read(&file)?);
        hasher.update([0]);
    }
    Ok(format!("sha256:{:x}", hasher.finalize()))
}

fn collect_files(root: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(root).with_context(|| format!("failed to read {}", root.display()))? {
        let path = entry?.path();
        if path.is_dir() {
            collect_files(&path, files)?;
        } else {
            files.push(path);
        }
    }
    Ok(())
}

fn digest_json(value: &impl Serialize) -> Result<String> {
    Ok(digest_bytes(&serde_json::to_vec(value)?))
}

fn digest_bytes(bytes: &[u8]) -> String {
    format!("sha256:{:x}", Sha256::digest(bytes))
}

struct ShardCache {
    directory: PathBuf,
}

impl ShardCache {
    fn new(directory: PathBuf) -> Self {
        Self { directory }
    }

    fn shard_path(&self, cache_key: &str) -> PathBuf {
        self.directory
            .join("shards")
            .join(format!("{cache_key}.json.gz"))
    }

    fn manifest_path(&self) -> PathBuf {
        self.directory.join("revision-manifest-v1.json")
    }

    fn project_path(&self, project_key: &str) -> PathBuf {
        self.directory
            .join("projects")
            .join(format!("{project_key}.json.gz"))
    }

    fn served_artifact_path(&self, project_key: &str) -> PathBuf {
        self.directory
            .join("artifacts")
            .join(format!("{project_key}.json"))
    }

    fn load(&self, candidate: &Candidate) -> Result<CacheRead> {
        let path = self.shard_path(&candidate.cache_key);
        let Some(bytes) = read_optional(&path)? else {
            return Ok(CacheRead::Miss);
        };
        let mut decoder = GzDecoder::new(bytes.as_slice());
        let mut json = Vec::new();
        if let Err(error) = decoder.read_to_end(&mut json) {
            return Ok(CacheRead::Corrupt(format!(
                "{} is not valid gzip: {error}",
                path.display()
            )));
        }
        let cached: CachedShard = match serde_json::from_slice(&json) {
            Ok(cached) => cached,
            Err(error) => {
                return Ok(CacheRead::Corrupt(format!(
                    "{} is not a valid shard: {error}",
                    path.display()
                )))
            }
        };
        if !cached.matches_candidate(candidate) {
            return Ok(CacheRead::Corrupt(format!(
                "{} has an incompatible shard identity",
                path.display()
            )));
        }
        Ok(CacheRead::Hit(Box::new(cached.shard), bytes.len() as u64))
    }

    fn store(&self, candidate: &Candidate, shard: &LocalFactShard) -> Result<u64> {
        let cached = CachedShard {
            schema_version: CACHE_SCHEMA_VERSION,
            cache_key: candidate.cache_key.clone(),
            source_digest: candidate.source_digest.clone(),
            path: candidate.path_identity.clone(),
            language: candidate.language.as_str().to_string(),
            profile: candidate.profile.to_string(),
            shard: shard.clone(),
        };
        let json = serde_json::to_vec(&cached)?;
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(&json)?;
        let compressed = encoder.finish()?;
        self.write_atomic(&self.shard_path(&candidate.cache_key), &compressed)?;
        Ok(compressed.len() as u64)
    }

    fn load_project(&self, project_key: &str) -> Result<ProjectCacheRead> {
        let path = self.project_path(project_key);
        let Some(bytes) = read_optional(&path)? else {
            return Ok(ProjectCacheRead::Miss);
        };
        let mut decoder = GzDecoder::new(bytes.as_slice());
        let mut json = Vec::new();
        if let Err(error) = decoder.read_to_end(&mut json) {
            return Ok(ProjectCacheRead::Corrupt(format!(
                "{} is not valid gzip: {error}",
                path.display()
            )));
        }
        let cached: CachedProject = match serde_json::from_slice(&json) {
            Ok(cached) => cached,
            Err(error) => {
                return Ok(ProjectCacheRead::Corrupt(format!(
                    "{} is not a valid project snapshot: {error}",
                    path.display()
                )))
            }
        };
        if cached.schema_version != CACHE_SCHEMA_VERSION || cached.project_key != project_key {
            return Ok(ProjectCacheRead::Corrupt(format!(
                "{} has an incompatible project snapshot identity",
                path.display()
            )));
        }
        Ok(ProjectCacheRead::Hit(
            Box::new(cached.output),
            bytes.len() as u64,
        ))
    }

    fn store_project(&self, project_key: &str, output: &ProfileOutput) -> Result<u64> {
        let cached = CachedProject {
            schema_version: CACHE_SCHEMA_VERSION,
            project_key: project_key.to_string(),
            output: output.clone(),
        };
        let json = serde_json::to_vec(&cached)?;
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(&json)?;
        let compressed = encoder.finish()?;
        self.write_atomic(&self.project_path(project_key), &compressed)?;
        Ok(compressed.len() as u64)
    }

    fn update_manifest(&self, candidates: &[Candidate]) -> Result<usize> {
        let prior = self.load_manifest()?;
        let files = candidates
            .iter()
            .map(|candidate| (candidate.path_identity.clone(), candidate.cache_key.clone()))
            .collect::<BTreeMap<_, _>>();
        let invalidated = prior
            .files
            .iter()
            .filter(|(path, key)| files.get(*path) != Some(*key))
            .count()
            + files
                .iter()
                .filter(|(path, key)| prior.files.get(*path) != Some(*key))
                .count();
        let manifest = RevisionManifest {
            schema_version: CACHE_SCHEMA_VERSION,
            revision: digest_json(&files)?,
            files,
        };
        self.write_atomic(
            &self.manifest_path(),
            &serde_json::to_vec_pretty(&manifest)?,
        )?;
        Ok(invalidated)
    }

    fn load_manifest(&self) -> Result<RevisionManifest> {
        let path = self.manifest_path();
        let Some(bytes) = read_optional(&path)? else {
            return Ok(RevisionManifest::default());
        };
        match serde_json::from_slice(&bytes) {
            Ok(manifest) => Ok(manifest),
            Err(error) => {
                std::eprintln!(
                    "FactMine incremental cache manifest ignored: {}: {error}",
                    path.display()
                );
                Ok(RevisionManifest::default())
            }
        }
    }

    fn write_atomic(&self, path: &Path, bytes: &[u8]) -> Result<()> {
        let parent = path.parent().expect("cache path has parent");
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
        let temporary = parent.join(format!(
            ".{}.{}.tmp",
            path.file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("cache"),
            unique_suffix(),
        ));
        fs::write(&temporary, bytes)
            .with_context(|| format!("failed to write {}", temporary.display()))?;
        fs::rename(&temporary, path)
            .with_context(|| format!("failed to replace {}", path.display()))
    }
}

fn read_optional(path: &Path) -> Result<Option<Vec<u8>>> {
    match fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("failed to read {}", path.display())),
    }
}

fn unique_suffix() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    format!(
        "{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    )
}

#[cfg(test)]
#[path = "incremental_tests.rs"]
mod tests;
