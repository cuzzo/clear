#!/usr/bin/env ruby
# frozen_string_literal: true

# Static gate: UNWRAP applied to a call whose declared return is not optional.
#
# The compiler reports these one at a time, and each one costs a full build to
# reach. The declaration says whether a function returns ?T, so every site is
# decidable from the source.
$PROGRAM_NAME = 'selfhost_unwrap_check_support'
require 'set'

GEN = File.join(File.expand_path('..', __dir__), 'compiler', 'src')
DEF = /^(?:PUB |PRIVATE )?FN\s+([A-Za-z_]\w*[?!]?)\s*(?:<[^>]*>)?\s*\([^)]*\)\s*RETURNS\s+([^\->]+?)\s*(?:->|$)/

# name => true when the declared return is optional (or fallible-optional)
optional = {}
Dir.glob(File.join(GEN, '**', '*.clear')).each do |path|
  File.readlines(path).each do |line|
    m = DEF.match(line) or next
    ret = m[2].strip
    optional[m[1]] = ret.start_with?('?') || ret.start_with?('!?')
  end
end

bad = 0
Dir.glob(File.join(GEN, '**', '*.clear')).sort.each do |path|
  rel = path.sub("#{GEN}/", '')
  lines = File.readlines(path)
  # A unit's OWN definition shadows an imported one of the same name, and five
  # cast helpers exist in both a total (panics) and a partial (NIL) form -- so
  # optionality has to be resolved per file, not globally.
  table = optional.dup
  lines.each do |line|
    m = DEF.match(line) or next
    table[m[1]] = m[2].strip.sub(/\A!/, '').start_with?('?')
  end
  lines.each_with_index do |line, i|
    # Only when the call is the WHOLE contents of the UNWRAP: in
    # `UNWRAP (f(x).field)` the unwrap applies to the field, not to f.
    pos = 0
    while (m = /UNWRAP\s*\(\s*([a-z]\w*[?!]?)\s*\(/.match(line, pos))
      pos = m.end(0)
      called = m[1]
      open_at = line.index('(', m.begin(0) + 6)
      depth = 0
      close_at = nil
      (open_at...line.length).each do |j|
        depth += 1 if line[j] == '('
        next unless line[j] == ')'

        depth -= 1
        if depth.zero?
          close_at = j
          break
        end
      end
      next unless close_at

      inner = line[(open_at + 1)...close_at].strip
      next unless inner.start_with?("#{called}(") && inner.end_with?(')')
      next unless table.key?(called)
      next if table[called]

      puts "#{rel}:#{i + 1}  UNWRAP of #{called}, which returns a non-optional"
      bad += 1
    end
  end
end
puts "UNWRAP on non-optional results: #{bad}"
exit(bad.zero? ? 0 : 1)
