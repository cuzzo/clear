//! Typed configuration and manifest contracts for the Gigasail evidence pipeline.

use anyhow::{bail, Context, Result};
use flate2::Compression;
use flate2::{read::GzDecoder, write::GzEncoder};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{Read, Write};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const CONFIG_FILE_NAME: &str = "gigasail.yml";
pub const CONFIG_JSON_FILE_NAME: &str = "gigasail.json";
pub const RUN_MANIFEST_VERSION: &str = "gigasail-run/v1";
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
    #[serde(default = "default_retained_runs")]
    pub retain_runs: usize,
    /// Staging and pending directories newer than this are considered active
    /// and are never pruned. Older abandoned directories are bounded so failed
    /// or interrupted CI cannot grow the artifact store indefinitely.
    #[serde(default = "default_stale_run_age_seconds")]
    pub stale_run_age_seconds: u64,
}

impl Default for ArtifactStoreConfig {
    fn default() -> Self {
        Self {
            directory: default_artifact_directory(),
            compression: default_compression(),
            retain_runs: default_retained_runs(),
            stale_run_age_seconds: default_stale_run_age_seconds(),
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
    /// Evidence families that this profile promises to emit. This makes
    /// `--require-complete` useful for a real CI contract rather than merely
    /// checking whichever artifacts happened to be declared.
    #[serde(default)]
    pub required_evidence: BTreeSet<ArtifactKind>,
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
    Gigasail,
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
    /// Coverage and SARIF may be complete without a mutation corpus. The
    /// sentinel is deliberately explicit in persisted scopes so those evidence
    /// families cannot be mistaken for mutation-backed evidence.
    #[serde(default = "not_applicable_mutant_corpus")]
    pub mutant_corpus: String,
    pub test_set: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactKind {
    /// A producer-owned intermediate artifact. It is staged, hashed, and
    /// retained with the run so later producers can consume it, but it is not
    /// evidence that Gigasail imports into its database.
    Auxiliary,
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
    Succeeded,
    #[default]
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProducerRun {
    pub name: String,
    pub argv: Vec<String>,
    #[serde(default)]
    pub tool_version: String,
    pub working_directory: PathBuf,
    pub settings_hash: String,
    pub started_at_unix_ms: u128,
    pub duration_ms: u128,
    pub exit_status: Option<i32>,
    #[serde(default)]
    pub outcome: ProducerOutcome,
    #[serde(default)]
    pub failure: Option<String>,
    pub stdout_log: PathBuf,
    pub stderr_log: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ProducerOutcome {
    Succeeded,
    Skipped,
    Failed,
    TimedOut,
    OutputLimited,
    #[default]
    Unknown,
}

/// A validated, immutable run. CI runs await publication; standalone analysis
/// runs are already classified under the bounded `analysis-*` namespace.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompletedRun {
    pub manifest: RunManifest,
    pub directory: PathBuf,
}

/// Chooses the durable run namespace before profile execution returns. This
/// prevents a standalone analysis run from ever being mistaken for an
/// interrupted CI publication during crash recovery.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProfileRunKind {
    CiPublication,
    StandaloneAnalysis,
}

/// Owns serialized profile execution for a repository. The session must stay
/// alive through CI ingestion/publication so producers sharing declared output
/// paths cannot interleave their workspace transactions.
pub struct ProfileExecutionSession {
    repo: PathBuf,
    config: LineageConfig,
    _lock: ExecutionLock,
}

impl ProfileExecutionSession {
    pub fn begin(repo: &Path, config: &LineageConfig) -> Result<Self> {
        let repository_root = canonical_directory_without_symlinks(repo, "repository")?;
        ensure_artifact_store_root(&repository_root, config)?;
        let lock = ExecutionLock::acquire(&repository_root, config)?;
        recover_workspace_transactions(&repository_root, config)?;
        Ok(Self {
            repo: repository_root,
            config: config.clone(),
            _lock: lock,
        })
    }

    pub fn execute(
        &self,
        profile_name: &str,
        revision: &str,
        kind: ProfileRunKind,
    ) -> Result<CompletedRun> {
        execute_profile_unlocked(&self.repo, &self.config, profile_name, revision, kind)
    }
}

fn ensure_artifact_store_root(repo: &Path, config: &LineageConfig) -> Result<()> {
    let root = canonical_directory_without_symlinks(repo, "repository")?;
    validate_relative_path(&config.artifacts.directory, "artifacts.directory")?;
    let mut current = root;
    for component in config.artifacts.directory.components() {
        let Component::Normal(name) = component else {
            continue;
        };
        current.push(name);
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
                bail!(
                    "Gigasail artifact-store ancestor {} must be a non-symlink directory",
                    current.display()
                );
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&current).with_context(|| {
                    format!(
                        "create Gigasail artifact-store directory {}",
                        current.display()
                    )
                })?;
            }
            Err(error) => {
                return Err(error).with_context(|| {
                    format!(
                        "inspect Gigasail artifact-store directory {}",
                        current.display()
                    )
                });
            }
        }
    }
    Ok(())
}

struct ExecutionLock {
    path: PathBuf,
}

impl ExecutionLock {
    fn acquire(repo: &Path, config: &LineageConfig) -> Result<Self> {
        let root = repo.join(&config.artifacts.directory);
        fs::create_dir_all(&root)?;
        let path = root.join(".profile-execution.lock");
        for attempt in 0..2 {
            match fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
            {
                Ok(mut file) => {
                    let identity = execution_lock_identity()?;
                    if let Err(error) = writeln!(file, "{identity}").and_then(|_| file.sync_all()) {
                        let _ = fs::remove_file(&path);
                        return Err(error).with_context(|| {
                            format!("write Gigasail execution lock {}", path.display())
                        });
                    }
                    return Ok(Self { path });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists && attempt == 0 => {
                    if stale_execution_lock(&path)? {
                        fs::remove_file(&path).with_context(|| {
                            format!("remove stale Gigasail execution lock {}", path.display())
                        })?;
                        continue;
                    }
                    bail!(
                        "acquire Gigasail execution lock {}; another profile execution may be running",
                        path.display()
                    );
                }
                Err(error) => {
                    return Err(error).with_context(|| {
                        format!("acquire Gigasail execution lock {}", path.display())
                    })
                }
            }
        }
        unreachable!("execution lock acquisition loop always returns")
    }
}

impl Drop for ExecutionLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn stale_execution_lock(path: &Path) -> Result<bool> {
    let contents = fs::read_to_string(path)
        .with_context(|| format!("read Gigasail execution lock {}", path.display()))?;
    let mut fields = contents.split_whitespace();
    let Some(pid) = fields.next().and_then(|pid| pid.parse::<u32>().ok()) else {
        return Ok(true);
    };
    let recorded_start = fields.next().map(str::to_string);
    if fields.next().is_some() {
        return Ok(true);
    }
    #[cfg(unix)]
    unsafe {
        let result = libc::kill(pid as i32, 0);
        let error = std::io::Error::last_os_error();
        if result != 0 {
            return Ok(error.raw_os_error() == Some(libc::ESRCH));
        }
        #[cfg(target_os = "linux")]
        if let Some(recorded_start) = recorded_start {
            return Ok(process_start_identity(pid).as_deref() != Some(recorded_start.as_str()));
        }
        Ok(false)
    }
    #[cfg(not(unix))]
    {
        let _ = (pid, recorded_start);
        Ok(false)
    }
}

fn execution_lock_identity() -> Result<String> {
    let pid = std::process::id();
    #[cfg(target_os = "linux")]
    {
        return Ok(format!(
            "{pid} {}",
            process_start_identity(pid).context("read process start identity")?
        ));
    }
    #[cfg(not(target_os = "linux"))]
    Ok(pid.to_string())
}

#[cfg(target_os = "linux")]
fn process_start_identity(pid: u32) -> Option<String> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let (_, fields) = stat.rsplit_once(") ")?;
    fields.split_whitespace().nth(19).map(str::to_string)
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
        .with_context(|| format!("read Gigasail configuration {}", path.display()))?;
    load_config_contents(
        &contents,
        path.extension().and_then(|extension| extension.to_str()),
    )
}

/// Parses a configuration from an already-trusted source snapshot. CI uses
/// this for a reviewed base revision so a pull request cannot grant itself
/// arbitrary command execution merely by editing `gigasail.yml`.
pub fn load_config_contents(contents: &str, extension: Option<&str>) -> Result<LineageConfig> {
    let config: LineageConfig = if extension == Some("json") {
        serde_json::from_str(contents).map_err(anyhow::Error::from)
    } else {
        serde_yaml::from_str(contents).map_err(anyhow::Error::from)
    }?;
    validate_config(config)
}

