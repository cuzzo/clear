# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::SlotCoverage do
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
end
