require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# `MATCH u START U.A AS MUTABLE item -> ...` binds the arm payload by mutable
# reference. Without it a union's payload cannot be written at all: the plain
# `AS` binding is a borrow of a copy, so field writes are rejected and, if they
# were allowed, would be lost.
RSpec.describe "MATCH arm mutable payload binding" do
  def parse(src)
    ClearParser.new(Lexer.new(src).tokenize, src).parse
  end

  let(:prelude) {
    <<~CLEAR
      STRUCT A { line: Int64 }
      STRUCT B { line: Int64 }
      UNION U { A: A, B: B }
    CLEAR
  }

  it "parses the MUTABLE arm binding and marks the case" do
    ast = parse(prelude + <<~CLEAR)
      FN setLine(MUTABLE u: U, value: Int64) RETURNS Void ->
        PARTIAL MATCH u START
          U.A AS MUTABLE item -> item.line = value;,
          U.B AS item -> value = value;
        END
      END
    CLEAR
    match_stmt = ast.statements.last.body.first
    expect(match_stmt.cases.map(&:binding)).to eq(%w[item item])
    expect(match_stmt.cases.map { |c| c.binding_mutable == true }).to eq([true, false])
  end

  it "captures the payload by pointer so writes reach the subject" do
    zig = ZigTranspiler.new.transpile(prelude + <<~CLEAR)
      FN setLine(MUTABLE u: U, value: Int64) RETURNS Void ->
        PARTIAL MATCH u START
          U.A AS MUTABLE item -> item.line = value;
        END
      END
    CLEAR
    expect(zig).to match(/\|\*__match_payload_\d+\|/)
  end

  it "still captures by value for a plain AS binding" do
    zig = ZigTranspiler.new.transpile(prelude + <<~CLEAR)
      FN readLine(u: U) RETURNS Int64 ->
        PARTIAL MATCH u START
          U.A AS item -> RETURN item.line;
        END
        RETURN 0;
      END
    CLEAR
    expect(zig).to match(/\|__match_payload_\d+\|/)
    expect(zig).not_to match(/\|\*__match_payload_\d+\|/)
  end

  it "rejects a mutable binding on an immutable subject" do
    src = prelude + <<~CLEAR
      FN setLine(u: U, value: Int64) RETURNS Void ->
        PARTIAL MATCH u START
          U.A AS MUTABLE item -> item.line = value;
        END
      END
    CLEAR
    expect { SemanticAnnotator.new.annotate!(parse(src)) }
      .to raise_error(/immutable/i)
  end
end
