#!/usr/bin/env ruby
# Apply fixes for dead-nil-check findings.
#
# Reads stdin (output of dead_nil_check_finder.rb) and rewrites
# `receiver&.method` to `receiver.method` at each flagged site.
#
# Usage:
#   bundle exec ruby tools/dead_nil_check_finder.rb src/ |
#     bundle exec ruby tools/dead_nil_check_fixer.rb

require "set"

# Parse "src/foo.rb:42  PATTERN  code  -- reason"
sites = Hash.new { |h, k| h[k] = [] }  # file => [line, ...]
STDIN.each_line do |line|
  next unless (m = line.match(/^(\S+\.rb):(\d+)\s+DEAD_SAFE_NAV/))
  sites[m[1]] << m[2].to_i
end

total = 0
sites.each do |path, lines|
  next unless File.exist?(path)
  src = File.read(path)
  src_lines = src.lines.dup
  lines.uniq.each do |ln|
    idx = ln - 1
    before = src_lines[idx]
    next unless before
    # Replace ALL `&.` on this line — multiple findings on the same line
    # all reference the same receiver narrowing, so all `&.` on the line
    # are dead together.
    after = before.gsub(/&\./, ".")
    if after != before
      src_lines[idx] = after
      total += 1
    end
  end
  File.write(path, src_lines.join)
  puts "  #{path}: #{lines.uniq.size} sites"
end
puts "Total lines patched: #{total}"
