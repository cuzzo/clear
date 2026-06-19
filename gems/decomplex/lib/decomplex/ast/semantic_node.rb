# frozen_string_literal: true

module Decomplex
  module Ast
    SemanticNode = Struct.new(
      :type, :children, :span, :text, :language, :metadata,
      keyword_init: true
    ) do
      def [](key)
        metadata.fetch(key)
      end

      def fetch(key, *fallback)
        metadata.fetch(key, *fallback)
      end

      def walk(&block)
        return enum_for(:walk) unless block

        block.call(self)
        children.each { |child| child.walk(&block) if child.respond_to?(:walk) }
      end
    end

    module_function

    def semantic_node?(node)
      node.is_a?(SemanticNode)
    end
  end
end
