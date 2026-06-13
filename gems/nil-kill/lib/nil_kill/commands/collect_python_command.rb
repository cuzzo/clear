# typed: false
# frozen_string_literal: true

module NilKill
  module Commands
    class CollectPythonCommand
      def initialize(argv)
        @argv = argv.dup
      end

      def run
        root = File.expand_path(option("--root") || Dir.pwd)
        output = File.expand_path(option("--output") || RUNTIME_DIR, ROOT)
        targets = options("--target")
        targets = ["src"] if targets.empty?
        append = @argv.delete("--append-runtime")
        split = @argv.index("--")
        abort "usage: nil-kill collect-python [--root DIR] [--target PATH] [--output DIR] -- <python test command...>" unless split
        command = @argv[(split + 1)..]
        abort "collect-python requires a command after --" if command.empty?

        FileUtils.rm_rf(output) unless append
        FileUtils.mkdir_p(output)
        lib_dir = File.expand_path("../..", __dir__)
        pythonpath = [lib_dir, ENV["PYTHONPATH"]].compact.reject(&:empty?).join(File::PATH_SEPARATOR)
        abs_targets = targets.map { |target| File.expand_path(target, root) }.join(File::PATH_SEPARATOR)
        env = ENV.to_h.merge(
          "NIL_KILL_PY_TRACE" => "1",
          "NIL_KILL_PY_TRACE_OUT" => output,
          "NIL_KILL_TRACE_ROOT" => root,
          "NIL_KILL_TARGETS" => abs_targets,
          "PYTHONPATH" => pythonpath
        )
        ok = system(env, *command, chdir: root)
        exit($?&.exitstatus || 1) unless ok
        puts "wrote Python trace events to #{output}"
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
