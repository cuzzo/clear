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
end
