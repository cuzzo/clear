# typed: false
# frozen_string_literal: true

module NilKill
  module Commands
    class CollectRuntimeCommand
      def initialize(argv)
        @argv = argv.dup
      end

      def run
        language = option("--language") || option("--tracer") || abort("collect-runtime requires --language LANGUAGE")
        root = File.expand_path(option("--root") || Dir.pwd)
        output = File.expand_path(option("--output") || RUNTIME_DIR, ROOT)
        targets = options("--target")
        targets = ["src"] if targets.empty?
        append = !!@argv.delete("--append-runtime")
        provider = Languages.provider_for(language)

        provider.collect_runtime(argv: @argv, root: root, output: output, targets: targets, append: append)
        if provider.runtime_capabilities.fetch("runtime_scip_calls", false)
          source_files = targets.flat_map do |target|
            path = File.expand_path(target, root)
            File.directory?(path) ?
              Dir.glob(File.join(path, "**", "*")).select { |candidate| File.file?(candidate) } :
              [path]
          end
          emitted = Runtime::ScipEmitter.emit(
            root: root,
            runtime_dir: output,
            files: source_files
          )
          puts "wrote runtime SCIP index to #{emitted.fetch("index")}"
        end
      rescue Languages::UnsupportedRuntimeTracer => e
        abort "nil-kill: #{e.message}"
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
