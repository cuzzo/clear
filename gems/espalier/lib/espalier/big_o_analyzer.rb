# frozen_string_literal: true

require "yaml"
require "set"

module Espalier
  class BigOAnalyzer
    attr_reader :registry, :nil_kill_evidence

    def initialize(language: :ruby, nil_kill_evidence: {})
      @language = language
      @nil_kill_evidence = nil_kill_evidence
      @registry = load_registry(language)
    end

    def load_registry(language)
      path = File.join(__dir__, "stdlib_complexity_#{language}.yml")
      return {} unless File.exist?(path)
      YAML.load_file(path) || {}
    end

    # Prototypical analyzer for a method.
    # We pass in `ast_nodes` which represents the parsed AST 
    # (mocked for this prototype as an array of operation hashes).
    def analyze_method(method_name, ast_nodes)
      complexity = "O(1)"
      unknown_operations = []
      warnings = []

      # Lower bound calculation
      # For a prototype, we just scan for the most complex operation in the flat AST.
      # In reality, this would recursively multiply nested loops.
      
      ast_nodes.each do |node|
        if node[:type] == :call
          receiver_type = resolve_type(node[:receiver], node[:line])
          method_called = node[:method].to_s

          if receiver_type
            known_complexity = @registry.dig(receiver_type, method_called)
            if known_complexity
              # If it's sequential, we just take the max of what we've seen so far.
              complexity = max_complexity(complexity, known_complexity)
            end
          else
            unknown_operations << "#{node[:receiver]}.#{method_called}"
            warnings << "Unknown receiver type for `#{node[:receiver]}` at line #{node[:line]}. Defaulting to O(1) for `.#{method_called}`, but this could be worse."
          end
        elsif node[:type] == :loop
          # multiply inner complexity
          complexity = multiply_complexity(complexity, "O(N)")
        elsif node[:type] == :callback || node[:type] == :yield
          warnings << "Function pointer / callback executed at line #{node[:line]}. This could execute arbitrary O(N^x) code, meaning our calculation is strictly a LOWER BOUND."
        end
      end

      {
        method: method_name,
        lower_bound_complexity: complexity,
        unknown_operations: unknown_operations.uniq,
        warnings: warnings.uniq
      }
    end

    private

    def resolve_type(receiver_name, line)
      # Mock nil_kill resolution
      # If nil_kill_evidence has a type for this receiver at this line, return it.
      # Otherwise return nil.
      @nil_kill_evidence.dig(line.to_s, receiver_name.to_s)
    end

    def max_complexity(current, added)
      rank = {
        "O(1)" => 1,
        "O(log N)" => 2,
        "O(N)" => 3,
        "O(N log N)" => 4,
        "O(N * M)" => 5,
        "O(N^2)" => 6
      }
      
      r1 = rank[current] || 1
      r2 = rank[added] || 1
      r1 > r2 ? current : added
    end

    def multiply_complexity(current, multiplier)
      return multiplier if current == "O(1)"
      return "O(N^2)" if current == "O(N)" && multiplier == "O(N)"
      return "O(N^2 log N)" if current == "O(N log N)" && multiplier == "O(N)"
      # fallback
      "#{current} * #{multiplier}"
    end
  end
end
