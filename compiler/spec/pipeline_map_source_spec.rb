require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "a map as a pipeline source" do
  it "names the map instead of leaving the placeholder untyped" do
    source = <<~CLEAR
      STRUCT Stat { count: Int64 }
      FN main() RETURNS Int64 ->
        MUTABLE agg: {String@symbol}Stat = {};
        agg[:a] = Stat{ count: 3 };
        kept = agg |> WHERE (_.count == 3);
        RETURN kept.length();
      END
    CLEAR

    message = begin
      ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd)
      nil
    rescue CompilerError => e
      e.message
    end

    expect(message).to include("SELECT_NEEDS_LIST")
    expect(message).to include("HashMap<String@symbol,Stat>")
  end

  it "still accepts the map's keys" do
    source = <<~CLEAR
      STRUCT Stat { count: Int64 }
      FN main() RETURNS Int64 ->
        MUTABLE agg: {String@symbol}Stat = {};
        agg[:a] = Stat{ count: 3 };
        kept = agg.keys() |> WHERE ((UNWRAP (agg[_])).count == 3);
        RETURN kept.length();
      END
    CLEAR

    expect(ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd)).to include("fn main")
  end
end
