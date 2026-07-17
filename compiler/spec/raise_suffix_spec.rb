require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/tools/formatter" unless defined?(Formatter)

RSpec.describe "postfix error propagation" do
  def parse_expression_from(source)
    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    T.cast(program.statements.last, AST::FunctionDef).body.first
  end

  it "parses value!! as value OR_ELSE RAISE" do
    expression = parse_expression_from(<<~CLEAR)
      FN risky() RETURNS !Int64 -> RETURN 4; END
      FN main() RETURNS !Int64 -> RETURN risky()!!; END
    CLEAR

    returned = T.cast(expression, AST::ReturnNode)
    expect(returned.value).to be_a(AST::BinaryOp)
    expect(T.cast(returned.value, AST::BinaryOp).op).to eq(:OR_ELSE)
    expect(T.cast(returned.value, AST::BinaryOp).right).to be_a(AST::OrElseRaise)
  end

  it "continues postfix parsing after !! for raise-navigation" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN load() RETURNS !Box -> RETURN Box{ value: 7 }; END
      FN main() RETURNS Void -> ASSERT load()!!.value == 7; END
    CLEAR

    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to include("(try load()).value")
  end

  it "keeps & on a mutating method receiver beneath the raise suffix" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }
      IMPLEMENTATION Box {
        METHOD update(MUTABLE self) RETURNS !Void ->
          self.value = 7_i64;
        END
      }
      FN main() RETURNS Void ->
        MUTABLE box = Box{ value: 1_i64 };
        &box.update()!!;
        ASSERT box.value == 7_i64;
      END
    CLEAR

    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    main = T.must(program.statements.grep(AST::FunctionDef).find { |fn| fn.name == "main" })
    raised_call = T.cast(main.body.find { |node| node.is_a?(AST::BinaryOp) }, AST::BinaryOp)
    call = T.cast(raised_call.left, AST::MethodCall)
    expect(call.explicit_mutable_receiver?).to be(true)
    expect { ZigTranspiler.new.transpile(source) }.not_to raise_error
  end

  it "formats !!. without inserting separating whitespace" do
    formatted = Formatter.format(<<~CLEAR)
      FN load() RETURNS !Int64 -> RETURN 7; END
      FN main() RETURNS !Int64 -> RETURN load( ) !!; END
    CLEAR

    expect(formatted).to include("load()!!")
  end
end
