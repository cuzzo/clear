# frozen_string_literal: true

module FactMine
  module Syntax
    # Shared row builders for language-owned type metadata facts. Syntax parsing
    # stays in syntax/<language>.rb; this module only normalizes fact shapes.
    module TypeMetadataFacts
      module_function

      def method_signature(language:, type_system:, file:, owner:, name:, line:, signature:, return_type:, params:)
        row(
          language: language,
          type_system: type_system,
          file: file,
          owner: owner,
          kind: "method_signature",
          name: name,
          line: line
        ).merge(
          "signature" => normalize_text(signature),
          "return_type" => blank_to_nil(return_type),
          "params" => Array(params).map { |param| stringify_keys(param) }
        )
      end

      def state_field(language:, type_system:, file:, owner:, name:, line:, declared_type:, type_references: [])
        row(
          language: language,
          type_system: type_system,
          file: file,
          owner: owner,
          kind: "state_field",
          name: name,
          line: line
        ).merge(
          "declared_type" => blank_to_nil(declared_type),
          "type_references" => Array(type_references).map(&:to_s)
        )
      end

      def type_alias(language:, type_system:, file:, owner:, name:, line:, target:)
        row(
          language: language,
          type_system: type_system,
          file: file,
          owner: owner,
          kind: "type_alias",
          name: name,
          line: line
        ).merge("target" => target.to_s.strip)
      end

      def included_module(language:, type_system:, file:, owner:, name:, line:)
        row(
          language: language,
          type_system: type_system,
          file: file,
          owner: owner,
          kind: "included_module",
          name: name,
          line: line
        )
      end

      def split_top_level(source, delimiter: ",")
        Syntax.type_profile(:generic).split_top_level(source, delimiter: delimiter)
      end

      def extract_parenthesized(source)
        text = source.to_s
        start = text.index("(")
        return [nil, nil] unless start

        depth = 0
        quote = nil
        i = start
        while i < text.length
          char = text[i]
          if quote
            quote = nil if char == quote && text[i - 1] != "\\"
          elsif char == "\"" || char == "'"
            quote = char
          elsif char == "("
            depth += 1
          elsif char == ")"
            depth -= 1
            return [text[(start + 1)...i], i] if depth.zero?
          end
          i += 1
        end
        [nil, nil]
      end

      def normalize_text(text)
        text.to_s.tr("\u00A0", " ").strip.gsub(/\s+/, " ")
      end

      def line_indent(line)
        line.to_s[/\A\s*/].to_s.length
      end

      def source_line_span(line, line_no)
        [line_no.to_i, 0, line_no.to_i, line.to_s.chomp.length]
      end

      def qualified_owner(parent, name)
        return name.to_s if name.to_s.include?("::")

        parent.to_s.empty? ? name.to_s : "#{parent}::#{name}"
      end

      def owner_for_line(document, line)
        Array(document.owner_defs).select do |owner|
          span = Array(owner.span)
          span[0].to_i <= line.to_i && span[2].to_i >= line.to_i
        end.max_by { |owner| Array(owner.span)[0].to_i }&.name.to_s
      end

      def owner_names(document)
        Set.new(Array(document.owner_defs).map { |owner| owner.name.to_s })
      end

      def signature_line(document, function)
        document.lines[function.line.to_i - 1].to_s
      end

      def file_for(document, value = nil)
        value.to_s.empty? ? document.file.to_s : value.to_s
      end

      def normalized_state_field(language, field)
        text = field.to_s
        return text if text.empty? || text.start_with?("@")
        return "@#{text}" if %w[python typescript javascript].include?(language.to_s)

        text
      end

      def stringify_keys(value)
        return value unless value.respond_to?(:to_h)

        value.to_h.transform_keys(&:to_s)
      end

      def blank_to_nil(value)
        text = value.to_s
        text.empty? ? nil : text
      end

      def row(language:, type_system:, file:, owner:, kind:, name:, line:)
        language = language.to_s
        type_system = type_system.to_s
        file = file.to_s
        {
          "id" => [language, file, owner, kind, name, line, type_system].map(&:to_s).join("\u0000"),
          "language" => language,
          "type_system" => type_system,
          "kind" => kind.to_s,
          "file" => file,
          "path" => file,
          "owner" => owner.to_s,
          "name" => name.to_s,
          "line" => line.to_i
        }
      end
    end
  end
end
