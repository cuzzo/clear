# frozen_string_literal: true

require "yaml"
require_relative "symbolic_complexity"
require "set"

module Espalier
  class BigOAnalyzer
    STDLIB_RETURN_TYPES = {
      "Array" => {
        "compact" => "Array",
        "filter_map" => "Array",
        "flatten" => "Array",
        "map" => "Array",
        "reject" => "Array",
        "select" => "Array",
        "sort" => "Array",
        "sort_by" => "Array",
        "to_a" => "Array"
      },
      "Hash" => {
        "keys" => "Array",
        "map" => "Array",
        "sort" => "Array",
        "sort_by" => "Array",
        "to_a" => "Array",
        "values" => "Array"
      },
      "Set" => {
        "map" => "Array",
        "sort" => "Array",
        "sort_by" => "Array",
        "to_a" => "Array"
      }
    }.freeze

    attr_reader :registry, :nil_kill_evidence

    def initialize(language: :ruby, nil_kill_evidence: {}, class_name: nil, ivar_types: {}, nil_kill: nil, local_types: {}, declared_fields: {})
      @language = language
      @nil_kill_evidence = nil_kill_evidence
      @class_name = class_name
      @ivar_types = ivar_types || {}
      @local_types = local_types || {}
      @nil_kill = nil_kill
      @declared_fields = declared_fields.each_with_object({}) do |(owner, fields), index|
        index[clean_type_name(owner)] = Set.new(Array(fields).map { |field| field.to_s.delete_prefix("@") })
      end
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
    def analyze_method(method_name, ast_nodes, local_types: nil)
      previous_local_types = @local_types
      @local_types = local_types if local_types
      complexity = "O(1)"
      space_complexity = "O(1)"
      time_complete = true
      space_complete = true
      symbolic_time = nil
      is_dynamic = false
      trigger = nil
      unknown_operations = []
      warnings = []

      # Lower bound calculation
      # For a prototype, we just scan for the most complex operation in the flat AST.
      # In reality, this would recursively multiply nested loops.
      
      ast_nodes.each do |node|
        if node[:type] == :call
          # Internal calls are summarized by StructuralBigO's fixed point. An
          # O(1) callee intentionally produces no structural hint, so the call
          # itself must not be mistaken for unresolved external behavior.
          next if node[:internal_call]

          if node[:known_time_complexity]
            known_complexity = node[:known_time_complexity].to_s
            if node[:symbolic_time]
              symbolic_time = Espalier::SymbolicComplexity.sum(symbolic_time, node[:symbolic_time])
              known_complexity = Espalier::SymbolicComplexity.render(symbolic_time)&.first || known_complexity
            elsif node[:execution_complexity]
              known_complexity = multiply_complexity(known_complexity, node[:execution_complexity])
            end
            complexity = max_complexity(complexity, known_complexity)
            if node[:known_space_complexity]
              space_complexity = max_space_complexity(space_complexity, node[:known_space_complexity].to_s)
            end
            next
          end

          receiver_type = resolve_type(node[:receiver], node[:line])
          method_called = node[:method].to_s

          if receiver_type
            known_complexity = @registry.dig(receiver_type, method_called)
            if known_complexity
              known_complexity = multiply_complexity(known_complexity, node[:execution_complexity]) if node[:execution_complexity]
              # If it's sequential, we just take the max of what we've seen so far.
              complexity = max_complexity(complexity, known_complexity)
            elsif (chained_complexity = flattened_chain_complexity(node, ast_nodes))
              chained_complexity = multiply_complexity(chained_complexity, node[:execution_complexity]) if node[:execution_complexity]
              complexity = max_complexity(complexity, chained_complexity)
            elsif declared_field?(receiver_type, method_called) || state_accessor_return_type(receiver_type, method_called)
              complexity = max_complexity(complexity, "O(1)")
            else
              unknown_operations << "#{receiver_type}##{method_called}"
              time_complete = false
              space_complete = false
              warnings << "Missing method complexity for `#{receiver_type}##{method_called}` in stdlib_complexity_ruby.yml at line #{node[:line]}."
              if Array(node[:collection_arguments]).any? && !node[:internal_call]
                warnings << unknown_collection_call_warning(node, method_called)
              end
            end
          else
            unknown_operations << "#{node[:receiver]}.#{method_called}"
            time_complete = false
            space_complete = false
            warnings << "Unknown receiver type for `#{node[:receiver]}` at line #{node[:line]}. Defaulting to O(1) for `.#{method_called}`, but this could be worse."
            if Array(node[:collection_arguments]).any?
              warnings << unknown_collection_call_warning(node, method_called)
            end
          end
        elsif node[:type] == :loop
          # Runtime loop evidence is currently flat by source line. Without a
          # nesting tree, multiple observed loops in one method are a sequential
          # lower bound, not proof of nested O(N^k) behavior.
          complexity = max_complexity(complexity, "O(N)")
          is_dynamic = true
        elsif node[:type] == :structural
          structural_complexity = node[:complexity].to_s
          if node[:symbolic_time]
            symbolic_time = Espalier::SymbolicComplexity.sum(symbolic_time, node[:symbolic_time])
            rendered_symbolic = Espalier::SymbolicComplexity.render(symbolic_time)&.first
            if rendered_symbolic && complexity_rank(rendered_symbolic) >= complexity_rank(structural_complexity)
              structural_complexity = rendered_symbolic
            end
          end
          time_complete = false if node[:time_complete] == false
          space_complete = false if node[:space_complete] == false
          if structural_complexity == "unknown"
            time_complete = false
          else
            complexity = max_complexity(complexity, structural_complexity)
          end
          if node[:space]
            if node[:space].to_s == "unknown"
              space_complete = false
            else
              space_complexity = max_space_complexity(space_complexity, node[:space].to_s)
            end
          end
          if node[:is_dynamic]
            is_dynamic = true
            trigger ||= node[:trigger]
          end
          warnings << structural_warning(node) if structural_complexity != "O(1)"
        elsif node[:type] == :callback || node[:type] == :yield
          time_complete = false
          space_complete = false
          warnings << "Function pointer / callback executed at line #{node[:line]}. This could execute arbitrary O(N^x) code, meaning our calculation is strictly a LOWER BOUND."
        end
      end

      {
        method: method_name,
        lower_bound_complexity: time_complete ? complexity : "unknown",
        space_complexity: space_complete ? space_complexity : "unknown",
        known_time_component: complexity,
        known_space_component: space_complexity,
        symbolic_time: symbolic_time,
        complexity_variables: Espalier::SymbolicComplexity.render(symbolic_time)&.last || [],
        time_complete: time_complete,
        space_complete: space_complete,
        is_dynamic: is_dynamic,
        trigger: trigger,
        unknown_operations: unknown_operations.uniq,
        warnings: warnings.uniq
      }
    ensure
      @local_types = previous_local_types if local_types
    end

    private

    def unknown_collection_call_warning(node, method_called)
      names = Array(node[:collection_arguments]).join(", ")
      "Unknown loop-contained call `.#{method_called}` receives known collection parameter(s) #{names}; runtime evidence is required before assigning a polynomial bound."
    end

    def clean_type_name(type_str)
      return nil unless type_str
      type_str = type_str.to_s.strip
      if type_str =~ /^T\.nilable\((.+)\)$/
        clean_type_name($1)
      elsif type_str =~ /^T\.any\((.+)\)$/
        types = $1.split(/\s*,\s*/)
        non_nil = types.reject { |t| t == "NilClass" || t == "nil" }
        clean_type_name(non_nil.first || types.first)
      elsif type_str =~ /^(?:T::|T\.)(Array|Hash|Set|Enumerable)\[.+\]$/
        $1
      else
        type_str
      end
    end

    def extract_return_type(signature)
      return nil unless signature
      if signature =~ /returns\(([^)]+)\)/
        $1.strip
      elsif signature =~ /->\s*([A-Za-z0-9_:]+)/
        $1.strip
      end
    end

    def resolve_type(receiver_name, line)
      return nil unless receiver_name
      receiver_name = receiver_name.to_s

      if receiver_name.include?(".")
        parts = receiver_name.split(".")
        current_type = resolve_simple_type(parts.first, line)
        parts[1..].each do |part|
          return nil unless current_type
          current_type = resolve_method_return_type(current_type, part)
        end
        clean_type_name(current_type)
      else
        resolve_simple_type(receiver_name, line)
      end
    end

    def resolve_simple_type(receiver_name, line)
      if receiver_name == "self"
        return clean_type_name(@class_name)
      end

      if (type = @local_types[receiver_name])
        return clean_type_name(type)
      end

      if receiver_name.start_with?("@")
        type = @ivar_types[receiver_name] || @ivar_types[receiver_name[1..]]
        return clean_type_name(type) if type
      end

      if (type = @ivar_types["@#{receiver_name}"] || @ivar_types[receiver_name])
        return clean_type_name(type)
      end

      if @class_name && @nil_kill
        sig = @nil_kill.method_signatures["#{@class_name}##{receiver_name}"]
        if sig
          ret = extract_return_type(sig)
          return clean_type_name(ret) if ret
        end
      end

      if @nil_kill_evidence
        type = @nil_kill_evidence.dig(line.to_s, receiver_name) || @nil_kill_evidence.dig(line.to_s, "@#{receiver_name}")
        return clean_type_name(type) if type
      end

      nil
    end

    def resolve_method_return_type(class_name, method_name)
      return nil unless class_name

      if @nil_kill
        sig = @nil_kill.method_signatures["#{class_name}##{method_name}"]
        if sig
          ret = extract_return_type(sig)
          return clean_type_name(ret)
        end

        state_type = state_accessor_return_type(class_name, method_name)
        return state_type if state_type
      end

      stdlib_type = STDLIB_RETURN_TYPES.dig(class_name, method_name)
      return clean_type_name(stdlib_type) if stdlib_type

      nil
    end

    def state_accessor_return_type(class_name, method_name)
      return nil unless @nil_kill&.respond_to?(:state_types)

      clean_type_name(@nil_kill.state_types.dig(class_name, "@#{method_name}"))
    end

    def declared_field?(class_name, method_name)
      fields = @declared_fields[clean_type_name(class_name)]
      fields&.include?(method_name.to_s.delete_prefix("@"))
    end

    def flattened_chain_complexity(node, ast_nodes)
      receiver = node[:receiver].to_s
      method_called = node[:method].to_s
      line = node[:line]

      Array(ast_nodes).each do |candidate|
        next unless candidate[:type] == :call
        next unless candidate[:receiver].to_s == receiver
        next unless candidate[:line] == line
        accessor = candidate[:method].to_s
        next if accessor == method_called

        chained_type = resolve_type("#{receiver}.#{accessor}", line)
        known_complexity = @registry.dig(chained_type, method_called)
        return known_complexity if known_complexity
      end

      nil
    end

    def max_complexity(current, added)
      return "unknown" if current == "unknown" || added == "unknown"

      r1 = complexity_rank(current)
      r2 = complexity_rank(added)
      r1 > r2 ? current : added
    end

    def structural_warning(node)
      parts = ["Structural Big-O hint at line #{node[:line]}"]
      parts << node[:reason].to_s unless node[:reason].to_s.empty?
      parts << "`#{node[:operation]}`" unless node[:operation].to_s.empty?
      parts << "=> #{node[:complexity]}"
      parts.join(": ")
    end

    def complexity_rank(complexity)
      return 1 if complexity.nil?
      return 1 if complexity == "O(1)" || complexity == "unknown"
      return 2 if complexity == "O(log N)"
      return 100 if complexity == "O(2^N)"
      return 200 if complexity == "O(N!)"

      rank = Espalier::SymbolicComplexity.rank_string(complexity)
      return 1 if rank.negative?
      return 10 if rank == 1
      return 11 if rank == 1.1

      10 + (rank.floor * 2) + (rank.modulo(1).positive? ? 1 : 0)
    end

    def multiply_complexity(current, multiplier)
      return multiplier if current == "O(1)"
      return current if multiplier == "O(1)"
      return "O(N!)" if current == "O(N!)" || multiplier == "O(N!)"
      return "O(2^N)" if current == "O(2^N)" || multiplier == "O(2^N)"
      
      c_pow = 0
      c_log = false
      if current == "O(N)"
        c_pow = 1
      elsif current =~ /O\(N\^(\d+)\)/
        c_pow = $1.to_i
      elsif current =~ /O\(N\^(\d+) log N\)/
        c_pow = $1.to_i
        c_log = true
      elsif current == "O(N log N)"
        c_pow = 1
        c_log = true
      elsif current == "O(log N)"
        c_log = true
      end

      m_pow = 0
      m_log = false
      if multiplier == "O(N)"
        m_pow = 1
      elsif multiplier =~ /O\(N\^(\d+)\)/
        m_pow = $1.to_i
      elsif multiplier =~ /O\(N\^(\d+) log N\)/
        m_pow = $1.to_i
        m_log = true
      elsif multiplier == "O(N log N)"
        m_pow = 1
        m_log = true
      elsif multiplier == "O(log N)"
        m_log = true
      end

      new_pow = c_pow + m_pow
      new_log = c_log || m_log

      if new_pow == 0
        new_log ? "O(log N)" : "O(1)"
      elsif new_pow == 1
        new_log ? "O(N log N)" : "O(N)"
      else
        new_log ? "O(N^#{new_pow} log N)" : "O(N^#{new_pow})"
      end
    end

    def max_space_complexity(current, added)
      return "unknown" if current == "unknown" || added == "unknown"

      r1 = space_complexity_rank(current)
      r2 = space_complexity_rank(added)
      r1 > r2 ? current : added
    end

    def space_complexity_rank(space)
      case space.to_s
      when "O(N)" then 10
      when "O(log N)" then 5
      when "O(1)" then 1
      else 1
      end
    end
  end
end
