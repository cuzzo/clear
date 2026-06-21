# frozen_string_literal: true

module FactMine
  module Syntax
    TYPESCRIPT_LEXICON = JAVASCRIPT_LEXICON
    Syntax.register_effect_lexicon(:typescript, JAVASCRIPT_EFFECT_LEXICON)

    class TypeScriptSyntaxAdapter < JavaScriptSyntaxAdapter
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
