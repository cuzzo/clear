require_relative "lib/ruby_to_clear"

def analyze_file(in_path)
  source = File.read(in_path)
  clear_code = RubyToClear.transpile(source, raise_on_error: false)
  
  # 1. Parse function signatures
  # FN <name>(<params>) RETURNS <return_type> ->
  total_params = 0
  auto_params = 0
  typed_params = 0
  
  total_returns = 0
  auto_returns = 0
  typed_returns = 0
  
  clear_code.scan(/FN\s+(\w+!*)\s*\((.*?)\)\s*RETURNS\s+(\S+)\s*->/) do |name, params_str, ret_type|
    # Exclude initialize! from return type analysis since it's always Void
    unless name == "initialize!"
      total_returns += 1
      if ret_type == "!Auto" || ret_type == "Auto"
        auto_returns += 1
      else
        typed_returns += 1
      end
    end
    
    # Parse parameters
    # E.g. "MUTABLE self: Calc, tokens: Lexer.Token[]"
    next if params_str.strip.empty?
    params_str.split(",").each do |param|
      param_clean = param.strip
      next if param_clean.empty?
      
      # Exclude "self"
      next if param_clean.start_with?("self:") || param_clean.start_with?("MUTABLE self:")
      
      total_params += 1
      if param_clean.end_with?(": Auto")
        auto_params += 1
      else
        typed_params += 1
      end
    end
  end
  
  # 2. Analyze .map, .select, .each, .reduce calls
  # Count original calls in Ruby source
  # Note: we use regular expressions to estimate the counts in original source
  ruby_maps = source.scan(/\.\bmap\b/).size
  ruby_selects = source.scan(/\.\b(select|filter)\b/).size
  ruby_eachs = source.scan(/\.\beach\b/).size
  ruby_reduces = source.scan(/\.\b(reduce|inject)\b/).size
  
  # Count successfully transpiled pipelines in CLEAR code
  clear_selects = clear_code.scan(/\|>\s*SELECT\b/).size
  clear_wheres = clear_code.scan(/\|>\s*WHERE\b/).size
  clear_eachs = clear_code.scan(/\|>\s*EACH\b/).size
  clear_reduces = clear_code.scan(/\|>\s*REDUCE\b/).size
  
  puts "========================================"
  puts "Analysis for: #{in_path}"
  puts "========================================"
  puts "Method Parameters Type Coverage:"
  puts "  Total Parameters (excl. self): #{total_params}"
  puts "  Typed Parameters:              #{typed_params} (#{(typed_params.to_f / total_params * 100).round(2)}%)" if total_params > 0
  puts "  Auto Parameters:               #{auto_params} (#{(auto_params.to_f / total_params * 100).round(2)}%)" if total_params > 0
  puts "Method Returns Type Coverage:"
  puts "  Total Returns (excl. init):    #{total_returns}"
  puts "  Typed Returns:                 #{typed_returns} (#{(typed_returns.to_f / total_returns * 100).round(2)}%)" if total_returns > 0
  puts "  Auto Returns:                  #{auto_returns} (#{(auto_returns.to_f / total_returns * 100).round(2)}%)" if total_returns > 0
  puts "Pipeline Mapping Success Rate:"
  puts "  .map:   #{clear_selects} / #{ruby_maps} mapped to |> SELECT"
  puts "  .select/filter: #{clear_wheres} / #{ruby_selects} mapped to |> WHERE"
  puts "  .each:  #{clear_eachs} / #{ruby_eachs} mapped to |> EACH"
  puts "  .reduce/inject: #{clear_reduces} / #{ruby_reduces} mapped to |> REDUCE"
end

analyze_file("../../src/ast/lexer.rb")
analyze_file("../../src/ast/parser.rb")
