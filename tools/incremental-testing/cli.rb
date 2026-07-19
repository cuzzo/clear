# typed: strict
# frozen_string_literal: true

require "json"
require "optparse"
require "sorbet-runtime"

require_relative "differential_runner"

module IncrementalTesting
  class CLI
    extend T::Sig

    sig { params(argv: T::Array[String]).returns(Integer) }
    def self.run(argv)
      limit = 10
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: tools/incremental-testing/run.rb [--limit N] FILE.clear"
        opts.on("--limit N", Integer, "maximum literal mutations") { |value| limit = value }
      end
      paths = parser.parse(argv)
      raise OptionParser::MissingArgument, "FILE.clear" unless paths.one?

      result = DifferentialRunner.new(source_path: T.must(paths.first), limit: limit).run
      puts JSON.pretty_generate(
        source_path: result.source_path,
        success: result.success?,
        cases: result.cases.map do |item|
          {
            description: item.description,
            status: item.status,
            equal: item.equal,
            incremental_digest: item.incremental_digest,
            clean_digest: item.clean_digest,
          }
        end,
      )
      result.success? ? 0 : 1
    rescue OptionParser::ParseError => error
      warn error.message
      warn parser
      2
    end
  end
end
