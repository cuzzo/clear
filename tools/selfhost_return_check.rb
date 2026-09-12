#!/usr/bin/env ruby
# frozen_string_literal: true

# Static gate: a function declared to return a plain T whose RETURN hands back
# an optional field.
#
# Ruby writes T.must(...) at these sites; when the translation drops it the
# compiler reports RETURN_MISMATCH -- one per build, and a build is ~50 minutes.
# Struct declarations say which fields are optional, so the site is decidable.
require 'set'
$PROGRAM_NAME = 'selfhost_return_check_support'

GEN = File.join(File.expand_path('..', __dir__), 'compiler', 'src')
FN_DEF = /^(?:PUB |PRIVATE )?FN\s+([A-Za-z_]\w*[?!]?)\s*(?:<[^>]*>)?\s*\([^)]*\)\s*RETURNS\s+([^\->]+?)\s*(?:->|$)/
STRUCT_OPEN = /^(?:PUB |PRIVATE )?(?:STRUCT|UNION)\s+(\w+)\s*\{/
FIELD = /^\s*([a-z_]\w*):\s*(\??[\w\[\]{}@<>, ]+?),?\s*$/

# field name => true when EVERY declaration of it is optional. A name declared
# both ways cannot be judged without knowing the receiver's type.
seen = Hash.new { |h, k| h[k] = [] }
Dir.glob(File.join(GEN, '**', '*.clear')).each do |path|
  inside = false
  File.readlines(path).each do |line|
    inside = true if STRUCT_OPEN.match(line)
    if inside && line.start_with?('}')
      inside = false
      next
    end
    next unless inside

    m = FIELD.match(line) or next
    seen[m[1]] << m[2].strip.start_with?('?')
  end
end
always_optional = seen.select { |_f, v| v.any? && v.all? }.keys.to_set

bad = 0
Dir.glob(File.join(GEN, '**', '*.clear')).sort.each do |path|
  rel = path.sub("#{GEN}/", '')
  lines = File.readlines(path)
  current = nil
  lines.each_with_index do |line, i|
    if (m = FN_DEF.match(line))
      ret = m[2].strip.sub(/\A!/, '')
      current = ret.start_with?('?') || ret == 'Void' ? nil : m[1]
      next
    end
    next unless current

    # RETURN [COPY] <expr>.field;  with no UNWRAP anywhere on the path
    r = /^\s*RETURN\s+(?:COPY\s+)?(?!UNWRAP)[^;]*\.([a-z_]\w*);\s*$/.match(line) or next
    next unless always_optional.include?(r[1])

    puts "#{rel}:#{i + 1}  #{current} returns plain T but hands back optional field '#{r[1]}'"
    bad += 1
  end
end
puts "returns of an optional field from a non-optional signature: #{bad}"
exit(bad.zero? ? 0 : 1)
