#!/usr/bin/env ruby
# typed: strict
# Targeted mutation runner for transpile-tests.

require 'fileutils'
require 'optparse'
require 'sorbet-runtime'
require_relative 'support'

module TranspileTestMutants
  extend T::Sig

  class Mutant < T::Struct
    const :name, Symbol
    const :description, String
    const :patch, String
    const :files, T::Array[String]
  end

  ROOT = T.let(MutationTesting::ROOT, String)
  PATCH_DIR = T.let(File.expand_path('../fuzz/mutants/patches', __dir__), String)

  REGISTRY = T.let([
    Mutant.new(
      name: :lower_if_cond_pending_leak,
      description: 'Disable lower_head pending-statement isolation; condition OR-fallback hoists should fail.',
      patch: File.join(PATCH_DIR, 'lower_if_cond_pending_leak.patch'),
      files: ['transpile-tests/or_fallback_in_if_condition_hoist.cht']
    ),
    Mutant.new(
      name: :escape_struct_field_walker,
      description: 'Disable receiver-escape walkers for wrapped loop-local collection sinks.',
      patch: File.join(PATCH_DIR, 'escape_struct_field_walker.patch'),
      files: ['transpile-tests/200_escape_callee_string_to_list.cht']
    ),
    Mutant.new(
      name: :loop_frame_scope_stamp,
      description: 'Force loop-local frame allocations to lower as function-scoped.',
      patch: File.join(PATCH_DIR, 'local_frame_decls_stdlib_provenance.patch'),
      files: ['transpile-tests/while_loop_with_local_split_no_rewind.cht']
    ),
    Mutant.new(
      name: :union_match_drops_payload_capture,
      description: 'Render union match arms without payload captures.',
      patch: File.join(PATCH_DIR, 'union_match_drops_payload_capture.patch'),
      files: ['transpile-tests/174_union_match_struct_fields.cht']
    ),
    Mutant.new(
      name: :fsm_suspend_returns_done,
      description: 'Return Done instead of yielding from FSM suspend tails.',
      patch: File.join(PATCH_DIR, 'fsm_suspend_returns_done.patch'),
      files: ['transpile-tests/256_sleep_int_literal.cht']
    ),
  ].freeze, T::Array[Mutant])

  class Options < T::Struct
    prop :mutant, T.nilable(Symbol)
    prop :all, T::Boolean
    prop :shard, T.nilable(MutationTesting::Shard)
    prop :out, String
    prop :list, T::Boolean
    prop :keep, T::Boolean
    prop :allow_dirty, T::Boolean
    prop :dry_run, T::Boolean
  end

  sig { params(argv: T::Array[String]).returns(Options) }
  def self.parse_options(argv)
    opts = Options.new(
      mutant: nil,
      all: false,
      shard: nil,
      out: '/tmp/clear-transpile-mutants',
      list: false,
      keep: false,
      allow_dirty: false,
      dry_run: false
    )
    OptionParser.new do |o|
      o.banner = 'Usage: ruby tools/mutants/transpile_tests.rb [--mutant NAME | --all] [--shard INDEX/COUNT] [--out DIR] [--keep] [--dry-run] [--allow-dirty]'
      o.on('--mutant NAME') { |v| opts.mutant = v.to_sym }
      o.on('--all') { opts.all = true }
      o.on('--shard INDEX/COUNT') { |v| opts.shard = MutationTesting.parse_shard(v) }
      o.on('--out DIR') { |v| opts.out = File.expand_path(v) }
      o.on('--keep') { opts.keep = true }
      o.on('--dry-run') { opts.dry_run = true }
      o.on('--allow-dirty') { opts.allow_dirty = true }
      o.on('--list') { opts.list = true }
      o.on('-h', '--help') { puts o; exit 0 }
    end.parse!(argv)
    opts
  end

  sig { params(mutant: Mutant).returns(T::Array[String]) }
  def self.patch_targets(mutant)
    File.readlines(mutant.patch).filter_map do |line|
      match = line.match(/^diff --git a\/(.+?) b\/(.+)$/)
      match && T.must(match[2])
    end.uniq
  end

  sig { params(paths: T::Array[String]).returns(T::Array[String]) }
  def self.dirty_paths(paths)
    return [] if paths.empty?

    result = MutationTesting.run_cmd(['git', 'status', '--porcelain', '--', *paths])
    result.output.lines.map(&:chomp).reject(&:empty?)
  end

  sig { params(mutant: Mutant, allow_dirty: T::Boolean).void }
  def self.ensure_clean_targets!(mutant, allow_dirty:)
    dirty = dirty_paths(patch_targets(mutant))
    return if dirty.empty? || allow_dirty

    raise "refusing to run #{mutant.name}: mutant targets have local changes\n#{dirty.join("\n")}"
  end

  sig { params(mutant: Mutant).void }
  def self.check_patch!(mutant)
    MutationTesting.run_cmd(['git', 'apply', '--check', mutant.patch])
  end

  sig { params(mutant: Mutant).void }
  def self.apply_patch!(mutant)
    MutationTesting.run_cmd(['git', 'apply', mutant.patch])
  end

  sig { params(mutant: Mutant).void }
  def self.revert_patch!(mutant)
    MutationTesting.run_cmd(['git', 'apply', '-R', mutant.patch])
  end

  sig { params(file: String, out_dir: String, log_path: String).returns(T::Boolean) }
  def self.run_transpile_file(file, out_dir, log_path)
    FileUtils.mkdir_p(out_dir)
    zig_file = File.join(ROOT, 'zig', "mutant_#{File.basename(file, '.cht')}.zig")
    begin
      generated = MutationTesting.run_cmd(
        ['bundle', 'exec', 'ruby', 'transpile-tests/gen.rb', '--single', file],
        allow_failure: true
      )
      File.write(zig_file, generated.output)
      if generated.exitstatus != 0
        File.write(log_path, generated.output)
        return false
      end

      result = MutationTesting.run_cmd(
        ['zig', 'test', zig_file, 'zig/runtime/switch.S', 'zig/runtime/onRoot.S', '-lc'],
        allow_failure: true,
        log_path: log_path
      )
      result.exitstatus == 0
    ensure
      FileUtils.rm_f(zig_file)
    end
  end

  sig { params(mutant: Mutant, out_dir: String).returns(T::Boolean) }
  def self.run_suite(mutant, out_dir)
    log_dir = File.join(out_dir, mutant.name.to_s)
    FileUtils.mkdir_p(log_dir)
    mutant.files.all? do |file|
      run_transpile_file(file, out_dir, File.join(log_dir, "#{File.basename(file)}.log"))
    end
  end

  sig { params(mutant: Mutant, out: String, allow_dirty: T::Boolean, dry_run: T::Boolean).returns(T::Boolean) }
  def self.run_mutant(mutant, out, allow_dirty:, dry_run:)
    puts "== #{mutant.name}"
    puts mutant.description
    puts "files: #{mutant.files.join(', ')}"
    puts "patch: #{mutant.patch}"
    ensure_clean_targets!(mutant, allow_dirty: allow_dirty)
    check_patch!(mutant)
    if dry_run
      puts 'result: dry-run patch check passed'
      return true
    end

    baseline = run_suite(mutant, File.join(out, mutant.name.to_s, 'baseline'))
    applied = false
    mutated = false
    begin
      apply_patch!(mutant)
      applied = true
      mutated = run_suite(mutant, File.join(out, mutant.name.to_s, 'mutated'))
    ensure
      revert_patch!(mutant) if applied
    end

    killed = baseline && !mutated
    puts "baseline=#{baseline ? 'pass' : 'fail'} mutated=#{mutated ? 'pass' : 'fail'} result=#{killed ? 'KILLED' : 'SURVIVED'}"
    killed
  end

  sig { params(opts: Options).returns(T::Array[Mutant]) }
  def self.selected_mutants(opts)
    selected =
      if opts.all
        REGISTRY
      else
        raise 'pass --mutant NAME, --all, or --list' unless opts.mutant

        found = REGISTRY.find { |m| m.name == opts.mutant }
        raise "unknown transpile mutant: #{opts.mutant}" unless found
        [T.must(found)]
      end

    MutationTesting.shard_items(selected, opts.shard)
  end

  sig { params(argv: T::Array[String]).returns(Integer) }
  def self.main(argv)
    opts = parse_options(argv)
    if opts.list
      selected = opts.all || opts.shard ? selected_mutants(Options.new(
        mutant: opts.mutant,
        all: true,
        shard: opts.shard,
        out: opts.out,
        list: opts.list,
        keep: opts.keep,
        allow_dirty: opts.allow_dirty,
        dry_run: opts.dry_run
      )) : REGISTRY
      selected.each { |m| puts "#{m.name} - #{m.description}" }
      return 0
    end

    FileUtils.rm_rf(opts.out) unless opts.keep
    FileUtils.mkdir_p(opts.out)
    mutants = selected_mutants(opts)
    if mutants.empty?
      puts "no transpile mutants selected for shard #{MutationTesting.shard_label(opts.shard)}"
      return 0
    end

    puts "transpile mutant shard #{MutationTesting.shard_label(opts.shard)}: #{mutants.length} mutant(s)"
    mutants.map do |mutant|
      run_mutant(mutant, opts.out, allow_dirty: opts.allow_dirty, dry_run: opts.dry_run)
    end.all? ? 0 : 1
  end
end

exit TranspileTestMutants.main(ARGV) if $PROGRAM_NAME == __FILE__
