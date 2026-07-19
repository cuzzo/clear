#!/usr/bin/env ruby
# Inspect, reproduce, and structurally reduce semantic fuzz derivations.

require 'json'
require 'optparse'
require_relative 'semantic_equivalence'

options = {
  depth: 1,
  seed: 1,
  limit: nil,
  shard: nil,
  case_id: nil,
  shrink: false,
  json: false,
}

OptionParser.new do |parser|
  parser.banner = 'Usage: ruby tools/fuzz/semantic.rb [options]'
  parser.on('--depth N', Integer) { |value| options[:depth] = value }
  parser.on('--seed N', Integer) { |value| options[:seed] = value }
  parser.on('--limit N', Integer) { |value| options[:limit] = value }
  parser.on('--shard I/N') { |value| options[:shard] = value }
  parser.on('--case ID') { |value| options[:case_id] = value }
  parser.on('--shrink') { options[:shrink] = true }
  parser.on('--json') { options[:json] = true }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!

parser_path = File.expand_path('../../compiler/ruby/ast/parser.rb', __dir__)
suite = SemanticEquivalence::Suite.mvp(
  parser_path: parser_path,
  max_depth: options.fetch(:depth),
  seed: options.fetch(:seed),
  limit: options.fetch(:limit),
  shard: options.fetch(:shard)
)

case_id = options.fetch(:case_id)
unless case_id
  body = suite.report.merge(case_ids: suite.cases.map(&:id))
  puts(options.fetch(:json) ? JSON.pretty_generate(body) : body.inspect)
  exit 0
end

item = suite.all_cases.find { |candidate| candidate.id == case_id } or raise "unknown semantic case #{case_id}"
if options.fetch(:shrink)
  fragment = suite.fragments.find { |candidate| candidate.derivation.fingerprint == item.derivation.fingerprint }
  replacement = SemanticEquivalence::Shrinker.new(suite.fragments).minimal(fragment)
  consumer = suite.consumers.find { |candidate| candidate.id == item.consumer_id }
  source = consumer.render.call(replacement)
  reduced = SemanticEquivalence::Case.new(
    id: "#{replacement.goal.type}-#{replacement.fingerprint}-#{consumer.id}",
    production_id: replacement.productions.first,
    consumer_id: consumer.id,
    source: source,
    derivation: replacement.derivation,
    expected_type: SemanticEquivalence::VALUES.fetch(replacement.goal.type).clear_type,
    expected_value: replacement.goal.value
  )
  puts(options.fetch(:json) ? JSON.pretty_generate(reduced.failure_context(seed: suite.seed)) : reduced.source)
else
  puts(options.fetch(:json) ? JSON.pretty_generate(item.failure_context(seed: suite.seed)) : item.source)
end
