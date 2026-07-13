#!/usr/bin/env ruby
# typed: strict
# Thresholded direct mutant runner and mutant-facts/v1 converter for Ruby specs.

require 'optparse'
require 'fileutils'
require 'json'
require 'shellwords'
require 'sorbet-runtime'
require 'time'
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
    const :summary, T.nilable(MutationTesting::MutantSummary), default: nil
  end

  SUBJECT_FILE = T.let(File.expand_path('src_subjects.yml', __dir__), String)
  COMPILER_RUBY_LOAD_PATH = T.let(File.join(MutationTesting::ROOT, 'compiler', 'ruby'), String)
  RUBY_SOURCE_ROOTS = T.let(['compiler/ruby', 'tools'].freeze, T::Array[String])
  DEFAULT_MAX_TIMEOUTS = 100

  class Options < T::Struct
    prop :subject, T.nilable(String)
    prop :since, T.nilable(String)
    prop :shard, T.nilable(MutationTesting::Shard)
    prop :out, String
    prop :facts, T.nilable(String), default: nil
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
    argv = T.let(['bundle', 'exec', 'mutant', '--zombie', 'run', '--usage', 'opensource', '-I', 'compiler/ruby'], T::Array[String])
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
      return SubjectResult.new(subject: subject, ok: true, blocking: false, summary: summary)
    end

    ok = summary.selected_tests.positive? &&
      summary.coverage >= subject.min_coverage &&
      summary.timeouts <= subject.max_timeouts
    SubjectResult.new(subject: subject, ok: ok, blocking: !ok && subject.hard_gate, summary: summary)
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
      specs = T.cast(raw_specs, T::Array[T.untyped]).map { |spec| resolve_spec_path(String(spec)) }
      raise "empty specs for mutant subject #{entry['subject']}" if specs.empty?
      return specs
    end

    [resolve_spec_path(String(entry.fetch('spec')))]
  end

  sig { params(spec: String).returns(String) }
  def self.resolve_spec_path(spec)
    return spec if File.file?(File.join(MutationTesting::ROOT, spec))

    candidate = spec.sub(/\Aspec\//, 'compiler/spec/')
    return candidate if candidate != spec && File.file?(File.join(MutationTesting::ROOT, candidate))

    spec
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
    opts = Options.new(subject: nil, since: nil, shard: nil, out: '/tmp/clear-ruby-mutants', facts: nil, list: false)
    OptionParser.new do |o|
      o.banner = 'Usage: ruby gems/lineage/tools/mutant-converters/ruby_mutant.rb [--subject NAME] [--since REV] [--shard INDEX/COUNT] [--out DIR] [--facts FILE] [--list]'
      o.on('--subject NAME') { |v| opts.subject = v }
      o.on('--since REV') { |v| opts.since = v }
      o.on('--shard INDEX/COUNT') { |v| opts.shard = MutationTesting.parse_shard(v) }
      o.on('--out DIR') { |v| opts.out = File.expand_path(v) }
      o.on('--facts FILE') { |v| opts.facts = File.expand_path(v) }
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
      return SubjectResult.new(subject: subject, ok: true, blocking: false, summary: summary)
    end

    evaluated = evaluate_summary(subject, summary)

    status = evaluated.ok ? 'PASS' : 'FAIL'
    gate = subject.hard_gate ? 'hard' : 'advisory'
    puts "#{subject.name}: #{status} coverage=#{format('%.2f', summary.coverage)}% " \
         "mutations=#{summary.mutations} killed=#{summary.kills} alive=#{summary.alive} " \
         "timeouts=#{summary.timeouts} selected_tests=#{summary.selected_tests} " \
         "min=#{format('%.2f', subject.min_coverage)}% gate=#{gate} log=#{log_path}"
    SubjectResult.new(subject: subject, ok: evaluated.ok, blocking: evaluated.blocking, summary: summary)
  end

  sig { params(results: T::Array[SubjectResult], path: String).void }
  def self.write_facts(results, path)
    body = {
      schema: 'mutant-facts/v1',
      generated_at: Time.now.utc.iso8601,
      source: 'gems/lineage/tools/mutant-converters/ruby_mutant.rb',
      language: 'ruby',
      mutation_kind: 'stochastic',
      subjects: results.filter_map { |result| fact_for_result(result) },
    }
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(body))
  end

  sig { params(result: SubjectResult).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.fact_for_result(result)
    summary = result.summary
    return nil unless summary

    subject = result.subject
    {
      method: subject.expression,
      file: source_file_for(subject),
      kill_rate: summary.coverage,
      gate_status: subject.hard_gate ? 'hard' : 'advisory',
      mutations: summary.mutations,
      killed: summary.kills,
      alive: summary.alive,
      timeouts: summary.timeouts,
      selected_tests: summary.selected_tests,
      mutation_kind: 'stochastic',
      ok: result.ok,
      blocking: result.blocking,
    }.compact
  end

  sig { params(subject: Subject).returns(T.nilable(String)) }
  def self.source_file_for(subject)
    static_path = static_source_file_for(subject)
    return static_path if static_path

    source_path = source_location_file_for(subject)
    return source_path if source_path && !source_path.include?('/gems/sorbet-runtime-')

    owner = subject.expression.delete_suffix('*').split(/[.#]/, 2).first.to_s
    hint = underscore(owner.split('::').last.to_s)
    candidates = subject.requires.filter_map do |req|
      RUBY_SOURCE_ROOTS.filter_map do |root|
        rel = File.join(root, "#{req.delete_suffix('.rb')}.rb")
        rel if File.file?(File.join(MutationTesting::ROOT, rel))
      end
    end.flatten.uniq
    candidates.find { |rel| rel.include?(hint) } || candidates.first
  end

  sig { params(subject: Subject).returns(T.nilable(String)) }
  def self.source_location_file_for(subject)
    $LOAD_PATH.unshift(COMPILER_RUBY_LOAD_PATH) unless $LOAD_PATH.include?(COMPILER_RUBY_LOAD_PATH)
    subject.requires.each { |req| require req }

    expression = subject.expression.delete_suffix('*')
    if subject.expression.end_with?('*')
      location = Object.const_source_location(expression)
      return nil unless location&.first

      return relative_repo_path(location.first)
    end

    owner, method_name, class_method = method_owner_and_name(expression)
    return nil unless owner && method_name

    owner_const = T.unsafe(Object).const_get(owner)
    location =
      if class_method
        owner_const.method(method_name).source_location
      else
        owner_const.instance_method(method_name).source_location
      end
    return nil unless location&.first

    relative_repo_path(location.first)
  rescue LoadError, NameError
    nil
  end

  sig { params(subject: Subject).returns(T.nilable(String)) }
  def self.static_source_file_for(subject)
    expression = subject.expression.delete_suffix('*')
    if subject.expression.end_with?('*')
      owner = expression
      candidates = ruby_source_files.select { |path| file_mentions_owner?(path, owner) }
      return best_owner_file(owner, candidates)
    end

    owner, method_name, _class_method = method_owner_and_name(expression)
    return nil unless owner && method_name

    candidates = ruby_source_files.select { |path| file_defines_method?(path, method_name) }
    owner_candidates = candidates.select { |path| file_mentions_owner?(path, owner) }
    return best_owner_file(owner, owner_candidates) unless owner_candidates.empty?

    owner_mentioned = candidates.select { |path| method_body_mentions_owner?(path, method_name, owner) }
    return owner_mentioned.first if owner_mentioned.length == 1
    return candidates.first if candidates.length == 1

    nil
  end

  sig { returns(T::Array[String]) }
  def self.ruby_source_files
    RUBY_SOURCE_ROOTS.flat_map do |root|
      Dir.glob(File.join(MutationTesting::ROOT, root, '**', '*.rb')).map do |path|
        relative_repo_path(path)
      end
    end.sort
  end

  sig { params(owner: String, candidates: T::Array[String]).returns(T.nilable(String)) }
  def self.best_owner_file(owner, candidates)
    return nil if candidates.empty?

    hint = underscore(owner.split('::').last.to_s)
    candidates.find { |path| path.include?(hint) } || candidates.first
  end

  sig { params(path: String, owner: String).returns(T::Boolean) }
  def self.file_mentions_owner?(path, owner)
    text = File.read(File.join(MutationTesting::ROOT, path))
    owner_tail = owner.split('::').last.to_s
    owner_patterns = [owner, owner_tail].uniq
    owner_patterns.any? do |name|
      text.match?(/^\s*(class|module)\s+#{Regexp.escape(name)}(\s|$)/) ||
        text.match?(/^\s*(class|module)\s+#{Regexp.escape(name)}[A-Z]/)
    end
  end

  sig { params(path: String, method_name: String).returns(T::Boolean) }
  def self.file_defines_method?(path, method_name)
    method_pattern = method_definition_pattern(method_name)
    File.foreach(File.join(MutationTesting::ROOT, path)).any? { |line| line.match?(method_pattern) }
  end

  sig { params(path: String, method_name: String, owner: String).returns(T::Boolean) }
  def self.method_body_mentions_owner?(path, method_name, owner)
    method_pattern = method_definition_pattern(method_name)
    lines = File.readlines(File.join(MutationTesting::ROOT, path), chomp: true)
    start = lines.index { |line| line.match?(method_pattern) }
    return false unless start

    owner_tail = owner.split('::').last.to_s
    body = lines[start, 40].join("\n")
    body.include?(owner) || body.include?(owner_tail)
  end

  sig { params(method_name: String).returns(Regexp) }
  def self.method_definition_pattern(method_name)
    escaped = Regexp.escape(method_name)
    /^\s*(?:(?:private|protected|public|private_class_method|module_function)\s+)?def\s+(?:self\.)?#{escaped}(?=\s|\(|$)/
  end

  sig { params(expression: String).returns([T.nilable(String), T.nilable(String), T::Boolean]) }
  def self.method_owner_and_name(expression)
    if expression.include?('#')
      owner, method_name = expression.split('#', 2)
      return [owner, method_name, false]
    end
    owner, separator, method_name = expression.rpartition('.')
    return [owner, method_name, true] unless separator.empty?

    owner, separator, method_name = expression.rpartition('::')
    return [owner, method_name, true] unless separator.empty?

    [nil, nil, true]
  end

  sig { params(path: String).returns(String) }
  def self.relative_repo_path(path)
    expanded = File.expand_path(path)
    root = "#{MutationTesting::ROOT}/"
    expanded.start_with?(root) ? expanded.delete_prefix(root) : path
  end

  sig { params(value: String).returns(String) }
  def self.underscore(value)
    value.gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
      .gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
      .tr('-', '_')
      .downcase
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
    facts_path = opts.facts || File.join(opts.out, 'mutant-facts.json')
    write_facts(results, facts_path)
    puts "wrote #{facts_path}"
    results.any?(&:blocking) ? 1 : 0
  end
end

exit RubySpecMutants.main(ARGV) if $PROGRAM_NAME == __FILE__
