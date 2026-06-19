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
