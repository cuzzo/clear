#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

require_relative "../gems/nil-kill/lib/nil_kill"

options = {
  format: "table",
  sort: "farthest",
  limit: nil,
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/type_slot_coverage.rb [options] [paths...]"
  opts.on("--json", "Emit JSON instead of a table") { options[:format] = "json" }
  opts.on("--sort=MODE", "Sort by farthest, closest, path, or slots") { |mode| options[:sort] = mode }
  opts.on("--limit=N", Integer, "Limit displayed files") { |value| options[:limit] = value }
end

parser.parse!(ARGV)

summaries = NilKill::SlotCoverage.scan(ARGV)
total = NilKill::SlotCoverage.totals(summaries)

sorted =
  case options.fetch(:sort)
  when "closest"
    summaries.sort_by { |summary| [-summary.fetch("typed_percent"), -summary.fetch("structural").fetch("total"), summary.fetch("path")] }
  when "path"
    summaries.sort_by { |summary| summary.fetch("path") }
  when "slots"
    summaries.sort_by { |summary| [-summary.fetch("structural").fetch("total"), summary.fetch("path")] }
  else
    summaries.sort_by { |summary| [summary.fetch("typed_percent"), -summary.fetch("structural").fetch("total"), summary.fetch("path")] }
  end

sorted = sorted.first(options[:limit]) if options[:limit]

if options[:format] == "json"
  puts JSON.pretty_generate("summary" => total, "files" => sorted)
  exit
end

def compact_counts(counts)
  "#{counts.fetch("strong")}/#{counts.fetch("weak")}/#{counts.fetch("untyped")}"
end

puts "Type slot coverage by file"
puts "typed = strong Sorbet type; weak = T.any or T.untyped inside a container; untyped = T.untyped or missing type"
puts "Category cells are strong/weak/untyped. Array/hash columns are cross-cutting collection slots."
puts

header = ["typed%", "slots", "typed", "weak", "untyped", "nilable", "params", "returns", "ivars", "structs", "arrays", "hashes", "file"]
widths = [7, 7, 7, 6, 8, 8, 12, 12, 12, 12, 12, 12, 1]
puts header.each_with_index.map { |cell, idx| cell.ljust(widths.fetch(idx)) }.join("  ")
puts widths.map { |width| "-" * width }.join("  ")

([total] + sorted).each do |summary|
  structural = summary.fetch("structural")
  row = [
    format("%.1f", summary.fetch("typed_percent")),
    structural.fetch("total").to_s,
    structural.fetch("strong").to_s,
    structural.fetch("weak").to_s,
    structural.fetch("untyped").to_s,
    structural.fetch("nilable").to_s,
    compact_counts(summary.fetch("params")),
    compact_counts(summary.fetch("returns")),
    compact_counts(summary.fetch("ivars")),
    compact_counts(summary.fetch("struct_fields")),
    compact_counts(summary.fetch("arrays")),
    compact_counts(summary.fetch("hashes")),
    summary.fetch("path"),
  ]
  puts row.each_with_index.map { |cell, idx| idx == row.size - 1 ? cell : cell.ljust(widths.fetch(idx)) }.join("  ")
end
