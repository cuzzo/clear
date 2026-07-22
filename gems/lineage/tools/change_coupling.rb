# frozen_string_literal: true

# Cross-module change coupling, from git history or (with --db) Lineage's
# own rename-stable logical-unit ledger.
#
# Counts commits in which two production source files (or, in --db mode,
# logical units) change together, keeping only pairs living in DIFFERENT
# modules (top-level directories) - same-directory co-change is expected and
# boring. Reports pairs by support (co-change commits) and confidence
# (co-changes / changes of the less-churned side).
#
# Default mode parses raw `git log --name-only`: fast, no prerequisites, but
# a renamed file's co-change history splits across its old and new name -
# undercounting support for anything renamed mid-history. Pass --db=PATH to
# an already-built lineage.db instead: coupling is computed over
# logical_units/events (unit_id survives a MOVE event, so a rename no
# longer fragments the count), and every result is still reported by its
# current path. This mode requires `lineage build --db PATH --repo .` to
# have already populated that database - a full-history scan, too
# expensive to run as a side effect of every invocation of this tool, so it
# stays opt-in rather than replacing the default.
#
# Usage: ruby change_coupling.rb REPO_ROOT [min_support] [--sarif=PATH] [--base=REF [--head=REF]] [--db=PATH]

require "set"
require "json"
require "open3"

RULES = [
  {
    "id" => "arch-change-coupling",
    "name" => "Cross-module change coupling",
    "shortDescription" => { "text" => "Files in different modules almost always change together" },
    "fullDescription" => {
      "text" => "High co-change support and confidence between files in different modules indicates a hidden dependency or a misplaced boundary: the logical unit spans the module split."
    },
    "defaultConfiguration" => { "level" => "note" }
  }
].freeze

args = []
options = { sarif: nil, base: nil, head: nil, db: nil }
ARGV.each do |arg|
  case arg
  when /\A--sarif=(.+)/ then options[:sarif] = Regexp.last_match(1)
  when /\A--base=(.+)/ then options[:base] = Regexp.last_match(1)
  when /\A--head=(.+)/ then options[:head] = Regexp.last_match(1)
  when /\A--db=(.+)/ then options[:db] = Regexp.last_match(1)
  else args << arg
  end
end

repo = File.expand_path(args[0] || ".")
min_support = (args[1] || 5).to_i

SOURCE_EXT = /\.(rb|py|js|mjs|cjs|ts|go|c|h|cc|cpp|cxx|hpp|hh|cs|java|kt|swift|lua|rs|zig|php)\z/
EXCLUDE = %r{(^|/)(test|tests|spec|specs|vendor|node_modules|examples?|bench(mark)?s?|dist|build|target|docs?|fixtures)(/|$)|(^|/)test_|[._](test|spec)\.}

def module_of(path)
  parts = path.split("/")
  parts.size > 1 ? parts[0] : "(root)"
end

# Bulk commits/change-sets (mass renames, reformats, generators) poison
# co-change counts - present in both modes, so factored out.
def reject_bulk_changesets!(changesets)
  changesets.reject! { |items| items.size > 20 || items.size < 2 }
end

# Shared core: given, per commit, the set of distinct items (file paths or
# unit_ids) touched, and a way to resolve an item to its module-grouping
# path, compute [support, confidence, distance, display_a, display_b] rows.
def coupled_pairs(changesets, min_support)
  changesets = changesets.map(&:uniq)
  reject_bulk_changesets!(changesets)

  item_changes = Hash.new(0)
  pair_changes = Hash.new(0)
  changesets.each do |items|
    items.each { |item| item_changes[item] += 1 }
    items.combination(2) do |a, b|
      path_a, path_b = yield(a), yield(b)
      next if module_of(path_a) == module_of(path_b) && File.dirname(path_a) == File.dirname(path_b)

      pair_changes[[a, b].sort] += 1
    end
  end

  pair_changes.filter_map do |(a, b), support|
    next if support < min_support

    confidence = support.to_f / [item_changes[a], item_changes[b]].min
    path_a, path_b = yield(a), yield(b)
    distance = module_of(path_a) == module_of(path_b) ? "cross-dir" : "cross-module"
    [support, confidence, distance, path_a, path_b]
  end
end

