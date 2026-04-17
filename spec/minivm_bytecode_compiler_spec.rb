require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../examples/minivm/bytecode_compiler"

RSpec.describe BytecodeCompiler do
  it "compiles BOOLEAN literals from the CLEAR parser" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
          flag = TRUE;
          RETURN;
      END
    CLEAR

    bytecode = described_class.new.compile_program(source)
    expect(bytecode[:consts]).to include([:bool, true])
  end
end
