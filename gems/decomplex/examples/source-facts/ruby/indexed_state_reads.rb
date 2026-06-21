# frozen_string_literal: true

class SourceFactIndexedStateReads
  def label
    return "#{@data[:label]} (Data)" if @data[:enabled]

    nil
  end

  def lineage_summary(out)
    out << "- [Lineage Unit Risk (#{@lineage[:units].size})]" \
           "(#lineage-unit-risk-#{@lineage[:units].size})\n"
  end
end
