# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "rexml/document"
require_relative "coverage_xml_branch_patch"

RSpec.describe CoverageXmlBranchPatch do
  it "rewrites SimpleCov Cobertura output to decision-level partial branch lines" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "src", "worker.rb")
      xml_path = File.join(dir, "coverage.xml")
      FileUtils.mkdir_p(File.dirname(source))
      File.write(source, "if flag\n  1\nelse\n  2\nend\n")
      File.write(xml_path, <<~XML)
        <?xml version="1.0"?>
        <coverage line-rate="1.0" branch-rate="1.0" branches-covered="2" branches-valid="2">
          <packages>
            <package name="default" line-rate="1.0" branch-rate="1.0">
              <classes>
                <class name="src/worker.rb" filename="src/worker.rb" line-rate="1.0" branch-rate="1.0">
                  <lines>
                    <line number="1" hits="1" branch="false"/>
                    <line number="2" hits="1" branch="true" condition-coverage="100% (1/1)">
                      <conditions><condition number="0" type="jump" coverage="100%"/></conditions>
                    </line>
                    <line number="4" hits="0" branch="true" condition-coverage="0% (0/1)">
                      <conditions><condition number="0" type="jump" coverage="0%"/></conditions>
                    </line>
                  </lines>
                </class>
              </classes>
            </package>
          </packages>
        </coverage>
      XML

      payload = {
        "coverage" => {
          source => {
            "branches" => {
              "[:if, 0, 1, 0, 5, 3]" => {
                "[:then, 1, 2, 2, 2, 3]" => 1,
                "[:else, 2, 4, 2, 4, 3]" => 0,
              },
            },
          },
        },
      }

      totals = described_class.apply(xml_path: xml_path, result_payload: payload, root: dir)
      document = REXML::Document.new(File.read(xml_path))
      decision_line = REXML::XPath.first(document, "//line[@number='1']")
      old_then_arm = REXML::XPath.first(document, "//line[@number='2']")
      old_else_arm = REXML::XPath.first(document, "//line[@number='4']")
      condition = REXML::XPath.first(document, "//line[@number='1']/conditions/condition")

      expect(totals).to eq(files: 1, branches_valid: 2, branches_covered: 1)
      expect(decision_line.attributes["branch"]).to eq("true")
      expect(decision_line.attributes["condition-coverage"]).to eq("50% (1/2)")
      expect(condition.attributes["coverage"]).to eq("50%")
      expect(old_then_arm.attributes["branch"]).to eq("false")
      expect(old_then_arm.attributes["condition-coverage"]).to be_nil
      expect(old_else_arm.attributes["branch"]).to eq("false")
      expect(old_else_arm.attributes["condition-coverage"]).to be_nil
      expect(document.root.attributes["branches-covered"]).to eq("1")
      expect(document.root.attributes["branches-valid"]).to eq("2")
      expect(document.root.attributes["branch-rate"]).to eq("0.5")
    end
  end

  it "combines multiple branch decisions on the same source line" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "src", "worker.rb")
      xml_path = File.join(dir, "coverage.xml")
      FileUtils.mkdir_p(File.dirname(source))
      File.write(source, "return a || b ? 1 : 2\n")
      File.write(xml_path, <<~XML)
        <coverage line-rate="1.0" branch-rate="0.0" branches-covered="0" branches-valid="0">
          <packages>
            <package name="default" line-rate="1.0" branch-rate="0.0">
              <classes>
                <class name="src/worker.rb" filename="src/worker.rb" line-rate="1.0" branch-rate="0.0">
                  <lines><line number="1" hits="1" branch="false"/></lines>
                </class>
              </classes>
            </package>
          </packages>
        </coverage>
      XML

      payload = {
        "coverage" => {
          source => {
            "branches" => {
              "[:if, 0, 1, 7, 1, 20]" => {
                "[:then, 1, 1, 16, 1, 17]" => 1,
                "[:else, 2, 1, 20, 1, 21]" => 0,
              },
              "[:if, 3, 1, 7, 1, 13]" => {
                "[:then, 4, 1, 7, 1, 8]" => 1,
                "[:else, 5, 1, 12, 1, 13]" => 1,
              },
            },
          },
        },
      }

      described_class.apply(xml_path: xml_path, result_payload: payload, root: dir)
      document = REXML::Document.new(File.read(xml_path))
      line = REXML::XPath.first(document, "//line[@number='1']")

      expect(line.attributes["condition-coverage"]).to eq("75% (3/4)")
      expect(document.root.attributes["branches-covered"]).to eq("3")
      expect(document.root.attributes["branches-valid"]).to eq("4")
      expect(document.root.attributes["branch-rate"]).to eq("0.75")
    end
  end

  it "adds missing control-flow line nodes when Cobertura omits branch parents" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "src", "lexer.rb")
      xml_path = File.join(dir, "coverage.xml")
      FileUtils.mkdir_p(File.dirname(source))
      File.write(source, "case\nwhen true then :ok\nelse :bad\nend\n")
      File.write(xml_path, <<~XML)
        <coverage line-rate="1.0" branch-rate="0.0" branches-covered="0" branches-valid="0">
          <packages>
            <package name="default" line-rate="1.0" branch-rate="0.0">
              <classes>
                <class name="src/lexer.rb" filename="src/lexer.rb" line-rate="1.0" branch-rate="0.0">
                  <lines>
                    <line number="2" hits="1" branch="false"/>
                    <line number="3" hits="0" branch="false"/>
                  </lines>
                </class>
              </classes>
            </package>
          </packages>
        </coverage>
      XML

      payload = {
        "coverage" => {
          source => {
            "branches" => {
              "[:case, 0, 1, 0, 4, 3]" => {
                "[:when, 1, 2, 0, 2, 18]" => 1,
                "[:else, 2, 3, 0, 3, 9]" => 0,
              },
            },
          },
        },
      }

      totals = described_class.apply(xml_path: xml_path, result_payload: payload, root: dir)
      document = REXML::Document.new(File.read(xml_path))
      case_line = REXML::XPath.first(document, "//line[@number='1']")

      expect(totals).to eq(files: 1, branches_valid: 2, branches_covered: 1)
      expect(case_line.attributes["hits"]).to eq("1")
      expect(case_line.attributes["branch"]).to eq("true")
      expect(case_line.attributes["condition-coverage"]).to eq("50% (1/2)")
    end
  end
end
