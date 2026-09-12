#!/usr/bin/env ruby
# frozen_string_literal: true

# Turn a stage-2 blocker list into the shape the mechanical repairs consume.
#
# The stage-1 loop already converts diagnostics into edits: each rule
# transcribes what the diagnostic states, anchored by `@@L=<line>@@C=<col>`.
# Stage 2 produces the same diagnostics for the LINKED closure, already
# translated from merged-package coordinates back to a real file and line -- so
# one closure round can drive the same repairs instead of one blocker per round.
#
#   ruby tools/selfhost_stage2_repair.rb tmp/stage2.json out.json
require 'json'

src = ARGV[0] or abort 'usage: selfhost_stage2_repair.rb <stage2.json> [out.json]'
out = ARGV[1] || 'tmp/stage2_repair.json'
data = JSON.parse(File.read(src))
records = data.is_a?(Hash) ? data.fetch('annotate', []) : data

rows = records.filter_map do |r|
  file = r['file']
  line = r['file_line'] || r['line']
  next nil unless file && line

  # The repair rules read the anchor, not the prose, so the message is passed
  # through untouched with the anchor appended.
  { 'file' => file, 'fn' => r['fn'] || '?', 'ok' => false,
    'error' => "#{r['message']} @@L=#{line}@@C=#{r['column'] || 1}" }
end

by_file = rows.group_by { |r| r['file'] }.transform_values(&:length).sort_by { |_f, n| -n }
File.write(out, JSON.pretty_generate(rows))
warn "#{rows.length} repairable blockers -> #{out}"
by_file.first(10).each { |f, n| warn format('  %4d  %s', n, f) }
