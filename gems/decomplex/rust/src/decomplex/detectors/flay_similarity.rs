use crate::decomplex::ast::Span;
use crate::decomplex::syntax::{self, CloneCandidate, Document, Language, SimilarityFinding};
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
    use crate::decomplex::syntax::adapters::language_profile;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn scan(source: &str, mass: usize, fuzzy: usize) -> Vec<SimilarityFinding> {
        let mut file = NamedTempFile::new().expect("tempfile");
        file.write_all(source.as_bytes()).expect("write source");
        scan_files(&[file.path().to_path_buf()], Language::Ruby, mass, fuzzy).expect("scan")
    }

    fn document(source: &str) -> Document {
        let mut file = NamedTempFile::new().expect("tempfile");
        file.write_all(source.as_bytes()).expect("write source");
        syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("document")
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

    #[test]
    fn singleton_method_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
def self.release(ctx_id, lock_index, lock_ref, unlock_method)
  [
    MIR::Set.new(
      MIR::FieldGet.new(MIR::Ident.new("__ctx_#{ctx_id}"), "__lock_held_#{lock_index}"),
      MIR::Lit.new("false"),
      false,
    ),
    MIR::ExprStmt.new(
      MIR::MethodCall.new(MIR::Ident.new(lock_ref), unlock_method, [], false),
      false,
    ),
  ]
end
"#,
        );
        let function = doc.function_defs.first().expect("function");
        let (_fingerprint, mass) =
            language_profile(Language::Ruby).clone_fingerprint(&function.body);
        assert_eq!(mass, 85);
    }

    #[test]
    fn unless_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
def check(attrs, tok)
  unless attrs
    has_at = T.must(tok).value.start_with?('@')
    candidates = has_at ? BG_SIGILS.keys : BG_SIGILS.keys.map { |k| k.sub(/^@/, '') }
    emit_typo_suggestion!(
      tok, T.must(tok).value, candidates,
      "Unknown BG prefix #{T.must(tok).value.inspect}",
      "closest BG body sigil",
      category: :type, cascade: true
    )
  end
end
"#,
        );
        let mut nodes = Vec::new();
        doc.root.walk(&mut nodes);
        let node = nodes
            .into_iter()
            .find(|node| node.kind == "unless" && node.named)
            .expect("unless");
        let (_fingerprint, mass) = language_profile(Language::Ruby).clone_fingerprint(node);
        assert_eq!(mass, 89);
    }

    #[test]
    fn struct_assignment_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
DeferStmt = Struct.new(:body) do
  extend T::Sig
  include Stmt
  sig { params(body: DeferBodyInput).void }
  def initialize(body)
    MIR.validate_defer_body!(body, "MIR::DeferStmt")
    super(body)
  end

  sig { returns(T::Array[BodySlot]) }
  def body_slots
    body.is_a?(Array) ? [body_slot(:body, body, ->(new_body) { self.body = new_body })] : []
  end
  sig { returns(T::Array[Emittable]) }
  def child_exprs = body.is_a?(Array) ? [] : compact_child_exprs([body])
end
"#,
        );
        let mut nodes = Vec::new();
        doc.root.walk(&mut nodes);
        let node = nodes
            .into_iter()
            .find(|node| node.kind == "assignment" && node.named)
            .expect("assignment");
        let (_fingerprint, mass) = language_profile(Language::Ruby).clone_fingerprint(node);
        assert_eq!(mass, 138);
    }

    #[test]
    fn body_slots_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
SwitchStmt = Struct.new(:subject, :arms, :default_body) do
  extend T::Sig
  include Stmt
  sig { returns(T::Array[Emittable]) }
  def child_exprs
    compact_child_exprs([subject, *(arms || []).flat_map(&:patterns)])
  end
  sig { returns(T::Array[BodySlot]) }
  def body_slots
    slots = T.let([], T::Array[BodySlot])
    arms&.each_with_index do |arm, index|
      slots << body_slot(:"arms_#{index}", arm.body, ->(new_body) { arm.body = new_body })
    end
    slots << body_slot(:default_body, default_body, ->(new_body) { self.default_body = new_body }) if default_body
    slots
  end
end
"#,
        );
        let function = doc
            .function_defs
            .iter()
            .find(|function| function.name == "body_slots")
            .expect("body_slots");
        let (_fingerprint, mass) =
            language_profile(Language::Ruby).clone_fingerprint(&function.body);
        assert_eq!(mass, 46);
    }

    #[test]
    fn if_bind_do_block_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
IfBind = Struct.new(:token, :bindings, :then_branch, :else_branch) do
  extend T::Sig
  include Locatable

  sig { params(args: T.untyped).void }
  def initialize(*args)
    super
    self[:bindings] = [] if self[:bindings].nil?
  end

  sig { params(val: T::Array[AST::Binding]).void }
  def bindings=(val)
    self[:bindings] = val
  end
