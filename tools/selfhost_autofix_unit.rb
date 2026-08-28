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
        # The call may carry arguments, which move after the receiver.
        return false unless lines[i]&.match?(/(\w+)\.#{Regexp.escape(field)}\(/)

        lines[i] = lines[i].gsub(/(\w+)\.#{Regexp.escape(field)}\((\)|)/) do
          Regexp.last_match(2).empty? ? "#{union_fn}(#{Regexp.last_match(1)}, " : "#{union_fn}(#{Regexp.last_match(1)})"
        end
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

  # "Argument N ('x') is MUTABLE. Pass 'x' as '&x'" -- CLEAR wants mutation
  # explicit at the call site, and the diagnostic names the argument exactly.
  def mutable_arg_fix(output)
    return nil unless (m = output.match(/Pass '(\w+)' as '&\1'/))
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    arg = m[1]
    line_no = loc[1].to_i
    Fix.new(label: "&#{arg}", apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      return false unless lines[i]&.match?(/(?<![&\w.])#{Regexp.escape(arg)}(?![\w.])/)

      lines[i] = lines[i].sub(/(?<![&\w.])#{Regexp.escape(arg)}(?![\w.])/, "&#{arg}")
      File.write(path, lines.join)
      true
    end)
  end

  # "Operator NEQ cannot compare T[] with NIL" -- Ruby guards a collection
  # against nil; CLEAR types it a list, so the question it can ask is whether
  # the list is empty.
  def list_nil_guard_fix(output)
    return nil unless output.match?(/Operator NEQ cannot compare \S+\[\] with NIL/)
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    line_no = loc[1].to_i
    Fix.new(label: 'list != NIL -> !empty?', apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      # The left side may be a whole call, not just a dotted name.
      return false unless lines[i]&.match?(/IF (.+?) != NIL THEN/)

      lines[i] = lines[i].sub(/IF (.+?) != NIL THEN/) { "IF !((#{Regexp.last_match(1)}).empty?()) THEN" }
      File.write(path, lines.join)
      true
    end)
  end

  # Inside an arm that narrowed the value, its variant name is already known --
  # so asking the union for it passes a struct where the union was expected.
  # The diagnostic names the struct, which IS the answer.
  def variant_name_literal_fix(output)
    return nil unless output.include?('emittable__variant_name')
    return nil unless (m = output.match(/argument 1 expects Emittable, got (\w+)/))
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    variant = m[1]
    line_no = loc[1].to_i
    Fix.new(label: "variant_name -> \"MIR::#{variant}\"", apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      return false unless lines[i]&.match?(/emittable__variant_name\(\w+\)/)

      lines[i] = lines[i].sub(/emittable__variant_name\(\w+\)/, "\"MIR::#{variant}\"")
      File.write(path, lines.join)
      true
    end)
  end

  # "Unknown method 'delete' on Set<...>. Available: ... remove ..." -- Ruby's
  # Set#delete is CLEAR's remove. The diagnostic names the receiver type and
  # lists the method that means the same thing.
  # Keyed by receiver type where the same Ruby name means different things:
  # Set#delete is CLEAR's remove, and a map's in-place merge is merge_mut.
  RENAMES = {
    ['Set', 'delete'] => 'remove',
    ['HashMap', 'merge'] => 'merge_mut',
  }.freeze

  def method_rename_fix(output)
    return nil unless (m = output.match(/Unknown method '(\w+)' on (\w+)</))
    return nil unless (target = RENAMES[[m[2], m[1]]])
    return nil unless output.include?(" #{target},") || output.include?(" #{target}\n")
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    from = m[1]
    line_no = loc[1].to_i
    Fix.new(label: "#{from}() -> #{target}()", apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      return false unless lines[i]&.include?(".#{from}(")

      lines[i] = lines[i].sub(".#{from}(", ".#{target}(")
      File.write(path, lines.join)
      true
    end)
  end

  # "Cannot unwrap non-optional type T" -- an UNWRAP applied where the value is
  # already present. The element-unwrap sweeps over-apply on lists whose
  # indexing the compiler can prove total, and this takes those back out.
  def redundant_unwrap_fix(output)
    return nil unless output.include?('Cannot unwrap non-optional type')
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    line_no = loc[1].to_i
    Fix.new(label: 'drop redundant UNWRAP', apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      line = lines[i].to_s
      at = line.index('UNWRAP (') or return false

      close = matching_paren(line, at + 7) or return false
      lines[i] = line[0...at] + line[(at + 8)...close].to_s + line[(close + 1)..].to_s
      File.write(path, lines.join)
      true
    end)
  end

  # Balanced close for the paren at `open`, ignoring string contents.
  def matching_paren(text, open)
    depth = 0
    in_string = false
    i = open
    while i < text.length
      char = text[i]
      if in_string
        i += 2 and next if char == '\\'

        in_string = false if char == '"'
        i += 1
        next
      end
      case char
      when '"' then in_string = true
      when '(' then depth += 1
      when ')'
        depth -= 1
        return i if depth.zero?
      end
      i += 1
    end
    nil
  end

  # "Set.insert: argument type ?T does not match set element type T" -- indexing
  # yields an optional, and the collection takes the value itself. Ruby's each
  # hands over the element.
  def optional_insert_fix(output)
    return nil unless output.match?(/argument type \?(\w+) does not match set element type \1/)
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    line_no = loc[1].to_i
    Fix.new(label: 'unwrap inserted element', apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      return false unless lines[i]&.match?(/\.insert\((\w+\[[^\]]+\])\)/)

      lines[i] = lines[i].sub(/\.insert\((\w+\[[^\]]+\])\)/) { ".insert(COPY UNWRAP (#{Regexp.last_match(1)}))" }
      File.write(path, lines.join)
      true
    end)
  end

  # "Numeric operator requires numeric operands, got T[SET] and T[SET]" --
  # Ruby spells set difference `a - b`; CLEAR spells it a.difference(b).
  def set_difference_fix(output)
    return nil unless output.match?(/Numeric operator requires numeric operands, got \S+\[SET\] and \S+\[SET\]/)
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    line_no = loc[1].to_i
    Fix.new(label: 'a - b -> a.difference(b)', apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      return false unless lines[i]&.match?(/\(([\w.]+) - ([\w.]+)\)/)

      lines[i] = lines[i].sub(/\(([\w.]+) - ([\w.]+)\)/) do
        "(#{Regexp.last_match(1)}.difference(#{Regexp.last_match(2)}))"
      end
      File.write(path, lines.join)
      true
    end)
  end

  # "Argument 1 ('receiver') is MUTABLE, but you passed immutable variable 'x'"
  # -- a local the body mutates has to be declared MUTABLE where it is bound.
  def mutable_local_fix(output)
    return nil unless (m = output.match(/is MUTABLE, but you passed immutable variable '(\w+)'/))
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    name = m[1]
    line_no = loc[1].to_i
    Fix.new(label: "MUTABLE #{name}", apply: lambda do |path|
      lines = File.readlines(path)
      # Search only the enclosing function. Taking the first match in the file
      # marked an unrelated function and the loop then chased its cascade.
      first = (0...(line_no - 1)).reverse_each.find { |k| lines[k].match?(/^(?:PUB |PRIVATE )?FN \w/) } || 0
      last = ((line_no - 1)...lines.length).find { |k| k > first && lines[k].match?(/^(?:PUB |PRIVATE )?FN \w/) } || lines.length
      scope = (first...last)

      idx = scope.find { |k| lines[k].match?(/^\s*#{Regexp.escape(name)}(?::[^=]*)? = /) }
      if idx
        lines[idx] = lines[idx].sub(/^(\s*)#{Regexp.escape(name)}/, "\\1MUTABLE #{name}")
      elsif (idx = scope.find { |k| lines[k].match?(/^(?:PUB |PRIVATE )?FN .*(?<![\w])#{Regexp.escape(name)}: /) })
        lines[idx] = lines[idx].sub(/(?<![\w])#{Regexp.escape(name)}: /, "MUTABLE #{name}: ")
      else
        # It may be a WITH alias, which carries its own mutability.
        idx = scope.find { |k| lines[k].match?(/WITH \w+ \w+ AS #{Regexp.escape(name)}\b/) }
        return false unless idx

        lines[idx] = lines[idx].sub(/AS #{Regexp.escape(name)}\b/, "AS MUTABLE #{name}")
      end
      File.write(path, lines.join)
      true
    end)
  end

  # "HashMap.contains?: key must be String, got ?String" -- a union accessor
  # returns an optional, and a map key is the value itself.
  def optional_key_fix(output)
    return nil unless output.match?(/key must be (\w+), got \?\1/)
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    line_no = loc[1].to_i
    Fix.new(label: 'unwrap map key', apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      line = lines[i].to_s
      at = line.index('.contains?(') or return false

      open_paren = at + 10
      close = matching_paren(line, open_paren) or return false
      inner = line[(open_paren + 1)...close]
      return false if inner.start_with?('UNWRAP ')

      lines[i] = line[0..open_paren] + "UNWRAP (#{inner})" + line[close..]
      File.write(path, lines.join)
      true
    end)
  end

  # "Function 'castNameToString' argument 1 expects Name, got String" -- the
  # value is already what the cast would produce, so the cast is redundant.
  # rtoc inserts these wherever a Ruby String-or-Symbol could appear.
  def redundant_cast_fix(output)
    return nil unless (m = output.match(/Function '\w+' argument 1 expects (\w+), got (\w+)/))
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    from, to = m[1], m[2]
    fn = "cast#{from}To#{to}"
    return nil unless loc[2].include?("#{fn}(")

    line_no = loc[1].to_i
    Fix.new(label: "drop #{fn}", apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      line = lines[i].to_s
      at = line.index("#{fn}(") or return false

      open_paren = at + fn.length
      close = matching_paren(line, open_paren) or return false
      lines[i] = line[0...at] + line[(open_paren + 1)...close].to_s + line[(close + 1)..].to_s
      File.write(path, lines.join)
      true
    end)
  end

  # "Union variant 'X' expects T, got ?T" -- the payload is optional where the
  # variant carries the value itself. Ruby's reader hands over the value.
  def union_payload_unwrap_fix(output)
    return nil unless (m = output.match(/Union variant '(\w+)' expects (\w+), got \?\2/))
    return nil unless (loc = output.match(/^\s+(\d+) \| (.*)$/))

    variant = m[1]
    line_no = loc[1].to_i
    Fix.new(label: "unwrap #{variant} payload", apply: lambda do |path|
      lines = File.readlines(path)
      i = line_no - 1
      line = lines[i].to_s
      marker = "#{variant}: COPY "
      at = line.index(marker) or return false

      rest = line[(at + marker.length)..]
      value = rest[/\A[\w.]+/] or return false
      lines[i] = line[0...(at + marker.length)] + "UNWRAP (#{value})" + rest[value.length..].to_s
      File.write(path, lines.join)
      true
    end)
  end

  FIXES = [method(:redundant_unwrap_fix), method(:redundant_cast_fix),
           method(:union_payload_unwrap_fix), method(:optional_key_fix),
           method(:set_difference_fix), method(:optional_insert_fix),
           method(:mutable_local_fix),
           method(:method_rename_fix), method(:field_call_fix), method(:boolean_or_fix), method(:name_wrap_fix),
           method(:mutable_arg_fix), method(:list_nil_guard_fix),
           method(:variant_name_literal_fix)].freeze

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
