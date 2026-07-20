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
      shard_index = 0
      shard_count = 1
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: tools/incremental-testing/run.rb [--limit N] [--shard I/N] FILE_OR_DIR..."
        opts.on("--limit N", Integer, "maximum mutations per source") { |value| limit = value }
        opts.on("--shard I/N", String, "zero-based corpus shard") do |value|
          pieces = value.split("/", 2).map(&:to_i)
          raise OptionParser::InvalidArgument, value unless pieces.length == 2 && pieces[1] > 0 && pieces[0] >= 0 && pieces[0] < pieces[1]

          shard_index, shard_count = pieces
        end
      end
      paths = parser.parse(argv)
      raise OptionParser::MissingArgument, "FILE_OR_DIR" if paths.empty?

      sources = paths.flat_map do |path|
        File.directory?(path) ? Dir.glob(File.join(path, "**", "*.clear")) : [path]
      end.map { |path| File.expand_path(path) }.uniq.sort
      sources = sources.each_with_index.filter_map { |path, index| path if index % shard_count == shard_index }
      raise OptionParser::InvalidArgument, "shard contains no .clear sources" if sources.empty?

      results = sources.map { |path| DifferentialRunner.new(source_path: path, limit: limit).run }
      success = results.all?(&:success?)
      puts JSON.pretty_generate(
        success: success,
        runs: results.map do |result|
          {
            source_path: result.source_path,
            cases: result.cases.map do |item|
              {
                description: item.description,
                status: item.status,
                equal: item.equal,
                incremental_digest: item.incremental_digest,
                clean_digest: item.clean_digest,
              }
            end,
          }
        end,
      )
      success ? 0 : 1
    rescue OptionParser::ParseError => error
      warn error.message
      warn parser
      2
    end
  end
end
