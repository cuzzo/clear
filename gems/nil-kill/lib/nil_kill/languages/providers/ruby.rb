# typed: false
# frozen_string_literal: true

require_relative "ruby/sorbet"

module NilKill
  module Languages
    module Providers
      class Ruby < Provider
        def language
          "ruby"
        end

        def extensions
          [".rb"]
        end

        def static_parser
          "tree_sitter"
        end

        def type_systems
          sorbet.type_systems
        end

        def runtime_tracing?
          true
        end

        def runtime_trace_events
          %w[
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
          ["runtime collection uses the existing nil-kill collect command and Ruby source instrumentation"]
        end

        def method_source(function_def)
          sorbet.method_source(function_def)
        end

        def static_method_signature(function_def)
          sorbet.signature_for(function_def)
        end

        def type_definitions(document:, facts:, rel_path:, methods:, state_declarations:)
          definitions = sorbet.type_definitions(
            rel_path: rel_path,
            function_defs: Array(facts[:function_defs]),
            state_declarations: state_declarations,
            provider: self
          )
          definitions.concat(ruby_struct_type_definitions(document, rel_path))
          definitions
        end

        def return_type_index(root:)
          sorbet.return_type_index(root: root)
        end

        def field_type_index(root:)
          sorbet.field_type_index(root: root)
        end

        def external_type_definitions(root:)
          sorbet.external_type_definitions(root: root)
        end

        def static_diff_findings(root:, added_lines:, context_paths:, finding_class:)
          NilKill::RubyStaticDiffAudit.new(
            root: root,
            added_lines: added_lines,
            context_paths: context_paths,
            finding_class: finding_class
          ).findings
        end

        def sorbet
          @sorbet ||= Sorbet.new
        end

        private

        def ruby_struct_type_definitions(document, rel_path)
          definitions = []
          class_stack = []
          document.lines.each_with_index do |line, index|
            line_no = index + 1
            stripped = line.strip
            if (match = stripped.match(/\Aclass\s+([A-Z]\w*)\s*<\s*T::Struct\b/))
              class_stack << { name: qualified_name(class_stack, match[1]), t_struct: true }
              next
            elsif (match = stripped.match(/\Aclass\s+([A-Z]\w*)\b/))
              class_stack << { name: qualified_name(class_stack, match[1]), t_struct: false }
              if (struct_match = stripped.match(/\Aclass\s+([A-Z]\w*)\s*=\s*Struct\.new\((.*)\)/))
                definitions.concat(ruby_struct_new_fields(rel_path, qualified_name(class_stack[0...-1], struct_match[1]), struct_match[2], line_no))
              end
              next
            elsif stripped == "end"
              class_stack.pop
              next
            end

            owner = class_stack.last
            if owner&.fetch(:t_struct) && (field = ruby_t_struct_field(stripped))
              definitions << ruby_state_field_definition(
                rel_path: rel_path,
                owner: owner.fetch(:name),
                name: field[:name],
                type: field[:type],
                line: line_no,
                source: "sorbet"
              )
            elsif (match = stripped.match(/\A([A-Z]\w*)\s*=\s*Struct\.new\((.*)\)/))
              definitions.concat(ruby_struct_new_fields(rel_path, qualified_name(class_stack, match[1]), match[2], line_no))
            end
          end
          definitions
        end

        def ruby_t_struct_field(stripped)
          match = stripped.match(/\A(?:const|prop)\s+:([A-Za-z_]\w*)\s*,\s*(.+?)\s*(?:do\b.*)?\z/)
          return nil unless match

          { name: match[1], type: match[2].strip }
        end

        def ruby_struct_new_fields(rel_path, owner, args, line)
          NilKill.split_top_level(args).filter_map do |arg|
            name = arg.strip[/\A:([A-Za-z_]\w*)\z/, 1]
            next unless name

            ruby_state_field_definition(
              rel_path: rel_path,
              owner: owner,
              name: name,
              type: nil,
              line: line,
              source: "ruby-struct"
            )
          end
        end

        def ruby_state_field_definition(rel_path:, owner:, name:, type:, line:, source:)
          {
            "id" => ["ruby", rel_path, owner, "state_field", name, line, source].map(&:to_s).join("\u0000"),
            "language" => "ruby",
            "type_system" => source,
            "kind" => "state_field",
            "path" => rel_path,
            "owner" => owner.to_s,
            "name" => name.to_s,
            "line" => line,
            "declared_type" => type,
          }
        end

        def qualified_name(stack, name)
          parents = Array(stack).map { |entry| entry.is_a?(Hash) ? entry[:name] : entry.to_s }.reject(&:empty?)
          (parents + [name]).join("::")
        end

        def self_receiver_names
          %w[self]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Ruby.new)
