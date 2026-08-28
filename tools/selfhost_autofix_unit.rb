#!/usr/bin/env ruby
# frozen_string_literal: true

# Drive selfhost_check_unit in a loop, applying the fixes whose shape the
# compiler states unambiguously.
#
# The diagnostics that dominate this translation name both the problem and the
# place: "Type T has no inherent METHOD named 'f'" at a line where `.f()` is a
# field read, "Cannot infer x from an optional value" where a binding needs its
# annotation. Applying those by hand costs a six-minute build each; applying
# them in a loop costs one build per fix with no human in it.
#
# Only shapes with a single safe rewrite are handled. Anything else stops the
# loop and is reported for a human.
#
#   ruby tools/selfhost_autofix_unit.rb mir/mir_checker.clear [--max 20]
require 'open3'
require 'optparse'

module SelfhostAutofixUnit
  extend self

  ROOT = File.expand_path('..', __dir__)

  Fix = Struct.new(:label, :apply, keyword_init: true)

  # "Type T has no inherent METHOD named 'f'." -- in this tree that is always a
  # Ruby attribute reader that rtoc emitted as a call.
  def field_call_fix(output)
    return nil unless (m = output.match(/has no inherent METHOD named '(\w+[?!]?)'/))
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    field = m[1]
    line_no = loc[1].to_i
    Fix.new(label: "#{field}() -> #{field}", apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      return false unless lines[i]&.include?("#{field}()")

      lines[i] = lines[i].gsub(/\.#{Regexp.escape(field)}\(\)/, ".#{field}")
      File.write(path, lines.join)
      true
    end)
  end

  FIXES = [method(:field_call_fix)].freeze

  def unit_path(relative) = File.join(ROOT, 'compiler', 'src', relative)

  def check(relative)
    out, err, status = Open3.capture3(
      { 'RUBYOPT' => '-W0' },
      RbConfig.ruby, File.join(ROOT, 'tools', 'selfhost_check_unit.rb'), relative, chdir: ROOT
    )
    ["#{out}\n#{err}", status.success?]
  end

  def main(argv)
    max = 25
    OptionParser.new { |p| p.on('--max N', Integer) { |v| max = v } }.parse!(argv)
    relative = argv.shift or abort 'usage: selfhost_autofix_unit.rb <relative/path.clear> [--max N]'
    path = unit_path(relative)
    abort "no such unit: #{relative}" unless File.exist?(path)

    applied = 0
    max.times do
      output, ok = check(relative)
      if ok
        puts "selfhost_autofix_unit: #{relative} type-checks after #{applied} fix(es)"
        return 0
      end

      fix = FIXES.filter_map { |f| f.call(output) }.first
      unless fix
        puts "selfhost_autofix_unit: stopped after #{applied} fix(es); needs a human:"
        puts output.lines.grep(/Compiler Error|^\s+\d+ \|/).first(3).join
        return 1
      end
      unless fix.apply.call(path)
        puts "selfhost_autofix_unit: #{fix.label} did not apply; stopping"
        return 1
      end
      applied += 1
      puts "  #{applied}. #{fix.label}"
    end
    puts "selfhost_autofix_unit: hit the #{max}-fix limit"
    1
  end
end

exit(SelfhostAutofixUnit.main(ARGV)) if $PROGRAM_NAME.end_with?('selfhost_autofix_unit.rb')
