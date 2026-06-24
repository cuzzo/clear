# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::EspalierEvidence do
  it "writes compact static evidence with the fields Espalier consumes" do
    Dir.mktmpdir("nil-kill-espalier", NilKill::ROOT) do |dir|
      source = File.join(dir, "fast_evidence_client.rb")
      File.write(source, <<~RUBY)
        class FastEvidenceClient
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

      output = File.join(dir, "espalier-evidence.json")
      FileUtils.rm_rf(NilKill::RUNTIME_DIR)

      isolated_env("NIL_KILL_TARGETS" => dir) do
        expect {
          described_class.new(["--output", output]).run
        }.to output(/wrote Espalier static evidence/).to_stdout
      end

      evidence = JSON.parse(File.read(output))
      expect(evidence["kind"]).to eq("espalier_static_evidence")
      expect(evidence["runtime_fields"]).to eq(false)
      expect(evidence["actions"]).to be_nil
      expect(evidence.dig("facts", "ivar_runtime")).to eq([])
      # ivar_param_origins: not yet in Rust FactMine (Phase 3)
      # expect(evidence.dig("facts", "ivar_param_origins", "FastEvidenceClient\u0000@client")).to eq(["client"])
      expect(evidence.dig("facts", "ivar_protocols", "FastEvidenceClient\u0000@client")).to eq(["fetch"])

      signatures = evidence["methods"].filter_map { |method| method.dig("source", "sig") }
      expect(signatures).to include("sig { params(client: T.untyped).void }")
      expect(signatures).to include("sig { returns(String) }")
    end
  end

  it "is reachable from the nil-kill CLI without runtime evidence" do
    Dir.mktmpdir("nil-kill-espalier-cli", NilKill::ROOT) do |dir|
      source = File.join(dir, "cli_client.rb")
      File.write(source, <<~RUBY)
        class CliClient
          extend T::Sig

          sig { returns(String) }
          def call
            "ok"
          end
        end
      RUBY

      output = File.join(dir, "cli-evidence.json")
      FileUtils.rm_rf(NilKill::RUNTIME_DIR)

      isolated_env("NIL_KILL_TARGETS" => dir) do
        expect {
          NilKill::CLI.new(["espalier-evidence", "--output", output]).run
        }.to output(/wrote Espalier static evidence/).to_stdout
      end

      evidence = JSON.parse(File.read(output))
      expect(evidence.dig("summary", "methods")).to eq(1)
      expect(evidence.dig("summary", "signatures")).to eq(1)
    end
  end

  it "emits Tree-sitter static evidence for Zig targets" do
    # skip "Zig static evidence pending in Rust FactMine (Phase 3)"
    Espalier::TreeSitter.parser_for(:zig)

    Dir.mktmpdir("nil-kill-espalier-zig", NilKill::ROOT) do |dir|
      source = File.join(dir, "box.zig")
      File.write(source, <<~ZIG)
        pub fn Box(comptime T: type) type {
            return struct {
                value: T,
                count: usize = 0,
                const Self = @This();
                pub fn init(value: T) Self {
                    return .{ .value = value, .count = 1 };
                }
                pub fn get(self: *Self) T {
                    self.count = self.count + 1;
                    return self.value;
                }
            };
        }
      ZIG

      output = File.join(dir, "zig-evidence.json")

      expect {
        NilKill::CLI.new(["espalier-evidence", "--tree-sitter", "--output", output, dir]).run
      }.to output(/wrote Espalier static evidence/).to_stdout

      evidence = JSON.parse(File.read(output))
      expect(evidence["schema_version"]).to eq(2)
      expect(evidence.dig("summary", "methods")).to eq(3)
      expect(evidence.dig("facts", "state_types", "Box\u0000value")).to eq("T")
      expect(evidence.dig("facts", "state_param_origins", "Box\u0000value")).to eq(["value"])
      expect(evidence["methods"].map { |method| [method["owner"], method["name"], method["language"]] })
        .to include(["Box", "get", "zig"])
    end
  end
end
