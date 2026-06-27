# frozen_string_literal: true

require "json"

module Boobytrap
  # Read-only bridge to Decomplex's rust binary output. Boobytrap uses
  # this as a method-risk signal.
  module DecomplexRisk
    Score = Struct.new(:score, :findings, :detectors, keyword_init: true)

    DECOMPLEX_RUST_BINARY = ENV.fetch(
      "DECOMPLEX_RUST_BINARY",
      File.expand_path("../../../decomplex/target/release/decomplex-rust", __dir__)
    ).freeze

    module_function

    def score(files, root:)
      return {} if files.empty?

      data = if ENV["DECOMPLEX_FACTS_FILE"] && File.file?(ENV["DECOMPLEX_FACTS_FILE"])
               JSON.parse(File.read(ENV["DECOMPLEX_FACTS_FILE"]))
             else
               require "tempfile"
               tmp = Tempfile.new(["decomplex-facts", ".json"])
               tmp.close
               ok = system(DECOMPLEX_RUST_BINARY, "facts", "--output", tmp.path, *files)
               return {} unless ok
               JSON.parse(File.read(tmp.path))
             end
      detectors_data = data["detectors"] || {}
      
      method_data = Hash.new { |h, k| h[k] = { findings: [], detectors: [] } }
      
      detectors_data.each do |detector_name, payload|
        extract_sites(payload).each do |site|
          parts = site.split(":")
          next unless parts.size >= 3
          # Format: file:method:line
          # wait, what if path has colons? We pop from the end.
          line = parts.pop
          method_name = parts.pop
          file_path = parts.join(":")
          
          rel_file = relpath(file_path, root)
          key = [rel_file, method_name]
          
          method_data[key][:detectors] << detector_name
          # findings can just be the detector name for simplicity
          method_data[key][:findings] << { type: detector_name }
        end
      end
      
      method_data.transform_values do |data|
        Score.new(
          score: data[:detectors].uniq.size,
          findings: data[:findings],
          detectors: data[:detectors].uniq
        )
      end
    rescue StandardError => e
      warn "boobytrap: decomplex risk unavailable: #{e.message}" if ENV["BOOBYTRAP_DEBUG"]
      {}
    ensure
      tmp&.unlink if defined?(tmp) && tmp
    end

    def extract_sites(payload)
      sites = []
      if payload.is_a?(Array)
        payload.each do |item|
          if item.is_a?(Hash) && item["sites"]
            sites.concat(item["sites"])
          end
        end
      elsif payload.is_a?(Hash)
        payload.each_value do |v|
          sites.concat(extract_sites(v)) if v.is_a?(Array) || v.is_a?(Hash)
        end
      end
      sites
    end

    def state_branch_density(files, root:)
      return [] if files.empty?
      
      data = if ENV["DECOMPLEX_FACTS_FILE"] && File.file?(ENV["DECOMPLEX_FACTS_FILE"])
               JSON.parse(File.read(ENV["DECOMPLEX_FACTS_FILE"]))
             else
               require "tempfile"
               tmp = Tempfile.new(["decomplex-facts", ".json"])
               tmp.close
               ok = system(DECOMPLEX_RUST_BINARY, "facts", "--output", tmp.path, *files)
               return [] unless ok
               JSON.parse(File.read(tmp.path))
             end
      density_data = data.dig("detectors", "state_branch_density") || []
      
      density_data.map do |h|
        {
          file: relpath(h["file"], root),
          method: h["method"],
          score: h["score"],
          decisions: h["decisions"],
          at: h["at"],
          state_refs: h["state_refs"],
          predicate: h["predicate"]
        }
      end
    rescue StandardError => e
      warn "boobytrap: decomplex state-branch density unavailable: #{e.message}" if ENV["BOOBYTRAP_DEBUG"]
      []
    ensure
      tmp&.unlink if defined?(tmp) && tmp
    end

    def load_decomplex_syntax
      return true if defined?(Decomplex::Syntax)

      sibling = ::File.expand_path("../../../decomplex/lib/decomplex/syntax", __dir__)
      if ::File.file?("#{sibling}.rb")
        require sibling
        return true
      end

      require "decomplex/syntax"
      true
    rescue LoadError
      false
    end

    def load_decomplex_source_filter
      return true if defined?(Decomplex::SourceFilter)

      require "espalier/type_profile"
      true
    rescue LoadError
      sibling = ::File.expand_path("../../../espalier/lib/espalier/type_profile", __dir__)
      return false unless ::File.file?("#{sibling}.rb")

      require sibling
      true
    end

    def supported_exts
      %w[.rb .py .js .ts .go .rs .zig .c .cpp .cs .kt]
    end

    def supported_source?(file)
      source_file?(file, root: ::File.dirname(file))
    end


    def tree_sitter?
      load_decomplex_syntax
    end

    def source_file?(file, root:, parser: nil, exclude: [])
      selected = parser || (tree_sitter? ? "tree_sitter" : "rubyvm")
      if load_decomplex_source_filter
        Decomplex::SourceFilter.source_file?(file, parser: selected, root: root, exclude: exclude)
      else
        abs = ::File.expand_path(file.to_s.start_with?("/") ? file : ::File.join(root, file))
        ::File.file?(abs) && %w[.rb .py .js .ts .go .rs .zig .c .cpp .cs .kt].include?(::File.extname(abs).downcase)
      end
    end

    def tree_sitter_supported_source?(file)
      source_file?(file, root: ::File.dirname(file))
    end

    def excluded_path?(file, root:, exclude: [])
      if load_decomplex_source_filter
        Decomplex::SourceFilter.excluded_path?(file, root: root, exclude: exclude)
      else
        false
      end
    end

    def relpath(file, root)
      rootp = ::File.realpath(root).chomp("/") + "/"
      real = ::File.realpath(file)
      real.start_with?(rootp) ? real[rootp.length..] : file
    rescue Errno::ENOENT
      file.sub(%r{\A#{Regexp.escape(root.chomp('/'))}/}, "")
    end
  end
end

module Decomplex
  module Syntax
    class Document
      attr_reader :branch_arms, :language

      def initialize(branch_arms, language)
        @branch_arms = branch_arms
        @language = language
      end
    end

    class BranchArm
      attr_reader :decision_line, :decision_span, :kind, :line, :member, :span, :body

      def initialize(data)
        @decision_line = data["decision_line"]
        @decision_span = data["decision_span"]
        @kind = data["kind"]
        @line = data["line"]
        @member = data["member"]
        @span = data["span"]
        @body = data["body"]
      end
    end

    @cache = {}

    class << self
      attr_accessor :cache
    end

    module_function

    def parse(file, parser: "tree_sitter", language: nil)
      @cache ||= {}
      key = [::File.expand_path(file), parser, language]
      return @cache[key] if @cache.key?(key)

      lang = language || language_for(file)
      bin = ENV.fetch("FACT_MINE_RUST_BINARY", File.expand_path("../../../fact-mine/target/release/fact-mine-rust", __dir__))
      return Document.new([], lang) unless File.executable?(bin)

      require "open3"
      stdout, _, status = Open3.capture3(bin, "syntax-facts", "--language", lang, file)
      return Document.new([], lang) unless status.success?

      data = JSON.parse(stdout)
      doc_data = data["documents"]&.first || {}
      arms_data = doc_data["branch_arms"] || []
      arms = arms_data.map { |arm_data| BranchArm.new(arm_data) }
      Document.new(arms, lang)
    rescue StandardError
      Document.new([], lang || "generic")
    end

    def batch_parse(files)
      @cache ||= {}
      bin = ENV.fetch("FACT_MINE_RUST_BINARY", File.expand_path("../../../fact-mine/target/release/fact-mine-rust", __dir__))
      return unless File.executable?(bin)

      # Group files by their language to pass the correct --language parameter
      files_by_lang = files.group_by { |f| language_for(f) }

      files_by_lang.each do |lang, lang_files|
        lang_files.each_slice(1000) do |slice|
          cmd = [bin, "syntax-facts", "--language", lang] + slice
          stdout, stderr, status = Open3.capture3(*cmd)
          unless status.success?
            warn "boobytrap batch_parse failed for #{lang} slice of #{slice.size} files: #{stderr.to_s.strip}" if ENV["BOOBYTRAP_DEBUG"]
            next
          end

          begin
            data = JSON.parse(stdout)
            (data["documents"] || []).each do |doc_data|
              file = doc_data["file"]
              next unless file

              abs_file = ::File.expand_path(file)
              doc_lang = doc_data["language"] || lang
              arms_data = doc_data["branch_arms"] || []
              arms = arms_data.map { |arm_data| BranchArm.new(arm_data) }
              
              @cache[[abs_file, "tree_sitter", nil]] = Document.new(arms, doc_lang)
              @cache[[abs_file, "tree_sitter", doc_lang]] = @cache[[abs_file, "tree_sitter", nil]]
            end
          rescue StandardError
            # fallback to on-demand parsing if JSON parsing fails
          end
        end
      end
    end

    def language_for(file)
      case File.extname(file).downcase
      when ".rb" then "ruby"
      when ".py" then "python"
      when ".js" then "javascript"
      when ".ts" then "typescript"
      when ".go" then "go"
      when ".rs" then "rust"
      when ".zig" then "zig"
      when ".c" then "c"
      when ".cpp" then "cpp"
      when ".cs" then "csharp"
      when ".kt" then "kotlin"
      else "generic"
      end
    end
  end

  module Sarif
    module_function

    SCHEMA = "https://json.schemastore.org/sarif-2.1.0.json"

    def document(tool_name:, rules:, results:, information_uri: nil, properties: {})
      normalized_rules = unique_rules(rules)
      rule_index = normalized_rules.each_with_index.to_h { |rule, idx| [rule.fetch("id"), idx] }
      normalized_results = Array(results).map do |result|
        result = compact_hash(json_safe_value(result))
        rule_id = result["ruleId"]
        result["ruleIndex"] = rule_index[rule_id] if rule_id && rule_index.key?(rule_id)
        result
      end

      run = compact_hash(
        {
          "tool" => {
            "driver" => compact_hash(
              {
                "name" => tool_name,
                "informationUri" => information_uri,
                "rules" => normalized_rules
              }
            )
          },
          "results" => normalized_results,
          "properties" => json_safe_value(properties)
        }
      )
      run["results"] = normalized_results

      compact_hash(
        {
          "version" => "2.1.0",
          "$schema" => SCHEMA,
          "runs" => [run]
        }
      )
    end

    def json(**kwargs)
      JSON.pretty_generate(document(**kwargs))
    end

    def rule(id:, name: nil, short_description: nil, full_description: nil,
             default_level: "warning", help_uri: nil, properties: {})
      compact_hash(
        {
          "id" => id.to_s,
          "name" => name || id.to_s,
          "shortDescription" => { "text" => short_description || name || id.to_s },
          "fullDescription" => (full_description ? { "text" => full_description } : nil),
          "defaultConfiguration" => { "level" => default_level },
          "helpUri" => help_uri,
          "properties" => json_safe_value(properties)
        }
      )
    end

    def result(rule_id:, message:, path: nil, line: nil, start_column: nil,
               end_line: nil, end_column: nil, level: "warning",
               properties: {}, partial_fingerprints: nil)
      compact_hash(
        {
          "ruleId" => rule_id.to_s,
          "level" => level,
          "message" => { "text" => message.to_s },
          "locations" => sarif_locations(
            path: path,
            line: line,
            start_column: start_column,
            end_line: end_line,
            end_column: end_column
          ),
          "partialFingerprints" => json_safe_value(partial_fingerprints),
          "properties" => json_safe_value(properties)
        }
      )
    end

    def sarif_locations(path:, line:, start_column: nil, end_line: nil, end_column: nil)
      return [] if path.to_s.empty?

      [
        {
          "physicalLocation" => compact_hash(
            {
              "artifactLocation" => { "uri" => normalize_path(path) },
              "region" => compact_hash(
                {
                  "startLine" => positive_int(line, 1),
                  "startColumn" => positive_int(start_column),
                  "endLine" => positive_int(end_line),
                  "endColumn" => positive_int(end_column)
                }
              )
            }
          )
        }
      ]
    end

    def normalize_path(path)
      path.to_s.tr("\\", "/").sub(%r{\A\./}, "")
    end

    def slug(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
    end

    def json_safe_value(value)
      case value
      when Hash
        value.to_h { |key, child| [key.to_s, json_safe_value(child)] }
      when Array
        value.map { |child| json_safe_value(child) }
      when Symbol
        value.to_s
      else
        value
      end
    end

    def compact_hash(hash)
      hash.each_with_object({}) do |(key, value), out|
        next if value.nil?
        next if value.respond_to?(:empty?) && value.empty?

        out[key] = value
      end
    end

    def positive_int(value, fallback = nil)
      number = value.nil? ? fallback : value
      return nil if number.nil?

      number = number.to_i
      number.positive? ? number : fallback
    end

    def unique_rules(rules)
      seen = {}
      Array(rules).filter_map do |rule|
        rule = json_safe_value(rule)
        id = rule["id"].to_s
        next if id.empty? || seen[id]

        seen[id] = true
        compact_hash(rule)
      end
    end
  end
end


