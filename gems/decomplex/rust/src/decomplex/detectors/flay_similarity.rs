use crate::decomplex::syntax::{self, CloneCandidate, Document, Language, SimilarityFinding, Span};
use anyhow::Result;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;

const MAX_FUZZY_CHILDREN: usize = 14;

pub fn scan_files(
    files: &[PathBuf],
    language: Language,
    mass: usize,
    fuzzy: usize,
) -> Result<Vec<SimilarityFinding>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents, mass, fuzzy))
}

pub fn scan_documents(documents: &[Document], mass: usize, fuzzy: usize) -> Vec<SimilarityFinding> {
    let mut scanner = Scanner::new(mass, fuzzy);
    scanner.scan(documents)
}

struct Scanner {
    mass: usize,
    fuzzy: usize,
}

impl Scanner {
    fn new(mass: usize, fuzzy: usize) -> Self {
        Self { mass, fuzzy }
    }

    fn scan(&mut self, documents: &[Document]) -> Vec<SimilarityFinding> {
        let mut candidates = Vec::new();
        for document in documents {
            candidates.extend(self.candidates_for_document(document));
        }
        let mut findings = self.type2_findings(&candidates);
        findings.extend(self.type3_findings(&candidates));
        findings.sort_by(|left, right| {
            (
                clone_type_rank(&left.clone_type),
                std::cmp::Reverse(left.mass),
                left.node.clone(),
                left.at.clone(),
            )
                .cmp(&(
                    clone_type_rank(&right.clone_type),
                    std::cmp::Reverse(right.mass),
                    right.node.clone(),
                    right.at.clone(),
                ))
        });
        self.prune_nested_findings(findings)
    }

    fn candidates_for_document(&mut self, document: &Document) -> Vec<CloneCandidate> {
        let mut out = Vec::new();
        let mut seen = HashSet::new();
        for candidate in syntax::clone_candidates(document) {
            self.add_candidate(&mut out, &mut seen, candidate);
        }
        out
    }

    fn add_candidate(
        &self,
        out: &mut Vec<CloneCandidate>,
        seen: &mut HashSet<String>,
        candidate: CloneCandidate,
    ) {
        if candidate.mass < self.effective_mass_floor() {
            return;
        }
        let key = format!(
            "{}\0{}\0{:?}\0{}\0{}",
            candidate.file,
            candidate.line,
            candidate.span,
            candidate.node_name,
            candidate.fingerprint
        );
        if seen.insert(key) {
            out.push(candidate);
        }
    }

    fn type2_findings(&self, candidates: &[CloneCandidate]) -> Vec<SimilarityFinding> {
        let mut groups: HashMap<&str, Vec<&CloneCandidate>> = HashMap::new();
        for candidate in candidates {
            groups
                .entry(candidate.fingerprint.as_str())
                .or_default()
                .push(candidate);
        }
        let mut out = Vec::new();
        for cluster in groups.values() {
            let cluster = uniq_sites(cluster.iter().copied());
            if cluster.len() < 2 {
                continue;
            }
            let raw_count = cluster
                .iter()
                .map(|candidate| candidate.raw.as_str())
                .collect::<HashSet<_>>()
                .len();
            if raw_count < 2 {
                continue;
            }
            let mass = cluster
                .iter()
                .map(|candidate| candidate.mass)
                .min()
                .unwrap_or(0);
            out.push(self.finding_for(&cluster, "type2", mass));
        }
        out
    }

