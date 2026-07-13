class OwnershipDataflow
  OwnershipState = T.type_alias { T::Hash[String, Integer] }

  def initialize
    @block_out = T.let({}, T::Hash[Integer, T.nilable(OwnershipState)])
  end

  def cleanup_decisions(pairs)
    pairs.each do |pair|
      block_exit_cleanup_summary(pair)
    end
  end

  def block_exit_cleanup_summary(place)
    block_exit_cleanup_summaries[place]
  end

  def block_exit_cleanup_summaries
    saw = T.let({}, T::Hash[String, Integer])
    @block_out.each_value do |state|
      next unless state

      state.each do |place, entry|
        saw[place] = entry
      end
    end
    saw.each_value { |entry| consume(entry) }
  end
end
