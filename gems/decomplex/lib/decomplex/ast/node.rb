# frozen_string_literal: true

module Decomplex
  module Ast
    Node = Struct.new(
      :type, :children, :first_lineno, :first_column, :last_lineno, :last_column,
      :text,
      keyword_init: true
    )

    module_function

    def node?(node)
      node.is_a?(Node)
    end
  end
end
