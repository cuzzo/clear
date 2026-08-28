#!/usr/bin/env ruby
# frozen_string_literal: true

# Type-check ONE generated unit, not the whole closure.
#
# The annotator harness compiles 91 packages and takes ~40 minutes to reach the
# next error. Most errors belong to a single file, and most files are their own
# package -- so a harness that REQUIREs just that package finds the same
# diagnostics in a fraction of the time (mir_checker: 6 minutes, not 40).
#
# Stops after the CLEAR stage: every error the compiler reports is decided
# during transpile, so Zig codegen is wasted work in a fixing loop.
#
#   ruby tools/selfhost_check_unit.rb mir/mir_checker.clear
require 'open3'
require 'fileutils'
require 'tmpdir'

saved = $PROGRAM_NAME
$PROGRAM_NAME = 'selfhost_check_unit_support'
require_relative 'parser_compat'
$PROGRAM_NAME = saved

module SelfhostCheckUnit
  extend self

  ROOT = File.expand_path('..', __dir__)

  # The package that owns this file: its SCC group when it is cyclic, else the
  # per-file package rtoc names by the hex of its relative path.
  def require_spec(relative, generated_root)
    group = ParserCompat.package_groups(generated_root).find { |_n, m| m.include?(relative) }
    group ? "pkg:#{group.first}" : "pkg:rtoc_#{relative.unpack1('H*')}"
  end

  def main(argv)
    relative = argv.shift or abort 'usage: selfhost_check_unit.rb <relative/path.clear>'
    generated_root = File.join(ROOT, 'compiler', 'src')
    abort "no such unit: #{relative}" unless File.exist?(File.join(generated_root, relative))

    Dir.mktmpdir('clear-unit-check') do |dir|
      source = File.join(dir, 'probe.clear')
      File.write(source, <<~CLEAR)
        REQUIRE "#{require_spec(relative, generated_root)}";

        FN main() RETURNS !Void ->
          RETURN;
        END
      CLEAR

      env = {
        'CLEAR_TRANSPILE_ONLY' => '1',
        'CLEAR_DISABLE_BUILD_ZIG' => '1',
        'CLEAR_EXTRA_LINK_LIBS' => 'pcre2-8',
        'CLEAR_EXTRA_NATIVE_DIRS' => generated_root,
      }
      cmd = [File.join(ROOT, 'clear'), 'build', source, '-o', File.join(dir, 'probe'),
             '--no-stack-check', '--main-tier', 'service',
             *ParserCompat.package_flags(generated_root)]
      out, err, status = Open3.capture3(env, *cmd, chdir: ROOT)
      text = "#{out}\n#{err}"
      noise = /^\e\[(33|36|90)m|^\s*from |^\t/
      lines = text.lines.reject { |l| l.match?(noise) }
      if status.success?
        puts "selfhost_check_unit: #{relative} type-checks"
        return 0
      end
      puts lines.join.strip
      1
    end
  end
end

exit(SelfhostCheckUnit.main(ARGV)) if $PROGRAM_NAME.end_with?('selfhost_check_unit.rb')
