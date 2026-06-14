# frozen_string_literal: true

module Boobytrap
  # Read-only bridge to Decomplex's own detector rollup. Boobytrap uses
  # this as a method-risk signal instead of reimplementing a local
  # complexity proxy.
  module DecomplexRisk
    Score = Struct.new(:score, :findings, :detectors, keyword_init: true)

    module_function

    def score(files, root:)
      return {} if files.empty?
      return {} unless load_decomplex

      sections = with_tree_sitter do
        Decomplex::Report.new(files).sections_data
      end
      from_sections(sections, root: root)
    rescue ArgumentError
      raise
    rescue LoadError, SyntaxError, StandardError => e
      warn "boobytrap: decomplex risk unavailable: #{e.message}" if ENV["BOOBYTRAP_DEBUG"]
      {}
    end

    def state_branch_density(files, root:)
      return [] if files.empty?
      return [] unless load_decomplex

      findings = with_tree_sitter do
        Decomplex::StateBranchDensity.scan(files).findings
      end
      findings.map do |h|
        h.merge(file: relpath(h[:file], root))
      end
    rescue LoadError, SyntaxError, StandardError => e
      warn "boobytrap: decomplex state-branch density unavailable: #{e.message}" if ENV["BOOBYTRAP_DEBUG"]
      []
    end

    def from_sections(sections, root:)
      Decomplex::Convergence.rollup(sections, min_detectors: 1).to_h do |unit|
        key = [relpath(unit[:file], root), unit[:method]]
        value = Score.new(
          score: unit[:score],
          findings: unit[:findings],
          detectors: unit[:detectors]
        )
        [key, value]
      end
    end

    def load_decomplex
      return true if defined?(Decomplex::Report) && defined?(Decomplex::Convergence)

      require "decomplex/report"
      true
    rescue LoadError
      sibling = ::File.expand_path("../../../decomplex/lib/decomplex/report", __dir__)
      return false unless ::File.file?("#{sibling}.rb")

      require sibling
      true
    end

    def load_decomplex_syntax
      return true if defined?(Decomplex::Syntax)

      require "decomplex/syntax"
      true
    rescue LoadError
      sibling = ::File.expand_path("../../../decomplex/lib/decomplex/syntax", __dir__)
      return false unless ::File.file?("#{sibling}.rb")

      require sibling
      true
    end

    def load_decomplex_source_filter
      return true if defined?(Decomplex::SourceFilter)

      require "decomplex/source_filter"
      true
    rescue LoadError
      sibling = ::File.expand_path("../../../decomplex/lib/decomplex/source_filter", __dir__)
      return false unless ::File.file?("#{sibling}.rb")

      require sibling
      true
    end

    def tree_sitter?
      ENV.fetch("DECOMPLEX_PARSER", "tree_sitter").to_s.tr("-", "_") == "tree_sitter"
    end

    def supported_exts(parser: nil)
      if load_decomplex_syntax
        selected = parser || "tree_sitter"
        Decomplex::Syntax.supported_exts(parser: selected)
      else
        [".rb"]
      end
    end

    def supported_source?(file, parser: nil)
      supported_exts(parser: parser).include?(::File.extname(file).downcase)
    end

    def tree_sitter_supported_source?(file)
      supported_source?(file, parser: "tree_sitter")
    end

    def source_file?(file, root:, parser: nil, exclude: [])
      selected = parser || "tree_sitter"
      if load_decomplex_source_filter
        Decomplex::SourceFilter.source_file?(file, parser: selected, root: root, exclude: exclude)
      else
        abs = ::File.expand_path(file.to_s.start_with?("/") ? file : ::File.join(root, file))
        ::File.file?(abs) && supported_source?(abs, parser: selected)
      end
    end

    def excluded_path?(file, root:, exclude: [])
      load_decomplex_source_filter &&
        Decomplex::SourceFilter.excluded_path?(file, root: root, exclude: exclude)
    end

    def with_tree_sitter
      previous = ENV["DECOMPLEX_PARSER"]
      ENV["DECOMPLEX_PARSER"] = "tree_sitter"
      yield
    ensure
      previous.nil? ? ENV.delete("DECOMPLEX_PARSER") : ENV["DECOMPLEX_PARSER"] = previous
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