    fn type3_findings(&self, candidates: &[CloneCandidate]) -> Vec<SimilarityFinding> {
        if self.fuzzy == 0 {
            return Vec::new();
        }
        let mut groups: HashMap<String, Vec<(&CloneCandidate, usize)>> = HashMap::new();
        for candidate in candidates {
            for (signature, signature_mass) in self.fuzzy_signatures(candidate) {
                if signature_mass >= self.effective_mass_floor() {
                    groups
                        .entry(signature)
                        .or_default()
                        .push((candidate, signature_mass));
                }
            }
        }

        let mut best_by_key: BTreeMap<String, SimilarityFinding> = BTreeMap::new();
        for rows in groups.values() {
            let cluster = uniq_sites(rows.iter().map(|(candidate, _)| *candidate));
            if cluster.len() < 2 {
                continue;
            }
            let fingerprint_count = cluster
                .iter()
                .map(|candidate| candidate.fingerprint.as_str())
                .collect::<HashSet<_>>()
                .len();
            if fingerprint_count < 2 {
                continue;
            }
            let mut key = cluster
                .iter()
                .map(|candidate| {
                    format!(
                        "{}\0{}\0{}",
                        candidate.file, candidate.line, candidate.node_name
                    )
                })
                .collect::<Vec<_>>();
            key.sort();
            let key = key.join("\0");
            let mass = rows
                .iter()
                .map(|(_, signature_mass)| *signature_mass)
                .max()
                .unwrap_or(0);
            let finding = self.finding_for(&cluster, "type3", mass);
            if best_by_key
                .get(&key)
                .map(|existing| existing.mass < finding.mass)
                .unwrap_or(true)
            {
                best_by_key.insert(key, finding);
            }
        }
        best_by_key.into_values().collect()
    }

    fn finding_for(
        &self,
        cluster: &[&CloneCandidate],
        clone_type: &str,
        mass: usize,
    ) -> SimilarityFinding {
        let mut sites = cluster
            .iter()
            .map(|candidate| site_for(candidate))
            .collect::<Vec<_>>();
        sites.sort();
        SimilarityFinding {
            at: sites.first().cloned().unwrap_or_default(),
            sites,
            spans: self.spans_for(cluster),
            clone_type: clone_type.to_string(),
            node: most_common_node(cluster),
            mass,
            locations: {
                let mut locations = cluster
                    .iter()
                    .map(|candidate| format!("{}:{}", candidate.file, candidate.line))
                    .collect::<Vec<_>>();
                locations.sort();
                locations
            },
        }
    }

    fn spans_for(&self, cluster: &[&CloneCandidate]) -> BTreeMap<String, Span> {
        let mut spans = BTreeMap::new();
        for candidate in cluster {
            let value = if candidate.node_name == "defn" {
                [candidate.span[0], 0, candidate.span[2], 1]
            } else {
                candidate.span
            };
            spans.insert(site_for(candidate), value);
        }
        spans
    }

    fn prune_nested_findings(&self, findings: Vec<SimilarityFinding>) -> Vec<SimilarityFinding> {
        let defn_site_sets = findings
            .iter()
            .filter(|finding| finding.node == "defn")
            .map(|finding| (finding.clone_type.clone(), site_identities(finding)))
            .collect::<Vec<_>>();
        let mut kept = Vec::new();
        for finding in findings {
            if finding.node != "defn"
                && defn_site_sets.contains(&(finding.clone_type.clone(), site_identities(&finding)))
            {
                continue;
            }
            if kept.iter().any(|larger| nested_finding(&finding, larger)) {
                continue;
            }
            kept.push(finding);
        }
        kept
    }

    fn fuzzy_signatures(&self, candidate: &CloneCandidate) -> Vec<(String, usize)> {
        let children = &candidate.child_fingerprints;
        if children.len() < 2 || children.len() > MAX_FUZZY_CHILDREN {
            return Vec::new();
        }
        let max_delete = self.fuzzy.min(children.len() - 1);
        let mut signatures = Vec::new();
        for delete_count in 0..=max_delete {
            for deleted in combinations(children.len(), delete_count) {
                let deleted = deleted.into_iter().collect::<HashSet<_>>();
                let mut kept = Vec::new();
                let mut mass = 0;
                for (index, fingerprint) in children.iter().enumerate() {
                    if deleted.contains(&index) {
                        continue;
                    }
                    kept.push(fingerprint.as_str());
                    mass += candidate.child_masses[index];
                }
                signatures.push((format!("{}({})", candidate.node_name, kept.join("|")), mass));
            }
        }
        signatures
    }

    fn effective_mass_floor(&self) -> usize {
        self.mass
            .max(((self.mass as f64) * 23.0 / 8.0).ceil() as usize)
    }
}

fn uniq_sites<'a>(
    candidates: impl IntoIterator<Item = &'a CloneCandidate>,
) -> Vec<&'a CloneCandidate> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for candidate in candidates {
        let key = format!(
            "{}\0{}\0{:?}\0{}",
            candidate.file, candidate.line, candidate.span, candidate.node_name
        );
        if seen.insert(key) {
            out.push(candidate);
        }
    }
    out
}

