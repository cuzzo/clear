#!/usr/bin/env ruby
# frozen_string_literal: true

# Gate: rtoc turns a Ruby KEYWORD argument into a positional hash literal.
#
#   Ruby: with_fiber_capture_map(map, rt_override: bg_rt)
#   def:  (new_entries, capture_symbols: {}, rt_override: "__rt", &blk)
#   rtoc: mIRLowering__with_fiber_capture_map(&self, map, {:rt_override: bg_rt}, "__rt", blk)
#
# The kwarg lands in the next POSITIONAL slot and every later argument keeps its
# default, so at least two arguments are wrong. It surfaces as ARGUMENT_TYPE_ERROR
# ~50 minutes into a 2b round; this finds it in about a second.
#
# The tell is a map literal whose keys are all CLEAR symbols (`{:name: expr}`)
# sitting in an argument list -- a genuine map literal keyed by symbols is
# vanishingly rare in this corpus, and a kwarg-shaped one names a parameter.
root = File.expand_path('../compiler/src', __dir__)

# Parameter names per function, read from the corpus. A packed kwarg's key names
# a PARAMETER of the callee; a genuine symbol-keyed data map (`{:string_map:
# ...}`, `{:get: ...}`) does not. Without this the gate reported 1468 sites,
# almost all of them registries -- and a gate that cries wolf stops being read.
params = Hash.new { |h, k| h[k] = [] }
Dir.glob("#{root}/**/*.clear").sort.each do |path|
  File.readlines(path).each do |line|
    m = /^(?:PUB |PRIVATE )?FN\s+(\w+)(?:<[^>]*>)?\(([^)]*)/.match(line) or next

    params[m[1]] = m[2].scan(/(?:MUTABLE\s+)?(\w+)\s*:/).flatten
  end
end

bad = []
Dir.glob("#{root}/**/*.clear").sort.each do |path|
  File.readlines(path).each_with_index do |line, idx|
    line.scan(/(\w+)\s*\(([^\n]*)/) do
      callee = Regexp.last_match(1)
      rest = Regexp.last_match(2)
      names = params[callee]
      next if names.empty?

      rest.scan(/\{\s*:(\w+)\s*:/) do
        key = Regexp.last_match(1)
        next unless names.include?(key)

        bad << [path.sub("#{root}/", ''), idx + 1, callee, key, line.strip[0, 110]]
      end
    end
  end
end

if bad.empty?
  puts 'kwarg-hash gate: clean'
else
  bad.uniq.each do |f, l, callee, key, src|
    puts "#{f}:#{l}: `{:#{key}: ...}` passed positionally to #{callee}, which HAS a parameter named #{key}\n    #{src}"
  end
  puts "kwarg-hash gate: #{bad.uniq.size} site(s)"
end
exit(bad.empty? ? 0 : 1)
