# frozen_string_literal: true

# WIP: cross-module change coupling from git history.
#
# Counts commits in which two production source files change together,
# keeping only pairs living in DIFFERENT modules (top-level directories) -
# same-directory co-change is expected and boring. Reports pairs by support
# (co-change commits) and confidence (co-changes / changes of the less-churned
# file). File-granularity is the WIP simplification; Lineage's rename-stable
# unit ledger is the intended upgrade path.
#
# Usage: ruby change_coupling.rb REPO_ROOT [min_support]

require "set"

repo = File.expand_path(ARGV[0] || ".")
min_support = (ARGV[1] || 5).to_i

SOURCE_EXT = /\.(rb|py|js|mjs|cjs|ts|go|c|h|cc|cpp|cxx|hpp|hh|cs|java|kt|swift|lua|rs|zig|php)\z/
EXCLUDE = %r{(^|/)(test|tests|spec|specs|vendor|node_modules|examples?|bench(mark)?s?|dist|build|target|docs?|fixtures)(/|$)|(^|/)test_|[._](test|spec)\.}

def module_of(path)
  parts = path.split("/")
  parts.size > 1 ? parts[0] : "(root)"
end

commits = []
current = nil
IO.popen(["git", "-C", repo, "log", "--no-merges", "--format=%x01%H", "--name-only"]) do |io|
  io.each_line do |line|
    line = line.strip
    if line.start_with?("\x01")
      commits << current if current
      current = []
    elsif !line.empty? && line.match?(SOURCE_EXT) && !line.match?(EXCLUDE)
      current << line if current
    end
  end
end
commits << current if current

# Bulk commits (mass renames, reformats, generators) poison co-change counts.
commits.reject! { |files| files.size > 20 || files.size < 2 }

file_changes = Hash.new(0)
pair_changes = Hash.new(0)
commits.each do |files|
  files = files.uniq
  files.each { |f| file_changes[f] += 1 }
  files.combination(2) do |a, b|
    next if module_of(a) == module_of(b) && File.dirname(a) == File.dirname(b)
    pair_changes[[a, b].sort] += 1
  end
end

rows = pair_changes.filter_map do |(a, b), support|
  next if support < min_support
  confidence = support.to_f / [file_changes[a], file_changes[b]].min
  distance = module_of(a) == module_of(b) ? "cross-dir" : "cross-module"
  [support, confidence, distance, a, b]
end

puts "repo: #{repo}  commits considered: #{commits.size}"
puts
puts "== Change-coupled pairs (support >= #{min_support}, sorted by support*confidence) =="
rows.sort_by { |s, c, _, _, _| -(s * c) }.first(15).each do |support, confidence, distance, a, b|
  printf("  s=%-3d c=%.2f %-12s %s <-> %s\n", support, confidence, distance, a, b)
end
puts "  (none)" if rows.empty?