def rows_from_git_log(repo, min_support)
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

  [commits.size, coupled_pairs(commits, min_support) { |path| path }]
end

def rows_from_lineage_db(db_path, min_support)
  require "sqlite3"
  db = SQLite3::Database.new(db_path)

  # A renamed file owns several units (the class, each method); a MOVE
  # event is recorded per unit independently, and in practice not every
  # sibling unit's own move gets tracked as reliably as the file/class-
  # level one - resolving "this unit's own current path" per unit_id
  # would leave a lagging method still bucketed under the file's old
  # name, splitting one real rename into two separate (and now
  # incomplete) coupling entries. Building one GLOBAL old-name ->
  # new-name alias map from every MOVE event recorded by ANY unit, and
  # applying it to every raw event path uniformly, fixes that: as long
  # as at least one unit belonging to the file tracked the rename, every
  # other unit's stale path resolves through the same alias.
  alias_target = {}
  db.execute("SELECT unit_id, path, event_type, timestamp, id FROM events ORDER BY unit_id, timestamp, id")
    .group_by { |unit_id, *| unit_id }.each_value do |unit_events|
      unit_events.each_cons(2) do |(_, prev_path, *), (_, move_path, move_type, *)|
        alias_target[prev_path] = move_path if move_type == "MOVE" && prev_path != move_path
      end
    end
  canonical_path = lambda do |path|
    seen = Set.new
    current = path
    while (next_path = alias_target[current]) && seen.add?(current)
      current = next_path
    end
    current
  end

  commits = Hash.new { |h, k| h[k] = Set.new }
  db.execute("SELECT commit_hash, path FROM events").each do |commit_hash, path|
    canonical = canonical_path.call(path)
    next unless canonical&.match?(SOURCE_EXT) && !canonical.match?(EXCLUDE)

    commits[commit_hash] << canonical
  end
  changesets = commits.values.map(&:to_a)

  [changesets.size, coupled_pairs(changesets, min_support) { |path| path }]
end

commit_count, rows =
  if options[:db]
    unless File.file?(options[:db])
      abort "--db=#{options[:db]}: not found (run `lineage build --db #{options[:db]} --repo #{repo}` first?)"
    end
    rows_from_lineage_db(options[:db], min_support)
  else
    rows_from_git_log(repo, min_support)
  end

changed = nil
if options[:base]
  stdout, _stderr, status = Open3.capture3(
    "git", "-C", repo, "diff", "--name-only", "#{options[:base]}...#{options[:head] || "HEAD"}"
  )
  changed = stdout.lines.map(&:strip).reject(&:empty?).to_set if status.success?
end

rows = rows.select { |_, _, _, a, b| changed.include?(a) || changed.include?(b) } if changed

puts "repo: #{repo}  #{options[:db] ? "logical units" : "commits"} considered: #{commit_count}"
puts
puts "== Change-coupled pairs (support >= #{min_support}, sorted by support*confidence) =="
sorted_rows = rows.sort_by { |s, c, _, _, _| -(s * c) }
sorted_rows.first(15).each do |support, confidence, distance, a, b|
  printf("  s=%-3d c=%.2f %-12s %s <-> %s\n", support, confidence, distance, a, b)
end
puts "  (none)" if rows.empty?

if options[:sarif]
  findings = sorted_rows.first(50).map do |support, confidence, distance, a, b|
    {
      rule_id: "arch-change-coupling",
      level: "note",
      message: "#{a} and #{b} co-changed in #{support} commits (confidence #{confidence.round(2)}, #{distance})",
      path: a,
      line: 1
    }
  end
  document = {
    "$schema" => "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
    "version" => "2.1.0",
    "runs" => [
      {
        "tool" => { "driver" => { "name" => "lineage-change-coupling", "rules" => RULES } },
        "results" => findings.map do |finding|
          {
            "ruleId" => finding[:rule_id],
            "level" => finding[:level],
            "message" => { "text" => finding[:message] },
            "locations" => [
              {
                "physicalLocation" => {
                  "artifactLocation" => { "uri" => finding[:path] },
                  "region" => { "startLine" => finding[:line] }
                }
              }
            ]
          }
        end
      }
    ]
  }
  File.write(options[:sarif], JSON.pretty_generate(document))
end