pub fn validate_config(config: LineageConfig) -> Result<LineageConfig> {
    if config.version != 1 {
        bail!(
            "unsupported gigasail.yml version {}; expected 1",
            config.version
        );
    }
    validate_artifact_directory(&config.artifacts.directory)?;
    if config.artifacts.retain_runs == 0 {
        bail!("artifacts.retain_runs must be positive");
    }
    if config.artifacts.stale_run_age_seconds == 0 {
        bail!("artifacts.stale_run_age_seconds must be positive");
    }
    for (name, producer) in &config.producers {
        if !is_safe_identifier(name) {
            bail!(
                "producer names must be ASCII identifiers containing only letters, digits, _ or -"
            );
        }
        if producer.executor == ProducerExecutor::Command && producer.argv.is_empty() {
            bail!("command producer {name:?} requires argv");
        }
        if producer.executor == ProducerExecutor::Gigasail
            && producer.argv.as_slice() != ["fact-mine-native"]
        {
            bail!(
                "gigasail producer {name:?} must use the allowlisted embedded provider argv: [fact-mine-native]; use executor: command for an explicitly trusted external command"
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
                    || scope.test_set.trim().is_empty()
                    || (artifact.kind == ArtifactKind::Mutants
                        && (scope.mutant_corpus.trim().is_empty()
                            || scope.mutant_corpus == not_applicable_mutant_corpus()))
                {
                    bail!("complete producer {name:?} artifact has an invalid evidence_scope");
                }
            }
        }
    }
    let mut declared_outputs = BTreeMap::<PathBuf, String>::new();
    for (producer_name, producer) in &config.producers {
        for artifact in &producer.produces {
            if let Some(previous) =
                declared_outputs.insert(artifact.path.clone(), producer_name.clone())
            {
                bail!(
                    "declared artifact path {} is shared by producers {previous:?} and {producer_name:?}",
                    artifact.path.display()
                );
            }
        }
    }
    for (name, profile) in &config.profiles {
        if name.trim().is_empty() || profile.producers.is_empty() {
            bail!("profile names and producer lists cannot be empty");
        }
        let mut seen = BTreeSet::new();
        for producer in &profile.producers {
            if !config.producers.contains_key(producer) {
                bail!("profile {name:?} references unknown producer {producer:?}");
            }
            if !seen.insert(producer) {
                bail!("profile {name:?} references producer {producer:?} more than once");
            }
        }
        let declared_families = profile
            .producers
            .iter()
            .flat_map(|producer| {
                config.producers[producer]
                    .produces
                    .iter()
                    .map(|artifact| artifact.kind)
            })
            .collect::<BTreeSet<_>>();
        if let Some(missing) = profile
            .required_evidence
            .iter()
            .find(|kind| !declared_families.contains(kind))
        {
            bail!(
                "profile {name:?} requires {missing:?} evidence but none of its producers declares that family"
            );
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
    let encoded_size = fs::metadata(&path)
        .with_context(|| format!("stat artifact {}", path.display()))?
        .len();
    if encoded_size > MAX_DECOMPRESSED_ARTIFACT_BYTES {
        bail!(
            "artifact {} exceeds {} byte encoded limit",
            artifact.path.display(),
            MAX_DECOMPRESSED_ARTIFACT_BYTES
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
        if encoded.len() as u64 > MAX_DECOMPRESSED_ARTIFACT_BYTES {
            bail!(
                "artifact {} exceeds {} byte limit",
                artifact.path.display(),
                MAX_DECOMPRESSED_ARTIFACT_BYTES
            );
        }
        encoded
    };
    if hex::encode(Sha256::digest(&bytes)) != artifact.content_hash {
        bail!("artifact hash mismatch for {}", artifact.path.display());
    }
    Ok(bytes)
}

/// Revalidates every payload that a run manifest names.  Published runs are
/// content-addressed records: callers must not trust a manifest merely
/// because it remains at the `latest` path.
pub fn validate_run_artifacts(run_directory: &Path, manifest: &RunManifest) -> Result<()> {
    for artifact in &manifest.artifacts {
        let bytes = read_manifest_artifact(run_directory, artifact)?;
        if artifact.kind == ArtifactKind::Sarif {
            validate_sarif_document(&bytes)
                .with_context(|| format!("validate SARIF artifact {}", artifact.path.display()))?;
        }
    }
    Ok(())
}

/// Validates the strict SARIF contract accepted for persisted Gigasail
/// evidence. Direct ingestion and manifest ingestion intentionally share this
/// gate so an unsupported document cannot be reported as complete.
pub fn validate_sarif_document(bytes: &[u8]) -> Result<()> {
    let document: serde_json::Value = serde_json::from_slice(bytes).context("parse JSON")?;
    if document.get("version").and_then(serde_json::Value::as_str) != Some("2.1.0") {
        bail!("SARIF version must be \"2.1.0\"");
    }
    let runs = document
        .get("runs")
        .and_then(serde_json::Value::as_array)
        .context("SARIF document must contain a runs array")?;
    for (index, run) in runs.iter().enumerate() {
        if run
            .pointer("/tool/driver/name")
            .and_then(serde_json::Value::as_str)
            .is_none()
        {
            bail!("SARIF run {index} must identify tool.driver.name");
        }
        if run
            .get("results")
            .is_some_and(|results| !results.is_array())
        {
            bail!("SARIF run {index} results must be an array when present");
        }
    }
    Ok(())
}

/// Makes a published run read-only on Unix after its final state has been
/// written. This is defense in depth; `validate_run_artifacts` remains the
/// integrity boundary for callers that read a run from a writable filesystem.
pub fn seal_published_run(run_directory: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        fn seal(path: &Path) -> Result<()> {
            let metadata = fs::symlink_metadata(path)?;
            if metadata.file_type().is_symlink() {
                return Ok(());
            }
            if metadata.is_dir() {
                for entry in fs::read_dir(path)? {
                    seal(&entry?.path())?;
                }
                fs::set_permissions(path, fs::Permissions::from_mode(0o555))?;
            } else if metadata.is_file() {
                fs::set_permissions(path, fs::Permissions::from_mode(0o444))?;
            }
            Ok(())
        }
        seal(run_directory)?;
    }
    #[cfg(not(unix))]
    let _ = run_directory;
    Ok(())
}

/// Removes a completed run that may have been sealed read-only after
/// publication. Retention is the one intentional exception to run
/// immutability, so make the tree writable immediately before deleting it.
fn remove_retained_run(run_directory: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        fn make_removable(path: &Path) -> Result<()> {
            let metadata = fs::symlink_metadata(path)?;
            if metadata.file_type().is_symlink() {
                return Ok(());
            }
            if metadata.is_dir() {
                for entry in fs::read_dir(path)? {
                    make_removable(&entry?.path())?;
                }
                fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
            } else if metadata.is_file() {
                fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
            }
            Ok(())
        }
        make_removable(run_directory)?;
    }
    fs::remove_dir_all(run_directory)
        .with_context(|| format!("prune retained Gigasail run {}", run_directory.display()))
}

/// Executes one configured profile and replaces the bounded `latest` run.
/// Commands receive no shell interpolation; their declared outputs are copied
/// only after a zero-exit status, then compressed unless opted out.
fn execute_profile_unlocked(
    repo: &Path,
    config: &LineageConfig,
    profile_name: &str,
    revision: &str,
    kind: ProfileRunKind,
) -> Result<CompletedRun> {
    let profile = config
        .profiles
        .get(profile_name)
        .with_context(|| format!("unknown Gigasail profile {profile_name:?}"))?;
    let declared_outputs = profile
        .producers
        .iter()
        .flat_map(|producer| {
            config.producers[producer]
                .produces
                .iter()
                .map(|artifact| artifact.path.clone())
        })
        .collect::<BTreeSet<_>>();
    let run_directory = staged_run_directory(repo, config, revision)?;
    fs::create_dir_all(&run_directory)?;
    let started_at_unix_ms = unix_time_ms()?;
    let started = Instant::now();
    let initial_tree_fingerprint = (revision == crate::git::WORKTREE_REVISION)
        .then(|| working_tree_fingerprint(repo, &config.artifacts.directory, &declared_outputs))
        .transpose()?;
    let mut artifacts = Vec::new();
    let mut producer_runs = Vec::new();
    // Outputs are workspace state, not run state. Quarantine all of them once
    // so a later producer can consume an earlier producer's fresh output, but
    // never let a failed (or successful) profile permanently replace files in
    // the caller's checkout. Only immutable staged copies are published.
    let workspace = quarantine_profile_outputs(repo, &run_directory, profile, config)?;
    prepare_declared_output_parents(repo, profile, config)?;
    let execution = (|| -> Result<RunManifest> {
        for producer_name in &profile.producers {
            let producer = &config.producers[producer_name];
            let producer_run = match execute_producer(repo, producer_name, producer, &run_directory)
            {
                Ok(run) => run,
                Err(error) => {
                    producer_runs.push(unstarted_failed_producer_run(
                        producer_name,
                        producer,
                        error.to_string(),
                    )?);
                    return Err(error);
                }
            };
            let skipped = producer_run.outcome == ProducerOutcome::Skipped;
            let failed = producer_run.outcome != ProducerOutcome::Succeeded && !skipped;
            let failure = producer_run.failure.clone();
            producer_runs.push(producer_run);
            if failed {
                bail!(
                    "producer {producer_name:?} failed: {}",
                    failure.unwrap_or_else(|| "unknown failure".into())
                );
            }
            if skipped {
                continue;
            }
            for (index, artifact) in producer.produces.iter().enumerate() {
                let staged = stage_artifact(
                    repo,
                    &run_directory,
                    producer_name,
                    index,
                    artifact,
                    config.artifacts.compression,
                );
                match staged {
                    Ok(artifact) => artifacts.push(artifact),
                    Err(error) => return Err(error),
                }
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
            initial_tree_fingerprint.as_deref(),
        )?;
        if let Some(expected) = initial_tree_fingerprint.as_deref() {
            let observed =
                working_tree_fingerprint(repo, &config.artifacts.directory, &declared_outputs)?;
            if observed != expected {
                bail!("working tree changed while Gigasail analysis was running");
            }
        }
        write_manifest(&run_directory, &manifest)?;
        // Validate the exact payload which will be published before changing
        // the `latest` pointer.
        let verified = load_run_manifest(&run_directory.join("manifest.json"))?;
        validate_run_artifacts(&run_directory, &verified)?;
        Ok(manifest)
    })();
    let restored = workspace.restore();
    let result = match (execution, restored) {
        (Ok(manifest), Ok(())) => Ok(manifest),
        (Ok(_), Err(error)) => Err(error.context("restore declared profile outputs")),
        (Err(error), Ok(())) => Err(error),
        (Err(error), Err(restore_error)) => Err(error.context(format!(
            "profile outputs could not be fully restored: {restore_error:#}"
        ))),
    };
    let manifest = match result {
        Ok(manifest) => manifest,
        Err(error) => {
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
                initial_tree_fingerprint.as_deref(),
            )?;
            write_manifest(&run_directory, &failed)?;
            retain_failed_run(repo, config, &run_directory)?;
            return Err(error);
        }
    };
    let directory = finalize_run(repo, config, &run_directory, kind)?;
    Ok(CompletedRun {
        manifest,
        directory,
    })
}

const WORKSPACE_TRANSACTION_JOURNAL: &str = "workspace-transaction.json";

#[derive(Debug, Clone)]
struct QuarantinedOutput {
    source: PathBuf,
    backup: PathBuf,
    original_present: bool,
}

/// On-disk recovery records deliberately contain no absolute filesystem paths.
/// They are untrusted input on the next invocation and are resolved only after
/// validation against canonical repository and run roots.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WorkspaceJournalEntry {
    source: PathBuf,
    backup: PathBuf,
    original_present: bool,
}

struct WorkspaceOutputTransaction {
    quarantined: Vec<QuarantinedOutput>,
    backup_root: PathBuf,
    journal: PathBuf,
}

