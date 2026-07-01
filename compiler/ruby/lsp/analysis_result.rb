# typed: strict
require "sorbet-runtime"

module LSP
  AnalysisResult = Struct.new(:findings, :fatal_error, keyword_init: true) do
    extend T::Sig

    sig { returns(T::Boolean) }
    def fatal?
      !fatal_error.nil?
    end
  end
end
