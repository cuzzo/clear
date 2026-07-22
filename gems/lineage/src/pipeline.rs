//! Typed configuration and manifest contracts for the Lineage evidence pipeline.

use anyhow::{bail, Context, Result};
use flate2::write::GzEncoder;
use flate2::Compression;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

pub const CONFIG_FILE_NAME: &str = "lineage.yml";
pub const CONFIG_JSON_FILE_NAME: &str = "lineage.json";
pub const RUN_MANIFEST_VERSION: &str = "lineage-run/v1";

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactCompression {
    Gzip,
    None,
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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
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
    pub configuration_hash: String,
    pub artifacts: Vec<ManifestArtifact>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManifestArtifact {
    pub producer: String,
    pub kind: ArtifactKind,
    pub format: String,
    pub path: PathBuf,
    pub content_hash: String,
    pub scope: Option<String>,
    pub complete: bool,
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
    validate_relative_path(&config.artifacts.directory, "artifacts.directory")?;
    for (name, producer) in &config.producers {
        if name.trim().is_empty() {
            bail!("producer names cannot be empty");
        }
        if producer.executor == ProducerExecutor::Command && producer.argv.is_empty() {
            bail!("command producer {name:?} requires argv");
        }
        for artifact in &producer.produces {
            validate_relative_path(&artifact.path, &format!("producer {name:?} artifact path"))?;
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
    let run_directory = latest_run_directory(repo, config);
    reset_latest_directory(&run_directory)?;
    let mut artifacts = Vec::new();
    for producer_name in &profile.producers {
        let producer = &config.producers[producer_name];
        execute_producer(repo, producer_name, producer, &run_directory)?;
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
    let manifest = RunManifest {
        version: RUN_MANIFEST_VERSION.into(),
        revision: revision.into(),
        configuration_hash: config_hash(config)?,
        artifacts,
    };
    fs::write(
        run_directory.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest)?,
    )?;
    Ok(manifest)
}

fn reset_latest_directory(path: &Path) -> Result<()> {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.file_type().is_symlink() {
            bail!(
                "refusing to replace symlinked latest artifact directory {}",
                path.display()
            );
        }
        fs::remove_dir_all(path)
            .with_context(|| format!("replace latest artifact directory {}", path.display()))?;
    }
    fs::create_dir_all(path)?;
    Ok(())
}

fn execute_producer(
    repo: &Path,
    name: &str,
    producer: &EvidenceProducer,
    run_directory: &Path,
) -> Result<()> {
    if producer.executor != ProducerExecutor::Command {
        bail!(
            "producer {name:?} uses unsupported executor {:?}",
            producer.executor
        );
    }
    let output = Command::new(&producer.argv[0])
        .args(&producer.argv[1..])
        .current_dir(repo)
        .output()
        .with_context(|| format!("start producer {name:?}"))?;
    let logs = run_directory.join("logs");
    fs::create_dir_all(&logs)?;
    fs::write(logs.join(format!("{name}.stdout")), &output.stdout)?;
    fs::write(logs.join(format!("{name}.stderr")), &output.stderr)?;
    if !output.status.success() {
        bail!("producer {name:?} exited with {}", output.status);
    }
    Ok(())
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
        scope: artifact.scope.clone(),
        complete: artifact.complete,
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

fn default_artifact_directory() -> PathBuf {
    PathBuf::from(".lineage/artifacts")
}

fn default_compression() -> ArtifactCompression {
    ArtifactCompression::Gzip
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
            "version: 1\nprofiles:\n  ci:\n    producers: [coverage]\nproducers:\n  coverage:\n    executor: command\n    argv: [bundle, exec, rake, test]\n    produces:\n      - kind: coverage\n        format: simplecov\n        path: coverage/.resultset.json\n        scope: unit\n        complete: true\n",
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
                    produces: vec![ProducedArtifact {
                        kind: ArtifactKind::Coverage,
                        format: "generic".into(),
                        path: "coverage/report.json".into(),
                        scope: Some("unit".into()),
                        complete: true,
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
    }
}
