#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"
require "set"

$LOAD_PATH.unshift("/home/yahn/litedb/gems/espalier/lib")
$LOAD_PATH.unshift("/home/yahn/litedb/gems/nil-kill/lib")
$LOAD_PATH.unshift("/home/yahn/litedb/gems/fact-mine/lib")

require "espalier/big_o_analyzer"
require "espalier/nil_kill_evidence"
require "espalier/static_evidence"
require "espalier/aggregator"

manifest_path = File.expand_path("../espalier_manifest.yml", __dir__)
nil_kill_path = "/tmp/clear-nil-kill/evidence.json"

explain_target = nil
ARGV.each_with_index do |arg, idx|
  if arg == "--explain"
    explain_target = ARGV[idx + 1]
  end
end

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

if explain_target
  puts "Loading nil-kill evidence for detailed trace..."
  nk = if File.exist?(nil_kill_path)
         Espalier::NilKillEvidence.load(nil_kill_path)
       else
         Espalier::NilKillEvidence.new({})
       end

  # Find the method
  matched_fn = nil
  matched_mod = nil
  
  manifest.each do |mod|
    mod[:functions].each do |fn|
      fn_key = "#{mod[:module] || mod[:name]}##{fn[:name]}"
      if fn_key.downcase.include?(explain_target.downcase)
        matched_fn = fn
        matched_mod = mod
        break
      end
    end
    break if matched_fn
  end

  unless matched_fn
    puts "\e[31merror:\e[0m no method matches '#{explain_target}' in the manifest."
    exit 1
  end

  mod_name = matched_mod[:module] || matched_mod[:name]
  fn_name = matched_fn[:name]
  file = matched_mod[:file]
  meth_line = matched_fn[:line] || 0
  
  # Re-evaluate ast_nodes like Aggregator does
  next_meth = matched_mod[:functions][matched_mod[:functions].index(matched_fn) + 1]
  end_line = next_meth ? (next_meth[:line] || Float::INFINITY) : Float::INFINITY

  ast_nodes = Array(matched_fn[:delegations] || []).map do |d|
    { type: :call, receiver: d[:receiver], method: d[:message], line: matched_fn[:line] || 0 }
  end

  if file && nk.loop_counts && nk.loop_counts[file]
    nk.loop_counts[file].each do |line, calls|
      if line >= meth_line && line < end_line && calls > 0
        ast_nodes << { type: :loop, line: line, calls: calls }
      end
    end
  end

  puts "\n\e[1m=== EXPLAINING COMPLEXITY: #{mod_name}##{fn_name} ===\e[0m"
  puts "File:        #{file}"
  puts "Line range:  #{meth_line} to #{end_line == Float::INFINITY ? 'EOF' : end_line}"
  puts "Analyzed AST operations: #{ast_nodes.size}"
  puts "----------------------------------------"

  analyzer = Espalier::BigOAnalyzer.new(
    nil_kill_evidence: nk.loop_counts,
    class_name: mod_name,
    ivar_types: matched_mod[:ivar_types] || {},
    nil_kill: nk
  )

  current_complexity = "O(1)"
  ast_nodes.each_with_index do |node, index|
    step_num = index + 1
    if node[:type] == :call
      receiver_type = analyzer.send(:resolve_type, node[:receiver], node[:line])
      method_called = node[:method].to_s
      
      if receiver_type
        known_complexity = analyzer.registry.dig(receiver_type, method_called)
        if known_complexity
          prev = current_complexity
          current_complexity = analyzer.send(:max_complexity, current_complexity, known_complexity)
          puts "  \e[32m[Step #{step_num}]\e[0m Call: `#{node[:receiver]}.#{method_called}` at line #{node[:line]}"
          puts "           -> Resolved receiver to `#{receiver_type}`"
          puts "           -> Signature complexity: #{known_complexity}"
          puts "           -> Complexity update: #{prev} -> #{current_complexity}"
        else
          puts "  \e[33m[Step #{step_num}]\e[0m Call: `#{node[:receiver]}.#{method_called}` at line #{node[:line]}"
          puts "           -> Resolved receiver to `#{receiver_type}`"
          puts "           -> \e[33mWarning:\e[0m Missing method complexity for `#{receiver_type}##{method_called}` in stdlib_complexity_ruby.yml."
          puts "           -> Complexity remains: #{current_complexity}"
        end
      else
        puts "  \e[34m[Step #{step_num}]\e[0m Call: `#{node[:receiver]}.#{method_called}` at line #{node[:line]}"
        puts "           -> \e[34mWarning:\e[0m Unknown receiver type for `#{node[:receiver]}`"
        puts "           -> Complexity remains: #{current_complexity}"
      end
    elsif node[:type] == :loop
      prev = current_complexity
      current_complexity = analyzer.send(:multiply_complexity, current_complexity, "O(N)")
      puts "  \e[35m[Step #{step_num}]\e[0m Loop: detected at line #{node[:line]} (iteration count: #{node[:calls]})"
      puts "           -> Multiplied complexity by O(N)"
      puts "           -> Complexity update: #{prev} -> #{current_complexity}"
    end
  end

  puts "----------------------------------------"
  puts "\e[1;31mFinal calculated complexity:\e[0m #{current_complexity}"
  
  if current_complexity =~ /O\(N\^(\d+)\)/ && $1.to_i > 3
    puts "\n\e[1;33mDiagnostic Insight:\e[0m"
    puts "This method has an unusually high complexity of #{current_complexity}."
    puts "This is typically caused by one of two factors:"
    puts "1. \e[1mSequential loops treated as nested:\e[0m The Big-O analyzer currently multiplies all loop complexities"
    puts "   found within the method's line span. If the loops are sequential rather than nested, this leads to an inflated"
    puts "   exponent (e.g. 5 sequential loops evaluated as O(N^5) instead of O(N))."
    puts "2. \e[1mMethod boundary detection issue:\e[0m If this is the last method in the file, it defaults its end line"
    puts "   to the end of the file. Any loops in subsequent lines/methods will be incorrectly counted towards this function."
  end
  exit 0
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
puts "\e[90m     Pass --explain \"<Module>#<Method>\" to trace the evaluation steps.\e[0m"
