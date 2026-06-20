# frozen_string_literal: true

class SourceFactMemoizedHelperCalls
  def owner_edges
    @owner_edges ||= build_owner_edges
  end

  def build_owner_edges
    []
  end
end