impl WorkspaceOutputTransaction {
    fn restore(self) -> Result<()> {
        let mut failures = Vec::new();
        for output in &self.quarantined {
            let source = &output.source;
            match fs::symlink_metadata(source) {
                Ok(metadata) if metadata.file_type().is_dir() => failures.push(format!(
                    "refusing to remove generated directory declared as artifact {}",
                    source.display()
                )),
                Ok(_) => {
                    if let Err(error) = fs::remove_file(source) {
                        failures.push(format!(
                            "remove generated artifact {}: {error}",
                            source.display()
                        ));
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => failures.push(format!(
                    "inspect generated artifact {}: {error}",
                    source.display()
                )),
            }
        }
        for output in self.quarantined.iter().rev() {
            if !output.backup.exists() {
                continue;
            }
            if let Some(parent) = output.source.parent() {
                if let Err(error) = fs::create_dir_all(parent) {
                    failures.push(format!("restore parent {}: {error}", parent.display()));
                    continue;
                }
            }
            if let Err(error) = fs::rename(&output.backup, &output.source) {
                failures.push(format!(
                    "restore declared artifact {}: {error}",
                    output.source.display()
                ));
            }
        }
        if self.backup_root.exists() {
            if let Err(error) = fs::remove_dir_all(&self.backup_root) {
                failures.push(format!(
                    "remove stale quarantine directory {}: {error}",
                    self.backup_root.display()
                ));
            }
        }
        if failures.is_empty() {
            if let Err(error) = fs::remove_file(&self.journal) {
                if error.kind() != std::io::ErrorKind::NotFound {
                    failures.push(format!(
                        "remove workspace transaction journal {}: {error}",
                        self.journal.display()
                    ));
                }
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            bail!(failures.join("; "));
        }
    }
}

fn quarantine_profile_outputs(
    repo: &Path,
    run_directory: &Path,
    profile: &VerificationProfile,
    config: &LineageConfig,
) -> Result<WorkspaceOutputTransaction> {
    let repository_root = canonical_directory_without_symlinks(repo, "repository")?;
    let mut quarantined = Vec::new();
    for producer_name in &profile.producers {
        let producer = &config.producers[producer_name];
        for (index, artifact) in producer.produces.iter().enumerate() {
            let source =
                resolve_relative_path(&repository_root, &artifact.path, "declared artifact path")?;
            let metadata = match fs::symlink_metadata(&source) {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => {
                    return Err(error).with_context(|| {
                        format!("inspect declared artifact {}", source.display())
                    });
                }
            };
            if metadata.file_type().is_dir() {
                let error = anyhow::anyhow!(
                    "declared artifact {} is a directory; artifacts must be files or symlinks",
                    source.display()
                );
                return Err(error);
            }
            let backup = run_directory
                .join("preexisting")
                .join(producer_name)
                .join(format!(
                    "{index}-{}",
                    artifact
                        .path
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                ));
            quarantined.push(QuarantinedOutput {
                source,
                backup,
                original_present: true,
            });
        }
    }
    // Include outputs which did not previously exist: recovery must remove a
    // generated file rather than mistake it for a pre-existing input.
    for producer_name in &profile.producers {
        for (index, artifact) in config.producers[producer_name].produces.iter().enumerate() {
            let source =
                resolve_relative_path(&repository_root, &artifact.path, "declared artifact path")?;
            if quarantined.iter().any(|output| output.source == source) {
                continue;
            }
            quarantined.push(QuarantinedOutput {
                source,
                backup: run_directory
                    .join("preexisting")
                    .join(producer_name)
                    .join(format!(
                        "{index}-{}",
                        artifact
                            .path
                            .file_name()
                            .unwrap_or_default()
                            .to_string_lossy()
                    )),
                original_present: false,
            });
        }
    }
    let journal = run_directory.join(WORKSPACE_TRANSACTION_JOURNAL);
    write_workspace_journal(repo, run_directory, &journal, &quarantined)?;
    let mut moved = Vec::new();
    for output in &quarantined {
        if !output.original_present {
            continue;
        }
        if let Err(error) = (|| -> Result<()> {
            if fs::symlink_metadata(&output.backup).is_ok() {
                bail!(
                    "quarantine destination {} already exists",
                    output.backup.display()
                );
            }
            fs::create_dir_all(output.backup.parent().expect("backup parent exists"))?;
            fs::rename(&output.source, &output.backup).with_context(|| {
                format!(
                    "quarantine stale declared artifact {}",
                    output.source.display()
                )
            })?;
            Ok(())
        })() {
            rollback_partial_quarantine(&moved, &run_directory.join("preexisting"))?;
            let _ = fs::remove_file(&journal);
            return Err(error);
        }
        moved.push(output.clone());
    }
    Ok(WorkspaceOutputTransaction {
        quarantined,
        backup_root: run_directory.join("preexisting"),
        journal,
    })
}

/// A declared output is an API contract: producers should not need a shell
/// prelude merely to create its parent directory. Create every parent after
/// stale outputs have been quarantined, checking each component so a config
/// cannot redirect a producer through a symlink outside the repository.
fn prepare_declared_output_parents(
    repo: &Path,
    profile: &VerificationProfile,
    config: &LineageConfig,
) -> Result<()> {
    let repository_root = canonical_directory_without_symlinks(repo, "repository")?;
    for producer_name in &profile.producers {
        for artifact in &config.producers[producer_name].produces {
            let parent = artifact.path.parent().unwrap_or_else(|| Path::new(""));
            create_checked_relative_directory(
                &repository_root,
                parent,
                "declared artifact parent",
            )?;
        }
    }
    Ok(())
}

fn write_workspace_journal(
    repo: &Path,
    run_directory: &Path,
    path: &Path,
    outputs: &[QuarantinedOutput],
) -> Result<()> {
    let repository_root = canonical_directory_without_symlinks(repo, "repository")?;
    let run_root = canonical_directory_without_symlinks(run_directory, "run directory")?;
    let entries = outputs
        .iter()
        .map(|output| {
            Ok(WorkspaceJournalEntry {
                source: output
                    .source
                    .strip_prefix(&repository_root)
                    .context("workspace source is outside the repository")?
                    .to_path_buf(),
                backup: output
                    .backup
                    .strip_prefix(&run_root)
                    .context("workspace backup is outside the run directory")?
                    .to_path_buf(),
                original_present: output.original_present,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    let temporary = path.with_extension("json.tmp");
    let mut file = fs::File::create(&temporary)?;
    file.write_all(&serde_json::to_vec(&entries)?)?;
    file.sync_all()?;
    fs::rename(&temporary, path)?;
    sync_parent_directory(path)?;
    Ok(())
}

/// Restores every crash-interrupted output transaction before a new profile
/// starts. Journal entries are written before renaming workspace files, so a
/// power loss cannot strand the sole copy inside a staging directory.
pub fn recover_workspace_transactions(repo: &Path, config: &LineageConfig) -> Result<()> {
    let repository_root = canonical_directory_without_symlinks(repo, "repository")?;
    let artifact_root = checked_relative_directory(
        &repository_root,
        &config.artifacts.directory,
        "Gigasail artifact store",
    )?;
    let runs = artifact_root.join("runs");
    if !runs.exists() {
        return Ok(());
    }
    let runs_root =
        checked_relative_directory(&artifact_root, Path::new("runs"), "Gigasail run store")?;
    let declared_outputs = declared_workspace_outputs(config)?;
    for entry in fs::read_dir(&runs)?.filter_map(std::result::Result::ok) {
        let run = entry.path();
        let metadata = fs::symlink_metadata(&run)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            bail!(
                "Gigasail run {} must be a non-symlink directory",
                run.display()
            );
        }
        let run_name = run
            .file_name()
            .context("Gigasail run directory has no file name")?;
        let run_root =
            checked_relative_directory(&runs_root, Path::new(run_name), "Gigasail run directory")?;
        if run_root.parent() != Some(runs_root.as_path()) {
            bail!(
                "Gigasail run {} escapes the configured run store",
                run.display()
            );
        }
        let journal = run.join(WORKSPACE_TRANSACTION_JOURNAL);
        if !journal.exists() {
            continue;
        }
        let journal_metadata = fs::symlink_metadata(&journal)?;
        if journal_metadata.file_type().is_symlink() || !journal_metadata.is_file() {
            bail!(
                "workspace transaction journal {} must be a regular file",
                journal.display()
            );
        }
        let entries: Vec<WorkspaceJournalEntry> = serde_json::from_slice(&fs::read(&journal)?)
            .with_context(|| {
                format!("parse workspace transaction journal {}", journal.display())
            })?;
        let outputs = entries
            .iter()
            .map(|entry| {
                recover_journal_entry(&repository_root, &run_root, &declared_outputs, entry)
            })
            .collect::<Result<Vec<_>>>()?;
        for output in outputs.iter().rev() {
            if output.original_present {
                if output.backup.exists() {
                    if fs::symlink_metadata(&output.source).is_ok() {
                        fs::remove_file(&output.source)?;
                    }
                    if let Some(parent) = output.source.parent() {
                        fs::create_dir_all(parent)?;
                    }
                    fs::rename(&output.backup, &output.source)?;
                }
            } else if output.source.exists() {
                fs::remove_file(&output.source)?;
            }
        }
        let backup_root = run.join("preexisting");
        if backup_root.exists() {
            fs::remove_dir_all(&backup_root)?;
        }
        fs::remove_file(&journal)?;
        sync_parent_directory(&journal)?;
    }
    Ok(())
}

fn declared_workspace_outputs(config: &LineageConfig) -> Result<BTreeMap<PathBuf, PathBuf>> {
    let mut outputs = BTreeMap::new();
    for (producer_name, producer) in &config.producers {
        for (index, artifact) in producer.produces.iter().enumerate() {
            validate_relative_path(&artifact.path, "declared artifact path")?;
            let backup = PathBuf::from("preexisting")
                .join(producer_name)
                .join(format!(
                    "{index}-{}",
                    artifact
                        .path
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                ));
            if outputs.insert(artifact.path.clone(), backup).is_some() {
                bail!(
                    "duplicate declared workspace artifact {}",
                    artifact.path.display()
                );
            }
        }
    }
    Ok(outputs)
}

fn recover_journal_entry(
    repository_root: &Path,
    run_root: &Path,
    declared_outputs: &BTreeMap<PathBuf, PathBuf>,
    entry: &WorkspaceJournalEntry,
) -> Result<QuarantinedOutput> {
    validate_relative_path(&entry.source, "workspace transaction source")?;
    validate_relative_path(&entry.backup, "workspace transaction backup")?;
    declared_outputs.get(&entry.source).with_context(|| {
        format!(
            "workspace transaction source {} is not a declared artifact",
            entry.source.display()
        )
    })?;
    // The backup label includes the producing configuration key only to make
    // an interrupted run inspectable. A later configuration may rename that
    // producer while retaining the same workspace output path; recovery must
    // still restore that known output. Source membership and the constrained
    // run-relative `preexisting/` path below are the security boundary.
    if entry
        .backup
        .components()
        .next()
        .is_none_or(|part| part.as_os_str() != "preexisting")
    {
        bail!("workspace transaction backup must be below preexisting/");
    }
    let source = resolve_relative_path(
        repository_root,
        &entry.source,
        "workspace transaction source",
    )?;
    let backup = resolve_relative_path(run_root, &entry.backup, "workspace transaction backup")?;
    Ok(QuarantinedOutput {
        source,
        backup,
        original_present: entry.original_present,
    })
}

fn resolve_relative_path(root: &Path, relative: &Path, label: &str) -> Result<PathBuf> {
    validate_relative_path(relative, label)?;
    let parent = relative.parent().unwrap_or_else(|| Path::new(""));
    checked_relative_directory(root, parent, label)?;
    Ok(root.join(relative))
}

fn canonical_directory_without_symlinks(path: &Path, label: &str) -> Result<PathBuf> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect {label} {}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        bail!("{label} {} must be a non-symlink directory", path.display());
    }
    let canonical = path
        .canonicalize()
        .with_context(|| format!("canonicalize {label} {}", path.display()))?;
    Ok(canonical)
}

fn checked_relative_directory(root: &Path, relative: &Path, label: &str) -> Result<PathBuf> {
    if relative.as_os_str().is_empty() {
        return canonical_directory_without_symlinks(root, label);
    }
    validate_relative_path(relative, label)?;
    let mut current = canonical_directory_without_symlinks(root, label)?;
    for component in relative.components() {
        let Component::Normal(name) = component else {
            continue;
        };
        current.push(name);
        let metadata = match fs::symlink_metadata(&current) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => break,
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("inspect {label} ancestor {}", current.display()))
            }
        };
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            bail!(
                "{label} ancestor {} must be a non-symlink directory",
                current.display()
            );
        }
    }
    Ok(current)
}

fn create_checked_relative_directory(root: &Path, relative: &Path, label: &str) -> Result<PathBuf> {
    if relative.as_os_str().is_empty() {
        return canonical_directory_without_symlinks(root, label);
    }
    validate_relative_path(relative, label)?;
    let mut current = canonical_directory_without_symlinks(root, label)?;
    for component in relative.components() {
        let Component::Normal(name) = component else {
            continue;
        };
        current.push(name);
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
                bail!(
                    "{label} ancestor {} must be a non-symlink directory",
                    current.display()
                );
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&current)
                    .with_context(|| format!("create {label} {}", current.display()))?;
            }
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("inspect {label} ancestor {}", current.display()));
            }
        }
    }
    Ok(current)
}

