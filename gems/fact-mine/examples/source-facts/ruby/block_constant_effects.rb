# frozen_string_literal: true

class SourceFactBlockConstantEffects
  CANDIDATES = %w[one two].freeze

  def resolve(path)
    CANDIDATES.map { |rel| ::File.join(path, rel) }
              .find { |candidate| ::File.file?(candidate) }
  end

  def direct(path)
    ::File.join(path, "x")
    ::File.file?(path)
  end
end
