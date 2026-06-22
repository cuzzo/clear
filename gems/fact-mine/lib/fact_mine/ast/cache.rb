# frozen_string_literal: true

module FactMine
  module Ast
    module_function

    def normalized_cache
      @normalized_cache ||= {}
    end
  end
end
