#! /usr/bin/env ruby
# Branch-gap TRIAGE: collapse never-taken arms to their enclosing method.
#
# You do not triage 955 branches. You triage the ~N methods that contain
# them. A never-taken arm's fill-modality is a property of the DECISION
# the enclosing method makes, not of the arm:
#
#   - a dark arm in an escape / frame / cleanup / move decision is a
#     latent UAF / double-free / leak, reachable only by a VALID program
#     of some shape the corpus never wrote -> fuzz template axis (scales
#     combinatorially; one axis value covers a whole arm family) + mutant.
#   - a dark arm in a diagnostic / error builder is reachable only by an
#     INVALID program. Fuzz emits valid self-checking programs by
#     construction, so fuzz can NEVER reach it -> negative unit spec
#     (deterministic, one per error cluster).
#   - a dark arm guarding an impossible / defensive case (raise
#     unreachable, exhaustive-when else) -> accept + annotate. No test.
#   - whole-program integration .cht almost never fills a branch gap:
#     92 real programs moved this set 50/1005 arms. Not the tool.
#
# This script does the collapse and the ranking. It does NOT classify by
# regexing arm source lines (that is the fake-value grep) — it groups by
# enclosing `def` so a human reads the DECISION, then assigns modality.
#
# Usage: ruby tools/branch_gap_triage.rb [src/file.rb ...]

require 'json'

ROOT = File.expand_path('..', __dir__)
RESULTSET = File.join(ROOT, 'coverage', '.resultset.json')
DEFAULT_FILES = %w[
  src/mir/escape_analysis.rb
  src/mir/control_flow.rb
  src/mir/mir_lowering.rb
].freeze

abort "no #{RESULTSET}" unless File.exist?(RESULTSET)

merged = Hash.new
JSON.parse(File.read(RESULTSET)).each_value do |entry|
  (entry['coverage'] || {}).each do |path, cov|
    next unless cov.is_a?(Hash) && cov['branches']
    dst = (merged[path] ||= {})
    cov['branches'].each do |parent, arms|
      d = (dst[parent] ||= Hash.new(0))
      arms.each { |arm, n| d[arm] = d[arm] + (n || 0) }
    end
  end
end

# line -> enclosing def name (nearest preceding `def` at lower indent),
# plus that def's start line, by a single top-down scan of the source.
def method_index(lines)
  idx = {}
  stack = [] # [indent, name, start_line]
  lines.each_with_index do |raw, i|
    ln = i + 1
    if (m = raw.match(/^(\s*)def\s+(self\.)?([A-Za-z0-9_?!]+)/))
      ind = m[1].length
      stack.pop while stack.any? && stack.last[0] >= ind
      stack.push([ind, m[3], ln])
    elsif (e = raw.match(/^(\s*)end\b/))
      ind = e[1].length
      stack.pop if stack.any? && stack.last[0] == ind
    end
    idx[ln] = stack.last ? [stack.last[1], stack.last[2]] : ['(top-level)', 0]
  end
  idx
end

targets = ARGV.empty? ? DEFAULT_FILES : ARGV
targets.each do |rel|
  abspath = File.join(ROOT, rel)
  branches = merged[abspath]
  next unless branches
  lines = File.readlines(abspath)
  midx = method_index(lines)

  by_method = Hash.new { |h, k| h[k] = [] }
  total_by_method = Hash.new(0)
  branches.each do |_p, arms|
    arms.each do |arm, count|
      a = arm.gsub(/[\[\]:]/, '').split(',').map(&:strip)
      line = a[2].to_i
      meth, mstart = midx[line] || ['(top-level)', 0]
      key = [meth, mstart]
      total_by_method[key] += 1
      by_method[key] << [line, a[0]] if count.to_i.zero?
    end
  end

  ranked = by_method.reject { |_, v| v.empty? }
                     .sort_by { |(_, _), v| -v.size }
  puts "\n##### #{rel} — #{ranked.size} methods carry dark arms " \
       "(#{by_method.values.sum(&:size)} arms)"
  puts format('  %-42s %5s %5s   %s', 'method', 'dark', 'tot', 'dark-arm lines')
  ranked.each do |(meth, mstart), arms|
    tot = total_by_method[[meth, mstart]]
    ls = arms.map(&:first).uniq.sort
    shown = ls.first(12).join(',')
    shown += ",+#{ls.size - 12}" if ls.size > 12
    puts format('  %-42s %5d %5d   %s', "#{meth}@#{mstart}", arms.size, tot, shown)
  end
end
