# frozen_string_literal: true

class SourceFactBranchQualifiedPredicates
  def checks(lines, path)
    return false unless External::Risk.enabled?
    return false unless External::Risk.load_config
    return false if lines.any? { |hit| !hit.nil? }

    case ::File.extname(path).downcase
    when ".rb"
      true
    else
      false
    end
  end

  def rescued_case(path)
    case ::File.extname(path).downcase
    when ".rb"
      true
    else
      false
    end
  rescue JSON::ParserError
    false
  end
end
