# frozen_string_literal: true

module Boobytrap
  module CoverageProviders
    module SimpleCov
      module_function

      def handles_file?(path)
        return false unless ::File.extname(path).downcase == ".json"

        CoverageData.simplecov_resultset?(JSON.parse(::File.read(path)))
      rescue JSON::ParserError, Errno::ENOENT
        false
      end

      def load(path, root:)
        CoverageData.load_simplecov(
          path,
          JSON.parse(::File.read(path)),
          root: root
        )
      end
    end
  end
end

Boobytrap::CoverageProviders.register(Boobytrap::CoverageProviders::SimpleCov)
