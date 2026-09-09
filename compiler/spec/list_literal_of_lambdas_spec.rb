require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "a list literal of lambdas" do
  it "keeps the function shape instead of the lambda's return type" do
    source = <<~CLEAR
      STRUCT D { name: String }
      FN run(branches: []FN() -> ?[]D) RETURNS Int64 ->
        RETURN branches.length();
      END
      FN main() RETURNS Int64 ->
        MUTABLE one: ?[]D = NIL;
        RETURN run([%() USE(one) -> one]);
      END
    CLEAR

    expect { ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd) }
      .not_to raise_error
  end
end
