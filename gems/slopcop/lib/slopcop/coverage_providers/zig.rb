# frozen_string_literal: true

module SlopCop
  module CoverageProviders
    module Zig
      module_function

      def language
        "zig"
      end

      def capability
        CoverageProviders::Capability.new(
          language: language,
          line_coverage: true,
          branch_coverage: false,
          native_branch_coverage: false,
          notes: "Zig currently uses kcov/DWARF line coverage. Exact branch-arm coverage needs a Zig instrumentation provider."
        )
      end

      def path_candidates(file, root:, source_roots:, summary:)
        return [] if file.to_s.start_with?("/")

        [::File.expand_path(::File.join("zig", file), root)]
      end
    end
  end
end

SlopCop::CoverageProviders.register_language(SlopCop::CoverageProviders::Zig)
