#!/usr/bin/env ruby
# frozen_string_literal: true

# Gate: a lambda argument landing in an OPTIONAL parameter's slot.
#
#   Ruby: def with_new_scope(scope = nil, &blk)
#   CLEAR: FN ...(scope: ?Scope = NIL, blk: FN() -> RESULT)
#   rtoc:  with_new_scope(self, %() -> { ... })   # binds to `scope`
#
# Same root as the kwarg-hash defect: omitting an optional argument shifts
# everything after it. The diagnostic blames the generic ("no parameter uses
# type RESULT"), which points away from the real problem, so it is worth a gate.
#
# Rule: a `%(` lambda literal is only legal at a parameter whose declared type
# is a function (`FN(`). If the positional index it lands on is a non-function
# parameter, the call is short an argument.
root = File.expand_path('../compiler/src', __dir__)

sigs = {}
Dir.glob("#{root}/**/*.clear").sort.each do |path|
  File.readlines(path).each do |line|
    m = /^(?:PUB |PRIVATE )?FN\s+(\w+)(?:<[^>]*>)?\((.*)$/.match(line) or next

    # Parameter list only -- stop at the closing paren of the signature.
    depth = 0
    params = +''
    m[2].each_char do |c|
      depth += 1 if '(<['.include?(c)
      if ')]>'.include?(c)
        break if c == ')' && depth.zero?

        depth -= 1
      end
      params << c
    end
    # Split on top-level commas.
    out = []
    buf = +''
    d = 0
    params.each_char do |c|
      d += 1 if '(<['.include?(c)
      d -= 1 if ')]>'.include?(c)
      if c == ',' && d.zero?
        out << buf
        buf = +''
      else
        buf << c
      end
    end
    out << buf
    sigs[m[1]] = out.map { |p| p.include?('FN(') || p.include?('FN (') }
  end
end

# A string literal is not code: `parse_comma_seq(&self, :CHAR, "(", ")", %(..))`
# passes "(" and ")" as DATA, and counting them as brackets corrupts the depth
# so the lambda's argument index comes out one short. Blank the literals first,
# keeping their length so column positions still line up.
def blank_strings(line)
  line.gsub(/"(?:\\.|[^"\\])*"/) { |m| '"' + ('.' * (m.length - 2)) + '"' }
end

bad = []
Dir.glob("#{root}/**/*.clear").sort.each do |path|
  File.readlines(path).each_with_index do |raw, idx|
    line = blank_strings(raw)
    line.scan(/(\w+)\(/) do
      callee = Regexp.last_match(1)
      kinds = sigs[callee] or next
      next unless kinds.any?

      start = Regexp.last_match.end(0)
      # Walk the argument list, tracking top-level commas, and note where a
      # lambda literal sits.
      d = 0
      arg = 0
      i = start
      lambda_at = []
      while i < line.length
        c = line[i]
        d += 1 if '(<['.include?(c)
        if ')]>'.include?(c)
          break if c == ')' && d.zero?

          d -= 1
        end
        arg += 1 if c == ',' && d.zero?
        lambda_at << arg if c == '%' && line[i + 1] == '(' && d.zero?
        i += 1
      end
      lambda_at.each do |slot|
        next if slot >= kinds.length
        next if kinds[slot]

        bad << [path.sub("#{root}/", ''), idx + 1, callee, slot, raw.strip[0, 110]]
      end
    end
  end
end

if bad.empty?
  puts 'lambda-slot gate: clean'
else
  bad.uniq.each { |f, l, c, s, src| puts "#{f}:#{l}: lambda at argument #{s} of #{c}, which is not a function parameter\n    #{src}" }
  puts "lambda-slot gate: #{bad.uniq.size} site(s)"
end
exit(bad.empty? ? 0 : 1)