end
"#,
        );
        let mut nodes = Vec::new();
        doc.root.walk(&mut nodes);
        let node = nodes
            .into_iter()
            .find(|node| node.kind == "block" && node.named)
            .expect("block");
        let (_fingerprint, mass) = language_profile(Language::Ruby).clone_fingerprint(node);
        assert_eq!(mass, 104);
    }

    #[test]
    fn control_flow_argument_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
def self.find_package_source(pkg_name, start_dir:)
  dir = File.expand_path(start_dir)
  loop do
    candidate = File.join(dir, "packages", pkg_name, "src", "lib.cht")
    return candidate if File.exist?(candidate)

    parent = File.dirname(dir)
    break if parent == dir

    dir = parent
  end
  nil
end
"#,
        );
        let function = doc.function_defs.first().expect("function");
        let (_fingerprint, mass) =
            language_profile(Language::Ruby).clone_fingerprint(&function.body);
        assert_eq!(mass, 74);
    }

    #[test]
    fn case_scope_pattern_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
def walk_for_local_decls(node, &block)
  return if node.nil?
  case node
  when AST::BindExpr, AST::VarDecl
    yield node if auto?(node.type)
    walk_for_local_decls(node.value, &block)
  when AST::FunctionDef
  when Array
    node.each { |c| walk_for_local_decls(c, &block) }
  when Hash
    node.each_value { |v| walk_for_local_decls(v, &block) }
  else
    if node.respond_to?(:each_pair)
      node.each_pair { |_, v| walk_for_local_decls(v, &block) }
    end
  end
end
"#,
        );
        let mut nodes = Vec::new();
        doc.root.walk(&mut nodes);
        let node = nodes
            .into_iter()
            .find(|node| node.kind == "case" && node.named)
            .expect("case");
        let (_fingerprint, mass) = language_profile(Language::Ruby).clone_fingerprint(node);
        assert_eq!(mass, 94);
    }

    #[test]
    fn case_simple_pattern_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
def references_alias?(expr, alias_name)
  found = false
  walk = lambda do |n|
    return if found
    case n
    when nil, Symbol, String, Integer, Float, TrueClass, FalseClass
    when Array then n.each { |x| walk.call(x) }
    when AST::Identifier
      found = true if n.name == alias_name
    else
      n.each_pair { |_, v| walk.call(v) } if n.respond_to?(:each_pair)
    end
  end
  walk.call(expr)
  found
end
"#,
        );
        let mut nodes = Vec::new();
        doc.root.walk(&mut nodes);
        let node = nodes
            .into_iter()
            .find(|node| node.kind == "case" && node.named)
            .expect("case");
        let (_fingerprint, mass) = language_profile(Language::Ruby).clone_fingerprint(node);
        assert_eq!(mass, 73);
    }

    #[test]
    fn alias_cluster_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r##"
def alias_clusters
  @preds.group_by(&:body).filter_map do |body, ps|
    names = ps.map(&:name).uniq
    next if names.size < 2

    { body: body, names: names,
      sites: ps.map { |p| "#{p.file}:#{p.name}:#{p.line}" },
      spans: ps.to_h { |p| ["#{p.file}:#{p.name}:#{p.line}", p.span] } }
  end.sort_by { |h| -h[:names].size }
end
"##,
        );
        let function = doc.function_defs.first().expect("function");
        let (_fingerprint, mass) =
            language_profile(Language::Ruby).clone_fingerprint(&function.body);
        assert_eq!(mass, 127);
    }

    #[test]
    fn native_module_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r##"
module Decomplex
  module Native
    module CoUpdate
      module_function

      def scan(files)
        paths = Array(files).map(&:to_s)
        validate_ruby_files!(paths)
        JSON.parse(Command.run("co-update", "--language", "ruby", *paths))
      end

      private_class_method def self.validate_ruby_files!(paths)
        bad = paths.reject { |path| File.extname(path) == ".rb" }
        return if bad.empty?

        raise ArgumentError, "--engine=rust currently supports Ruby files only: #{bad.join(', ')}"
      end
    end
  end
end
"##,
        );
        let mut nodes = Vec::new();
        doc.root.walk(&mut nodes);
        let node = nodes
            .into_iter()
            .find(|node| node.kind == "module" && node.named)
            .expect("module");
        let (_fingerprint, mass) = language_profile(Language::Ruby).clone_fingerprint(node);
        assert_eq!(mass, 112);
    }

    #[test]
    fn hidden_method_name_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r##"
def inline_def_name(node)
  return nil unless inline_def_argument_list?(node)

  receiver_index = node.named_children.index { |child| child.kind == "self" || child.kind == "constant" }
  search = receiver_index ? node.named_children[(receiver_index + 1)..] : node.named_children
  name = search&.find { |child| %w[identifier field_identifier property_identifier].include?(child.kind) }&.text
  receiver_index ? "self.#{name}" : name
end
"##,
        );
        let function = doc.function_defs.first().expect("function");
        let (_fingerprint, mass) =
            language_profile(Language::Ruby).clone_fingerprint(&function.body);
        assert_eq!(mass, 105);
    }
}