fn sync_parent_directory(path: &Path) -> Result<()> {
    #[cfg(unix)]
    fs::File::open(path.parent().context("path has no parent")?)?.sync_all()?;
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

fn rollback_partial_quarantine(
    quarantined: &[QuarantinedOutput],
    backup_root: &Path,
) -> Result<()> {
    restore_quarantined_outputs(quarantined)?;
    if backup_root.exists() {
        fs::remove_dir_all(backup_root)
            .with_context(|| format!("remove partial quarantine {}", backup_root.display()))?;
    }
    Ok(())
}

fn restore_quarantined_outputs(quarantined: &[QuarantinedOutput]) -> Result<()> {
    for output in quarantined.iter().rev() {
        if output.backup.exists() {
            fs::rename(&output.backup, &output.source)?;
        }
    }
    Ok(())
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
    observed_tree_fingerprint: Option<&str>,
) -> Result<RunManifest> {
    let tree_fingerprint = if let Some(fingerprint) = observed_tree_fingerprint {
        fingerprint.to_string()
    } else if revision == crate::git::WORKTREE_REVISION {
        working_tree_fingerprint(repo, &config.artifacts.directory, &BTreeSet::new())?
    } else {
        revision.to_string()
    };
    Ok(RunManifest {
        version: RUN_MANIFEST_VERSION.into(),
        revision: revision.into(),
        profile: profile_name.into(),
        repository_identity: repository_identity(repo),
        tree_fingerprint,
        started_at_unix_ms,
        duration_ms,
        status,
        configuration_hash: configuration_fingerprint(config)?,
        producers,
        artifacts,
    })
}

/// Identifies the exact checkout consumed by a WORKTREE analysis run.  The
/// synthetic `WORKTREE` revision names a moving target, so it is never a
/// sufficient provenance identity on its own.  Hash status kind, path, and
/// current file content for every non-ignored change, anchored to HEAD.
fn working_tree_fingerprint(
    repo: &Path,
    gigasail_directory: &Path,
    declared_outputs: &BTreeSet<PathBuf>,
) -> Result<String> {
    let repository = git2::Repository::discover(repo).with_context(|| {
        format!(
            "open repository for worktree fingerprint {}",
            repo.display()
        )
    })?;
    let head = repository
        .head()
        .ok()
        .and_then(|head| head.peel_to_commit().ok())
        .map(|commit| commit.id().to_string())
        .unwrap_or_else(|| "EMPTY".to_string());
    let workdir = repository
        .workdir()
        .context("bare repositories do not have a working-tree fingerprint")?;
    let repository_root = repo
        .canonicalize()
        .with_context(|| format!("canonicalize analysis repository {}", repo.display()))?;
    let repository_prefix = repository_root
        .strip_prefix(workdir)
        .ok()
        .filter(|path| !path.as_os_str().is_empty())
        .map(|path| path.to_string_lossy().replace('\\', "/"));
    let mut options = git2::StatusOptions::new();
    options
        .include_untracked(true)
        .recurse_untracked_dirs(true)
        .include_ignored(false)
        .renames_head_to_index(true)
        .renames_index_to_workdir(true);
    let gigasail_root = gigasail_directory
        .components()
        .next()
        .map(|component| component.as_os_str().to_string_lossy().replace('\\', "/"))
        .map(|root| match &repository_prefix {
            Some(prefix) => format!("{prefix}/{root}"),
            None => root,
        });
    let declared_outputs = declared_outputs
        .iter()
        .map(|path| {
            let path = path.to_string_lossy().replace('\\', "/");
            match &repository_prefix {
                Some(prefix) => format!("{prefix}/{path}"),
                None => path,
            }
        })
        .collect::<BTreeSet<_>>();
    let mut changes = repository
        .statuses(Some(&mut options))?
        .iter()
        .filter_map(|entry| {
            entry
                .path()
                .map(|path| (path.replace('\\', "/"), entry.status().bits()))
        })
        .filter(|(path, _)| {
            gigasail_root
                .as_ref()
                .is_none_or(|root| path != root && !path.starts_with(&format!("{root}/")))
        })
        .filter(|(path, _)| !declared_outputs.contains(path))
        .collect::<Vec<_>>();
    changes.sort();

    let mut fingerprint = Sha256::new();
    fingerprint.update(b"gigasail-worktree-fingerprint-v1\0");
    fingerprint.update(head.as_bytes());
    // Include the index object IDs as well as worktree bytes. Analysis reads
    // the worktree, but a staged-only change is still part of the developer's
    // dirty tree and must not share provenance with another staged state.
    fingerprint.update(b"\0index\0");
    for entry in repository.index()?.iter() {
        fingerprint.update(&entry.path);
        fingerprint.update(entry.id.as_bytes());
        fingerprint.update(entry.mode.to_le_bytes());
    }
    for (path, status) in changes {
        fingerprint.update(b"\0path\0");
        fingerprint.update(path.as_bytes());
        fingerprint.update(status.to_le_bytes());
        update_fingerprint_for_workspace_path(&mut fingerprint, &workdir.join(path))?;
    }
    Ok(format!("worktree:{}", hex::encode(fingerprint.finalize())))
}

fn update_fingerprint_for_workspace_path(fingerprint: &mut Sha256, path: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fingerprint.update(b"\0missing");
            return Ok(());
        }
        Err(error) => return Err(error).with_context(|| format!("stat {}", path.display())),
    };
    if metadata.file_type().is_symlink() {
        fingerprint.update(b"\0symlink\0");
        fingerprint.update(fs::read_link(path)?.to_string_lossy().as_bytes());
        return Ok(());
    }
    if !metadata.is_file() {
        fingerprint.update(b"\0non-file");
        return Ok(());
    }
    fingerprint.update(b"\0file\0");
    let mut file = fs::File::open(path)?;
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        fingerprint.update(&buffer[..read]);
    }
    Ok(())
}

fn write_manifest(run_directory: &Path, manifest: &RunManifest) -> Result<()> {
    fs::write(
        run_directory.join("manifest.json"),
        serde_json::to_vec_pretty(manifest)?,
    )?;
    Ok(())
}

fn retain_failed_run(repo: &Path, config: &LineageConfig, staged: &Path) -> Result<()> {
    let runs = repo.join(&config.artifacts.directory).join("runs");
    let name = staged
        .file_name()
        .and_then(|name| name.to_str())
        .context("staged run directory has no valid file name")?;
    let failed = runs.join(format!("failed-{}", name.trim_start_matches(".staging-")));
    fs::rename(staged, &failed)
        .with_context(|| format!("retain failed Gigasail run {}", staged.display()))?;
    prune_retained_runs(repo, config)?;
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

fn finalize_run(
    repo: &Path,
    config: &LineageConfig,
    staged: &Path,
    kind: ProfileRunKind,
) -> Result<PathBuf> {
    let root = repo.join(&config.artifacts.directory);
    let runs = root.join("runs");
    let run_name = staged
        .file_name()
        .and_then(|name| name.to_str())
        .context("staged run directory has no valid file name")?;
    let prefix = match kind {
        ProfileRunKind::CiPublication => "pending-",
        ProfileRunKind::StandaloneAnalysis => "analysis-",
    };
    let completed = runs.join(format!(
        "{prefix}{}",
        run_name.trim_start_matches(".staging-")
    ));
    fs::rename(staged, &completed)
        .with_context(|| format!("finalize staged Gigasail run {}", staged.display()))?;
    if kind == ProfileRunKind::StandaloneAnalysis {
        prune_retained_runs(repo, config)?;
    }
    Ok(completed)
}

/// Atomically updates the `latest` pointer after the completed run has been
/// ingested successfully. This operation is deliberately idempotent for a
/// `published-*` directory: startup recovery can finish publication after a
/// crash between the directory rename and the `latest` pointer replacement.
pub fn publish_run(repo: &Path, config: &LineageConfig, completed: &Path) -> Result<()> {
    let root = repo.join(&config.artifacts.directory);
    let runs = root.join("runs");
    let completed_name = completed
        .file_name()
        .and_then(|name| name.to_str())
        .context("completed run directory has no valid file name")?;
    // The completed run must live directly in the configured run store. Compare
    // canonically as well, so a relative `--repo` (which makes `runs` relative)
    // still matches a run directory whose path was resolved to an absolute form
    // upstream.
    let in_store = completed.parent().is_some_and(|parent| {
        parent == runs
            || matches!(
                (parent.canonicalize(), runs.canonicalize()),
                (Ok(parent), Ok(runs)) if parent == runs
            )
    });
    if !in_store {
        bail!(
            "completed run {} is not in the configured run store",
            completed.display()
        );
    }

    let published_name = if let Some(name) = completed_name.strip_prefix("pending-") {
        let published = runs.join(format!("published-{name}"));
        fs::rename(completed, &published)
            .with_context(|| format!("publish completed Gigasail run {}", completed.display()))?;
        name
    } else if let Some(name) = completed_name.strip_prefix("published-") {
        name
    } else {
        bail!("only pending or published runs can be published")
    };
    let latest = latest_run_directory(repo, config);
    let temporary_link = root.join(format!(".latest-{published_name}"));
    if fs::symlink_metadata(&temporary_link).is_ok() {
        fs::remove_file(&temporary_link).with_context(|| {
            format!(
                "remove stale temporary latest link {}",
                temporary_link.display()
            )
        })?;
    }
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(
            Path::new("runs").join(format!("published-{published_name}")),
            &temporary_link,
        )?;
    }
    #[cfg(not(unix))]
    {
        // Windows does not permit the inexpensive symlink publication used on
        // Unix. Keep the completed run immutable and require a platform
        // specific publisher rather than destructively replacing `latest`.
        bail!("atomic Gigasail run publication is currently supported on Unix hosts");
    }
    if let Ok(metadata) = fs::symlink_metadata(&latest) {
        if !metadata.file_type().is_symlink() {
            let legacy = runs.join(format!("legacy-{published_name}"));
            fs::rename(&latest, &legacy).with_context(|| {
                format!("preserve legacy latest Gigasail run {}", latest.display())
            })?;
        }
    }
    fs::rename(&temporary_link, &latest)
        .with_context(|| format!("atomically publish latest Gigasail run {}", latest.display()))?;
    sync_parent_directory(&latest)?;
    prune_retained_runs(repo, config)?;
    Ok(())
}

fn prune_retained_runs(repo: &Path, config: &LineageConfig) -> Result<()> {
    let root = repo.join(&config.artifacts.directory);
    let runs = root.join("runs");
    let latest = latest_run_directory(repo, config).canonicalize().ok();
    prune_run_kind(
        &runs,
        "published-",
        config.artifacts.retain_runs,
        latest.as_deref(),
    )?;
    prune_run_kind(&runs, "failed-", config.artifacts.retain_runs, None)?;
    prune_run_kind(&runs, "analysis-", config.artifacts.retain_runs, None)?;
    prune_run_kind(&runs, "legacy-", config.artifacts.retain_runs, None)?;
    prune_abandoned_runs(
        &runs,
        Duration::from_secs(config.artifacts.stale_run_age_seconds),
    )
}

fn prune_run_kind(
    runs: &Path,
    prefix: &str,
    retain_runs: usize,
    protected: Option<&Path>,
) -> Result<()> {
    let mut completed = fs::read_dir(runs)?
        .filter_map(std::result::Result::ok)
        .filter_map(|entry| {
            let metadata = fs::symlink_metadata(entry.path()).ok()?;
            (entry.file_name().to_string_lossy().starts_with(prefix)
                && !metadata.file_type().is_symlink()
                && metadata.is_dir()
                && protected.is_none_or(|path| entry.path() != path))
            .then_some((metadata.modified().ok()?, entry.path()))
        })
        .collect::<Vec<_>>();
    completed.sort_by(|left, right| right.0.cmp(&left.0));
    let keep = retain_runs.saturating_sub(usize::from(protected.is_some()));
    for (_, path) in completed.into_iter().skip(keep) {
        remove_retained_run(&path)?;
    }
    Ok(())
}

