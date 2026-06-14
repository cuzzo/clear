# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class TypeScript < Provider
        def language
          "typescript"
        end

        def aliases
          ["ts"]
        end

        def display_name
          "TypeScript"
        end

        def extensions
          %w[.ts .tsx]
        end

        def type_systems
          ["typescript"]
        end

        def runtime_tracing?
          false
        end

        def notes
          ["static TypeScript annotation evidence is supported; runtime tracing is not implemented"]
        end

        def canonical_state_field(field, receiver: nil)
          text = field.to_s
          return text if text.empty? || text.start_with?("@")

          receiver_text = receiver.to_s.sub(/\A\*/, "")
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

        def type_definitions(document:, facts:, rel_path:, methods:, state_declarations:)
          definitions = []
          Array(facts[:function_defs]).each do |fn|
            typed = typescript_signature_types(fn.signature)
            next if typed[:params].empty? && typed[:return_type].to_s.empty?

            definitions << {
              "id" => ["typescript", rel_path, fn.owner, "method_signature", fn.name, fn.line, "typescript"].map(&:to_s).join("\u0000"),
              "language" => "typescript",
              "type_system" => "typescript",
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
              "id" => ["typescript", rel_path, state.owner, "state_field", field, state.line, "typescript"].map(&:to_s).join("\u0000"),
              "language" => "typescript",
              "type_system" => "typescript",
              "kind" => "state_field",
              "path" => rel_path,
              "owner" => state.owner.to_s,
              "name" => field,
              "line" => state.line,
              "declared_type" => type,
            }
          end

          definitions.concat(typescript_interface_type_definitions(document, rel_path))
          definitions
        end

        private

        def self_receiver_names
          %w[this]
        end

        def typescript_signature_types(signature)
          source = signature.to_s.strip
          params_source, close_idx = extract_parenthesized(source)
          return { params: [], return_type: nil } unless params_source

          params = NilKill.split_top_level(params_source).filter_map do |entry|
            name, type = typescript_param_entry(entry)
            next unless name && type

            { "name" => name, "type" => type }
          end

          tail = source[(close_idx + 1)..].to_s
          return_type = tail[/\A\s*:\s*([^={;]+)/, 1]&.strip
          { params: params, return_type: return_type }
        end

        def typescript_param_entry(entry)
          text = entry.to_s.strip
          return [nil, nil] if text.empty?

          text = text.sub(/\A(?:public|private|protected|readonly|override|declare)\s+/, "")
          text = text.sub(/\A(?:public|private|protected)\s+readonly\s+/, "")
          text = text.sub(/\A\.\.\./, "")
          name, type = text.split(/:\s*/, 2)
          return [nil, nil] unless name && type

          name = name.sub(/=.*/, "").sub(/\?\z/, "").strip
          type = type.sub(/=.*/, "").strip
          return [nil, nil] if name.empty? || type.empty?

          [name, type]
        end

        def typescript_interface_type_definitions(document, rel_path)
          definitions = []
          owner = nil
          document.lines.each_with_index do |line, idx|
            line_no = idx + 1
            stripped = line.strip
            if (match = stripped.match(/\A(?:export\s+)?interface\s+([A-Za-z_$]\w*)\b/))
              owner = match[1]
              next
            end

            if owner && stripped.start_with?("}")
              owner = nil
              next
            end
            next unless owner

            if (match = stripped.match(/\A([A-Za-z_$]\w*)\??\s*\((.*)\)\s*:\s*([^;{]+)/))
              name = match[1]
              params = NilKill.split_top_level(match[2]).filter_map do |entry|
                param_name, type = typescript_param_entry(entry)
                next unless param_name && type

                { "name" => param_name, "type" => type }
              end
              definitions << {
                "id" => ["typescript", rel_path, owner, "method_signature", name, line_no, "typescript-interface"].map(&:to_s).join("\u0000"),
                "language" => "typescript",
                "type_system" => "typescript",
                "kind" => "method_signature",
                "path" => rel_path,
                "owner" => owner,
                "name" => name,
                "line" => line_no,
                "signature" => stripped.delete_suffix(";"),
                "return_type" => match[3].strip,
                "params" => params,
              }
            elsif (match = stripped.match(/\A([A-Za-z_$]\w*)\??\s*:\s*([^;{]+)/))
              name = match[1]
              definitions << {
                "id" => ["typescript", rel_path, owner, "state_field", name, line_no, "typescript-interface"].map(&:to_s).join("\u0000"),
                "language" => "typescript",
                "type_system" => "typescript",
                "kind" => "state_field",
                "path" => rel_path,
                "owner" => owner,
                "name" => name,
                "line" => line_no,
                "declared_type" => match[2].strip,
              }
            end
          end
          definitions
        end

        def extract_parenthesized(source)
          start = source.index("(")
          return [nil, nil] unless start

          depth = 0
          i = start
          while i < source.length
            case source[i]
            when "("
              depth += 1
            when ")"
              depth -= 1
              return [source[(start + 1)...i], i] if depth.zero?
            end
            i += 1
          end
          [nil, nil]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::TypeScript.new)
