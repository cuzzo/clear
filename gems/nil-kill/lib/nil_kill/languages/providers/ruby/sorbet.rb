# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class Ruby < Provider
        class Sorbet
          def name
            "sorbet"
          end

          def type_systems
            %w[sorbet rbi]
          end

          def method_source(function_def)
            signature = signature_for(function_def)
            return {} if signature.empty?

            {
              "sig" => signature,
              "signature" => signature,
              "type_system" => "sorbet",
            }
          end

          def signature_for(function_def)
            signature = function_def.signature.to_s.strip
            signature.start_with?("sig ") ? signature : ""
          end

          def type_definitions(rel_path:, function_defs:, state_declarations:, provider:)
            definitions = []
            function_defs.each do |fn|
              signature = signature_for(fn)
              next if signature.empty?

              definitions << {
                "id" => ["ruby", rel_path, fn.owner, "method_signature", fn.name, fn.line, "sorbet"].map(&:to_s).join("\u0000"),
                "language" => "ruby",
                "type_system" => "sorbet",
                "kind" => "method_signature",
                "path" => rel_path,
                "owner" => fn.owner.to_s,
                "name" => fn.name.to_s,
                "line" => fn.line,
                "signature" => signature,
                "return_type" => NilKill.extract_return_type(signature),
                "params" => NilKill.extract_param_entries(signature).map do |name, type|
                  { "name" => name, "type" => type }
                end,
              }
            end

            state_declarations.each do |state|
              type = state.type.to_s
              next if type.empty?

              field = provider.declared_state_field(state.field)
              definitions << {
                "id" => ["ruby", rel_path, state.owner, "state_field", field, state.line, "sorbet"].map(&:to_s).join("\u0000"),
                "language" => "ruby",
                "type_system" => "sorbet",
                "kind" => "state_field",
                "path" => rel_path,
                "owner" => state.owner.to_s,
                "name" => field.to_s,
                "line" => state.line,
                "declared_type" => type,
              }
            end

            definitions
          end

          def return_type_index(root:)
            NilKill::RbiReturnIndex.build
          end

          def field_type_index(root:)
            types = {}
            Dir.glob(File.join(root, "sorbet", "rbi", "**", "*.rbi")).sort.each do |path|
              load_field_types(path, types)
            end
            types
          end

          def external_type_definitions(root:)
            field_type_index(root: root).map do |(klass, field), type|
              {
                "id" => ["ruby", "rbi", klass, "state_field", field, "sorbet"].map(&:to_s).join("\u0000"),
                "language" => "ruby",
                "type_system" => "rbi",
                "kind" => "state_field",
                "path" => File.join("sorbet", "rbi"),
                "owner" => klass,
                "name" => field,
                "declared_type" => type,
              }
            end
          end

          private

          def load_field_types(path, types)
            klass = nil
            pending_type = nil
            File.readlines(path).each do |line|
              if line =~ /^\s*class\s+([A-Z]\S*)/
                klass = Regexp.last_match(1)
              elsif klass && line =~ /^\s*sig\s*\{\s*returns\((.+)\)\s*\}/
                pending_type = Regexp.last_match(1).strip
              elsif klass && line =~ /^\s*def\s+([a-zA-Z_]\w*)\b/
                types[[klass, Regexp.last_match(1)]] = pending_type || "T.untyped"
                pending_type = nil
              elsif line =~ /^\s*end\s*$/
                klass = nil
                pending_type = nil
              end
            end
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
