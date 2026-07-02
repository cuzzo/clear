# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyToClear::Transpiler do
  def expect_transpile(ruby_code, expected_clear)
    result = RubyToClear.transpile(ruby_code)
    expect(result.strip).to eq(expected_clear.strip)
  end

  describe "basic expressions and literals" do
    it "transpiles leaf nodes correctly" do
      expect_transpile("123", "123;")
      expect_transpile("0.5", "0.5;")
      expect_transpile('"hello"', '"hello";')
      expect_transpile(":my_sym", ":my_sym;")
      expect_transpile("nil", "NIL;")
      expect_transpile("false", "FALSE;")
      expect_transpile("true", "TRUE;")
    end

    it "transpiles arrays and hashes" do
      expect_transpile("[1, 2, 3]", "[1, 2, 3];")
      expect_transpile("{ a: 1, b: 2 }", "{a: 1, b: 2};")
      expect_transpile('{ "a" => 1 }', '{"a": 1};')
    end

    it "transpiles ranges and boolean operators" do
      expect_transpile("1..3", "1 ..= 3;")
      expect_transpile("1...3", "1 ..< 3;")
      expect_transpile("a && b", "(a() && b());")
      expect_transpile("a || b", "(a() || b());")
    end

    it "keeps parenthesized single expressions expression-safe" do
      expect_transpile(
        "x = (str.length - T.must(last_newline_index))",
        "MUTABLE x = ((str().length() - last_newline_index()));"
      )
    end

    it "transpiles string interpolations" do
      expect_transpile('x = 10; "count: #{x}"', "MUTABLE x = 10;\n\"count: ${x}\";")
      expect_transpile('x = 10; "count: #{x + 1}"', "MUTABLE x = 10;\n\"count: ${(x + 1)}\";")
      expect_transpile('x = 10; "count: #{x}" " total"', "MUTABLE x = 10;\n\"count: ${x} total\";")
      expect_transpile("x = 10; \"count: \#{x}\" \\\n  \" total\"", "MUTABLE x = 10;\n\"count: ${x} total\";")
    end

    it "emits CLEAR triple-quoted strings for Ruby heredocs" do
      ruby_code = <<~RUBY
        source = <<~CLEAR
          FN main() ->
            RETURN;
          END
        CLEAR
      RUBY
      expected_clear = <<~'CLEAR'
        MUTABLE source = """  FN main() ->
            RETURN;
          END
        """;
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "rejects multi-statement string interpolation" do
      expect {
        RubyToClear.transpile('"count: #{x = 1; x}"')
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /String interpolation must contain a single expression/)
    end

    it "transpiles self" do
      expect_transpile("self", "self;")
    end
  end

  describe "variable assignments and reads" do
    it "handles local variables write and read" do
      ruby_code = <<~RUBY
        x = 10
        y = x + 5
        x = 20
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE x = 10;
        MUTABLE y = (x + 5);
        x = 20;
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "handles instance variables read and write" do
      ruby_code = <<~RUBY
        @val = 42
        x = @val
      RUBY
      expected_clear = <<~CLEAR
        self.val = 42;
        MUTABLE x = self.val;
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end
  end

  describe "operators and method calls" do
    it "transpiles binary and unary operators" do
      expect_transpile("a = 1; b = 2; a == b", "MUTABLE a = 1;\nMUTABLE b = 2;\n(a == b);")
      expect_transpile("a = 1; b = 2; a != b", "MUTABLE a = 1;\nMUTABLE b = 2;\n(a != b);")
      expect_transpile("a = 1; b = 2; a << b", "MUTABLE a = 1;\nMUTABLE b = 2;\na.append(b);")
      expect_transpile("rank = 1; rank = -rank", "MUTABLE rank = 1;\nrank = (-rank);")
      expect_transpile("rank = 1; rank = +rank", "MUTABLE rank = 1;\nrank = (+rank);")
      expect_transpile("nums = []; x = 1; !nums.include?(x)", "MUTABLE nums = [];\nMUTABLE x = 1;\n!(nums.contains?(x));")
    end

    it "lowers Ruby regex match operators to syntax-valid CLEAR calls in lax mode" do
      expect_transpile("word =~ /^[A-Z]/", 'regexMatch?(word(), "^[A-Z]");')
      expect_transpile("word !~ /^[A-Z]/", '!(regexMatch?(word(), "^[A-Z]"));')
    end

    it "preserves dynamic Ruby type predicates as explicit CLEAR helper calls" do
      expect_transpile("node.is_a?(AST::Identifier)", 'isA?(node(), "AST::Identifier");')
      expect_transpile("node.respond_to?(:line)", 'respondsTo?(node(), "line");')
    end

    it "transpiles index access and assignments" do
      expect_transpile("states = {}; key = 1; states[key]", "MUTABLE states = {};\nMUTABLE key = 1;\nstates[key];")
      expect_transpile("states = {}; key = 1; value = 2; states[key] = value", "MUTABLE states = {};\nMUTABLE key = 1;\nMUTABLE value = 2;\nstates[key] = value;")
      expect_transpile("line = 'abc'; line[1, 2]", "MUTABLE line = \"abc\";\nline.substr(1, 2);")
      expect_transpile("line = 'abc'; line[1..2]", "MUTABLE line = \"abc\";\nline.substr(1, ((2 - 1) + 1));")
      expect_transpile("line = 'abc'; line[1..]", "MUTABLE line = \"abc\";\nline.substr(1, (line.length() - 1));")
    end

    it "transpiles standard method calls" do
      expect_transpile("pattern = 'abc'; scan(pattern)", "MUTABLE pattern = \"abc\";\nscan(pattern);")
      expect_transpile("obj = nil; pattern = 'abc'; obj.scan(pattern)", "MUTABLE obj = NIL;\nMUTABLE pattern = \"abc\";\nobj.scan(pattern);")
    end

    it "rejects splat arguments instead of emitting a runtime helper" do
      expect {
        RubyToClear.transpile("T.unsafe(node_class).new(start_token, *args)")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Splat arguments require an explicit call shape/)
    end

    it "lowers simple block parameter destructuring inside lambdas" do
      expect_transpile(
        "fields.each_with_object({}) { |(kv, t), h| h[kv.first] = t }",
        <<~CLEAR
          fields().each_with_object({}, %(tuple_param_0, h) -> {
            MUTABLE kv = tuple_param_0[0];
            MUTABLE t = tuple_param_0[1];
            h[kv.first()] = t;
            NIL
          });
        CLEAR
      )
    end
  end

  describe "conditionals and loops" do
    it "transpiles if / elsif / else" do
      ruby_code = <<~RUBY
        x = 1
        if x > 10
          y = 1
        elsif x < 5
          y = 2
        else
          y = 3
        end
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE x = 1;
        IF (x > 10) THEN
          MUTABLE y = 1;
        ELSE_IF (x < 5) THEN
          y = 2;
        ELSE
          y = 3;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles unless" do
      ruby_code = <<~RUBY
        unless active?
          deactivate!
        end
      RUBY
      expected_clear = <<~CLEAR
        IF !(active?()) THEN
          deactivate!();
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles Ruby ternaries as CLEAR if expressions" do
      ruby_code = <<~RUBY
        x = flag ? left : right
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE x = IF flag() THEN
          left()
        ELSE
          right()
        END;
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "wraps final ternary method bodies in an explicit return" do
      ruby_code = <<~RUBY
        sig { params(flag: Boolean).returns(Symbol) }
        def choose(flag)
          flag ? :left : :right
        end
      RUBY
      expected_clear = <<~CLEAR
        FN choose(flag: Bool) RETURNS String@symbol ->
          RETURN IF flag THEN
            :left
          ELSE
            :right
          END;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers statementful if assignments to branch assignments" do
      ruby_code = <<~RUBY
        token = if method?
          is_method = true
          consume(:METHOD)
        else
          consume(:FN)
        end
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE token = NIL;
        IF method?() THEN
          MUTABLE is_method = TRUE;
          token = consume(symbol("METHOD"));
        ELSE
          token = consume(symbol("FN"));
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "emits constructor calls for symbols that collide with CLEAR keywords" do
      expect_transpile(":left", ":left;")
      expect_transpile(":_hidden", "symbol(\"_hidden\");")
      expect_transpile(":VIEW", "symbol(\"VIEW\");")
      expect_transpile(":SNAPSHOT", "symbol(\"SNAPSHOT\");")
    end

    it "hoists assignment predicates before if statements" do
      ruby_code = <<~RUBY
        if (item = next_item)
          use(item)
        end
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE item = next_item();
        IF item THEN
          use(item);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles expression if assignments with expression-only branches" do
      ruby_code = <<~RUBY
        value = if a
          left
        elsif b
          middle
        else
          right
        end
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE value = IF a() THEN
          left()
        ELSE_IF b() THEN
          middle()
        ELSE
          right()
        END;
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers statementful expression if assignments in lax mode" do
      ruby_code = <<~RUBY
        value = if a
          left
        else
          seen = true
          right
        end
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE value = NIL;
        IF a() THEN
          value = left();
        ELSE
          MUTABLE seen = TRUE;
          value = right();
        END
      CLEAR
      expect(RubyToClear.transpile(ruby_code, raise_on_error: false).strip).to eq(expected_clear.strip)
    end

    it "drops guarded require scaffolding conditionals" do
      ruby_code = <<~RUBY
        require_relative "../ruby/ast/lexer" unless defined?(Lexer)
        require_relative "../ruby/ast/parser" unless defined?(ClearParser)
        unless active?
          deactivate!
        end
      RUBY
      expected_clear = <<~CLEAR
        IF !(active?()) THEN
          deactivate!();
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles case statements with no target" do
      ruby_code = <<~RUBY
        x = 1
        case
        when x == 1 then foo
        when x == 2 then bar
        else baz
        end
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE x = 1;
        IF (x == 1) THEN
          foo();
        ELSE_IF (x == 2) THEN
          bar();
        ELSE
          baz();
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles case statements with a target" do
      ruby_code = <<~RUBY
        val = :a
        case val
        when :a then 1
        when :b then 2
        else 99
        end
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE val = :a;
        PARTIAL MATCH val START
          :a -> 1;,
          :b -> 2;,
          DEFAULT -> 99;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles case expression assignments with a target" do
      ruby_code = <<~RUBY
        result = case val
        when :a then 1
        when :b then 2
        else 99
        end
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE result = PARTIAL MATCH val() START
          :a -> 1,
          :b -> 2,
          DEFAULT -> 99
        END;
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses placeholders for statementful case expression arms in lax mode" do
      ruby_code = <<~RUBY
        result = case val
        when :a
          seen = true
          1
        end
      RUBY
      expect(RubyToClear.transpile(ruby_code, raise_on_error: false).strip).to eq(
        'MUTABLE result = unsupportedRuby("WhenNode at 2:0: Case expression arms must contain one expression");'
      )
    end

    it "transpiles while and until loops" do
      ruby_code = <<~RUBY
        x = 1
        while x < 10
          x = x + 1
        end
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE x = 1;
        WHILE (x < 10) DO
          x = (x + 1);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)

      ruby_code = <<~RUBY
        until finished?
          do_work
        end
      RUBY
      expected_clear = <<~CLEAR
        WHILE !(finished?()) DO
          do_work();
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles Ruby next as CLEAR continue" do
      ruby_code = <<~RUBY
        while running
          next
        end
      RUBY
      expected_clear = <<~CLEAR
        WHILE running() DO
          CONTINUE;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers while predicates with assignment guards" do
      ruby_code = <<~RUBY
        while (item = next_item) && item.ok?
          use(item)
        end
      RUBY
      expect_transpile(ruby_code, <<~CLEAR)
        WHILE TRUE DO
          MUTABLE item = next_item();
          IF !(item) THEN
            BREAK;
          END
          IF !(item.ok?()) THEN
            BREAK;
          END
          use(item);
        END
      CLEAR
    end
  end

  describe "classes and methods" do
    it "preserves Ruby module bodies as comment-bounded flat output" do
      ruby_code = <<~RUBY
        module AST
          def helper(value)
            value
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        # Ruby module AST
        FN helper(value: Auto) RETURNS Auto ->
          value;
        END
        # End Ruby module AST
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "preserves empty Ruby modules without inventing namespace syntax" do
      expect_transpile("module Empty; end", "# Ruby module Empty")
    end

    it "transpiles Struct.new definition and constructor call mapping" do
      ruby_code = <<~RUBY
        Token = Struct.new(:type, :value, :line, :column)
        t = Token.new(:ELLIPSIS, '...', 1, 1)
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Token {
          type: Any,
          value: Any,
          line: Any,
          column: Any
        }
        MUTABLE t = Token{ type: :ELLIPSIS, value: "...", line: 1, column: 1 };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles keyword constructors for statically known struct fields" do
      ruby_code = <<~RUBY
        Token = Struct.new(:type, :value, keyword_init: true)
        t = Token.new(type: :IDENT, value: "name")
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Token {
          type: Any,
          value: Any
        }
        MUTABLE t = Token{ type: :IDENT, value: "name" };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles keyword constructors through constant paths when fields are known" do
      ruby_code = <<~RUBY
        Token = Struct.new(:type, :value)
        t = AST::Token.new(type: :IDENT, value: "name")
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Token {
          type: Any,
          value: Any
        }
        MUTABLE t = Token{ type: :IDENT, value: "name" };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles block parameters as ordinary optional callback parameters" do
      ruby_code = <<~RUBY
        sig { params(type: Symbol, block: T.nilable(StmtRule)).returns(StmtRule) }
        def self.stmt(type, &block)
          block
        end
      RUBY
      expected_clear = <<~CLEAR
        FN stmt(type: String@symbol, block = NIL: ?StmtRule) RETURNS StmtRule ->
          block;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles Ruby block arguments to CLEAR lambda values" do
      expect_transpile(
        "stmt(:KEYWORD, 'REQUIRE') { parse_require }",
        'stmt(:KEYWORD, "REQUIRE", %() -> parse_require());'
      )
      expect_transpile(
        "suffix(:CHAR, '[') { |lhs| parse_index(lhs) }",
        'suffix(:CHAR, "[", %(lhs) -> parse_index(lhs));'
      )
    end

    it "transpiles Ruby attr writer calls as CLEAR field assignments" do
      expect_transpile("lit.field_tokens = fields", "lit().field_tokens = fields();")
    end

    it "maps keyword calls to positional calls when method parameters are known" do
      ruby_code = <<~RUBY
        def parse_function_def(visibility = :package, is_method: false)
          visibility
        end

        parse_function_def(:package, is_method: true)
      RUBY
      expected_clear = <<~CLEAR
        FN parse_function_def(visibility = :package: Auto, is_method = FALSE: Auto) RETURNS Auto ->
          visibility;
        END
        parse_function_def(:package, TRUE);
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "fills skipped optional defaults when mapping known keyword calls" do
      ruby_code = <<~RUBY
        def configure(a = 1, b = 2, c = 3)
          c
        end

        configure(c: 4)
      RUBY
      expected_clear = <<~CLEAR
        FN configure(a = 1: Auto, b = 2: Auto, c = 3: Auto) RETURNS Auto ->
          c;
        END
        configure(1, 2, 4);
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers unmapped keyword calls to a final hash argument" do
      expect_transpile(
        "error!(token, :CODE, value: current.value, type: current.type)",
        "error!(token(), :CODE, {value: current().value(), type: current().type()});"
      )
    end

    it "maps keyword constructor calls through known initialize parameters" do
      ruby_code = <<~RUBY
        class Type
          def initialize(raw_input, ownership: nil, sync: nil)
          end
        end

        Type.new(:Int64, sync: :atomic)
        Type.new(:String)
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Type {

        }

        FN initialize!(MUTABLE self: Type, raw_input: Auto, ownership = NIL: Auto, sync = NIL: Auto) RETURNS Void ->

        END
        Type.new(:Int64, NIL, :atomic);
        Type.new(:String);
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles lambda block calls to CLEAR lambdas" do
      ruby_code = <<~RUBY
        rule = lambda do
          start = current
          build(start)
        end
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE rule = %() -> {
          MUTABLE start = current();
          build(start)
        };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "returns branch values from final if expressions inside CLEAR lambdas" do
      ruby_code = <<~RUBY
        suffix(:CHAR, '[') do |lhs|
          if first
            build(lhs)
          else
            fallback(lhs)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        suffix(:CHAR, "[", %(lhs) -> {
          IF first() THEN
            RETURN build(lhs);
          ELSE
            RETURN fallback(lhs);
          END
          NIL
        });
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles Ruby class variables as shared CLEAR variables" do
      ruby_code = <<~RUBY
        @@stmt_rules = T.let({}, T::Hash[RuleKey, StmtRule])
        @@stmt_rules[[type, value]] = block
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE stmt_rules = {};
        stmt_rules[[type(), value()]] = block();
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers singleton-class methods as static functions" do
      ruby_code = <<~RUBY
        class Parser
          @gradual_mode = T.let(false, T.nilable(T::Boolean))
          def initialize
            @value = 1
          end
          class << self
            def gradual_mode
              T.must(@gradual_mode)
            end
            def gradual_mode=(value)
              @gradual_mode = T.let(value, T.nilable(T::Boolean))
              value
            end
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Parser {
          value: Any
        }

        MUTABLE gradual_mode = FALSE;
        FN initialize!(MUTABLE self: Parser) RETURNS Void ->
          self.value = 1;
        END
        FN gradual_mode() RETURNS Auto ->
          gradual_mode;
        END
        FN set_gradual_mode!(value: Auto) RETURNS Auto ->
          gradual_mode = value;
          value;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses require_relative struct metadata for positional constructors when transpiling files" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ast.rb"), "module AST\n  Pair = Struct.new(:left, :right)\nend\n")
        source_path = File.join(dir, "parser.rb")
        File.write(source_path, "require_relative './ast'\nAST::Pair.new(1, 2)\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq("Pair{ left: 1, right: 2 };")
      end
    end

    it "uses constructor metadata from guarded require_relative calls" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "lexer.rb"), "class Lexer\n  def initialize(source)\n  end\nend\n")
        source_path = File.join(dir, "parser_spec.rb")
        File.write(source_path, "require_relative './lexer' unless defined?(Lexer)\nLexer.new(src)\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq("Lexer.new(src());")
      end
    end

    it "uses a placeholder for unknown positional constructors in lax mode" do
      res = RubyToClear.transpile("node = AST::Program.new(token, statements)", raise_on_error: false)
      expect(res.strip).to eq(
        'MUTABLE node = unsupportedRuby("CallNode at 1:7: Constructor call needs known field names");'
      )
    end

    it "transpiles classes, fields, and instance methods" do
      ruby_code = <<~RUBY
        class Calc
          def initialize(start)
            @val = start
          end

          def add(n)
            @val = @val + n
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Calc {
          val: Any
        }

        FN initialize!(MUTABLE self: Calc, start: Auto) RETURNS Void ->
          self.val = start;
        END
        FN add(MUTABLE self: Calc, n: Auto) RETURNS Auto ->
          self.val = (self.val + n);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses T.let metadata for generated instance field types" do
      ruby_code = <<~RUBY
        class Lexer
          def initialize(source)
            @s = T.let(StringScanner.new(source), StringScanner)
            @line = T.let(1, Integer)
            @tokens = T.let([], T::Array[Token])
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Lexer {
          line: Int64,
          s: Scanner,
          tokens: Token[]
        }

        FN initialize!(MUTABLE self: Lexer, source: Auto) RETURNS Void ->
          self.s = Scanner{ source: source, pos: 0 };
          self.line = 1;
          self.tokens = [];
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end
  end

  describe "method translations via registry" do
    it "transpiles map and collect" do
      ruby_code = "nums = []; nums.map { |x| x * 2 }"
      expected_clear = "MUTABLE nums = [];\nnums |> SELECT (_ * 2);"
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles map and select with block arguments" do
      expect_transpile("nums = []; nums.map(&:to_s)", "MUTABLE nums = [];\nnums |> SELECT _.toString();")
      expect_transpile("nums = []; nums.select(&:even?)", "MUTABLE nums = [];\nnums |> WHERE _.even?();")
    end

    it "transpiles select and filter" do
      ruby_code = "nums = []; nums.select { |x| x > 5 }"
      expected_clear = "MUTABLE nums = [];\nnums |> WHERE (_ > 5);"
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles predicate collection blocks" do
      expect_transpile("nums = []; nums.reject { |x| x < 2 }", "MUTABLE nums = [];\nnums |> WHERE !((_ < 2));")
      expect_transpile("nums = []; nums.any?", "MUTABLE nums = [];\nnums |> ANY _;")
      expect_transpile("nums = []; nums.any? { |x| x > 5 }", "MUTABLE nums = [];\nnums |> ANY (_ > 5);")
      expect_transpile("nums = []; nums.all?", "MUTABLE nums = [];\nnums |> ALL _;")
      expect_transpile("nums = []; nums.all? { |x| x > 0 }", "MUTABLE nums = [];\nnums |> ALL (_ > 0);")
      expect_transpile("nums = []; nums.find { |x| x == 3 }", "MUTABLE nums = [];\nnums |> FIND (_ == 3);")
      expect_transpile("nums = []; nums.detect { |x| x == 3 }", "MUTABLE nums = [];\nnums |> FIND (_ == 3);")
    end

    it "transpiles projection collection blocks" do
      expect_transpile("nums = []; nums.collect { |x| x * 2 }", "MUTABLE nums = [];\nnums |> SELECT (_ * 2);")
      expect_transpile("nums = []; nums.filter_map { |x| maybe(x) }", "MUTABLE nums = [];\nnums |> SELECT maybe(_) |> WHERE _ != NIL;")
      expect_transpile("nums = []; nums.filter { |x| x > 2 }", "MUTABLE nums = [];\nnums |> WHERE (_ > 2);")
      expect_transpile("groups = []; groups.flat_map { |g| g.items }", "MUTABLE groups = [];\ngroups |> UNNEST _.items();")
      expect_transpile("items = []; items.sort_by { |item| item.name }", "MUTABLE items = [];\nitems |> ORDER_BY _.name();")
    end

    it "transpiles mutating map and sum pipeline terminals" do
      ruby_code = "nums = []; nums.map! { |x| y = x + 1; y }"
      expected_clear = <<~CLEAR
        MUTABLE nums = [];
        nums = nums |> SELECT {
          MUTABLE y = (_ + 1);
          y
        };
      CLEAR
      expect_transpile(ruby_code, expected_clear)

      expect_transpile("nums = []; nums.sum", "MUTABLE nums = [];\nnums |> SUM _;")
      expect_transpile("items = []; items.sum { |item| item.value }", "MUTABLE items = [];\nitems |> SUM _.value();")
    end

    it "transpiles reduce and inject" do
      ruby_code = "nums = []; nums.reduce(0) { |acc, x| acc + x }"
      expected_clear = "MUTABLE nums = [];\nnums |> REDUCE(0) (acc + _);"
      expect_transpile(ruby_code, expected_clear)
      expect_transpile("nums = []; nums.inject(0) { |acc, x| acc + x }", "MUTABLE nums = [];\nnums |> REDUCE(0) (acc + _);")

      ruby_code = "nums = []; nums.reduce(0) { |acc, x| next_value = acc + x; next_value }"
      expected_clear = <<~CLEAR
        MUTABLE nums = [];
        nums |> REDUCE(0) {
          MUTABLE next_value = (acc + _);
          next_value
        };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles gsub" do
      ruby_code = "str = ''; str.gsub('a', 'b')"
      expected_clear = "MUTABLE str = \"\";\nstr.replace(\"a\", \"b\");"
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles include?" do
      ruby_code = "nums = []; x = 1; nums.include?(x)"
      expected_clear = "MUTABLE nums = [];\nMUTABLE x = 1;\nnums.contains?(x);"
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles each" do
      ruby_code = "nums = []; nums.each { |x| puts x }"
      expected_clear = "MUTABLE nums = [];\nnums |> EACH { puts(_); };"
      expect_transpile(ruby_code, expected_clear)

      ruby_code = "nums = []; nums.each { |x| puts x; audit x }"
      expected_clear = <<~CLEAR
        MUTABLE nums = [];
        nums |> EACH {
          puts(_);
          audit(_);
        };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles receiver-transform iteration helpers" do
      expect_transpile("nums = []; nums.reverse_each { |x| puts x }", "MUTABLE nums = [];\nnums.reverse() |> EACH { puts(_); };")
      expect_transpile("map = {}; map.each_key { |key| puts key }", "MUTABLE map = {};\nmap.keys() |> EACH { puts(_); };")
      expect_transpile("map = {}; map.each_value { |value| puts value }", "MUTABLE map = {};\nmap.values() |> EACH { puts(_); };")
    end

    it "transpiles common File and Dir stdlib calls to CLEAR primitives or thin adapters" do
      expect_transpile('File.read("a.txt")', "REQUIRE \"pkg:fs\"\nread(\"a.txt\") OR RAISE;")
      expect_transpile('File.readlines("a.txt")', "REQUIRE \"pkg:fs\"\nreadLines(\"a.txt\") OR RAISE;")
      expect_transpile('File.foreach("a.txt")', "REQUIRE \"pkg:fs\"\nreadLines(\"a.txt\") OR RAISE;")
      expect_transpile('File.foreach("a.txt") { |line| puts line }', "REQUIRE \"pkg:fs\"\n(readLines(\"a.txt\") OR RAISE) |> EACH { puts(_); };")
      expect_transpile('File.write("a.txt", body)', "REQUIRE \"pkg:fs\"\nwrite(\"a.txt\", body()) OR RAISE;")
      expect_transpile('File.binwrite("a.txt", bytes)', "REQUIRE \"pkg:fs\"\nwrite(\"a.txt\", bytes()) OR RAISE;")
      expect_transpile('File.size(path)', "REQUIRE \"pkg:fs\"\nsize(path()) OR RAISE;")
      expect_transpile('File.exist?(path)', "REQUIRE \"pkg:fs\"\nexists?(path());")
      expect_transpile('File.exists?(path)', "REQUIRE \"pkg:fs\"\nexists?(path());")
      expect_transpile('File.file?(path)', "REQUIRE \"pkg:fs\"\nfile?(path());")
      expect_transpile('File.directory?(path)', "REQUIRE \"pkg:fs\"\ndir?(path());")
      expect_transpile('File.mtime(path)', "REQUIRE \"pkg:fs\"\nmtime(path()) OR RAISE;")
      expect_transpile('File.delete(path)', "REQUIRE \"pkg:fs\"\ndelete(path()) OR RAISE;")
      expect_transpile('File.readlink(path)', "REQUIRE \"pkg:fs\"\nreadLink(path()) OR RAISE;")
      expect_transpile('File.symlink(target, link)', "REQUIRE \"pkg:fs\"\nsymlink(target(), link()) OR RAISE;")
      expect_transpile('File.symlink?(path)', "REQUIRE \"pkg:fs\"\nsymlink?(path());")
      expect_transpile('File.join(root, "src", name)', "REQUIRE \"pkg:path\"\njoin(root(), \"src\", name());")
      expect_transpile('File.expand_path("../x", base)', "REQUIRE \"pkg:path\"\nexpand(\"../x\", base());")
      expect_transpile('File.basename(path)', "REQUIRE \"pkg:path\"\nbasename(path());")
      expect_transpile('File.dirname(path)', "REQUIRE \"pkg:path\"\ndirname(path());")
      expect_transpile('Dir.glob(File.join(root, "*.rb"))', "REQUIRE \"pkg:fs\"\nREQUIRE \"pkg:path\"\nglob(join(root(), \"*.rb\")) OR RAISE;")
      expect_transpile('Dir.exist?(path)', "REQUIRE \"pkg:fs\"\ndir?(path());")
      expect_transpile('Dir.exists?(path)', "REQUIRE \"pkg:fs\"\ndir?(path());")
      expect_transpile('Dir.children(path)', "REQUIRE \"pkg:fs\"\nlist(path()) OR RAISE;")
      expect_transpile('Dir.entries(path)', "REQUIRE \"pkg:fs\"\nlistAll(path()) OR RAISE;")
      expect_transpile('Dir.pwd', "REQUIRE \"pkg:fs\"\npwd() OR RAISE;")
    end

    it "emits one pkg:fs require and marks methods fallible when fs calls can raise" do
      ruby_code = <<~RUBY
        sig { params(path: String, out: String).returns(String) }
        def copy_text(path, out)
          body = File.read(path)
          File.write(out, body)
          body
        end
      RUBY
      expected_clear = <<~CLEAR
        REQUIRE "pkg:fs"
        FN copy_text(path: String, out: String) RETURNS !String ->
          MUTABLE body = NIL;
          body = read(path) OR RAISE;
          write(out, body) OR RAISE;
          body;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "does not wrap unknown inferred return types in fallible Auto" do
      ruby_code = <<~RUBY
        def load_text(path)
          File.read(path)
        end
      RUBY
      expected_clear = <<~CLEAR
        REQUIRE "pkg:fs"
        FN load_text(path: Auto) RETURNS Auto ->
          read(path) OR RAISE;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles JSON, regexp escaping, scanner construction, and string aliases" do
      expect_transpile('JSON.parse(raw)', 'parseJson(raw());')
      expect_transpile('JSON.generate(doc)', 'generateJson(doc());')
      expect_transpile('JSON.pretty_generate(doc)', 'prettyGenerateJson(doc());')
      expect_transpile('Regexp.escape(name)', 'escapeRegex(name());')
      expect_transpile('StringScanner.new(source)', 'Scanner{ source: source(), pos: 0 };')
      expect_transpile('s = " x "; s.strip', "MUTABLE s = \" x \";\ns.trim();")
      expect_transpile('s = "abc"; s.start_with?("a")', "MUTABLE s = \"abc\";\ns.startsWith?(\"a\");")
      expect_transpile('s = "abc"; s.end_with?("c")', "MUTABLE s = \"abc\";\ns.endsWith?(\"c\");")
      expect_transpile('s = "abc"; s.index("b")', "MUTABLE s = \"abc\";\ns.indexOf(\"b\");")
      expect_transpile('s = "a"; s.lines', "MUTABLE s = \"a\";\ns.split(\"\\n\");")
      expect_transpile('parts = []; parts.join', "MUTABLE parts = [];\nparts.join(\"\");")
    end

    it "uses receiver-shape tracking for overloaded collection and string calls" do
      expect_transpile('[1].size', "[1].length();")
      expect_transpile('items = []; items.empty?', "MUTABLE items = [];\n(items.length() == 0);")
      expect_transpile('items = []; items.size', "MUTABLE items = [];\nitems.length();")
      expect_transpile('{ a: 1 }.length', "{a: 1}.count();")
      expect_transpile('table = {}; table.empty?', "MUTABLE table = {};\n(table.count() == 0);")
      expect_transpile('table = {}; table.size', "MUTABLE table = {};\ntable.count();")
      expect_transpile('"abc".empty?', "(\"abc\".length() == 0);")
      expect_transpile('name = "abc"; name.empty?', "MUTABLE name = \"abc\";\n(name.length() == 0);")
      expect_transpile('name = "abc"; name.split("b")', "MUTABLE name = \"abc\";\nname.split(\"b\");")
      expect_transpile('name = "abc"; name.delete_prefix("a")', "MUTABLE name = \"abc\";\nname.deletePrefix(\"a\");")
    end

    it "tracks receiver shapes through typed values and call results" do
      expect_transpile('items = T.let([], T::Array[String]); items.size', "MUTABLE items: String[] = [];\nitems.length();")
      expect_transpile('name = T.must("abc"); name.size', "MUTABLE name = \"abc\";\nname.length();")
      expect_transpile('n = text.to_i', "MUTABLE n = (text().toInt() OR 0);")
      expect_transpile('lines = File.readlines(path); lines.size', "REQUIRE \"pkg:fs\"\nMUTABLE lines = readLines(path()) OR RAISE;\nlines.length();")
      expect_transpile('name = "a:b"; parts = name.split(":"); parts.size', "MUTABLE name = \"a:b\";\nMUTABLE parts = name.split(\":\");\nparts.length();")
      expect_transpile('table = {}; keys = table.keys; keys.size', "MUTABLE table = {};\nMUTABLE keys = table.keys();\nkeys.length();")
      expect_transpile('items = []; mapped = items.map { |item| item }; mapped.size', "MUTABLE items = [];\nMUTABLE mapped = items |> SELECT _;\nmapped.length();")
      expect_transpile('pairs = []; pairs.any? { |w, t| match?(t, w) }', "MUTABLE pairs = [];\npairs |> ANY match?(_[1], _[0]);")
      expect_transpile('table = {}; pairs = []; pairs.each { |k, v| table[k] = v }', "MUTABLE table = {};\nMUTABLE pairs = [];\npairs |> EACH { table[_[0]] = _[1]; };")
    end

    it "statically lowers simple nil and type/reflection checks when receiver shape is known" do
      expect_transpile('items = []; items.nil?', "MUTABLE items = [];\n(items == NIL);")
      expect_transpile('nil.is_a?(NilClass)', "TRUE;")
      expect_transpile('true.is_a?(Boolean)', "TRUE;")
      expect_transpile('1.is_a?(Numeric)', "TRUE;")
      expect_transpile(':name.is_a?(Symbol)', "TRUE;")
      expect_transpile('"abc".is_a?("String")', "TRUE;")
      expect_transpile('items = []; items.is_a?(Array)', "MUTABLE items = [];\nTRUE;")
      expect_transpile('items = []; items.is_a?(Hash)', "MUTABLE items = [];\nFALSE;")
      expect_transpile('items = []; items.respond_to?("size")', "MUTABLE items = [];\nTRUE;")
      expect_transpile('table = {}; table.respond_to?(:keys)', "MUTABLE table = {};\nTRUE;")
      expect_transpile('table = {}; table.respond_to?(:strip)', "MUTABLE table = {};\nFALSE;")
    end

    it "preserves dynamic receiver type/reflection checks as explicit helpers" do
      expect {
        RubyToClear.transpile('items = unknown; items.respond_to?(method_name)')
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /respond_to\? requires a static method name/)

      expect {
        RubyToClear.transpile('items = unknown; items.is_a?(klass)')
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /is_a\? requires a static type argument/)

      expect_transpile(
        'items = get_items; items.respond_to?(:size)',
        "MUTABLE items = get_items();\nrespondsTo?(items, \"size\");"
      )
      expect_transpile(
        'items = get_items; items.is_a?(Array)',
        "MUTABLE items = get_items();\nisA?(items, \"Array\");"
      )
    end

    it "uses placeholders for dynamic type/reflection checks in lax mode" do
      expect(RubyToClear.transpile('items = unknown; items.is_a?(klass)', raise_on_error: false).strip).to eq(
        "MUTABLE items = unknown();\nunsupportedRuby(\"CallNode at 1:17: is_a? requires a static type argument\");"
      )
      expect(RubyToClear.transpile('obj = unknown; obj.respond_to?(method_name)', raise_on_error: false).strip).to eq(
        "MUTABLE obj = unknown();\nunsupportedRuby(\"CallNode at 1:15: respond_to? requires a static method name\");"
      )
    end

    it "rejects unsupported registry edge cases with precise TODOs" do
      {
        'JSON.parse' => /JSON.parse expects 1 arguments/,
        'File.read' => /File.read expects 1 arguments/,
        'File.foreach("a.txt", "b.txt")' => /File.foreach expects 1 argument/,
        'StringScanner.new' => /StringScanner.new expects 1 argument/,
        'Set.new { |item| item }' => /Set.new with a block requires a source enumerable/,
        'Set.new(a, b)' => /Set.new expects 0 or 1 arguments/,
        '"abc".delete_prefix' => /delete_prefix expects 1 argument/,
        '[1].map! { |x| x }' => /map! is only supported on a mutable local receiver/,
        'items = []; items.map { |x = 1| x }' => /map block parameter shape is not supported/,
        'nums = []; nums.reduce(0) { |acc| acc }' => /reduce block expects 2 required parameters/,
        'items = []; items.map { |item| }' => /Pipeline block must contain at least one expression/
      }.each do |ruby_code, error|
        expect {
          RubyToClear.transpile(ruby_code)
        }.to raise_error(RubyToClear::Transpiler::TranspilationError, error)
      end
    end

    it "transpiles Set constructors to CLEAR set-producing expressions" do
      expect_transpile('Set.new', 'Set[];')
      expect_transpile('Set.new([1, 2, 1])', '[1, 2, 1] |> DISTINCT _;')
      expect_transpile('Set.new(items) { |item| item.name }', 'items() |> SELECT _.name() |> DISTINCT _;')
      expect_transpile('Set[:a, :b]', '[:a, :b] |> DISTINCT _;')
    end

    it "rejects Ruby regexp global match state instead of hiding it behind an adapter" do
      expect {
        RubyToClear.transpile("Regexp.last_match(1)")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /implicit regexp match state/)
    end
  end

  describe "unsupported/incorrect nodes in strict and lax mode" do
    it "transpiles class variable writes as shared CLEAR variables" do
      expect_transpile("@@count = 0", "MUTABLE count = 0;")
    end

    it "transpiles class variable writes in lax mode" do
      res = RubyToClear.transpile("@@count = 0", raise_on_error: false)
      expect(res.strip).to eq("MUTABLE count = 0;")
    end

    it "transpiles class variable reads in lax mode" do
      res = RubyToClear.transpile("rule = @@rules[key]", raise_on_error: false)
      expect(res.strip).to eq(
        "MUTABLE rule = rules[key()];"
      )
    end

    it "keeps supported statements around class variable writes in lax mode" do
      ruby_code = <<~RUBY
        if ok
          before
          @@count = 1
          after
        end
      RUBY
      expected_clear = <<~CLEAR
        IF ok() THEN
          before();
          MUTABLE count = 1;
          after();
        END
      CLEAR

      expect(RubyToClear.transpile(ruby_code, raise_on_error: false).strip).to eq(expected_clear.strip)
    end

    it "assigns class variables inside methods without declaring locals" do
      ruby_code = <<~RUBY
        def build
          value = 1
          @@count = value
          value
        end
      RUBY
      expected_clear = <<~CLEAR
        FN build() RETURNS Auto ->
          MUTABLE value = NIL;
          value = 1;
          count = value;
          value;
        END
      CLEAR

      expect(RubyToClear.transpile(ruby_code, raise_on_error: false).strip).to eq(expected_clear.strip)
    end
  end

  describe "regular expressions and gsub/sub validation" do
    it "lowers regex literals to CLEAR pattern strings" do
      expect_transpile("/pattern/", '"pattern";')
      expect_transpile("/^x(\\d+)$/", '"^x(\\\\d+)$";')
    end

    it "lowers regex literals in expression position" do
      expect_transpile("scanner.scan(/pattern/)", 'scanner().scan("pattern");')
    end

    it "uses a syntax-valid placeholder for defined? in expression position in lax mode" do
      res = RubyToClear.transpile("unless defined?(Lexer)\nend", raise_on_error: false)
      expect(res.strip).to eq(<<~CLEAR.strip)
        IF !(unsupportedRuby("DefinedNode at 1:7: defined? is not supported")) THEN

        END
      CLEAR
    end

    it "lowers regex sub expressions to explicit helper calls" do
      expect_transpile(
        "body = matched.sub(/_x\\z/, '')",
        'MUTABLE body = regexReplaceFirst(matched(), "_x\\\\z", "");'
      )
    end

    it "lowers top-level constant writes to valid CLEAR variable names" do
      expect_transpile(
        "KEYWORDS = T.let(%w[A], T::Set[String]); KEYWORDS.include?('A')",
        "MUTABLE keywords = [\"A\"];\nkeywords.contains?(\"A\");"
      )
    end

    it "treats Ruby freeze calls as immutability scaffolding" do
      expect_transpile("values = %w[A].freeze", "MUTABLE values = [\"A\"];")
    end

    it "translates RSpec block DSL calls to CLEAR test syntax" do
      ruby_code = <<~RUBY
        RSpec.describe(Lexer) do
          it("works") { expect(true).to eq(true) }
        end
      RUBY
      res = RubyToClear.transpile(ruby_code, raise_on_error: false)

      expected_clear = <<~CLEAR
        TEST Lexer DO
          WHEN "examples" DO
            TEST THAT "works" DO
              ASSERT TRUE == TRUE, "expected TRUE to eq(true)";
            END
          END
        END
      CLEAR
      expect(res.strip).to eq(expected_clear.strip)
    end

    it "translates RSpec type matchers to type assertions" do
      ruby_code = <<~RUBY
        RSpec.describe("x") do
          it("type") { expect(node).to be_a(AST::Node) }
          it("all") { expect(nodes).to all(be_a(AST::Node)) }
        end
      RUBY
      res = RubyToClear.transpile(ruby_code, raise_on_error: false)

      expected_clear = <<~CLEAR
        TEST X DO
          WHEN "examples" DO
            TEST THAT "type" DO
              ASSERT isA?(node(), "AST::Node"), "expected node() to be_a(AST::Node)";
            END
            TEST THAT "all" DO
              ASSERT nodes() |> ALL isA?(_, "AST::Node"), "expected nodes() to all(be_a(AST::Node))";
            END
          END
        END
      CLEAR
      expect(res.strip).to eq(expected_clear.strip)
    end

    it "lowers gsub with regex to an explicit helper call" do
      expect_transpile(
        "str = ''; str.gsub(/pat/, 'replacement')",
        "MUTABLE str = \"\";\nregexReplaceAll(str, \"pat\", \"replacement\");"
      )
    end

    it "raises error on gsub with block" do
      expect {
        RubyToClear.transpile("str = ''; str.gsub('a') { 'b' }")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /gsub with block or invalid arguments is not supported/)
    end

    it "keeps receiver package imports when regex gsub is lowered" do
      result = RubyToClear.transpile('File.basename(path, ".clear").gsub(/[^a]/, "_")', raise_on_error: false)

      expect(result.strip).to eq(<<~CLEAR.strip)
        REQUIRE "pkg:path"
        regexReplaceAll(basename(path(), ".clear"), "[^a]", "_");
      CLEAR
    end

    it "lowers sub method calls" do
      expect_transpile(
        "str = ''; str.sub('a', 'b')",
        "MUTABLE str = \"\";\nreplaceFirst(str, \"a\", \"b\");"
      )
    end
  end

  describe "pipeline translations validation" do
    it "raises error on map without block" do
      expect {
        RubyToClear.transpile("list = []; list.map")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /map without a block is not supported/)
    end

    it "raises error on select without block" do
      expect {
        RubyToClear.transpile("list = []; list.select")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /select without a block is not supported/)
    end

    it "raises error on reduce without block" do
      expect {
        RubyToClear.transpile("list = []; list.reduce(0)")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /reduce without a block is not supported/)
    end

    it "raises error on each without block" do
      expect {
        RubyToClear.transpile("list = []; list.each")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /each without a block is not supported/)
    end

    it "raises error on enumerable helpers that need unavailable Ruby semantics" do
      expect {
        RubyToClear.transpile("pairs = []; pairs.each_pair { |key, value| puts key }")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /each_pair requires pair\/destructuring block support/)

      expect_transpile(
        "items = []; items.each_with_index { |item, index| puts item }",
        "MUTABLE items = [];\nitems.eachWithIndex() |> EACH { puts(_[0]); };"
      )

      expect_transpile(
        "loop { tick; break unless keep_going }",
        "WHILE TRUE DO\n  tick();\n  IF !(keep_going()) THEN\n    BREAK;\n  END\nEND"
      )
    end

    it "translates multi-statement pipeline blocks with implicit final expression values" do
      ruby_code = "list = []; list.map { |x| y = x * 2; y + 1 }"
      expected_clear = <<~CLEAR
        MUTABLE list = [];
        list |> SELECT {
          MUTABLE y = (_ * 2);
          (y + 1)
        };
      CLEAR
      expect_transpile(ruby_code, expected_clear)

      ruby_code = "list = []; list.select { |x| y = x * 2; y > 10 }"
      expected_clear = <<~CLEAR
        MUTABLE list = [];
        list |> WHERE {
          MUTABLE y = (_ * 2);
          (y > 10)
        };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "raises error on nonlocal control flow inside pipeline value blocks" do
      expect {
        RubyToClear.transpile("list = []; list.map { |x| return x }")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /map block contains unsupported ReturnNode/)
    end

    it "raises error on destructured pipeline block parameters" do
      expect {
        RubyToClear.transpile("pairs = []; pairs.find { |(left, right)| left }")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /block parameter destructuring is not supported/)
    end
  end

  describe "MultiWriteNode destructuring" do
    it "translates swaps and literal array destructuring correctly" do
      ruby_code = <<~RUBY
        def swap_vars(a, b)
          a, b = b, a
        end
      RUBY
      expected_clear = <<~CLEAR
        FN swap_vars(MUTABLE a: Auto, MUTABLE b: Auto) RETURNS Auto ->
          a, b = [b, a];
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
      expect_transpile("a, b = [1, 2]", "MUTABLE a, b = [1, 2];")
    end

    it "translates destructuring from non-literal values" do
      expect_transpile("a, b = get_val", "MUTABLE a, b = get_val();")
    end

    it "raises error on unsupported destructuring targets" do
      expect {
        RubyToClear.transpile("@a, b = [1, 2]")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Destructuring targets must be local variables or _/)
    end
  end

  describe "local variable scoping and parameter mutability inside def" do
    it "pre-declares variables assigned inside conditionals at the def function start" do
      ruby_code = <<~RUBY
        def test_fn(cond)
          if cond
            x = 42
          end
          x
        end
      RUBY
      expected_clear = <<~CLEAR
        FN test_fn(cond: Auto) RETURNS Auto ->
          MUTABLE x = NIL;
          IF cond THEN
            x = 42;
          END
          x;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "marks parameters as MUTABLE if they are reassigned in def body" do
      ruby_code = <<~RUBY
        def test_fn(p)
          p = 10
        end
      RUBY
      expected_clear = <<~CLEAR
        FN test_fn(MUTABLE p: Auto) RETURNS Auto ->
          p = 10;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end
  end

  describe "keyword arguments and parameters validation" do
    it "lowers unknown keyword arguments inside calls to a final hash" do
      expect_transpile("test_call(a: 1)", "test_call({a: 1});")
    end

    it "uses expression placeholders for unsupported keyword constructors in lax mode" do
      expect(RubyToClear.transpile("fix = Edit.new(span: span)", raise_on_error: false).strip).to eq(
        'MUTABLE fix = unsupportedRuby("KeywordHashNode at 1:15: Keyword arguments are not supported for this constructor");'
      )
      expect(RubyToClear.transpile("error!(code: :BAD)", raise_on_error: false).strip).to eq(
        "error!({code: :BAD});"
      )
    end

    it "translates static keyword parameters as ordinary CLEAR parameters" do
      ruby_code = <<~RUBY
        def my_func(a, b:, c: 1)
          b
        end
      RUBY
      expected_clear = <<~CLEAR
        FN my_func(a: Auto, b: Auto, c = 1: Auto) RETURNS Auto ->
          b;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "raises error on keyword rest parameters inside method signatures" do
      expect {
        RubyToClear.transpile("def my_func(**kwargs); end")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Keyword rest parameters are not supported/)
    end
  end

  describe "exception handling (rescue) validation" do
    it "raises error on begin-rescue blocks" do
      expect {
        RubyToClear.transpile("begin; do_something; rescue; handle_error; end")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Exception handling \(rescue\) is not supported/)
    end

    it "drops Sorbet bind rescue nil metadata" do
      ruby_code = <<~RUBY
        def bound
          T.bind(self, Thing) rescue nil
          x = 1
        end
      RUBY
      expected_clear = <<~CLEAR
        FN bound() RETURNS Auto ->
          MUTABLE x = NIL;
          x = 1;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "raises error on inline rescue modifier" do
      expect {
        RubyToClear.transpile("do_something rescue handle_error")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Exception handling \(rescue\) is not supported/)
    end
  end

  describe "dynamic Ruby blocker validation" do
    it "raises on dynamic and reflection calls instead of emitting Ruby-shaped CLEAR" do
      {
        "Object.const_get(:Name)" => /dynamic constant lookup/,
        "instance_variable_get(:@value)" => /dynamic instance state/,
        "define_method(:value) { 1 }" => /dynamic method definition/,
        "eval('1 + 1')" => /dynamic evaluation/,
        "instance_eval('1 + 1')" => /dynamic evaluation/,
      }.each do |ruby_code, error|
        expect {
          RubyToClear.transpile(ruby_code)
        }.to raise_error(RubyToClear::Transpiler::TranspilationError, error)
      end
    end

    it "lowers static send calls to direct method calls" do
      expect_transpile("send(:foo)", "self.foo();")
      expect_transpile("public_send(:foo, 1)", "self.foo(1);")
      expect_transpile("parser.send(:parse_type_annotation)", "parser().parse_type_annotation();")
    end

    it "rejects send calls with dynamic method names" do
      expect {
        RubyToClear.transpile("method_name = :foo; send(method_name)")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /requires a static symbol or string method name/)
    end
  end

  describe "compound assignments and optional parameters" do
    it "translates local and instance variable operator writes (+=, ||=, etc.)" do
      expect_transpile("x = 10; x += 5", "MUTABLE x = 10;\nx = (x + 5);")
      expect_transpile("x += 5", "MUTABLE x = 5;")
      expect_transpile("x = 10; x ||= 5", "MUTABLE x = 10;\nx = (x || 5);")
      expect_transpile("x ||= 5", "MUTABLE x = 5;")
      expect_transpile("x &&= 5", "MUTABLE x = 5;")
      expect_transpile("x = true; x &&= false", "MUTABLE x = TRUE;\nx = (x && FALSE);")
      expect_transpile("@val = 10; @val += 5", "self.val = 10;\nself.val = (self.val + 5);")
    end

    it "translates optional parameters in def signatures" do
      expect_transpile("def my_func(a, b = 42); end", "FN my_func(a: Auto, b = 42: Auto) RETURNS Auto ->\n\nEND")
    end

    it "lifts parameter is_a? predicates into generic COMPTIME IS_A guards" do
      ruby_code = <<~RUBY
        def handle(node)
          if node.is_a?(AST::BinaryOp)
            node
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        FN handle<T>(node: T) RETURNS Auto ->
          COMPTIME IF T IS_A AST.BinaryOp THEN
            node;
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses runtime IS_A for explicitly typed AST node union parameters" do
      ruby_code = <<~RUBY
        sig { params(node: AST::Node).void }
        def ensure_binary(node)
          unless node.is_a?(AST::BinaryOp)
            return
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        FN ensure_binary(node: Node) RETURNS Void ->
          IF !(node IS_A AST.BinaryOp) THEN
            RETURN;
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "emits union aliases from Sorbet fat union type aliases and narrows with AS bindings" do
      ruby_code = <<~RUBY
        Node = T.type_alias { T.any(AST::BinaryOp, AST::Identifier) }
        sig { params(node: Node).void }
        def handle_node(node)
          if node.is_a?(AST::BinaryOp)
            node
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Node { BinaryOp: BinaryOp, Identifier: Identifier }
        FN handle_node(node: Node) RETURNS Void ->
          IF node IS_A AST.BinaryOp AS binary_op THEN
            binary_op;
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "synthesizes union types from inline Sorbet T.any parameters" do
      ruby_code = <<~RUBY
        sig { params(node: T.any(AST::BinaryOp, AST::Identifier)).void }
        def handle_inline(node)
          if node.is_a?(AST::Identifier)
            node
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Node { BinaryOp: BinaryOp, Identifier: Identifier }
        FN handle_inline(node: Node) RETURNS Void ->
          IF node IS_A AST.Identifier AS identifier THEN
            identifier;
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "does not add generic params for exact known type predicates" do
      ruby_code = <<~RUBY
        sig { params(type: Type).returns(Bool) }
        def already_type(type)
          return type.is_a?(Type)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN already_type(type: Type) RETURNS Bool ->
          RETURN TRUE;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "omits collection literal defaults that CLEAR parameter syntax cannot parse" do
      ruby_code = <<~RUBY
        sig { params(items: T::Array[String], options: T::Hash[String, Integer]).void }
        def configure(items = [], options: {})
        end
      RUBY
      expected_clear = <<~CLEAR
        FN configure(items: String[], options: HashMap<String, Int64>) RETURNS Void ->

        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end
  end

  describe "Sorbet sig type parsing" do
    it "compiles method signatures with explicit parameter and return types" do
      ruby_code = <<~RUBY
        sig { params(x: Integer, y: T.nilable(String), z: T::Array[Token]).returns(Void) }
        def my_method(x, y, z)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN my_method(x: Int64, y: ?String, z: Token[]) RETURNS Void ->

        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "strips application namespace qualifiers from Sorbet type paths" do
      ruby_code = <<~RUBY
        sig { params(token: Lexer::Token, node: T.nilable(AST::Node)).returns(AST::Program) }
        def parse_token(token, node)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN parse_token(token: Token, node: ?Node) RETURNS Program ->

        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "compiles richer Sorbet collection and union types" do
      ruby_code = <<~RUBY
        sig { params(items: T::Array[String], table: T::Hash[String, Integer], seen: T::Set[Symbol], maybe: T.any(String, NilClass)).returns(T::Hash[String, T::Array[Integer]]) }
        def typed(items, table, seen, maybe)
          table
        end
      RUBY
      expected_clear = <<~CLEAR
        FN typed(items: String[], table: HashMap<String, Int64>, seen: String[]@set, maybe: ?String) RETURNS HashMap<String, Int64[]> ->
          table;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "compiles broader Sorbet scalar and collection type forms" do
      ruby_code = <<~RUBY
        sig { params(f: Float, n: NilClass, b: Boolean, t: TrueClass, f2: FalseClass, any_t: T, arr: T::Array, hash: T::Hash, set: T::Set, raw: T.untyped, anything: T.anything, either: T.any(String, Integer, NilClass), unknown_maybe: T.nilable(T::Class[T.anything]), enumerable: T::Enumerable[String]).void }
        def edge_types(f, n, b, t, f2, any_t, arr, hash, set, raw, anything, either, unknown_maybe, enumerable)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN edge_types(f: Float64, n: Void, b: Bool, t: Bool, f2: Bool, any_t: Auto, arr: Any, hash: Any, set: Any, raw: Auto, anything: Auto, either: Auto, unknown_maybe: Auto, enumerable: String[]) RETURNS Void ->

        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses T.let and T.cast as local type metadata without emitting Sorbet runtime calls" do
      ruby_code = <<~RUBY
        value = "x"
        items = T.let([], T::Array[String])
        table = T.let({}, T::Hash[String, Integer])
        maybe = T.cast(value, T.nilable(String))
        sure = T.must(maybe)
        unsafe = T.unsafe(sure)
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE value = "x";
        MUTABLE items: String[] = [];
        MUTABLE table: HashMap<String, Int64> = {};
        MUTABLE maybe: ?String = value;
        MUTABLE sure = maybe;
        MUTABLE unsafe = sure;
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "drops T.bind statements" do
      ruby_code = <<~RUBY
        def bound
          T.bind(self, Thing)
          x = 1
        end
      RUBY
      expected_clear = <<~CLEAR
        FN bound() RETURNS Auto ->
          MUTABLE x = NIL;
          x = 1;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "drops Ruby require, visibility, and Sorbet extend scaffolding" do
      ruby_code = <<~RUBY
        require "sorbet-runtime"
        class Thing
          extend T::Sig
          private
          def run
            1
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Thing {

        }

        FN run(MUTABLE self: Thing) RETURNS Auto ->
          1;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "records simple T.type_alias constants for later signatures" do
      ruby_code = <<~RUBY
        Table = T.type_alias { T::Hash[String, Integer] }
        sig { params(table: Table).returns(Table) }
        def passthrough(table)
          table
        end
      RUBY
      expected_clear = <<~CLEAR
        FN passthrough(table: HashMap<String, Int64>) RETURNS HashMap<String, Int64> ->
          table;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles field-only T::Struct classes to explicit CLEAR structs" do
      ruby_code = <<~RUBY
        class Config < T::Struct
          const :path, String
          prop :count, Integer
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Config {
          path: String,
          count: Int64
        }
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end
  end
end
