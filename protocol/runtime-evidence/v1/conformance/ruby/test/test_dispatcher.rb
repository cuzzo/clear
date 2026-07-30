# frozen_string_literal: true

module RuntimeEvidenceConformance
  # This implementation deliberately lives in a non-production path. The
  # collector must preserve it as raw evidence while FactMine must not publish
  # it as a production target.
  class TestDispatcher
    def dispatch
      Value.new(:test)
    end
  end
end
