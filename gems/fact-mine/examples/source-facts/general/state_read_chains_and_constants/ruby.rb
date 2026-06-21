# frozen_string_literal: true

class SourceFactStateReadChainsAndConstants
  def results
    @ranked.first(@top).map do |row|
      Custom::Sarif.result(path: row.file)
    end
  end

  def build(path)
    Dataset.new(path)
  end

  def provider_paths
    language_providers.flat_map { |provider| provider.path_candidates }
  end

  def helper_result(items)
    decorate(items).each_with_object({}) do |item, out|
      out[item.name] = true
    end
  end

  def core_effects(path)
    ::File.file?(path)
    Time.now
  end
end
