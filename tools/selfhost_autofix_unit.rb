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
    # `class` is Ruby reflection, not an attribute -- a union has no such field,
    # and the fix is a variant-name accessor rather than a field read.
    return nil if field == 'class'

    line_no = loc[1].to_i
    # A union may already have a generated dispatcher for this name, in which
    # case the call is right and only its SHAPE is wrong -- `x.f()` should be
    # `union__f(x)`, not a field read.
    union_fn = union_dispatcher_for(output, field)
    if union_fn
      return Fix.new(label: "#{field}() -> #{union_fn}(...)", apply: lambda do |path|
        lines = File.readlines(path)
        i = line_no - 1
        return false unless lines[i]&.match?(/(\w+)\.#{Regexp.escape(field)}\(\)/)

        lines[i] = lines[i].gsub(/(\w+)\.#{Regexp.escape(field)}\(\)/, "#{union_fn}(\\1)")
        File.write(path, lines.join)
        true
      end)
    end

    Fix.new(label: "#{field}() -> #{field}", apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      return false unless lines[i]&.include?("#{field}()")

      lines[i] = lines[i].gsub(/\.#{Regexp.escape(field)}\(\)/, ".#{field}")
      File.write(path, lines.join)
      true
    end)
  end

  # "Operator OR requires Bool operands" -- Ruby's `a || b` is nil-coalescing,
  # which CLEAR spells OR_ELSE. The diagnostic only fires where the operands
  # are not Bools, so the rewrite is unambiguous.
  def boolean_or_fix(output)
    return nil unless output.include?('Operator OR requires Bool operands')
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    line_no = loc[1].to_i
    Fix.new(label: 'OR -> OR_ELSE', apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      return false unless lines[i]&.include?(' OR ')

      lines[i] = lines[i].sub(' OR ', ' OR_ELSE ')
      File.write(path, lines.join)
      true
    end)
  end

  # "argument N expects ?Name, got String" -- error() takes the Name union rtoc
  # synthesized for Ruby's String-or-Symbol argument, and a bare String needs
  # the variant that carries it. The argument index makes the target exact.
  def name_wrap_fix(output)
    return nil unless output.match?(/argument (\d+) expects \?Name, got \??String/)
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    index = output.match(/argument (\d+) expects \?Name/)[1].to_i
    output_optional = output.include?('got ?String')
    line_no = loc[1].to_i
    Fix.new(label: "wrap argument #{index} in Name", apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      line = lines[i].to_s
      at = line.index('__error(') or return false

      open_paren = line.index('(', at)
      args = split_arguments(line, open_paren) or return false
      target = args[index - 1] or return false
      return false if target.strip.start_with?('Name{')

      inner = target.strip
      optional = output_optional
      inner = "UNWRAP (#{inner})" if optional

      lines[i] = line[0...target_start(args, index)] +
                 "Name{ StringValue: COPY #{inner} }" +
                 line[(target_start(args, index) + target.length)..]
      File.write(path, lines.join)
      true
    end)
  end

  # Argument spans of a call, as [start, text] pairs over the original line.
  def split_arguments(line, open_paren)
    depth = 0
    in_string = false
    start = open_paren + 1
    spans = []
    i = open_paren
    while i < line.length
      char = line[i]
      if in_string
        i += 2 and next if char == '\\'

        in_string = false if char == '"'
        i += 1
        next
      end
      case char
      when '"' then in_string = true
      when '(', '{', '[' then depth += 1
      when ')', '}', ']'
        depth -= 1
        if depth.zero?
          spans << [start, line[start...i]]
          @arg_spans = spans
          return spans.map(&:last)
        end
      when ','
        if depth == 1
          spans << [start, line[start...i]]
          start = i + 1
        end
      end
      i += 1
    end
    nil
  end

  def target_start(_args, index)
    span = @arg_spans[index - 1]
    span[0] + (span[1].length - span[1].lstrip.length)
  end

  # `Type T has no inherent METHOD named 'f'` names the receiver's union; if a
  # `t__f` dispatcher exists, that is what the call meant.
  def union_dispatcher_for(output, field)
    union = output[/Type (\w+) has no inherent METHOD/, 1] or return nil

    name = "#{union[0].downcase}#{union[1..]}__#{field}"
    Dir.glob(File.join(ROOT, 'compiler', 'src', '**', '*.clear')).any? do |path|
      File.foreach(path).any? { |l| l.match?(/^(?:PUB )?FN #{Regexp.escape(name)}\(/) }
    end ? name : nil
  end

  FIXES = [method(:field_call_fix), method(:boolean_or_fix), method(:name_wrap_fix)].freeze

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
