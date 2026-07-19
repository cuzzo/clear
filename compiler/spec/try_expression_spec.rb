require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/tools/formatter" unless defined?(Formatter)

RSpec.describe "TRY propagation" do
  def parse_expression_from(source)
    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    T.cast(program.statements.last, AST::FunctionDef).body.first
  end

  it "parses TRY as an explicit prefix propagation boundary" do
    expression = parse_expression_from(<<~CLEAR)
      FN risky() RETURNS !Int64 -> RETURN 4; END
      FN main() RETURNS !Int64 -> RETURN TRY risky(); END
    CLEAR

    returned = T.cast(expression, AST::ReturnNode)
    expect(returned.value).to be_a(AST::UnaryOp)
    expect(T.cast(returned.value, AST::UnaryOp).op).to eq(:TRY)
  end

  it "propagates a fallible result before ordinary field access" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN load() RETURNS !Box -> RETURN Box{ value: 7 }; END
      FN main() RETURNS !Int64 ->
        box = TRY load();
        RETURN box.value;
      END
    CLEAR

    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to include("try load()")
  end

  it "propagates the error layer while retaining the optional layer of !?T" do
    source = <<~CLEAR
      FN find(values: []Int64) RETURNS !?Int64 -> RETURN values[0]; END
      FN main(values: []Int64) RETURNS !?Int64 -> RETURN TRY find(values); END
    CLEAR

    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to include("try find(values)")
    expect(zig).not_to include("try find(values) orelse return error.TryOptional")
  end

  it "lets TRY of !?T participate in optional predicates" do
    source = <<~CLEAR
      FN maybe() RETURNS !?Int64 -> RETURN NIL; END
      FN main() RETURNS !Void ->
        IF (TRY maybe()) == NIL THEN RETURN; END
        RETURN;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.not_to raise_error
  end

  it "propagates a fallible intrinsic whose type channel is behavioral metadata" do
    source = <<~CLEAR
      FN main() RETURNS !Int64 -> RETURN TRY "42".toInt(); END
    CLEAR

    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to include("CheatLib.toInt")
  end

  it "uses the same recoverable-result fact for IS_OK and OR_ELSE" do
    source = <<~CLEAR
      FN main() RETURNS Int64 ->
        parsed = "not-a-number".toInt() OR_ELSE 17;
        ASSERT "42".toInt() IS_OK;
        RETURN parsed;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.not_to raise_error
  end

  it "allows explicit recovery from an allocation fault without making the value !T" do
    source = <<~CLEAR
      FN main() RETURNS String ->
        RETURN 3.toString() OR_ELSE "fallback";
      END
    CLEAR

    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to include("catch")
    expect(zig).to include("fallback")
    expect(zig).not_to match(/return try .*intToString/)
  end

  it "does not propagate a missing-file fault past an explicit fallback" do
    source = <<~CLEAR
      FN load(path: String) RETURNS String ->
        raw = readFile(path) OR_ELSE "";
        RETURN raw;
      END
      FN main() RETURNS !Void ->
        ASSERT load("definitely-missing") == "";
        RETURN;
      END
    CLEAR

    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to include("CheatLib.readFile")
    expect(zig).to include("catch")
    expect(zig).not_to match(/const raw[^\n]*try CheatLib\.readFile/)
  end

  it "composes with an explicit mutable receiver" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }
      IMPLEMENTATION Box {
        METHOD update(MUTABLE self) RETURNS !Void ->
          self.value = 7;
        END
      }
      FN main() RETURNS !Void ->
        MUTABLE box = Box{ value: 1 };
        TRY &box.update();
        ASSERT box.value == 7;
      END
    CLEAR

    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    main = T.must(program.statements.grep(AST::FunctionDef).find { |fn| fn.name == "main" })
    tried_call = T.cast(main.body.find { |node| node.is_a?(AST::UnaryOp) }, AST::UnaryOp)
    call = T.cast(tried_call.right, AST::MethodCall)
    expect(call.explicit_mutable_receiver?).to be(true)
    expect { ZigTranspiler.new.transpile(source) }.not_to raise_error
  end

  it "formats TRY with a visible operand boundary" do
    formatted = Formatter.format(<<~CLEAR)
      FN load() RETURNS !Int64 -> RETURN 7; END
      FN main() RETURNS !Int64 -> RETURN TRY load( ); END
    CLEAR

    expect(formatted).to include("TRY load()")
  end

  it "does not accept the retired postfix propagation spelling" do
    source = "FN risky() RETURNS !Int64 -> RETURN 4; END\nFN main() RETURNS !Int64 -> RETURN risky()!!; END"
    expect { ClearParser.new(Lexer.new(source).tokenize, source).parse }.to raise_error(ParserError)
  end

  it "requires an explicit choice when an inferred binding receives a fallible result" do
    source = <<~CLEAR
      FN risky() RETURNS !Int64 -> RETURN 4; END
      FN main() RETURNS !Void ->
        value = risky();
        RETURN;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }
      .to raise_error(CompilerError, /Cannot infer `value` from a fallible value/)
  end

  it "requires an explicit choice when an inferred binding receives an optional result" do
    source = <<~CLEAR
      FN maybe() RETURNS ?Int64 -> RETURN 4; END
      FN main() RETURNS Void ->
        value = maybe();
        RETURN;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }
      .to raise_error(CompilerError, /Cannot infer `value` from an optional value/)
  end

  it "keeps a safe-navigation result inference-friendly" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN maybe() RETURNS ?Box -> RETURN Box{ value: 4 }; END
      FN main() RETURNS ?Int64 ->
        value = maybe()?.value;
        RETURN value;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.not_to raise_error
  end

  it "supports explicit !, ?, and !? wrapper bindings with TRY and UNWRAP" do
    source = <<~CLEAR
      FN maybe(value: Int64) RETURNS ?Int64 -> RETURN value; END
      FN fallibleMaybe(value: Int64) RETURNS !?Int64 -> RETURN value; END
      FN main() RETURNS !Int64 ->
        retained:!? = fallibleMaybe(7);
        first:? = TRY retained;
        second = TRY UNWRAP fallibleMaybe(8);
        optional:? = TRY fallibleMaybe(9);
        widened:! = UNWRAP maybe(10);
        RETURN (UNWRAP first) + second + (UNWRAP optional) + TRY widened;
      END
    CLEAR

    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to include("const retained: anyerror!?i64 = fallibleMaybe(7);")
    expect(zig).to include("(try fallibleMaybe(8)).?")
    expect(zig).to include("const optional = try fallibleMaybe(9)")
    expect(zig).to include("const widened: anyerror!i64")
  end

  it "requires an explicit decision for inferred futures and streams" do
    future_source = <<~CLEAR
      FN main() RETURNS Void ->
        future = BG { 7; };
        RETURN;
      END
    CLEAR
    stream_source = <<~CLEAR
      FN produce() RETURNS [~]Int64 ->
        RETURN BG STREAM { YIELD 7; CLOSE; };
      END
      FN main() RETURNS Void ->
        result = produce();
        RETURN;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(future_source) }
      .to raise_error(CompilerError, /Cannot infer `future` from an asynchronous value/)
    expect { ZigTranspiler.new.transpile(stream_source) }
      .to raise_error(CompilerError, /Cannot infer `result` from an asynchronous value/)
  end

  it "allows a direct future or stream handle to be retained with :~" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        future:~ = BG { 7; };
        value = NEXT future;
        stream:~ = BG STREAM { YIELD 9; CLOSE; };
        IF NEXT stream EXISTS AS item THEN ASSERT item == 9; END
        ASSERT value == 7;
        RETURN;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.not_to raise_error
  end

  it "materializes finite stream SELECT pipelines before binding" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        stream:~ = BG STREAM { YIELD 9; CLOSE; };
        selected = stream |> SELECT _ + 1;
        ASSERT selected.length() == 1;
        RETURN;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.not_to raise_error
  end

  it "rejects OR_ELSE on a definite value even when the fallback has the same type" do
    source = <<~CLEAR
      FN foo() RETURNS Int64 -> RETURN 1; END
      FN bar() RETURNS Int64 -> RETURN 2; END
      FN main() RETURNS Void ->
        value = foo() OR_ELSE bar();
        RETURN;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.to raise_error(
      CompilerError,
      /OR_ELSE requires a fallible \(!T\) or optional \(\?T\) left operand, got Int64/
    )
  end

  it "rejects OR_ELSE on a definite value outside an assignment" do
    source = <<~CLEAR
      FN foo() RETURNS Int64 -> RETURN 1; END
      FN bar() RETURNS Int64 -> RETURN 2; END
      FN main() RETURNS Int64 ->
        RETURN foo() OR_ELSE bar();
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.to raise_error(
      CompilerError,
      /OR_ELSE requires a fallible \(!T\) or optional \(\?T\) left operand, got Int64/
    )
  end

  it "rejects OR_ELSE RAISE on a definite value" do
    source = <<~CLEAR
      FN foo() RETURNS Int64 -> RETURN 1; END
      FN main() RETURNS !Int64 ->
        RETURN foo() OR_ELSE RAISE;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.to raise_error(
      CompilerError,
      /OR_ELSE requires a fallible \(!T\) or optional \(\?T\) left operand, got Int64/
    )
  end

  it "rejects OR_ELSE on a definite value nested in a call argument" do
    source = <<~CLEAR
      FN sink(value: Int64) RETURNS Void -> RETURN; END
      FN bar() RETURNS Int64 -> RETURN 1; END
      FN baz() RETURNS Int64 -> RETURN 2; END
      FN main() RETURNS Void ->
        sink(bar() OR_ELSE baz());
        RETURN;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.to raise_error(
      CompilerError,
      /OR_ELSE requires a fallible \(!T\) or optional \(\?T\) left operand, got Int64/
    )
  end

  it "type-checks a recoverable OR_ELSE fallback nested in a call argument" do
    source = <<~CLEAR
      FN sink(value: Int64) RETURNS Void -> RETURN; END
      FN maybe() RETURNS ?Int64 -> RETURN 1; END
      FN baz() RETURNS String -> RETURN "wrong"; END
      FN main() RETURNS Void ->
        sink(maybe() OR_ELSE baz());
        RETURN;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.to raise_error(
      CompilerError,
      /Type mismatch in OR_ELSE: expected Int64, got String/
    )
  end

  it "preserves recoverability through function pipelines" do
    source = <<~CLEAR
      FN risky(value: Int64) RETURNS !Int64 ->
        IF value < 0 THEN RAISE "negative"; END
        RETURN value + 1;
      END
      FN main() RETURNS !Int64 ->
        RETURN (-1 |> risky) OR_ELSE 7;
      END
    CLEAR

    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to include("catch 7")
  end
end
