# frozen_string_literal: true

# Module-level dependency-cycle report over fact-mine facts.
#
# Edges come from fact-mine's emitted import facts (file/include/require plus
# symbol imports resolved to project files) and corpus-resolved call edges
# (call-resolution --format edges). Strongly-connected components are
# reported at file and directory granularity - levels no compiler checks.
#
# Python __init__.py re-export facades are intentional cycles and are
# excluded from file-level findings (kept at directory level).
#
# Usage: ruby cycle_report.rb REPO_ROOT [--sarif=PATH] [--base=REF [--head=REF]]

require_relative "corpus_common"

RULES = [
  {
    "id" => "arch-dependency-cycle",
    "name" => "Module dependency cycle",
    "shortDescription" => { "text" => "Files or directories form an import/call dependency cycle" },
    "fullDescription" => {
      "text" => "A strongly-connected component in the module dependency graph. Cycles at file/directory granularity are not rejected by compilers but block layering, isolated testing, and incremental builds."
    },
    "defaultConfiguration" => { "level" => "warning" }
  }
].freeze

def resolve_import_target(repo, src_path, import, file_set)
  target = import["target"].to_s
  return nil if target.empty?
  dir = File.dirname(src_path)

  candidates =
    case import["kind"]
    when "include"
      [target, File.expand_path(File.join(dir, target), "/").delete_prefix("/")]
    when "file"
      if target.start_with?(".")
        base = File.expand_path(File.join(dir, target), "/").delete_prefix("/")
        [base, "#{base}.js", "#{base}.ts", "#{base}.mjs", "#{base}.rb",
         "#{base}/index.js", "#{base}/index.ts"]
      else
        base = File.expand_path(File.join(dir, target), "/").delete_prefix("/")
        ["#{base}.rb", base, "lib/#{target}.rb", "#{target}.rb", "#{target}"]
      end
    when "symbol"
      # Dotted/qualified module target: resolve the longest path prefix.
      parts = target.split(/[.\/]/).reject(&:empty?)
      prefixes = (1..parts.size).map { |i| parts[0, i].join("/") }
      prefixes.flat_map do |prefix|
        ["#{prefix}.py", "#{prefix}/__init__.py", "src/#{prefix}.py",
         "src/#{prefix}/__init__.py", "#{prefix}.java", "src/main/java/#{prefix}.java"]
      end
    else
      []
    end
  candidates.find { |candidate| file_set.include?(candidate) }
end

options = CorpusCommon.parse_tool_options(ARGV)
repo = options[:repo]
files = CorpusCommon.production_files(repo)
abort "no production sources found" if files.empty?

changed = options[:base] ? CorpusCommon.changed_files(repo, options[:base], options[:head]).to_set : nil
if changed
  files, scoped_modules = CorpusCommon.scope_to_changed_modules(files, changed)
  warn "scoped to changed modules: #{scoped_modules.sort.join(", ")} (#{files.size} files)"
  if files.empty?
    CorpusCommon.write_sarif(options[:sarif], "espalier-cycle-report", RULES, []) if options[:sarif]
    puts "(no production sources in changed modules)"
    exit 0
  end
end
file_set = files.to_set

facts = CorpusCommon.run_syntax_facts(repo, files)
edge_facts = CorpusCommon.run_call_edges(repo, files)

file_graph = Hash.new { |h, k| h[k] = Set.new }
dir_graph = Hash.new { |h, k| h[k] = Set.new }
edge_examples = Hash.new { |h, k| h[k] = [] }

add_edge = lambda do |src, dst, label|
  return if src == dst
  file_graph[src] << dst
  edge_examples[[src, dst]] << label
  s_dir = File.dirname(src)
  d_dir = File.dirname(dst)
  dir_graph[s_dir] << d_dir unless s_dir == d_dir
  edge_examples[[s_dir, d_dir]] << label unless s_dir == d_dir
end

import_edge_count = 0
(facts["documents"] || []).each do |doc|
  src = doc["file"]
  (doc["imports"] || []).each do |import|
    dst = resolve_import_target(repo, src, import, file_set)
    next unless dst
    import_edge_count += 1
    add_edge.call(src, dst, "import #{src}:#{import["line"]} -> #{dst}")
  end
end

call_edge_count = 0
(edge_facts["edges"] || []).each do |edge|
  src = edge["source_path"]
  dst = edge["target_path"]
  next unless src && dst && file_set.include?(src) && file_set.include?(dst)
  next if src == dst
  call_edge_count += 1
  add_edge.call(src, dst, "call #{src}:#{edge["line"]} #{edge["message"]} -> #{dst}")
end

# Re-export facades are intentional cycles: Python __init__.py packages and
# function-less index.* barrel files (pure re-export modules). Drop them from
# file-level analysis; they still participate at directory level.
barrels = (facts["documents"] || []).filter_map do |doc|
  file = doc["file"].to_s
  next unless File.basename(file).start_with?("index.") || file.end_with?("__init__.py")
  file if (doc["functions"] || []).empty?
end.to_set

facade_free = Hash.new { |h, k| h[k] = Set.new }
file_graph.each do |src, dsts|
  next if barrels.include?(src)
  dsts.each { |dst| facade_free[src] << dst unless barrels.include?(dst) }
end

findings = []
{ "file" => facade_free, "directory" => dir_graph }.each do |granularity, graph|
  CorpusCommon.strongly_connected_components(graph).select { |c| c.size > 1 }.each do |component|
    members = component.sort
    if changed
      touches_changed = members.any? do |member|
        granularity == "file" ? changed.include?(member) : changed.any? { |c| File.dirname(c) == member }
      end
      next unless touches_changed
    end
    anchor = members.first
    anchor_line =
      edge_examples.keys.filter_map { |(a, b)| edge_examples[[a, b]].first if members.include?(a) && members.include?(b) }
                   .first.to_s[/:(\d+) /, 1] || 1
    findings << {
      rule_id: "arch-dependency-cycle",
      message: "#{granularity} dependency cycle (#{members.size} members): #{members.join(" <-> ")}",
      path: granularity == "file" ? anchor : (Dir.glob(File.join(repo, anchor, "*")).first ? "#{anchor}/" : anchor),
      line: anchor_line
    }
  end
end

puts "repo: #{repo}"
puts "files: #{files.size}  import edges: #{import_edge_count}  resolved call edges: #{call_edge_count}"
puts
findings.each { |f| puts "#{f[:path]}:#{f[:line]}  #{f[:message]}" }
puts "(no cycles)" if findings.empty?

CorpusCommon.write_sarif(options[:sarif], "espalier-cycle-report", RULES, findings) if options[:sarif]
