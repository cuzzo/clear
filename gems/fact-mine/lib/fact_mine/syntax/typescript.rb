# frozen_string_literal: true

module FactMine
  module Syntax
    TYPESCRIPT_LEXICON = JAVASCRIPT_LEXICON
    Syntax.register_effect_lexicon(:typescript, JAVASCRIPT_EFFECT_LEXICON)

    class TypeScriptSyntaxAdapter < JavaScriptSyntaxAdapter
      def typed_state_declarations(document)
        document.lines.each_with_index.filter_map do |line, index|
          line_no = index + 1
          owner = TypeMetadataFacts.owner_for_line(document, line_no)
          next if owner.empty?

          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("//")
          next if stripped.include?("(")

          match = stripped.match(
            /\A(?:(?:public|private|protected|readonly|static|declare|override|abstract)\s+)*(?:accessor\s+)?([A-Za-z_$]\w*)[?!]?\s*:\s*([^=;{]+)/
          )
          next unless match

          StateDeclaration.new(
            field: match[1],
            owner: owner,
            type: TypeMetadataFacts.normalize_text(match[2].to_s.delete_suffix(";")),
            type_references: [],
            file: document.file,
            line: line_no,
            span: TypeMetadataFacts.source_line_span(line, line_no)
          )
        end
      end

      def type_definitions(document)
        definitions = []
        definitions.concat(typescript_method_type_definitions(document))
        definitions.concat(typescript_state_field_type_definitions(document))
        definitions.concat(typescript_interface_type_definitions(document))
        definitions.concat(typescript_type_alias_definitions(document))
        definitions.uniq { |row| [row["language"], row["file"], row["owner"], row["kind"], row["name"], row["line"], row["type_system"]] }
      end

      private

      def typescript_method_type_definitions(document)
        Array(document.function_defs).filter_map do |function|
          signature = typescript_function_signature(document, function)
          typed = typescript_signature_types(signature)
          next if typed.fetch(:params).empty? && typed.fetch(:return_type).to_s.empty?

          TypeMetadataFacts.method_signature(
            language: "typescript",
            type_system: "typescript",
            file: function.file,
            owner: function.owner,
            name: function.name,
            line: function.line,
            signature: signature,
            return_type: typed.fetch(:return_type),
            params: typed.fetch(:params)
          )
        end
      end

      def typescript_state_field_type_definitions(document)
        Array(document.state_declarations).filter_map do |state|
          type = state.type.to_s
          next if type.empty?

          TypeMetadataFacts.state_field(
            language: "typescript",
            type_system: "typescript",
            file: state.file,
            owner: state.owner,
            name: TypeMetadataFacts.normalized_state_field("typescript", state.field),
            line: state.line,
            declared_type: type,
            type_references: state.respond_to?(:type_references) ? state.type_references : []
          )
        end
      end

      def typescript_interface_type_definitions(document)
        definitions = []
        owner = nil
        document.lines.each_with_index do |line, index|
          line_no = index + 1
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
            params = TypeMetadataFacts.split_top_level(match[2]).filter_map do |entry|
              name, type = typescript_param_entry(entry)
              next unless name && type

              { "name" => name, "type" => type }
            end
            definitions << TypeMetadataFacts.method_signature(
              language: "typescript",
              type_system: "typescript",
              file: document.file,
              owner: owner,
              name: match[1],
              line: line_no,
              signature: stripped.delete_suffix(";"),
              return_type: match[3].strip,
              params: params
            )
          elsif (match = stripped.match(/\A([A-Za-z_$]\w*)\??\s*:\s*([^;{]+)/))
            definitions << TypeMetadataFacts.state_field(
              language: "typescript",
              type_system: "typescript",
              file: document.file,
              owner: owner,
              name: match[1],
              line: line_no,
              declared_type: match[2].strip
            )
          end
        end
        definitions
      end

      def typescript_type_alias_definitions(document)
        document.lines.each_with_index.filter_map do |line, index|
          match = line.strip.match(/\A(?:export\s+)?type\s+([A-Za-z_$]\w*)\s*=\s*(.+?)\s*;?\s*\z/)
          next unless match

          TypeMetadataFacts.type_alias(
            language: "typescript",
            type_system: "typescript",
            file: document.file,
            owner: "",
            name: match[1],
            line: index + 1,
            target: match[2].strip
          )
        end
      end

      def typescript_function_signature(document, function)
        signature = function.respond_to?(:signature) ? function.signature.to_s : ""
        signature = TypeMetadataFacts.signature_line(document, function).strip if signature.empty?
        signature
      end

      def typescript_signature_types(signature)
        source = signature.to_s.strip
        params_source, close_index = TypeMetadataFacts.extract_parenthesized(source)
        return { params: [], return_type: nil } unless params_source

        params = TypeMetadataFacts.split_top_level(params_source).filter_map do |entry|
          name, type = typescript_param_entry(entry)
          next unless name && type

          { "name" => name, "type" => type }
        end
        tail = source[(close_index + 1)..].to_s
        { params: params, return_type: tail[/\A\s*:\s*([^={;]+)/, 1]&.strip }
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
    end

    class TypeScriptNormalizedExtractionBehavior < JavaScriptNormalizedExtractionBehavior
      def function_visibility(_name, node, lines:)
        text = node.text.to_s.strip
        return "private" if text.match?(/\A(?:private|protected)\b/)

        "public"
      end

      def parameter_name_from_signature(param)
        text = param.to_s.strip.sub(/=.*\z/, "").strip
        text = text.sub(/\A(?:public|private|protected|readonly)\s+/, "")
        name = text[/\A([A-Za-z_]\w*)\??\s*:/, 1]
        name || super
      end
    end

    NormalizedExtractionBehavior.register(:typescript, TypeScriptNormalizedExtractionBehavior)
  end
end
