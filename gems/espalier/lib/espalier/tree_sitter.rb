# typed: false
# frozen_string_literal: true

sibling_fact_mine = File.expand_path("../../../fact-mine/lib/fact_mine", __dir__)
if File.file?("#{sibling_fact_mine}/syntax.rb")
  require "#{sibling_fact_mine}/syntax"
else
  require "fact_mine/syntax"
end

module Espalier
  module TreeSitter
    module_function

    def parse(path, parser: "tree_sitter", language: nil)
      FactMine::Syntax.parse(path, parser: parser, language: language)
    end

    def supported_exts(parser: "tree_sitter")
      FactMine::Syntax.supported_exts(parser: parser)
    end

    def language_for(path)
      FactMine::Syntax.language_for(path)
    end

    def parser_for(language)
      FactMine::Syntax::TreeSitterAdapter.new.send(:parser_for, language)
    end
  end
end
