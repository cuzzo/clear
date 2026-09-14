#!/usr/bin/env ruby
# Gate: `|> WHERE _ != NIL` filters elements but does NOT change the element
# type -- []?T stays []?T. Ruby's filter_map/compact DROPS the nils, yielding
# []T. So a chain whose result is declared/returned as a NON-optional element
# type must go through `.compact()` or `SELECT UNWRAP _`.
# Missing it is a TYPE_COERCION_FAILED at build time (~50min to learn); this
# gate finds it in ~1s.
root = File.expand_path('../compiler/src', __dir__)
bad = []
Dir.glob("#{root}/**/*.clear").sort.each do |path|
  File.readlines(path).each_with_index do |line, idx|
    next unless line.include?('WHERE _ != NIL')
    # Only judge lines that state the element type they must produce: either a
    # typed declaration or a RETURN in a fn whose element type we can read.
    m = line[/(?:MUTABLE|LET)\s+\w+\s*:\s*(\[[^\]]*\]|\[Set\])\s*([A-Za-z_][\w<>,]*)\s*=/]
    next unless m
    elem = $2
    next if elem.start_with?('?')          # optional element: filtering is enough
    # Does the chain drop the nils anywhere after the WHERE?
    tail = line[line.index('WHERE _ != NIL')..]
    next if tail.include?('.compact()') || tail.include?('UNWRAP')
    bad << [path.sub("#{root}/", ''), idx + 1, elem, line.strip[0, 120]]
  end
end
if bad.empty?
  puts "compact gate: clean"
else
  bad.each { |f, l, e, s| puts "#{f}:#{l}: []#{e} from a WHERE-filtered chain, no .compact()/UNWRAP\n    #{s}" }
  puts "compact gate: #{bad.size} site(s)"
end
exit(bad.empty? ? 0 : 1)
