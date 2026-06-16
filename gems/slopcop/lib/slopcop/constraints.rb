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
        "zig" => ZigProvider
      }
    end
  end
end
