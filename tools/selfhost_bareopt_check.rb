#!/usr/bin/env ruby
# frozen_string_literal: true

# Static gate: `MUTABLE x:? = ...` -- an optional annotation with no type.
#
# The declaration does not type-check, so the binding never exists and every
# later use of it reports as an undefined variable. One of these produced four
# of the forty blockers in the last accumulated round, all of them cascades.
#
# When the initialiser is a plain call, the callee's declared return names the
# type, so the annotation can be completed from the source.
$PROGRAM_NAME = 'selfhost_bareopt_check_support'

GEN = File.join(File.expand_path('..', __dir__), 'compiler', 'src')
DEF = /^(?:PUB |PRIVATE )?FN\s+([A-Za-z_]\w*[?!]?)\s*(?:<[^>]*>)?\s*\([^)]*\)\s*RETURNS\s+([^\->]+?)\s*(?:EFFECTS|->|$)/
BARE = /^(\s*MUTABLE\s+[A-Za-z_]\w*)\s*:\s*\?\s*=\s*(.+)$/

returns = {}
Dir.glob(File.join(GEN, '**', '*.clear')).each do |path|
  File.readlines(path).each do |l|
    m = DEF.match(l) or next
    returns[m[1]] ||= m[2].strip
  end
end

bad = 0
fixable = 0
Dir.glob(File.join(GEN, '**', '*.clear')).sort.each do |path|
  rel = path.sub("#{GEN}/", '')
  File.readlines(path).each_with_index do |line, i|
    m = BARE.match(line) or next

    bad += 1
    init = m[2].strip
    call = /\A(?:TRY\s*\(\s*)?(?:COPY\s+)?([a-z]\w*[?!]?)\s*\(/.match(init)
    ret = call && returns[call[1]]
    if ret
      fixable += 1
      puts "#{rel}:#{i + 1}  bare `?` annotation; #{call[1]} returns #{ret}"
    else
      puts "#{rel}:#{i + 1}  bare `?` annotation; initialiser is not a plain call"
    end
  end
end
puts "bare `?` annotations: #{bad} (#{fixable} with a callee return to read)"
exit(bad.zero? ? 0 : 1)
