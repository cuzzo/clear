# frozen_string_literal: true

module FactMine
  module Syntax
    TYPESCRIPT_LEXICON = JAVASCRIPT_LEXICON
    Syntax.register_effect_lexicon(:typescript, JAVASCRIPT_EFFECT_LEXICON)

    class TypeScriptSyntaxAdapter < JavaScriptSyntaxAdapter
    end
  end
end
