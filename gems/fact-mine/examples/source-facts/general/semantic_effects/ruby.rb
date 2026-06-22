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

  def shape_hash(data)
    schema = { "$schema" => "https://example.test/schema.json" }
    buckets = Hash.new { |hash, key| hash[key] = [] }
    totals = Hash.new(0)
    data.each { |key, count| totals[key] += count }
    [schema, buckets, totals]
  end
end