fn prune_abandoned_runs(runs: &Path, stale_age: Duration) -> Result<()> {
    let now = SystemTime::now();
    for entry in fs::read_dir(runs)?.filter_map(std::result::Result::ok) {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !(name.starts_with(".staging-") || name.starts_with("pending-")) {
            continue;
        }
        // A journal is the sole durable record of quarantined workspace
        // outputs. It must be recovered before any stale-run policy may
        // delete the directory containing its backups.
        if entry.path().join(WORKSPACE_TRANSACTION_JOURNAL).exists() {
            continue;
        }
        let metadata = fs::symlink_metadata(entry.path())?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            continue;
        }
        let stale = metadata
            .modified()
            .ok()
            .and_then(|modified| now.duration_since(modified).ok())
            .is_some_and(|age| age >= stale_age);
        if stale {
            fs::remove_dir_all(entry.path()).with_context(|| {
                format!("prune abandoned Gigasail run {}", entry.path().display())
            })?;
        }
    }
    Ok(())
}

fn execute_producer(
    repo: &Path,
    name: &str,
    producer: &EvidenceProducer,
    run_directory: &Path,
) -> Result<ProducerRun> {
    if producer.executor == ProducerExecutor::Gigasail {
        return execute_gigasail_provider(repo, name, producer, run_directory);
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
    #[cfg(unix)]
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == 0 {
                Ok(())
            } else {
                Err(std::io::Error::last_os_error())
            }
        });
    }
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
    let (output_sender, output_receiver) = mpsc::channel();
    let stdout_sender = output_sender.clone();
    thread::spawn(move || {
        let _ = stdout_sender.send(("stdout", read_bounded_output(stdout, max_output_bytes)));
    });
    thread::spawn(move || {
        let _ = output_sender.send(("stderr", read_bounded_output(stderr, max_output_bytes)));
    });
    let deadline = Instant::now() + Duration::from_secs(producer.timeout_seconds);
    let mut timed_out = false;
    let mut group_terminated = false;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            group_terminated = terminate_process_tree(&mut child);
            timed_out = true;
            break child.wait()?;
        }
        thread::sleep(Duration::from_millis(10));
    };
    // A shell can exit before background descendants. Those descendants keep
    // our output pipes open, so treat the producer process group—not merely
    // its leader—as the lifecycle boundary.
    if !group_terminated && process_group_alive(child.id()) {
        group_terminated = terminate_process_group(child.id());
    }
    let mut stdout = None;
    let mut stderr = None;
    while stdout.is_none() || stderr.is_none() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match output_receiver.recv_timeout(remaining) {
            Ok(("stdout", result)) => stdout = Some(result),
            Ok(("stderr", result)) => stderr = Some(result),
            Ok(_) => unreachable!("only stdout and stderr readers are registered"),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if !group_terminated {
                    let _ = terminate_process_tree(&mut child);
                }
                timed_out = true;
                break;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    let stdout = stdout.unwrap_or_else(|| {
        Err(anyhow::anyhow!(
            "producer stdout did not close before deadline"
        ))
    });
    let stderr = stderr.unwrap_or_else(|| {
        Err(anyhow::anyhow!(
            "producer stderr did not close before deadline"
        ))
    });
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
    let (outcome, failure) = if timed_out {
        (
            ProducerOutcome::TimedOut,
            Some(format!(
                "exceeded configured {} second timeout",
                producer.timeout_seconds
            )),
        )
    } else if output_exceeded {
        (
            ProducerOutcome::OutputLimited,
            Some("exceeded configured output limit".into()),
        )
    } else if !status.success() {
        (
            ProducerOutcome::Failed,
            Some(format!("exited with {status}")),
        )
    } else {
        (ProducerOutcome::Succeeded, None)
    };
    Ok(ProducerRun {
        name: name.into(),
        argv: producer.argv.clone(),
        tool_version: String::new(),
        working_directory: producer
            .working_directory
            .clone()
            .unwrap_or_else(|| PathBuf::from(".")),
        settings_hash: hex::encode(Sha256::digest(serde_json::to_vec(producer)?)),
        started_at_unix_ms,
        duration_ms: started.elapsed().as_millis(),
        exit_status: status.code(),
        outcome,
        failure,
        stdout_log: PathBuf::from("logs").join(format!("{name}.stdout")),
        stderr_log: PathBuf::from("logs").join(format!("{name}.stderr")),
    })
}

/// Executes an embedded Gigasail provider. The enum deliberately does *not*
/// resolve arbitrary executables from PATH: configuration is data, and a
/// `gigasail` executor must remain an auditable, constrained capability.
fn execute_gigasail_provider(
    repo: &Path,
    name: &str,
    producer: &EvidenceProducer,
    run_directory: &Path,
) -> Result<ProducerRun> {
    let started_at_unix_ms = unix_time_ms()?;
    let started = Instant::now();
    let logs = run_directory.join("logs");
    fs::create_dir_all(&logs)?;
    let stdout_log = PathBuf::from("logs").join(format!("{name}.stdout"));
    let stderr_log = PathBuf::from("logs").join(format!("{name}.stderr"));
    if producer.argv.as_slice() == ["fact-mine-native"] {
        let repository = repo.to_path_buf();
        let (outcome, failure, exit_status, stats) =
            match run_bounded_work(Duration::from_secs(producer.timeout_seconds), move || {
                build_fact_mine_sarif(&repository)
            })? {
                Some((stats, document)) => {
                    write_fact_mine_sarif(repo, producer, &document)?;
                    (ProducerOutcome::Succeeded, None, Some(0), Some(stats))
                }
                None => (
                    ProducerOutcome::TimedOut,
                    Some(format!(
                        "embedded FactMine exceeded configured {} second timeout",
                        producer.timeout_seconds
                    )),
                    None,
                    None,
                ),
            };
        fs::write(
            logs.join(format!("{name}.stdout")),
            stats
                .map(|stats| {
                    format!(
                "FactMine {} scanned source file(s), emitted {} static hazard finding(s){}\n",
                stats.scanned_files,
                stats.findings,
                if stats.truncated { "; stopped at the static-analysis budget" } else { "" },
            )
                })
                .unwrap_or_else(|| {
                    "FactMine timed out before producing a SARIF artifact\n".to_string()
                }),
        )?;
        fs::write(
            logs.join(format!("{name}.stderr")),
            failure.as_deref().unwrap_or("").as_bytes(),
        )?;
        return Ok(ProducerRun {
            name: name.into(),
            argv: producer.argv.clone(),
            tool_version: embedded_fact_mine_version(),
            working_directory: producer
                .working_directory
                .clone()
                .unwrap_or_else(|| PathBuf::from(".")),
            settings_hash: hex::encode(Sha256::digest(serde_json::to_vec(producer)?)),
            started_at_unix_ms,
            duration_ms: started.elapsed().as_millis(),
            exit_status,
            outcome,
            failure,
            stdout_log,
            stderr_log,
        });
    }
    unreachable!("configuration validation restricts embedded providers")
}

/// Runs read-only embedded analysis behind a wall-clock boundary. A late
/// worker can never write an artifact: only the caller publishes a completed
/// result after receiving it before the deadline.
fn run_bounded_work<T, F>(timeout: Duration, work: F) -> Result<Option<T>>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T> + Send + 'static,
{
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let _ = sender.send(work());
    });
    match receiver.recv_timeout(timeout) {
        Ok(result) => result.map(Some),
        Err(mpsc::RecvTimeoutError::Timeout) => Ok(None),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            bail!("embedded analysis worker terminated unexpectedly")
        }
    }
}

const MAX_FACT_MINE_SOURCE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_FACT_MINE_FILES: usize = 25_000;
const MAX_FACT_MINE_TOTAL_SOURCE_BYTES: u64 = 256 * 1024 * 1024;

#[derive(Debug, Default)]
struct FactMineRunStats {
    scanned_files: usize,
    scanned_bytes: u64,
    findings: usize,
    truncated: bool,
    unreadable_files: usize,
    oversized_files: usize,
}

/// The FactMine provider is linked into Gigasail and is therefore safe to run
/// in an unconfigured repository. It deliberately reports source-derived
/// hazards as *partial* SARIF: static syntax can prove a site exists, never
/// that a dynamic risk is absent.
#[cfg(test)]
fn run_builtin_fact_mine(repo: &Path, producer: &EvidenceProducer) -> Result<FactMineRunStats> {
    let (stats, document) = build_fact_mine_sarif(repo)?;
    write_fact_mine_sarif(repo, producer, &document)?;
    Ok(stats)
}

fn build_fact_mine_sarif(repo: &Path) -> Result<(FactMineRunStats, Vec<u8>)> {
    let mut findings = Vec::new();
    let mut stats = FactMineRunStats::default();
    let repository = git2::Repository::open(repo).ok();
    collect_fact_mine_findings(repo, repo, repository.as_ref(), &mut findings, &mut stats)?;
    let document = serde_json::json!({
        "version": "2.1.0",
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "runs": [{
            "tool": {"driver": {"name": "FactMine", "informationUri": "https://github.com/cuzzo/clear"}},
            "properties": {
                "gigasail.analysis_complete": false,
                "gigasail.provider_capability": "bounded-syntax-hazard-scan",
                "gigasail.proof_boundary": fact_mine_proof_boundary(&stats),
                "gigasail.scanned_files": stats.scanned_files,
                "gigasail.scanned_bytes": stats.scanned_bytes,
                "gigasail.unreadable_files": stats.unreadable_files,
                "gigasail.oversized_files": stats.oversized_files,
            },
            "results": findings,
        }],
    });
    stats.findings = document["runs"][0]["results"]
        .as_array()
        .map_or(0, Vec::len);
    Ok((stats, serde_json::to_vec_pretty(&document)?))
}

fn write_fact_mine_sarif(repo: &Path, producer: &EvidenceProducer, document: &[u8]) -> Result<()> {
    let output = producer
        .produces
        .iter()
        .find(|artifact| artifact.kind == ArtifactKind::Sarif)
        .with_context(|| "the built-in fact-mine provider requires a declared SARIF output")?;
    let output_path = repo.join(&output.path);
    if let Some(parent) = output_path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&output_path, document)
        .with_context(|| format!("write FactMine SARIF {}", output_path.display()))
}

fn embedded_fact_mine_version() -> String {
    const FACT_MINE_MANIFEST: &str = include_str!("../../../fact-mine/Cargo.toml");
    let version = FACT_MINE_MANIFEST
        .lines()
        .skip_while(|line| line.trim() != "[package]")
        .find_map(|line| line.trim().strip_prefix("version = "))
        .map(|value| value.trim_matches('"'))
        .unwrap_or("unknown");
    format!(
        "fact-mine-rust/{version};gigasail/{}",
        env!("CARGO_PKG_VERSION")
    )
}

