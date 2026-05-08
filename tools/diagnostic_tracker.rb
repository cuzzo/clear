#!/usr/bin/env ruby
# Diagnostic tracker — `tools/diagnostic_tracker.rb [<category>] [--bucket=<id>] [--verbose]`
#
# Slices the diagnostic registry into themed buckets and reports the
# per-bucket annotation progress (which codes have a bad+good example
# in spec files vs. which are still :todo / :pending). Defaults to
# `:type` because that's the largest category.
#
# Dev-only: this is a tracker for whoever's documenting the registry,
# not part of the user-facing `clear` CLI. Run via bundle (the
# diagnostic_buckets module pulls in sorbet-runtime):
#
#   bundle exec ruby tools/diagnostic_tracker.rb            # :type buckets
#   bundle exec ruby tools/diagnostic_tracker.rb :ownership
#   bundle exec ruby tools/diagnostic_tracker.rb --bucket=type_match_pattern
#   bundle exec ruby tools/diagnostic_tracker.rb --verbose

$LOAD_PATH.unshift(File.expand_path('..', __dir__))
require 'src/ast/diagnostic_registry'
require 'src/ast/diagnostic_examples'
require 'src/ast/diagnostic_buckets'

category = :type
bucket_filter = nil
ARGV.each do |arg|
  if arg.start_with?('--bucket=')
    bucket_filter = arg.split('=', 2).last.to_sym
  elsif arg.start_with?(':')
    category = arg[1..].to_sym
  elsif !arg.start_with?('--')
    category = arg.to_sym
  end
end

examples = DiagnosticExamples.all
buckets = DiagnosticBuckets.for_category(category)
buckets = buckets.select { |b| b[:id] == bucket_filter } if bucket_filter

if buckets.empty?
  $stderr.puts "\e[31merror:\e[0m no buckets for category :#{category}"
  $stderr.puts "       known categories with buckets: #{DiagnosticBuckets::BUCKETS.map { |b| b[:category] }.uniq.map { |c| ":#{c}" }.join(', ')}"
  exit 2
end

total_codes = 0
total_done  = 0
total_pending = 0

puts "\e[1mDiagnostic tracker — :#{category}\e[0m"
puts ""

# Sort buckets by frequency desc, then alien_factor desc (high first).
alien_rank = { high: 3, medium: 2, low: 1 }
buckets = buckets.sort_by { |b| [-b[:frequency], -alien_rank.fetch(b[:alien_factor], 0)] }

buckets.each do |b|
  annotated = b[:codes].count { |c| DiagnosticBuckets.status_of(c, examples) == :annotated }
  pending   = b[:codes].count { |c| DiagnosticBuckets.status_of(c, examples) == :pending }
  todo      = b[:codes].count { |c| DiagnosticBuckets.status_of(c, examples) == :todo }
  n         = b[:codes].size
  pct       = n.zero? ? 100 : (annotated * 100.0 / n).round
  bar_done  = "█" * (annotated * 20 / [n, 1].max)
  bar_rest  = "░" * (20 - bar_done.length)

  total_codes   += n
  total_done    += annotated
  total_pending += pending

  stars   = DiagnosticBuckets.frequency_stars(b[:frequency])
  alien   = DiagnosticBuckets.alien_label(b[:alien_factor])
  color_alien = case b[:alien_factor]
                when :high   then "\e[31m"
                when :medium then "\e[33m"
                when :low    then "\e[32m"
                else ""
                end

  puts "\e[1m#{b[:title]}\e[0m  \e[90m[#{b[:id]}]\e[0m"
  puts "  Frequency: #{stars}    Alien: #{color_alien}#{alien}\e[0m    " \
       "Coverage: \e[32m#{bar_done}\e[90m#{bar_rest}\e[0m  " \
       "#{annotated}/#{n} done#{pending > 0 ? ", #{pending} pending" : ""}#{todo > 0 ? ", #{todo} todo" : ""}  (#{pct}%)"
  puts "  #{b[:summary]}"
  if bucket_filter || ARGV.include?('--verbose') || ARGV.include?('-v')
    puts ""
    b[:codes].each do |code|
      st = DiagnosticBuckets.status_of(code, examples)
      sym = case st
            when :annotated then "\e[32m✓\e[0m"
            when :pending   then "\e[33m⏳\e[0m"
            when :todo      then "\e[90m☐\e[0m"
            end
      entry = DiagnosticRegistry.lookup(code)
      summary = entry ? entry[:summary] : "(unknown)"
      puts "    #{sym} #{code.to_s.ljust(40)} \e[90m#{summary}\e[0m"
    end
  end
  puts ""
end

total_todo = total_codes - total_done - total_pending
total_pct  = total_codes.zero? ? 100 : (total_done * 100.0 / total_codes).round
bar_done   = "█" * (total_done * 30 / [total_codes, 1].max)
bar_rest   = "░" * (30 - bar_done.length)
puts "\e[1mTotal\e[0m  \e[32m#{bar_done}\e[90m#{bar_rest}\e[0m  " \
     "#{total_done}/#{total_codes} done, #{total_pending} pending, #{total_todo} todo  (#{total_pct}%)"
puts ""
puts "\e[90mTip: pass --verbose or --bucket=<id> to see individual codes per bucket.\e[0m"
puts "\e[90m     Statuses: \e[32m✓\e[90m annotated, \e[33m⏳\e[90m pending (future feature), \e[90m☐\e[90m todo.\e[0m"
