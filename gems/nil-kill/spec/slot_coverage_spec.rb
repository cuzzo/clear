# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::SlotCoverage do
  it "matches singleton methods to their normalized signature definitions" do
    path, = repo_tmp_file("slot_coverage_singleton_fixture.rb", <<~RUBY)
      module SlotCoverageSingletonFixture
        sig { params(value: String).returns(Integer) }
        def self.measure(value)
          value.length
        end
      end
    RUBY

    summary = described_class.new([path]).summaries.fetch(0)

    expect(summary.fetch("params")).to include("total" => 1, "strong" => 1, "untyped" => 0)
    expect(summary.fetch("returns")).to include("total" => 1, "strong" => 1, "untyped" => 0)
  end

  it "keeps the richer signature when FactMine emits duplicate path forms" do
    coverage = described_class.new([])
    sparse = {
      "kind" => "method_signature", "path" => "sample.rb", "owner" => "Sample",
      "name" => "initialize", "params" => [],
    }
    rich = sparse.merge(
      "path" => File.join(NilKill::ROOT, "sample.rb"),
      "params" => [{ "name" => "value", "type" => "String" }],
      "return_type" => "NilClass"
    )
    evidence = { "facts" => { "type_definitions" => [rich, sparse] } }
    coverage.send(:relativize_paths!, evidence, NilKill::ROOT)

    index = coverage.send(:method_signature_index, evidence)

    expect(index.fetch(["sample.rb", "Sample", "initialize"])).to eq(rich)
  end

  it "uses types carried directly by struct declarations" do
    coverage = described_class.new([])
    evidence = {
      "facts" => {
        "type_definitions" => [],
        "struct_declarations" => [{
          "path" => "sample.rb", "class" => "Sample::Record",
          "fields" => ["name"], "field_types" => { "name" => "String" },
        }],
      },
    }

    index = coverage.send(:field_type_index, evidence)
    type = coverage.send(:field_type_for, index, {
      "path" => "sample.rb", "owner" => "Sample::Record", "name" => "name",
    })

    expect(type).to eq("String")
  end

  it "does not assign built-in types from repeated project slot names" do
    path, = repo_tmp_file("slot_coverage_names_fixture.rb", <<~RUBY)
      class SlotCoverageNamesFixture
        Record = Struct.new(:name, :line, :body)
      end
    RUBY

    summary = described_class.new([path]).summaries.fetch(0)

    expect(summary.fetch("struct_fields")).to include("total" => 3, "strong" => 0, "weak" => 0, "untyped" => 3)
  end

  it "applies explicit slot type override rules when a project opts in" do
    path, = repo_tmp_file("slot_coverage_override_fixture.rb", <<~RUBY)
      class SlotCoverageOverrideFixture
        Record = Struct.new(:payload)
      end
    RUBY
    config, = repo_tmp_file("slot_coverage_overrides.json", JSON.generate({
      "slot_types" => [
        {
          "path" => "slot_coverage_override_fixture\\.rb\\z",
          "name" => "\\Apayload\\z",
          "type" => "String"
        }
      ]
    }))

    isolated_env("NIL_KILL_SLOT_TYPE_OVERRIDES" => config) do
      summary = described_class.new([path]).summaries.fetch(0)

      expect(summary.fetch("struct_fields")).to include("total" => 1, "strong" => 1, "weak" => 0, "untyped" => 0)
    end
  end

  it "reports static type distributions for repeated untyped slot names" do
    path, = repo_tmp_file("slot_coverage_hint_fixture.rb", <<~RUBY)
      class SlotCoverageHintFixture
        sig { params(node: AST::Node, payload: Alpha).void }
        def first(node, payload); end

        sig { params(node: AST::Node, payload: Beta).void }
        def second(node, payload); end

        sig { params(node: MIR::Node, payload: Gamma).void }
        def third(node, payload); end

        sig { params(node: ExtraNode, payload: Delta).void }
        def fourth(node, payload); end

        sig { params(node: MIR::Node, payload: Epsilon).void }
        def fifth(node, payload); end

        def missing_one(node, payload); end
        def missing_two(node, payload); end
      end
    RUBY

    rows = described_class.new([path]).analysis.fetch("top_untyped_slot_names")
    node = rows.find { |row| row["name"] == "node" }
    payload = rows.find { |row| row["name"] == "payload" }

    expect(node).to include("count" => 2, "typed_total" => 5)
    expect(node.fetch("typed_hints")).to eq([
      { "type" => "AST::Node", "count" => 2, "percent" => 40.0 },
      { "type" => "MIR::Node", "count" => 2, "percent" => 40.0 },
      { "type" => "Other", "count" => 1, "percent" => 20.0 },
    ])
    expect(payload).to include("count" => 2, "typed_total" => 5)
    expect(payload).not_to have_key("typed_hints")
  end

  it "includes repeated untyped hash fields in slot-name pressure" do
    path, = repo_tmp_file("slot_coverage_hash_field_fixture.rb", <<~RUBY)
      class SlotCoverageHashFieldFixture
        def first
          { token: compute_token, name: "ready" }
        end

        def second
          { token: other_token, name: "done" }
        end
      end
    RUBY

    rows = described_class.new([path]).analysis.fetch("top_untyped_slot_names")
    token = rows.find { |row| row["name"] == "token" }

    expect(token).to include("count" => 2)
    expect(token.fetch("categories")).to include("hash_field" => 2)
    expect(token.fetch("examples")).to include(match(/hash field token/))
    expect(token.fetch("typed_total")).to eq(0)
  end

  it "does not report hash fields whose literal values have typed shapes" do
    path, = repo_tmp_file("slot_coverage_typed_hash_field_fixture.rb", <<~RUBY)
      class SlotCoverageTypedHashFieldFixture
        ERROR_ID = 12

        def first
          { codes: %i[A B], id: ERROR_ID, col: 7, name: "ready" }
        end

        def second
          { codes: %i[C D], id: ERROR_ID, col: 8, name: "done" }
        end
      end
    RUBY

    rows = described_class.new([path]).analysis.fetch("top_untyped_slot_names")

    expect(rows.map { |row| row["name"] }).not_to include("codes", "id", "col", "name")
  end

  it "credits typed accessors from included modules to Ruby struct fields" do
    path, = repo_tmp_file("slot_coverage_included_accessor_fixture.rb", <<~RUBY)
      module IncludedAccessorFixture
        module DropField
          extend T::Sig

          sig { returns(T::Array[String]) }
          def drops
            self[:drops] ||= []
          end
        end

        Item = Struct.new(:drops) do
          include DropField
        end
      end
    RUBY

    summary = described_class.new([path]).summaries.fetch(0)
    rows = described_class.new([path]).analysis.fetch("top_untyped_slot_names")

    expect(summary.fetch("struct_fields")).to include("total" => 1, "strong" => 1, "weak" => 0, "untyped" => 0)
    expect(rows.map { |row| row["name"] }).not_to include("drops")
  end

  it "qualifies Ruby struct owners under modules without popping on method ends" do
    path, = repo_tmp_file("slot_coverage_nested_structs.rb", <<~RUBY)
      module Sample
        def self.helper
          :ok
        end

        module Nested
          Item = Struct.new(:token)
        end

        Item = Struct.new(:token) do
          extend T::Sig

          sig { returns(String) }
          def token
            self[:token].to_s
          end
        end

        class Record < T::Struct
          const :value, String

          def helper
            :ok
          end

          prop :after_method, Integer
        end
      end
    RUBY

    type_definitions = NilKill::StaticEvidence.build([path], root: NilKill::ROOT)
                                             .dig("facts", "type_definitions")

    expect(type_definitions).to include(a_hash_including(
      "kind" => "state_field",
      "owner" => "Sample::Item",
      "name" => "token",
      "type_system" => "ruby-struct"
    ))
    expect(type_definitions).to include(a_hash_including(
      "kind" => "state_field",
      "owner" => "Sample::Nested::Item",
      "name" => "token",
      "type_system" => "ruby-struct"
    ))
    expect(type_definitions).not_to include(a_hash_including(
      "owner" => "Sample::Sample::Nested::Item"
    ))
    expect(type_definitions).to include(a_hash_including(
      "kind" => "method_signature",
      "owner" => "Sample::Item",
      "name" => "token",
      "return_type" => "String"
    ))
    expect(type_definitions).to include(a_hash_including(
      "kind" => "state_field",
      "owner" => "Sample::Record",
      "name" => "value",
      "declared_type" => "String",
      "type_system" => "sorbet"
    ))
    expect(type_definitions).to include(a_hash_including(
      "kind" => "state_field",
      "owner" => "Sample::Record",
      "name" => "after_method",
      "declared_type" => "Integer",
      "type_system" => "sorbet"
    ))
  end

  it "counts typed, weak, and untyped slots per file without regex source scanning" do
    path, rel = repo_tmp_file("slot_coverage_fixture.rb", <<~RUBY)
      class CoverageFixture
        Pair = Struct.new(:left, :right)

        class Record < T::Struct
          const :name, String
          prop :items, T::Array[String]
          prop :payload, T::Hash[String, T.untyped]
        end

        sig { params(name: String, data: T.untyped, items: T::Array[T.untyped]).returns(T::Array[String]) }
        def build(name, data, items)
          @name = T.let(name, String)
          @raw = T.let({}, T::Hash[String, T.untyped])
          @late = 1
          items
        end

        sig { void }
        def reset
          @name = "reset"
        end

        def unsigned(value)
          value
        end
      end
    RUBY

    summary = described_class.new([path]).summaries.fetch(0)

    expect(summary.fetch("path")).to eq(rel)
    expect(summary.fetch("params")).to include("total" => 4, "strong" => 1, "weak" => 1, "untyped" => 2)
    expect(summary.fetch("returns")).to include("total" => 3, "strong" => 2, "weak" => 0, "untyped" => 1)
    expect(summary.fetch("ivars")).to include("total" => 3, "strong" => 1, "weak" => 1, "untyped" => 1)
    expect(summary.fetch("struct_fields")).to include("total" => 5, "strong" => 2, "weak" => 1, "untyped" => 2)
    expect(summary.fetch("arrays")).to include("total" => 3, "strong" => 2, "weak" => 1, "untyped" => 0)
    expect(summary.fetch("hashes")).to include("total" => 2, "strong" => 0, "weak" => 2, "untyped" => 0)
    expect(summary.fetch("structural")).to include("total" => 15, "strong" => 6, "weak" => 3, "untyped" => 6)
    expect(summary.fetch("typed_percent")).to eq(40.0)
  end

  it "rolls up totals across files" do
    first, = repo_tmp_file("slot_coverage_first.rb", <<~RUBY)
      class FirstCoverageFixture
        sig { returns(String) }
        def name = "name"
      end
    RUBY
    second, = repo_tmp_file("slot_coverage_second.rb", <<~RUBY)
      class SecondCoverageFixture
        def value = 1
      end
    RUBY

    summaries = described_class.new([first, second]).summaries
    total = described_class.totals(summaries)

    expect(total.fetch("structural")).to include("total" => 2, "strong" => 1, "weak" => 0, "untyped" => 1)
    expect(total.fetch("typed_percent")).to eq(50.0)
  end

  it "normalizes slot types" do
    sc = described_class.new([])
    expect(sc.send(:normalize_slot_type, "Array")).to eq("T::Array[T.untyped]")
    expect(sc.send(:normalize_slot_type, "Hash")).to eq("T::Hash[T.untyped, T.untyped]")
    expect(sc.send(:normalize_slot_type, "Set")).to eq("T::Set[T.untyped]")
    expect(sc.send(:normalize_slot_type, "Any")).to eq("T.untyped")
    expect(sc.send(:strip_nilable_type, "T.nilable(String)")).to eq("String")
    expect(sc.send(:strip_nilable_type, "Optional[Integer]")).to eq("Integer")
  end

  it "exercises class-level entrypoints" do
    target = "gems/nil-kill/lib/nil_kill/slot_coverage.rb"
    expect(described_class.files_for([target])).to be_an(Array)
    expect(described_class.scan([target])).to be_an(Array)
    expect(described_class.analyze([target])).to be_a(Hash)
  end

  it "raises errors on invalid overrides configuration" do
    config1, = repo_tmp_file("slot_coverage_invalid.json", "{invalid json")
    isolated_env("NIL_KILL_SLOT_TYPE_OVERRIDES" => config1) do
      expect { described_class.new([]) }.to raise_error(ArgumentError, /invalid NIL_KILL_SLOT_TYPE_OVERRIDES/)
    end

    config2, = repo_tmp_file("slot_coverage_invalid2.json", JSON.generate({ "owner_aliases" => ["not a hash"] }))
    isolated_env("NIL_KILL_SLOT_TYPE_OVERRIDES" => config2) do
      expect { described_class.new([]) }.to raise_error(ArgumentError, /expected object/)
    end

    config3, = repo_tmp_file("slot_coverage_invalid3.json", JSON.generate({ "owner_aliases" => [{}] }))
    isolated_env("NIL_KILL_SLOT_TYPE_OVERRIDES" => config3) do
      expect { described_class.new([]) }.to raise_error(ArgumentError, /owner and qualified_owner are required/)
    end

    config4, = repo_tmp_file("slot_coverage_invalid4.json", JSON.generate({ "owner_aliases" => [{ "owner" => "[invalid regex", "qualified_owner" => "A" }] }))
    isolated_env("NIL_KILL_SLOT_TYPE_OVERRIDES" => config4) do
      expect { described_class.new([]) }.to raise_error(ArgumentError, /invalid owner pattern/)
    end

    config5, = repo_tmp_file("slot_coverage_invalid5.json", JSON.generate({ "slot_types" => [{}] }))
    isolated_env("NIL_KILL_SLOT_TYPE_OVERRIDES" => config5) do
      expect { described_class.new([]) }.to raise_error(ArgumentError, /name and type are required/)
    end
  end

  it "applies owner aliases rules" do
    config, = repo_tmp_file("slot_coverage_aliases.json", JSON.generate({
      "owner_aliases" => [
        {
          "owner" => "\\AUnqualified\\z",
          "qualified_owner" => "Qualified::Owner"
        }
      ]
    }))
    isolated_env("NIL_KILL_SLOT_TYPE_OVERRIDES" => config) do
      sc = described_class.new([])
      expect(sc.send(:qualified_owner, "path.rb", "Unqualified")).to eq("Qualified::Owner")
    end
  end
end
