# frozen_string_literal: true

module RubyToClear
  module Analysis
    module DiagnosticInventory
      ANSI_PATTERN = /\e\[[\d;]*m/
      OWNERSHIP_TAG_PATTERN = /\A\[([A-Z][A-Z0-9_]+)\]\s+(.+)\z/
      COMPILER_TAG_PATTERN = /\A\[(?:Compiler|Parser) Error\]\s+\[([A-Z][A-Z0-9_]+)\]/

      module_function

      def extract(text, fallback_code:, stage:)
        clean = text.to_s.gsub(ANSI_PATTERN, "")
        location = extract_location(clean)
        source_excerpt = extract_source_excerpt(clean, location&.fetch("line", nil))
        diagnostics = clean.each_line.filter_map do |line|
          message = diagnostic_message(line.strip)
          next unless message

          code = classify_message(message, fallback_code)
          tag = ownership_tag(message)
          {
            "code" => code,
            "category" => category(message, code),
            "subcategory" => tag || subcategory(message, code),
            "fingerprint" => normalize(message),
            "message" => message[0, 1000],
            "stage" => stage,
            **(location || {}),
            **(source_excerpt ? { "source_excerpt" => source_excerpt } : {})
          }
        end

        if diagnostics.any? { |item| item["subcategory"]&.match?(/\A[A-Z][A-Z0-9_]+\z/) }
          diagnostics.reject! { |item| item["message"].include?("MIR ownership verification failed") }
        end
        diagnostics = [fallback_diagnostic(clean, fallback_code, stage, location, source_excerpt)] if diagnostics.empty?
        diagnostics.uniq { |item| [item["fingerprint"], item["line"], item["column"], item["subcategory"]] }
      end

      def aggregate(units, variant: "raw")
        rows = units.flat_map do |unit|
          diagnostics = variant == "raw" ? unit.fetch("diagnostics", []) : unit.dig("autofix", "diagnostics") || []
          diagnostics.map { |diagnostic| diagnostic.merge("root" => unit["source"]) }
        end
        clusters = rows.group_by do |item|
          [item["category"], item["subcategory"], cluster_fingerprint(item), item["provider"], item["line"]]
        end.map do |(_key, items)|
          roots = items.map { |item| item.fetch("root") }.uniq.sort
          provider = items.filter_map { |item| item["provider"] }.first
          direct_roots = provider ? items.select { |item| item["generated_relative"] == provider }.map { |item| item["root"] }.uniq : []
          first = items.first
          {
            "category" => first["category"],
            "subcategory" => first["subcategory"],
            "code" => first["code"],
            "fingerprint" => cluster_fingerprint(first),
            "provider" => provider,
            "line" => first["line"],
            "column" => first["column"],
            "source_excerpt" => first["source_excerpt"],
            "instances" => items.length,
            "affected_roots" => roots.length,
            "direct_roots" => direct_roots.length,
            "amplified_roots" => provider ? [roots.length - direct_roots.length, 0].max : 0,
            "sample_roots" => roots.first(8)
          }.compact
        end.sort_by { |item| [-item["affected_roots"], -item["instances"], item["category"], item["fingerprint"]] }

        categories = rows.group_by { |item| item["category"] }.map do |name, items|
          fingerprints = items.map { |item| [item["subcategory"], cluster_fingerprint(item), item["provider"], item["line"]] }.uniq
          {
            "category" => name,
            "instances" => items.length,
            "unique_clusters" => fingerprints.length,
            "affected_roots" => items.map { |item| item.fetch("root") }.uniq.length
          }
        end.sort_by { |item| [-item["affected_roots"], -item["instances"], item["category"]] }

        {
          "observed_instances" => rows.length,
          "unique_clusters" => clusters.length,
          "affected_roots" => rows.map { |item| item.fetch("root") }.uniq.length,
          "categories" => categories,
          "clusters" => clusters,
          "limitations" => "Counts include diagnostics emitted before each compiler process stopped; fail-fast errors can hide additional latent diagnostics."
        }
      end

      def normalize(message)
        normalized = message.dup
        normalized.gsub!(%r{(?<![A-Za-z0-9_.-])(?:/[^\s:]+)+}, "<path>")
        normalized.sub!(/\A[^\s:]+:\d+(?::\d+)?:in [`'][^`']+[`']:\s*/, "")
        normalized.sub!(/\A[^\s:]+:\d+:\d+:\s*/, "")
        normalized.gsub!(/0x[0-9a-f]+/i, "<hex>")
        normalized.gsub!(/\b\d+\b/, "<n>")
        normalized.gsub!(/\s+/, " ")
        normalized[0, 300]
      end

      def cluster_fingerprint(item)
        tag = item["subcategory"]
        message = item["message"].to_s
        if tag&.match?(/\A[A-Z][A-Z0-9_]+\z/) && (reason = message.split(" -- ", 2)[1])
          return "[#{tag}] #{normalize(reason)}"
        end

        item["fingerprint"]
      end

      def diagnostic_message(line)
        return nil if line.empty? || line.start_with?("from ", "[Warning]", "[Info]", "warning:")
        return line if line.match?(/\A\[(?:Compiler|Parser) Error\]/)
        return line if line.match?(OWNERSHIP_TAG_PATTERN)
        return line if line.start_with?("Error: Unsupported Ruby syntax:", "missing generated dependency:", "forbidden output marker")
        return line if line.match?(/MIR ownership verification failed|annotation stamp .+ \(RuntimeError\)/i)
        return line if line.match?(/(?:Lexer|Parser)\s*Error:/)
        return line if line.match?(/\A(?:[^\s:]+:\d+(?::\d+)?:\s*)?error:\s+/i)

        nil
      end

      def classify_message(message, fallback_code)
        return "T0" if message.start_with?("Error: Unsupported Ruby syntax:")
        return "C0" if message.start_with?("[Parser Error]") || message.match?(/(?:Lexer|Parser)\s*Error:/)
        return "C3" if message.match?(OWNERSHIP_TAG_PATTERN) || message.match?(/ownership|lifetime|borrow|transfer|cleanup|allocmark|movemark/i)
        return "Z0" if message.match?(/\A(?:[^\s:]+:\d+(?::\d+)?:\s*)?error:/i)

        fallback_code
      end

      def category(message, code)
        return "unsupported_ruby" if code == "T0"
        return "ruby_parse" if code == "R0"
        return "clear_syntax" if code == "C0"
        return "mutability" if code == "C5"
        return "effects_capabilities" if code == "C6"
        return "dependency" if message.start_with?("missing generated dependency:")
        return "ownership_lifetime" if code == "C3"
        return "type_system" if code == "C2"
        return "name_resolution" if code == "C1"
        return "backend" if code == "Z0"
        return "harness" if code == "H0"
        return "forbidden_output" if code == "T1"
        return "compiler_internal" if code == "C4"

        "other"
      end

      def subcategory(message, code)
        return message[/Unsupported node ([A-Za-z0-9_:]+)/, 1] || "unsupported_semantics" if code == "T0"
        return "undefined_function" if message.match?(/Undefined function/i)
        return "undefined_field" if message.match?(/(?:Undefined|unknown).+field/i)
        return "missing_dependency" if message.start_with?("missing generated dependency:")
        return "annotation_stamp" if message.include?("annotation stamp")
        return "parser" if code == "C0"
        return "zig" if code == "Z0"

        code.downcase
      end

      def ownership_tag(message)
        match = message.match(OWNERSHIP_TAG_PATTERN) || message.match(COMPILER_TAG_PATTERN)
        match && match[1]
      end

      def extract_location(text)
        match = text.match(/Location:\s*Line\s+(\d+),\s*Column\s+(\d+)/i)
        return { "line" => match[1].to_i, "column" => match[2].to_i } if match

        nil
      end

      def extract_source_excerpt(text, line_number)
        return nil unless line_number

        text.each_line do |line|
          match = line.match(/^\s*#{line_number}\s*\|\s?(.*?)\s*$/)
          return match[1].strip unless match.nil? || match[1].strip.empty?
        end
        nil
      end

      def fallback_diagnostic(text, code, stage, location, source_excerpt)
        message = text.each_line.map(&:strip).find { |line| !line.empty? && !line.start_with?("from ") } || "no diagnostic output"
        {
          "code" => code,
          "category" => category(message, code),
          "subcategory" => subcategory(message, code),
          "fingerprint" => normalize(message),
          "message" => message[0, 1000],
          "stage" => stage,
          **(location || {}),
          **(source_excerpt ? { "source_excerpt" => source_excerpt } : {})
        }
      end
    end
  end
end
