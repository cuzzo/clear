# frozen_string_literal: true

require 'open3'
require 'rbconfig'

module LexerHarnessSupport
  ROOT = File.expand_path('..', __dir__)
  CLEAR = File.join(ROOT, 'clear')

  SMOKE_CASES = [
    { 'name' => 'assignment', 'source' => 'x = 42' },
    { 'name' => 'keywords_types_vars', 'source' => 'IF If if WITH SNAPSHOT x AS y' },
    { 'name' => 'whitespace_comments', 'source' => "IF # comment\n x\n  = 10" },
    { 'name' => 'simple_string', 'source' => ' "Hello" ' },
    { 'name' => 'triple_string', 'source' => "\"\"\"\n A\n\"\"\"\nIF" },
    { 'name' => 'interpolation', 'source' => '"Hello ${name}!"' },
    { 'name' => 'based_literals', 'source' => '0xFF 0b1010_0101 0o12_34 0xFF_FF_u32' },
    { 'name' => 'decimal_literals', 'source' => '1_000 1_000_i32 1_000_u64 1_234.5_f32 3.141_592_f64' },
    { 'name' => 'operators', 'source' => '.. -> |> OR || && != +=' },
    { 'name' => 'suffix_ids', 'source' => 'check?(x) value? value?.field update! value! name!=' },
    { 'name' => 'pipeline', 'source' => 'items |> WHERE _.ok?() |> SELECT _.name' }
  ].freeze

  BENCHMARK_CASES = (SMOKE_CASES + [
    {
      'name' => 'function_body',
      'source' => <<~'CLEAR'
        PUB FN score!(items: Item[]@list) RETURNS !Int64 ->
          MUTABLE total = 0;
          FOR item IN items DO
            IF item.enabled?() THEN
              total += item.weight * 3;
            ELSE_IF item.name == "skip" THEN
              CONTINUE;
            ELSE
              total -= 1;
            END
          END
          RETURN total;
        END
      CLEAR
    }
  ]).freeze

  module_function

  def clear_string_literal(value)
    body = value.each_char.map do |ch|
      case ch
      when '\\' then '\\\\'
      when '"' then '\\"'
      when "\n" then '\\n'
      when "\r" then '\\r'
      when "\t" then '\\t'
      when "\0" then '\\0'
      else ch
      end
    end.join
    "\"#{body}\""
  end

  def clear_string_expr(value)
    parts = value.split('$', -1)
    return clear_string_literal(value) if parts.length == 1

    expr = clear_string_literal(parts.first)
    parts[1..].each do |part|
      expr = "#{expr} + \"$\" + #{clear_string_literal(part)}"
    end
    expr
  end

  def run!(*cmd, chdir: ROOT, env: {})
    stdout, stderr, status = Open3.capture3(env, *cmd, chdir: chdir)
    return [stdout, stderr] if status.success?

    raise "#{cmd.join(' ')} failed with #{status.exitstatus}\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
  end

  def time_command(*cmd, chdir: ROOT, env: {})
    time_bin = '/usr/bin/time'
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if File.executable?(time_bin)
      stdout, stderr, status = Open3.capture3(env, time_bin, '-v', *cmd, chdir: chdir)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      metrics = parse_time_v(stderr)
      metrics['elapsed_seconds'] ||= elapsed
    else
      stdout, stderr, status = Open3.capture3(env, *cmd, chdir: chdir)
      metrics = { 'elapsed_seconds' => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
    end

    metrics['stdout'] = stdout
    metrics['stderr'] = stderr
    metrics['exitstatus'] = status.exitstatus
    metrics['success'] = status.success?
    metrics
  end

  def parse_time_v(stderr)
    metrics = {}
    metrics['user_seconds'] = stderr[/User time \(seconds\):\s*([0-9.]+)/, 1]&.to_f
    metrics['system_seconds'] = stderr[/System time \(seconds\):\s*([0-9.]+)/, 1]&.to_f
    metrics['max_rss_kb'] = stderr[/Maximum resident set size \(kbytes\):\s*(\d+)/, 1]&.to_i
    elapsed_raw = stderr[/Elapsed \(wall clock\) time \(h:mm:ss or m:ss\):\s*([0-9:.]+)/, 1]
    metrics['elapsed_seconds'] = parse_elapsed_seconds(elapsed_raw) if elapsed_raw
    metrics
  end

  def parse_elapsed_seconds(raw)
    pieces = raw.split(':').map(&:to_f)
    case pieces.length
    when 2 then (pieces[0] * 60) + pieces[1]
    when 3 then (pieces[0] * 3600) + (pieces[1] * 60) + pieces[2]
    end
  end

  def ruby_executable
    RbConfig.ruby
  end
end
