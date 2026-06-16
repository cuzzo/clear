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
          %w[.py .pyi]
        end

        def type_systems
          ["python-typing"]
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
          ["source rewriting is owned by auto-type providers; Python analysis remains report-only here"]
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

        def declared_state_field(field)
          text = field.to_s
          return text if text.empty? || text.start_with?("@")

          "@#{text}"
        end

        def extra_state_declarations(document:, facts:, rel_path:)
          python_state_assignments(document, facts).filter_map do |assignment|
            next if assignment[:type].to_s.empty?

            Decomplex::Syntax::StateDeclaration.new(
              field: assignment[:field],
              owner: assignment[:owner],
              type: assignment[:type],
              file: document.file,
              line: assignment[:line],
              span: assignment[:span]
            )
          end
        end

        def extra_state_param_origins(document:, facts:, rel_path:)
          python_state_assignments(document, facts).filter_map do |assignment|
            param = assignment[:param].to_s
            next if param.empty? || self_receiver_names.include?(param)

            Decomplex::Syntax::StateParamOrigin.new(
              field: assignment[:field],
              receiver: assignment[:receiver],
              owner: assignment[:owner],
              param: param,
              file: document.file,
              function: assignment[:function],
              line: assignment[:line],
              span: assignment[:span]
            )
          end
        end

        def type_definitions(document:, facts:, rel_path:, methods:, state_declarations:)
          definitions = []
          Array(facts[:function_defs]).each do |fn|
            typed = python_signature_types(fn.signature)
            next if typed[:params].empty? && typed[:return_type].to_s.empty?

            definitions << {
              "id" => ["python", rel_path, fn.owner, "method_signature", fn.name, fn.line, "python-typing"].map(&:to_s).join("\u0000"),
              "language" => "python",
              "type_system" => "python-typing",
              "kind" => "method_signature",
              "path" => rel_path,
              "owner" => fn.owner.to_s,
              "name" => fn.name.to_s,
              "line" => fn.line,
              "signature" => fn.signature.to_s,
              "return_type" => typed[:return_type],
              "params" => typed[:params],
            }
          end

          state_declarations.each do |state|
            type = state.type.to_s
            next if type.empty?

            field = declared_state_field(state.field)
            definitions << {
              "id" => ["python", rel_path, state.owner, "state_field", field, state.line, "python-typing"].map(&:to_s).join("\u0000"),
              "language" => "python",
              "type_system" => "python-typing",
              "kind" => "state_field",
              "path" => rel_path,
              "owner" => state.owner.to_s,
              "name" => field,
              "line" => state.line,
              "declared_type" => type,
            }
          end

          definitions.concat(python_stub_type_definitions(document, rel_path))
          definitions.concat(python_type_alias_definitions(document, rel_path))
          definitions
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

        def python_signature_types(signature)
          source = signature.to_s.strip
          match = source.match(/\A(?:async\s+)?def\s+\w+\s*\((.*)\)\s*(?:->\s*([^:]+))?:/)
          return { params: [], return_type: nil } unless match

          params = NilKill.split_top_level(match[1]).filter_map do |entry|
            entry = entry.sub(/\A\*\*?/, "").strip
            name, rest = entry.split(/:\s*/, 2)
            next unless name && rest
            name = name.sub(/=.*/, "").strip
            next if self_receiver_names.include?(name)

            type = rest.sub(/=.*/, "").strip
            next if type.empty?

            { "name" => name, "type" => type }
          end

          { params: params, return_type: match[2]&.strip }
        end

        def python_state_assignments(document, facts)
          Array(facts[:function_defs]).flat_map do |fn|
            next [] unless fn.kind.to_s == "method"

            lines_for_function(document, fn).filter_map do |line, line_no|
              match = line.match(/\b(self|cls)\.([A-Za-z_]\w*)\s*(?::\s*([^=]+?))?\s*=\s*([A-Za-z_]\w*)\b/)
              next unless match

              {
                receiver: match[1],
                field: match[2],
                type: match[3]&.strip,
                param: match[4],
                owner: fn.owner.to_s,
                function: fn.name.to_s,
                line: line_no,
                span: [line_no, 0, line_no, line.length],
              }
            end
          end
        end

        def lines_for_function(document, function_def)
          start_line = function_def.line.to_i
          end_line = Array(function_def.span)[2].to_i
          end_line = start_line if end_line < start_line
          document.lines[(start_line - 1)..(end_line - 1)].to_a.each_with_index.map do |line, idx|
            [line, start_line + idx]
          end
        end

        def python_stub_type_definitions(document, rel_path)
          return [] unless File.extname(document.file).downcase == ".pyi"

          definitions = []
          owner = nil
          owner_indent = nil
          document.lines.each_with_index do |line, idx|
            line_no = idx + 1
            stripped = line.strip
            next if stripped.empty? || stripped.start_with?("#")

            indent = line[/\A\s*/].to_s.length
            if owner && indent <= owner_indent.to_i && !stripped.start_with?("def ")
              owner = nil
              owner_indent = nil
            end

            if (match = stripped.match(/\Aclass\s+([A-Za-z_]\w*)\b/))
              owner = match[1]
              owner_indent = indent
              next
            end

            if (match = stripped.match(/\A(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\((.*)\)\s*(?:->\s*([^:]+))?:/))
              name = match[1]
              signature = stripped.sub(/\s*\.\.\.\s*\z/, "")
              typed = python_signature_types(signature)
              definitions << {
                "id" => ["python", rel_path, owner, "method_signature", name, line_no, "python-typing-stub"].map(&:to_s).join("\u0000"),
                "language" => "python",
                "type_system" => "python-typing",
                "kind" => "method_signature",
                "path" => rel_path,
                "owner" => owner.to_s,
                "name" => name,
                "line" => line_no,
                "signature" => signature,
                "return_type" => typed[:return_type],
                "params" => typed[:params],
              }
            elsif owner && (match = stripped.match(/\A([A-Za-z_]\w*)\s*:\s*([^=#]+)(?:\s*=.*)?\z/))
              name = match[1]
              definitions << {
                "id" => ["python", rel_path, owner, "state_field", name, line_no, "python-typing-stub"].map(&:to_s).join("\u0000"),
                "language" => "python",
                "type_system" => "python-typing",
                "kind" => "state_field",
                "path" => rel_path,
                "owner" => owner.to_s,
                "name" => name,
                "line" => line_no,
                "declared_type" => match[2].strip,
              }
            end
          end
          definitions
        end

        def python_type_alias_definitions(document, rel_path)
          document.lines.each_with_index.filter_map do |line, idx|
            stripped = line.strip
            next if stripped.empty? || stripped.start_with?("#")

            name = nil
            target = nil
            if (match = stripped.match(/\A([A-Z]\w*)\s*:\s*TypeAlias\s*=\s*(.+?)\s*(?:#.*)?\z/))
              name = match[1]
              target = match[2].strip
            elsif (match = stripped.match(/\Atype\s+([A-Z]\w*)\s*=\s*(.+?)\s*(?:#.*)?\z/))
              name = match[1]
              target = match[2].strip
            end
            next unless name && target

            {
              "id" => ["python", rel_path, "", "type_alias", name, idx + 1, "python-typing"].map(&:to_s).join("\u0000"),
              "language" => "python",
              "type_system" => "python-typing",
              "kind" => "type_alias",
              "path" => rel_path,
              "owner" => "",
              "name" => name,
              "line" => idx + 1,
              "target" => target,
              "source" => "TypeAlias",
            }
          end
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Python.new)
