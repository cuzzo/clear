# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/slopcop"

class ConstraintsDynamicProviderTest < Minitest::Test
  def test_dynamic_providers_are_registered
    assert_same SlopCop::Constraints::RubyProvider, SlopCop::Constraints.providers.fetch("ruby")
    assert_same SlopCop::Constraints::PythonProvider, SlopCop::Constraints.providers.fetch("python")
    assert_same SlopCop::Constraints::JavascriptProvider, SlopCop::Constraints.providers.fetch("javascript")
    assert_same SlopCop::Constraints::TypescriptProvider, SlopCop::Constraints.providers.fetch("typescript")
    assert_same SlopCop::Constraints::LuaProvider, SlopCop::Constraints.providers.fetch("lua")
    assert_same SlopCop::Constraints::JavaProvider, SlopCop::Constraints.providers.fetch("java")
    assert_same SlopCop::Constraints::KotlinProvider, SlopCop::Constraints.providers.fetch("kotlin")
    assert_same SlopCop::Constraints::SwiftProvider, SlopCop::Constraints.providers.fetch("swift")
    assert_same SlopCop::Constraints::PhpProvider, SlopCop::Constraints.providers.fetch("php")
  end

  def test_packaged_hazard_contract_matches_monorepo_contract
    packaged = JSON.parse(File.read(File.expand_path("../config/hazard_contract.json", __dir__)))
    canonical = JSON.parse(File.read(File.expand_path("../../hazard-contract/contract.json", __dir__)))
    assert_equal canonical, packaged
  end

  def test_ruby_hazard_matcher_matches_contract_vectors
    contract = SlopCop::Constraints::FactMineProviderHelper.hazard_contract
    vectors = contract.fetch("matcher_vectors")
    refute_empty vectors

    vectors.each do |vector|
      actual = SlopCop::Constraints::FactMineProviderHelper.hazard_pattern_matches?(
        vector.fetch("pattern"), vector.fetch("value")
      )
      assert_equal vector.fetch("matches"), actual, vector.inspect
    end
  end

  def test_ruby_provider_finds_metaprogramming_hazard
    with_file("test.rb", <<~RB) do |dir, path|
      class Foo
        def perform
          self.send(:run)
          $1
        end
      end
    RB
      hazards = SlopCop::Constraints::RubyProvider.scan_hazards(repo: dir, paths: [path])
      types = hazards.map { |h| h[:hazard_type] }

      assert_includes types, "ruby_metaprogramming"
      assert_equal 2, hazards.size
      
      # Dynamic boundaries remain visible as review findings. Nil-kill evidence
      # records reachability but cannot satisfy the review requirement.
      evidence = SlopCop::Constraints::Evidence.from_specs([], repo: dir)
      findings = SlopCop::Constraints::RubyProvider.findings(repo: dir, additions: { path => [3] }, evidence: evidence)
      assert_equal 1, findings.size
      assert_includes findings.first.message, "requires review"
      assert_equal "nil-kill", findings.first.required_evidence

      # Write covered evidence (Cobertura XML covering line 3)
      xml_content = <<~XML
        <?xml version="1.0" ?>
        <coverage line-rate="1.0" branch-rate="1.0" version="1.9">
          <packages>
            <package name="test" line-rate="1.0" branch-rate="1.0">
              <classes>
                <class name="Foo" filename="test.rb" line-rate="1.0" branch-rate="1.0">
                  <methods/>
                  <lines>
                    <line number="3" hits="1" branch="false"/>
                  </lines>
                </class>
              </classes>
            </package>
          </packages>
        </coverage>
      XML
      xml_path = File.join(dir, "cobertura.xml")
      File.write(xml_path, xml_content)

      covered_evidence = SlopCop::Constraints::Evidence.from_specs(["nil-kill:#{xml_path}"], repo: dir)
      covered_findings = SlopCop::Constraints::RubyProvider.findings(repo: dir, additions: { path => [3] }, evidence: covered_evidence)
      assert_equal 1, covered_findings.size
      assert_includes covered_findings.first.message, "requires review"
    end
  end

  def test_javascript_provider_finds_metaprogramming_hazard
    with_file("test.js", <<~JS) do |dir, path|
      eval("1+1");
      const p = new Proxy({}, {});
      RegExp.$1;
    JS
      hazards = SlopCop::Constraints::JavascriptProvider.scan_hazards(repo: dir, paths: [path])
      types = hazards.map { |h| h[:hazard_type] }

      assert_includes types, "javascript_metaprogramming"
      assert_equal 3, hazards.size
    end
  end

  private

  def with_file(name, contents)
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      yield dir, name
    end
  end
end
