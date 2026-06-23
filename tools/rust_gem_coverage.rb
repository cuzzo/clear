#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"

ROOT = File.expand_path("..", __dir__)
Dir.chdir(ROOT)

PACKAGES = {
  "decomplex-rust" => "gems/decomplex",
  "fact-mine-rust" => "gems/fact-mine",
  "lineage" => "gems/lineage"
}.freeze

def run_cmd(cmd, cwd)
  # puts "Running: #{cmd} in #{cwd}"
  system(cmd, chdir: cwd)
end

def parse_lcov(path)
  file_cov = {}
  current_file = nil

  return file_cov unless File.exist?(path)

  File.foreach(path) do |line|
    line.strip!
    if line.start_with?("SF:")
      current_file = line[3..-1]
      file_cov[current_file] ||= {}
    elsif line.start_with?("DA:")
      parts = line[3..-1].split(",")
      if parts.size >= 2
        line_num = parts[0].to_i
        hits = parts[1].to_i
        if current_file
          file_cov[current_file][line_num] = hits
        end
      end
    elsif line == "end_of_record"
      current_file = nil
    end
  end

  file_cov
end

def merge_lcovs(lcovs)
  merged = {}
  lcovs.each do |cov|
    cov.each do |file, lines|
      merged[file] ||= {}
      lines.each do |line, hits|
        merged[file][line] ||= 0
        merged[file][line] += hits
      end
    end
  end
  merged
end

# 1. Clean previous coverage profiles
PACKAGES.each_value do |path|
  run_cmd("cargo llvm-cov clean", path)
end

unit_lcov_paths = []
integration_lcov_paths = []

# 2. Run coverage for each package
PACKAGES.each do |name, rel_path|
  pkg_dir = File.join(ROOT, rel_path)
  puts "=== Running coverage for #{name} ==="

  # Unit tests: run lib and bins
  unit_lcov = "/tmp/rust_cov_#{name}_unit.lcov"
  puts "Running unit tests..."
  if run_cmd("cargo llvm-cov --lib --bins --lcov --output-path #{unit_lcov}", pkg_dir)
    unit_lcov_paths << unit_lcov
  else
    warn "Unit tests for #{name} failed or produced no coverage."
  end

  # Integration tests: run individual tests in tests/
  tests_dir = File.join(pkg_dir, "tests")
  if Dir.exist?(tests_dir)
    Dir.glob(File.join(tests_dir, "*.rs")).each do |test_file|
      test_target = File.basename(test_file, ".rs")
      int_lcov = "/tmp/rust_cov_#{name}_integration_#{test_target}.lcov"
      puts "Running integration test: #{test_target}..."
      if run_cmd("cargo llvm-cov --test #{test_target} --lcov --output-path #{int_lcov}", pkg_dir)
        integration_lcov_paths << int_lcov
      else
        warn "Integration test #{test_target} failed or produced no coverage."
      end
    end
  end
end

# 3. Parse and Merge LCOV coverage
puts "=== Parsing and merging coverage data ==="
unit_covs = unit_lcov_paths.map { |p| parse_lcov(p) }
integration_covs = integration_lcov_paths.map { |p| parse_lcov(p) }

unit_merged = merge_lcovs(unit_covs)
integration_merged = merge_lcovs(integration_covs)

# 4. Find all production source files
source_files = []
PACKAGES.each_value do |rel_path|
  src_dir = File.join(ROOT, rel_path, "src")
  Dir.glob(File.join(src_dir, "**/*.rs")).each do |file|
    # Exclude files that are not part of the active source code, e.g. tests modules or benches
    next if file.include?("/tests/") || file.include?("/benches/")
    source_files << File.expand_path(file)
  end
end
source_files = source_files.uniq.sort

# 5. Print Markdown Report
puts "\n| File | Executable LoC (Union) | Integration Cov % (Union) | Prod LoC | Prod Integration Cov % | Missed Prod Lines |"
puts "| --- | --- | --- | --- | --- | --- |"

source_files.each do |file|
  # Relpath for nice display
  rel_file = file.sub("#{ROOT}/", "")

  unit_file_cov = unit_merged[file] || {}
  int_file_cov = integration_merged[file] || {}

  all_lines = unit_file_cov.keys | int_file_cov.keys
  loc = all_lines.size

  if loc.zero?
    # No executable lines in the file (e.g. pure type definitions / modules definition only)
    next
  end

  int_hits = all_lines.count { |l| (int_file_cov[l] || 0) > 0 }
  int_pct = (int_hits.to_f / loc * 100).round(2)

  prod_loc = int_file_cov.keys.size
  if prod_loc > 0
    prod_int_hits = int_file_cov.values.count { |hits| hits > 0 }
    prod_int_pct = (prod_int_hits.to_f / prod_loc * 100).round(2)
    prod_int_str = "#{prod_int_pct}% (#{prod_int_hits}/#{prod_loc})"
    missed_lines = int_file_cov.select { |l, hits| hits == 0 }.keys.sort
    missed_str = missed_lines.empty? ? "None" : missed_lines.join(", ")
  else
    prod_int_str = "N/A"
    missed_str = "N/A"
  end

  puts "| `#{rel_file}` | #{loc} | #{int_pct}% (#{int_hits}/#{loc}) | #{prod_loc} | #{prod_int_str} | #{missed_str} |"
end

# Cleanup temporary files
(unit_lcov_paths + integration_lcov_paths).each do |p|
  File.delete(p) if File.exist?(p)
end
