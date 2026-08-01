#!/usr/bin/env ruby
# frozen_string_literal: true

# Run the compiler's own spec suite against the Sorbet-stripped mirror.
#
# The mirror is only trustworthy if the existing tests pass against it
# unchanged. Rather than shimming `require_relative` (which breaks rspec's own
# internals), the real tree is moved aside and the mirror takes its place for
# the duration of the run, so every require resolves naturally and not one spec
# file or source file is edited. The original is always restored, including on
# interrupt or crash; re-running repairs a tree left swapped by a hard kill.

require "fileutils"
require "optparse"

ROOT = File.expand_path("..", __dir__)
LIVE = File.join(ROOT, "compiler", "ruby")
STASH = File.join(ROOT, "compiler", ".ruby-original")

def restore!
  return unless Dir.exist?(STASH)

  FileUtils.rm_rf(LIVE)
  FileUtils.mv(STASH, LIVE)
end

options = { out: "compiler/.ruby-rbs", specs: "compiler/spec", regenerate: true }
OptionParser.new do |o|
  o.banner = "Usage: ruby tools/sorbet_strip_test.rb [--specs PATH] [--no-regenerate]"
  o.on("--out DIR", "Stripped mirror (default compiler/.ruby-rbs)") { |v| options[:out] = v }
  o.on("--specs PATH", "Spec file or directory (default compiler/spec)") { |v| options[:specs] = v }
  o.on("--[no-]regenerate", "Re-run the stripper first (default yes)") { |v| options[:regenerate] = v }
end.parse!(ARGV)

# A previous run may have died mid-swap.
restore!

if options[:regenerate]
  puts "==> regenerating #{options[:out]}"
  Dir.chdir(ROOT) do
    system(RbConfig.ruby, "tools/sorbet_strip.rb", "--out", options[:out]) || abort("strip failed")
  end
end

mirror = File.expand_path(options[:out], ROOT)
abort("no mirror at #{mirror}; run tools/sorbet_strip.rb") unless Dir.exist?(mirror)

ok = false
begin
  %w[INT TERM].each { |sig| Signal.trap(sig) { restore!; exit(130) } }

  FileUtils.mv(LIVE, STASH)
  FileUtils.mkdir_p(LIVE)
  # Copy only the .rb mirror; the RBS sidecars live under sig/ and are not code.
  Dir[File.join(mirror, "**", "*.rb")].each do |file|
    relative = file.delete_prefix("#{mirror}/")
    next if relative.start_with?("sig/")

    target = File.join(LIVE, relative)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(file, target)
  end

  # These specs read compiler/ruby as TEXT and assert on Sorbet syntax
  # (`class X < T::Struct`, `const :kind, Symbol`, sig shapes). Stripping
  # changes exactly that, by design, so they are guards on the SOURCE and are
  # verified by the ordinary suite against the unmodified tree -- running them
  # here would only assert that stripping happened.
  source_form_specs = %w[
    compiler/spec/architecture_invariants_spec.rb
    compiler/spec/gen_attr_rbi_spec.rb
  ]
  excludes = source_form_specs.flat_map { |f| ["--exclude-pattern", f.sub("compiler/spec/", "**/")] }

  puts "==> running #{options[:specs]} against the stripped mirror"
  puts "    (excluding source-form specs: #{source_form_specs.map { |f| File.basename(f) }.join(', ')})"
  # The specs are NOT stripped (they are never compiled), and some of them use
  # T.must/T.let themselves, so sorbet-runtime stays loaded for the test
  # process. The mirror under test does not reference it.
  Dir.chdir(ROOT) do
    ok = system("bundle", "exec", "rspec", "--require", "sorbet-runtime", *excludes, options[:specs])
  end
ensure
  restore!
end

# Two examples assert that Sorbet's T::Props setter raises TypeError on a bad
# prop value. Stripping removes that runtime check on purpose -- it is an
# assert, compiled out of the optimized build, and the type is still enforced
# statically by srb and by the ordinary suite. Everything else must pass.
#
# The other pre-existing failures in this repo (generic_implementation_resolution,
# mutable_call_site, tense_operation_plan) fail identically on the UNMODIFIED
# tree and are not caused by stripping -- verified by restoring every file.
EXPECTED_FAILURES = 2

puts(ok ? "==> stripped mirror PASSES the suite" : "==> stripped mirror FAILS the suite " \
          "(expected: #{EXPECTED_FAILURES} T::Props enforcement asserts + this repo's " \
          "pre-existing failures)")
exit(ok ? 0 : 1)
