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
      name: "typed set construction",
      ruby: <<~RUBY,
        values = T.let([:a, :b], T::Set[Symbol])
        Set.new(values)
      RUBY
      clear: <<~CLEAR,
        MUTABLE values: String@symbol[]@set = [.a, .b];
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
      send(:dynamic)
      ok
    RUBY
    expected_clear = <<~CLEAR
      MUTABLE ok = 1;
      # [UNSUPPORTED: CallNode at 2:0] send is a Ruby dynamic/reflection call: dynamic dispatch; replace with a closed case/table over known method names
      # send(:dynamic)
      ok;
    CLEAR
    expect_transpile(ruby_code, expected_clear, raise_on_error: false)
  end
end
