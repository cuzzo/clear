require "open3"
require "rbconfig"

RSpec.describe "attr RBI generator" do
  it "emits SymbolEntry lifecycle and flow accessors from typed fact structs" do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "tools/gen_attr_rbi.rb")

    expect(status).to be_success, stderr
    expect(stdout).to include("def storage; end")
    expect(stdout).to include("sig { params(value: Symbol).returns(Symbol) }")
    expect(stdout).to include("def storage=(value); end")
    expect(stdout).to include("sig { returns(T::Boolean) }")
    expect(stdout).to include("def non_escaping; end")
    expect(stdout).to include("def valid; end")
    expect(stdout).not_to include("sig { params(value: Type).returns(Type) }\n  def type=(value); end")
  end
end
