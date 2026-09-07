#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 3: does the CLEAR function return what Ruby returned, for Ruby's inputs?
#
# Stage 1 asks whether a function compiles, stage 2 whether it links. Neither
# says anything about behaviour. This replays the oracle recorded by
# fn_io_record.rb: for each recorded call whose arguments can be written as
# CLEAR literals, it builds a main that calls the function with exactly those
# arguments, prints the result, and compares that to what Ruby returned.
#
# The probe already stubs every internal call and already takes a custom main
# through FN_PROBE_MAIN, so this only has to render the call and the compare.
#
#   ruby tools/fn_io_record.rb --corpus transpile-tests --out tmp/fn-io
#   ruby tools/selfhost_fn_verify.rb --calls tmp/fn-io/calls.jsonl
#
# A call is replayable only when every argument renders as a literal. That is
# the binding constraint today, not the comparison: most annotator arguments
# are AST nodes and Types, which `clear_literal` cannot write out.
require 'json'
require 'open3'
require 'optparse'
require 'set'
require 'tempfile'

module SelfhostFnVerify
  extend self

  ROOT = File.expand_path('..', __dir__)

  # Results Ruby recorded as one of these can be printed by the CLEAR side and
  # compared as text. A structured result needs the canonical encoder in CLEAR
  # and is skipped rather than guessed at.
  SCALAR = %w[TrueClass FalseClass NilClass String Integer Symbol Float].freeze
  LIST = %w[Array Set].freeze

  def expected_text(row)
    case row['result_class']
    when 'TrueClass' then 'true'
    when 'FalseClass' then 'false'
    when 'NilClass' then ''
    else decode_scalar(row['result'])
    end
  end

  # The oracle encodes with parser_compat's canonical encoder: `S<len>:<text>`
  # for a string, `Y<len>:<text>` for a symbol, `I<n>` for an integer, `[...]`
  # for a list. Only those shapes are compared.
  def decode_scalar(enc)
    return nil unless enc.is_a?(String)

    case enc
    when /\AS(\d+):(.*)\z/m then Regexp.last_match(2)[0, Regexp.last_match(1).to_i]
    when /\AY(\d+):(.*)\z/m then Regexp.last_match(2)[0, Regexp.last_match(1).to_i]
    when /\AI(-?\d+)\z/ then Regexp.last_match(1)
    when 'T' then 'true'
    when 'F' then 'false'
    when 'N' then ''
    end
  end

  # A list encodes as `A<count>[<items>]`; a set as `E<count>[...]`.
  def list_items(enc)
    return nil unless enc.is_a?(String)

    m = enc.match(/\A[AE](\d+)\[(.*)\]\z/m)
    return nil unless m

    body = m[2].to_s
    return [] if body.empty?

    items = []
    rest = body
    until rest.empty?
      m = rest.match(/\A([SY])(\d+):/)
      return nil unless m

      len = m[2].to_i
      items << rest[m[0].length, len]
      rest = rest[(m[0].length + len)..].to_s
    end
    items
  end

  def fallible?(fn)
    @returns ||= begin
      map = {}
      Dir.glob(File.join(ROOT, 'compiler', 'src', '**', '*.clear')).each do |f|
        File.read(f).scan(/^(?:PUB |PRIVATE )?FN ([\w?!]+)\(.*?\)\s*RETURNS\s+(\S+)/m) do |name, ret|
          map[name] ||= ret
        end
      end
      map
    end
    @returns[fn].to_s.start_with?('!')
  end

  # One replayable call: the arguments as literals, and the text the CLEAR
  # side has to print for the run to agree with Ruby.
  Case = Struct.new(:fn, :args, :expected, :kind, :ruby_class)

  def cases(rows)
    out = {}
    rows.each do |row|
      args = row['args_clear']
      next unless args.is_a?(Array) && args.none?(&:nil?)

      kind, expected =
        if SCALAR.include?(row['result_class'])
          [:scalar, expected_text(row)]
        elsif LIST.include?(row['result_class'])
          items = list_items(row['result'])
          items ? [:list, items.join("\n")] : [nil, nil]
        end
      next unless kind && expected

      out[[row['fn'], args]] ||= Case.new(row['fn'], args, expected, kind, row['result_class'])
    end
    out.values
  end

  # `print` takes a String, so a list is printed one item per line and a
  # non-string scalar goes through interpolation.
  def main_body(kase)
    # The probe restates the target under a prefixed name so it cannot collide
    # with the stub set; the replay has to call that name.
    safe = "probe__#{kase.fn.delete('?').delete('!')}"
    inner = "#{safe}(#{kase.args.join(', ')})"
    # TRY on a non-fallible call is itself an error, so wrap only what the
    # target's declared return type says is fallible.
    call = fallible?(kase.fn) ? "TRY (#{inner})" : inner
    case kase.kind
    when :list
      "  verify_result = #{call};\n" \
        "  FOR verify_item IN verify_result DO\n    print(\"${verify_item}\");\n  END\n  RETURN;\n"
    else
      # Interpolation takes String operands, so only a String result goes in
      # directly; a Bool is branched on and anything else is converted.
      show =
        case kase.ruby_class
        when 'TrueClass', 'FalseClass'
          "  IF verify_result THEN\n    print(\"true\");\n  ELSE\n    print(\"false\");\n  END\n"
        when 'String', 'Symbol', 'NilClass'
          "  print(\"${verify_result}\");\n"
        else
          "  print(verify_result.toString());\n"
        end
      "  verify_result = #{call};\n#{show}  RETURN;\n"
    end
  end

  def run_case(kase, keep: false)
    body = Tempfile.new(['fnverify', '.clear'])
    body.write(main_body(kase))
    body.close
    out_json = Tempfile.new(['fnverify', '.json'])
    out_json.close
    env = { 'FN_PROBE_MAIN' => body.path }
    cmd = ['bundle', 'exec', 'ruby', 'tools/selfhost_fn_probe.rb',
           '--fn', kase.fn, '--jobs', '1', '--stage', 'run', '--out', out_json.path]
    Open3.capture3(env, *cmd, chdir: ROOT)
    rows = begin
      JSON.parse(File.read(out_json.path))
    rescue StandardError
      []
    end
    row = rows.find { |r| r['fn'] == kase.fn }
    return [:build_failed, row && row['error'].to_s[0, 120]] unless row && row['ok']

    actual = row['error'].to_s.strip   # stage :run puts the program's stdout here
    actual == kase.expected.to_s.strip ? [:match, actual] : [:differs, "ruby=#{kase.expected.inspect} clear=#{actual.inspect}"]
  ensure
    body&.unlink
    out_json&.unlink unless keep
  end

  def main(argv)
    calls = File.join(ROOT, 'tmp', 'fn-io', 'calls.jsonl')
    limit = nil
    stage1 = nil
    OptionParser.new do |p|
      p.on('--calls FILE') { |v| calls = File.expand_path(v) }
      p.on('--limit N', Integer) { |v| limit = v }
      p.on('--stage1 FILE', 'Probe JSON; only replay functions that compile') { |v| stage1 = File.expand_path(v) }
    end.parse!(argv)
    abort "no oracle at #{calls} -- run tools/fn_io_record.rb first" unless File.exist?(calls)

    rows = File.readlines(calls).map { |l| JSON.parse(l) }
    all = cases(rows)
    # A function that does not reach stage 1 cannot be replayed; counting its
    # cases as behavioural failures would hide the real rate.
    if stage1 && File.exist?(stage1)
      compiling = JSON.parse(File.read(stage1)).select { |r| r['ok'] }.map { |r| r['fn'] }.to_set
      before = all.length
      all = all.select { |k| compiling.include?(k.fn) }
      warn "#{before - all.length} replayable cases skipped: their function does not pass stage 1"
    end
    replayable = all.length
    all = all.first(limit) if limit
    warn "#{rows.length} recorded calls; #{replayable} replayable (args render as literals, " \
         "result is comparable text)"

    tally = Hash.new(0)
    all.each do |kase|
      status, detail = run_case(kase)
      tally[status] += 1
      warn format('  %-9s %s  %s', status, kase.fn, detail.to_s[0, 90])
    end
    checked = all.length
    matched = tally[:match]
    puts "#{matched}/#{checked} replayed calls return what Ruby returned" \
         "#{checked.zero? ? '' : format(' (%.1f%%)', 100.0 * matched / checked)}"
    puts "build_failed=#{tally[:build_failed]} differs=#{tally[:differs]}"
    0
  end
end

exit SelfhostFnVerify.main(ARGV) if $PROGRAM_NAME == __FILE__
