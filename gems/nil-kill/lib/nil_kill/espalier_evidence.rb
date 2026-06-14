# typed: false
# frozen_string_literal: true

require "optparse"

module NilKill
  class EspalierEvidence
    DEFAULT_OUTPUT = File.join(TMP_DIR, "espalier-evidence.json")

    def initialize(argv)
      @argv = argv.dup
      @output = DEFAULT_OUTPUT
      @stdout = false
    end

    def run
      parse_options!
      evidence = build
      body = JSON.pretty_generate(evidence)

      if @stdout
        puts body
      else
        FileUtils.mkdir_p(File.dirname(@output))
        File.write(@output, body)
        puts "nil-kill: wrote Espalier static evidence to #{NilKill.rel(@output)} " \
          "(methods=#{evidence.dig("summary", "methods")}, " \
          "ivar_protocols=#{evidence.dig("summary", "ivar_protocols")}, " \
          "ivar_param_origins=#{evidence.dig("summary", "ivar_param_origins")})"
      end

      evidence
    end

    def build
      infer = Infer.new(["--no-sorbet"])
      infer.index_sources
      full = infer.store.to_h
      facts = full.fetch("facts")
      methods = compact_methods(full.fetch("methods"))
      ivar_protocols = compact_fact_map(facts.fetch("ivar_protocols", {}))
      ivar_param_origins = compact_fact_map(facts.fetch("ivar_param_origins", {}))

      {
        "version" => 1,
        "kind" => "espalier_static_evidence",
        "generated_at" => Time.now.utc.iso8601,
        "target_dirs" => NilKill.target_dirs.map { |dir| NilKill.rel(dir) },
        "target_exclude_dirs" => NilKill.target_exclude_dirs.map { |dir| NilKill.rel(dir) },
        "runtime_fields" => false,
        "methods" => methods,
        "facts" => {
          "ivar_runtime" => [],
          "ivar_protocols" => ivar_protocols,
          "ivar_param_origins" => ivar_param_origins,
        },
        "summary" => {
          "methods" => methods.size,
          "signatures" => methods.count { |method| !method.dig("source", "sig").to_s.empty? },
          "ivar_protocols" => ivar_protocols.size,
          "ivar_param_origins" => ivar_param_origins.size,
        },
      }
    end

    private

    def parse_options!
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: bundle exec tools/nil-kill espalier-evidence [--output FILE] [--stdout]"

        opts.on("-o", "--output FILE", "Write static Espalier evidence to FILE") do |path|
          @output = path
        end

        opts.on("--stdout", "Print evidence JSON to stdout instead of writing a file") do
          @stdout = true
        end
      end
      parser.parse!(@argv)
      abort "unexpected arguments: #{@argv.join(" ")}" unless @argv.empty?
    end

    def compact_methods(methods)
      Array(methods).filter_map do |method|
        source = method["source"]
        sig = source && source["sig"].to_s
        next if sig.empty?

        {
          "key" => method["key"],
          "source" => { "sig" => sig },
        }
      end.sort_by { |method| Array(method["key"]).map(&:to_s) }
    end

    def compact_fact_map(map)
      Hash[Hash(map).sort.map do |key, values|
        [key, Array(values).map(&:to_s).sort.uniq]
      end]
    end
  end
end
