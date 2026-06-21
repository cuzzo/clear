# frozen_string_literal: true

require_relative "adapters/base"
require_relative "adapters/ruby"
require_relative "adapters/python"
require_relative "adapters/lua"
require_relative "adapters/typescript"
require_relative "adapters/c"
require_relative "adapters/go"
require_relative "adapters/kotlin"
require_relative "adapters/rust"
require_relative "adapters/zig"

module FactMine
  module Ast
    module TreeSitterNormalizationAdapters
      module_function

      def for(document)
        case document&.language&.to_sym
        when :ruby then RubyTreeSitterNormalizationAdapter.new(document)
        when :python then PythonTreeSitterNormalizationAdapter.new(document)
        when :lua then LuaTreeSitterNormalizationAdapter.new(document)
        when :typescript, :javascript then TypeScriptTreeSitterNormalizationAdapter.new(document)
        when :c then CTreeSitterNormalizationAdapter.new(document)
        when :cpp then CppTreeSitterNormalizationAdapter.new(document)
        when :go then GoTreeSitterNormalizationAdapter.new(document)
        when :kotlin then KotlinTreeSitterNormalizationAdapter.new(document)
        when :rust then RustTreeSitterNormalizationAdapter.new(document)
        when :zig then ZigTreeSitterNormalizationAdapter.new(document)
        else TreeSitterNormalizationAdapter.new(document)
        end
      end
    end
  end
end
