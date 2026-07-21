# frozen_string_literal: true

# WIP: module-level dependency-cycle report.
#
# Import edges are the primary graph (statically ~complete, like
# dependency-cruiser/import-linter); fact-mine call_graph_edges supplement
# them. fact-mine extracts imports internally (SymbolScope.explicit_imports)
# but does not emit them yet, so this WIP extracts import statements itself.
# Reports strongly-connected components at owner, file, and directory
# granularity - levels no compiler checks.
#
# Usage: ruby cycle_report.rb REPO_ROOT

require_relative "corpus_common"

repo = File.expand_path(ARGV[0] || ".")
files = CorpusCommon.production_files(repo)
abort "no production sources found" if files.empty?

# ---- import edge extraction (per-language, resolved to repo files) ----
file_set = files.to_set

def resolve_candidates(candidates, file_set)
  candidates.find { |c| file_set.include?(c) }
end

import_edges = []
files.each do |path|
  src = begin
    File.read(File.join(repo, path))
  rescue StandardError
    next
  end
  dir = File.dirname(path)
  ext = File.extname(path)

  case ext
  when ".py"
    base_pkg = path.sub(/\.py\z/, "").split("/")
    src.scan(/^\s*(?:from\s+([\w.]+)\s+import|import\s+([\w.]+))/) do |from_mod, plain_mod|
      mod = from_mod || plain_mod
      next unless mod
      if mod.start_with?(".")
        levels = mod[/\A\.+/].length
        rest = mod.sub(/\A\.+/, "").split(".").reject(&:empty?)
        anchor = base_pkg[0...-levels]
        target = (anchor + rest).join("/")
      else
        target = mod.tr(".", "/")
      end
      hit = resolve_candidates(["#{target}.py", "#{target}/__init__.py",
                                "src/#{target}.py", "src/#{target}/__init__.py"], file_set)
      import_edges << [path, hit] if hit
    end
  when ".js", ".mjs", ".cjs", ".ts"
    src.scan(/(?:from\s+|require\s*\(\s*)["'](\.[^"']+)["']/) do |(rel)|
      target = File.expand_path(File.join(dir, rel), "/").delete_prefix("/")
      hit = resolve_candidates([target, "#{target}.js", "#{target}.ts", "#{target}.mjs",
                                "#{target}/index.js", "#{target}/index.ts"], file_set)
      import_edges << [path, hit] if hit
    end
  when ".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".hh"
    src.scan(/^\s*#\s*include\s+"([^"]+)"/) do |(inc)|
      hit = resolve_candidates([inc, File.expand_path(File.join(dir, inc), "/").delete_prefix("/")],
                               file_set)
      import_edges << [path, hit] if hit
    end
  when ".java"
    src.scan(/^\s*import\s+(?:static\s+)?([\w.]+);/) do |(fqn)|
      parts = fqn.split(".")
      candidates = (1..parts.size).map { |i| parts[0, i].join("/") + ".java" }
      candidates += candidates.map { |c| "src/main/java/#{c}" }
      hit = resolve_candidates(candidates, file_set)
      import_edges << [path, hit] if hit
    end
  when ".rb"
    src.scan(/^\s*require_relative\s+["']([^"']+)["']/) do |(rel)|
      target = File.expand_path(File.join(dir, rel), "/").delete_prefix("/")
      hit = resolve_candidates(["#{target}.rb", target], file_set)
      import_edges << [path, hit] if hit
    end
    src.scan(/^\s*require\s+["']([^"']+)["']/) do |(mod)|
      hit = resolve_candidates(["lib/#{mod}.rb", "#{mod}.rb"], file_set)
      import_edges << [path, hit] if hit
    end
  when ".go"
    pkg_dirs = files.group_by { |f| File.dirname(f) }
    src.scan(%r{^\s*(?:[\w.]+\s+)?"([^"]+)"}) do |(imp)|
      tail = imp.split("/").last
      hit_dir = pkg_dirs.keys.find { |d| File.basename(d) == tail && d != dir }
      import_edges << [path, "#{hit_dir}/"] if hit_dir
    end
  end
end
import_edges.uniq!

facts = CorpusCommon.run_fact_mine("profile", repo, ["nil-kill"] + files)
methods = facts["methods"] || []
edges = facts["call_graph_edges"] || []

path_by_fn = {}
owner_dir = {}
methods.each do |m|
  fn_id = "fn:#{m["owner"]}##{m["name"]}"
  path_by_fn[fn_id] = m["path"]
  owner_dir[m["owner"]] = File.dirname(m["path"].to_s)
end

owner_graph = Hash.new { |h, k| h[k] = Set.new }
file_graph = Hash.new { |h, k| h[k] = Set.new }
dir_graph = Hash.new { |h, k| h[k] = Set.new }
edge_examples = Hash.new { |h, k| h[k] = [] }

resolved = 0
edges.each do |e|
  next unless e["kind"] == "internal_call"
  src = e["source"].to_s
  dst = e["target"].to_s
  s_owner = src[/\Afn:(.*)#/, 1]
  d_owner = dst[/\Afn:(.*)#/, 1]
  next unless s_owner && d_owner
  resolved += 1
  example = "#{src.sub('fn:', '')} -> #{dst.sub('fn:', '')}"
  if s_owner != d_owner
    owner_graph[s_owner] << d_owner
    edge_examples[[s_owner, d_owner]] << example
  end
  s_path = path_by_fn[src]
  d_path = path_by_fn[dst]
  next unless s_path && d_path
  if s_path != d_path
    file_graph[s_path] << d_path
    edge_examples[[s_path, d_path]] << example
  end
  s_dir = File.dirname(s_path)
  d_dir = File.dirname(d_path)
  if s_dir != d_dir
    dir_graph[s_dir] << d_dir
    edge_examples[[s_dir, d_dir]] << example
  end
end

import_edges.each do |src_path, dst_path|
  dst_path = dst_path.chomp("/")
  next if src_path == dst_path
  example = "import: #{src_path} -> #{dst_path}"
  file_graph[src_path] << dst_path
  edge_examples[[src_path, dst_path]] << example
  s_dir = File.dirname(src_path)
  d_dir = File.dirname(dst_path.chomp("/"))
  if s_dir != d_dir
    dir_graph[s_dir] << d_dir
    edge_examples[[s_dir, d_dir]] << example
  end
end

puts "repo: #{repo}"
puts "files: #{files.size}  methods: #{methods.size}  internal call edges: #{resolved}  import edges: #{import_edges.size}"
puts

[["owner", owner_graph], ["file", file_graph], ["directory", dir_graph]].each do |label, graph|
  sccs = CorpusCommon.strongly_connected_components(graph).select { |c| c.size > 1 }
  puts "== #{label}-level cycles: #{sccs.size} (graph: #{graph.size} nodes) =="
  sccs.sort_by { |c| -c.size }.first(8).each do |component|
    puts "  cycle of #{component.size}: #{component.sort.join(' <-> ')}"
    component.each_cons(2).first(3).each do |a, b|
      example = edge_examples[[a, b]].first || edge_examples[[b, a]].first
      puts "    e.g. #{example}" if example
    end
  end
  puts
end