fn most_common_node(cluster: &[&CloneCandidate]) -> String {
    let mut order = Vec::new();
    let mut tally: HashMap<&str, usize> = HashMap::new();
    for candidate in cluster {
        if !tally.contains_key(candidate.node_name.as_str()) {
            order.push(candidate.node_name.as_str());
        }
        *tally.entry(candidate.node_name.as_str()).or_default() += 1;
    }
    let mut best = "";
    let mut best_count = 0;
    for node in order {
        let count = tally.get(node).copied().unwrap_or(0);
        if count > best_count {
            best = node;
            best_count = count;
        }
    }
    best.to_string()
}

fn site_for(candidate: &CloneCandidate) -> String {
    format!(
        "{}:{}:{}",
        candidate.file, candidate.method_name, candidate.line
    )
}

fn nested_finding(inner: &SimilarityFinding, outer: &SimilarityFinding) -> bool {
    if outer.mass <= inner.mass {
        return false;
    }
    inner.spans.iter().all(|(site, span)| {
        let file = site_file(site);
        outer.spans.iter().any(|(outer_site, outer_span)| {
            site_file(outer_site) == file && contains_span(*outer_span, *span)
        })
    })
}

fn contains_span(outer: Span, inner: Span) -> bool {
    let outer_start = (outer[0], outer[1]);
    let outer_end = (outer[2], outer[3]);
    let inner_start = (inner[0], inner[1]);
    let inner_end = (inner[2], inner[3]);
    outer_start <= inner_start && outer_end >= inner_end
}

fn site_file(site: &str) -> String {
    let mut parts = site.split(':').collect::<Vec<_>>();
    if parts.len() >= 2 {
        parts.truncate(parts.len() - 2);
    }
    parts.join(":")
}

fn site_identities(finding: &SimilarityFinding) -> Vec<(String, String)> {
    let mut identities = finding
        .sites
        .iter()
        .map(|site| {
            let parts = site.split(':').collect::<Vec<_>>();
            let file = if parts.len() >= 2 {
                parts[..parts.len() - 2].join(":")
            } else {
                String::new()
            };
            let method = parts
                .get(parts.len().saturating_sub(2))
                .copied()
                .unwrap_or_default()
                .to_string();
            (file, method)
        })
        .collect::<Vec<_>>();
    identities.sort();
    identities
}

fn clone_type_rank(clone_type: &str) -> usize {
    if clone_type == "type2" {
        0
    } else {
        1
    }
}

fn combinations(size: usize, count: usize) -> Vec<Vec<usize>> {
    fn step(
        start: usize,
        size: usize,
        count: usize,
        current: &mut Vec<usize>,
        out: &mut Vec<Vec<usize>>,
    ) {
        if current.len() == count {
            out.push(current.clone());
            return;
        }
        for index in start..size {
            current.push(index);
            step(index + 1, size, count, current, out);
            current.pop();
        }
    }
    let mut out = Vec::new();
    step(0, size, count, &mut Vec::new(), &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn scan(source: &str, mass: usize, fuzzy: usize) -> Vec<SimilarityFinding> {
        let mut file = NamedTempFile::new().expect("tempfile");
        file.write_all(source.as_bytes()).expect("write source");
        scan_files(&[file.path().to_path_buf()], Language::Ruby, mass, fuzzy).expect("scan")
    }

    #[test]
    fn detects_type2_similarity_for_renamed_ruby_methods() {
        let out = scan(
            r#"
def a(node)
  return false unless node.respond_to?(:type)
  node.type == :heap || node.type == :frame
end

def b(entry)
  return false unless entry.respond_to?(:kind)
  entry.kind == :heap || entry.kind == :frame
end
"#,
            8,
            1,
        );
        assert!(out
            .iter()
            .any(|finding| finding.clone_type == "type2" && finding.node == "defn"));
    }

    #[test]
    fn detects_type3_similarity_for_missing_child() {
        let out = scan(
            r#"
def a(node)
  alpha(node.left)
  beta(node.right)
  gamma(node.name)
  delta(node.type)
end

def b(entry)
  alpha(entry.left)
  beta(entry.right)
  delta(entry.type)
end
"#,
            4,
            1,
        );
        assert!(out.iter().any(|finding| finding.clone_type == "type3"));
    }
}
