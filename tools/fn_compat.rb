#!/usr/bin/env ruby
# frozen_string_literal: true

# Per-function byte-compatibility harness.
#
# A clean transpile says nothing about behaviour: every silent-wrongness bug
# found so far (a mutation landing on a discarded COPY, a Ruby block `return`
# becoming a lambda RETURN, stamps written through a copying visitor) compiles
# fine. This harness measures the thing that matters instead -- for a target
# function, RECORD every (arguments, result) the Ruby compiler produces over a
# corpus, then REPLAY the same arguments through the self-hosted CLEAR function
# and compare the encoded results byte for byte.
#
#   ruby tools/fn_compat.rb --record --out tmp/fn-compat
#   ruby tools/fn_compat.rb --replay --out tmp/fn-compat
#
# Targets live in TARGETS: a Ruby entry point, the CLEAR function that must
# match it, and the scalar shape of its arguments. Scalar-shaped leaves are
# the beachhead; graph-shaped inputs (Type, SymbolEntry, Locatable) reuse
# parser_compat.rb's canonical encoders once the leaves hold.
require 'json'
require 'fileutils'
require 'optparse'
require 'open3'

saved_program_name = $PROGRAM_NAME
$PROGRAM_NAME = 'fn_compat_support'
require_relative 'parser_compat'
$PROGRAM_NAME = saved_program_name

