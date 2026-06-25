# typed: false
# frozen_string_literal: true

module NilKill
  module Commands
    class AnalyzeCommand
      def initialize(argv)
        @argv = argv.dup
      end

      def run
        evidence_path = option("--evidence") || File.join(TMP_DIR, "evidence.json")
        output = option("--output") || evidence_path
        evidence = FactMine::Syntax::TypeExpr.wrap_types!(JSON.parse(File.read(evidence_path)))
        abort "analyze requires normalized schema_version 2 evidence" unless Schema::EvidenceBundle.v2?(evidence)
        evidence["actions"] = Analyzers::RuntimeEvidenceAnalyzer.new(evidence).analyze
        FileUtils.mkdir_p(File.dirname(output))
        File.write(output, JSON.pretty_generate(evidence))
        puts "wrote analyzed evidence to #{NilKill.rel(output)}"
      end

      private

      def option(name)
        if (idx = @argv.index(name))
          value = @argv[idx + 1] || abort("#{name} requires a value")
          @argv.slice!(idx, 2)
          value
        elsif (arg = @argv.find { |item| item.start_with?("#{name}=") })
          @argv.delete(arg)
          arg.split("=", 2).last
        end
      end
    end
  end
end
