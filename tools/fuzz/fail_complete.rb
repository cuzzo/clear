# frozen_string_literal: true

# Runs a batch once and recursively isolates its failures. A green batch costs
# one invocation; a red batch is split until each independently failing entry
# has its own diagnostic. Results use the fuzz runner's four-array shape:
# [pass, runtime_failures, compile_failures, leaks].
module FuzzFailComplete
  module_function

  def run(entries, &runner)
    result = runner.call(entries)
    return result if entries.length <= 1 || successful?(result)

    midpoint = entries.length / 2
    left = run(entries.take(midpoint), &runner)
    right = run(entries.drop(midpoint), &runner)
    isolated = merge(left, right)

    # Do not hide a failure caused only by combining otherwise-green cells.
    successful?(isolated) ? result : isolated
  end

  def successful?(result)
    result.drop(1).all?(&:empty?)
  end

  def merge(left, right)
    left.zip(right).map { |left_items, right_items| left_items + right_items }
  end
end
