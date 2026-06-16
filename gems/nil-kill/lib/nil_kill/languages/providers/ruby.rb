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
          definitions.concat(ruby_type_alias_definitions(document, rel_path))
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
          owner_stack = []
          document.lines.each_with_index do |line, index|
            line_no = index + 1
            stripped = line.strip
            indent = line_indent(line)
            if (match = stripped.match(/\Amodule\s+([A-Z]\w*(?:::[A-Z]\w*)*)\b/))
              owner_stack << { name: qualified_owner_name(owner_stack, match[1]), t_struct: false, indent: indent }
              next
            elsif (match = stripped.match(/\Aclass\s+([A-Z]\w*(?:::[A-Z]\w*)*)\s*<\s*T::Struct\b/))
              owner_stack << { name: qualified_owner_name(owner_stack, match[1]), t_struct: true, indent: indent }
              next
            elsif (match = stripped.match(/\Aclass\s+([A-Z]\w*(?:::[A-Z]\w*)*)\b/))
              owner_stack << { name: qualified_owner_name(owner_stack, match[1]), t_struct: false, indent: indent }
              next
            elsif stripped == "end"
              owner_stack.pop while owner_stack.last && indent <= owner_stack.last.fetch(:indent)
              next
            end

            owner = owner_stack.last
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
              owner_name = qualified_name(owner_stack, match[1])
              definitions.concat(ruby_struct_new_fields(rel_path, owner_name, match[2], line_no))
              owner_stack << { name: owner_name, t_struct: false, indent: indent } if stripped.match?(/\bdo\b/)
              next
            elsif owner && (match = stripped.match(/\Ainclude\s+([A-Z]\w*(?:::[A-Z]\w*)*)\b/))
              definitions << ruby_included_module_definition(
                rel_path: rel_path,
                owner: owner.fetch(:name),
                name: qualified_include_name(owner_stack, match[1]),
                line: line_no
              )
            end
          end
          definitions
        end

        def ruby_type_alias_definitions(document, rel_path)
          definitions = []
          owner_stack = []
          pending = nil
          document.lines.each_with_index do |line, index|
            line_no = index + 1
            stripped = line.strip
            next if stripped.empty? || stripped.start_with?("#")

            if pending
              if stripped == "end" && line_indent(line) <= pending[:indent]
                target = normalize_alias_body(pending[:body].join(" "))
                definitions << ruby_type_alias_definition(
                  rel_path: rel_path,
                  owner: pending[:owner],
                  name: pending[:name],
                  target: target,
                  line: pending[:line]
                ) unless target.empty?
                pending = nil
              else
                pending[:body] << stripped
              end
              next
            end

            if (match = stripped.match(/\A(?:class|module)\s+([A-Z]\w*(?:::[A-Z]\w*)*)\b/))
              owner_stack << qualified_owner_name(owner_stack, match[1])
              next
            end

            if stripped == "end"
              owner_stack.pop
              next
            end

            if (match = stripped.match(/\A([A-Z]\w*)\s*=\s*T\.type_alias\s*\{\s*(.+)\s*\}\s*(?:#.*)?\z/))
              definitions << ruby_type_alias_definition(
                rel_path: rel_path,
                owner: owner_stack.last.to_s,
                name: match[1],
                target: normalize_alias_body(match[2]),
                line: line_no
              )
            elsif (match = stripped.match(/\A([A-Z]\w*)\s*=\s*T\.type_alias\s+do\b/))
              pending = {
                owner: owner_stack.last.to_s,
                name: match[1],
                line: line_no,
                indent: line_indent(line),
                body: [],
              }
            end
          end
          definitions
        end

        def ruby_type_alias_definition(rel_path:, owner:, name:, target:, line:)
          {
            "id" => ["ruby", rel_path, owner, "type_alias", name, line, "sorbet"].map(&:to_s).join("\u0000"),
            "language" => "ruby",
            "type_system" => "sorbet",
            "kind" => "type_alias",
            "path" => rel_path,
            "owner" => owner.to_s,
            "name" => name.to_s,
            "line" => line,
            "target" => target.to_s,
            "source" => "T.type_alias",
          }
        end

        def normalize_alias_body(body)
          body.to_s.gsub(/\s+/, " ").strip.sub(/,\z/, "")
        end

        def line_indent(line)
          line[/\A\s*/].to_s.length
        end

        def qualified_owner_name(stack, name)
          name.to_s.include?("::") ? name.to_s : qualified_name(stack, name)
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

        def ruby_included_module_definition(rel_path:, owner:, name:, line:)
          {
            "id" => ["ruby", rel_path, owner, "included_module", name, line, "ruby-include"].map(&:to_s).join("\u0000"),
            "language" => "ruby",
            "type_system" => "ruby-include",
            "kind" => "included_module",
            "path" => rel_path,
            "owner" => owner.to_s,
            "name" => name.to_s,
            "line" => line,
          }
        end

        def qualified_name(stack, name)
          return name.to_s if name.to_s.include?("::")

          parent = Array(stack).reverse.find do |entry|
            value = entry.is_a?(Hash) ? entry[:name] : entry.to_s
            !value.to_s.empty?
          end
          parent_name = parent.is_a?(Hash) ? parent[:name].to_s : parent.to_s
          parent_name.empty? ? name.to_s : "#{parent_name}::#{name}"
        end

        def qualified_include_name(stack, name)
          return name.to_s if name.to_s.include?("::")

          qualified_name(Array(stack)[0...-1], name)
        end

        def self_receiver_names
          %w[self]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Ruby.new)
