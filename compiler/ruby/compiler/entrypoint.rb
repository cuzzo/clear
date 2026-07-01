# typed: strict
require "sorbet-runtime"

module Compiler
  module Entrypoint
    NAME = T.let("main", String)
    ZIG_NAME = T.let("clearMain", String)
  end
end
