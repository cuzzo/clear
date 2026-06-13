# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class Python < Provider
        def language
          "python"
        end

        def aliases
          ["py"]
        end

        def display_name
          "Python"
        end

        def extensions
          [".py"]
        end

        def runtime_tracing?
          true
        end

        def runtime_trace_events
          %w[
            process_start
            process_end
            method_call
            method_return
            method_raise
            param_observed
            field_observed
            collection_observed
            hash_shape_observed
            call_edge
            coverage
          ]
        end

        def runtime_capabilities
          super.merge(
            "method_calls" => true,
            "params" => true,
            "returns" => true,
            "exceptions" => true,
            "fields" => true,
            "collections" => true,
            "hash_shapes" => true,
            "call_edges" => true,
            "line_coverage" => true
          )
        end

        def notes
          ["autofix is intentionally unsupported; Python actions remain report-only"]
        end

        def collect_runtime(argv:, root:, output:, targets:, append: false)
          split = argv.index("--")
          abort "usage: nil-kill collect-runtime --language python [--root DIR] [--target PATH] [--output DIR] -- <python test command...>" unless split

          command = argv[(split + 1)..]
          abort "collect-runtime --language python requires a command after --" if command.empty?

          FileUtils.rm_rf(output) unless append
          FileUtils.mkdir_p(output)
          env = runtime_env(root: root, output: output, targets: targets)
          ok = system(env, *command, chdir: root)
          exit($?&.exitstatus || 1) unless ok
          puts "wrote Python trace events to #{output}"
        end

        def canonical_state_field(field, receiver: nil)
          text = field.to_s
          return text if text.empty? || text.start_with?("@")

          receiver_text = receiver.to_s
          if self_receiver_names.include?(receiver_text) ||
              self_receiver_names.any? { |name| receiver_text.start_with?("#{name}.") }
            "@#{text}"
          else
            text
          end
        end

        private

        def runtime_env(root:, output:, targets:)
          lib_dir = File.expand_path("../../..", __dir__)
          pythonpath = [lib_dir, ENV["PYTHONPATH"]].compact.reject(&:empty?).join(File::PATH_SEPARATOR)
          abs_targets = targets.map { |target| File.expand_path(target, root) }.join(File::PATH_SEPARATOR)
          ENV.to_h.merge(
            "NIL_KILL_PY_TRACE" => "1",
            "NIL_KILL_PY_TRACE_OUT" => output,
            "NIL_KILL_TRACE_ROOT" => root,
            "NIL_KILL_TARGETS" => abs_targets,
            "PYTHONPATH" => pythonpath
          )
        end

        def self_receiver_names
          %w[self cls]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Python.new)
