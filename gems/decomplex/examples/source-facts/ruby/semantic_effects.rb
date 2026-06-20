# frozen_string_literal: true

class SourceFactSemanticEffects
  def perform(callback, name)
    puts name
    callback.call(name)
    send(:audit, name)
    $source_fact_seen
  end

  def mutate(target, value)
    target[:name] = value
    target.items << value
  end
end
