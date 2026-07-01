# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::HiddenEnumPressure do
  def write_sample(dir, name, body)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  it "reports a high-confidence method param with a closed symbol decision set" do
    Dir.mktmpdir("nil-kill-hidden-enum", NilKill::ROOT) do |dir|
      path = write_sample(dir, "workflow.rb", <<~RUBY)
        class Workflow
          extend T::Sig

          sig { params(status: Symbol).returns(String) }
          def label(status)
            case status
            when :pending
              "pending"
            when :active
              "active"
            when :archived
              "archived"
            end
          end
        end
      RUBY

      rows = described_class.scan([path])

      expect(rows).to contain_exactly(a_hash_including(
        "kind" => "param",
        "owner" => "Workflow",
        "method" => "label",
        "slot" => "status",
        "type" => "Symbol",
        "values" => %w[:active :archived :pending],
        "primitive_kinds" => ["Symbol"],
        "confidence" => "high",
        "decision_pressure" => 3
      ))
    end
  end

  it "combines equality and membership decisions for string slots" do
    Dir.mktmpdir("nil-kill-hidden-enum", NilKill::ROOT) do |dir|
      path = write_sample(dir, "router.rb", <<~RUBY)
        class Router
          extend T::Sig

          sig { params(mode: String).returns(T::Boolean) }
          def allowed?(mode)
            return true if mode == "fast"

            ["safe", "slow"].include?(mode)
          end
        end
      RUBY

      row = described_class.scan([path]).fetch(0)

      expect(row).to include(
        "slot" => "mode",
        "values" => ['"fast"', '"safe"', '"slow"'],
        "primitive_kinds" => ["String"],
        "confidence" => "high",
        "decision_pressure" => 3
      )
      expect(row.fetch("decisions").map { |site| site["kind"] }).to include("==", "include?")
    end
  end

  it "keeps dynamic/open-world producers as review blockers instead of high confidence" do
    Dir.mktmpdir("nil-kill-hidden-enum", NilKill::ROOT) do |dir|
      path = write_sample(dir, "stateful.rb", <<~RUBY)
        class Stateful
          def load
            @state = ENV["STATE"]
          end

          def ready?
            case @state
            when :open
              true
            when :closed
              false
            end
          end
        end
      RUBY

      row = described_class.scan([path]).fetch(0)

      expect(row).to include(
        "kind" => "state",
        "owner" => "Stateful",
        "slot" => "@state",
        "values" => %w[:closed :open],
        "confidence" => "review"
      )
      expect(row.fetch("blockers")).to include(a_hash_including("kind" => "open-world producer"))
    end
  end

  it "uses legacy runtime class evidence as support without inventing runtime values" do
    Dir.mktmpdir("nil-kill-hidden-enum", NilKill::ROOT) do |dir|
      path = write_sample(dir, "runtime_supported.rb", <<~RUBY)
        class RuntimeSupported
          extend T::Sig

          sig { params(status: Symbol).void }
          def apply(status)
            status == :on || status == :off
          end
        end
      RUBY
      rel = NilKill.rel(path)
      evidence = {
        "methods" => [{
          "calls" => 12,
          "params_by_name" => {"status" => ["Symbol"]},
          "source" => {
            "path" => rel,
            "line" => 5,
            "class" => "RuntimeSupported",
            "method" => "apply",
            "kind" => "instance",
          },
        }],
      }

      row = described_class.scan([path], evidence: evidence).fetch(0)

      expect(row.fetch("runtime")).to include(
        "calls" => 12,
        "classes" => ["Symbol"]
      )
      expect(row.fetch("values")).to contain_exactly(":off", ":on")
    end
  end

  it "loads persisted hidden enum observations without rescanning source" do
    observations = [
      {
        "key" => "slot-1",
        "kind" => "param",
        "path" => "src/workflow.rb",
        "line" => "12",
        "owner" => "Workflow",
        "method" => "transition",
        "method_kind" => "instance",
        "slot" => "state",
        "type" => "T.untyped",
        "event" => "decision",
        "values" => [{ "kind" => "Symbol", "value" => ":draft" }, { "kind" => "Symbol", "value" => ":sent" }],
        "site" => { "path" => "src/workflow.rb", "line" => 13, "kind" => "case" },
      },
      {
        "key" => "slot-1",
        "kind" => "param",
        "path" => "src/workflow.rb",
        "line" => "12",
        "owner" => "Workflow",
        "method" => "transition",
        "method_kind" => "instance",
        "slot" => "state",
        "type" => "T.untyped",
        "event" => "producer",
        "values" => [{ "kind" => "Symbol", "value" => ":archived" }],
        "site" => { "path" => "src/workflow.rb", "line" => 10, "kind" => "producer" },
      },
      {
        "key" => "slot-1",
        "kind" => "param",
        "path" => "src/workflow.rb",
        "line" => "12",
        "owner" => "Workflow",
        "method" => "transition",
        "method_kind" => "instance",
        "slot" => "state",
        "type" => "T.untyped",
        "event" => "blocker",
        "site" => { "path" => "src/workflow.rb", "line" => 9, "kind" => "open-world producer" },
      },
    ]
    evidence = {
      "facts" => { "hidden_enum_observations" => observations },
      "methods" => [{
        "calls" => 5,
        "params_by_name" => { "state" => ["Symbol"] },
        "source" => {
          "path" => "src/workflow.rb",
          "line" => 12,
          "class" => "Workflow",
          "method" => "transition",
          "kind" => "instance",
        },
      }],
    }

    row = described_class.scan(["/definitely/missing.rb"], evidence: evidence).fetch(0)

    expect(row).to include(
      "values" => %w[:archived :draft :sent],
      "primitive_kinds" => ["Symbol"],
      "confidence" => "review",
      "decision_pressure" => 2
    )
    expect(row.fetch("runtime")).to include("calls" => 5, "classes" => ["Symbol"])
    expect(row.fetch("blockers")).to include(a_hash_including("kind" => "open-world producer"))
  end

  it "tracks aliases, defaults, class variables, literal-left comparisons, and dynamic blockers" do
    Dir.mktmpdir("nil-kill-hidden-enum-advanced", NilKill::ROOT) do |dir|
      path = write_sample(dir, "advanced.rb", <<~RUBY)
        class Advanced
          extend T::Sig

          sig do
            params(mode: T.any(String, Symbol), state: T.untyped, source: String).void
          end
          def call(mode = :draft, state:, source: "manual")
            alias_mode = T.must(mode)
            return if "manual" == alias_mode

            [:draft, :queued].member?(alias_mode)
            @state = "\#{source}-suffix"
            @@global_state = File.read("state.txt")

            case @state
            when "ready"
              true
            when "done"
              false
            end

            case @@global_state
            when :open
              true
            when :closed
              false
            end
          end
        end
      RUBY

      rows = described_class.scan([path])
      mode = rows.find { |row| row["slot"] == "mode" }
      state = rows.find { |row| row["slot"] == "@state" }
      global = rows.find { |row| row["slot"] == "@@global_state" }

      expect(mode).to include(
        "values" => ['"manual"', ":draft", ":queued"],
        "primitive_kinds" => %w[String Symbol],
        "confidence" => "high"
      )
      expect(state.fetch("blockers")).to include(a_hash_including("kind" => "dynamic primitive producer"))
      expect(global.fetch("blockers")).to include(a_hash_including("kind" => "open-world producer"))
    end
  end

  it "does not report a single literal check as an enum candidate" do
    Dir.mktmpdir("nil-kill-hidden-enum", NilKill::ROOT) do |dir|
      path = write_sample(dir, "single.rb", <<~RUBY)
        class Single
          def active?(status)
            status == :active
          end
        end
      RUBY

      expect(described_class.scan([path])).to be_empty
    end
  end
