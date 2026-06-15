# typed: false
# frozen_string_literal: true

require "set"

module NilKill
  class StaticDiffAudit
    Finding = Struct.new(:kind, :path, :line, :message, :detail, :code, keyword_init: true) do
      def to_h
        {
          "kind" => kind,
          "path" => path,
          "line" => line,
          "message" => message,
          "detail" => detail,
          "code" => code,
        }
      end
    end

    TYPE_ERASURE_TOKEN = "T." + "untyped"
    EMPTY_TYPED_IVAR_FILES = Set.new.freeze

    def initialize(root:, added_lines:)
      @root = root
      @added_lines = added_lines
      @typed_ivar_files_by_name = nil
    end

    def findings
      SourceIndex.reset_global_shape_indexes
      src_ruby_paths.flat_map { |path| findings_for_path(path) }
    end

    private

    attr_reader :root, :added_lines

    def src_ruby_paths
      added_lines.keys.select { |path| path.start_with?("src/") && path.end_with?(".rb") && File.file?(File.join(root, path)) }.sort
    end

    def findings_for_path(path)
      lines = SourceIndex.source_lines(File.join(root, path))
      facts = lightweight_facts_for_path(path)
      audit_methods(path, facts.fetch(:methods), lines) +
        audit_hash_records(path, facts.fetch(:hash_shapes)) +
        audit_added_source_lines(path, lines)
    end

    def audit_methods(path, methods, lines)
      methods.filter_map do |method|
        next unless added_line?(path, method["line"])

        sig = signature_above(lines, method["line"])
        if !sig
          finding("missing_sig", path, method["line"],
            "added src method has no Sorbet signature",
            "#{method["class"]}##{method["method"]}".sub(/\A#/, ""),
            method["method"])
        elsif weak_type?(sig)
          finding("untyped_sig", path, method["line"],
            "added src method signature uses #{TYPE_ERASURE_TOKEN}",
            "#{method["class"]}##{method["method"]}".sub(/\A#/, ""),
            sig)
        end
      end
    end

    def audit_hash_records(path, hash_shapes)
      hash_shapes.filter_map do |shape|
        next unless added_line?(path, shape["line"])
        keys = Array(shape["keys"])
        next if keys.length < 2
        next if typed_lookup_hash?(shape["code"])
        next if typed_struct_value_hash?(shape["code"], keys)
        next if homogeneous_lookup_hash?(shape["code"])
        next if constant_key_lookup_hash?(keys)

        finding("hash_record_candidate", path, shape["line"],
          "added hash record literal may want a typed struct",
          "keys: #{keys.join(", ")}",
          shape["code"])
      end
    end

    def lightweight_facts_for_path(path)
      lines = SourceIndex.source_lines(File.join(root, path))
      line_numbers = added_lines.fetch(path)
      {
        methods: line_numbers.filter_map { |line_number| lightweight_method(path, line_number, lines[line_number - 1]) },
        hash_shapes: line_numbers.filter_map { |line_number| lightweight_hash_shape(path, line_number, lines) },
      }
    end

    def lightweight_method(path, line_number, line)
      match = line.to_s.strip.match(/\Adef\s+((?:self\.)?[^\s(;]+)/)
      return nil unless match

      raw_name = match[1].delete_suffix("(")
      class_method = raw_name.start_with?("self.")
      method_name = raw_name.delete_prefix("self.")
      {
        "path" => path,
        "line" => line_number,
        "end_line" => line_number,
        "class" => "",
        "method" => method_name,
        "kind" => class_method ? "class" : "instance",
      }
    end

    def lightweight_hash_shape(path, line_number, lines)
      first_line = lines[line_number - 1].to_s
      return nil if first_line.strip.start_with?("sig ")

      code = balanced_brace_code(lines, line_number - 1)
      return nil unless code

      keys = top_level_hash_keys(code)
      return nil if keys.size < 2

      { "path" => path, "line" => line_number, "keys" => keys, "code" => code }
    end

    def audit_added_source_lines(path, lines)
      added_lines.fetch(path).flat_map do |line_number|
        line = lines[line_number - 1].to_s
        [
          audit_ivar_write(path, line_number, line),
          audit_weak_collection_type(path, line_number, line),
        ].compact
      end
    end

    def audit_ivar_write(path, line_number, line)
      stripped = line.strip
      match = stripped.match(/\A(@[a-zA-Z_]\w*)\s*=(?!=)/)
      return nil unless match
      return nil if stripped.include?("T.let(")
      return nil if typed_ivar_initialized_before?(path, line_number, match[1])

      finding("untyped_ivar", path, line_number,
        "added instance variable assignment is not wrapped in T.let",
        "prefer a concrete T.let type at the first write",
        stripped)
    end

    def audit_weak_collection_type(path, line_number, line)
      stripped = line.strip
      return nil unless weak_type?(stripped)

      if stripped.include?("T::Hash[")
        finding("untyped_hash", path, line_number,
          "added hash type uses #{TYPE_ERASURE_TOKEN}",
          "prefer concrete key/value types or a struct for record-shaped data",
          stripped)
      elsif stripped.include?("T::Array[")
        finding("untyped_array", path, line_number,
          "added array type uses #{TYPE_ERASURE_TOKEN}",
          "prefer a concrete element type",
          stripped)
      end
    end

    def added_line?(path, line)
      added_lines.fetch(path, Set.new).include?(line.to_i)
    end

    def weak_type?(text)
      text.to_s.include?(TYPE_ERASURE_TOKEN)
    end

    def signature_above(lines, line)
      idx = line.to_i - 2
      idx -= 1 while idx >= 0 && lines[idx].to_s.strip.empty?
      return nil if idx.negative?

      if lines[idx].to_s.strip == "end"
        scan_start = [idx - 40, 0].max
        idx.downto(scan_start) do |sig_idx|
          return lines[sig_idx..idx].join("\n") if lines[sig_idx].to_s.strip.start_with?("sig do")
        end
        return nil
      end

      scan_start = [idx - 40, 0].max
      idx.downto(scan_start) do |sig_idx|
        stripped = lines[sig_idx].to_s.strip
        return lines[sig_idx..idx].join("\n") if stripped.start_with?("sig ") || stripped.start_with?("sig{")
        return nil unless stripped.start_with?("#") || stripped.empty? || stripped == "end"
      end
      nil
    end

    def typed_ivar_initialized_before?(path, line_number, ivar)
      lines = SourceIndex.source_lines(File.join(root, path))
      return true if lines.first(line_number - 1).any? { |prior| typed_ivar_line?(prior, ivar) }
      return true if in_initialize_copy?(lines, line_number) && lines.any? { |line| typed_ivar_line?(line, ivar) }

      typed_ivar_initialized_elsewhere?(path, ivar)
    end

    def in_initialize_copy?(lines, line_number)
      idx = line_number.to_i - 1
      idx.downto(0) do |line_idx|
        stripped = lines[line_idx].to_s.strip
        return true if stripped.match?(/\Adef\s+initialize_copy\b/)
        return false if stripped.start_with?("def ")
      end
      false
    end

    def typed_ivar_initialized_elsewhere?(path, ivar)
      return false unless path.start_with?("src/")

      typed_ivar_files_by_name.fetch(ivar, EMPTY_TYPED_IVAR_FILES).any? { |rel| rel != path }
    end

    def typed_ivar_files_by_name
      @typed_ivar_files_by_name ||= begin
        files_by_ivar = Hash.new { |hash, key| hash[key] = Set.new }
        Dir.glob(File.join(root, "src/**/*.rb")).sort.each do |candidate|
          rel = candidate.delete_prefix("#{root}/")
          SourceIndex.source_lines(candidate).each do |line|
            found_ivar = typed_ivar_from_line(line)
            files_by_ivar[found_ivar] << rel if found_ivar
          end
        end
        files_by_ivar
      end
    end

    def typed_ivar_line?(line, ivar)
      typed_ivar_from_line(line) == ivar
    end

    def typed_ivar_from_line(line)
      line.strip.match(/\A(@[a-zA-Z_]\w*)\s*=\s*T\.let\(/)&.[](1)
    end

    def balanced_brace_code(lines, start_index)
      return nil unless lines[start_index].to_s.include?("{")

      depth = 0
      quote = nil
      escape = false
      seen_open = false
      collected = []
      lines[start_index, 80].to_a.each do |line|
        collected << line
        line.each_char do |char|
          if quote
            if escape
              escape = false
            elsif char == "\\"
              escape = true
            elsif char == quote
              quote = nil
            end
            next
          end

          case char
          when "'", "\""
            quote = char
          when "#"
            break
          when "{"
            seen_open = true
            depth += 1
          when "}"
            depth -= 1 if seen_open
            return collected.join if seen_open && depth.zero?
          end
        end
      end
      nil
    end

    def top_level_hash_keys(code)
      state = { brace: 0, paren: 0, bracket: 0, quote: nil, escape: false, keys: [] }
      idx = 0
      while idx < code.length
        idx = scan_hash_key(code, idx, state)
        char = code[idx]
        break unless char

        if advance_string_state(char, state)
          idx += 1
          next
        end

        case char
        when "#"
          idx = code.index("\n", idx) || code.length
          next
        when "{"
          state[:brace] += 1
        when "}"
          state[:brace] -= 1 if state[:brace].positive?
        when "("
          state[:paren] += 1 if state[:brace].positive?
        when ")"
          state[:paren] -= 1 if state[:paren].positive?
        when "["
          state[:bracket] += 1 if state[:brace].positive?
        when "]"
          state[:bracket] -= 1 if state[:bracket].positive?
        end
        idx += 1
      end
      state.fetch(:keys)
    end

    def scan_hash_key(code, idx, state)
      return idx unless state[:brace] == 1 && state[:paren].zero? && state[:bracket].zero? && !state[:quote]

      if code[idx] =~ /[A-Za-z_]/
        finish = scan_identifier_end(code, idx)
        after = skip_space(code, finish)
        if code[after] == ":" && code[after + 1] != ":"
          state.fetch(:keys) << code[idx...finish]
          return after + 1
        elsif code[after, 2] == "=>"
          state.fetch(:keys) << code[idx...finish]
          return after + 2
        end
      elsif code[idx] == ":"
        finish = scan_identifier_end(code, idx + 1)
        after = skip_space(code, finish)
        if finish > idx + 1 && code[after, 2] == "=>"
          state.fetch(:keys) << code[(idx + 1)...finish]
          return after + 2
        end
      elsif ["'", "\""].include?(code[idx])
        finish, value = scan_string_literal(code, idx)
        after = skip_space(code, finish)
        if value && code[after, 2] == "=>"
          state.fetch(:keys) << value
          return after + 2
        end
      end

      idx
    end

    def advance_string_state(char, state)
      if state[:quote]
        if state[:escape]
          state[:escape] = false
        elsif char == "\\"
          state[:escape] = true
        elsif char == state[:quote]
          state[:quote] = nil
        end
        return true
      end

      if ["'", "\""].include?(char)
        state[:quote] = char
        return true
      end

      false
    end

    def scan_identifier_end(code, idx)
      idx += 1 while idx < code.length && code[idx] =~ /[A-Za-z0-9_]/
      idx
    end

    def skip_space(code, idx)
      idx += 1 while idx < code.length && code[idx] =~ /\s/
      idx
    end

    def scan_string_literal(code, idx)
      quote = code[idx]
      idx += 1
      start = idx
      escaped = false
      while idx < code.length
        char = code[idx]
        if escaped
          escaped = false
        elsif char == "\\"
          escaped = true
        elsif char == quote
          return [idx + 1, code[start...idx]]
        end
        idx += 1
      end
      [idx, nil]
    end

    def homogeneous_lookup_hash?(code)
      values = hash_literal_values(code)
      return false if values.length < 2

      kinds = values.map { |value| literal_kind(value) }
      kinds.all? && kinds.uniq.one?
    end

    def hash_literal_values(code)
      text = code.to_s
      rocket_values = text.scan(/=>\s*([^,\n}]+)/).flatten.map(&:strip)
      return rocket_values unless rocket_values.empty?

      text.scan(/:\s*([^,\n}]+)/).flatten.map(&:strip)
    end

    def constant_key_lookup_hash?(keys)
      keys.all? { |key| key.to_s.match?(/\A[A-Z]\w*\z/) }
    end

    def typed_lookup_hash?(code)
      text = code.to_s
      text.include?("T.let({") && text.include?("T::Hash[")
    end

    def typed_struct_value_hash?(code, keys)
      text = code.to_s
      keys.all? do |key|
        text.match?(/^\s*#{Regexp.escape(key.to_s)}:\s+[A-Z]\w*(?:::\w+)*\.new\(/)
      end
    end

    def literal_kind(value)
      case value
      when /\A"[^"]*"\z/, /\A'[^']*'\z/
        :string
      when /\A:[a-zA-Z_]\w*\z/
        :symbol
      when /\A-?\d+\z/
        :integer
      when /\A(?:true|false)\z/
        :boolean
      end
    end

    def finding(kind, path, line, message, detail, code)
      Finding.new(kind: kind, path: path, line: line.to_i, message: message, detail: detail.to_s, code: code.to_s)
    end
  end
end
