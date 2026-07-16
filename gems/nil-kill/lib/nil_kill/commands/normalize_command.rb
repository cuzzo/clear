# typed: false
# frozen_string_literal: true

module NilKill
  module Commands
    class NormalizeCommand
      def initialize(argv)
        @argv = argv.dup
      end

      def run
        static_path = option("--static") || abort("normalize requires --static PATH")
        output = option("--output") || File.join(TMP_DIR, "evidence.json")
        analyze = !@argv.delete("--no-analyze")
        explicit_traces = options("--traces")
        static = FactMine::Syntax::TypeExpr.wrap_types!(JSON.parse(File.read(static_path)))
        root = File.expand_path(option("--root") || static["root"] || ROOT)
        traces = explicit_traces
        bundle = Runtime::Normalizer.new(root: root).normalize(static: static, trace_paths: traces, analyze: analyze)
        FileUtils.mkdir_p(File.dirname(output))
        File.write(output, JSON.pretty_generate(bundle))
        puts "wrote normalized evidence to #{NilKill.rel(output)}"
      end

      private

      def options(name)
        values = []
        while (idx = @argv.index(name))
          value = @argv[idx + 1] || abort("#{name} requires a value")
          values << value
          @argv.slice!(idx, 2)
        end
        @argv.select { |item| item.start_with?("#{name}=") }.each do |arg|
          values << arg.split("=", 2).last
          @argv.delete(arg)
        end
        values
      end

      def option(name)
        options(name).last
      end

    end
  end
end
