#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"
require "set"

manifest_path = File.expand_path("../espalier_manifest.yml", __dir__)

unless File.exist?(manifest_path)
  puts "\e[31merror:\e[0m espalier_manifest.yml not found."
  puts "Please generate it first by running:"
  puts "  bundle exec gems/espalier/exe/espalier --nil-kill=/tmp/clear-nil-kill/evidence.json --format yaml --output=espalier_manifest.yml src/"
  exit 1
end

puts "Loading manifest..."
manifest = begin
             YAML.unsafe_load(File.read(manifest_path))
           rescue => e
             puts "YAML error: #{e.class}: #{e.message}"
             nil
           end
if manifest.nil? || !manifest.is_a?(Array)
  puts "\e[31merror:\e[0m failed to parse espalier_manifest.yml."
  exit 1
end

total_functions = 0
uncertain_functions = 0
poorly_performing = []

unknown_receivers = []
missing_complexity = []
dynamic_callbacks = []

manifest.each do |mod|
  mod_name = mod[:module] || mod[:name]
  functions = mod[:functions] || []
  
  functions.each do |fn|
    total_functions += 1
    quality = fn[:quality_metrics] || {}
    
    big_o = quality[:big_o]
    warnings = quality[:big_o_warnings] || []
    unknowns = quality[:big_o_unknowns] || []
    
    # Track poorly performing functions (O(N^2) or worse, or O(N log N))
    if big_o && big_o != "O(1)" && big_o != "O(N)"
      poorly_performing << {
        module: mod_name,
        function: fn[:name],
        complexity: big_o,
        file: mod[:file],
        line: fn[:line]
      }
    end
    
    # Check if runtime is uncertain
    is_uncertain = false
    
    warnings.each do |warn|
      is_uncertain = true
      record = {
        module: mod_name,
        function: fn[:name],
        warning: warn,
        file: mod[:file],
        line: fn[:line]
      }
      
      if warn =~ /Unknown receiver type/
        unknown_receivers << record
      elsif warn =~ /Missing method complexity/
        missing_complexity << record
      elsif warn =~ /Function pointer|callback/
        dynamic_callbacks << record
      end
    end
    
    uncertain_functions += 1 if is_uncertain
  end
end

pct_uncertain = total_functions.zero? ? 0 : (uncertain_functions * 100.0 / total_functions).round(1)

puts "\n\e[1m=== ESPALIER BIG-O RUNTIME DIAGNOSTIC ===\e[0m"
puts "Total functions analyzed:  #{total_functions}"
puts "Uncertain runtime:         #{uncertain_functions} (#{pct_uncertain}%)"
puts "Poorly performing (>=O(N log N)): #{poorly_performing.size}"
puts "----------------------------------------"

# 1. Poorly Performing
puts "\n\e[1;31m1. Unexpected Poorly Performing Functions (>= O(N log N))\e[0m"
if poorly_performing.empty?
  puts "  None found."
else
  poorly_performing.sort_by { |f| f[:complexity] }.reverse.each do |f|
    puts "  - \e[1m#{f[:module]}##{f[:function]}\e[0m -> #{f[:complexity]} at #{f[:file]}:#{f[:line]}"
  end
end

# Helper to print buckets
def print_bucket(title, records, color)
  puts "\n#{color}#{title} (#{records.size})\e[0m"
  if records.empty?
    puts "  None."
  else
    # Group by receiver/method name for clean reporting
    grouped = Hash.new { |h, k| h[k] = [] }
    records.each do |r|
      detail = r[:warning].match(/for `([^`]+)`/)&.captures&.first || r[:warning]
      grouped[detail] << r
    end
    
    grouped.first(15).each do |detail, items|
      puts "  - \e[1m#{detail}\e[0m (affects #{items.size} function#{items.size > 1 ? 's' : ''})"
      if ARGV.include?("--verbose") || ARGV.include?("-v")
        items.each do |item|
          puts "      #{item[:module]}##{item[:function]} at #{item[:file]}:#{item[:line]}"
        end
      end
    end
    if grouped.size > 15
      puts "  ... and #{grouped.size - 15} more types (run with -v to see details)"
    end
  end
end

# 2. Categorized Uncertainties
print_bucket("2. Missing Method Complexity in stdlib_complexity_ruby.yml", missing_complexity, "\e[1;33m")
print_bucket("3. Unknown Receiver Type Resolution (Dynamic/Static Gaps)", unknown_receivers, "\e[1;34m")
print_bucket("4. Dynamic Callbacks / Function Pointer Invocations", dynamic_callbacks, "\e[1;35m")

# 3. Generate YAML config suggestions
if missing_complexity.any?
  puts "\n\e[1;32m=== SUGGESTED STDLIB_COMPLEXITY_RUBY.YML EXPANSIONS ===\e[0m"
  puts "Add these signatures to gems/espalier/lib/espalier/stdlib_complexity_ruby.yml to resolve uncertainty:"
  
  # Group missing method complexities by receiver class
  config_groups = Hash.new { |h, k| h[k] = Set.new }
  missing_complexity.each do |r|
    if r[:warning] =~ /for `([^#`]+)#([^`]+)`/
      config_groups[$1] << $2
    end
  end
  
  config_groups.each do |klass, methods|
    puts "#{klass}:"
    methods.each do |method|
      puts "  #{method}: \"O(N)\"  # TODO: Verify correct complexity"
    end
  end
end

puts "\n\e[90mTip: Pass -v or --verbose to see individual functions and file lines.\e[0m"
