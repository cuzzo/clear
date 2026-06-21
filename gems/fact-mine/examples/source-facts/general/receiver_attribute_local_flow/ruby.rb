# frozen_string_literal: true

class SourceFactReceiverAttributeLocalFlow
  def apply(row, facts)
    @repo = row.file
    fact = facts.status_for(row.file, row.name)
    row.status = fact.summary
    row.count = fact.count
    row.risk = (row.risk * row.multiplier).round(4)
    fact
  end
end
