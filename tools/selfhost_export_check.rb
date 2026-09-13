#!/usr/bin/env ruby
# frozen_string_literal: true

# Static gate: a PUB function whose signature names a type that is not PUB.
#
# The importing unit can call the function but cannot describe what it gets
# back, so the compiler reports "cannot determine struct type" at the first
# field access -- far from the declaration, and only reachable by a full build.
# The rule is local: everything in a PUB signature has to be PUB too.
$PROGRAM_NAME = 'selfhost_export_check_support'
require 'set'

GEN = File.join(File.expand_path('..', __dir__), 'compiler', 'src')
TYPE_DECL = /^(PUB |PRIVATE )?(STRUCT|UNION|ENUM|PROTOCOL)\s+(\w+)/
PUB_FN = /^PUB FN\s+[A-Za-z_]\w*[?!]?\s*(?:<[^>]*>)?\s*\(([^)]*)\)\s*RETURNS\s+([^\->]+?)\s*(?:EFFECTS|->|$)/

declared = {}
Dir.glob(File.join(GEN, '**', '*.clear')).each do |path|
  File.readlines(path).each_with_index do |line, i|
    m = TYPE_DECL.match(line) or next
    declared[m[3]] = { pub: m[1] == 'PUB ', at: "#{path.sub("#{GEN}/", '')}:#{i + 1}" }
  end
end

bad = 0
Dir.glob(File.join(GEN, '**', '*.clear')).sort.each do |path|
  rel = path.sub("#{GEN}/", '')
  File.readlines(path).each_with_index do |line, i|
    m = PUB_FN.match(line) or next

    "#{m[1]} #{m[2]}".scan(/\b([A-Z]\w*)/).flatten.uniq.each do |t|
      info = declared[t] or next
      next if info[:pub]

      puts "#{rel}:#{i + 1}  PUB signature names non-PUB #{t} (declared #{info[:at]})"
      bad += 1
    end
  end
end
puts "PUB signatures naming a non-PUB type: #{bad}"
exit(bad.zero? ? 0 : 1)
