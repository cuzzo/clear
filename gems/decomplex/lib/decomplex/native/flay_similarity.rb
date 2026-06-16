# frozen_string_literal: true

require "json"
require_relative "command"

module Decomplex
  module Native
    module FlaySimilarity
      module_function

      def scan(files, mass:, fuzzy:)
        paths = Array(files).map(&:to_s)
        validate_ruby_files!(paths)
        JSON.parse(
          Command.run(
            "flay-similarity",
            "--language", "ruby",
            "--mass", mass.to_i.to_s,
            "--fuzzy", fuzzy.to_i.to_s,
            *paths
          ),
          symbolize_names: true
        ).map { |finding| normalize_finding(finding) }
      end

      private_class_method def self.validate_ruby_files!(paths)
        bad = paths.reject { |path| File.extname(path) == ".rb" }
        return if bad.empty?

        raise ArgumentError, "--engine=rust currently supports Ruby files only: #{bad.join(', ')}"
      end

      private_class_method def self.normalize_finding(finding)
        finding.merge(
          clone_type: finding.fetch(:clone_type).to_sym,
          spans: finding.fetch(:spans).transform_values { |span| Array(span).map(&:to_i) }
        )
      end
    end
  end
end
