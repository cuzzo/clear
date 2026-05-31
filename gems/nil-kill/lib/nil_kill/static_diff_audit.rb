# typed: false
# frozen_string_literal: true

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

    def initialize(root:, added_lines:)
      @root = root
      @added_lines = added_lines
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
      index = SourceIndex.new(File.join(root, path))
      lines = SourceIndex.source_lines(File.join(root, path))
      audit_methods(path, index, lines) + audit_hash_records(path, index) + audit_added_source_lines(path, lines)
    end

    def audit_methods(path, index, lines)
      index.methods.filter_map do |method|
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

    def audit_hash_records(path, index)
      index.hash_shapes.filter_map do |shape|
        next unless added_line?(path, shape["line"])
        keys = Array(shape["keys"])
        next if keys.length < 2

        finding("hash_record_candidate", path, shape["line"],
          "added hash record literal may want a typed struct",
          "keys: #{keys.join(", ")}",
          shape["code"])
      end
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
      return nil unless stripped.match?(/\A@[a-zA-Z_]\w*\s*=(?!=)/)
      return nil if stripped.include?("T.let(")

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
        scan_start = [idx - 12, 0].max
        idx.downto(scan_start) do |sig_idx|
          return lines[sig_idx..idx].join("\n") if lines[sig_idx].to_s.strip.start_with?("sig do")
        end
        return nil
      end

      scan_start = [idx - 8, 0].max
      idx.downto(scan_start) do |sig_idx|
        stripped = lines[sig_idx].to_s.strip
        return lines[sig_idx..idx].join("\n") if stripped.start_with?("sig ") || stripped.start_with?("sig{")
        return nil unless stripped.start_with?("#") || stripped.empty? || stripped == "end"
      end
      nil
    end

    def finding(kind, path, line, message, detail, code)
      Finding.new(kind: kind, path: path, line: line.to_i, message: message, detail: detail.to_s, code: code.to_s)
    end
  end
end
