#!/usr/bin/env ruby
# frozen_string_literal: true

# Replay the arguments Ruby was given through the CLEAR function and compare
# results.
#
# Stage 3 of the per-function harness: stage 1 asks whether a function compiles,
# stage 2 whether it links, this asks whether it BEHAVES. For every recorded
# call whose arguments can be written as CLEAR literals, build a probe that
# reconstructs them, calls the function, and prints the result; then compare
# against what the Ruby compiler returned for the same input.
#
#   ruby tools/fn_io_record.rb --files 60 --out tmp/fn-io
#   ruby tools/fn_io_replay.rb --calls tmp/fn-io/calls.jsonl
require 'json'
require 'optparse'
require 'etc'
require 'set'

saved = $PROGRAM_NAME
$PROGRAM_NAME = 'fn_io_replay_support'
load File.expand_path('selfhost_fn_probe.rb', __dir__)
$PROGRAM_NAME = saved

module FnIoReplay
  extend self

  P = SelfhostFnProbe

  # What Ruby returned, as the text the CLEAR probe will print.
  def expected_text(row)
    case row['result_class']
    when 'TrueClass' then 'TRUE'
    when 'FalseClass' then 'FALSE'
    when 'NilClass' then 'NIL'
    when 'String' then row['result'][/\AS\d+:(.*)\z/m, 1]
    when 'Integer' then row['result'][/\AI(-?\d+);\z/, 1]
    when 'Symbol' then row['result'][/\AY\d+:(.*)\z/m, 1]
    end
  end

  # A probe that calls the function and prints its result.
  def replay_source(target, cache, pkg_name, args, kind)
    base = P.probe_source(target, nil, cache, pkg_name)
    safe = "probe__#{target.name.delete('?').delete('!')}"
    call = "#{safe}(#{args.join(', ')})"
    show =
      case kind
      when 'TrueClass', 'FalseClass'
        %(  MUTABLE r = #{call};\n  IF r THEN\n    print("TRUE");\n  ELSE\n    print("FALSE");\n  END)
      when 'NilClass'
        %(  MUTABLE r = #{call};\n  IF r == NIL THEN\n    print("NIL");\n  ELSE\n    print("NOT_NIL");\n  END)
      when 'Integer'
        %(  print((#{call}).toString());)
      else
        %(  print(#{call});)
      end
    base.sub(/FN main\(\) RETURNS !Void ->\n  RETURN;\nEND\n/,
             "FN main() RETURNS !Void ->\n#{show}\n  RETURN;\nEND\n")
  end

  def main(argv)
    calls = File.expand_path('../tmp/fn-io/calls.jsonl', __dir__)
    jobs = [Etc.nprocessors - 8, 1].max
    limit = nil
    OptionParser.new do |p|
      p.on('--calls FILE') { |v| calls = File.expand_path(v) }
      p.on('--jobs N', Integer) { |v| jobs = v }
      p.on('--limit N', Integer) { |v| limit = v }
    end.parse!(argv)

    rows = File.readlines(calls).map { |l| JSON.parse(l) }
    rows.select! { |r| r['args_clear'].all? { |a| !a.nil? } && expected_text(r) }
    # One representative call per function first; behaviour differences show up
    # on the first divergent input, and a broken function fails all of them.
    seen = Set.new
    rows.select! { |r| seen.add?([r['fn'], r['args_clear']]) }
    rows = rows.first(limit) if limit

    cache = {}
    index = P.fn_index(cache)
    stub_dir = File.expand_path('../tmp/fnprobe', __dir__)
    FileUtils.mkdir_p(stub_dir)
    types_path = File.join(stub_dir, 'types.clear')
    File.write(types_path, P.types_package(cache))
    flag = ['--pkg', "fnprobe_types=#{types_path}"]

    todo = rows.select { |r| index[r['fn']] }
    warn "#{todo.length} replayable calls across #{todo.map { |r| r['fn'] }.uniq.length} functions"

    queue = Queue.new
    todo.each_with_index { |r, i| queue << [i, r] }
    results = Array.new(todo.length)
    mutex = Mutex.new
    done = 0
    Array.new(jobs) do
      Thread.new do
        loop do
          i, row = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          target = index[row['fn']]
          src = replay_source(target, cache, 'fnprobe_types', row['args_clear'], row['result_class'])
          ran, actual, err = P.compile(src, :run, flag)
          expected = expected_text(row)
          matched = ran && actual == expected
          results[i] = [row['fn'], ran, matched, actual.to_s[0, 60], expected, err.to_s[0, 100]]
          mutex.synchronize do
            done += 1
            warn "  #{done}/#{todo.length}" if (done % 20).zero?
          end
        end
      end
    end.each(&:join)

    ran = results.count { |r| r && r[1] }
    matched = results.count { |r| r && r[2] }
    puts
    puts "#{ran}/#{results.length} replay probes ran"
    puts "#{matched}/#{results.length} produced the SAME result as Ruby " \
         "(#{results.empty? ? 0 : (100.0 * matched / results.length).round(1)}%)"
    File.write(File.expand_path('../.fn_replay.json', __dir__),
               JSON.pretty_generate(results.compact.map do |f, r, m, a, e, err|
                 { fn: f, ran: r, matched: m, actual: a, expected: e, error: err }
               end))
    0
  end
end

exit(FnIoReplay.main(ARGV)) if $PROGRAM_NAME.end_with?('fn_io_replay.rb')
