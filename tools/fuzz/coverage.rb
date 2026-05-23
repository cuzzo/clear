#!/usr/bin/env ruby
# Reports how much of the ownership-safety surface is covered by tools/fuzz.

require 'optparse'
require_relative 'generator'
require_relative 'surface_registry'

opts = {
  report_only: false,
}

OptionParser.new do |o|
  o.banner = "Usage: ruby tools/fuzz/coverage.rb [--report-only]"
  o.on('--report-only') { opts[:report_only] = true }
  o.on('-h', '--help') { puts o; exit 0 }
end.parse!

FuzzGenerator.new(seed: 1)

templates = FuzzGenerator::TEMPLATES.keys.sort
readme = File.expand_path('README.md', __dir__)
documented_templates =
  if File.exist?(readme)
    lines = File.readlines(readme)
    start = lines.index { |line| line.strip == '## Current templates' }
    if start
      lines[(start + 1)..]
        .take_while { |line| !line.start_with?('### ') }
        .grep(/^\| `([^`]+)`/)
        .map { |line| line[/^\| `([^`]+)`/, 1].to_sym }
    else
      []
    end
  else
    []
  end

gaps = []

missing_from_code = documented_templates - templates
missing_from_docs = templates - documented_templates

missing_from_code.each do |name|
  gaps << "README documents #{name}, but no template is registered"
end

missing_from_docs.each do |name|
  gaps << "template #{name} is registered, but README does not document it"
end

FuzzSurfaceRegistry::GLOBAL_REQUIRED_SURFACES.each do |surface|
  required = FuzzSurfaceRegistry.surface(surface)
  covered = FuzzSurfaceRegistry::TEMPLATE_COVERAGE.values.flat_map { |coverage| coverage.fetch(surface, []) }.uniq
  missing = required - covered
  next if missing.empty?

  gaps << "global #{surface} missing: #{missing.join(', ')}"
end

FuzzSurfaceRegistry::REQUIRED_SURFACES_BY_TEMPLATE.each do |template, surfaces|
  unless templates.include?(template)
    gaps << "coverage registry references missing template #{template}"
    next
  end

  surfaces.each do |surface|
    required = FuzzSurfaceRegistry.surface(surface)
    covered = FuzzSurfaceRegistry.covered(template, surface)
    missing = required - covered
    next if missing.empty?

    gaps << "#{template} missing #{surface}: #{missing.join(', ')}"
  end
end

# Cross-cut shape check: a sink isn't truly covered unless the templates
# claiming it collectively touch each of the required value shapes (#41).
# Without this, a struct-only claim masks collection-shape blind spots --
# the exact pattern that hid #37/#39/#40/#42.
FuzzSurfaceRegistry::SINK_REQUIRES_SHAPES.each do |sink, required_shapes|
  covering = FuzzSurfaceRegistry.templates_covering_sink(sink)
  exercised = covering.flat_map { |t|
    FuzzSurfaceRegistry.covered(t, :cleanup_value_shapes)
  }.uniq
  missing = required_shapes - exercised
  next if missing.empty?

  gaps << "sink #{sink} -- no template's cleanup_value_shapes covers: #{missing.join(', ')} (covered by: #{covering.join(', ')})"
end

puts "Fuzz coverage report"
puts "templates: #{templates.size} registered"
puts "documented: #{documented_templates.size}"
puts

if gaps.empty?
  puts "No coverage gaps found."
  exit 0
end

puts "Coverage gaps:"
gaps.each { |gap| puts "  - #{gap}" }

exit(opts[:report_only] ? 0 : 1)
