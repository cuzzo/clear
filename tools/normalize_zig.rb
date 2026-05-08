#!/usr/bin/env ruby
# tools/normalize_zig.rb
#
# Normalize auto-generated counter-based identifiers in transpiled .zig
# files to stable, content-deterministic names. Used by the
# `#TRANSPILE_PURE` workflow before diffing two trees.
#
# Background: the transpiler uses `node.object_id.abs` to disambiguate
# nested-WITH guard variables, MATCH binding aliases, snapshot guards,
# acquire-block labels, etc. `object_id` is process-instance-specific
# and shifts whenever Ruby allocation order changes — any refactor that
# adds or removes object allocations produces different numbers even
# when the generated Zig is functionally identical.
#
# We can't replace `object_id` in the transpiler itself: object_id
# uniquely identifies cloned AST subtrees, which pipeline rewriting can
# produce. Source-position-based naming would silently collide on clones
# that share (line, column).
#
# This script keeps the transpiler unchanged and normalizes the OUTPUT
# instead. For each file independently:
#   1. Find every `__<word>_<digits>` identifier where digits is large
#      enough (MIN_DIGITS) to plausibly be an object_id.
#   2. Number unique values by FIRST OCCURRENCE per `<word>` prefix.
#   3. Replace each occurrence with `__<word>_N<index>`.
#
# Two files that produce structurally-equivalent but allocation-shifted
# identifiers normalize to the same content. Two files with semantically
# different counter counts or orderings normalize to different content
# (the diff still surfaces real changes).
#
# Collision safety: each unique original number gets its OWN index, so
# two distinct identifiers in the source remain distinct in the
# normalized output. We never merge identifiers that were unique.
#
# Usage:
#   bundle exec ruby tools/normalize_zig.rb <path>...
#   # paths can be files or directories; .zig files processed in place.

require "find"

# Match: `__<word>_<digits>` where the digits aren't preceded by an
# alpha-num (so the `__` boundary is real), and are followed by `_`,
# end-of-string, or any non-identifier char (so we cleanly split
# concatenated counter names like `__acq_2760___c_guard_2760` into two
# matches: `__acq_2760` and `__c_guard_2760`).
#
# `\b` doesn't work here because `_` is a word character in Ruby regex,
# so word boundaries don't fire between underscored counter prefixes.
#
# MIN_DIGITS=4 because object_id.abs values seen in practice are 4-5
# digits. User numeric literals in transpiled Zig (array sizes, loop
# bounds) are typically 1-3 digits and rarely use the `__<word>_`
# leading-context. The leading `__` is the primary filter.
MIN_DIGITS = 4
PATTERN = /(?<![A-Za-z0-9])(__[a-zA-Z][\w]*?)_(\d{#{MIN_DIGITS},})(?=_|[^A-Za-z0-9_]|$)/

def normalize_file(path)
  text = File.read(path)
  return false unless text =~ PATTERN

  # Per-prefix first-occurrence numbering. `_guard_` and `_snap_` get
  # independent N1/N2/... sequences since they're separate name spaces.
  index_for = Hash.new { |h, k| h[k] = {} }

  normalized = text.gsub(PATTERN) do
    prefix = $1   # e.g. __c_guard, __vars_snap, __with, __acq
    num    = $2

    map = index_for[prefix]
    map[num] ||= "N#{map.size + 1}"
    "#{prefix}_#{map[num]}"
  end

  return false if normalized == text
  File.write(path, normalized)
  true
end

def collect_files(paths)
  paths.flat_map do |p|
    if File.directory?(p)
      result = []
      Find.find(p) { |f| result << f if f.end_with?(".zig") }
      result
    elsif File.file?(p)
      [p]
    else
      $stderr.puts "warn: not found: #{p}"
      []
    end
  end
end

if __FILE__ == $0
  paths = ARGV
  if paths.empty?
    $stderr.puts "Usage: #{$0} <path>..."
    exit 1
  end

  files = collect_files(paths)
  changed = 0
  files.each { |f| changed += 1 if normalize_file(f) }
  puts "Normalized #{changed} of #{files.size} .zig file(s)."
end
