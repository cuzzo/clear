#!/usr/bin/env ruby
# Reports how much of the ownership-safety surface is covered by tools/fuzz.

require 'optparse'
require_relative 'generator'
require_relative 'surface_registry'
require_relative 'coverage_model'

opts = {
  report_only: false,
}

OptionParser.new do |o|
  o.banner = "Usage: ruby tools/fuzz/coverage.rb [--report-only]"
  o.on('--report-only') { opts[:report_only] = true }
  o.on('-h', '--help') { puts o; exit 0 }
end.parse!

FuzzGenerator.new(seed: 1)

templates = FuzzGenerator::TEMPLATES
readme = File.expand_path('README.md', __dir__)
documented_counts = FuzzCoverageModel.documented_counts(readme)
snapshots = FuzzCoverageModel.snapshots(templates)

gaps = []
gaps.concat(FuzzCoverageModel.readme_gaps(templates, documented_counts))
gaps.concat(FuzzCoverageModel.metadata_gaps(templates))
gaps.concat(FuzzCoverageModel.required_surface_gaps)
gaps.concat(FuzzCoverageModel.cross_product_gaps)

puts "Fuzz coverage report"
puts "templates: #{templates.size} registered"
puts "documented: #{documented_counts.size}"
puts
puts "Template scope metadata:"
FuzzCoverageModel.render_template_scope_lines(snapshots).each { |line| puts "  #{line}" }
puts
puts "High-risk cross-products:"
FuzzCoverageModel.render_cross_product_lines.each { |line| puts "  #{line}" }
puts

if gaps.empty?
  puts "No coverage gaps found."
  exit 0
end

puts "Coverage gaps:"
gaps.each { |gap| puts "  - #{gap}" }

exit(opts[:report_only] ? 0 : 1)
