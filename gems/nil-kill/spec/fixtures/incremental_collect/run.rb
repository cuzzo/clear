# frozen_string_literal: true

require_relative "lib/calculator"

calculator = IncrementalCalculator.new
raise "wrong total" unless calculator.total([1, 2, 3]) == 12
raise "wrong label" unless calculator.label(12) == "total=12"
