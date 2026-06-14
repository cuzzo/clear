#!/usr/bin/env ruby
# typed: strict
# Thresholded direct mutant runner for Ruby specs.

require 'optparse'
require 'fileutils'
require 'shellwords'
require 'sorbet-runtime'
require 'yaml'
require_relative 'support'

module RubySpecMutants
  extend T::Sig

  class Subject < T::Struct
    const :name, String
    const :expression, String
    const :requires, T::Array[String]
    const :specs, T::Array[String]
    const :min_coverage, Float
    const :max_timeouts, Integer
    const :hard_gate, T::Boolean
  end

  class SubjectResult < T::Struct
    const :subject, Subject
    const :ok, T::Boolean
    const :blocking, T::Boolean
  end

  SUBJECT_FILE = T.let(File.expand_path('src_subjects.yml', __dir__), String)
  DEFAULT_MAX_TIMEOUTS = 100

  class Options < T::Struct
    prop :subject, T.nilable(String)
    prop :since, T.nilable(String)
    prop :shard, T.nilable(MutationTesting::Shard)
    prop :out, String
    prop :list, T::Boolean
  end

  sig { params(value: String).returns(String) }
  def self.slug(value)
    value.gsub(/[^A-Za-z0-9]+/, '-').gsub(/\A-|-+\z/, '').downcase
  end

  sig { params(subject: String).returns(String) }
  def self.subject_expression(subject)
    subject.include?('#') ? subject : "#{subject}*"
  end

  sig { params(subject: Subject, since: T.nilable(String)).returns(T::Array[String]) }
  def self.mutant_argv(subject, since)
    argv = T.let(['bundle', 'exec', 'mutant', '--zombie', 'run', '--usage', 'opensource', '-I', 'src'], T::Array[String])
    subject.requires.each { |req| argv.concat(['-r', req]) }
    argv.concat([
      '--integration', 'rspec',
      '--jobs', ENV.fetch('MUTANT_JOBS', '32'),
    ])
    subject.specs.each { |spec| argv.concat(['--integration-argument', spec]) }
    argv.concat(['--since', since]) if since
    argv << subject.expression
    argv
  end

  sig { params(subject: Subject, summary: MutationTesting::MutantSummary).returns(SubjectResult) }
  def self.evaluate_summary(subject, summary)
    if summary.mutations.zero?
      return SubjectResult.new(subject: subject, ok: true, blocking: false)
    end

    ok = summary.selected_tests.positive? &&
      summary.coverage >= subject.min_coverage &&
      summary.timeouts <= subject.max_timeouts
    SubjectResult.new(subject: subject, ok: ok, blocking: !ok && subject.hard_gate)
  end

  sig { params(require_string: String).returns(T::Array[String]) }
  def self.parse_requires(require_string)
    tokens = Shellwords.split(require_string)
    requires = T.let([], T::Array[String])
    skip_next = T.let(false, T::Boolean)
    tokens.each_with_index do |token, index|
      if skip_next
        skip_next = false
        next
      end

      if token == '-r'
        req = tokens[index + 1]
        raise "dangling -r in mutant require string: #{require_string}" unless req
        requires << req
        skip_next = true
      else
        requires << token
      end
    end
    requires
  end

  sig { params(entry: T::Hash[String, T.untyped]).returns(Subject) }
  def self.subject_from_entry(entry)
    subject = String(entry['subject'])
    baseline = Float(entry['baseline'])
    specs = subject_specs(entry)
    expression = entry['expression'] ? String(entry['expression']) : subject_expression(subject)
    Subject.new(
      name: slug(subject),
      expression: expression,
      requires: parse_requires(String(entry['require'])),
      specs: specs,
      min_coverage: baseline,
      max_timeouts: Integer(entry.fetch('max_timeouts', DEFAULT_MAX_TIMEOUTS)),
      hard_gate: entry.fetch('hard_gate', false) == true
    )
  end

  sig { params(entry: T::Hash[String, T.untyped]).returns(T::Array[String]) }
  def self.subject_specs(entry)
    raw_specs = entry['specs']
    if raw_specs
      specs = T.cast(raw_specs, T::Array[T.untyped]).map { |spec| String(spec) }
      raise "empty specs for mutant subject #{entry['subject']}" if specs.empty?
      return specs
    end

    [String(entry.fetch('spec'))]
  end

  sig { returns(T::Array[Subject]) }
  def self.load_subjects
    raw = YAML.safe_load(File.read(SUBJECT_FILE), permitted_classes: [], aliases: false)
    entries = T.cast(raw, T::Array[T::Hash[String, T.untyped]])
    subjects = entries.map { |entry| subject_from_entry(entry) }
    duplicate_names = subjects.group_by(&:name).select { |_name, group| group.length > 1 }.keys
    raise "duplicate ruby mutant subject names: #{duplicate_names.join(', ')}" unless duplicate_names.empty?

    subjects.each do |subject|
      subject.specs.each do |spec|
        raise "missing mutant spec for #{subject.expression}: #{spec}" unless File.file?(spec)
      end
    end
    subjects.freeze
  end

  SUBJECTS = T.let(load_subjects, T::Array[Subject])

  sig { params(argv: T::Array[String]).returns(Options) }
  def self.parse_options(argv)
    opts = Options.new(subject: nil, since: nil, shard: nil, out: '/tmp/clear-ruby-mutants', list: false)
    OptionParser.new do |o|
      o.banner = 'Usage: ruby tools/mutants/ruby_specs.rb [--subject NAME] [--since REV] [--shard INDEX/COUNT] [--out DIR] [--list]'
      o.on('--subject NAME') { |v| opts.subject = v }
      o.on('--since REV') { |v| opts.since = v }
      o.on('--shard INDEX/COUNT') { |v| opts.shard = MutationTesting.parse_shard(v) }
      o.on('--out DIR') { |v| opts.out = File.expand_path(v) }
      o.on('--list') { opts.list = true }
      o.on('-h', '--help') { puts o; exit 0 }
    end.parse!(argv)
    opts
  end

  sig { params(subject: Subject, since: T.nilable(String), log_path: String).returns(SubjectResult) }
  def self.run_subject(subject, since, log_path)
    result = MutationTesting.run_cmd(mutant_argv(subject, since), allow_failure: true, log_path: log_path)
    summary = MutationTesting.parse_mutant_summary(result.output)
    unless summary
      puts "#{subject.name}: FAILED (could not parse mutant output; log #{log_path})"
      return SubjectResult.new(subject: subject, ok: false, blocking: subject.hard_gate)
    end

    if summary.mutations.zero?
      puts "#{subject.name}: skipped (0 mutations selected)"
      return SubjectResult.new(subject: subject, ok: true, blocking: false)
    end

    evaluated = evaluate_summary(subject, summary)

    status = evaluated.ok ? 'PASS' : 'FAIL'
    gate = subject.hard_gate ? 'hard' : 'advisory'
    puts "#{subject.name}: #{status} coverage=#{format('%.2f', summary.coverage)}% " \
         "mutations=#{summary.mutations} killed=#{summary.kills} alive=#{summary.alive} " \
         "timeouts=#{summary.timeouts} selected_tests=#{summary.selected_tests} " \
         "min=#{format('%.2f', subject.min_coverage)}% gate=#{gate} log=#{log_path}"
    evaluated
  end

  sig { params(opts: Options).returns(T::Array[Subject]) }
  def self.selected_subjects(opts)
    selected =
      if opts.subject
        wanted_expression = subject_expression(T.must(opts.subject))
        matches = SUBJECTS.select do |s|
          s.name == opts.subject || s.expression == opts.subject || s.expression == wanted_expression
        end
        raise "unknown ruby mutant subject: #{opts.subject}" if matches.empty?
        matches
      else
        SUBJECTS
      end

    MutationTesting.shard_items(selected, opts.shard)
  end

  sig { params(argv: T::Array[String]).returns(Integer) }
  def self.main(argv)
    opts = parse_options(argv)
    if opts.list
      selected_subjects(opts).each do |s|
        gate = s.hard_gate ? 'hard' : 'advisory'
        puts "#{s.name} #{s.expression} #{gate} min=#{format('%.2f', s.min_coverage)} specs=#{s.specs.join(',')}"
      end
      return 0
    end

    FileUtils.rm_rf(opts.out)
    FileUtils.mkdir_p(opts.out)
    subjects = selected_subjects(opts)
    if subjects.empty?
      puts "no ruby mutant subjects selected for shard #{MutationTesting.shard_label(opts.shard)}"
      return 0
    end

    puts "ruby mutant shard #{MutationTesting.shard_label(opts.shard)}: #{subjects.length} subject(s)"
    results = subjects.map do |subject|
      run_subject(subject, opts.since, File.join(opts.out, "#{subject.name}.log"))
    end
    results.any?(&:blocking) ? 1 : 0
  end
end

exit RubySpecMutants.main(ARGV) if $PROGRAM_NAME == __FILE__
