#!/usr/bin/env ruby
# typed: strict
# frozen_string_literal: true

require "json"
require "fileutils"
require "optparse"
require "sorbet-runtime"

module Lineage
  module MutantConverters
    module RustMutants
      extend T::Sig

      class Options < T::Struct
        const :input, String
        const :output, String
      end

      sig { params(argv: T::Array[String]).returns(Options) }
      def self.parse_options(argv)
        input = T.let(nil, T.nilable(String))
        output = T.let(nil, T.nilable(String))
        OptionParser.new do |o|
          o.banner = "Usage: ruby gems/lineage/tools/mutant-converters/rust_mutant.rb --input PATH --output PATH"
          o.on("--input PATH") { |v| input = v }
          o.on("--output PATH") { |v| output = v }
          o.on("-h", "--help") { puts o; exit 0 }
        end.parse!(argv)

        raise "--input is required" unless input
        raise "--output is required" unless output

        Options.new(input: T.must(input), output: T.must(output))
      end

      PACKAGE_PATHS = T.let({
        "sql-cov" => "gems/sql-cov",
        "lineage" => "gems/lineage",
        "fact-mine-rust" => "gems/fact-mine",
        "decomplex-rust" => "gems/decomplex"
      }.freeze, T::Hash[String, String])

      sig { params(input_path: String, output_path: String).void }
      def self.convert_file(input_path, output_path)
        outcomes_json_path = if File.directory?(input_path)
          File.join(input_path, "outcomes.json")
        else
          input_path
        end

        raise "input file #{outcomes_json_path} does not exist" unless File.exist?(outcomes_json_path)

        data = JSON.parse(File.read(outcomes_json_path))
        raise "expected outcomes.json structure" unless data.is_a?(Hash) && data["outcomes"].is_a?(Array)

        outcomes = T.cast(data["outcomes"], T::Array[T::Hash[String, T.untyped]])

        groups = {}

        outcomes.each do |outcome|
          scenario = outcome["scenario"]
          next unless scenario.is_a?(Hash)

          mutant = scenario["Mutant"]
          next unless mutant.is_a?(Hash)

          file_rel = mutant["file"]
          func = mutant["function"]
          next unless func.is_a?(Hash)

          method = func["function_name"]
          pkg = mutant["package"]

          next unless file_rel.is_a?(String) && method.is_a?(String) && pkg.is_a?(String)

          pkg_path = PACKAGE_PATHS[pkg] || "gems/#{pkg}"
          file_path = File.join(pkg_path, file_rel)

          key = [file_path, method]
          groups[key] ||= { killed: 0, alive: 0, mutations: 0 }

          summary = outcome["summary"]
          groups[key][:mutations] += 1

          if summary == "CaughtMutant" || summary == "Timeout"
            groups[key][:killed] += 1
          elsif summary == "MissedMutant"
            groups[key][:alive] += 1
          end
        end

        subjects = []
        groups.each do |(file, method), counts|
          killed = counts[:killed]
          alive = counts[:alive]
          mutations = counts[:mutations]

          total_evaluated = killed + alive
          kill_rate = total_evaluated > 0 ? (killed.to_f / total_evaluated * 100.0).round(2) : 0.0

          subjects << {
            "file" => file,
            "method" => method,
            "kill_rate" => kill_rate,
            "mutations" => mutations,
            "killed" => killed,
            "alive" => alive,
            "mutation_kind" => "stochastic"
          }
        end

        result = {
          "schema" => "mutant-facts/v1",
          "source" => "gems/lineage/tools/mutant-converters/rust_mutant.rb",
          "language" => "rust",
          "mutation_kind" => "stochastic",
          "subjects" => subjects
        }

        FileUtils.mkdir_p(File.dirname(output_path))
        File.write(output_path, JSON.pretty_generate(result) + "\n")
      end

      sig { params(argv: T::Array[String]).returns(Integer) }
      def self.main(argv)
        opts = parse_options(argv)
        convert_file(opts.input, opts.output)
        0
      rescue StandardError => e
        warn "rust-mutants converter failed: #{e.message}"
        1
      end
    end
  end
end

exit Lineage::MutantConverters::RustMutants.main(ARGV) if $PROGRAM_NAME == __FILE__
