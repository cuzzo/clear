# frozen_string_literal: true

require_relative "lib/calculator"
legacy = File.join(__dir__, "lib", "legacy.rb")
if File.file?(legacy)
  require legacy
  raise "wrong legacy value" unless IncrementalLegacy.identity(12) == 12
end

calculator = IncrementalCalculator.new
raise "wrong total" unless calculator.total([1, 2, 3]) == 12
raise "wrong label" unless calculator.label(12) == "total=12"
