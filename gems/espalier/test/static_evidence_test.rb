# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/espalier"

class StaticEvidenceTest < Minitest::Test
  def test_builds_static_evidence_inside_espalier_without_nil_kill
    refute Object.const_defined?(:NilKill)

    Dir.mktmpdir("espalier-static", Dir.pwd) do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "client_user.rb"), <<~RUBY)
        class ClientUser
          extend T::Sig

          sig { params(client: T.untyped).void }
          def initialize(client)
            @client = client
          end

          sig { returns(String) }
          def call
            @client.fetch
          end
        end
      RUBY

      evidence = Espalier::StaticEvidence.build([src], root: dir)

      assert_equal "espalier_static_evidence", evidence["kind"]
      assert_equal 2, evidence.dig("summary", "methods")
      assert_equal ["client"], evidence.dig("facts", "state_param_origins", "ClientUser\u0000@client")
      assert_equal ["fetch"], evidence.dig("facts", "state_protocols", "ClientUser\u0000@client")
      assert_equal false, evidence.dig("language_capabilities", "ruby", "runtime_tracing")
    end
  end

  def test_skips_root_rbi_annotations_for_explicit_non_project_targets
    Dir.mktmpdir("espalier-static-rbi", Dir.pwd) do |dir|
      target = File.join(dir, "tmp_target")
      rbi = File.join(dir, "sorbet", "rbi")
      FileUtils.mkdir_p(target)
      FileUtils.mkdir_p(rbi)
      File.write(File.join(target, "worker.rb"), <<~RUBY)
        class Worker
          def call(value)
            value
          end
        end
      RUBY
      File.write(File.join(rbi, "generated.rbi"), <<~RBI)
        class Generated
          sig { returns(String) }
          def name; end
        end
      RBI

      evidence = Espalier::StaticEvidence.build([target], root: dir)
      rbi_definitions = evidence.dig("facts", "type_definitions").select do |definition|
        definition["path"].to_s.end_with?(".rbi")
      end

      assert_empty rbi_definitions
      assert_equal 0, evidence.dig("summary", "rbi_field_types")
    end
  end

  def test_static_builder_consumes_fact_mine_type_definitions
    Dir.mktmpdir("espalier-static-mined", Dir.pwd) do |dir|
      file = File.join(dir, "service.rb")
      mined = {
        "language" => "ruby",
        "type_system" => "sorbet",
        "kind" => "method_signature",
        "file" => file,
        "path" => file,
        "owner" => "Service",
        "name" => "call",
        "line" => 4,
        "signature" => "sig { returns(Result) }",
        "return_type" => "Result",
        "params" => []
      }
      document = OpenStruct.new(
        language: :ruby,
        file: file,
        lines: [],
        root: nil,
        type_definitions: [mined]
      )
      structural_facts = {
        function_defs: [],
        owner_defs: [],
        call_sites: [],
        state_declarations: [],
        state_writes: [],
        state_reads: [],
        state_param_origins: [],
        local_methods: [],
        comparison_sites: []
      }

      facts = Espalier::FactMineStaticFacts.build(document, structural_facts, root: dir)
      definition = facts.fetch(:type_definitions).first

      assert_equal "service.rb", definition["path"]
      assert_equal "Result", definition["return_type"]
      assert_includes definition["id"], "service.rb"
    end
  end
end