fn collect_fact_mine_findings(
    repo: &Path,
    directory: &Path,
    repository: Option<&git2::Repository>,
    findings: &mut Vec<serde_json::Value>,
    stats: &mut FactMineRunStats,
) -> Result<()> {
    if stats.truncated {
        return Ok(());
    }
    let mut entries = fs::read_dir(directory)?.collect::<std::result::Result<Vec<_>, _>>()?;
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        if stats.truncated {
            break;
        }
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() {
            continue;
        }
        let relative_path = path
            .strip_prefix(repo)
            .expect("walked source path is inside repository")
            .to_string_lossy()
            .replace('\\', "/");
        if !crate::extract::SourceFilter::code_defaults().supports_path(&relative_path)
            && !metadata.is_dir()
        {
            continue;
        }
        if repository.is_some_and(|repository| {
            repository
                .status_file(Path::new(&relative_path))
                .is_ok_and(|status| status.contains(git2::Status::IGNORED))
        }) {
            continue;
        }
        if metadata.is_dir() {
            let directory_marker = format!("{relative_path}/placeholder.rs");
            if crate::extract::SourceFilter::code_defaults().supports_path(&directory_marker) {
                collect_fact_mine_findings(repo, &path, repository, findings, stats)?;
            }
            continue;
        }
        if !metadata.is_file() {
            continue;
        }
        if metadata.len() > MAX_FACT_MINE_SOURCE_BYTES {
            stats.oversized_files += 1;
            continue;
        }
        let Some(language) = fact_mine_rust::syntax::Language::for_path(&path) else {
            continue;
        };
        if stats.scanned_files >= MAX_FACT_MINE_FILES
            || stats.scanned_bytes.saturating_add(metadata.len()) > MAX_FACT_MINE_TOTAL_SOURCE_BYTES
        {
            stats.truncated = true;
            continue;
        }
        let source = match fs::read_to_string(&path) {
            Ok(source) => source,
            Err(_) => {
                stats.unreadable_files += 1;
                continue;
            }
        };
        stats.scanned_files += 1;
        stats.scanned_bytes += metadata.len();
        let relative = path
            .strip_prefix(repo)
            .expect("walked source path is inside repository")
            .to_string_lossy()
            .replace('\\', "/");
        for hazard in
            fact_mine_rust::syntax::hazards::extract_file_hazards(&relative, &source, language)
        {
            let fingerprint = hex::encode(Sha256::digest(format!(
                "{}:{}:{}:{}",
                relative, hazard.line, hazard.hazard_type, hazard.snippet
            )));
            findings.push(serde_json::json!({
                "ruleId": format!("fact-mine.{}", hazard.hazard_type),
                "level": "warning",
                "message": {"text": format!(
                    "{} (required evidence: {})",
                    hazard.hazard_type,
                    if hazard.required_evidence.is_empty() { "review" } else { &hazard.required_evidence },
                )},
                "partialFingerprints": {"gigasail/v1": fingerprint},
                "properties": {
                    "category": "static-hazard",
                    "required_evidence": hazard.required_evidence,
                    "hazard_kind": hazard.hazard_kind,
                    "provider": "fact-mine",
                },
                "locations": [{"physicalLocation": {
                    "artifactLocation": {"uri": relative},
                    "region": {"startLine": hazard.line.max(1), "endLine": hazard.end_line.unwrap_or(hazard.line).max(1)},
                }}],
            }));
        }
    }
    Ok(())
}

fn fact_mine_proof_boundary(stats: &FactMineRunStats) -> Vec<String> {
    let mut boundaries = vec![
        "static findings are partial evidence and cannot prove absence of runtime risk".to_string(),
    ];
    if stats.truncated {
        boundaries.push(
            "analysis budget exhausted before every eligible source file was scanned".to_string(),
        );
    }
    if stats.unreadable_files > 0 {
        boundaries.push(format!(
            "{} eligible source file(s) could not be read",
            stats.unreadable_files
        ));
    }
    if stats.oversized_files > 0 {
        boundaries.push(format!(
            "{} source file(s) exceeded the per-file analysis limit",
            stats.oversized_files
        ));
    }
    boundaries
}

fn unstarted_failed_producer_run(
    name: &str,
    producer: &EvidenceProducer,
    failure: String,
) -> Result<ProducerRun> {
    Ok(ProducerRun {
        name: name.into(),
        argv: producer.argv.clone(),
        tool_version: String::new(),
        working_directory: producer
            .working_directory
            .clone()
            .unwrap_or_else(|| PathBuf::from(".")),
        settings_hash: hex::encode(Sha256::digest(serde_json::to_vec(producer)?)),
        started_at_unix_ms: unix_time_ms()?,
        duration_ms: 0,
        exit_status: None,
        outcome: ProducerOutcome::Failed,
        failure: Some(failure),
        stdout_log: PathBuf::from("logs").join(format!("{name}.stdout")),
        stderr_log: PathBuf::from("logs").join(format!("{name}.stderr")),
    })
}

fn terminate_process_tree(child: &mut std::process::Child) -> bool {
    #[cfg(unix)]
    {
        terminate_process_group(child.id())
    }
    #[cfg(not(unix))]
    {
        child.kill().is_ok()
    }
}

fn process_group_alive(pid: u32) -> bool {
    #[cfg(unix)]
    unsafe {
        let process_group = -(pid as i32);
        libc::kill(process_group, 0) == 0
            || std::io::Error::last_os_error().kind() == std::io::ErrorKind::PermissionDenied
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        false
    }
}

fn terminate_process_group(pid: u32) -> bool {
    #[cfg(unix)]
    unsafe {
        let process_group = -(pid as i32);
        if libc::kill(process_group, 0) != 0 {
            return false;
        }
        if libc::kill(process_group, libc::SIGTERM) != 0 {
            return false;
        }
        let grace_deadline = Instant::now() + Duration::from_millis(100);
        while Instant::now() < grace_deadline {
            if !process_group_alive(pid) {
                return true;
            }
            thread::sleep(Duration::from_millis(10));
        }
        if process_group_alive(pid) {
            let _ = libc::kill(process_group, libc::SIGKILL);
        }
        true
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        false
    }
}

