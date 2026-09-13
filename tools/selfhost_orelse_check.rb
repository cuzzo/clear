#!/usr/bin/env ruby
# frozen_string_literal: true

# Static gate: OR_ELSE whose left operand is a call that cannot fail and cannot
# be absent.
#
# The declaration says whether a function returns ?T or !T, so the site is
# decidable. One of these blocks a whole function -- the declaration it feeds
# fails, and every later use of that variable reports as undefined, so a single
# OR_ELSE produced six of the forty errors in the last round.
$PROGRAM_NAME = 'selfhost_orelse_check_support'

GEN = File.join(File.expand_path('..', __dir__), 'compiler', 'src')
DEF = /^(?:PUB |PRIVATE )?FN\s+([A-Za-z_]\w*[?!]?)\s*(?:<[^>]*>)?\s*\([^)]*\)\s*RETURNS\s+([^\->]+?)\s*(?:EFFECTS|->|$)/

def recoverable?(ret)
  r = ret.strip
  r.start_with?('?') || r.start_with?('!')
end

bad = 0
Dir.glob(File.join(GEN, '**', '*.clear')).sort.each do |path|
  rel = path.sub("#{GEN}/", '')
  lines = File.readlines(path)
  # A unit's own definition shadows an imported one of the same name.
  table = {}
  Dir.glob(File.join(GEN, '**', '*.clear')).each do |other|
    File.readlines(other).each do |l|
      m = DEF.match(l) or next
      table[m[1]] ||= recoverable?(m[2])
    end
  end
  lines.each do |l|
    m = DEF.match(l) or next
    table[m[1]] = recoverable?(m[2])
  end

  lines.each_with_index do |line, i|
    # `name(...) OR_ELSE` -- the call whose result is being defaulted
    line.scan(/([a-z]\w*[?!]?)\([^()]*\)\s*OR_ELSE/).flatten.each do |called|
      next unless table.key?(called)
      next if table[called]

      puts "#{rel}:#{i + 1}  OR_ELSE on #{called}, which returns neither ?T nor !T"
      bad += 1
    end
  end
end
puts "OR_ELSE on a non-recoverable left operand: #{bad}"
exit(bad.zero? ? 0 : 1)
