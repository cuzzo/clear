//! Typed configuration and manifest contracts for the Lineage evidence pipeline.

use anyhow::{bail, Context, Result};
use flate2::Compression;
use flate2::{read::GzDecoder, write::GzEncoder};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const CONFIG_FILE_NAME: &str = "lineage.yml";
pub const CONFIG_JSON_FILE_NAME: &str = "lineage.json";
pub const RUN_MANIFEST_VERSION: &str = "lineage-run/v1";
const MAX_DECOMPRESSED_ARTIFACT_BYTES: u64 = 128 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LineageConfig {
    pub version: u32,
    #[serde(default)]
    pub artifacts: ArtifactStoreConfig,
    #[serde(default)]
    pub profiles: BTreeMap<String, VerificationProfile>,
    #[serde(default)]
    pub producers: BTreeMap<String, EvidenceProducer>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ArtifactStoreConfig {
    #[serde(default = "default_artifact_directory")]
    pub directory: PathBuf,
    #[serde(default = "default_compression")]
    pub compression: ArtifactCompression,
}

impl Default for ArtifactStoreConfig {
    fn default() -> Self {
        Self {
            directory: default_artifact_directory(),
            compression: default_compression(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactCompression {
    Gzip,
    None,
}

impl Default for ArtifactCompression {
    fn default() -> Self {
        Self::None
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VerificationProfile {
    pub producers: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EvidenceProducer {
    pub executor: ProducerExecutor,
    #[serde(default)]
    pub argv: Vec<String>,
    #[serde(default)]
    pub working_directory: Option<PathBuf>,
    #[serde(default = "default_command_timeout_seconds")]
    pub timeout_seconds: u64,
    #[serde(default = "default_command_output_bytes")]
    pub max_output_bytes: usize,
    /// Extra environment entries. Commands otherwise receive only a small,
    /// explicitly inherited execution allowlist.
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    #[serde(default)]
    pub produces: Vec<ProducedArtifact>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProducerExecutor {
    Command,
    Lineage,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProducedArtifact {
    pub kind: ArtifactKind,
    pub format: String,
    pub path: PathBuf,
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub complete: bool,
    #[serde(default)]
    pub evidence_scope: Option<DeclaredEvidenceScope>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeclaredEvidenceScope {
    pub selection: String,
    pub mutant_corpus: String,
    pub test_set: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactKind {
    Coverage,
    Mutants,
    Sarif,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RunManifest {
    pub version: String,
    pub revision: String,
    #[serde(default)]
    pub profile: String,
    #[serde(default)]
    pub repository_identity: String,
    #[serde(default)]
    pub tree_fingerprint: String,
    #[serde(default)]
    pub started_at_unix_ms: u128,
    #[serde(default)]
    pub duration_ms: u128,
    #[serde(default)]
    pub status: RunStatus,
    pub configuration_hash: String,
    #[serde(default)]
    pub producers: Vec<ProducerRun>,
    pub artifacts: Vec<ManifestArtifact>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    #[default]
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProducerRun {
    pub name: String,
    pub argv: Vec<String>,
    pub working_directory: PathBuf,
    pub settings_hash: String,
    pub started_at_unix_ms: u128,
    pub duration_ms: u128,
    pub exit_status: Option<i32>,
    pub stdout_log: PathBuf,
    pub stderr_log: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManifestArtifact {
    pub producer: String,
    pub kind: ArtifactKind,
    pub format: String,
    pub path: PathBuf,
    pub content_hash: String,
    #[serde(default)]
    pub compression: ArtifactCompression,
    pub scope: Option<String>,
    pub complete: bool,
    #[serde(default)]
    pub evidence_scope: Option<DeclaredEvidenceScope>,
}

pub fn load_config(repo: &Path) -> Result<LineageConfig> {
    let yaml = repo.join(CONFIG_FILE_NAME);
    let json = repo.join(CONFIG_JSON_FILE_NAME);
    if yaml.exists() && json.exists() {
        bail!("repository contains both {CONFIG_FILE_NAME} and {CONFIG_JSON_FILE_NAME}");
    }
    let path = if yaml.exists() {
        yaml
    } else if json.exists() {
        json
    } else {
        bail!("no {CONFIG_FILE_NAME} found in {}", repo.display());
    };
    let contents = fs::read_to_string(&path)
        .with_context(|| format!("read Lineage configuration {}", path.display()))?;
    let config: LineageConfig = if path
        .extension()
        .is_some_and(|extension| extension == "json")
    {
        serde_json::from_str(&contents).map_err(anyhow::Error::from)
    } else {
        serde_yaml::from_str(&contents).map_err(anyhow::Error::from)
    }
    .with_context(|| format!("parse Lineage configuration {}", path.display()))?;
    validate_config(config)
}

pub fn validate_config(config: LineageConfig) -> Result<LineageConfig> {
    if config.version != 1 {
        bail!(
            "unsupported lineage.yml version {}; expected 1",
            config.version
        );
    }
    validate_artifact_directory(&config.artifacts.directory)?;
    for (name, producer) in &config.producers {
        if !is_safe_identifier(name) {
            bail!(
                "producer names must be ASCII identifiers containing only letters, digits, _ or -"
            );
        }
        if producer.executor == ProducerExecutor::Command && producer.argv.is_empty() {
            bail!("command producer {name:?} requires argv");
        }
        if producer.executor == ProducerExecutor::Lineage {
            bail!(
                "producer {name:?} uses unsupported executor `lineage`; use a command adapter that emits declared artifacts"
            );
        }
        if producer.timeout_seconds == 0 || producer.max_output_bytes == 0 {
            bail!(
                "command producer {name:?} timeout_seconds and max_output_bytes must be positive"
            );
        }
        if let Some(path) = &producer.working_directory {
            validate_relative_path(path, &format!("producer {name:?} working_directory"))?;
        }
        if producer
            .environment
            .keys()
            .any(|key| !is_environment_key(key))
        {
            bail!("command producer {name:?} has an invalid environment variable name");
        }
        for artifact in &producer.produces {
            validate_relative_path(&artifact.path, &format!("producer {name:?} artifact path"))?;
            if artifact.complete {
                let scope = artifact.evidence_scope.as_ref().with_context(|| {
                    format!("complete producer {name:?} artifact requires evidence_scope")
                })?;
                if scope.selection.trim().is_empty()
                    || scope.mutant_corpus.trim().is_empty()
                    || scope.test_set.trim().is_empty()
                {
                    bail!("complete producer {name:?} artifact has an invalid evidence_scope");
                }
            }
        }
    }
    for (name, profile) in &config.profiles {
        if name.trim().is_empty() || profile.producers.is_empty() {
            bail!("profile names and producer lists cannot be empty");
        }
        for producer in &profile.producers {
            if !config.producers.contains_key(producer) {
                bail!("profile {name:?} references unknown producer {producer:?}");
            }
        }
    }
    Ok(config)
}

pub fn latest_run_directory(repo: &Path, config: &LineageConfig) -> PathBuf {
    repo.join(&config.artifacts.directory).join("latest")
}

pub fn load_run_manifest(path: &Path) -> Result<RunManifest> {
    let manifest: RunManifest = serde_json::from_slice(&fs::read(path)?)?;
    if manifest.version != RUN_MANIFEST_VERSION {
        bail!("unsupported run manifest version {:?}", manifest.version);
    }
    for artifact in &manifest.artifacts {
        validate_relative_path(&artifact.path, "run manifest artifact path")?;
    }
    Ok(manifest)
}

pub fn read_manifest_artifact(
    run_directory: &Path,
    artifact: &ManifestArtifact,
) -> Result<Vec<u8>> {
    let path = run_directory.join(&artifact.path);
    let root = run_directory
        .canonicalize()
        .with_context(|| format!("canonicalize run directory {}", run_directory.display()))?;
    let canonical_path = path
        .canonicalize()
        .with_context(|| format!("canonicalize artifact {}", path.display()))?;
    if !canonical_path.starts_with(&root) {
        bail!(
            "run manifest artifact {} escapes its run directory",
            artifact.path.display()
        );
    }
    let encoded = fs::read(&path).with_context(|| format!("read artifact {}", path.display()))?;
    let bytes = if artifact.compression == ArtifactCompression::Gzip {
        let decoder = GzDecoder::new(encoded.as_slice());
        let mut bytes =
            Vec::with_capacity(encoded.len().min(MAX_DECOMPRESSED_ARTIFACT_BYTES as usize));
        decoder
            .take(MAX_DECOMPRESSED_ARTIFACT_BYTES + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_DECOMPRESSED_ARTIFACT_BYTES {
            bail!(
                "decompressed artifact {} exceeds {} byte limit",
                artifact.path.display(),
                MAX_DECOMPRESSED_ARTIFACT_BYTES
            );
        }
        bytes
    } else {
        encoded
    };
    if hex::encode(Sha256::digest(&bytes)) != artifact.content_hash {
        bail!("artifact hash mismatch for {}", artifact.path.display());
    }
    Ok(bytes)
}

/// Executes one configured profile and replaces the bounded `latest` run.
/// Commands receive no shell interpolation; their declared outputs are copied
/// only after a zero-exit status, then compressed unless opted out.
pub fn execute_profile(
    repo: &Path,
    config: &LineageConfig,
    profile_name: &str,
    revision: &str,
) -> Result<RunManifest> {
    let profile = config
        .profiles
        .get(profile_name)
        .with_context(|| format!("unknown Lineage profile {profile_name:?}"))?;
    let run_directory = staged_run_directory(repo, config, revision)?;
    fs::create_dir_all(&run_directory)?;
    let started_at_unix_ms = unix_time_ms()?;
    let started = Instant::now();
    let mut artifacts = Vec::new();
    let mut producer_runs = Vec::new();
    let result = (|| -> Result<RunManifest> {
        for producer_name in &profile.producers {
            let producer = &config.producers[producer_name];
            producer_runs.push(execute_producer(
                repo,
                producer_name,
                producer,
                &run_directory,
            )?);
            for (index, artifact) in producer.produces.iter().enumerate() {
                artifacts.push(stage_artifact(
                    repo,
                    &run_directory,
                    producer_name,
                    index,
                    artifact,
                    config.artifacts.compression,
                )?);
            }
        }
        let manifest = build_manifest(
            repo,
            config,
            profile_name,
            revision,
            started_at_unix_ms,
            started.elapsed().as_millis(),
            RunStatus::Succeeded,
            producer_runs.clone(),
            artifacts.clone(),
        )?;
        write_manifest(&run_directory, &manifest)?;
        // Validate the exact payload which will be published before changing
        // the `latest` pointer.
        let verified = load_run_manifest(&run_directory.join("manifest.json"))?;
        for artifact in &verified.artifacts {
            read_manifest_artifact(&run_directory, artifact)?;
        }
        publish_run(repo, config, &run_directory)?;
        Ok(manifest)
    })();
    if let Err(error) = result {
        let failed = build_manifest(
            repo,
            config,
            profile_name,
            revision,
            started_at_unix_ms,
            started.elapsed().as_millis(),
            RunStatus::Failed,
            producer_runs,
            artifacts,
        )?;
        write_manifest(&run_directory, &failed)?;
        retain_failed_run(repo, config, &run_directory)?;
        return Err(error);
    }
    result
}

fn build_manifest(
    repo: &Path,
    config: &LineageConfig,
    profile_name: &str,
    revision: &str,
    started_at_unix_ms: u128,
    duration_ms: u128,
    status: RunStatus,
    producers: Vec<ProducerRun>,
    artifacts: Vec<ManifestArtifact>,
) -> Result<RunManifest> {
    Ok(RunManifest {
        version: RUN_MANIFEST_VERSION.into(),
        revision: revision.into(),
        profile: profile_name.into(),
        repository_identity: repository_identity(repo),
        tree_fingerprint: revision.into(),
        started_at_unix_ms,
        duration_ms,
        status,
        configuration_hash: config_hash(config)?,
        producers,
        artifacts,
    })
}

fn write_manifest(run_directory: &Path, manifest: &RunManifest) -> Result<()> {
    fs::write(
        run_directory.join("manifest.json"),
        serde_json::to_vec_pretty(manifest)?,
    )?;
    Ok(())
}

fn retain_failed_run(repo: &Path, config: &LineageConfig, staged: &Path) -> Result<()> {
    let root = repo.join(&config.artifacts.directory);
    let runs = root.join("runs");
    let name = staged
        .file_name()
        .and_then(|name| name.to_str())
        .context("staged run directory has no valid file name")?;
    let failed = runs.join(format!("failed-{}", name.trim_start_matches(".staging-")));
    fs::rename(staged, &failed)
        .with_context(|| format!("retain failed Lineage run {}", staged.display()))?;
    Ok(())
}

fn staged_run_directory(repo: &Path, config: &LineageConfig, revision: &str) -> Result<PathBuf> {
    let root = repo.join(&config.artifacts.directory);
    let runs = root.join("runs");
    fs::create_dir_all(&runs)?;
    let revision = revision
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(16)
        .collect::<String>();
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system time precedes Unix epoch")?
        .as_nanos();
    Ok(runs.join(format!(
        ".staging-{revision}-{nonce}-{}",
        std::process::id()
    )))
}

fn publish_run(repo: &Path, config: &LineageConfig, staged: &Path) -> Result<()> {
    let root = repo.join(&config.artifacts.directory);
    let runs = root.join("runs");
    let run_name = staged
        .file_name()
        .and_then(|name| name.to_str())
        .context("staged run directory has no valid file name")?;
    let published_name = run_name.trim_start_matches(".staging-");
    let published = runs.join(published_name);
    fs::rename(staged, &published)
        .with_context(|| format!("publish staged Lineage run {}", staged.display()))?;

    let latest = latest_run_directory(repo, config);
    let temporary_link = root.join(format!(".latest-{published_name}"));
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(Path::new("runs").join(published_name), &temporary_link)?;
    }
    #[cfg(not(unix))]
    {
        // Windows does not permit the inexpensive symlink publication used on
        // Unix. Keep the completed run immutable and require a platform
        // specific publisher rather than destructively replacing `latest`.
        bail!("atomic Lineage run publication is currently supported on Unix hosts");
    }
    if let Ok(metadata) = fs::symlink_metadata(&latest) {
        if !metadata.file_type().is_symlink() {
            let legacy = runs.join(format!("legacy-{published_name}"));
            fs::rename(&latest, &legacy).with_context(|| {
                format!("preserve legacy latest Lineage run {}", latest.display())
            })?;
        }
    }
    fs::rename(&temporary_link, &latest)
        .with_context(|| format!("atomically publish latest Lineage run {}", latest.display()))?;
    Ok(())
}

fn execute_producer(
    repo: &Path,
    name: &str,
    producer: &EvidenceProducer,
    run_directory: &Path,
) -> Result<ProducerRun> {
    if producer.executor != ProducerExecutor::Command {
        bail!(
            "producer {name:?} uses unsupported executor {:?}",
            producer.executor
        );
    }
    let working_directory = producer
        .working_directory
        .as_ref()
        .map(|path| repo.join(path))
        .unwrap_or_else(|| repo.to_path_buf());
    let started_at_unix_ms = unix_time_ms()?;
    let started = Instant::now();
    let mut command = Command::new(&producer.argv[0]);
    command
        .args(&producer.argv[1..])
        .current_dir(&working_directory)
        .env_clear();
    for key in ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "SYSTEMROOT"] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    command.envs(&producer.environment);
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("start producer {name:?}"))?;
    let max_output_bytes = producer.max_output_bytes;
    let stdout = child
        .stdout
        .take()
        .context("producer stdout was not captured")?;
    let stderr = child
        .stderr
        .take()
        .context("producer stderr was not captured")?;
    let stdout_reader = thread::spawn(move || read_bounded_output(stdout, max_output_bytes));
    let stderr_reader = thread::spawn(move || read_bounded_output(stderr, max_output_bytes));
    let deadline = Instant::now() + Duration::from_secs(producer.timeout_seconds);
    let mut timed_out = false;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            timed_out = true;
            break child.wait()?;
        }
        thread::sleep(Duration::from_millis(10));
    };
    let stdout = stdout_reader
        .join()
        .map_err(|_| anyhow::anyhow!("producer {name:?} stdout reader panicked"))?;
    let stderr = stderr_reader
        .join()
        .map_err(|_| anyhow::anyhow!("producer {name:?} stderr reader panicked"))?;
    let output_exceeded = stdout.is_err() || stderr.is_err();
    let logs = run_directory.join("logs");
    fs::create_dir_all(&logs)?;
    fs::write(
        logs.join(format!("{name}.stdout")),
        stdout.unwrap_or_else(|error| error.to_string().into_bytes()),
    )?;
    fs::write(
        logs.join(format!("{name}.stderr")),
        stderr.unwrap_or_else(|error| error.to_string().into_bytes()),
    )?;
    if timed_out {
        bail!(
            "producer {name:?} exceeded configured {} second timeout",
            producer.timeout_seconds
        );
    }
    if output_exceeded {
        bail!("producer {name:?} exceeded configured output limit");
    }
    if !status.success() {
        bail!("producer {name:?} exited with {status}");
    }
    Ok(ProducerRun {
        name: name.into(),
        argv: producer.argv.clone(),
        working_directory: producer
            .working_directory
            .clone()
            .unwrap_or_else(|| PathBuf::from(".")),
        settings_hash: hex::encode(Sha256::digest(serde_json::to_vec(producer)?)),
        started_at_unix_ms,
        duration_ms: started.elapsed().as_millis(),
        exit_status: status.code(),
        stdout_log: PathBuf::from("logs").join(format!("{name}.stdout")),
        stderr_log: PathBuf::from("logs").join(format!("{name}.stderr")),
    })
}

fn stage_artifact(
    repo: &Path,
    run_directory: &Path,
    producer: &str,
    index: usize,
    artifact: &ProducedArtifact,
    compression: ArtifactCompression,
) -> Result<ManifestArtifact> {
    let source = repo.join(&artifact.path);
    let repository_root = repo
        .canonicalize()
        .with_context(|| format!("canonicalize repository {}", repo.display()))?;
    let canonical_source = source
        .canonicalize()
        .with_context(|| format!("canonicalize artifact {}", source.display()))?;
    if !canonical_source.starts_with(&repository_root) {
        bail!(
            "artifact {} escapes repository through a symlink",
            artifact.path.display()
        );
    }
    let bytes = fs::read(&source).with_context(|| format!("read artifact {}", source.display()))?;
    let file_name = artifact
        .path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("artifact");
    let relative = PathBuf::from("artifacts")
        .join(producer)
        .join(format!("{index}-{file_name}"));
    let target = run_directory.join(&relative);
    fs::create_dir_all(target.parent().expect("artifact target parent exists"))?;
    let path = match compression {
        ArtifactCompression::None => {
            fs::write(&target, &bytes)?;
            relative
        }
        ArtifactCompression::Gzip => {
            let compressed_relative = relative.with_added_extension("gz");
            let compressed = run_directory.join(&compressed_relative);
            let mut encoder = GzEncoder::new(fs::File::create(compressed)?, Compression::default());
            encoder.write_all(&bytes)?;
            encoder.finish()?;
            compressed_relative
        }
    };
    Ok(ManifestArtifact {
        producer: producer.into(),
        kind: artifact.kind,
        format: artifact.format.clone(),
        path,
        content_hash: hex::encode(Sha256::digest(&bytes)),
        compression,
        scope: artifact.scope.clone(),
        complete: artifact.complete,
        evidence_scope: artifact.evidence_scope.clone(),
    })
}

fn config_hash(config: &LineageConfig) -> Result<String> {
    Ok(hex::encode(Sha256::digest(serde_json::to_vec(config)?)))
}

pub fn validate_relative_path(path: &Path, label: &str) -> Result<()> {
    if path.as_os_str().is_empty() || path.is_absolute() {
        bail!("{label} must be a non-empty relative path");
    }
    if path.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        bail!("{label} must not escape its declared root");
    }
    Ok(())
}

fn validate_artifact_directory(path: &Path) -> Result<()> {
    validate_relative_path(path, "artifacts.directory")?;
    let reserved = Path::new(".lineage/artifacts");
    if !path.starts_with(reserved) {
        bail!("artifacts.directory must be beneath {}", reserved.display());
    }
    Ok(())
}

fn is_safe_identifier(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

fn is_environment_key(value: &str) -> bool {
    let mut bytes = value.bytes();
    let Some(first) = bytes.next() else {
        return false;
    };
    is_environment_key_start(first) && bytes.all(is_environment_key_continue)
}

fn is_environment_key_start(byte: u8) -> bool {
    byte == b'_' || byte.is_ascii_alphabetic()
}

fn is_environment_key_continue(byte: u8) -> bool {
    is_environment_key_start(byte) || byte.is_ascii_digit()
}

fn default_artifact_directory() -> PathBuf {
    PathBuf::from(".lineage/artifacts")
}

fn default_compression() -> ArtifactCompression {
    ArtifactCompression::Gzip
}

fn default_command_timeout_seconds() -> u64 {
    15 * 60
}

fn default_command_output_bytes() -> usize {
    4 * 1024 * 1024
}

fn unix_time_ms() -> Result<u128> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system time precedes Unix epoch")?
        .as_millis())
}

fn repository_identity(repo: &Path) -> String {
    let remote = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["config", "--get", "remote.origin.url"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    remote.unwrap_or_else(|| {
        repo.canonicalize()
            .unwrap_or_else(|_| repo.to_path_buf())
            .to_string_lossy()
            .into_owned()
    })
}

fn read_bounded_output(mut reader: impl Read, max_output_bytes: usize) -> Result<Vec<u8>> {
    let mut bytes = Vec::with_capacity(max_output_bytes.min(64 * 1024));
    reader
        .by_ref()
        .take((max_output_bytes + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > max_output_bytes {
        bail!("producer output exceeds {max_output_bytes} byte limit");
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn loads_valid_yaml_and_uses_a_bounded_latest_directory() {
        let directory = tempdir().unwrap();
        fs::write(
            directory.path().join(CONFIG_FILE_NAME),
            "version: 1\nprofiles:\n  ci:\n    producers: [coverage]\nproducers:\n  coverage:\n    executor: command\n    argv: [bundle, exec, rake, test]\n    produces:\n      - kind: coverage\n        format: simplecov\n        path: coverage/.resultset.json\n        scope: unit\n        complete: true\n        evidence_scope: {selection: full, mutant_corpus: unit-corpus, test_set: unit}\n",
        )
        .unwrap();

        let config = load_config(directory.path()).unwrap();

        assert_eq!(config.artifacts.compression, ArtifactCompression::Gzip);
        assert_eq!(
            latest_run_directory(directory.path(), &config),
            directory.path().join(".lineage/artifacts/latest")
        );
        assert_eq!(config.profiles["ci"].producers, ["coverage"]);
    }

    #[test]
    fn rejects_ambiguous_or_escaping_configuration() {
        let directory = tempdir().unwrap();
        fs::write(
            directory.path().join(CONFIG_FILE_NAME),
            "version: 1\nartifacts:\n  directory: ../outside\n",
        )
        .unwrap();
        assert!(load_config(directory.path())
            .unwrap_err()
            .to_string()
            .contains("must not escape"));

        fs::write(directory.path().join(CONFIG_JSON_FILE_NAME), "{}\n").unwrap();
        assert!(load_config(directory.path())
            .unwrap_err()
            .to_string()
            .contains("both lineage.yml"));
    }

    #[test]
    fn replaces_latest_run_and_compresses_declared_artifacts() {
        let directory = tempdir().unwrap();
        fs::create_dir_all(directory.path().join("coverage")).unwrap();
        fs::write(
            directory.path().join("coverage/report.json"),
            "{\"files\":{}}\n",
        )
        .unwrap();
        let config = validate_config(LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig::default(),
            profiles: BTreeMap::from([(
                "ci".into(),
                VerificationProfile {
                    producers: vec!["coverage".into()],
                },
            )]),
            producers: BTreeMap::from([(
                "coverage".into(),
                EvidenceProducer {
                    executor: ProducerExecutor::Command,
                    argv: vec!["true".into()],
                    working_directory: None,
                    timeout_seconds: default_command_timeout_seconds(),
                    max_output_bytes: default_command_output_bytes(),
                    environment: BTreeMap::new(),
                    produces: vec![ProducedArtifact {
                        kind: ArtifactKind::Coverage,
                        format: "generic".into(),
                        path: "coverage/report.json".into(),
                        scope: Some("unit".into()),
                        complete: true,
                        evidence_scope: Some(DeclaredEvidenceScope {
                            selection: "full".into(),
                            mutant_corpus: "unit-corpus".into(),
                            test_set: "unit".into(),
                        }),
                    }],
                },
            )]),
        })
        .unwrap();
        let latest = latest_run_directory(directory.path(), &config);
        fs::create_dir_all(&latest).unwrap();
        fs::write(latest.join("old.txt"), "old").unwrap();

        let manifest = execute_profile(directory.path(), &config, "ci", "abc").unwrap();

        assert_eq!(manifest.version, RUN_MANIFEST_VERSION);
        assert_eq!(
            manifest.artifacts[0].path,
            PathBuf::from("artifacts/coverage/0-report.json.gz")
        );
        assert!(!latest.join("old.txt").exists());
        assert!(latest.join("manifest.json").exists());
        assert!(latest.join(&manifest.artifacts[0].path).exists());
        assert!(latest.is_symlink());
        assert!(
            latest
                .parent()
                .unwrap()
                .join("runs")
                .read_dir()
                .unwrap()
                .count()
                >= 2
        );
    }

    #[test]
    fn failing_profile_keeps_the_last_successful_run_published() {
        let directory = tempdir().unwrap();
        fs::create_dir_all(directory.path().join("coverage")).unwrap();
        fs::write(directory.path().join("coverage/report.json"), "{}\n").unwrap();
        let mut config = validate_config(LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig::default(),
            profiles: BTreeMap::from([(
                "ci".into(),
                VerificationProfile {
                    producers: vec!["coverage".into()],
                },
            )]),
            producers: BTreeMap::from([(
                "coverage".into(),
                EvidenceProducer {
                    executor: ProducerExecutor::Command,
                    argv: vec!["true".into()],
                    working_directory: None,
                    timeout_seconds: 5,
                    max_output_bytes: 1024,
                    environment: BTreeMap::new(),
                    produces: vec![ProducedArtifact {
                        kind: ArtifactKind::Coverage,
                        format: "generic".into(),
                        path: "coverage/report.json".into(),
                        scope: None,
                        complete: false,
                        evidence_scope: None,
                    }],
                },
            )]),
        })
        .unwrap();
        execute_profile(directory.path(), &config, "ci", "first").unwrap();
        let latest = latest_run_directory(directory.path(), &config);
        let first = fs::read(latest.join("manifest.json")).unwrap();
        config.producers.get_mut("coverage").unwrap().argv = vec!["false".into()];

        assert!(execute_profile(directory.path(), &config, "ci", "second").is_err());
        assert_eq!(fs::read(latest.join("manifest.json")).unwrap(), first);
        let failed = latest
            .parent()
            .unwrap()
            .join("runs")
            .read_dir()
            .unwrap()
            .map(|entry| entry.unwrap())
            .map(|entry| entry.path())
            .find(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with("failed-"))
            })
            .unwrap();
        assert_eq!(
            load_run_manifest(&failed.join("manifest.json"))
                .unwrap()
                .status,
            RunStatus::Failed
        );
    }

    #[cfg(unix)]
    #[test]
    fn rejects_manifest_artifact_symlink_escaping_the_run() {
        let directory = tempdir().unwrap();
        let run = directory.path().join("run");
        fs::create_dir_all(run.join("artifacts")).unwrap();
        let outside = directory.path().join("outside.json");
        fs::write(&outside, "{}\n").unwrap();
        std::os::unix::fs::symlink(&outside, run.join("artifacts/report.json")).unwrap();
        let artifact = ManifestArtifact {
            producer: "coverage".into(),
            kind: ArtifactKind::Coverage,
            format: "generic".into(),
            path: "artifacts/report.json".into(),
            content_hash: "unused".into(),
            compression: ArtifactCompression::None,
            scope: None,
            complete: false,
            evidence_scope: None,
        };

        assert!(read_manifest_artifact(&run, &artifact)
            .unwrap_err()
            .to_string()
            .contains("escapes"));
    }
}
