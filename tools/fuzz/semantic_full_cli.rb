#!/usr/bin/env ruby
# Report or emit the complete, per-family semantic campaign.

require 'json'
require 'optparse'
require_relative 'semantic_full'

options = { depth: 3, seed: 1, target: 1_000, case_id: nil, json: false }
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby tools/fuzz/semantic_full_cli.rb [options]'
  parser.on('--depth N', Integer) { |value| options[:depth] = value }
  parser.on('--seed N', Integer) { |value| options[:seed] = value }
  parser.on('--target-per-family N', Integer) { |value| options[:target] = value }
  parser.on('--case ID') { |value| options[:case_id] = value }
  parser.on('--json') { options[:json] = true }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!

suite = SemanticFull::Suite.new(
  parser_path: File.expand_path('../../compiler/ruby/ast/parser.rb', __dir__),
  depth: options.fetch(:depth),
  seed: options.fetch(:seed),
  target_per_family: options.fetch(:target)
)

if (case_id = options.fetch(:case_id))
  item = suite.cases.find { |candidate| candidate.id == case_id } or raise "unknown semantic full case #{case_id}"
  payload = { id: item.id, family: item.family, topology: item.topology.id, derivation: item.fragment.derivation.to_h, source: item.source }
  puts(options.fetch(:json) ? JSON.pretty_generate(payload) : item.source)
else
  payload = suite.report.merge(case_ids: suite.cases.map(&:id))
  puts(options.fetch(:json) ? JSON.pretty_generate(payload) : suite.report.inspect)
end
