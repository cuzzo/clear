#!/usr/bin/env ruby
# typed: strict
# Thresholded direct mutant runner for Ruby specs.

require 'optparse'
require 'fileutils'
require 'sorbet-runtime'
require_relative 'support'

module RubySpecMutants
  extend T::Sig

  class Subject < T::Struct
    const :name, String
    const :expression, String
    const :requires, T::Array[String]
    const :spec, String
    const :min_coverage, Float
    const :max_timeouts, Integer
  end

  SUBJECTS = T.let([
    Subject.new(
      name: 'mir-inline-alloc-metadata',
      expression: 'MIR::InlineAllocMetadata*',
      requires: ['backends/transpiler'],
      spec: 'spec/mir_gap_burn_spec.rb',
      min_coverage: 92.0,
      max_timeouts: 2
    ),
    Subject.new(
      name: 'lexer',
      expression: 'Lexer*',
      requires: ['ast/lexer'],
      spec: 'spec/lexer_spec.rb',
      min_coverage: 76.0,
      max_timeouts: 70
    ),
  ].freeze, T::Array[Subject])

  class Options < T::Struct
    prop :subject, T.nilable(String)
    prop :since, T.nilable(String)
    prop :out, String
    prop :list, T::Boolean
  end

  sig { params(argv: T::Array[String]).returns(Options) }
  def self.parse_options(argv)
    opts = Options.new(subject: nil, since: nil, out: '/tmp/clear-ruby-mutants', list: false)
    OptionParser.new do |o|
      o.banner = 'Usage: ruby tools/mutants/ruby_specs.rb [--subject NAME] [--since REV] [--out DIR] [--list]'
      o.on('--subject NAME') { |v| opts.subject = v }
      o.on('--since REV') { |v| opts.since = v }
      o.on('--out DIR') { |v| opts.out = File.expand_path(v) }
      o.on('--list') { opts.list = true }
      o.on('-h', '--help') { puts o; exit 0 }
    end.parse!(argv)
    opts
  end

  sig { params(subject: Subject, since: T.nilable(String), log_path: String).returns(T::Boolean) }
  def self.run_subject(subject, since, log_path)
    argv = T.let(['bundle', 'exec', 'mutant', 'run', '--usage', 'opensource', '-I', 'src'], T::Array[String])
    subject.requires.each { |req| argv.concat(['-r', req]) }
    argv.concat([
      '--integration', 'rspec',
      '--integration-argument', subject.spec,
      '--jobs', ENV.fetch('MUTANT_JOBS', '32'),
    ])
    argv.concat(['--since', since]) if since
    argv << subject.expression

    result = MutationTesting.run_cmd(argv, allow_failure: true, log_path: log_path)
    summary = MutationTesting.parse_mutant_summary(result.output)
    unless summary
      puts "#{subject.name}: FAILED (could not parse mutant output; log #{log_path})"
      return false
    end

    if summary.mutations.zero?
      puts "#{subject.name}: skipped (0 mutations selected)"
      return true
    end

    ok = summary.selected_tests.positive? &&
      summary.coverage >= subject.min_coverage &&
      summary.timeouts <= subject.max_timeouts

    status = ok ? 'PASS' : 'FAIL'
    puts "#{subject.name}: #{status} coverage=#{format('%.2f', summary.coverage)}% " \
         "mutations=#{summary.mutations} killed=#{summary.kills} alive=#{summary.alive} " \
         "timeouts=#{summary.timeouts} selected_tests=#{summary.selected_tests} " \
         "min=#{format('%.2f', subject.min_coverage)}% log=#{log_path}"
    ok
  end

  sig { params(opts: Options).returns(T::Array[Subject]) }
  def self.selected_subjects(opts)
    return SUBJECTS unless opts.subject

    selected = SUBJECTS.select { |s| s.name == opts.subject || s.expression == opts.subject }
    raise "unknown ruby mutant subject: #{opts.subject}" if selected.empty?
    selected
  end

  sig { params(argv: T::Array[String]).returns(Integer) }
  def self.main(argv)
    opts = parse_options(argv)
    if opts.list
      SUBJECTS.each do |s|
        puts "#{s.name} #{s.expression} min=#{format('%.2f', s.min_coverage)} spec=#{s.spec}"
      end
      return 0
    end

    FileUtils.rm_rf(opts.out)
    FileUtils.mkdir_p(opts.out)
    results = selected_subjects(opts).map do |subject|
      run_subject(subject, opts.since, File.join(opts.out, "#{subject.name}.log"))
    end
    results.all? ? 0 : 1
  end
end

exit RubySpecMutants.main(ARGV) if $PROGRAM_NAME == __FILE__
