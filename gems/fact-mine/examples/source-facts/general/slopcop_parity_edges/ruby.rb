# frozen_string_literal: true

class SourceFactSlopcopParityEdges
  def report(gaps)
    flagged = gaps.reject { |x| x[:detectors].to_a.empty? }
    dup = flagged.count { |x| x[:coarse_dup] }
    gaps.first(@top).map { |x| x[:file] }
    "#{gaps.size} #{dup.positive? ? @top : 0}"
  end

  def scan(paths)
    if paths && !Array(paths).empty?
      Array(paths).select { |path| source_path?(path) }
    else
      []
    end
  end

  def guarded_emit(source, evidence)
    return unless source
    return if evidence.covered?

    emit(source)
  end
end
