# frozen_string_literal: true

class FlowExample
  def prepare; self.status = :ready; end
  def validate; @valid = status == :ready; end
  def commit; self.done = @valid; end

  def ok1; prepare; validate; commit; end
  def ok2; prepare; validate; commit; end
  def ok3; prepare; validate; commit; end
  def ok4; prepare; validate; commit; end
  def drift; validate; prepare; commit; end
end
