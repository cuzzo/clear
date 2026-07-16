# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require_relative "../lib/espalier/nil_kill_evidence"

class NilKillEvidenceTest < Minitest::Test
  def test_load_and_apply
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nil_kill.json")
      payload = {
        "facts" => {
          "state_types" => {
            "Cov\u0000@state" => "String"
          },
          "state_param_origins" => {
            "Cov\u0000@state" => ["p"]
          },
          "state_protocols" => {
            "Cov\u0000@state" => ["each"]
          },
          "ivar_runtime" => [
            { "class" => "Cov", "name" => "@dynamic", "classes" => ["Integer", "String"] }
          ]
        },
        "methods" => [
          { "owner" => "Cov", "name" => "m1", "signature" => "sig { void }" },
          { "key" => ["Cov", "m2", "instance"], "source" => { "sig" => "sig { returns(String) }" } }
        ]
      }
      File.write(path, JSON.generate(payload))

      evidence = Espalier::NilKillEvidence.load(path)
      assert_equal "sig { void }", evidence.method_signatures["Cov#m1"]
      assert_equal "sig { returns(String) }", evidence.method_signatures["Cov#m2"]
      
      modules = [
        { name: "Cov", states: ["@state", "@dynamic"] }
      ]
      evidence.apply!(modules)
      
      cov = modules.first
      assert_equal "String", cov[:ivar_types]["@state"]
      assert_equal "T.any(Integer, String)", cov[:ivar_types]["@dynamic"]
      assert_includes cov[:ivar_properties]["@state"], "loaded from param: p"
      assert_includes cov[:ivar_properties]["@state"], "protocol interfaces: each"
    end
  end

  def test_empty_and_missing
    evidence = Espalier::NilKillEvidence.load(nil)
    assert_empty evidence.method_signatures
  end

  def test_load_rescue
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.json")
      File.write(path, "invalid json")
      evidence = Espalier::NilKillEvidence.load(path)
      assert_empty evidence.method_signatures
    end
  end

  def test_loads_aggregated_and_legacy_loop_rows
    Dir.mktmpdir do |dir|
      path = File.join(dir, "evidence.json")
      runtime = File.join(dir, "runtime")
      FileUtils.mkdir_p(runtime)
      File.write(path, JSON.generate("facts" => {}, "methods" => []))
      File.write(
        File.join(runtime, "loops-1.jsonl"),
        [
          JSON.generate("path" => "/src/work.rb", "line" => 9, "count" => 7),
          JSON.generate("path" => "/src/work.rb", "line" => 9),
        ].join("\n") + "\n"
      )

      evidence = Espalier::NilKillEvidence.load(path)

      assert_equal 8, evidence.loop_counts["/src/work.rb"][9]
    end
  end
end
