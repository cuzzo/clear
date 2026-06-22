# frozen_string_literal: true

class SourceFactLocalFlowEdges
  def build(sections, audit, grammar)
    rows = []
    skip "missing grammar" unless grammar && File.file?(grammar)

    sections.each do |title, findings|
      next unless findings

      findings.each do |finding|
        file, meth, = parse_loc(finding.loc)
        next unless file && !file.empty? && meth && !meth.empty?

        key = [file, meth]
        rows << "| #{key.join(":")} | #{audit.findings.size} |"
      end
    end

    assert_empty audit.findings
    rows
  end
end
