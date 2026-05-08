#!/usr/bin/env ruby
# Aggregate Sorbet nil/method-not-found errors by ORIGIN site.
#
# Sorbet emits a trace like:
#   src/foo.rb:100: Method `bar` does not exist on `NilClass`
#   ...
#   Got `NilClass` originating from:
#       src/foo.rb:50: Possibly uninitialized (`NilClass`) in:
#       50 |  def some_method(arg)
#
# The ORIGIN is the source of the nil — fix that method's signature
# (declare nilable, or initialize the variable, or stop returning nil)
# and ALL downstream errors disappear at once.
#
# Usage: bundle exec ruby tools/srb_nil_origins.rb [/path/to/srb_output.txt]
#        SRB_YES=1 bundle exec srb tc 2>&1 | bundle exec ruby tools/srb_nil_origins.rb

input = ARGV[0] ? File.read(ARGV[0]) : STDIN.read

# Strip ANSI color codes (Sorbet emits them even when piped)
input = input.gsub(/\e\[[0-9;]*m/, '')

# Parse: each error block looks like
#   src/X.rb:LINE: Method `M` does not exist on `T` https://...
#   ...
#   Got `T` originating from:
#       src/Y.rb:OL: Possibly uninitialized (`T`) in:
#       OL |  ...
# OR
#       src/Y.rb:OL:
#       OL |  some_expr
#
# We group by the ORIGIN (file:line) and count downstream errors.
origins = Hash.new { |h, k| h[k] = [] }
current_error = nil

input.each_line do |line|
  if (m = line.match(/^(src\/[^:]+\.rb):(\d+):.*does not exist on/))
    current_error = "#{m[1]}:#{m[2]}"
  elsif current_error && (m = line.match(/^\s+(src\/[^:]+\.rb):(\d+):/))
    origin = "#{m[1]}:#{m[2]}"
    origins[origin] << current_error
    current_error = nil  # only count first origin per error
  end
end

ranked = origins.sort_by { |_, errs| -errs.size }
total = ranked.sum { |_, errs| errs.size }

puts "═══ Nil-origin aggregation ═══"
puts "Total errors with origins: #{total}"
puts "Distinct origins: #{ranked.size}"
puts
puts "ORIGIN → DOWNSTREAM ERROR COUNT"
puts "─" * 70
ranked.each do |origin, errs|
  puts format("  %4d  %s", errs.size, origin)
end
puts
puts "Top 10 origins explain #{ranked.first(10).sum { |_, errs| errs.size }} / #{total} errors."
