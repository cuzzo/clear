#!/usr/bin/env ruby
# frozen_string_literal: true

# 2b census: how many functions in the linked closure annotate, and which do not.
#
# The whole-closure `./clear build` answers "is there an error" -- one error per
# ~50 minute round, and no denominator. Reading "1 error" as "1 defect left" is
# how a walk through a single function looked like a countdown for five rounds.
#
# This asks the measurable question instead: of the N functions in the closure,
# how many annotate clean? It runs the FRONTEND ONLY (parse + annotate) -- no
# lowering, no Zig -- and loads tools/probe_multi_error, whose function-level
# catch keeps every function independent, so one run yields the complete work
# list with an X/N rate.
$PROGRAM_NAME = 'selfhost_2b_census_support'
require 'json'
require_relative 'parser_compat'
require_relative '../compiler/ruby/compiler/compiler_frontend'

GEN = File.expand_path('../compiler/src', __dir__)

def merged_closure_source
  groups = ParserCompat.package_groups(GEN)
  pkg_paths = {}
  groups.each { |n, m| pkg_paths[n] = m.map { |r| File.join(GEN, r) }.join(',') }
  ParserCompat.generated_relatives(GEN).each { |r| pkg_paths[ParserCompat.package_name(r)] = File.join(GEN, r) }

  in_group = groups.values.flatten.to_set
  units = groups.map { |n, m| [n, m.map { |r| File.join(GEN, r) }] } +
          ParserCompat.generated_relatives(GEN).reject { |r| in_group.include?(r) }
                      .map { |r| [ParserCompat.package_name(r), [File.join(GEN, r)]] }

  # One merged source for the whole closure: merge() strips each member's
  # REQUIREs and inlines what they reach, so concatenating every unit's merged
  # body gives the linked program the build would compile.
  seen = {}
  parts = []
  units.each do |name, paths|
    src = PackageSource.merge(paths, resolve_pkg: ->(n) { pkg_paths[n] }).source
    src.each_line do |line|
      next if line.start_with?('REQUIRE ')

      parts << line
    end
    seen[name] = true
  end
  parts.join
end

t0 = Time.now
source = merged_closure_source
warn "merged #{source.lines.length} lines in #{(Time.now - t0).round(1)}s"

# The whole linked closure is one 172k-line program, well past the 1M-token
# default meant for a single user file. The budget is constructor-injected, so
# the harness raises it without touching the compiler.
budget = FrontendResourceBudget.new(max_tokens: 50_000_000, max_source_bytes: 256 * 1024 * 1024)

# Parse and annotate on a THREAD with a large stack: the parser is recursive
# descent, and 2M tokens overflowed the main thread's C stack -- the process
# died with no message at all. Thread stack size is set by
# RUBY_THREAD_VM_STACK_SIZE in the environment (see the runner script).
worker = Thread.new do
  t1 = Time.now
  tokens = Lexer.new(source, budget: budget).tokenize
  warn "lexed #{tokens.length} tokens in #{(Time.now - t1).round(1)}s"

  t1b = Time.now
  ast = ClearParser.new(tokens, source, budget: budget).parse
  warn "parsed in #{(Time.now - t1b).round(1)}s"

  t2 = Time.now
  begin
    SemanticAnnotator.new(source_code: source).annotate!(ast)
  rescue Exception => e # rubocop:disable Lint/RescueException
    warn "annotate stopped: #{e.class}: #{e.message.to_s.lines.first.to_s.strip[0, 120]}"
  end
  warn "annotated in #{(Time.now - t2).round(1)}s (total #{(Time.now - t0).round(1)}s)"
end
worker.join
