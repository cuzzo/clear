# frozen_string_literal: true

require_relative "constraints/audit"
require_relative "constraints/c_provider"
require_relative "constraints/cpp_provider"
require_relative "constraints/csharp_provider"
require_relative "constraints/diff"
require_relative "constraints/evidence"
require_relative "constraints/finding"
require_relative "constraints/go_provider"
require_relative "constraints/rust_provider"
require_relative "constraints/sarif"
require_relative "constraints/zig_provider"
require_relative "constraints/ruby_provider"
require_relative "constraints/python_provider"
require_relative "constraints/javascript_provider"
require_relative "constraints/typescript_provider"
require_relative "constraints/lua_provider"

module SlopCop
  module Constraints
    module_function

    def providers
      {
        "c" => CProvider,
        "cpp" => CppProvider,
        "csharp" => CsharpProvider,
        "go" => GoProvider,
        "rust" => RustProvider,
        "zig" => ZigProvider,
        "ruby" => RubyProvider,
        "python" => PythonProvider,
        "javascript" => JavascriptProvider,
        "typescript" => TypescriptProvider,
        "lua" => LuaProvider
      }
    end
  end
end
