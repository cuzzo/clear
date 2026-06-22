# frozen_string_literal: true

class SourceFactBlockConjunctionDecisions
  def fallback(files)
    files.select do |rel|
      in_scope?(rel) && current_file?(rel) &&
        source_file?(rel)
    end
  end

  def filter_paths(hash)
    hash.select { |rel, _| in_scope?(rel) && current_file?(rel) }
  end
end