fn stage_artifact(
    repo: &Path,
    run_directory: &Path,
    producer: &str,
    index: usize,
    artifact: &ProducedArtifact,
    compression: ArtifactCompression,
) -> Result<ManifestArtifact> {
    let repository_root = canonical_directory_without_symlinks(repo, "repository")?;
    let source = resolve_relative_path(&repository_root, &artifact.path, "declared artifact path")?;
    let canonical_source = source
        .canonicalize()
        .with_context(|| format!("canonicalize artifact {}", source.display()))?;
    if !canonical_source.starts_with(&repository_root) {
        bail!(
            "artifact {} escapes repository through a symlink",
            artifact.path.display()
        );
    }
    let size = fs::metadata(&source)
        .with_context(|| format!("stat artifact {}", source.display()))?
        .len();
    if size > MAX_DECOMPRESSED_ARTIFACT_BYTES {
        bail!(
            "artifact {} exceeds {} byte staging limit",
            artifact.path.display(),
            MAX_DECOMPRESSED_ARTIFACT_BYTES
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

pub fn configuration_fingerprint(config: &LineageConfig) -> Result<String> {
    Ok(hex::encode(Sha256::digest(serde_json::to_vec(config)?)))
}

pub fn run_manifest_hash(manifest: &RunManifest) -> Result<String> {
    Ok(hex::encode(Sha256::digest(serde_json::to_vec(manifest)?)))
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
    // A project may keep the database, run store, and declared producer
    // outputs under one `.giga/` root. Keep the historical
    // `.giga/artifacts/` default, but do not force a split that makes the
    // database look like a source-tree mutation during subproject CI.
    let reserved = Path::new(".giga");
    if !path.starts_with(reserved) {
        bail!("artifacts.directory must be beneath {}", reserved.display());
    }
    Ok(())
}

/// Returns whether an identifier is safe to use as an on-disk namespace.
/// External manifests must apply the same rule as trusted configuration.
pub fn is_safe_identifier(value: &str) -> bool {
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
    PathBuf::from(".giga/artifacts")
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

fn default_retained_runs() -> usize {
    20
}

fn default_stale_run_age_seconds() -> u64 {
    24 * 60 * 60
}

fn not_applicable_mutant_corpus() -> String {
    "not-applicable".into()
}

fn unix_time_ms() -> Result<u128> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system time precedes Unix epoch")?
        .as_millis())
}

pub fn repository_identity(repo: &Path) -> String {
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
            directory.path().join(".giga/artifacts/latest")
        );
        assert_eq!(config.profiles["ci"].producers, ["coverage"]);
    }

    #[test]
    fn worktree_fingerprint_changes_with_dirty_source_and_untracked_files() {
        let directory = tempdir().unwrap();
        let repository = git2::Repository::init(directory.path()).unwrap();
        let signature = git2::Signature::now("Gigasail", "gigasail@example.test").unwrap();
        fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
        let mut index = repository.index().unwrap();
        index.add_path(Path::new("lib.rs")).unwrap();
        index.write().unwrap();
        let tree = repository.find_tree(index.write_tree().unwrap()).unwrap();
        repository
            .commit(Some("HEAD"), &signature, &signature, "initial", &tree, &[])
            .unwrap();

        let artifact_directory = Path::new(".giga/artifacts");
        let clean =
            working_tree_fingerprint(directory.path(), artifact_directory, &BTreeSet::new())
                .unwrap();
        fs::write(
            directory.path().join("lib.rs"),
            "pub unsafe fn value() {}\n",
        )
        .unwrap();
        let modified =
            working_tree_fingerprint(directory.path(), artifact_directory, &BTreeSet::new())
                .unwrap();
        let mut index = repository.index().unwrap();
        index.add_path(Path::new("lib.rs")).unwrap();
        index.write().unwrap();
        let staged =
            working_tree_fingerprint(directory.path(), artifact_directory, &BTreeSet::new())
                .unwrap();
        fs::write(directory.path().join("new.rs"), "pub fn added() {}\n").unwrap();
        let untracked =
            working_tree_fingerprint(directory.path(), artifact_directory, &BTreeSet::new())
                .unwrap();
        fs::create_dir_all(directory.path().join(".giga/artifacts")).unwrap();
        fs::write(
            directory.path().join(".giga/artifacts/transient.json"),
            "{}\n",
        )
        .unwrap();
        let with_gigasail_output =
            working_tree_fingerprint(directory.path(), artifact_directory, &BTreeSet::new())
                .unwrap();
        assert_ne!(clean, modified);
        assert_ne!(modified, staged);
        assert_ne!(modified, untracked);
        assert_eq!(untracked, with_gigasail_output);
        assert!(untracked.starts_with("worktree:"));
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
            .contains("both gigasail.yml"));
    }

    #[test]
    fn rejects_duplicate_profile_producers_and_output_paths() {
        let producer = |path: &str| EvidenceProducer {
            executor: ProducerExecutor::Command,
            argv: vec!["true".into()],
            working_directory: None,
            timeout_seconds: 1,
            max_output_bytes: 1024,
            environment: BTreeMap::new(),
            produces: vec![ProducedArtifact {
                kind: ArtifactKind::Coverage,
                format: "generic".into(),
                path: path.into(),
                scope: None,
                complete: false,
                evidence_scope: None,
            }],
        };
        let duplicate_profile = LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig::default(),
            profiles: BTreeMap::from([(
                "ci".into(),
                VerificationProfile {
                    producers: vec!["coverage".into(), "coverage".into()],
                    required_evidence: BTreeSet::new(),
                },
            )]),
            producers: BTreeMap::from([("coverage".into(), producer("coverage.json"))]),
        };
        assert!(validate_config(duplicate_profile)
            .unwrap_err()
            .to_string()
            .contains("more than once"));

        let duplicate_output = LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig::default(),
            profiles: BTreeMap::new(),
            producers: BTreeMap::from([
                ("coverage".into(), producer("result.json")),
                ("other".into(), producer("result.json")),
            ]),
        };
        assert!(validate_config(duplicate_output)
            .unwrap_err()
            .to_string()
            .contains("shared by producers"));
    }

    #[test]
    fn complete_coverage_and_sarif_scopes_do_not_require_a_mutant_corpus() {
        let config: LineageConfig = serde_yaml::from_str(
            "version: 1\nproducers:\n  coverage:\n    executor: command\n    argv: [true]\n    produces:\n      - kind: coverage\n        format: generic\n        path: coverage.json\n        complete: true\n        evidence_scope: {selection: full, test_set: unit}\n  mutants:\n    executor: command\n    argv: [true]\n    produces:\n      - kind: mutants\n        format: generic\n        path: mutants.json\n        complete: true\n        evidence_scope: {selection: full, test_set: unit}\n",
        )
        .unwrap();
        let error = validate_config(config).unwrap_err().to_string();
        assert!(error.contains("invalid evidence_scope"));

        let coverage_only: LineageConfig = serde_yaml::from_str(
            "version: 1\nproducers:\n  coverage:\n    executor: command\n    argv: [true]\n    produces:\n      - kind: coverage\n        format: generic\n        path: coverage.json\n        complete: true\n        evidence_scope: {selection: full, test_set: unit}\n",
        )
        .unwrap();
        let coverage_only = validate_config(coverage_only).unwrap();
        assert_eq!(
            coverage_only.producers["coverage"].produces[0]
                .evidence_scope
                .as_ref()
                .unwrap()
                .mutant_corpus,
            "not-applicable"
        );
    }

    #[test]
    fn profile_transaction_restores_all_preexisting_outputs_after_later_failure() {
        let directory = tempdir().unwrap();
        fs::create_dir_all(directory.path().join("out")).unwrap();
        fs::write(directory.path().join("out/coverage.json"), "old coverage").unwrap();
        fs::write(directory.path().join("out/mutants.json"), "old mutants").unwrap();
        let artifact = |kind, path: &str| ProducedArtifact {
            kind,
            format: "generic".into(),
            path: path.into(),
            scope: None,
            complete: false,
            evidence_scope: None,
        };
        let config = validate_config(LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig {
                compression: ArtifactCompression::None,
                ..ArtifactStoreConfig::default()
            },
            profiles: BTreeMap::from([(
                "ci".into(),
                VerificationProfile {
                    producers: vec!["coverage".into(), "mutants".into()],
                    required_evidence: BTreeSet::new(),
                },
            )]),
            producers: BTreeMap::from([
                (
                    "coverage".into(),
                    EvidenceProducer {
                        executor: ProducerExecutor::Command,
                        argv: vec![
                            "sh".into(),
                            "-c".into(),
                            "printf 'fresh coverage' > out/coverage.json".into(),
                        ],
                        working_directory: None,
                        timeout_seconds: 1,
                        max_output_bytes: 1024,
                        environment: BTreeMap::new(),
                        produces: vec![artifact(ArtifactKind::Coverage, "out/coverage.json")],
                    },
                ),
                (
                    "mutants".into(),
                    EvidenceProducer {
                        executor: ProducerExecutor::Command,
                        argv: vec!["false".into()],
                        working_directory: None,
                        timeout_seconds: 1,
                        max_output_bytes: 1024,
                        environment: BTreeMap::new(),
                        produces: vec![artifact(ArtifactKind::Mutants, "out/mutants.json")],
                    },
                ),
            ]),
        })
        .unwrap();

        assert!(ProfileExecutionSession::begin(directory.path(), &config)
            .unwrap()
            .execute("ci", "abc", ProfileRunKind::CiPublication)
            .is_err());
        assert_eq!(
            fs::read_to_string(directory.path().join("out/coverage.json")).unwrap(),
            "old coverage"
        );
        assert_eq!(
            fs::read_to_string(directory.path().join("out/mutants.json")).unwrap(),
            "old mutants"
        );
        let failed = directory
            .path()
            .join(".giga/artifacts/runs")
            .read_dir()
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .find(|path| {
                path.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("failed-")
            })
            .unwrap();
        assert!(!failed.join("preexisting").exists());
        let manifest = load_run_manifest(&failed.join("manifest.json")).unwrap();
        assert_eq!(manifest.producers.len(), 2);
        assert_eq!(manifest.producers[1].outcome, ProducerOutcome::Failed);
    }

    #[test]
    fn successful_profile_stages_fresh_output_and_restores_workspace_output() {
        let directory = tempdir().unwrap();
        fs::create_dir_all(directory.path().join("out")).unwrap();
        fs::write(directory.path().join("out/report.json"), "old").unwrap();
        let config = validate_config(LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig {
                compression: ArtifactCompression::None,
                ..ArtifactStoreConfig::default()
            },
            profiles: BTreeMap::from([(
                "ci".into(),
                VerificationProfile {
                    producers: vec!["coverage".into()],
                    required_evidence: BTreeSet::new(),
                },
            )]),
            producers: BTreeMap::from([(
                "coverage".into(),
                EvidenceProducer {
                    executor: ProducerExecutor::Command,
                    argv: vec![
                        "sh".into(),
                        "-c".into(),
                        "printf fresh > out/report.json".into(),
                    ],
                    working_directory: None,
                    timeout_seconds: 1,
                    max_output_bytes: 1024,
                    environment: BTreeMap::new(),
                    produces: vec![ProducedArtifact {
                        kind: ArtifactKind::Coverage,
                        format: "generic".into(),
                        path: "out/report.json".into(),
                        scope: None,
                        complete: false,
                        evidence_scope: None,
                    }],
                },
            )]),
        })
        .unwrap();

        let completed = ProfileExecutionSession::begin(directory.path(), &config)
            .unwrap()
            .execute("ci", "abc", ProfileRunKind::CiPublication)
            .unwrap();
        assert_eq!(
            fs::read_to_string(directory.path().join("out/report.json")).unwrap(),
            "old"
        );
        assert_eq!(
            read_manifest_artifact(&completed.directory, &completed.manifest.artifacts[0]).unwrap(),
            b"fresh"
        );
        assert!(!completed.directory.join("preexisting").exists());
    }

    #[test]
    fn partial_quarantine_failure_restores_already_moved_outputs() {
        let directory = tempdir().unwrap();
        let run = directory.path().join("run");
        fs::create_dir_all(directory.path().join("out")).unwrap();
        fs::write(directory.path().join("out/first.json"), "first").unwrap();
        fs::write(directory.path().join("out/second.json"), "second").unwrap();
        fs::create_dir_all(run.join("preexisting/producer/1-second.json")).unwrap();
        let config = LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig::default(),
            profiles: BTreeMap::from([(
                "ci".into(),
                VerificationProfile {
                    producers: vec!["producer".into()],
                    required_evidence: BTreeSet::new(),
                },
            )]),
            producers: BTreeMap::from([(
                "producer".into(),
                EvidenceProducer {
                    executor: ProducerExecutor::Command,
                    argv: vec!["true".into()],
                    working_directory: None,
                    timeout_seconds: 1,
                    max_output_bytes: 1024,
                    environment: BTreeMap::new(),
                    produces: ["first.json", "second.json"]
                        .into_iter()
                        .map(|name| ProducedArtifact {
                            kind: ArtifactKind::Coverage,
                            format: "generic".into(),
                            path: PathBuf::from("out").join(name),
                            scope: None,
                            complete: false,
                            evidence_scope: None,
                        })
                        .collect(),
                },
            )]),
        };

        assert!(quarantine_profile_outputs(
            directory.path(),
            &run,
            &config.profiles["ci"],
            &config
        )
        .is_err());
        assert_eq!(
            fs::read_to_string(directory.path().join("out/first.json")).unwrap(),
            "first"
        );
        assert_eq!(
            fs::read_to_string(directory.path().join("out/second.json")).unwrap(),
            "second"
        );
        assert!(!run.join("preexisting/producer/0-first.json").exists());
    }

    #[test]
    fn recovers_workspace_outputs_after_an_interrupted_quarantine() {
        let directory = tempdir().unwrap();
        let output = directory.path().join("out/report.json");
        fs::create_dir_all(output.parent().unwrap()).unwrap();
        fs::write(&output, "previous report").unwrap();
        let config = validate_config(LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig::default(),
            profiles: BTreeMap::from([(
                "ci".into(),
                VerificationProfile {
                    producers: vec!["coverage".into()],
                    required_evidence: BTreeSet::new(),
                },
            )]),
            producers: BTreeMap::from([(
                "coverage".into(),
                EvidenceProducer {
                    executor: ProducerExecutor::Command,
                    argv: vec!["true".into()],
                    working_directory: None,
                    timeout_seconds: 1,
                    max_output_bytes: 1024,
                    environment: BTreeMap::new(),
                    produces: vec![ProducedArtifact {
                        kind: ArtifactKind::Coverage,
                        format: "generic".into(),
                        path: "out/report.json".into(),
                        scope: None,
                        complete: false,
                        evidence_scope: None,
                    }],
                },
            )]),
        })
        .unwrap();
        let run = directory
            .path()
            .join(".giga/artifacts/runs/.staging-interrupted");
        fs::create_dir_all(&run).unwrap();
        let transaction =
            quarantine_profile_outputs(directory.path(), &run, &config.profiles["ci"], &config)
                .unwrap();
        assert!(!output.exists());
        std::mem::forget(transaction);

        recover_workspace_transactions(directory.path(), &config).unwrap();

        assert_eq!(fs::read_to_string(&output).unwrap(), "previous report");
        assert!(!run.join(WORKSPACE_TRANSACTION_JOURNAL).exists());
        assert!(!run.join("preexisting").exists());
    }

    #[test]
    fn recovery_removes_workspace_outputs_that_did_not_exist_before() {
        let directory = tempdir().unwrap();
        let config = validate_config(LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig::default(),
            profiles: BTreeMap::from([(
                "ci".into(),
                VerificationProfile {
                    producers: vec!["coverage".into()],
                    required_evidence: BTreeSet::new(),
                },
            )]),
            producers: BTreeMap::from([(
                "coverage".into(),
                EvidenceProducer {
                    executor: ProducerExecutor::Command,
                    argv: vec!["true".into()],
                    working_directory: None,
                    timeout_seconds: 1,
                    max_output_bytes: 1024,
                    environment: BTreeMap::new(),
                    produces: vec![ProducedArtifact {
                        kind: ArtifactKind::Coverage,
                        format: "generic".into(),
                        path: "out/new.json".into(),
                        scope: None,
                        complete: false,
                        evidence_scope: None,
                    }],
                },
            )]),
        })
        .unwrap();
        let run = directory
            .path()
            .join(".giga/artifacts/runs/.staging-interrupted");
        fs::create_dir_all(&run).unwrap();
        let transaction =
            quarantine_profile_outputs(directory.path(), &run, &config.profiles["ci"], &config)
                .unwrap();
        let generated = directory.path().join("out/new.json");
        fs::create_dir_all(generated.parent().unwrap()).unwrap();
        fs::write(&generated, "new").unwrap();
        std::mem::forget(transaction);

        recover_workspace_transactions(directory.path(), &config).unwrap();
        assert!(!generated.exists());
    }

    #[test]
    fn profile_transaction_removes_new_workspace_outputs_after_failure() {
        let directory = tempdir().unwrap();
        let artifact = |kind, path: &str| ProducedArtifact {
            kind,
            format: "generic".into(),
            path: path.into(),
            scope: None,
            complete: false,
            evidence_scope: None,
        };
        let config = validate_config(LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig::default(),
            profiles: BTreeMap::from([(
                "ci".into(),
                VerificationProfile {
                    producers: vec!["coverage".into(), "mutants".into()],
                    required_evidence: BTreeSet::new(),
                },
            )]),
            producers: BTreeMap::from([
                (
                    "coverage".into(),
                    EvidenceProducer {
                        executor: ProducerExecutor::Command,
                        argv: vec![
                            "sh".into(),
                            "-c".into(),
                            "mkdir -p out && printf fresh > out/coverage.json".into(),
                        ],
                        working_directory: None,
                        timeout_seconds: 1,
                        max_output_bytes: 1024,
                        environment: BTreeMap::new(),
                        produces: vec![artifact(ArtifactKind::Coverage, "out/coverage.json")],
                    },
                ),
                (
                    "mutants".into(),
                    EvidenceProducer {
                        executor: ProducerExecutor::Command,
                        argv: vec!["false".into()],
                        working_directory: None,
                        timeout_seconds: 1,
                        max_output_bytes: 1024,
                        environment: BTreeMap::new(),
                        produces: vec![artifact(ArtifactKind::Mutants, "out/mutants.json")],
                    },
                ),
            ]),
        })
        .unwrap();

        assert!(ProfileExecutionSession::begin(directory.path(), &config)
            .unwrap()
            .execute("ci", "abc", ProfileRunKind::CiPublication)
            .is_err());
        assert!(!directory.path().join("out/coverage.json").exists());
    }

    #[cfg(unix)]
    #[test]
    fn producer_timeout_kills_background_descendants_without_fixed_success_delay() {
        let directory = tempdir().unwrap();
        let producer = EvidenceProducer {
            executor: ProducerExecutor::Command,
            argv: vec!["sh".into(), "-c".into(), "sleep 5 &".into()],
            working_directory: None,
            timeout_seconds: 1,
            max_output_bytes: 1024,
            environment: BTreeMap::new(),
            produces: Vec::new(),
        };
        let run = directory.path().join("run");
        fs::create_dir_all(&run).unwrap();
        let started = Instant::now();
        let result = execute_producer(directory.path(), "background", &producer, &run).unwrap();
        assert_eq!(result.outcome, ProducerOutcome::Succeeded);
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[cfg(unix)]
    #[test]
    fn producer_timeout_records_timeout_and_returns_promptly() {
        let directory = tempdir().unwrap();
        let producer = EvidenceProducer {
            executor: ProducerExecutor::Command,
            argv: vec!["sh".into(), "-c".into(), "sleep 5".into()],
            working_directory: None,
            timeout_seconds: 1,
            max_output_bytes: 1024,
            environment: BTreeMap::new(),
            produces: Vec::new(),
        };
        let run = directory.path().join("run");
        fs::create_dir_all(&run).unwrap();
        let started = Instant::now();
        let result = execute_producer(directory.path(), "timeout", &producer, &run).unwrap();
        assert_eq!(result.outcome, ProducerOutcome::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn gigasail_executor_rejects_unallowlisted_path_commands() {
        let config = LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig::default(),
            profiles: BTreeMap::new(),
            producers: BTreeMap::from([(
                "unsafe".into(),
                EvidenceProducer {
                    executor: ProducerExecutor::Gigasail,
                    argv: vec!["sh".into(), "-c".into(), "touch escaped".into()],
                    working_directory: None,
                    timeout_seconds: 1,
                    max_output_bytes: 1024,
                    environment: BTreeMap::new(),
                    produces: Vec::new(),
                },
            )]),
        };
        let error = validate_config(config).unwrap_err().to_string();
        assert!(error.contains("allowlisted embedded provider"), "{error}");
    }

    #[test]
    fn standalone_analysis_runs_are_retained_with_a_bounded_history() {
        let directory = tempdir().unwrap();
        let config = validate_config(LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig {
                retain_runs: 2,
                compression: ArtifactCompression::None,
                ..ArtifactStoreConfig::default()
            },
            profiles: BTreeMap::from([(
                "analyse".into(),
                VerificationProfile {
                    producers: vec!["report".into()],
                    required_evidence: BTreeSet::new(),
                },
            )]),
            producers: BTreeMap::from([(
                "report".into(),
                EvidenceProducer {
                    executor: ProducerExecutor::Command,
                    argv: vec![
                        "sh".into(),
                        "-c".into(),
                        "printf '{\"version\":\"2.1.0\",\"runs\":[]}' > report.json".into(),
                    ],
                    working_directory: None,
                    timeout_seconds: 1,
                    max_output_bytes: 1024,
                    environment: BTreeMap::new(),
                    produces: vec![ProducedArtifact {
                        kind: ArtifactKind::Sarif,
                        format: "sarif".into(),
                        path: "report.json".into(),
                        scope: None,
                        complete: false,
                        evidence_scope: None,
                    }],
                },
            )]),
        })
        .unwrap();
        for revision in ["one", "two", "three"] {
            let run = ProfileExecutionSession::begin(directory.path(), &config)
                .unwrap()
                .execute("analyse", revision, ProfileRunKind::StandaloneAnalysis)
                .unwrap();
            assert!(run
                .directory
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("analysis-"));
            if revision == "one" {
                seal_published_run(&run.directory).unwrap();
            }
        }
        let runs = fs::read_dir(directory.path().join(".giga/artifacts/runs"))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy().starts_with("analysis-"))
            .count();
        assert_eq!(runs, 2);
        assert!(!directory.path().join("report.json").exists());
    }

    #[test]
    fn standalone_analysis_rejects_structurally_invalid_sarif_before_finalization() {
        let directory = tempdir().unwrap();
        git2::Repository::init(directory.path()).unwrap();
        let config = validate_config(LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig::default(),
            profiles: BTreeMap::from([(
                "analyse".into(),
                VerificationProfile {
                    producers: vec!["invalid".into()],
                    required_evidence: BTreeSet::new(),
                },
            )]),
            producers: BTreeMap::from([(
                "invalid".into(),
                EvidenceProducer {
                    executor: ProducerExecutor::Command,
                    argv: vec![
                        "sh".into(),
                        "-c".into(),
                        "printf not-json > findings.sarif".into(),
                    ],
                    working_directory: None,
                    timeout_seconds: 1,
                    max_output_bytes: 1024,
                    environment: BTreeMap::new(),
                    produces: vec![ProducedArtifact {
                        kind: ArtifactKind::Sarif,
                        format: "sarif".into(),
                        path: "findings.sarif".into(),
                        scope: None,
                        complete: false,
                        evidence_scope: None,
                    }],
                },
            )]),
        })
        .unwrap();
        let error = ProfileExecutionSession::begin(directory.path(), &config)
            .unwrap()
            .execute("analyse", "WORKTREE", ProfileRunKind::StandaloneAnalysis)
            .unwrap_err()
            .to_string();
        assert!(error.contains("validate SARIF artifact"), "{error}");
        assert!(
            fs::read_dir(directory.path().join(".giga/artifacts/runs"))
                .unwrap()
                .filter_map(std::result::Result::ok)
                .all(|entry| !entry.file_name().to_string_lossy().starts_with("analysis-"))
        );
    }

    #[test]
    fn bounded_embedded_work_returns_at_its_deadline() {
        let started = Instant::now();
        let result = run_bounded_work(Duration::from_millis(20), || {
            thread::sleep(Duration::from_millis(200));
            Ok::<_, anyhow::Error>(())
        })
        .unwrap();
        assert!(result.is_none());
        assert!(started.elapsed() < Duration::from_millis(100));
    }

    #[test]
    fn profile_execution_session_serializes_workspace_transactions() {
        let directory = tempdir().unwrap();
        let config = LineageConfig {
            version: 1,
            artifacts: ArtifactStoreConfig::default(),
            profiles: BTreeMap::new(),
            producers: BTreeMap::new(),
        };
        let session = ProfileExecutionSession::begin(directory.path(), &config).unwrap();
        let error = match ProfileExecutionSession::begin(directory.path(), &config) {
            Ok(_) => panic!("second execution session unexpectedly acquired the lock"),
            Err(error) => error.to_string(),
        };
        assert!(error.contains("another profile execution"), "{error}");
        drop(session);
        assert!(ProfileExecutionSession::begin(directory.path(), &config).is_ok());
    }

    #[test]
    fn embedded_fact_mine_is_deterministic_honors_gitignore_and_records_proof_boundaries() {
        let directory = tempdir().unwrap();
        git2::Repository::init(directory.path()).unwrap();
        fs::write(directory.path().join(".gitignore"), "ignored.rs\n").unwrap();
        fs::write(
            directory.path().join("z.rs"),
            "pub unsafe fn z() { unsafe { core::ptr::read(0 as *const u8); } }\n",
        )
        .unwrap();
        fs::write(
            directory.path().join("a.rs"),
            "pub unsafe fn a() { unsafe { core::ptr::read(0 as *const u8); } }\n",
        )
        .unwrap();
        fs::write(
            directory.path().join("ignored.rs"),
            "pub unsafe fn ignored() { unsafe { core::ptr::read(0 as *const u8); } }\n",
        )
        .unwrap();
        let producer = EvidenceProducer {
            executor: ProducerExecutor::Gigasail,
            argv: vec!["fact-mine-native".into()],
            working_directory: None,
            timeout_seconds: 1,
            max_output_bytes: 1024,
            environment: BTreeMap::new(),
            produces: vec![ProducedArtifact {
                kind: ArtifactKind::Sarif,
                format: "sarif".into(),
                path: "out/fact-mine.sarif".into(),
                scope: None,
                complete: false,
                evidence_scope: None,
            }],
        };
        run_builtin_fact_mine(directory.path(), &producer).unwrap();
        let first = fs::read(directory.path().join("out/fact-mine.sarif")).unwrap();
        run_builtin_fact_mine(directory.path(), &producer).unwrap();
        let second = fs::read(directory.path().join("out/fact-mine.sarif")).unwrap();
        assert_eq!(first, second);
        let document: serde_json::Value = serde_json::from_slice(&second).unwrap();
        let results = document.pointer("/runs/0/results").unwrap().to_string();
        assert!(results.contains("a.rs"));
        assert!(results.contains("z.rs"));
        assert!(!results.contains("ignored.rs"));
        assert_eq!(
            document.pointer("/runs/0/properties/gigasail.analysis_complete"),
            Some(&serde_json::Value::Bool(false))
        );
        assert_eq!(
            document.pointer("/runs/0/properties/gigasail.provider_capability"),
            Some(&serde_json::Value::String(
                "bounded-syntax-hazard-scan".to_string()
            ))
        );
        assert!(document
            .pointer("/runs/0/properties/gigasail.proof_boundary")
            .and_then(serde_json::Value::as_array)
            .is_some());
        let run = directory.path().join("run");
        fs::create_dir_all(&run).unwrap();
        let producer_run =
            execute_gigasail_provider(directory.path(), "fact-mine", &producer, &run).unwrap();
        assert_eq!(producer_run.outcome, ProducerOutcome::Succeeded);
        assert!(
            producer_run.tool_version.starts_with("fact-mine-rust/"),
            "{}",
            producer_run.tool_version
        );
    }
}
