# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Ruby-to-CLEAR oracle corpus" do
  def expect_transpile(ruby_code, expected_clear, raise_on_error: true)
    result = RubyToClear.transpile(ruby_code, raise_on_error: raise_on_error)
    expect(result.strip).to eq(expected_clear.strip)
  end

  ORACLE_CASES = [
    {
      name: "typed file read pipeline",
      ruby: <<~RUBY,
        sig { params(path: String).returns(T::Array[String]) }
        def read_names(path)
          File.readlines(path).map { |line| line.strip }
        end
      RUBY
      clear: <<~CLEAR,
        REQUIRE "pkg:fs"
        FN read_names(path: String) RETURNS !String[] ->
          (readLines(path) OR RAISE) |> SELECT _.trim();
        END
      CLEAR
    },
    {
      name: "shape tracked file pipeline result",
      ruby: <<~RUBY,
        sig { params(path: String).returns(Integer) }
        def count_names(path)
          lines = File.readlines(path)
          names = lines.map { |line| name = line.strip; name }
          names.size
        end
      RUBY
      clear: <<~CLEAR,
        REQUIRE "pkg:fs"
        FN count_names(path: String) RETURNS !Int64 ->
          MUTABLE lines = readLines(path) OR RAISE;
          MUTABLE names = lines |> SELECT {
          MUTABLE name = _.trim();
          name
          };
          names.length();
        END
      CLEAR
    },
    {
      name: "typed set construction",
      ruby: <<~RUBY,
        values = T.let([:a, :b], T::Set[Symbol])
        Set.new(values)
      RUBY
      clear: <<~CLEAR,
        MUTABLE values: String[]@set = [:a, :b];
        values |> DISTINCT _;
      CLEAR
    },
    {
      name: "field-only T::Struct plus constructor",
      ruby: <<~RUBY,
        class Config < T::Struct
          const :path, String
          prop :count, Integer
        end

        config = Config.new("x", 1)
      RUBY
      clear: <<~CLEAR,
        STRUCT Config {
          path: String,
          count: Int64
        }
        MUTABLE config = Config{ path: "x", count: 1 };
      CLEAR
    },
  ].freeze

  ORACLE_CASES.each do |test_case|
    it "transpiles #{test_case.fetch(:name)}" do
      expect_transpile(test_case.fetch(:ruby), test_case.fetch(:clear))
    end
  end

  it "keeps dynamic Ruby blockers localized in repair mode" do
    ruby_code = <<~RUBY
      ok = 1
      method_name = :dynamic
      send(method_name)
      ok
    RUBY
    expected_clear = <<~CLEAR
      MUTABLE ok = 1;
      MUTABLE method_name = :dynamic;
      unsupportedRuby("CallNode at 3:0: send requires a static symbol or string method name");
      ok;
    CLEAR
    expect_transpile(ruby_code, expected_clear, raise_on_error: false)
  end
end
