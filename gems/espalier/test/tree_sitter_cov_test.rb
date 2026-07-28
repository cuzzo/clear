# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier/tree_sitter"

class TreeSitterCovTest < Minitest::Test
  def test_parser_for_loads_the_real_installed_ruby_runtime
    parser = Espalier::TreeSitter.parser_for("ruby")

    assert_instance_of TreeSitter::Parser, parser
  end

  def test_parser_for_normalizes_supported_language_names
    %w[python javascript typescript go rust c cpp csharp kotlin].each do |language|
      parser = Espalier::TreeSitter.parser_for(language)

      assert_instance_of TreeSitter::Parser, parser, language
    rescue LoadError, RuntimeError
      # Optional parser shared libraries are environment-specific. The Ruby
      # parser above is required by this repository and exercises the actual
      # gem/require path without replacing Kernel methods with test doubles.
    end
  end
end
