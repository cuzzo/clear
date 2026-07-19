#!/usr/bin/env ruby
# Differential mutation runner for the type-directed semantic fuzz suite.

require 'fileutils'
require 'json'
require 'optparse'
require 'time'
require_relative 'support'

module SemanticMutants
  ROOT = MutationTesting::ROOT
  DEFAULT_SUBJECT = 'ClearParser#parse_binary_op'
  DEFAULT_SEMANTIC_LIMIT = 148
  SEMANTIC_SPEC = 'compiler/spec/semantic_equivalence_integration_spec.rb'
  SUBJECTS = {
    DEFAULT_SUBJECT => {
      requires: %w[ast/lexer ast/parser],
      specs: %w[
        compiler/spec/ast_coverage_burndown_spec.rb
        compiler/spec/parser_mutation_contract_spec.rb
      ],
    },
  }.freeze

  module_function

  def mutant_ids(output)
    output.scan(/^evil:.*:([0-9a-f]+)$/).flatten.uniq.sort
  end

  def evaluate(baseline_output, semantic_output)
    baseline = MutationTesting.parse_mutant_summary(baseline_output) or raise 'missing baseline mutant summary'
    semantic = MutationTesting.parse_mutant_summary(semantic_output) or raise 'missing semantic mutant summary'
    raise 'paired mutation counts differ' unless baseline.mutations == semantic.mutations
    raise 'baseline mutation run timed out' unless baseline.timeouts.zero?
    raise 'semantic mutation run timed out' unless semantic.timeouts.zero?
    raise 'semantic spec was not selected' unless semantic.selected_tests > baseline.selected_tests

    baseline_alive = mutant_ids(baseline_output)
    semantic_alive = mutant_ids(semantic_output)
    raise 'baseline alive-mutant identities are incomplete' unless baseline_alive.length == baseline.alive
    raise 'semantic alive-mutant identities are incomplete' unless semantic_alive.length == semantic.alive
    regressed = semantic_alive - baseline_alive
    raise "semantic run regressed alive mutants: #{regressed.join(', ')}" unless regressed.empty?

    newly_killed = baseline_alive - semantic_alive
    {
      baseline: summary_hash(baseline),
      semantic: summary_hash(semantic),
      newly_killed: newly_killed,
      newly_killed_count: newly_killed.length,
    }
  end

  def summary_hash(summary)
    {
      mutations: summary.mutations,
      killed: summary.kills,
      alive: summary.alive,
      timeouts: summary.timeouts,
      selected_tests: summary.selected_tests,
      coverage: summary.coverage,
    }
  end

  def argv(subject, config, jobs:, timeout:, semantic:)
    args = ['bundle', 'exec', 'mutant', '--zombie', 'run', '--usage', 'opensource', '-I', 'compiler/ruby']
    config.fetch(:requires).each { |required| args.concat(['-r', required]) }
    args.concat(['--integration', 'rspec', '--jobs', jobs.to_s, '--mutation-timeout', timeout.to_s])
    specs = config.fetch(:specs) + (semantic ? [SEMANTIC_SPEC] : [])
    specs.each { |spec| args.concat(['--integration-argument', spec]) }
    args << subject
  end

  def run(argv)
    options = { subject: DEFAULT_SUBJECT, out: '/tmp/clear-semantic-mutants', jobs: 32, timeout: 30, min_new_kills: 1 }
    OptionParser.new do |parser|
      parser.on('--subject SUBJECT') { |value| options[:subject] = value }
      parser.on('--out DIR') { |value| options[:out] = File.expand_path(value) }
      parser.on('--jobs N', Integer) { |value| options[:jobs] = value }
      parser.on('--timeout N', Integer) { |value| options[:timeout] = value }
      parser.on('--min-new-kills N', Integer) { |value| options[:min_new_kills] = value }
      parser.on('-h', '--help') { puts parser; return 0 }
    end.parse!(argv)

    subject = options.fetch(:subject)
    config = SUBJECTS.fetch(subject) { raise "unsupported semantic mutant subject #{subject}" }
    out = options.fetch(:out)
    FileUtils.mkdir_p(out)
    previous_limit = ENV['SEMANTIC_MUTATION_LIMIT']
    ENV['SEMANTIC_MUTATION_LIMIT'] = DEFAULT_SEMANTIC_LIMIT.to_s
    begin
      baseline_result = MutationTesting.run_cmd(
        self.argv(subject, config, jobs: options.fetch(:jobs), timeout: options.fetch(:timeout), semantic: false),
        allow_failure: true,
        log_path: File.join(out, 'baseline.log')
      )
      semantic_result = MutationTesting.run_cmd(
        self.argv(subject, config, jobs: options.fetch(:jobs), timeout: options.fetch(:timeout), semantic: true),
        allow_failure: true,
        log_path: File.join(out, 'semantic.log')
      )
    ensure
      previous_limit ? ENV['SEMANTIC_MUTATION_LIMIT'] = previous_limit : ENV.delete('SEMANTIC_MUTATION_LIMIT')
    end

    comparison = evaluate(baseline_result.output, semantic_result.output)
    facts = {
      schema: 'semantic-mutant-delta/v1',
      generated_at: Time.now.utc.iso8601,
      subject: subject,
      source: 'gems/lineage/tools/mutant-converters/semantic_mutant.rb',
      semantic_spec: SEMANTIC_SPEC,
    }.merge(comparison)
    File.write(File.join(out, 'facts.json'), JSON.pretty_generate(facts))
    puts "#{subject}: baseline=#{comparison.fetch(:baseline).fetch(:killed)}/#{comparison.fetch(:baseline).fetch(:mutations)} " \
      "semantic=#{comparison.fetch(:semantic).fetch(:killed)}/#{comparison.fetch(:semantic).fetch(:mutations)} " \
      "newly_killed=#{comparison.fetch(:newly_killed_count)} timeouts=0"
    puts "wrote #{File.join(out, 'facts.json')}"
    comparison.fetch(:newly_killed_count) >= options.fetch(:min_new_kills) ? 0 : 1
  end
end

exit SemanticMutants.run(ARGV) if $PROGRAM_NAME == __FILE__
