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

      from_sections(Decomplex::Report.new(files).sections_data, root: root)
    rescue ArgumentError
      raise
    rescue StandardError => e
      warn "boobytrap: decomplex risk unavailable: #{e.message}" if ENV["BOOBYTRAP_DEBUG"]
      {}
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

    def relpath(file, root)
      rootp = ::File.realpath(root).chomp("/") + "/"
      real = ::File.realpath(file)
      real.start_with?(rootp) ? real[rootp.length..] : file
    rescue Errno::ENOENT
      file.sub(%r{\A#{Regexp.escape(root.chomp('/'))}/}, "")
    end
  end
end
