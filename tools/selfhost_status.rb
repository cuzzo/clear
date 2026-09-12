#!/usr/bin/env ruby
# frozen_string_literal: true

# One place to read how far the self-host actually is.
#
# The numbers live in artifacts written by different tools at different times,
# and quoting a stale one has burned this migration repeatedly -- a stage-1
# figure derived from a tracked failing set, a stage-2 round that read cached
# blanks as green. Each line below says where its number came from and how old
# it is, so a stale number is visible as stale rather than quoted as fact.
require 'json'

ROOT = File.expand_path('..', __dir__)
S = ENV['CLEAR_SELFHOST_SCRATCH'] || File.join(ROOT, 'tmp')

def age(path)
  return 'missing' unless File.exist?(path)

  mins = ((Time.now - File.mtime(path)) / 60).round
  mins < 90 ? "#{mins}m ago" : "#{(mins / 60.0).round(1)}h ago"
end

def stage1(path)
  return ['stage 1  CLEAR->Zig, callees stubbed', 'no measurement', path] unless File.exist?(path)

  rs = JSON.parse(File.read(path))
  ok = rs.count { |r| r['ok'] }
  harness = rs.count { |r| !r['ok'] && (r['error'] || '').include?('probe harness:') }
  note = harness.zero? ? '' : "  (#{harness} rows unmeasured: harness broke)"
  ['stage 1  CLEAR->Zig, callees stubbed',
   format('%d/%d = %.2f%%%s', ok, rs.length, 100.0 * ok / rs.length, note), path]
end

def stage2(path)
  return ['stage 2a/2b  linked closure', 'no measurement', path] unless File.exist?(path)

  d = JSON.parse(File.read(path))
  a = d.is_a?(Hash) ? d.fetch('annotate', []) : d
  l = d.is_a?(Hash) ? d.fetch('lower', []) : []
  u = d.is_a?(Hash) ? d.fetch('units', []) : []
  ['stage 2a/2b  linked closure',
   "#{a.length} annotation blockers, #{l.length} unlowered fns, #{u.length} failed units", path]
end

rows = [
  stage1(File.join(S, 'stage1_now.json')),
  stage2(File.join(S, 'stage2.json')),
  ['stage 2c  zig build-exe', File.exist?(File.join(ROOT, 'tmp/stage2/stage2_entry')) ? 'binary present' : 'no binary', File.join(ROOT, 'tmp/stage2/stage2_entry')],
  ['stage 3  byte compatibility', File.exist?(File.join(ROOT, 'tmp/annotator-compat/summary.json')) ? JSON.parse(File.read(File.join(ROOT, 'tmp/annotator-compat/summary.json')))['mismatches'].length.to_s + ' mismatches' : 'never run', File.join(ROOT, 'tmp/annotator-compat/summary.json')],
]

puts format('%-36s %-52s %s', 'STAGE', 'RESULT', 'AS OF')
rows.each { |name, result, path| puts format('%-36s %-52s %s', name, result, age(path)) }
puts
puts 'static gates (each ~1s, run them before spending a build):'
%w[dup_check visibility_check predicate_check unwrap_check parse_check].each do |gate|
  script = File.join(ROOT, 'tools', "selfhost_#{gate}.rb")
  next unless File.exist?(script)

  out = `cd #{ROOT} && bundle exec ruby #{script} 2>/dev/null | tail -1`.strip
  puts format('  %-20s %s', gate, out)
end
