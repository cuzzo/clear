# frozen_string_literal: true

module Espalier
  class StructuralBigO
    FIXPOINT_NAMES = %w[changed progress dirty updated again].freeze
    FIXPOINT_COLLECTION_METHODS = %w[
      each each_key each_value each_with_index any? all? count
    ].freeze
    AGGREGATE_SCAN_METHODS = %w[all? any? count].freeze

    LOOP_START = /
      \b(?:while|until)\b|
      \bloop\s+do\b|
      \.(?:each|each_key|each_value|each_with_index|map|map!|select|reject|filter|filter_map|flat_map|sort_by|reverse_each)\b
    /x.freeze

    def initialize(source_cache: {}, method_complexities: {})
      @source_cache = source_cache
      @method_complexities = method_complexities.transform_values do |methods|
        methods.select { |_name, complexity| complexity_rank(complexity) >= complexity_rank("O(N)") }
      end
    end

    def hints_for(file, method, owner)
      return [] unless file && method[:span].is_a?(Array)
      lines = source_lines(file)
      return [] if lines.empty?

      start_line = method[:line].to_i
      end_line = method[:span][2].to_i
      return [] if start_line <= 0 || end_line < start_line

      slice = lines[(start_line - 1)..(end_line - 1)] || []
      loops = loop_ranges(slice, start_line)

      constants = Set.new
      lines.each do |line|
        if line =~ /\b(?:const\s+([A-Z_a-z]\w*)|([A-Z][A-Z_0-9]*)\s*=)/
          constants.add($1 || $2)
        end
      end

      hints = []
      hints.concat(polynomial_loop_hints(lines, loops, start_line, constants))
      hints.concat(recursion_hints(lines, method, start_line, end_line))
      loops.each do |loop_range|
        classification = classify_loop(loop_range[:text], loop_range[:start], start_line, lines, constants)
        is_dynamic = classification[:is_dynamic]
        trigger = classification[:trigger]

        if fixpoint_loop?(lines, loop_range)
          hints.concat(
            fixpoint_collection_hints(lines, loop_range).map do |h|
              h.merge(is_dynamic: is_dynamic, trigger: trigger)
            end
          )
          hints.concat(
            project_call_hints(lines, loop_range, owner).map do |h|
              h.merge(is_dynamic: is_dynamic, trigger: trigger)
            end
          )
        end
        hints.concat(
          expensive_project_call_hints(lines, loop_range, owner, method[:name].to_s).map do |h|
            h.merge(is_dynamic: is_dynamic, trigger: trigger)
          end
        )
        hints.concat(
          aggregate_scan_hints(lines, loop_range).map do |h|
            h.merge(is_dynamic: is_dynamic, trigger: trigger)
          end
        )
        hints.concat(
          shifting_insert_hints(lines, loop_range).map do |h|
            h.merge(is_dynamic: is_dynamic, trigger: trigger)
          end
        )
        hints.concat(
          graph_traversal_hints(lines, loops, loop_range).map do |h|
            h.merge(is_dynamic: is_dynamic, trigger: trigger)
          end
        )
      end
      hints.uniq { |hint| [hint[:line], hint[:reason], hint[:operation]] }
    end

    private

    def source_lines(file)
      @source_cache[file] ||= File.file?(file) ? File.readlines(file) : []
    end

    def loop_ranges(slice, start_line)
      ranges = []
      heredoc_end = nil
      slice.each_with_index do |line, offset|
        stripped = line.strip
        if heredoc_end
          heredoc_end = nil if stripped == heredoc_end
          next
        end
        if (match = line.match(/<<[-~]?([A-Z][A-Z0-9_]*)/))
          heredoc_end = match[1]
        end
        next unless loop_start?(line)

        absolute_line = start_line + offset
        ranges << {
          start: absolute_line,
          finish: block_finish(slice, offset, start_line),
          inline: inline_loop?(line),
          text: line.strip
        }
      end
      ranges
    end

    def loop_start?(line)
      stripped = line.strip
      return false if stripped.start_with?("#", '"', "'", "%Q", "%q")

      line.match?(LOOP_START)
    end

    def block_finish(slice, start_offset, start_line)
      return start_line + start_offset if inline_loop?(slice[start_offset])
      return brace_block_finish(slice, start_offset, start_line) if opens_brace_block?(slice[start_offset])

      start_indent = indent_width(slice[start_offset])
      ((start_offset + 1)...slice.length).each do |idx|
        line = slice[idx]
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        if stripped == "end" && indent_width(line) <= start_indent
          return start_line + idx
        end
      end
      start_line + slice.length - 1
    end

    def opens_brace_block?(line)
      line.include?("{") && !balanced_braces?(line)
    end

    def brace_block_finish(slice, start_offset, start_line)
      depth = 0
      (start_offset...slice.length).each do |idx|
        slice[idx].each_char do |char|
          depth += 1 if char == "{"
          depth -= 1 if char == "}"
        end
        return start_line + idx if depth <= 0
      end
      start_line + slice.length - 1
    end

    def inline_loop?(line)
      stripped = line.strip
      return true if stripped.match?(/\A.+\b(?:while|until)\b.+\z/) && !stripped.start_with?("while ", "until ")
      return true if stripped.include?("{") && balanced_braces?(stripped)
      return true if collection_method_call?(stripped) && !stripped.match?(/\bdo\b/) && !stripped.include?("{")

      false
    end

    def collection_method_call?(line)
      line.match?(/\.(?:each|each_key|each_value|each_with_index|map|map!|select|reject|filter|filter_map|flat_map|sort_by|reverse_each)\b/)
    end

    def balanced_braces?(line)
      depth = 0
      line.each_char do |char|
        depth += 1 if char == "{"
        depth -= 1 if char == "}"
      end
      depth <= 0
    end

    def fixpoint_loop?(lines, loop_range)
      text = loop_range[:text]
      return true if text.match?(/\bwhile\s+(?:#{FIXPOINT_NAMES.join("|")})\b/)

      body = body_text(lines, loop_range)
      return false unless text.match?(/\bloop\s+do\b/) || body.match?(/\bwhile\b/)

      body.match?(/\b(?:#{FIXPOINT_NAMES.join("|")})\s*=\s*(?:false|true)\b/) &&
        body.match?(/\bbreak\s+unless\s+(?:#{FIXPOINT_NAMES.join("|")})\b/)
    end

    def polynomial_loop_hints(lines, loops, start_line, constants)
      block_loops = loops.reject { |loop_range| loop_range[:inline] }
      block_loops.filter_map do |loop_range|
        depth = loop_depth(block_loops, loop_range)
        next if depth < 2
        next if containing_fixpoint_loop?(lines, block_loops, loop_range)

        classification = classify_loop(loop_range[:text], loop_range[:start], start_line, lines, constants)

        structural_hint(
          line: loop_range[:start],
          complexity: polynomial_complexity(depth),
          operation: loop_range[:text],
          reason: "nested loop containment depth #{depth}",
          detail: lines[loop_range[:start] - 1].to_s.strip,
          is_dynamic: classification[:is_dynamic],
          trigger: classification[:trigger]
        )
      end
    end

    def loop_depth(loops, loop_range)
      loops.count do |candidate|
        candidate[:start] <= loop_range[:start] && candidate[:finish] >= loop_range[:finish]
      end
    end

    def containing_fixpoint_loop?(lines, loops, loop_range)
      loops.any? do |candidate|
        next false if candidate.equal?(loop_range)
        next false unless candidate[:start] < loop_range[:start] && candidate[:finish] >= loop_range[:finish]

        fixpoint_loop?(lines, candidate)
      end
    end

    def recursion_hints(lines, method, start_line, end_line)
      method_name = method[:name].to_s.sub(/\Aself\./, "")
      return [] if method_name.empty?

      recursive_calls = recursive_call_lines(lines, method_name, start_line, end_line)
      return [] if recursive_calls.empty?

      if factorial_recursion?(lines, recursive_calls, start_line, end_line)
        return [
          structural_hint(
            line: recursive_calls.first,
            complexity: "O(N!)",
            space: "O(N)",
            is_dynamic: true,
            trigger: "line #{start_line}",
            operation: method_name,
            reason: "recursive branching over shrinking collection",
            detail: lines[recursive_calls.first - 1].to_s.strip
          )
        ]
      end

      if exponential_recursion?(lines, recursive_calls)
        return [
          structural_hint(
            line: recursive_calls.first,
            complexity: "O(2^N)",
            space: "O(N)",
            is_dynamic: true,
            trigger: "line #{start_line}",
            operation: method_name,
            reason: "multiple recursive branches",
            detail: lines[recursive_calls.first - 1].to_s.strip
          )
        ]
      end

      if divide_and_conquer_recursion?(lines, recursive_calls)
        return [
          structural_hint(
            line: recursive_calls.first,
            complexity: "O(log N)",
            space: "O(log N)",
            is_dynamic: true,
            trigger: "line #{start_line}",
            operation: method_name,
            reason: "recursive call with division / halving",
            detail: lines[recursive_calls.first - 1].to_s.strip
          )
        ]
      end

      # Linear recursion fallback
      [
        structural_hint(
          line: recursive_calls.first,
          complexity: "O(N)",
          space: "O(N)",
          is_dynamic: true,
          trigger: "line #{start_line}",
          operation: method_name,
          reason: "recursive self call",
          detail: lines[recursive_calls.first - 1].to_s.strip
        )
      ]
    end

    def divide_and_conquer_recursion?(lines, recursive_calls)
      recursive_calls.any? do |line_no|
        line = lines[line_no - 1].to_s
        line.match?(%r{/\s*2\b|>>\s*1\b|\bsplit\b|\bslice\b|mid\b})
      end
    end

    def recursive_call_lines(lines, method_name, start_line, end_line)
      escaped = Regexp.escape(method_name)
      ((start_line + 1)..end_line).flat_map do |line_no|
        line = lines[line_no - 1].to_s
        stripped = line.strip
        next [] if stripped.start_with?("#", "def ")

        line.scan(/(?:^|[^\.\w])#{escaped}\s*\(/).map { line_no }
      end
    end

    def factorial_recursion?(lines, recursive_calls, start_line, end_line)
      slice = lines[(start_line - 1)..(end_line - 1)] || []
      loops = loop_ranges(slice, start_line).reject { |loop_range| loop_range[:inline] }
      return false if loops.empty?

      loops.any? do |loop_range|
        recursive_calls.any? { |line_no| line_no > loop_range[:start] && line_no <= loop_range[:finish] } &&
          shrinking_collection?(body_text(lines, loop_range))
      end
    end

    def shrinking_collection?(body)
      body.match?(/\b(?:remaining|rest|tail|without|others)\b/) ||
        body.match?(/\.(?:reject|drop|delete|delete_at|slice)\b/) ||
        body.match?(/\s-\s*\[/)
    end

    def exponential_recursion?(lines, recursive_calls)
      return false if recursive_calls.length < 2

      recursive_calls.tally.any? do |line_no, count|
        next false if count < 2

        lines[line_no - 1].to_s.match?(/-\s*(?:1|2)\b|\b(?:rest|tail|remaining)\b/)
      end
    end

    def fixpoint_collection_hints(lines, loop_range)
      body_lines(lines, loop_range).filter_map do |line_no, line|
        method_name = fixpoint_collection_method_on_line(line)
        next unless method_name

        structural_hint(
          line: line_no,
          operation: method_name,
          reason: "linear collection scan inside fixpoint loop",
          detail: line.strip
        )
      end
    end

    def fixpoint_collection_method_on_line(line)
      return nil if line.strip.start_with?("#")

      FIXPOINT_COLLECTION_METHODS.find do |method_name|
        escaped = Regexp.escape(method_name)
        line.match?(/(?:\.|\b)#{escaped}\b\s*(?:\{|do|\()/)
      end
    end

    def project_call_hints(lines, loop_range, owner)
      return [] unless owner

      linear_methods = @method_complexities.fetch(owner, {})
      return [] if linear_methods.empty?

      body_lines(lines, loop_range).filter_map do |line_no, line|
        method_name = linear_methods.keys.find { |name| bare_method_call?(line, name) }
        next unless method_name

        structural_hint(
          line: line_no,
          operation: method_name,
          reason: "known linear project call inside fixpoint loop",
          detail: line.strip
        )
      end
    end

    def expensive_project_call_hints(lines, loop_range, owner, current_method_name)
      return [] unless owner

      current_method_name = current_method_name.sub(/\Aself\./, "")
      expensive_methods = @method_complexities.fetch(owner, {}).select do |_name, complexity|
        complexity_rank(complexity) >= complexity_rank("O(N^2)")
      end
      return [] if expensive_methods.empty?

      body_lines(lines, loop_range).filter_map do |line_no, line|
        method_name, method_complexity = expensive_methods.find do |name, _|
          next false if name.sub(/\Aself\./, "") == current_method_name

          bare_method_call?(line, name)
        end
        next unless method_name && method_complexity

        structural_hint(
          line: line_no,
          complexity: multiply_complexity("O(N)", method_complexity),
          operation: method_name,
          reason: "known expensive project call inside loop",
          detail: line.strip
        )
      end
    end

    def bare_method_call?(line, method_name)
      return false if method_name.start_with?("self.")
      return false if line.strip.start_with?("#")

      escaped = Regexp.escape(method_name)
      line.match?(/(?:^|[^\.\w])#{escaped}\b\s*(?:\(|\{|do|\z)/)
    end

    def aggregate_scan_hints(lines, loop_range)
      return [] unless collection_iterator?(loop_range[:text])

      body_lines(lines, loop_range).filter_map do |line_no, line|
        method_name = aggregate_scan_on_line(line)
        next unless method_name

        structural_hint(
          line: line_no,
          operation: method_name,
          reason: "aggregate collection scan inside collection loop",
          detail: line.strip
        )
      end
    end

    def aggregate_scan_on_line(line)
      stripped = line.strip
      return nil if stripped.start_with?("#")

      AGGREGATE_SCAN_METHODS.find do |method_name|
        escaped = Regexp.escape(method_name)
        stripped.match?(/\.#{escaped}\b\s*(?:\{|do)/)
      end
    end

    def shifting_insert_hints(lines, loop_range)
      return [] unless explicit_loop?(loop_range[:text])

      body_lines(lines, loop_range).filter_map do |line_no, line|
        next unless line.match?(/\.insert\s*\(/)

        structural_hint(
          line: line_no,
          operation: "insert",
          reason: "array insert inside loop can shift remaining elements",
          detail: line.strip
        )
      end
    end

    def graph_traversal_hints(lines, loops, outer_range)
      return [] unless collection_iterator?(outer_range[:text])
      return [] unless graph_source?(outer_range[:text])

      loops.filter_map do |inner|
        next if inner.equal?(outer_range)
        next unless inner[:start] > outer_range[:start] && inner[:start] <= outer_range[:finish]
        next unless queue_loop?(inner[:text])
        next unless body_text(lines, inner).match?(/function_call_graph\s*\[/)

        structural_hint(
          line: inner[:start],
          operation: inner[:text],
          reason: "graph traversal inside per-node graph loop",
          detail: lines[inner[:start] - 1].to_s.strip
        )
      end
    end

    def collection_iterator?(line)
      line.match?(/\.(?:each|each_key|each_value|each_with_index|map|map!|select|reject|filter|filter_map|flat_map|sort_by|reverse_each)\b\s*(?:\{|do)/)
    end

    def explicit_loop?(line)
      line.match?(/\A\s*(?:while|until)\b|\bloop\s+do\b/)
    end

    def graph_source?(line)
      line.match?(/\b(?:function_call_graph|call_graph|cfg|graph)\b/)
    end

    def queue_loop?(line)
      line.match?(/\b(?:while|until)\s+[^#]*(?:queue|worklist|stack)\./)
    end

    def body_lines(lines, loop_range)
      ((loop_range[:start] + 1)..loop_range[:finish]).map do |line_no|
        [line_no, lines[line_no - 1].to_s]
      end
    end

    def body_text(lines, loop_range)
      body_lines(lines, loop_range).map { |_, line| line }.join
    end

    def indent_width(line)
      line[/\A\s*/].to_s.length
    end

    def structural_hint(line:, operation:, reason:, detail:, complexity: "O(N^2)", space: nil, is_dynamic: true, trigger: nil)
      {
        type: :structural,
        line: line,
        complexity: complexity,
        space: space,
        is_dynamic: is_dynamic,
        trigger: trigger,
        operation: operation,
        reason: reason,
        detail: detail
      }
    end

    def polynomial_complexity(depth)
      depth == 1 ? "O(N)" : "O(N^#{depth})"
    end

    def complexity_rank(complexity)
      case complexity.to_s
      when "O(1)" then 1
      when "O(log N)" then 2
      when "O(N)" then 10
      when "O(N log N)" then 11
      when "O(N * M)" then 14
      when /\AO\(N\^(\d+)( log N)?\)\z/
        10 + ($1.to_i * 2) + ($2 ? 1 : 0)
      when "O(2^N)" then 100
      when "O(N!)" then 200
      else
        1
      end
    end

    def multiply_complexity(current, multiplier)
      return multiplier if current == "O(1)"
      return current if multiplier == "O(1)"
      return "O(N!)" if current == "O(N!)" || multiplier == "O(N!)"
      return "O(2^N)" if current == "O(2^N)" || multiplier == "O(2^N)"

      current_power, current_log = polynomial_parts(current)
      multiplier_power, multiplier_log = polynomial_parts(multiplier)
      power = current_power + multiplier_power
      with_log = current_log || multiplier_log

      if power.zero?
        with_log ? "O(log N)" : "O(1)"
      elsif power == 1
        with_log ? "O(N log N)" : "O(N)"
      else
        with_log ? "O(N^#{power} log N)" : "O(N^#{power})"
      end
    end

    def polynomial_parts(complexity)
      case complexity.to_s
      when "O(N)" then [1, false]
      when "O(N log N)" then [1, true]
      when "O(log N)" then [0, true]
      when /\AO\(N\^(\d+)( log N)?\)\z/
        [$1.to_i, !$2.nil?]
      else
        [0, false]
      end
    end

    def classify_loop(loop_line, loop_line_no, start_line, lines, constants)
      trigger_var = extract_bound_variable(loop_line)
      if trigger_var.nil? || constants.include?(trigger_var)
        { is_dynamic: false, trigger: nil }
      else
        def_line = find_variable_definition_line(lines, trigger_var, loop_line_no, start_line)
        trigger = def_line ? "line #{def_line}" : nil
        { is_dynamic: true, trigger: trigger }
      end
    end

    def extract_bound_variable(loop_line)
      # 1. for x in collection / for x in &collection
      if loop_line =~ /\bin\s+&?(?:mut\s+)?([a-zA-Z_]\w*)\b/
        return $1
      end
      # 2. for x := range collection
      if loop_line =~ /\brange\s+([a-zA-Z_]\w*)\b/
        return $1
      end
      # 3. i < limit / i <= n / j < len(users)
      if loop_line =~ /(?:<|>|<=|>=)\s*([a-zA-Z_]\w*)\b/
        return $1
      end
      # 4. collection.each / collection.map
      if loop_line =~ /\b([a-zA-Z_]\w*)\.(?:each|each_key|each_value|each_with_index|map|map!|select|reject|filter|filter_map|flat_map|sort_by)\b/
        return $1
      end
      
      # Fallback: first non-ignored token
      tokens = loop_line.scan(/[a-zA-Z_]\w*/)
      ignored_tokens = %w[for while until do each times loop in range let mut var int i j k class module def end return]
      other_tokens = tokens - ignored_tokens
      other_tokens.first
    end

    def find_variable_definition_line(lines, var_name, loop_line_no, start_line)
      (loop_line_no - 1).downto(start_line) do |idx|
        line = lines[idx - 1].to_s
        if line =~ /\b(?:let(?:\s+mut)?\s+)?#{Regexp.escape(var_name)}\s*(?:=|\+=|-=|:=)\b/
          return idx
        end
        if idx == start_line
          if line =~ /\b#{Regexp.escape(var_name)}\b/
            return idx
          end
        end
      end
      nil
    end
  end
end