end

RSpec.describe NilKill::Report, "hidden enum pressure" do
  it "renders hidden enum rows without requiring rewrite actions" do
    evidence = {
      "facts" => {
        "hidden_enum_pressure" => [{
          "path" => "src/workflow.rb",
          "line" => 10,
          "owner" => "Workflow",
          "method" => "label",
          "method_kind" => "instance",
          "kind" => "param",
          "slot" => "status",
          "confidence" => "high",
          "score" => 12,
          "values" => %w[:active :pending],
          "decision_pressure" => 2,
          "runtime" => {"calls" => 5, "classes" => ["Symbol"]},
          "blockers" => [],
          "suggestion" => "review for a named Status enum or literal-union contract",
          "decisions" => [{
            "path" => "src/workflow.rb",
            "line" => 11,
            "kind" => "case",
            "code" => "case status",
          }],
        }],
      },
    }
    lines = []

    described_class.new.send(:append_hidden_enum_pressure_report, lines, evidence)

    expect(lines.join("\n")).to include("## Hidden Enum Pressure (1)")
    expect(lines.join("\n")).to include("Workflow#label param `status`")
    expect(lines.join("\n")).to include("values :active, :pending")
    expect(lines.join("\n")).to include("runtime 5 call(s), classes Symbol")
  end
end