module FnCompat
  extend self

  SCHEMA = 'clear.fn.compat.v1'

  Target = Struct.new(:name, :ruby_require, :ruby_call, :clear_unit, :clear_call, :arg_types, :result_type, keyword_init: true)

  TARGETS = [
    Target.new(
      name: 'zig_type.reserved_identifier?',
      ruby_require: 'compiler/ruby/backends/zig_type',
      ruby_call: ->(args) { ZigType.reserved_identifier?(*args) },
      clear_unit: 'backends/zig_type.clear',
      clear_call: 'zigType__reserved_identifier?',
      arg_types: %i[zig_name],
      result_type: :bool
    ),
    Target.new(
      name: 'zig_type.primitive_numeric_identifier?',
      ruby_require: 'compiler/ruby/backends/zig_type',
      ruby_call: ->(args) { ZigType.primitive_numeric_identifier?(*args) },
      clear_unit: 'backends/zig_type.clear',
      clear_call: 'zigType__primitive_numeric_identifier?',
      arg_types: %i[zig_name],
      result_type: :bool
    ),
    Target.new(
      name: 'zig_type.float_identifier?',
      ruby_require: 'compiler/ruby/backends/zig_type',
      ruby_call: ->(args) { ZigType.float_identifier?(*args) },
      clear_unit: 'backends/zig_type.clear',
      clear_call: 'zigType__float_identifier?',
      arg_types: %i[zig_name],
      result_type: :bool
    ),
    Target.new(
      name: 'zig_type.integer_identifier?',
      ruby_require: 'compiler/ruby/backends/zig_type',
      ruby_call: ->(args) { ZigType.integer_identifier?(*args) },
      clear_unit: 'backends/zig_type.clear',
      clear_call: 'zigType__integer_identifier?',
      arg_types: %i[zig_name],
      result_type: :bool
    ),
    Target.new(
      name: 'ownership_edge_planner.move_op',
      ruby_require: 'compiler/ruby/semantic/ownership_edge_planner',
      ruby_call: ->(args) { OwnershipEdgePlanner.move_op(*args) },
      clear_unit: 'semantic/ownership_edge_planner.clear',
      clear_call: 'ownershipEdgePlanner__move_op',
      arg_types: %i[carrier],
      result_type: :symbol
    ),
    Target.new(
      name: 'ownership_edge_planner.keep_op',
      ruby_require: 'compiler/ruby/semantic/ownership_edge_planner',
      ruby_call: ->(args) { OwnershipEdgePlanner.keep_op(*args) },
      clear_unit: 'semantic/ownership_edge_planner.clear',
      clear_call: 'ownershipEdgePlanner__keep_op',
      arg_types: %i[carrier],
      result_type: :symbol
    ),
    Target.new(
      name: 'placement.alloc',
      ruby_require: 'compiler/ruby/mir/placement',
      ruby_call: ->(args) { MIR::Placement.alloc(*args) },
      clear_unit: 'mir/placement.clear',
      clear_call: 'placement__alloc',
      arg_types: %i[opt_symbol symbol],
      result_type: :symbol
    ),
    Target.new(
      name: 'placement.heap?',
      ruby_require: 'compiler/ruby/mir/placement',
      ruby_call: ->(args) { MIR::Placement.heap?(*args) },
      clear_unit: 'mir/placement.clear',
      clear_call: 'placement__heap?',
      arg_types: %i[opt_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'placement.frame?',
      ruby_require: 'compiler/ruby/mir/placement',
      ruby_call: ->(args) { MIR::Placement.frame?(*args) },
      clear_unit: 'mir/placement.clear',
      clear_call: 'placement__frame?',
      arg_types: %i[opt_symbol],
      result_type: :bool
    ),
    Target.new(
      name: 'placement.explicit_heap?',
      ruby_require: 'compiler/ruby/mir/placement',
      ruby_call: ->(args) { MIR::Placement.explicit_heap?(*args) },
      clear_unit: 'mir/placement.clear',
      clear_call: 'placement__explicit_heap?',
      arg_types: %i[opt_symbol],
      result_type: :bool
    )
  ].freeze

  # The inputs a target is exercised with. Recording from a live compile is the
  # end state; an explicit domain is what makes the first leaves runnable today
  # and keeps the comparison total rather than sampled.
  DOMAINS = {
    opt_symbol: [nil, :heap, :frame, :stack, :rodata, :borrow, :none],
    symbol: %i[heap frame],
    carrier: %i[plain multiowned shared],
    zig_name: ['u8', 'i64', 'f32', 'f0', 'u', 'i', 'f', 'usize', 'fn', 'var', 'const', 'anytype',
               'x64', 'u8x', 'i128', 'f64', 'bool', 'struct', 'Type', ''],
    bool: [true, false]
  }.freeze

  def main(argv)
    options = { out_dir: File.expand_path('tmp/fn-compat'), mode: nil, only: nil, keep: false }
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby tools/fn_compat.rb [--record|--replay] [options]'
      parser.on('--record', 'Record Ruby results for every target') { options[:mode] = :record }
      parser.on('--replay', 'Replay recorded inputs through CLEAR and compare') { options[:mode] = :replay }
      parser.on('--out DIR') { |v| options[:out_dir] = File.expand_path(v) }
      parser.on('--only NAME') { |v| options[:only] = v }
      parser.on('--keep', 'Keep the generated CLEAR harness and binary') { options[:keep] = true }
      parser.on('-h', '--help') { puts parser; exit 0 }
    end.parse!(argv)

    targets = TARGETS
    targets = targets.select { |t| t.name == options[:only] } if options[:only]
    abort 'fn_compat: no targets selected' if targets.empty?
    FileUtils.mkdir_p(options[:out_dir])

    case options[:mode]
    when :record then record(targets, options)
    when :replay then replay(targets, options)
    else
      record(targets, options)
      replay(targets, options)
    end
  end

  def record(targets, options)
    payload = { 'schema' => SCHEMA, 'implementation' => 'ruby', 'targets' => [] }
    targets.each do |target|
      require File.expand_path(target.ruby_require, __dir__ + '/..')
      calls = argument_tuples(target).map do |args|
        { 'args' => args.map { |a| encode_scalar(a) }, 'result' => encode_scalar(target.ruby_call.call(args)) }
      end
      payload['targets'] << { 'name' => target.name, 'calls' => calls }
    end
    path = File.join(options[:out_dir], 'ruby.json')
    File.write(path, JSON.pretty_generate(payload))
    puts "recorded #{payload['targets'].sum { |t| t['calls'].length }} calls across #{payload['targets'].length} targets -> #{path}"
    0
  end

  def replay(targets, options)
    recorded = JSON.parse(File.read(File.join(options[:out_dir], 'ruby.json')))
    by_name = recorded['targets'].to_h { |t| [t['name'], t['calls']] }

    dir = File.join(options[:out_dir], 'build')
    FileUtils.mkdir_p(dir)
    source = File.join(dir, 'fn_compat.clear')
    binary = File.join(dir, 'fn_compat')
    File.write(source, clear_source(targets, by_name))

    build = %w[./clear build] + [source, '-o', binary, '--no-stack-check'] + package_flags
    # zig_type.clear and friends call into compiler_regex.zig; the native dir
    # and its pcre2 link have to travel with the harness build.
    env = {
      'CLEAR_DISABLE_BUILD_ZIG' => '1',
      'CLEAR_EXTRA_LINK_LIBS' => 'pcre2-8',
      'CLEAR_EXTRA_NATIVE_DIRS' => File.expand_path('compiler/src', __dir__ + '/..')
    }
    _out, err, status = Open3.capture3(env, *build)
    unless status.success?
      warn "fn_compat: CLEAR build failed\n#{err.lines.grep(/Error|error/).first(12).join}"
      return 1
    end
    stdout, stderr, status = Open3.capture3(env, binary)
    stdout = stderr if stdout.empty?
    warn "fn_compat: CLEAR exited #{status.exitstatus}" unless status.success?

    actual = stdout.lines.map(&:chomp).reject(&:empty?).map { |line| line.split('|', 3) }
    mismatches = 0
    total = 0
    targets.each do |target|
      calls = by_name.fetch(target.name, [])
      calls.each_with_index do |call, index|
        total += 1
        got = actual.find { |t, i, _| t == target.name && i.to_i == index }&.last
        next if got == call['result']

        mismatches += 1
        puts "MISMATCH #{target.name}[#{index}] args=#{call['args'].inspect} ruby=#{call['result'].inspect} clear=#{got.inspect}"
      end
    end
    FileUtils.rm_rf(dir) unless options[:keep]
    puts "fn_compat: #{total - mismatches}/#{total} calls byte-identical across #{targets.length} targets"
    mismatches.zero? ? 0 : 1
  end

  def argument_tuples(target)
    domains = target.arg_types.map { |kind| DOMAINS.fetch(kind) }
    domains[1..].inject(domains.first.map { |v| [v] }) do |acc, domain|
      acc.flat_map { |prefix| domain.map { |v| prefix + [v] } }
    end
  end

  def encode_scalar(value)
    case value
    when nil          then 'nil'
    when true, false  then value.to_s
    when Symbol       then ":#{value}"
    when String       then "\"#{value}\""
    when Integer      then value.to_s
    else raise "fn_compat: unsupported scalar #{value.class}"
    end
  end

  def clear_literal(encoded)
    return 'NIL' if encoded == 'nil'
    return encoded.upcase if %w[true false].include?(encoded)
    return "symbol(\"#{encoded[1..]}\")" if encoded.start_with?(':')

    encoded
  end

  def clear_render(expr, result_type)
    case result_type
    when :bool   then "(IF #{expr} THEN \"true\" ELSE \"false\" END)"
    when :symbol then "(\":\" $+ CAST(#{expr} AS String))"
    when :string then "(\"\\\"\" $+ #{expr} $+ \"\\\"\")"
    else raise "fn_compat: unsupported result type #{result_type}"
    end
  end

  def clear_source(targets, by_name)
    units = targets.map(&:clear_unit).uniq
    requires = units.map { |unit| "REQUIRE \"pkg:rtoc_#{unit.unpack1('H*')}\";" }.join("\n")
    body = targets.flat_map do |target|
      by_name.fetch(target.name, []).each_with_index.map do |call, index|
        args = call['args'].map { |a| clear_literal(a) }.join(', ')
        value = clear_render("#{target.clear_call}(#{args})", target.result_type)
        "  print(\"#{target.name}|#{index}|\" $+ #{value});"
      end
    end.join("\n")

    <<~CLEAR
      #{requires}

      FN main() RETURNS !Void ->
      #{body}
      END
    CLEAR
  end

  # compiler/src has REQUIRE cycles (type <-> schemas), so the units must be
  # registered as the SCC-merged packages parser_compat.rb already builds.
  def package_flags
    root = File.expand_path('compiler/src', __dir__ + '/..')
    ParserCompat.package_flags(root) +
      ['--pkg', "fs=#{File.expand_path('stdlib/fs/src/lib.clear', __dir__ + '/..')}",
       '--pkg', "path=#{File.expand_path('stdlib/path/src/lib.clear', __dir__ + '/..')}"]
  end
end

exit(FnCompat.main(ARGV)) if $PROGRAM_NAME.end_with?('fn_compat.rb')
