# frozen_string_literal: true

# Cross-language reach-through report: module A invoking non-public methods
# of module B.
#
# Primary source: corpus-resolved call edges (call-resolution --format
# edges), which carry the target's declared visibility - no name heuristics.
# Secondary sources from syntax-facts: Ruby send(:literal) resolution and
# convention-private (leading underscore) cross-owner calls in languages
# without enforcement. Dynamic send sites are counted, not resolved - they
# are already ruby_metaprogramming hazards with a nil-kill escalation path.
#
# Visibility semantics: package (Java), crate (Rust), and internal (C#) are
# same-namespace-legal and never reported. private/protected findings in
# compiler-enforcing languages are quarantined as suspects (they indicate
# resolution or extraction artifacts, since such code cannot compile).
#
# Usage: ruby reach_through_report.rb REPO_ROOT [--sarif=PATH] [--base=REF [--head=REF]]

require_relative "corpus_common"

RULES = [
  {
    "id" => "arch-reach-through",
    "name" => "Cross-module private reach-through",
    "shortDescription" => { "text" => "A module invokes another module's non-public method" },
    "fullDescription" => {
      "text" => "Cross-owner call to a method whose declared or conventional visibility is non-public. The language does not or cannot enforce this boundary; the dependency bypasses the target's public API."
    },
    "defaultConfiguration" => { "level" => "warning" }
  },
  {
    "id" => "arch-privacy-bypass",
    "name" => "Privacy bypass via dynamic dispatch",
    "shortDescription" => { "text" => "send(:literal) resolves to a non-public method of another owner" },
    "fullDescription" => {
      "text" => "A literal send bypasses declared privacy. Dynamic sends are covered separately by metaprogramming hazards with runtime-evidence escalation."
    },
    "defaultConfiguration" => { "level" => "warning" }
  }
].freeze

NAMESPACE_SCOPED = %w[package crate internal].freeze
ENFORCING_LANGUAGES = %w[java csharp go rust swift kotlin].freeze
SEND_METHODS = %w[send __send__ public_send].freeze

options = CorpusCommon.parse_tool_options(ARGV)
repo = options[:repo]
files = CorpusCommon.production_files(repo)
abort "no production sources found" if files.empty?

# The call graph is always built from the FULL corpus, changed-scope or
# not. A changed file's reach-through into another module's private API is
# a real finding regardless of whether that other module happened to
# change too; narrowing the corpus before graph construction would drop
# the callee's facts entirely, making the violation undetectable rather
# than merely unreported. `changed` (below, at the finding-filter step)
# still scopes which findings get reported - only the graph itself must
# never be scoped.
changed = options[:base] ? CorpusCommon.changed_files(repo, options[:base], options[:head]).to_set : nil
if changed&.empty?
  CorpusCommon.write_sarif(options[:sarif], "espalier-reach-through", RULES, []) if options[:sarif]
  puts "(no changed production sources)"
  exit 0
end

facts = CorpusCommon.run_syntax_facts(repo, files)
documents = facts["documents"] || []
edge_facts = CorpusCommon.run_call_edges(repo, files)

language_by_path = documents.to_h { |doc| [doc["file"], doc["language"]] }

findings = { declared: [], convention: [], send_resolved: [], suspect: [] }
send_dynamic = 0

# --- Primary: resolved call edges with target visibility ---
(edge_facts["edges"] || []).each do |edge|
  visibility = edge["target_visibility"].to_s
  next if visibility.empty? || visibility == "public"
  next if NAMESPACE_SCOPED.include?(visibility)
  next if edge["source_owner"] == edge["target_owner"]
  # Nested/outer class access is not a module boundary violation.
  next if edge["source_owner"].to_s.start_with?("#{edge["target_owner"]}::")
  next if edge["target_owner"].to_s.start_with?("#{edge["source_owner"]}::")

  language = language_by_path[edge["source_path"]]
  finding = {
    from: edge["source_owner"], to: "#{edge["target_owner"]}##{edge["target_name"]}",
    visibility: visibility, at: "#{edge["source_path"]}:#{edge["line"]}",
    target_at: "#{edge["target_path"]}:#{edge["target_line"]}", resolution: "call-edge"
  }
  bucket = ENFORCING_LANGUAGES.include?(language) ? :suspect : :declared
  findings[bucket] << finding
end

# --- Secondary: syntax-facts for sends and convention privacy ---
functions = {}
owners_by_tail = Hash.new { |h, k| h[k] = Set.new }
documents.each do |doc|
  lang = doc["language"]
  (doc["functions"] || []).each do |f|
    owner = f["owner"].to_s
    functions[[lang, owner, f["name"]]] ||= {
      "visibility" => f["visibility"] || "public", "path" => doc["file"], "line" => f["line"]
    }
    owners_by_tail[[lang, owner.split("::").last]] << owner unless owner.empty?
    owners_by_tail[[lang, owner]] << owner unless owner.empty?
  end
end

