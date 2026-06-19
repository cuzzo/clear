# frozen_string_literal: true

require_relative "node"

module Decomplex
  module Ast
    module_function

    # Exact source text of a node, trivial formatting normalised.
    def slice(node, _lines)
      return "" unless node?(node)

      node.text.to_s.strip.gsub(/\s+/, " ")
    end
  end
end
