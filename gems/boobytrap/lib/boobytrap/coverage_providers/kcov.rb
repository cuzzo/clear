# frozen_string_literal: true

module Boobytrap
  module CoverageProviders
    module KCov
      DIRECTORY_CANDIDATES = %w[
        merged/kcov-merged/cobertura.xml
        kcov-merged/cobertura.xml
        cobertura.xml
        cov.xml
        merged/kcov-merged/codecov.json
        kcov-merged/codecov.json
        codecov.json
      ].freeze

      module_function

      def resolve_directory(path, root:)
        DIRECTORY_CANDIDATES.map { |rel| ::File.join(path, rel) }
                            .find { |candidate| ::File.file?(candidate) } ||
          Dir[::File.join(path, "**", "kcov-merged", "cobertura.xml")].sort.first ||
          Dir[::File.join(path, "**", "cobertura.xml")].sort.first ||
          Dir[::File.join(path, "**", "codecov.json")].sort.first
      end

      def handles_file?(path)
        case ::File.extname(path).downcase
        when ".xml"
          true
        when ".json"
          CoverageData.kcov_codecov?(JSON.parse(::File.read(path)))
        else
          false
        end
      rescue JSON::ParserError, Errno::ENOENT
        false
      end

      def load(path, root:)
        case ::File.extname(path).downcase
        when ".xml"
          CoverageData.load_cobertura(path, root: root)
        when ".json"
          CoverageData.load_kcov_codecov(
            path,
            JSON.parse(::File.read(path)),
            root: root
          )
        else
          CoverageData.empty_dataset(path)
        end
      end
    end
  end
end

Boobytrap::CoverageProviders.register(Boobytrap::CoverageProviders::KCov)
