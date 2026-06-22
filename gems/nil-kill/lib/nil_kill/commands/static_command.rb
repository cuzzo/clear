# typed: false
# frozen_string_literal: true

module NilKill
  module Commands
    class StaticCommand
      def initialize(argv)
        @argv = argv.dup
      end

      def run
        output = option("--output") || File.join(TMP_DIR, "static.json")
        root = File.expand_path(option("--root") || ROOT)
        language = option("--language")
        vcs = option("--vcs")
        targets = @argv.reject { |arg| arg.start_with?("--") }
        evidence = StaticEvidence.build(targets.empty? ? nil : targets, root: root, language: language, vcs: vcs)
        FileUtils.mkdir_p(File.dirname(output))
        File.write(output, JSON.pretty_generate(evidence))
        puts "wrote static evidence to #{NilKill.rel(output)}"
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
