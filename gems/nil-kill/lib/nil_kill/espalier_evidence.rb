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
      @parser = "auto"
      @targets = []
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
          "state_protocols=#{evidence.dig("summary", "state_protocols") || evidence.dig("summary", "ivar_protocols")}, " \
          "state_param_origins=#{evidence.dig("summary", "state_param_origins") || evidence.dig("summary", "ivar_param_origins")})"
      end

      evidence
    end

    def build
      return StaticEvidence.build(@targets, root: NilKill::ROOT) if tree_sitter_static?

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

        opts.on("--parser PARSER", "Evidence parser: auto, ruby, tree_sitter") do |parser_name|
          @parser = parser_name.to_s.tr("-", "_")
        end

        opts.on("--tree-sitter", "Use Tree-sitter static evidence for all supported source languages") do
          @parser = "tree_sitter"
        end
      end
      parser.parse!(@argv)
      @targets = @argv.dup
    end

    def tree_sitter_static?
      return true if %w[tree_sitter treesitter].include?(@parser)
      return false if %w[ruby].include?(@parser)
      return true if ENV.fetch("DECOMPLEX_PARSER", "").to_s.tr("-", "_") == "tree_sitter"
      return true if @targets.any? { |target| non_ruby_target?(target) }
      return true if ENV.key?("NIL_KILL_TARGETS") && NilKill.target_dirs.any? { |target| non_ruby_target?(target) }

      false
    end

    def non_ruby_target?(target)
      path = File.expand_path(target, NilKill::ROOT)
      exts = FactMine::Syntax.supported_exts(parser: "tree_sitter") - [".rb"]
      if File.directory?(path)
        Dir.glob(File.join(path, "**", "*")).any? { |file| File.file?(file) && exts.include?(File.extname(file).downcase) }
      else
        exts.include?(File.extname(path).downcase)
      end
    rescue StandardError
      false
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
