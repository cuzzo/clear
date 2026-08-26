#!/usr/bin/env ruby
# frozen_string_literal: true

# Value-recursive type cycles in the generated CLEAR tree.
#
# Ruby structs hold each other by reference, so a Ruby type graph may contain
# cycles freely. CLEAR lowers a struct field or union payload to a Zig field BY
# VALUE, and a by-value cycle has no finite size -- Zig rejects it with
# "dependency loop". `@boxed` (or a slice/collection) breaks the cycle.
#
# Finding these one at a time costs a full package build each; this finds every
# cycle in the tree in about a second.
#
#   ruby tools/selfhost_type_cycles.rb [--root DIR]
require 'optparse'
require 'set'

module SelfhostTypeCycles
  extend self

  # A field/payload that occupies its type's storage inline. `@boxed` is a
  # pointer, and every collection form is a slice or handle.
  BY_VALUE = /\A\??([A-Z]\w*)\z/.freeze

  def by_value_target(type_text)
    text = type_text.sub(/\s*=.*\z/, '').gsub(/[,}]/, '').strip
    return nil if text.include?('@')
    return nil if text.start_with?('[')

    match = BY_VALUE.match(text)
    match && match[1]
  end

  def collect(root)
    edges = Hash.new { |h, k| h[k] = [] }
    kind = {}
    Dir.glob(File.join(root, '**', '*.clear')).sort.each do |path|
      current = nil
      File.readlines(path).each_with_index do |line, index|
        if (match = line.match(/\A(?:PUB )?(STRUCT|UNION) (\w+) \{/))
          current = match[2]
          kind[current] = match[1]
          # A single-line union declares every variant on the opening line.
          line.sub(/\A[^{]*\{/, '').split(',').each do |member|
            record(edges, current, member, path, index + 1)
          end
          next
        end
        next unless current

        if line.strip.start_with?('}')
          current = nil
          next
        end
        record(edges, current, line, path, index + 1)
      end
    end
    [edges, kind]
  end

  def record(edges, from, member, path, line_number)
    name, type_text = member.split(':', 2)
    return unless name && type_text
    return unless /\A\s*\w+\s*\z/.match?(name)

    target = by_value_target(type_text)
    return unless target

    edges[from] << { to: target, from: from, field: name.strip, path: path, line: line_number,
                     at: "#{path}:#{line_number}" }
  end

  # Every simple cycle reachable in the by-value graph, deduplicated by the set
  # of types it passes through.
  def cycles(edges)
    found = {}
    edges.each_key do |start|
      walk(edges, start, [start], Set.new([start]), found)
    end
    found.values
  end

  def walk(edges, node, path, seen, found)
    edges[node].each do |edge|
      if edge[:to] == path.first
        key = path.grep(String).sort.join('>')
        found[key] ||= path + [edge]
        next
      end
      next if seen.include?(edge[:to])
      next unless edges.key?(edge[:to])
      next if path.length > 8

      walk(edges, edge[:to], path + [edge], seen | [edge[:to]], found)
    end
  end

  def main(argv)
    root = File.expand_path('compiler/src', __dir__ + '/..')
    fix = false
    OptionParser.new do |parser|
      parser.on('--root DIR') { |v| root = File.expand_path(v) }
      parser.on('--fix', 'Add @boxed to the struct-side field of every cycle') { fix = true }
    end.parse!(argv)

    edges, kind = collect(root)
    found = cycles(edges)
    if found.empty?
      puts 'selfhost_type_cycles: no value-recursive cycles'
      return 0
    end

    return apply_fixes(found, kind) if fix

    found.each do |path|
      types = path.grep(String)
      puts "CYCLE #{types.join(' -> ')} -> #{types.first}"
      path.grep(Hash).each { |step| puts "  #{step[:at]}  .#{step[:field]}: #{step[:to]}" }
    end
    puts "selfhost_type_cycles: #{found.length} cycle(s)"
    1
  end

  # Break each cycle on its struct side. A union variant naming its own payload
  # type is the discriminated form and must stay by value; the struct field that
  # points back at the union is the one that has to become a pointer.
  def apply_fixes(found, kind)
    targets = found.filter_map do |path|
      path.grep(Hash).find { |step| kind[step[:from]] == 'STRUCT' }
    end.uniq { |step| step[:at] }

    unbroken = found.length - found.count { |path| path.grep(Hash).any? { |s| kind[s[:from]] == 'STRUCT' } }
    warn "selfhost_type_cycles: #{unbroken} cycle(s) have no struct-side edge to break" if unbroken.positive?

    targets.group_by { |step| step[:path] }.each do |path, steps|
      lines = File.readlines(path)
      steps.each do |step|
        index = step[:line] - 1
        line = lines[index]
        updated = line.sub(/(:\s*\??#{Regexp.escape(step[:to])})(?![\w@])/, '\\1@boxed')
        raise "selfhost_type_cycles: could not box #{step[:at]}" if updated == line

        lines[index] = updated
      end
      File.write(path, lines.join)
    end
    puts "selfhost_type_cycles: boxed #{targets.length} field(s) across #{targets.group_by { |s| s[:path] }.length} file(s)"
    0
  end
end

exit(SelfhostTypeCycles.main(ARGV)) if $PROGRAM_NAME.end_with?('selfhost_type_cycles.rb')
