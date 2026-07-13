# frozen_string_literal: true

require "pathname"
require "rexml/document"
require "rexml/formatters/pretty"

module CoverageXmlBranchPatch
  module_function

  def apply(xml_path:, result_payload:, root:)
    aggregates = branch_aggregates(result_payload, root: root)
    return { files: 0, branches_valid: 0, branches_covered: 0 } if aggregates.empty?

    document = REXML::Document.new(File.read(xml_path))
    totals = empty_totals
    package_totals = Hash.new { |hash, key| hash[key] = empty_totals.merge(package: nil) }

    REXML::XPath.each(document, "//class") do |klass|
      filename = normalize_path(klass.attributes["filename"].to_s)
      branch_totals = patch_class!(klass, aggregates.fetch(filename, {}))
      line_totals = class_line_totals(klass)
      update_line_rate!(klass, line_totals.fetch(:lines_covered), line_totals.fetch(:lines_valid))
      update_branch_rate!(klass, branch_totals.fetch(:covered), branch_totals.fetch(:valid))

      totals[:files] += 1 if branch_totals.fetch(:valid).positive?
      totals[:branches_valid] += branch_totals.fetch(:valid)
      totals[:branches_covered] += branch_totals.fetch(:covered)
      totals[:lines_valid] += line_totals.fetch(:lines_valid)
      totals[:lines_covered] += line_totals.fetch(:lines_covered)
      package = package_for(klass)
      next unless package

      package_key = package.object_id
      package_totals[package_key][:package] = package
      package_totals[package_key][:branches_valid] += branch_totals.fetch(:valid)
      package_totals[package_key][:branches_covered] += branch_totals.fetch(:covered)
      package_totals[package_key][:lines_valid] += line_totals.fetch(:lines_valid)
      package_totals[package_key][:lines_covered] += line_totals.fetch(:lines_covered)
    end

    package_totals.each_value do |entry|
      update_line_rate!(entry.fetch(:package), entry.fetch(:lines_covered), entry.fetch(:lines_valid))
      update_branch_rate!(entry.fetch(:package), entry.fetch(:branches_covered), entry.fetch(:branches_valid))
    end

    update_document_totals!(document, totals)
    write_xml(xml_path, document)
    branch_totals_for_return(totals)
  end

  def empty_totals
    { files: 0, lines_valid: 0, lines_covered: 0, branches_valid: 0, branches_covered: 0 }
  end

  def branch_totals_for_return(totals)
    {
      files: totals.fetch(:files),
      branches_valid: totals.fetch(:branches_valid),
      branches_covered: totals.fetch(:branches_covered)
    }
  end

  def branch_aggregates(result_payload, root:)
    root_path = Pathname.new(File.expand_path(root))
    result_payload.fetch("coverage", {}).each_with_object({}) do |(path, coverage), files|
      branches = coverage.fetch("branches", {})
      next unless branches.is_a?(Hash)

      file = relative_path(path, root_path)
      file_totals = files[file] ||= Hash.new { |hash, key| hash[key] = { valid: 0, covered: 0 } }
      branches.each do |parent_tuple, arms|
        next unless arms.is_a?(Hash) && arms.any?

        line = tuple_line(parent_tuple)
        next unless line.positive?

        file_totals[line][:valid] += arms.size
        file_totals[line][:covered] += arms.values.count { |hits| hits.to_i.positive? }
      end
    end
  end

  def patch_class!(klass, line_totals)
    totals = { valid: 0, covered: 0 }
    lines_container = klass.elements["lines"]
    lines = {}

    REXML::XPath.each(klass, "lines/line") do |line|
      line_number = line.attributes["number"].to_i
      lines[line_number] = line
      clear_branch_attributes!(line)
    end

    line_totals.each do |line_number, counts|
      valid = counts.fetch(:valid)
      covered = counts.fetch(:covered)
      next unless valid.positive?

      line = lines[line_number] || create_line!(lines_container, line_number, covered: covered)
      lines[line_number] = line
      annotate_branch_line!(line, covered: covered, valid: valid)
      totals[:valid] += valid
      totals[:covered] += covered
    end

    totals
  end

  def create_line!(lines_container, line_number, covered:)
    lines_container.add_element(
      "line",
      "number" => line_number.to_s,
      "hits" => covered.positive? ? "1" : "0",
      "branch" => "false"
    )
  end

  def clear_branch_attributes!(line)
    line.attributes["branch"] = "false"
    line.delete_attribute("condition-coverage")
    line.delete_element(line.elements["conditions"]) while line.elements["conditions"]
  end

  def annotate_branch_line!(line, covered:, valid:)
    percent = percent_text(covered, valid)
    line.attributes["branch"] = "true"
    line.attributes["condition-coverage"] = "#{percent}% (#{covered}/#{valid})"
    conditions = line.add_element("conditions")
    condition = conditions.add_element("condition")
    condition.attributes["number"] = "0"
    condition.attributes["type"] = "jump"
    condition.attributes["coverage"] = "#{percent}%"
  end

  def update_branch_rate!(element, covered, valid)
    element.attributes["branch-rate"] = ratio_text(covered, valid)
  end

  def update_line_rate!(element, covered, valid)
    element.attributes["lines-covered"] = covered.to_s if element.attributes["lines-covered"]
    element.attributes["lines-valid"] = valid.to_s if element.attributes["lines-valid"]
    element.attributes["line-rate"] = ratio_text(covered, valid)
  end

  def update_document_totals!(document, totals)
    root = document.root
    root.attributes["lines-covered"] = totals.fetch(:lines_covered).to_s
    root.attributes["lines-valid"] = totals.fetch(:lines_valid).to_s
    root.attributes["line-rate"] = ratio_text(totals.fetch(:lines_covered), totals.fetch(:lines_valid))
    root.attributes["branches-covered"] = totals.fetch(:branches_covered).to_s
    root.attributes["branches-valid"] = totals.fetch(:branches_valid).to_s
    root.attributes["branch-rate"] = ratio_text(totals.fetch(:branches_covered), totals.fetch(:branches_valid))
  end

  def tuple_line(tuple)
    parts = tuple.to_s.delete("[]").split(",").map(&:strip)
    parts.fetch(2, "0").to_i
  end

  def relative_path(path, root_path)
    expanded = Pathname.new(File.expand_path(path))
    normalize_path(expanded.relative_path_from(root_path).to_s)
  rescue ArgumentError
    normalize_path(path.to_s)
  end

  def normalize_path(path)
    path.tr("\\", "/")
  end

  def package_for(element)
    cursor = element.parent
    until cursor.nil? || cursor.name == "package"
      cursor = cursor.parent
    end
    cursor
  end

  def class_line_totals(klass)
    REXML::XPath.match(klass, "lines/line").each_with_object({ lines_valid: 0, lines_covered: 0 }) do |line, totals|
      next unless line.attributes["number"].to_i.positive?

      totals[:lines_valid] += 1
      totals[:lines_covered] += 1 if line.attributes["hits"].to_i.positive?
    end
  end

  def ratio_text(covered, valid)
    return "0.0" unless valid.positive?

    format_number(covered.to_f / valid)
  end

  def percent_text(covered, valid)
    return "0" unless valid.positive?

    format_number((covered.to_f * 100.0) / valid)
  end

  def format_number(value)
    formatted = format("%.4f", value)
    formatted.sub(/0+\z/, "").sub(/\.\z/, "")
  end

  def write_xml(xml_path, document)
    formatter = REXML::Formatters::Pretty.new(2)
    formatter.compact = true
    File.open(xml_path, "w") do |file|
      formatter.write(document, file)
      file.write("\n")
    end
  end
end
