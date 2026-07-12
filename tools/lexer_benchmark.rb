#!/usr/bin/env ruby
# frozen_string_literal: true

begin
  require 'bundler/setup'
rescue LoadError
end

require 'fileutils'
require 'json'
require 'optparse'
require 'tmpdir'

require_relative 'lexer_harness_support'

module LexerBenchmark
  module_function

  def main(argv)
    options = {
      iterations: 20_000,
      out_dir: File.join(LexerHarnessSupport::ROOT, 'tmp', 'lexer-benchmark'),
      keep: false
    }

    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby tools/lexer_benchmark.rb [--iterations N] [--out DIR] [--keep]'
      parser.on('--iterations N', Integer, 'Number of corpus passes per implementation') { |value| options[:iterations] = value }
      parser.on('--out DIR', 'Output directory for benchmark artifacts') { |value| options[:out_dir] = File.expand_path(value) }
      parser.on('--keep', 'Keep generated benchmark sources and binary') { options[:keep] = true }
    end.parse!(argv)

    FileUtils.mkdir_p(options[:out_dir])
    cases = LexerHarnessSupport::BENCHMARK_CASES

    results = Dir.mktmpdir('lexer-benchmark-', options[:out_dir]) do |dir|
      clear_binary = build_clear_benchmark(dir, cases, options[:iterations])
      ruby_script = write_ruby_benchmark(dir, cases, options[:iterations])

      ruby_metrics = LexerHarnessSupport.time_command(LexerHarnessSupport.ruby_executable, ruby_script)
      clear_metrics = LexerHarnessSupport.time_command(clear_binary)

      if options[:keep]
        FileUtils.cp(File.join(dir, 'lexer_benchmark.clear'), File.join(options[:out_dir], 'lexer_benchmark.clear'))
        FileUtils.cp(File.join(dir, 'lexer_benchmark.rb'), File.join(options[:out_dir], 'lexer_benchmark_child.rb'))
        FileUtils.cp(clear_binary, File.join(options[:out_dir], 'lexer_benchmark'))
      end

      {
        'schema' => 'clear.lexer.benchmark.v1',
        'iterations' => options[:iterations],
        'cases' => cases.map { |entry| entry['name'] },
        'case_count' => cases.length,
        'tokenizations' => options[:iterations] * cases.length,
        'ruby' => summarize_metrics(ruby_metrics),
        'clear' => summarize_metrics(clear_metrics)
      }
    end

    results['wall_ratio_clear_over_ruby'] = ratio(results.dig('clear', 'elapsed_seconds'), results.dig('ruby', 'elapsed_seconds'))
    results['rss_ratio_clear_over_ruby'] = ratio(results.dig('clear', 'max_rss_kb'), results.dig('ruby', 'max_rss_kb'))

    File.write(File.join(options[:out_dir], 'results.json'), JSON.pretty_generate(results))
    print_results(results, options[:out_dir])

    unless results.dig('ruby', 'success') && results.dig('clear', 'success')
      exit 1
    end
  end

  def build_clear_benchmark(dir, cases, iterations)
    source = File.join(dir, 'lexer_benchmark.clear')
    binary = File.join(dir, 'lexer_benchmark')
    File.write(source, clear_benchmark_source(cases, iterations))

    LexerHarnessSupport.run!(
      LexerHarnessSupport::CLEAR,
      'build',
      source,
      '-o',
      binary,
      '--optimized',
      '--no-stack-check',
      '--force'
    )
    binary
  end

  def write_ruby_benchmark(dir, cases, iterations)
    script = File.join(dir, 'lexer_benchmark.rb')
    File.write(script, ruby_benchmark_source(cases, iterations))
    script
  end

  def clear_benchmark_source(cases, iterations)
    lexer_path = File.join(LexerHarnessSupport::ROOT, 'compiler', 'src', 'ast', 'lexer.clear')
    case_calls = cases.map do |entry|
      "      total += consume!(#{LexerHarnessSupport.clear_string_expr(entry['source'])}) OR_ELSE RAISE;"
    end.join("\n")

    <<~CLEAR
      REQUIRE #{LexerHarnessSupport.clear_string_literal(lexer_path)};

      PRIVATE FN consume!(source: String@raw) RETURNS !Int64 ->
        tokens = tokenizeSource!(source) OR_ELSE RAISE;
        RETURN tokens.length();
      END

      FN main() RETURNS !Void ->
        MUTABLE total = 0;
        MUTABLE i = 0;
        WHILE i < #{iterations} DO
      #{case_calls}
          i += 1;
        END
        print("tokens=" + total.toString());
        RETURN;
      END
    CLEAR
  end

  def ruby_benchmark_source(cases, iterations)
    root = LexerHarnessSupport::ROOT
    sources = cases.map { |entry| entry['source'] }
    <<~RUBY
      # frozen_string_literal: true

      begin
        require 'bundler/setup'
      rescue LoadError
      end

      begin
        require 'sorbet-runtime'
        T::Configuration.default_checked_level = :never
      rescue LoadError
      end

      require #{File.join(root, 'compiler', 'ruby', 'ast', 'lexer').inspect}

      sources = #{sources.inspect}
      iterations = #{iterations}
      total = 0
      i = 0
      while i < iterations
        sources.each do |source|
          total += Lexer.new(source).tokenize.length
        end
        i += 1
      end
      puts "tokens=\#{total}"
    RUBY
  end

  def summarize_metrics(metrics)
    stdout = metrics['stdout'].to_s.strip
    if stdout.empty?
      stdout = metrics['stderr'].to_s.each_line.find { |line| line.start_with?('tokens=') }.to_s.strip
    end

    {
      'success' => metrics['success'],
      'exitstatus' => metrics['exitstatus'],
      'elapsed_seconds' => metrics['elapsed_seconds'],
      'user_seconds' => metrics['user_seconds'],
      'system_seconds' => metrics['system_seconds'],
      'max_rss_kb' => metrics['max_rss_kb'],
      'stdout' => stdout,
      'stderr' => metrics['stderr'].to_s.strip
    }
  end

  def ratio(numerator, denominator)
    return nil if numerator.nil? || denominator.nil? || denominator.to_f.zero?

    numerator.to_f / denominator.to_f
  end

  def print_results(results, out_dir)
    puts "lexer benchmark corpus: #{results['case_count']} cases x #{results['iterations']} iterations"
    puts "results: #{File.join(out_dir, 'results.json')}"
    puts
    puts format('%-8s %10s %10s %10s %12s %s', 'impl', 'wall_s', 'user_s', 'sys_s', 'max_rss_kb', 'stdout')
    %w[ruby clear].each do |name|
      row = results[name]
      puts format(
        '%-8s %10.3f %10.3f %10.3f %12s %s',
        name,
        row['elapsed_seconds'] || 0.0,
        row['user_seconds'] || 0.0,
        row['system_seconds'] || 0.0,
        row['max_rss_kb'] || 'n/a',
        row['stdout']
      )
    end
    if results['wall_ratio_clear_over_ruby']
      puts format('clear/ruby wall-time ratio: %.2fx', results['wall_ratio_clear_over_ruby'])
    end
    if results['rss_ratio_clear_over_ruby']
      puts format('clear/ruby max-RSS ratio: %.2fx', results['rss_ratio_clear_over_ruby'])
    end
  end
end

LexerBenchmark.main(ARGV) if $PROGRAM_NAME == __FILE__