documents.each do |doc|
  lang = doc["language"]
  (doc["calls"] || []).each do |call|
    caller_owner = call["owner"].to_s
    receiver = call["receiver"].to_s
    message = call["message"].to_s
    file = doc["file"]

    if SEND_METHODS.include?(message)
      literal = Array(call["arguments"]).first.to_s[/\A:(\w+[?!=]?)\z/, 1]
      if literal.nil?
        send_dynamic += 1
        next
      end
      target_owner =
        if receiver.empty? || receiver == "self"
          caller_owner
        elsif receiver.match?(/\A[A-Z]/)
          candidates = owners_by_tail[[lang, receiver]]
          candidates.size == 1 ? candidates.first : nil
        else
          defining = functions.keys.select { |(l, _, name)| l == lang && name == literal }
                              .map { |(_, owner, _)| owner }.uniq
          defining.size == 1 ? defining.first : nil
        end
      next unless target_owner
      target = functions[[lang, target_owner, literal]]
      next unless target
      if message != "public_send" && !NAMESPACE_SCOPED.include?(target["visibility"]) && target["visibility"] != "public"
        findings[:send_resolved] << {
          from: caller_owner, to: "#{target_owner}##{literal}", visibility: target["visibility"],
          at: "#{file}:#{call["line"]}", target_at: "#{target["path"]}:#{target["line"]}",
          resolution: "send-literal"
        }
      end
      next
    end

    # Convention privacy: underscore-prefixed cross-owner target in languages
    # that enforce nothing. Distinctive names only; plain names need the
    # call-edge path above.
    next unless %w[python javascript typescript ruby].include?(lang)
    next unless message.start_with?("_") && !message.start_with?("__")
    next if receiver.empty? || %w[self cls this].include?(receiver)
    defining = functions.keys.select { |(l, _, name)| l == lang && name == message }
                        .map { |(_, owner, _)| owner }.uniq
    next unless defining.size == 1
    target_owner = defining.first
    next if target_owner == caller_owner
    target = functions[[lang, target_owner, message]]
    next unless target
    findings[:convention] << {
      from: caller_owner.empty? ? file : caller_owner, to: "#{target_owner}##{message}",
      visibility: target["visibility"] == "public" ? "underscore-convention" : target["visibility"],
      at: "#{file}:#{call["line"]}", target_at: "#{target["path"]}:#{target["line"]}",
      resolution: "unique-name"
    }
  end
end

%i[declared convention send_resolved suspect].each do |bucket|
  findings[bucket].uniq! { |f| [f[:at], f[:to]] }
end

in_scope = lambda do |finding|
  changed.nil? || changed.include?(finding[:at].split(":").first)
end

sarif_findings = []
findings[:declared].select(&in_scope).each do |f|
  sarif_findings << {
    rule_id: "arch-reach-through",
    message: "#{f[:from]} calls #{f[:to]} (#{f[:visibility]}, defined #{f[:target_at]})",
    path: f[:at].split(":").first, line: f[:at].split(":").last
  }
end
findings[:convention].select(&in_scope).each do |f|
  sarif_findings << {
    rule_id: "arch-reach-through",
    message: "#{f[:from]} calls #{f[:to]} (#{f[:visibility]}, defined #{f[:target_at]})",
    path: f[:at].split(":").first, line: f[:at].split(":").last
  }
end
findings[:send_resolved].select(&in_scope).each do |f|
  sarif_findings << {
    rule_id: "arch-privacy-bypass",
    message: "#{f[:from]} send-bypasses #{f[:to]} (#{f[:visibility]}, defined #{f[:target_at]})",
    path: f[:at].split(":").first, line: f[:at].split(":").last
  }
end

puts "repo: #{repo}  files: #{files.size}  resolved edges: #{(edge_facts["edges"] || []).size}"
puts
puts "== Declared-private reach-through (#{findings[:declared].size}) =="
findings[:declared].first(12).each { |f| puts "  #{f[:at]}  #{f[:from]} -> #{f[:to]} (#{f[:visibility]}, defined #{f[:target_at]})" }
puts
puts "== send(:literal) privacy bypass (#{findings[:send_resolved].size}); dynamic send sites: #{send_dynamic} =="
findings[:send_resolved].first(12).each { |f| puts "  #{f[:at]}  #{f[:from]} -> #{f[:to]} (#{f[:visibility]})" }
puts
puts "== Convention-private reach-through (#{findings[:convention].size}) =="
findings[:convention].first(12).each { |f| puts "  #{f[:at]}  #{f[:from]} -> #{f[:to]} (#{f[:visibility]})" }
puts
puts "== Suspect (enforcing language; likely extraction artifact) (#{findings[:suspect].size}) =="
findings[:suspect].first(6).each { |f| puts "  #{f[:at]}  #{f[:from]} -> #{f[:to]} (#{f[:visibility]})" }

CorpusCommon.write_sarif(options[:sarif], "espalier-reach-through", RULES, sarif_findings) if options[:sarif]
