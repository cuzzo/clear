# frozen_string_literal: true

module SlopCop
  module CoverageProviders
    module NativeBranchJson
      CANDIDATES = %w[
        branch-coverage.json
        nil-kill-branch-coverage.json
      ].freeze

      module_function

      def resolve_directory(path, root:)
        CANDIDATES.map { |rel| ::File.join(path, rel) }
                  .find { |candidate| ::File.file?(candidate) }
      end

      def handles_file?(path)
        return false unless ::File.extname(path).downcase == ".json"

        CoverageData.nil_kill_branch_coverage?(JSON.parse(::File.read(path)))
      rescue JSON::ParserError, Errno::ENOENT
        false
      end

      def load(path, root:)
        CoverageData.load_nil_kill_branch_coverage(
          path,
          JSON.parse(::File.read(path)),
          root: root
        )
      end
    end
  end
end

SlopCop::CoverageProviders.register(SlopCop::CoverageProviders::NativeBranchJson)
