#!/usr/bin/env ruby
# frozen_string_literal: true

# Close the mutable-receiver contract over the whole generated tree.
#
# A Ruby `foo!` mutates its receiver, and a method that calls a bang method on
# self mutates its receiver too. CLEAR says that three ways at once -- `MUTABLE
# self`, a mutable WITH alias, and `&` at every call site -- and all three have
# to agree or the compiler reports the argument rather than the signature.
#
# Applying any one of them alone leaves the tree inconsistent, which is what
# makes this a whole-tree pass rather than a per-diagnostic edit: run it after
# anything that makes a receiver mutable.
#
#   ruby tools/selfhost_mutation_closure.rb [--root compiler/src]
require 'optparse'
require 'set'

module SelfhostMutationClosure
  extend self

  FN_HEAD = /\A\s*(?:PUB |PRIVATE )?FN ([\w?!]+)\(/
  RECEIVERS = /&?(?:self|rtoc_self_view|rtoc_local_receiver_\d+|rtoc_mutable_receiver_\d+)\b/

  # Top-level comma split: a nested call's commas are not parameter separators.
  def split_top(text)
    parts, depth, cur = [], 0, +''
    text.each_char do |ch|
      depth += 1 if '([{'.include?(ch)
      depth -= 1 if ')]}'.include?(ch)
      if ch == ',' && depth.zero?
        parts << cur
        cur = +''
      else
        cur << ch
      end
    end
    parts << cur
  end

  def mutable_positions(sources)
    positions = Hash.new { |h, k| h[k] = Set.new }
    sources.each_value do |text|
      text.scan(/^(?:PUB |PRIVATE )?FN ([\w?!]+)\((.*?)\)\s*(?:RETURNS|$)/) do |name, params|
        split_top(params).each_with_index do |param, index|
          positions[name] << index if param.strip.start_with?('MUTABLE ')
        end
      end
    end
    positions.reject { |_, v| v.empty? }
  end

  # Each FN's line span, so a body edit lands inside the function that owns it.
  def function_spans(lines)
    heads = lines.each_with_index.filter_map { |line, i| [i, Regexp.last_match(1)] if line =~ FN_HEAD }
    heads.each_with_index.map do |(index, name), position|
      [name, index, position + 1 < heads.length ? heads[position + 1][0] : lines.length]
    end
  end

  # A function that calls a mutating method on its own receiver mutates its
  # receiver -- that is what Ruby means, so the property propagates upward.
  def grow_mutating_receivers!(sources)
    mutating = Set.new
    sources.each_value { |text| mutating.merge(text.scan(/^(?:PUB |PRIVATE )?FN ([\w?!]+)\(MUTABLE self: /).flatten) }
    grown = 0
    sources.each do |path, text|
      lines = text.split("\n", -1)
      changed = false
      function_spans(lines).each do |_, head, tail|
        next unless lines[head].match?(/\((?!MUTABLE )self: /)

        body = lines[head...tail].join("\n")
        calls = body.scan(/(?<![\w.])([\w?!]+)\(\s*#{RECEIVERS}/).flatten
        alias_mutable = lines[head...tail].any? { |l| l.include?('WITH POLYMORPHIC self AS MUTABLE ') }
        next unless alias_mutable || calls.any? { |callee| mutating.include?(callee) }

        lines[head] = lines[head].sub(/\((?!MUTABLE )self: /, '(MUTABLE self: ')
        (head...tail).each do |i|
          next unless lines[i].include?('WITH POLYMORPHIC self AS ') && !lines[i].include?('AS MUTABLE ')

          lines[i] = lines[i].sub('WITH POLYMORPHIC self AS ', 'WITH POLYMORPHIC self AS MUTABLE ')
        end
        grown += 1
        changed = true
      end
      sources[path] = lines.join("\n") if changed
    end
    grown
  end

  # `&` is the call-site half of the contract; without it the callee's MUTABLE
  # parameter has nothing to bind.
  def mark_call_sites!(sources)
    positions = mutable_positions(sources)
    return 0 if positions.empty?

    marked = 0
    sources.each do |path, text|
      lines = text.split("\n", -1)
      changed = false
      lines.each_with_index do |line, index|
        next if line =~ FN_HEAD

        out = +''
        cursor = 0
        while (call = line.index(/(?<![\w.&])[\w?!]+\(/, cursor))
          name = line[call..][/\A[\w?!]+/]
          open_paren = call + name.length + 1
          unless positions.key?(name)
            out << line[cursor...open_paren]
            cursor = open_paren
            next
          end
          depth = 1
          scan = open_paren
          start = open_paren
          args = []
          while scan < line.length && depth.positive?
            ch = line[scan]
            depth += 1 if '([{'.include?(ch)
            if ')]}'.include?(ch)
              depth -= 1
              if depth.zero?
                args << (start...scan)
                break
              end
            elsif ch == ',' && depth == 1
              args << (start...scan)
              start = scan + 1
            end
            scan += 1
          end
          if depth.positive?
            out << line[cursor...open_paren]
            cursor = open_paren
            next
          end
          out << line[cursor...open_paren]
          args.each_with_index do |range, position|
            arg = line[range]
            if positions[name].include?(position) && arg.match?(/\A\s*[a-z_]\w*\s*\z/)
              arg = arg.sub(arg.strip, "&#{arg.strip}")
              marked += 1
            end
            out << arg
            out << ',' if position < args.length - 1
          end
          cursor = args.last.end
        end
        out << line[cursor..] if cursor < line.length
        next if out == line

        lines[index] = out
        changed = true
      end
      sources[path] = lines.join("\n") if changed
    end
    marked
  end

  def main(argv)
    root = File.expand_path('../compiler/src', __dir__)
    OptionParser.new { |o| o.on('--root DIR') { |v| root = File.expand_path(v) } }.parse!(argv)

    paths = Dir.glob(File.join(root, '**', '*.clear')).sort
    sources = paths.to_h { |path| [path, File.read(path)] }
    original = sources.dup

    total_grown = 0
    total_marked = 0
    12.times do |round|
      grown = grow_mutating_receivers!(sources)
      marked = mark_call_sites!(sources)
      total_grown += grown
      total_marked += marked
      if (grown + marked).zero?
        warn "selfhost_mutation_closure: fixed point after #{round} round(s)"
        break
      end
      warn "selfhost_mutation_closure: round #{round + 1}: +#{grown} receivers, +#{marked} call sites"
    end

    written = sources.count { |path, text| text != original[path] && (File.write(path, text) || true) }
    puts "receivers #{total_grown}, call sites #{total_marked}, files #{written}"
    0
  end
end

exit(SelfhostMutationClosure.main(ARGV)) if $PROGRAM_NAME.end_with?('selfhost_mutation_closure.rb')
