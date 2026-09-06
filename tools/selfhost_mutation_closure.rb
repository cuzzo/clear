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

  FN_HEAD = /\A\s*(?:PUB |PRIVATE )?FN ([\w?!]+)(?:<[^>]*>)?\(/
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
      text.scan(/^(?:PUB |PRIVATE )?FN ([\w?!]+)(?:<[^>]*>)?\((.*?)\)\s*(?:RETURNS|$)/) do |name, params|
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
    sources.each_value { |text| mutating.merge(text.scan(/^(?:PUB |PRIVATE )?FN ([\w?!]+)(?:<[^>]*>)?\(MUTABLE self: /).flatten) }
    grown = 0
    sources.each do |path, text|
      lines = text.split("\n", -1)
      changed = false
      function_spans(lines).each do |_, head, tail|
        body = lines[head...tail].join("\n")
        calls = body.scan(/(?<![\w.])([\w?!]+)\(\s*#{RECEIVERS}/).flatten
        mutates = calls.any? { |callee| mutating.include?(callee) }
        receiver_mutable = !lines[head].match?(/\((?!MUTABLE )self: /)
        alias_mutable = lines[head...tail].any? { |l| l.include?('WITH POLYMORPHIC self AS MUTABLE ') }

        # The receiver and its WITH alias state one fact; either one being
        # mutable makes the other mutable, or the call site reports the alias.
        want_mutable = mutates || alias_mutable || receiver_mutable
        next unless want_mutable
        next if receiver_mutable && alias_mutable && !lambda_capture_needed?(lines, head, tail, mutating)

        lines[head] = lines[head].sub(/\((?!MUTABLE )self: /, '(MUTABLE self: ') unless receiver_mutable
        (head...tail).each do |i|
          next unless lines[i].include?('WITH POLYMORPHIC self AS ') && !lines[i].include?('AS MUTABLE ')

          lines[i] = lines[i].sub('WITH POLYMORPHIC self AS ', 'WITH POLYMORPHIC self AS MUTABLE ')
        end
        # A lambda that calls a mutating method on a captured receiver has to
        # capture it mutably, or the call inside the body is the one reported.
        (head...tail).each do |i|
          next unless lines[i].include?('USE(')
          next unless lambda_mutates_capture?(lines, i, mutating)

          lines[i] = lines[i].gsub(/USE\(([^)]*)\)/) do
            names = Regexp.last_match(1).split(',').map do |n|
              t = n.strip
              t.start_with?('MUTABLE ') || !t.match?(/\A(?:self|rtoc_self_view)\z/) ? t : "MUTABLE #{t}"
            end
            "USE(#{names.join(', ')})"
          end
        end
        grown += 1 unless receiver_mutable
        changed = true
      end
      sources[path] = lines.join("\n") if changed
    end
    grown
  end

  def mark_text(text, positions)
    out = +''
    cursor = 0
    marked = 0
    while (call = text.index(/(?<![\w.&])[\w?!]+\(/, cursor))
      name = text[call..][/\A[\w?!]+/]
      open_paren = call + name.length + 1
      unless positions.key?(name)
        out << text[cursor...open_paren]
        cursor = open_paren
        next
      end
      depth = 1
      scan = open_paren
      start = open_paren
      args = []
      while scan < text.length && depth.positive?
        ch = text[scan]
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
        out << text[cursor...open_paren]
        cursor = open_paren
        next
      end
      out << text[cursor...open_paren]
      args.each_with_index do |range, position|
        inner, inner_marked = mark_text(text[range], positions)
        marked += inner_marked
        if positions[name].include?(position) && inner.match?(/\A\s*[a-z_]\w*\s*\z/)
          inner = inner.sub(inner.strip, "&#{inner.strip}")
          marked += 1
        end
        out << inner
        out << ',' if position < args.length - 1
      end
      cursor = args.last.end
    end
    out << text[cursor..] if cursor < text.length
    [out, marked]
  end

  # A lambda body routinely spans many lines; the mutating call that forces a
  # mutable capture is rarely on the `USE(...)` line itself.
  def lambda_body_range(lines, start)
    return (start..start) unless lines[start].include?('-> {')

    depth = 0
    (start...lines.length).each do |i|
      depth += lines[i].count('{') - lines[i].count('}')
      return (start..i) if depth <= 0 && i > start
    end
    (start..[start + 40, lines.length - 1].min)
  end

  def lambda_mutates_capture?(lines, index, mutating)
    lambda_body_range(lines, index).any? do |i|
      line = lines[i]
      mutating.any? { |callee| line.include?("#{callee}(&") || line.include?("#{callee}(rtoc_self_view") }
    end
  end

  # A lambda body that mutates the captured receiver needs `USE(MUTABLE x)`
  # even when the enclosing function's own receiver is already mutable.
  def lambda_capture_needed?(lines, head, tail, mutating)
    (head...tail).any? do |i|
      line = lines[i]
      next false unless line.include?('USE(')
      next false if line.match?(/USE\([^)]*MUTABLE (?:self|rtoc_self_view)/)
      next false unless line.match?(/USE\([^)]*(?:self|rtoc_self_view)/)

      lambda_mutates_capture?(lines, i, mutating)
    end
  end

  # A parameter handed to a callee's MUTABLE parameter must itself be MUTABLE --
  # the same contract as the receiver, one argument over. Without this the
  # cascade walks the call graph one function per sweep round, driven by
  # diagnostics, instead of closing in a single pass.
  def grow_mutating_params!(sources)
    positions = mutable_positions(sources)
    return 0 if positions.empty?

    grown = 0
    sources.each do |path, text|
      lines = text.split("\n", -1)
      changed = false
      function_spans(lines).each do |_, head, tail|
        params = split_top(lines[head][/\((.*?)\)\s*(?:RETURNS|$)/, 1].to_s)
        plain = {}
        params.each do |param|
          t = param.strip
          next if t.start_with?('MUTABLE ', 'TAKES ')

          name = t.split(':').first.to_s.strip
          plain[name] = true unless name.empty?
        end
        next if plain.empty?

        body = lines[head...tail].join("\n")
        # A body that passes the parameter mutably (`&p`) or assigns through it
        # needs it MUTABLE, whatever the callee's slots say.
        plain.keys.each do |name|
          next unless body.match?(/(?<![\w.])&#{Regexp.escape(name)}(?![\w])/) ||
                      body.match?(/(?<![\w.])#{Regexp.escape(name)}\.\w+ =(?!=)/)

          lines[head] = lines[head].sub(/(?<=[(, ])#{Regexp.escape(name)}: /,
                                        "MUTABLE #{name}: ")
          plain.delete(name)
          grown += 1
          changed = true
        end
        next if plain.empty?

        # Balanced scan: a call's arguments routinely contain further calls, so
        # a [^()]* argument list matches almost nothing real.
        pos = 0
        while (m = /(?<![\w.&])([\w?!]+)\(/.match(body, pos))
          pos = m.end(0)
          callee = m[1]
          slots = positions[callee]
          next unless slots

          depth = 1
          j = m.end(0)
          start_arg = j
          args = []
          while j < body.length && depth.positive?
            ch = body[j]
            depth += 1 if '([{'.include?(ch)
            if ')]}'.include?(ch)
              depth -= 1
              if depth.zero?
                args << body[start_arg...j]
                break
              end
            elsif ch == ',' && depth == 1
              args << body[start_arg...j]
              start_arg = j + 1
            end
            j += 1
          end
          next if depth.positive?

          args.each_with_index do |arg, idx|
            next unless slots.include?(idx)

            name = arg.strip.delete_prefix('&')
            next unless plain[name]

            lines[head] = lines[head].sub(/(?<=[(, ])#{Regexp.escape(name)}: /,
                                          "MUTABLE #{name}: ")
            plain.delete(name)
            grown += 1
            changed = true
          end
        end
      end
      sources[path] = lines.join("\n") if changed
    end
    grown
  end

  # `&` is the call-site half of the contract; without it the callee's MUTABLE
  # parameter has nothing to bind.
  # `&` is the call-site half of the contract; without it the callee's MUTABLE
  # parameter has nothing to bind. Scans whole-file rather than line-by-line:
  # a call's arguments routinely continue onto following lines.
  def mark_call_sites!(sources)
    positions = mutable_positions(sources)
    return 0 if positions.empty?

    marked = 0
    sources.each do |path, text|
      line_starts = [0]
      text.each_char.with_index { |ch, i| line_starts << i + 1 if ch == "\n" }
      head_lines = Set.new
      text.split("\n", -1).each_with_index { |line, i| head_lines << i if line =~ FN_HEAD }
      line_of = lambda do |offset|
        low = 0
        high = line_starts.length - 1
        while low < high
          mid = (low + high + 1) / 2
          line_starts[mid] <= offset ? low = mid : high = mid - 1
        end
        low
      end

      out = +''
      cursor = 0
      while (call = text.index(/(?<![\w.&])[\w?!]+\(/, cursor))
        name = text[call..][/\A[\w?!]+/]
        open_paren = call + name.length + 1
        if !positions.key?(name) || head_lines.include?(line_of.call(call))
          out << text[cursor...open_paren]
          cursor = open_paren
          next
        end
        depth = 1
        scan = open_paren
        start = open_paren
        args = []
        while scan < text.length && depth.positive?
          ch = text[scan]
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
          out << text[cursor...open_paren]
          cursor = open_paren
          next
        end
        out << text[cursor...open_paren]
        args.each_with_index do |range, position|
          # An argument routinely contains further calls; mark inside it too.
          inner, inner_marked = mark_text(text[range], positions)
          marked += inner_marked
          if positions[name].include?(position) && inner.match?(/\A\s*[a-z_]\w*\s*\z/)
            inner = inner.sub(inner.strip, "&#{inner.strip}")
            marked += 1
          end
          out << inner
          out << ',' if position < args.length - 1
        end
        cursor = args.last.end
      end
      out << text[cursor..] if cursor < text.length
      next if out == text

      sources[path] = out
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
      grown += grow_mutating_params!(sources)
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
