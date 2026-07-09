# frozen_string_literal: true

require "spec_helper"
require "fileutils"
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
      expect_transpile("{ a: 1, b: 2 }", "{:a: 1, :b: 2};")
      expect_transpile("{ MOD: 1 }", "{symbol(\"MOD\"): 1};")
      expect_transpile('{ "a" => 1 }', '{"a": 1};')
    end

    it "transpiles ranges and boolean operators" do
      expect_transpile("1..3", "1 ..= 3;")
      expect_transpile("1...3", "1 ..< 3;")
      expect_transpile("a && b", "(a() && b());")
      expect_transpile("a || b", "(a() || b());")
    end

    it "transpiles nilable Ruby || as CLEAR fallback OR" do
      expect_transpile(
        <<~RUBY,
          class Emit < T::Struct
            prop :bc_op, T.nilable(Symbol), default: nil

            def op(default_name)
              bc_op || default_name
            end
          end
        RUBY
        <<~CLEAR
          STRUCT Emit {
            bc_op: ?String@symbol
          }

          FN op(self: Emit, default_name: Auto) RETURNS Auto ->
            (self.bc_op OR default_name);
          END
        CLEAR
      )
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
      expect_transpile("a = T.let(Set.new, T::Set[Integer]); a << 1", "MUTABLE a: Int64[]@set = Set[];\na.insert(1);")
      expect_transpile("rank = 1; rank = -rank", "MUTABLE rank = 1;\nrank = (-rank);")
      expect_transpile("rank = 1; rank = +rank", "MUTABLE rank = 1;\nrank = (+rank);")
      expect_transpile("nums = []; x = 1; !nums.include?(x)", "MUTABLE nums = [];\nMUTABLE x = 1;\n!(nums.contains?(x));")
    end

    it "lowers Ruby regex match operators to syntax-valid CLEAR calls in lax mode" do
      expect_transpile("word =~ /^[A-Z]/", 'regexMatch?(word(), "^[A-Z]");')
      expect_transpile("word !~ /^[A-Z]/", '!(regexMatch?(word(), "^[A-Z]"));')
    end

    it "lowers static Ruby type predicates to CLEAR type predicates" do
      expect_transpile("node.is_a?(AST::Identifier)", 'node() IS_A AST.Identifier;')
      expect_transpile("node.respond_to?(:line)", 'respondsTo?(node(), "line");')
    end

    it "lowers known module function calls to flattened CLEAR functions" do
      ruby_code = <<~RUBY
        module Schemas
          def self.struct?(schema)
            schema.is_a?(StructSchema)
          end
        end

        schema = nil
        Schemas.struct?(schema)
      RUBY
      expected_clear = <<~CLEAR
        # Ruby module Schemas
        FN struct?<T>(schema: T) RETURNS Auto ->
          T IS_A StructSchema;
        END
        # End Ruby module Schemas
        MUTABLE schema = NIL;
        struct?(schema);
      CLEAR

      expect_transpile(ruby_code, expected_clear)
    end

    it "assigns symbol parameters to struct fields without owned-string copies" do
      ruby_code = <<~RUBY
        class Entry < T::Struct
          const :visibility, Symbol

          sig { params(visibility: Symbol).void }
          def initialize(visibility)
            @visibility = T.let(visibility, Symbol)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Entry {
          visibility: String@symbol
        }

        FN initialize!(MUTABLE self: Entry, visibility: String@symbol) RETURNS Void ->
          self.visibility = visibility;
        END
      CLEAR

      expect_transpile(ruby_code, expected_clear)
    end

    it "drops bare freeze calls in initializer bodies" do
      ruby_code = <<~RUBY
        class Entry
          def initialize
            freeze
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Entry {

        }

        FN initialize!(MUTABLE self: Entry) RETURNS Void ->

        END
        FN entry__new() RETURNS Entry ->
          MUTABLE self = Entry{};
          initialize!(self);
          self;
        END
      CLEAR

      expect_transpile(ruby_code, expected_clear)
    end

    it "casts unknown to_s receivers to String" do
      expect_transpile("value.to_s", "CAST(value() AS String);")
    end

    it "lowers known sentinel identity checks to CLEAR type predicates" do
      ruby_code = <<~RUBY
        class TypeCapabilities
          UNSET = Object.new
          def same?(ownership)
            ownership.equal?(UNSET)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT TypeCapabilities {

        }

        FN same?(self: TypeCapabilities, ownership: Auto) RETURNS Auto ->
          ownership IS_A TypeCapabilityUnset;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "guards sentinel identity checks on optional union aliases" do
      ruby_code = <<~RUBY
        class TypeCapabilityUnset < T::Struct
        end

        class TypeCapabilities
          UNSET = TypeCapabilityUnset.new
          MaybeSymbol = T.type_alias { T.any(TypeCapabilityUnset, Symbol, NilClass) }
          sig { params(ownership: MaybeSymbol).returns(T::Boolean) }
          def unset?(ownership = UNSET)
            ownership.equal?(UNSET)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT TypeCapabilityUnset {

        }
        STRUCT TypeCapabilities {

        }

        UNION TypeCapabilitiesMaybeSymbol { TypeCapabilityUnset: TypeCapabilityUnset, SymbolValue: String@symbol }
        FN unset?(self: TypeCapabilities, ownership = TypeCapabilitiesMaybeSymbol{ TypeCapabilityUnset: TypeCapabilityUnset{} }: ?TypeCapabilitiesMaybeSymbol) RETURNS Bool ->
          ((ownership != NIL) && (ownership? IS_A TypeCapabilityUnset));
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "extracts payloads from sentinel unions for Sorbet casts" do
      ruby_code = <<~RUBY
        class TypeCapabilityUnset < T::Struct
        end

        class TypeCapabilities
          UNSET = TypeCapabilityUnset.new
          MaybeSymbol = T.type_alias { T.any(TypeCapabilityUnset, Symbol, NilClass) }
          sig { params(ownership: MaybeSymbol).returns(T.nilable(Symbol)) }
          def extract(ownership = UNSET)
            ownership.equal?(UNSET) ? nil : T.cast(ownership, T.nilable(Symbol))
          end
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("castOptionalTypeCapabilitiesMaybeSymbolToOptionalStringSymbol(ownership)")
      expect(clear).to include("FN castOptionalTypeCapabilitiesMaybeSymbolToOptionalStringSymbol(value: ?TypeCapabilitiesMaybeSymbol) RETURNS ?String@symbol ->")
      expect(clear).to include("IF value? IS_A String@symbol AS cast_payload THEN")
      expect(clear).to include("RETURN NIL;")
    end

    it "transpiles index access and assignments" do
      expect_transpile("states = {}; key = 1; states[key]", "MUTABLE states = {};\nMUTABLE key = 1;\nstates[key];")
      expect_transpile("states = {}; key = 1; value = 2; states[key] = value", "MUTABLE states = {};\nMUTABLE key = 1;\nMUTABLE value = 2;\nstates[key] = value;")
      expect_transpile("line = 'abc'; line[0]", "MUTABLE line = \"abc\";\nline.substr(0, 1);")
      expect_transpile("line = 'abc'; line[1, 2]", "MUTABLE line = \"abc\";\nline.substr(1, 2);")
      expect_transpile("line = 'abc'; line[1..2]", "MUTABLE line = \"abc\";\nline.substr(1, ((2 - 1) + 1));")
      expect_transpile("line = 'abc'; line[1..]", "MUTABLE line = \"abc\";\nline.substr(1, (line.length() - 1));")
      expect_transpile("parts = split_name; parts.drop(1)", "MUTABLE parts = split_name();\nparts |> SKIP 1;")
    end

    it "transpiles standard method calls" do
      expect_transpile("pattern = 'abc'; scan(pattern)", "MUTABLE pattern = \"abc\";\nscan(pattern);")
      expect_transpile("obj = nil; pattern = 'abc'; obj.scan(pattern)", "MUTABLE obj = NIL;\nMUTABLE pattern = \"abc\";\nobj.scan(pattern);")
    end

    it "lowers String#to_sym to a symbol conversion" do
      ruby_code = <<~RUBY
        sig { params(core_str: String).returns(Symbol) }
        def raw_symbol(core_str)
          core_str.to_sym
        end
      RUBY
      expected_clear = <<~CLEAR
        FN raw_symbol(core_str: String) RETURNS String@symbol ->
          symbol(core_str);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Symbol#to_s#to_sym through an explicit string cast" do
      ruby_code = <<~RUBY
        sig { params(name: Symbol).returns(Symbol) }
        def re_symbol(name)
          name.to_s.to_sym
        end
      RUBY
      expected_clear = <<~CLEAR
        FN re_symbol(name: String@symbol) RETURNS String@symbol ->
          symbol(CAST(name AS String));
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Symbol#to_s to the receiver" do
      ruby_code = <<~RUBY
        sig { params(name: Symbol).returns(String) }
        def symbol_name(name)
          name.to_s
        end
      RUBY
      expected_clear = <<~CLEAR
        FN symbol_name(name: String@symbol) RETURNS String ->
          CAST(name AS String);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Integer#to_s to Clear toString" do
      ruby_code = <<~RUBY
        sig { params(count: Integer).returns(String) }
        def count_name(count)
          count.to_s
        end
      RUBY
      expected_clear = <<~CLEAR
        FN count_name(count: Int64) RETURNS String ->
          count.toString();
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Symbol field to_s to the receiver" do
      ruby_code = <<~RUBY
        class Item < T::Struct
          const :kind, Symbol

          sig { returns(String) }
          def display
            kind.to_s
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Item {
          kind: String@symbol
        }

        FN display(self: Item) RETURNS String ->
          CAST(self.kind AS String);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
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
          IF flag THEN
            RETURN :left;
          ELSE
            RETURN :right;
          END
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

    it "does not auto-return nested case statements from value-returning methods" do
      ruby_code = <<~RUBY
        sig { returns(T::Boolean) }
        def done
          while active?
            case
            when ready? then step
            else stop
            end
          end
          return true
        end
      RUBY
      expected_clear = <<~CLEAR
        FN done() RETURNS Bool ->
          WHILE active?() DO
            IF ready?() THEN
              step();
            ELSE
              stop();
            END
          END
          RETURN TRUE;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles target case statements with multi-statement arms as condition chains" do
      ruby_code = <<~RUBY
        sig { params(token: Symbol).returns(T::Boolean) }
        def check(token)
          depth = T.let(1, Integer)
          case token
          when :close
            depth -= 1
            return false if depth <= 0
          when :semi
            return false if depth == 1
          end
          return true
        end
      RUBY
      expected_clear = <<~CLEAR
        FN check(token: String@symbol) RETURNS Bool ->
          MUTABLE depth: Int64 = 1;
          IF (token == :close) THEN
            depth = (depth - 1);
            IF (depth <= 0) THEN
              RETURN FALSE;
            END
          ELSE_IF (token == :semi) THEN
            IF (depth == 1) THEN
              RETURN FALSE;
            END
          END
          RETURN TRUE;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles return case expressions with expression match arms" do
      ruby_code = <<~RUBY
        def pick(value)
          return case value
          when :a then 1
          when :b then 2
          else 99
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        FN pick(value: Auto) RETURNS Auto ->
          RETURN PARTIAL MATCH value START
            :a -> 1,
            :b -> 2,
            DEFAULT -> 99
          END;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "returns final case expressions from methods" do
      ruby_code = <<~RUBY
        def pick(value)
          case value
          when :a then 1
          when :b then 2
          else 99
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        FN pick(value: Auto) RETURNS Auto ->
          RETURN PARTIAL MATCH value START
            :a -> 1,
            :b -> 2,
            DEFAULT -> 99
          END;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "returns final case statements with multi-statement arms using branch returns" do
      ruby_code = <<~RUBY
        sig { params(kind: Symbol).returns(Integer) }
        def resolve(kind)
          case kind
          when :a
            value = 1
            value
          else
            2
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        FN resolve(kind: String@symbol) RETURNS Int64 ->
          IF (kind == :a) THEN
            MUTABLE value = 1;
            RETURN value;
          ELSE
            RETURN 2;
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "returns nil from case expressions without an else" do
      ruby_code = <<~RUBY
        def pick(value)
          case value
          when :a then :a
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        FN pick(value: Auto) RETURNS Auto ->
          RETURN PARTIAL MATCH value START
            :a -> :a,
            DEFAULT -> NIL
          END;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles splatted case arms as membership checks" do
      ruby_code = <<~RUBY
        case key
        when *EMIT_BOOL
          truthy
        when :other
          other
        end
      RUBY
      expected_clear = <<~CLEAR
        IF EMIT_BOOL.contains?(key()) THEN
          truthy();
        ELSE_IF (key() == :other) THEN
          other();
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

    it "transpiles Ruby yield as an explicit yield call" do
      ruby_code = <<~RUBY
        def walk(node)
          yield node
        end
      RUBY
      expected_clear = <<~CLEAR
        FN walk(node: Auto) RETURNS Auto ->
          yield(node);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Ruby raise calls to the compiler panic intrinsic" do
      expect_transpile('raise "bad"', 'panic("bad");')
      expect_transpile('Kernel.raise "bad"', 'panic("bad");')
      expect_transpile('raise ArgumentError, "bad"', 'panic("bad");')
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

    it "marks generated structs public with a ruby-to-clear annotation" do
      ruby_code = <<~RUBY
        # ruby-to-clear: pub
        Param = Struct.new(:takes)
      RUBY
      expected_clear = <<~CLEAR
        PUB STRUCT Param {
          takes: Any
        }
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "reads Struct.new fields from indexed typed arrays without method-call syntax" do
      ruby_code = <<~RUBY
        Param = Struct.new(:takes)
        params = T.let([], T::Array[Param])
        params.each_with_index { |param, index| param.takes }
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("params[rtoc_idx].takes;")
      expect(clear).not_to include("params[rtoc_idx].takes()")
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

    it "transpiles classes inheriting from Struct.new as structs" do
      ruby_code = <<~RUBY
        class Param < Struct.new(:name, :type, keyword_init: true)
          def type
            self[:type]
          end
        end

        p = AST::Param.new(name: "value", type: :String)
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Param {
          name: Any,
          type: Any
        }

        FN type(self: Param) RETURNS Auto ->
          self[:type];
        END
        MUTABLE p = Param{ name: "value", type: :String };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses same-file T::Struct metadata even when the struct has methods" do
      ruby_code = <<~RUBY
        class Action < T::Struct
          const :name, String

          def copy
            Action.new(name: name)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Action {
          name: String
        }

        FN copy(self: Action) RETURNS Auto ->
          Action{ name: COPY self.name };
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "passes self for bare same-class instance method calls" do
      ruby_code = <<~RUBY
        class ZigType
          def error_union?
            @flag
          end

          def fallible_return_type
            error_union?
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT ZigType {
          flag: Any
        }

        FN error_union?(self: ZigType) RETURNS Auto ->
          self.flag;
        END
        FN fallible_return_type(self: ZigType) RETURNS Auto ->
          error_union?(self);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "does not emit a duplicate struct for reopened classes" do
      ruby_code = <<~RUBY
        class Type
          def initialize(raw)
            @raw = raw
          end
        end

        class Type
          def raw_value
            raw
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Type {
          raw: Any
        }

        FN initialize!(MUTABLE self: Type, raw: Auto) RETURNS Void ->
          self.raw = raw;
        END
        FN type__new(raw: Auto) RETURNS Type ->
          MUTABLE self = Type{ raw: raw };
          initialize!(self, raw);
          self;
        END
        FN raw_value(self: Type) RETURNS Auto ->
          self.raw;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "mangles duplicate instance method names across classes and rewrites typed calls" do
      ruby_code = <<~RUBY
        class A
          sig { params(other: B).returns(Integer) }
          def take(other)
            other.copy
          end

          def copy
            1
          end
        end

        class B
          def copy
            2
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT A {

        }

        FN take(self: A, other: B) RETURNS Int64 ->
          b__copy(other);
        END
        FN a__copy(self: A) RETURNS Auto ->
          1;
        END
        STRUCT B {

        }

        FN b__copy(self: B) RETURNS Auto ->
          2;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "mangles duplicate constructors across classes" do
      ruby_code = <<~RUBY
        class A
          def initialize(value)
            @value = value
          end
        end

        class B
          def initialize(value)
            @value = value
          end
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN a__initialize!(MUTABLE self: A, value: Auto) RETURNS Void")
      expect(clear).to include("FN b__initialize!(MUTABLE self: B, value: Auto) RETURNS Void")
      expect(clear).not_to include("FN initialize!")
    end

    it "transpiles zero-field T::Struct classes and constructors" do
      ruby_code = <<~RUBY
        class Marker < T::Struct
        end

        Marker.new
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Marker {

        }
        Marker{};
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "fills omitted T::Struct constructor fields from declared defaults" do
      ruby_code = <<~RUBY
        class Parts < T::Struct
          const :array, T::Boolean, default: false
          const :name, T.nilable(Symbol), default: nil
          const :items, T::Array[Symbol], default: []
        end

        Parts.new
        Parts.new(array: true)
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Parts {
          array: Bool,
          name: ?String@symbol,
          items: String[]
        }
        Parts{ array: FALSE, name: NIL, items: [] };
        Parts{ array: TRUE, name: NIL, items: [] };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses empty Set defaults for set-typed struct fields" do
      ruby_code = <<~RUBY
        class EnumSchema
          def initialize
            @variants = T.let(Set.new, T::Set[String])
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT EnumSchema {
          variants: String[]@set
        }

        FN initialize!(MUTABLE self: EnumSchema) RETURNS Void ->
          self.variants = Set[];
        END
        FN enumSchema__new() RETURNS EnumSchema ->
          MUTABLE self = EnumSchema{ variants: Set[] };
          initialize!(self);
          self;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "copies string locals for known constructor string fields" do
      ruby_code = <<~RUBY
        class Action < T::Struct
          const :name, String
        end

        sig { params(name: String).returns(Action) }
        def build(name)
          Action.new(name: name)
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Action {
          name: String
        }
        FN build(name: String) RETURNS Action ->
          Action{ name: COPY name };
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "maps bare new inside class methods to the same T::Struct constructor" do
      ruby_code = <<~RUBY
        class Parts < T::Struct
          const :left, String
          const :right, String

          def self.empty
            new(left: "L", right: "R")
          end
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include('Parts{ left: "L", right: "R" }')
      expect(clear).not_to include("new({")
    end

    it "lowers T::Struct with keyword overrides" do
      ruby_code = <<~RUBY
        class Shape < T::Struct
          const :name, String
          const :items, T::Array[String], default: []

          sig { returns(Shape) }
          def copy
            with(items: items.dup)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Shape {
          name: String,
          items: String[]
        }

        FN copy(self: Shape) RETURNS Shape ->
          Shape{ name: self.name, items: COPY self.items };
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "infers T::Struct field types for local union narrowing" do
      ruby_code = <<~RUBY
        Raw = T.type_alias { T.any(FunctionSignature, Symbol) }
        class Shape < T::Struct
          const :raw, Raw

          sig { returns(Symbol) }
          def resolved
            current_raw = raw
            if current_raw.is_a?(FunctionSignature)
              current_raw.return_type.to_sym
            elsif current_raw.is_a?(Symbol)
              current_raw
            else
              :Any
            end
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Raw { FunctionSignature: FunctionSignature, SymbolValue: String@symbol }
        STRUCT Shape {
          raw: Raw
        }

        FN resolved(self: Shape) RETURNS String@symbol ->
          MUTABLE current_raw = self.raw;
          IF current_raw IS_A FunctionSignature AS function_signature THEN
            function_signature.return_type().to_sym();
          ELSE_IF current_raw IS_A String@symbol AS string_symbol THEN
            string_symbol;
          ELSE
            :Any;
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "narrows elsif runtime union predicates with payload bindings" do
      ruby_code = <<~RUBY
        Raw = T.type_alias { T.any(FunctionSignature, Symbol, String) }
        class Shape < T::Struct
          const :raw, Raw

          sig { returns(Symbol) }
          def resolved
            current_raw = raw
            if current_raw.is_a?(FunctionSignature)
              current_raw.return_type.to_sym
            elsif current_raw.is_a?(String)
              current_raw.to_sym
            elsif current_raw.is_a?(Symbol)
              current_raw
            else
              :Any
            end
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Raw { FunctionSignature: FunctionSignature, SymbolValue: String@symbol, StringValue: String }
        STRUCT Shape {
          raw: Raw
        }

        FN resolved(self: Shape) RETURNS String@symbol ->
          MUTABLE current_raw = self.raw;
          IF current_raw IS_A FunctionSignature AS function_signature THEN
            function_signature.return_type().to_sym();
          ELSE_IF current_raw IS_A String AS string THEN
            symbol(string);
          ELSE_IF current_raw IS_A String@symbol AS string_symbol THEN
            string_symbol;
          ELSE
            :Any;
          END
        END
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

    it "maps keyword calls to class methods inside singleton method bodies" do
      ruby_code = <<~RUBY
        class TypeShape
          def self.from_core(shape_str)
            parse_generic_shape(shape_str, array: true, map: false)
          end

          def self.parse_generic_shape(shape_str, array:, map:)
            shape_str
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        FN from_core(shape_str: Auto) RETURNS Auto ->
          parse_generic_shape(shape_str, TRUE, FALSE);
        END
        FN parse_generic_shape(shape_str: Auto, array: Auto, map: Auto) RETURNS Auto ->
          shape_str;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "maps keyword calls to constant-receiver class methods" do
      ruby_code = <<~RUBY
        class TypeShape
          sig { params(core_str: String, auto: T::Boolean).returns(String) }
          def self.from_core(core_str, auto: false)
            core_str
          end
        end

        flag = true
        TypeShape.from_core("Int64", auto: flag)
      RUBY
      expected_clear = <<~CLEAR
        FN from_core(core_str: String, auto = FALSE: Bool) RETURNS String ->
          core_str;
        END
        MUTABLE flag = TRUE;
        from_core("Int64", flag);
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
        "error!(token(), :CODE, {:value: current().value(), :type: current().type()});"
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
        FN type__new(raw_input: Auto, ownership = NIL: Auto, sync = NIL: Auto) RETURNS Type ->
          MUTABLE self = Type{};
          initialize!(self, raw_input, ownership, sync);
          self;
        END
        type__new(:Int64, NIL, :atomic);
        type__new(:String);
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
        FN parser__new() RETURNS Parser ->
          MUTABLE self = Parser{ value: 1 };
          initialize!(self);
          self;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "does not emit empty structs for namespace-only classes" do
      ruby_code = <<~RUBY
        class Parser
          class Rule < T::Struct
            const :name, Symbol
          end

          def self.rule(name)
            Rule.new(name: name)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Rule {
          name: String@symbol
        }
        FN rule(name: Auto) RETURNS Auto ->
          Rule{ name: name };
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses require_relative struct metadata for positional constructors when transpiling files" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ast.rb"), "module AST\n  Pair = Struct.new(:left, :right)\nend\n")
        source_path = File.join(dir, "parser.rb")
        File.write(source_path, "require_relative './ast'\nAST::Pair.new(1, 2)\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq(<<~CLEAR.strip)
          REQUIRE "ast.clear"
          Pair{ left: 1, right: 2 };
        CLEAR
      end
    end

    it "uses require_relative struct metadata for keyword constructors when transpiling files" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ast.rb"), "module AST\n  Pair = Struct.new(:left, :right, keyword_init: true)\nend\n")
        source_path = File.join(dir, "parser.rb")
        File.write(source_path, "require_relative './ast'\nAST::Pair.new(left: 1, right: 2)\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq(<<~CLEAR.strip)
          REQUIRE "ast.clear"
          Pair{ left: 1, right: 2 };
        CLEAR
      end
    end

    it "emits unguarded local require_relative calls as CLEAR requires" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "parser_rules.rb"), "class Rule < T::Struct\n  const :name, Symbol\nend\n")
        source_path = File.join(dir, "parser.rb")
        File.write(source_path, "require_relative './parser_rules'\nclass Parser\nend\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq(<<~CLEAR.strip)
          REQUIRE "parser_rules.clear"
        CLEAR
      end
    end

    it "uses metadata from no-require require_relative calls without emitting CLEAR requires" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ast.rb"), "module AST\n  Pair = Struct.new(:left, :right, keyword_init: true)\nend\n")
        source_path = File.join(dir, "parser.rb")
        File.write(source_path, "require_relative './ast' # ruby-to-clear: no-require\nAST::Pair.new(left: 1, right: 2)\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq("Pair{ left: 1, right: 2 };")
      end
    end

    it "emits CLEAR requires for namespace module function dependencies" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "schemas.rb"), <<~RUBY)
          module Schemas
            def self.struct?(schema)
              schema.is_a?(StructSchema)
            end
          end
        RUBY
        source_path = File.join(dir, "type.rb")
        File.write(source_path, "schema = nil\nSchemas.struct?(schema)\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq(<<~CLEAR.strip)
          REQUIRE "schemas.clear"
          MUTABLE schema = NIL;
          struct?(schema);
        CLEAR
      end
    end

    it "does not collect the current file as imported metadata through circular requires" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "type.rb"), <<~RUBY)
          require_relative './schemas'

          class Type
            TypeInput = T.type_alias { T.any(Type, Symbol, String) }
          end
        RUBY
        source_path = File.join(dir, "schemas.rb")
        File.write(source_path, <<~RUBY)
          require_relative './type'

          module Schemas
            class InlineStructVariant
            end

            class UnionSchema
              VariantValue = T.type_alias { T.nilable(T.any(Type::TypeInput, Schemas::InlineStructVariant)) }
              sig { params(value: VariantValue).returns(VariantValue) }
              def keep(value)
                value
              end
            end
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include("UNION UnionSchemaVariantValue { TypeTypeInput: TypeTypeInput, InlineStructVariant: InlineStructVariant }")
        expect(clear).not_to include("TypeInput: TypeInput")
      end
    end

    it "casts alias-equivalent imported union members through local T.cast assignments" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "schemas.rb"), <<~RUBY)
          require_relative './type'

          module Schemas
            class InlineStructVariant
            end

            class UnionSchema
              VariantValue = T.type_alias { T.nilable(T.any(Type::TypeInput, Schemas::InlineStructVariant)) }
            end
          end
        RUBY
        source_path = File.join(dir, "type.rb")
        File.write(source_path, <<~RUBY)
          require_relative './schemas'

          class Type
            TypeInput = T.type_alias { T.any(Type, Symbol, String) }
            sig { params(value: Schemas::UnionSchema::VariantValue).returns(T.nilable(TypeInput)) }
            def self.cast_variant(value)
              return nil unless value

              typed = T.cast(T.must(value), T.nilable(TypeInput))
              typed
            end
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include("MUTABLE typed: ?TypeTypeInput = castUnionSchemaVariantValueToOptionalTypeTypeInput(value?);")
        expect(clear).to include("FN castUnionSchemaVariantValueToOptionalTypeTypeInput(value: UnionSchemaVariantValue) RETURNS ?TypeTypeInput ->")
      end
    end

    it "uses namespace metadata for typed block locals without explicit local requires" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "ast"))
        FileUtils.mkdir_p(File.join(dir, "annotator", "helpers"))
        File.write(File.join(dir, "ast", "ast.rb"), "module AST\n  Param = Struct.new(:takes)\nend\n")
        source_path = File.join(dir, "annotator", "helpers", "intrinsic_contract.rb")
        File.write(source_path, <<~RUBY)
          class IntrinsicContract
            sig { params(params: T::Array[AST::Param]).void }
            def self.normalized_takes_indices(params)
              params.each_with_index { |param, index| param.takes }
            end
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include("params[rtoc_idx].takes;")
        expect(clear).not_to include("params[rtoc_idx].takes()")
      end
    end

    it "does not emit duplicate structs for imported class extension files" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "core.rb"), <<~RUBY)
          class Signature
            def initialize(value)
              @value = value
            end
          end
        RUBY
        source_path = File.join(dir, "extension.rb")
        File.write(source_path, <<~RUBY)
          require_relative './core'

          class Signature
            def value_string
              value.to_s
            end
          end
        RUBY

        expect(RubyToClear.transpile_file(source_path).strip).to eq(<<~CLEAR.strip)
          REQUIRE "core.clear"
          FN value_string(self: Signature) RETURNS Auto ->
            CAST(self.value AS String);
          END
        CLEAR
      end
    end

    it "uses constructor metadata from guarded require_relative calls" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "lexer.rb"), "class Lexer\n  def initialize(source)\n  end\nend\n")
        source_path = File.join(dir, "parser_spec.rb")
        File.write(source_path, "require_relative './lexer' unless defined?(Lexer)\nLexer.new(src)\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq("lexer__new(src());")
      end
    end

    it "uses imported initialize keyword metadata from require_relative calls" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "type.rb"), "class Type\n  def initialize(raw_input, ownership: nil, sync: nil)\n  end\nend\n")
        source_path = File.join(dir, "schema.rb")
        File.write(source_path, "require_relative './type' unless defined?(Type)\nType.new(:Int64, sync: :atomic)\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq("type__new(:Int64, NIL, :atomic);")
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
        FN calc__new(start: Auto) RETURNS Calc ->
          MUTABLE self = Calc{ val: start };
          initialize!(self, start);
          self;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "marks instance methods mutable when they delegate to mutating helpers" do
      ruby_code = <<~RUBY
        class Type
          def apply_capabilities!(value)
            @capabilities = value
          end

          def ownership=(value)
            apply_capabilities!(value)
            value
          end

          def stamp(value)
            self.ownership = value
          end

          def ownership
            @capabilities
          end
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN apply_capabilities!(MUTABLE self: Type, value: Auto) RETURNS Auto")
      expect(clear).to include("FN set_ownership!(MUTABLE self: Type, value: Auto) RETURNS Auto")
      expect(clear).to include("FN stamp(MUTABLE self: Type, value: Auto) RETURNS Auto")
      expect(clear).to include("FN ownership(self: Type) RETURNS Auto")
    end

    it "does not mistake equality calls on self for setter mutation" do
      ruby_code = <<~RUBY
        class Type
          def accepts?(other)
            self == other
          end
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN accepts?(self: Type, other: Auto) RETURNS Auto")
      expect(clear).not_to include("FN accepts?(MUTABLE self: Type")
    end

    it "maps Ruby equality method definitions to CLEAR identifiers" do
      ruby_code = <<~RUBY
        class Pair
          def ==(other)
            other && other.left == left
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Pair {

        }

        FN equals?(self: Pair, other: Auto) RETURNS Auto EFFECTS REENTRANT ->
          (other && (other.left() == left()));
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses known method return types for method-call receivers" do
      ruby_code = <<~RUBY
        class Type
          sig { returns(Type) }
          def inner
            self
          end

          sig { returns(T::Boolean) }
          def fixed?
            true
          end

          sig { returns(T::Boolean) }
          def bounded?
            inner.fixed?
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Type {

        }

        FN inner(self: Type) RETURNS Type ->
          self;
        END
        FN fixed?(self: Type) RETURNS Bool ->
          TRUE;
        END
        FN bounded?(self: Type) RETURNS Bool ->
          fixed?(inner(self));
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "emits private class methods as PRIVATE functions" do
      ruby_code = <<~RUBY
        class Tools
          def self.helper(value)
            value
          end
          private_class_method :helper
        end
      RUBY
      expected_clear = <<~CLEAR
        PRIVATE FN helper(value: Auto) RETURNS Auto ->
          value;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "marks generated functions private with a ruby-to-clear annotation" do
      ruby_code = <<~RUBY
        class Tools
          extend T::Sig

          # ruby-to-clear: private
          sig { params(value: T.untyped).returns(T.untyped) }
          def self.helper(value)
            value
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        PRIVATE FN helper(value: Auto) RETURNS Auto ->
          value;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "marks generated functions reentrant with a ruby-to-clear annotation" do
      ruby_code = <<~RUBY
        class Tools
          # ruby-to-clear: effects reentrant
          def self.walk(n)
            return 0 if n == 0
            walk(n - 1)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        FN walk(n: Auto) RETURNS Auto EFFECTS REENTRANT ->
          IF (n == 0) THEN
            RETURN 0;
          END
          walk((n - 1));
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "finds declaration annotations after non-ascii source text" do
      ruby_code = <<~RUBY
        # cafe accented: é
        class Tools
          sig { returns(Integer) }
          # ruby-to-clear: effects reentrant
          def self.value
            1
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        FN value() RETURNS Int64 EFFECTS REENTRANT ->
          1;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "marks generated functions reentrant when recursion is inferred" do
      ruby_code = <<~RUBY
        class Type
          sig { params(other: Type).returns(T::Boolean) }
          def accepts?(other)
            return true if self == other

            other.accepts?(self)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Type {

        }

        FN accepts?(self: Type, other: Type) RETURNS Bool EFFECTS REENTRANT ->
          IF (self == other) THEN
            RETURN TRUE;
          END
          accepts?(other, self);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "omits generated functions with a ruby-to-clear skip annotation" do
      ruby_code = <<~RUBY
        class Tools
          # ruby-to-clear: skip
          sig { params(value: T.untyped).returns(T.untyped) }
          def self.ruby_only(value)
            value.params
          end

          def self.clear_entry
            1
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        FN clear_entry() RETURNS Auto ->
          1;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "flattens constant receiver class method calls" do
      ruby_code = <<~RUBY
        class Tools
          def self.helper(value)
            value
          end

          def run
            Tools.helper(1)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Tools {

        }

        FN helper(value: Auto) RETURNS Auto ->
          value;
        END
        FN run(self: Tools) RETURNS Auto ->
          helper(1);
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
        FN lexer__new(source: Auto) RETURNS Lexer ->
          MUTABLE self = Lexer{ line: 1, s: Scanner{ source: source, pos: 0 }, tokens: [] };
          initialize!(self, source);
          self;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "expands non-emitted qualified Sorbet aliases for generated instance fields" do
      ruby_code = <<~RUBY
        module Schemas
          class InlineStructVariant
            FieldMap = T.type_alias { T::Hash[T.any(String, Symbol), String] }
            FieldInputMap = T.type_alias { T::Hash[T.any(String, Symbol), String] }

            sig { params(fields: FieldInputMap).void }
            def initialize(fields:)
              @fields = T.let(fields.dup, Schemas::InlineStructVariant::FieldMap)
            end
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        # Ruby module Schemas
        STRUCT InlineStructVariant {
          fields: HashMap<String, String>
        }

        FN initialize!(MUTABLE self: InlineStructVariant, fields: HashMap<String, String>) RETURNS Void ->
          self.fields = COPY fields;
        END
        FN inlineStructVariant__new(fields: HashMap<String, String>) RETURNS InlineStructVariant ->
          MUTABLE self = InlineStructVariant{ fields: COPY fields };
          initialize!(self, fields);
          self;
        END
        # End Ruby module Schemas
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "recursively expands non-emitted aliases inside generated instance field containers" do
      ruby_code = <<~RUBY
        module Schemas
          class ResourceSchema
            StaticMethodValue = T.type_alias { T.any(T::Array[Symbol], Symbol, String, T::Boolean) }
            StaticMethodSpec = T.type_alias { T::Hash[Symbol, StaticMethodValue] }
            StaticMethodsMap = T.type_alias { T::Hash[String, StaticMethodSpec] }

            sig { params(static_methods: StaticMethodsMap).void }
            def initialize(static_methods: {})
              @static_methods = T.let(static_methods, Schemas::ResourceSchema::StaticMethodsMap)
            end
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        # Ruby module Schemas
        STRUCT ResourceSchema {
          static_methods: HashMap<String, HashMap<String, ResourceSchemaStaticMethodValue>>
        }

        UNION ResourceSchemaStaticMethodValue { ArrayValue: String[], SymbolValue: String@symbol, StringValue: String, BoolValue: Bool }
        FN initialize!(MUTABLE self: ResourceSchema, static_methods: HashMap<String, HashMap<String, ResourceSchemaStaticMethodValue>>) RETURNS Void ->
          self.static_methods = COPY static_methods;
        END
        FN resourceSchema__new(static_methods: HashMap<String, HashMap<String, ResourceSchemaStaticMethodValue>>) RETURNS ResourceSchema ->
          MUTABLE self = ResourceSchema{ static_methods: COPY static_methods };
          initialize!(self, static_methods);
          self;
        END
        # End Ruby module Schemas
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "copies string parameters stored directly in instance fields" do
      ruby_code = <<~RUBY
        class ZigType
          sig { params(source: String).void }
          def initialize(source)
            @source = T.let(source, String)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT ZigType {
          source: String
        }

        FN initialize!(MUTABLE self: ZigType, source: String) RETURNS Void ->
          self.source = COPY source;
        END
        FN zigType__new(source: String) RETURNS ZigType ->
          MUTABLE self = ZigType{ source: COPY source };
          initialize!(self, source);
          self;
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
      expect_transpile('words = []; words.map(&:strip)', "MUTABLE words = [];\nwords |> SELECT _.trim();")
      expect_transpile('words = []; words.map(&:to_sym)', "MUTABLE words = [];\nwords |> SELECT symbol(_);")
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

    it "leaves non-array predicate methods as ordinary calls" do
      ruby_code = <<~RUBY
        sig { params(type: Type).returns(T::Boolean) }
        def type_any(type)
          type.any?
        end
      RUBY
      expected_clear = <<~CLEAR
        FN type_any(type: Type) RETURNS Bool ->
          type.any?();
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles projection collection blocks" do
      expect_transpile("nums = []; nums.collect { |x| x * 2 }", "MUTABLE nums = [];\nnums |> SELECT (_ * 2);")
      expect_transpile("nums = []; nums.filter_map { |x| maybe(x) }", "MUTABLE nums = [];\nnums |> SELECT maybe(_) |> WHERE _ != NIL;")
      expect_transpile("nums = []; nums.filter { |x| x > 2 }", "MUTABLE nums = [];\nnums |> WHERE (_ > 2);")
      expect_transpile("groups = []; groups.flat_map { |g| g.items }", "MUTABLE groups = [];\ngroups |> UNNEST _.items();")
      expect_transpile("items = []; items.sort_by { |item| item.name }", "MUTABLE items = [];\nitems |> ORDER_BY _.name();")
    end

    it "allows next inside effect-only each blocks" do
      ruby_code = <<~RUBY
        items = []
        items.each do |item|
          next if item.nil?
          puts item
        end
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE items = [];
        items |> EACH {
          IF (_ == NIL) THEN
            CONTINUE;
          END
          puts(_);
        };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
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

    it "leaves bare reduce/inject attr readers as ordinary calls" do
      expect_transpile("rule = get_rule; rule.inject", "MUTABLE rule = get_rule();\nrule.inject();")
      expect_transpile("rule = get_rule; rule.reduce", "MUTABLE rule = get_rule();\nrule.reduce();")
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
          MUTABLE body = read(path) OR RAISE;
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
      expect_transpile('{ a: 1 }.length', "{:a: 1}.count();")
      expect_transpile('table = {}; table.empty?', "MUTABLE table = {};\n(table.count() == 0);")
      expect_transpile('table = {}; table.size', "MUTABLE table = {};\ntable.count();")
      expect_transpile('"abc".empty?', "(\"abc\".length() == 0);")
      expect_transpile('name = "abc"; name.empty?', "MUTABLE name = \"abc\";\n(name.length() == 0);")
      expect_transpile('name = "abc"; name.split("b")', "MUTABLE name = \"abc\";\nname.split(\"b\");")
      expect_transpile('name = "abc"; name.delete_prefix("a")', "MUTABLE name = \"abc\";\nname.deletePrefix(\"a\");")
      expect_transpile('items = []; copy = items.dup', "MUTABLE items = [];\nMUTABLE copy = COPY items;")
      expect_transpile('name = "abc"; copy = name.dup', "MUTABLE name = \"abc\";\nMUTABLE copy = COPY name;")
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
      expect_transpile("shape = get_shape; shape.map", "MUTABLE shape = get_shape();\nshape.map();")
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

    it "lowers lexer scalar conversions with explicit helpers when Ruby needs a base or codepoint" do
      expect_transpile('hex.to_i(16)', "(toIntBase(hex(), 16) OR 0);")
      expect_transpile('hex.to_i(16).chr', "codepointToString((toIntBase(hex(), 16) OR 0));")
      expect_transpile('hex.to_i(16).chr(Encoding::UTF_8)', "codepointToString((toIntBase(hex(), 16) OR 0));")
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
        "MUTABLE items = get_items();\nitems IS_A Any[];"
      )
      expect_transpile(
        'items = get_items; items.is_a?(Hash)',
        "MUTABLE items = get_items();\nitems IS_A HashMap<Any>;"
      )
    end

    it "maps generic Ruby collection type checks to CLEAR collection types" do
      ruby_code = <<~RUBY
        sig { type_parameters(:T).params(raw: T.type_parameter(:T)).returns(Bool) }
        def hashish?(raw)
          raw.is_a?(Hash)
        end
      RUBY

      expected_clear = <<~CLEAR
        FN hashish?<T>(raw: T) RETURNS Bool ->
          T IS_A HashMap<Any>;
        END
      CLEAR

      expect_transpile(ruby_code, expected_clear)
    end

    it "narrows generic Ruby hash checks to concrete generated union map payloads" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(String, T::Hash[T.any(String, Symbol), Integer]) }
        sig { params(value: Value).returns(Bool) }
        def hash_value?(value)
          value.is_a?(Hash)
        end
      RUBY

      expected_clear = <<~CLEAR
        UNION Value { StringValue: String, HashMapValue: HashMap<String, Int64> }
        FN hash_value?(value: Value) RETURNS Bool ->
          value IS_A HashMap<String, Int64>;
        END
      CLEAR

      expect_transpile(ruby_code, expected_clear)
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
          MUTABLE value = 1;
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

    it "lowers interpolated regex patterns" do
      expect_transpile(
        'SUFFIX = /i32|u32/; scanner.scan(/0x_(#{SUFFIX})\b/o)',
        "MUTABLE suffix = \"i32|u32\";\nscanner().scan(\"0x_(${suffix})\\\\b\");"
      )
    end

    it "uses helper config for compiler regex and scanner lowering" do
      config = {
        "requires" => ["compiler_regex.clear"],
        "prelude" => ["EXTERN FN compilerRegexScan(scanner: CompilerRegexScanner, regex: CompilerRegex) RETURNS Bool EFFECTS :safe FROM \"compiler_regex\";"],
        "helpers" => {
          "regex_literal" => "compilerRegexCompile",
          "regex_interpolated_literal" => "compilerRegexCompile",
          "regex_pattern" => "compilerRegexPattern",
          "regex_match" => "compilerRegexMatch",
          "regex_match_data" => "compilerRegexMatchData",
          "regex_replace_first" => "compilerRegexReplaceFirst",
          "regex_escape" => "compilerRegexEscape",
          "scanner_new" => "compilerRegexScanner",
          "scanner_scan" => "compilerRegexScan",
          "scanner_matched" => "compilerRegexMatched",
          "scanner_capture" => "compilerRegexCapture",
          "string_to_int_base" => "compilerParseIntBase",
          "codepoint_to_string" => "compilerCodepointToString"
        },
        "scanner_receivers" => ["scanner"]
      }

      result = RubyToClear.transpile(<<~'RUBY', helper_config: config)
        scanner = StringScanner.new(source)
        SUFFIX = /i32|u32/
        scanner.scan(/0x_(#{SUFFIX})\b/o)
        scanner.matched.sub(/_#{Regexp.escape(suffix)}\z/, "")
        scanner[1]
        word =~ /^[A-Z]/
        hex.to_i(16).chr
      RUBY

      expect(result.strip).to eq(<<~CLEAR.strip)
        REQUIRE "compiler_regex.clear"
        EXTERN FN compilerRegexScan(scanner: CompilerRegexScanner, regex: CompilerRegex) RETURNS Bool EFFECTS :safe FROM "compiler_regex";
        MUTABLE scanner = compilerRegexScanner(source());
        MUTABLE suffix = compilerRegexCompile("i32|u32");
        compilerRegexScan(scanner, compilerRegexCompile("0x_(${compilerRegexPattern(suffix)})\\\\b"));
        compilerRegexReplaceFirst(compilerRegexMatched(scanner), compilerRegexCompile("_${compilerRegexEscape(suffix())}\\\\z"), "");
        compilerRegexCapture(scanner, 1);
        compilerRegexMatch(word(), compilerRegexCompile("^[A-Z]"));
        compilerCodepointToString(compilerParseIntBase(hex(), 16));
      CLEAR
    end

    it "lowers Ruby match data captures through compiler regex helpers" do
      config = {
        "helpers" => {
          "regex_literal" => "compilerRegexCompile",
          "regex_match_data" => "compilerRegexMatchData",
          "scanner_capture" => "compilerRegexCapture"
        }
      }

      result = RubyToClear.transpile(<<~RUBY, helper_config: config)
        sig { params(word: String).returns(T.nilable(Symbol)) }
        def capture(word)
          match = word.match(/^([A-Z]+)(\\d+)$/)
          return nil unless match
          match[1].to_sym
        end
      RUBY

      expect(result.strip).to eq(<<~CLEAR.strip)
        FN capture(word: String) RETURNS ?String@symbol ->
          MUTABLE match = compilerRegexMatchData(word, compilerRegexCompile("^([A-Z]+)(\\\\d+)$"));
          IF match THEN
            symbol(compilerRegexCapture(match?, 1));
          ELSE
            RETURN NIL;
          END
        END
      CLEAR
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
        "MUTABLE keywords: String[]@set = [\"A\"];\nkeywords.contains?(\"A\");"
      )
    end

    it "treats Ruby freeze calls as immutability scaffolding" do
      expect_transpile("values = %w[A].freeze", "MUTABLE values = [\"A\"];")
      expect_transpile(':"?#{name}"', 'symbol("?${name()}");')
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
        "MUTABLE items = [];\nMUTABLE rtoc_idx = 0;\nWHILE rtoc_idx < items.length() DO\n  puts(items[rtoc_idx]);\n  rtoc_idx = rtoc_idx + 1;\nEND"
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
          MUTABLE x: Int64 = 0;
          IF cond THEN
            x = 42;
          END
          x;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "preserves T.let types on pre-declared locals" do
      ruby_code = <<~RUBY
        def test_fn(flag)
          x = T.let(flag ? true : false, T::Boolean)
          x
        end
      RUBY
      expected_clear = <<~CLEAR
        FN test_fn(flag: Auto) RETURNS Auto ->
          MUTABLE x: Bool = FALSE;
          IF flag THEN
            x = TRUE;
          ELSE
            x = FALSE;
          END
          x;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "keeps branch-only locals inside the branch scope" do
      ruby_code = <<~RUBY
        sig { params(s: String).returns(Void) }
        def test_fn(s)
          if s.start_with?("~")
            x = T.must(s[1..])
            x.start_with?("~")
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        FN test_fn(s: String) RETURNS Void ->
          IF s.startsWith?("~") THEN
            MUTABLE x = s.substr(1, (s.length() - 1));
            x.startsWith?("~");
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses narrowed hash value types on branch-local locals" do
      ruby_code = <<~RUBY
        class StructSchema
          sig { params(fields: T::Hash[String, Integer]).void }
          def initialize(fields)
            @fields = T.let(fields, T::Hash[String, Integer])
          end
        end

        SchemaLookupResult = T.type_alias { T.any(StructSchema, String) }

        sig { params(schema_value: SchemaLookupResult).returns(Integer) }
        def count_values(schema_value)
          if schema_value.is_a?(StructSchema)
            fields = schema_value.fields.values
            i = T.let(0, Integer)
            total = T.let(0, Integer)
            while i < fields.length
              total += fields[i]
              i += 1
            end
            return total
          end
          0
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE fields = struct_schema.fields.values();")
      expect(clear).to include("WHILE (i < fields.length()) DO")
    end

    it "narrows optional locals after nil guard exits" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(String, Integer) }

        sig { params(values: T::Array[T.nilable(Value)]).returns(Void) }
        def walk(values)
          i = T.let(0, Integer)
          while i < values.length
            vt = values.fetch(i)
            unless vt
              i += 1
              next
            end
            if vt.is_a?(String)
              vt.to_sym
            end
            i += 1
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF vt THEN")
      expect(clear).to include("IF vt IS_A String AS string THEN")
      expect(clear).not_to include("vt??")
    end

    it "does not unwrap optional-guard locals in runtime type-test else branches" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(String, Integer) }

        sig { params(value: Value).returns(Void) }
        def keep(value)
        end

        sig { params(values: T::Array[T.nilable(Value)]).returns(Void) }
        def walk(values)
          vt = values.fetch(0)
          return unless vt

          if vt.is_a?(String)
            vt.to_sym
          else
            keep(T.must(vt))
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to match(/IF vt\?? IS_A String AS string THEN/)
      expect(clear).to include("keep(vt);")
      expect(clear).not_to include("keep(vt?);")
    end

    it "unwraps non-union optional locals after nil guard exits" do
      ruby_code = <<~RUBY
        sig { params(value: String).returns(String) }
        def keep(value)
          value
        end

        sig { params(value: T.nilable(String)).returns(String) }
        def keep_optional(value)
          return "" unless value

          return keep(value)
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF value THEN")
      expect(clear).to include("RETURN keep(value?);")
    end

    it "keeps T.must unwraps on non-union optional locals after nil guard exits" do
      ruby_code = <<~RUBY
        sig { params(value: String).returns(String) }
        def keep(value)
          value
        end

        sig { params(values: T::Array[T.nilable(String)]).returns(String) }
        def keep_first(values)
          value = values.fetch(0)
          return "" unless value

          return keep(T.must(value))
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN keep(value?);")
      expect(clear).not_to include("RETURN keep(value);")
    end

    it "predeclares optional element arrays with an empty array default" do
      ruby_code = <<~RUBY
        sig { params(flag: T::Boolean).returns(Void) }
        def test_fn(flag)
          if flag
            items = T.let([], T::Array[T.nilable(String)])
            items.length
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE items: ?String[] = [];")
      expect(clear).to include("items.length();")
    end

    it "does not predeclare non-defaultable struct locals with NIL as that struct" do
      ruby_code = <<~RUBY
        class Item
          sig { params(name: String).void }
          def initialize(name)
            @name = T.let(name, String)
          end
        end

        sig { params(flag: T::Boolean, items: T::Array[Item]).returns(Void) }
        def test_fn(flag, items)
          if flag
            item = items.fetch(0)
            item.name
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).not_to include("MUTABLE item = NIL;")
      expect(clear).not_to include("MUTABLE item: Item = NIL;")
      expect(clear).to include("MUTABLE item = items[0];")
    end

    it "infers typed field-reader values through hash values and loop fetches" do
      ruby_code = <<~RUBY
        module AST
          class StructField
            sig { params(type: String, borrowed: T::Boolean).void }
            def initialize(type:, borrowed: false)
              @type = T.let(type, String)
              @borrowed = T.let(borrowed, T::Boolean)
            end
          end
        end

        module Schemas
          class StructSchema
            sig { params(fields: T::Hash[String, AST::StructField]).void }
            def initialize(fields)
              @fields = T.let(fields, T::Hash[String, AST::StructField])
            end
          end
        end

        sig { params(schema: Schemas::StructSchema).returns(T::Boolean) }
        def has_borrowed_field?(schema)
          fields = schema.fields
          values = fields.values
          i = T.let(0, Integer)
          while i < values.length
            field = values.fetch(i)
            return true if field.borrowed
            i += 1
          end
          false
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).not_to include("MUTABLE field = NIL;")
      expect(clear).to include("MUTABLE fields = schema.fields;")
      expect(clear).to include("MUTABLE values = fields.values();")
      expect(clear).to include("MUTABLE field = values[i];")
      expect(clear).to include("IF field.borrowed THEN")
    end

    it "narrows through schema helper predicates" do
      ruby_code = <<~RUBY
        module Schemas
          class StructSchema
            sig { params(fields: T::Hash[String, Integer]).void }
            def initialize(fields)
              @fields = T.let(fields, T::Hash[String, Integer])
            end
          end

          sig { params(schema: T.untyped).returns(T::Boolean) }
          def self.struct?(schema)
            schema.is_a?(StructSchema)
          end
        end

        SchemaLookupResult = T.type_alias { T.any(Schemas::StructSchema, String) }

        sig { params(schema: SchemaLookupResult).returns(Integer) }
        def count_fields(schema)
          return 0 unless Schemas.struct?(schema)
          fields = schema.fields.values
          fields.length
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF schema IS_A Schemas.StructSchema AS struct_schema THEN")
      expect(clear).to include("MUTABLE fields = struct_schema.fields.values();")
    end

    it "wraps namespaced narrowed values for generated union parameters" do
      ruby_code = <<~RUBY
        module Schemas
          class StructSchema
          end

          class ResourceSchema
          end
        end

        Schema = T.type_alias { T.any(Schemas::StructSchema, Schemas::ResourceSchema) }
        Value = T.type_alias { T.any(Schemas::StructSchema, String) }

        sig { params(schema: Schema).returns(Void) }
        def use_schema(schema)
        end

        sig { params(value: Value).returns(Void) }
        def call_use(value)
          if value.is_a?(Schemas::StructSchema)
            use_schema(value)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("use_schema(Schema{ StructSchema: COPY struct_schema });")
    end

    it "copies string local aliases from borrowed parameters and owned locals" do
      ruby_code = <<~RUBY
        sig { params(source: String).returns(String) }
        def alias_string(source)
          after_error_str = source
          shape_str = after_error_str
          shape_str
        end
      RUBY
      expected_clear = <<~CLEAR
        FN alias_string(source: String) RETURNS String ->
          MUTABLE after_error_str = COPY source;
          MUTABLE shape_str = COPY after_error_str;
          shape_str;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "does not copy symbol local aliases" do
      ruby_code = <<~RUBY
        sig { params(kind: Symbol).returns(Symbol) }
        def alias_symbol(kind)
          other = kind
          other
        end
      RUBY
      expected_clear = <<~CLEAR
        FN alias_symbol(kind: String@symbol) RETURNS String@symbol ->
          MUTABLE other = kind;
          other;
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
      expect_transpile("test_call(a: 1)", "test_call({:a: 1});")
    end

    it "uses expression placeholders for unsupported keyword constructors in lax mode" do
      expect(RubyToClear.transpile("fix = Edit.new(span: span)", raise_on_error: false).strip).to eq(
        'MUTABLE fix = unsupportedRuby("KeywordHashNode at 1:15: Keyword arguments are not supported for this constructor");'
      )
      expect(RubyToClear.transpile("error!(code: :BAD)", raise_on_error: false).strip).to eq(
        "error!({:code: :BAD});"
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

    it "translates rest and keyword-rest parameters as explicit collection parameters" do
      ruby_code = <<~RUBY
        def emit(code, *args, **kwargs)
          format(code, args, kwargs)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN emit(code: Auto, args = []: Auto[], kwargs = {}: HashMap<String@symbol, Auto>) RETURNS Auto ->
          format(code, args, kwargs);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "maps keyword splats into explicit keyword-rest arguments when parameters are known" do
      ruby_code = <<~RUBY
        def emit(code, *args, **kwargs)
          format(code, args, kwargs)
        end

        emit(:BAD, value: name, **kwargs)
      RUBY
      expected_clear = <<~CLEAR
        FN emit(code: Auto, args = []: Auto[], kwargs = {}: HashMap<String@symbol, Auto>) RETURNS Auto ->
          format(code, args, kwargs);
        END
        emit(:BAD, [], mergeKwargs({:value: name()}, kwargs()));
      CLEAR
      expect_transpile(ruby_code, expected_clear)
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
          MUTABLE x = 1;
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
      expect_transpile("@type_object ||= fallback", "self.type_object = (self.type_object || fallback());")
      expect_transpile("@enabled &&= flag", "self.enabled = (self.enabled && flag());")
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

    it "loads AST::Node as a dependency-derived union and narrows locals assigned from typed calls" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ast.rb"), <<~RUBY)
          module AST
            module Locatable; end
            BinaryOp = Struct.new(:token, :op) { include Locatable }
            Identifier = Struct.new(:token, :name) { include Locatable }
            Node = T.type_alias { Locatable }
          end
        RUBY
        source_path = File.join(dir, "parser.rb")
        File.write(source_path, <<~RUBY)
          require_relative "./ast"
          sig { returns(AST::Node) }
          def parse_node
            AST::Identifier.new(nil, "x")
          end

          def handle
            node = parse_node
            if node.is_a?(AST::BinaryOp)
              node.op
            end
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include('REQUIRE "ast.clear"')
        expect(clear).to include("IF node IS_A AST.BinaryOp AS binary_op THEN")
        expect(clear).to include("binary_op.op;")
        expect(clear).not_to include("binary_op.op()")
      end
    end

    it "rewrites is_a? guard returns into narrowed branches for the remaining statements" do
      ruby_code = <<~RUBY
        Node = T.type_alias { T.any(AST::BinaryOp, AST::Identifier) }
        sig { params(node: Node).void }
        def validate(node)
          return unless node.is_a?(AST::BinaryOp)
          node.op
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Node { BinaryOp: BinaryOp, Identifier: Identifier }
        FN validate(node: Node) RETURNS Void ->
          IF node IS_A AST.BinaryOp AS binary_op THEN
            binary_op.op();
          ELSE
            RETURN;
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

    it "preserves typed array element fields inside value pipeline blocks" do
      ruby_code = <<~RUBY
        class Entry < T::Struct
          const :type, String
        end

        sig { params(entries: T::Array[Entry]).returns(T::Array[String]) }
        def names(entries)
          entries.map { |entry| entry.type }
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Entry {
          type: String
        }
        FN names(entries: Entry[]) RETURNS String[] ->
          entries |> SELECT _.type;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "compiles broader Sorbet scalar and collection type forms" do
      ruby_code = <<~RUBY
        sig { params(f: Float, n: NilClass, b: Boolean, t: TrueClass, f2: FalseClass, any_t: T, arr: T::Array, hash: T::Hash, set: T::Set, raw: T.untyped, anything: T.anything, broad: T.any(String, Object, T.untyped), either: T.any(String, Integer, NilClass), unknown_maybe: T.nilable(T::Class[T.anything]), enumerable: T::Enumerable[String]).void }
        def edge_types(f, n, b, t, f2, any_t, arr, hash, set, raw, anything, broad, either, unknown_maybe, enumerable)
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Either { StringValue: String, Int64Value: Int64 }
        FN edge_types(f: Float64, n: Void, b: Bool, t: Bool, f2: Bool, any_t: Auto, arr: Any, hash: Any, set: Any, raw: Auto, anything: Auto, broad: Any, either: ?Either, unknown_maybe: Auto, enumerable: String[]) RETURNS Void ->

        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "maps BasicObject to concrete Any for raw storage seams" do
      ruby_code = <<~RUBY
        sig { params(value: T.nilable(BasicObject)).void }
        def store(value)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN store(value: ?Any) RETURNS Void ->

        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "emits nested Sorbet union aliases inside collections" do
      ruby_code = <<~RUBY
        PatternItem = T.type_alias { T.any(String, Symbol, T::Hash[T.any(String, Symbol), Symbol]) }
        Pattern = T.type_alias { T::Array[PatternItem] }
        PatternCapture = T.type_alias { T.nilable(T.any(AST::Node, Type, String, Symbol, Integer, Float, T::Boolean)) }
        SigilAttrs = T.type_alias { T::Hash[Symbol, T.any(Symbol, T::Boolean)] }
        sig { params(item: PatternItem, pattern: Pattern, capture: PatternCapture, attrs: SigilAttrs).returns(PatternCapture) }
        def typed_aliases(item, pattern, capture, attrs)
          capture
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION PatternItem { StringValue: String, SymbolValue: String@symbol, HashMapValue: HashMap<String, String> }
        UNION PatternCapture { Node: Node, Type: Type, StringValue: String, SymbolValue: String@symbol, Int64Value: Int64, Float64Value: Float64, BoolValue: Bool }
        UNION SigilAttrsValue { SymbolValue: String@symbol, BoolValue: Bool }
        FN typed_aliases(item: PatternItem, pattern: PatternItem[], capture: ?PatternCapture, attrs: HashMap<String, SigilAttrsValue>) RETURNS ?PatternCapture ->
          capture;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "treats string-or-symbol hash keys as string maps and infers map index values" do
      ruby_code = <<~RUBY
        sig { params(table: T::Hash[T.any(String, Symbol), Integer], key: String).returns(Integer) }
        def fetch_value(table, key)
          value = T.must(table[key])
          value
        end
      RUBY
      expected_clear = <<~CLEAR
        FN fetch_value(table: HashMap<String, Int64>, key: String) RETURNS Int64 ->
          MUTABLE value = table[key]?;
          value;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Ruby fetch calls to Clear indexing" do
      expect_transpile(
        'items = T.let([], T::Array[T.nilable(String)]); item = items.fetch(0)',
        "MUTABLE items: ?String[] = [];\nMUTABLE item = items[0];"
      )
      expect_transpile(
        'items = T.let([], T::Array[String]); item = items.fetch(0)',
        "MUTABLE items: String[] = [];\nMUTABLE item = items[0];"
      )
      expect_transpile(
        'table = T.let({}, T::Hash[String, Integer]); value = table.fetch("missing", 0)',
        "MUTABLE table: HashMap<String, Int64> = {};\nMUTABLE value = (table[\"missing\"] OR 0);"
      )

      clear = RubyToClear.transpile(<<~RUBY)
        sig { params(flag: T::Boolean, items: T::Array[T.nilable(String)]).returns(Void) }
        def branch_fetch(flag, items)
          if flag
            item = items.fetch(0)
            item.nil?
          end
        end
      RUBY
      expect(clear).to include("IF flag THEN")
      expect(clear).to include("MUTABLE item = items[0];")
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
        MUTABLE maybe: ?String = COPY value;
        MUTABLE sure = COPY maybe?;
        MUTABLE unsafe = COPY sure;
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "tracks class method return types for local T.must unwrapping" do
      ruby_code = <<~RUBY
        class Type
          sig { returns(T.nilable(String)) }
          def self.schema_resolver
            "x"
          end
        end

        resolver = Type.schema_resolver
        sure = T.must(resolver)
      RUBY
      expected_clear = <<~CLEAR
        FN schema_resolver() RETURNS ?String ->
          "x";
        END
        MUTABLE resolver = schema_resolver();
        MUTABLE sure = COPY resolver?;
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "preserves T.let type metadata on constants" do
      ruby_code = <<~RUBY
        TABLE = T.let({ a: "A" }.freeze, T::Hash[Symbol, String])
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE table: HashMap<String, String> = {:a: "A"};
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "keeps typed string arrays distinct from string receivers" do
      ruby_code = 'parts = T.let(["a", "b"], T::Array[String]); parts[0]; parts[1].to_sym'
      expected_clear = <<~CLEAR
        MUTABLE parts: String[] = ["a", "b"];
        parts[0];
        symbol(parts[1]);
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "preserves untyped arrays as concrete union payloads" do
      ruby_code = <<~RUBY
        Raw = T.type_alias { T.any(FunctionSignature, T::Array[T.untyped], Symbol, String) }
        class Shape < T::Struct
          const :raw, Raw

          sig { params(name: String).returns(Shape) }
          def self.make(name)
            raw_symbol = name.to_sym
            Shape.new(raw: raw_symbol)
          end
        end
        Shape.new(raw: :Any)
      RUBY
      expected_clear = <<~CLEAR
        UNION Raw { FunctionSignature: FunctionSignature, ArrayValue: Any[], SymbolValue: String@symbol, StringValue: String }
        STRUCT Shape {
          raw: Raw
        }

        FN make(name: String) RETURNS Shape ->
          MUTABLE raw_symbol = symbol(name);
          Shape{ raw: Raw{ SymbolValue: raw_symbol } };
        END
        Shape{ raw: Raw{ SymbolValue: :Any } };
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
          MUTABLE x = 1;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "drops Ruby require and Sorbet extend scaffolding while preserving private visibility" do
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

        PRIVATE FN run(self: Thing) RETURNS Auto ->
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

    it "scopes nested Sorbet union aliases to their owning class" do
      ruby_code = <<~RUBY
        class TypeCapabilityUnset < T::Struct
        end

        class TypeCapabilities
          UNSET = TypeCapabilityUnset.new
          MaybeSymbol = T.type_alias { T.any(TypeCapabilityUnset, Symbol, NilClass) }
          sig { params(ownership: MaybeSymbol).returns(MaybeSymbol) }
          def keep(ownership = UNSET)
            ownership
          end
        end

        class TypePlacementUnset < T::Struct
        end

        class TypePlacement
          UNSET = TypePlacementUnset.new
          MaybeSymbol = T.type_alias { T.any(TypePlacementUnset, Symbol, NilClass) }
          sig { params(provenance: MaybeSymbol).returns(MaybeSymbol) }
          def keep(provenance = TypePlacement::UNSET)
            provenance
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT TypeCapabilityUnset {

        }
        STRUCT TypeCapabilities {

        }

        UNION TypeCapabilitiesMaybeSymbol { TypeCapabilityUnset: TypeCapabilityUnset, SymbolValue: String@symbol }
        FN typeCapabilities__keep(self: TypeCapabilities, ownership = TypeCapabilitiesMaybeSymbol{ TypeCapabilityUnset: TypeCapabilityUnset{} }: ?TypeCapabilitiesMaybeSymbol) RETURNS ?TypeCapabilitiesMaybeSymbol ->
          ownership;
        END
        STRUCT TypePlacementUnset {

        }
        STRUCT TypePlacement {

        }

        UNION TypePlacementMaybeSymbol { TypePlacementUnset: TypePlacementUnset, SymbolValue: String@symbol }
        FN typePlacement__keep(self: TypePlacement, provenance = TypePlacementMaybeSymbol{ TypePlacementUnset: TypePlacementUnset{} }: ?TypePlacementMaybeSymbol) RETURNS ?TypePlacementMaybeSymbol ->
          provenance;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "resolves nested aliases referenced by later aliases in the same class" do
      ruby_code = <<~RUBY
        class Type
          TypeInput = T.type_alias { T.any(Type, Symbol, String) }
          TypeNodeInput = T.type_alias { T.nilable(T.any(TypeInput, String)) }
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("UNION TypeTypeNodeInput { TypeTypeInput: TypeTypeInput, StringValue: String }")
      expect(clear).not_to include("TypeInput: TypeInput")
    end

    it "keeps string and symbol union argument wrappers distinct" do
      ruby_code = <<~RUBY
        Raw = T.type_alias { T.any(Symbol, String) }
        sig { params(value: Raw).returns(Void) }
        def accept_raw(value)
        end

        accept_raw("name")
        accept_raw(:name)
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include('accept_raw(Raw{ StringValue: COPY "name" });')
      expect(clear).to include("accept_raw(Raw{ SymbolValue: :name });")
    end

    it "wraps keyword call arguments with scoped nested union alias parameter types" do
      ruby_code = <<~RUBY
        class TypeCapabilityUnset < T::Struct
        end

        class TypeCapabilities
          UNSET = TypeCapabilityUnset.new
          MaybeSymbol = T.type_alias { T.any(TypeCapabilityUnset, Symbol, NilClass) }
          sig { params(ownership: MaybeSymbol, sync: MaybeSymbol).returns(MaybeSymbol) }
          def with(ownership: UNSET, sync: UNSET)
            ownership
          end

          sig { returns(MaybeSymbol) }
          def without_runtime_wrappers
            with(ownership: :affine, sync: nil)
          end
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("with(self, TypeCapabilitiesMaybeSymbol{ SymbolValue: :affine }, NIL)")
      expect(clear).to include("ownership = TypeCapabilitiesMaybeSymbol{ TypeCapabilityUnset: TypeCapabilityUnset{} }: ?TypeCapabilitiesMaybeSymbol")
    end

    it "copies string expressions when wrapping union argument payloads" do
      ruby_code = <<~RUBY
        Raw = T.type_alias { T.any(String, Symbol) }

        sig { params(value: Raw).returns(Raw) }
        def keep(value)
          value
        end

        sig { params(items: T::Array[String]).returns(Raw) }
        def first_raw(items)
          keep(items[0])
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("keep(Raw{ StringValue: COPY items[0] })")
    end

    it "wraps explicit returns into optional Sorbet union aliases" do
      ruby_code = <<~RUBY
        ArrayCapacity = T.type_alias { T.nilable(T.any(Integer, Symbol)) }

        sig { params(raw_capacity: T.nilable(String)).returns(ArrayCapacity) }
        def parse_array_capacity(raw_capacity)
          return nil if raw_capacity.nil?
          return :STREAM_OPEN if raw_capacity == "?"
          return raw_capacity.to_i
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION ArrayCapacity { Int64Value: Int64, SymbolValue: String@symbol }
        FN parse_array_capacity(raw_capacity: ?String) RETURNS ?ArrayCapacity ->
          IF (raw_capacity == NIL) THEN
            RETURN NIL;
          END
          IF (raw_capacity == "?") THEN
            RETURN ArrayCapacity{ SymbolValue: :STREAM_OPEN };
          END
          RETURN ArrayCapacity{ Int64Value: (raw_capacity.toInt() OR 0) };
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Sorbet tuple type aliases to generic Tuple types" do
      ruby_code = <<~RUBY
        RuleKey = T.type_alias { [Symbol, T.nilable(String)] }
        sig { params(key: RuleKey).returns(RuleKey) }
        def key_for(key)
          key
        end
      RUBY
      expected_clear = <<~CLEAR
        FN key_for(key: Tuple<String@symbol, ?String>) RETURNS Tuple<String@symbol, ?String> ->
          key;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Sorbet proc aliases to CLEAR function types" do
      ruby_code = <<~RUBY
        NodeRule = T.type_alias { T.proc.returns(T.nilable(AST::Node)) }
        Expr = T.type_alias { T.any(AST::BinaryOp, AST::Identifier) }
        SuffixRule = T.type_alias { T.proc.params(lhs: AST::Node).returns(Expr) }
        sig { params(rule: NodeRule, suffix: SuffixRule).void }
        def register(rule, suffix)
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Expr { BinaryOp: BinaryOp, Identifier: Identifier }
        FN register(rule: FN() -> ?Node, suffix: FN(Node) -> Expr) RETURNS Void ->

        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Proc#call on function-typed values to CLEAR function calls" do
      ruby_code = <<~RUBY
        Lookup = T.type_alias { T.proc.params(name: Symbol).returns(String) }
        sig { params(resolver: Lookup, name: Symbol).returns(String) }
        def resolve(resolver, name)
          resolver.call(name)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN resolve(resolver: FN(String@symbol) -> String, name: String@symbol) RETURNS String ->
          resolver(name);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "rejects Proc#call on optional function receivers without an explicit local unwrap" do
      ruby_code = <<~RUBY
        Lookup = T.type_alias { T.proc.params(name: Symbol).returns(String) }
        sig { params(resolver: T.nilable(Lookup), name: Symbol).returns(String) }
        def resolve(resolver, name)
          if resolver
            return resolver.call(name)
          end
          ""
        end
      RUBY

      expect {
        RubyToClear.transpile(ruby_code)
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Proc#call on optional function receivers/)
    end

    it "lowers Proc#call on locally unwrapped function values" do
      ruby_code = <<~RUBY
        Lookup = T.type_alias { T.proc.params(name: Symbol).returns(String) }
        sig { params(resolver: T.nilable(Lookup), name: Symbol).returns(String) }
        def resolve(resolver, name)
          fn = T.must(resolver)
          fn.call(name)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN resolve(resolver: ?FN(String@symbol) -> String, name: String@symbol) RETURNS String ->
          MUTABLE fn = resolver?;
          fn(name);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Proc#call through chained type aliases" do
      ruby_code = <<~RUBY
        Lookup = T.type_alias { T.proc.params(name: Symbol).returns(String) }
        Resolver = T.type_alias { Lookup }
        sig { params(resolver: T.nilable(Resolver), name: Symbol).returns(String) }
        def resolve(resolver, name)
          fn = T.must(resolver)
          fn.call(name)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN resolve(resolver: ?FN(String@symbol) -> String, name: String@symbol) RETURNS String ->
          MUTABLE fn = resolver?;
          fn(name);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "predeclares function-typed locals with a function default" do
      ruby_code = <<~RUBY
        Lookup = T.type_alias { T.proc.params(name: Symbol).returns(T.nilable(String)) }
        sig { params(resolver: T.nilable(Lookup), fallback: T::Boolean, name: Symbol).returns(T.nilable(String)) }
        def resolve(resolver, fallback, name)
          fn = T.let(
            if fallback
              lambda { |_name| nil }
            else
              T.must(resolver)
            end,
            Lookup
          )
          fn.call(name)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN resolve(resolver: ?FN(String@symbol) -> ?String, fallback: Bool, name: String@symbol) RETURNS ?String ->
          MUTABLE fn: FN(String@symbol) -> ?String = %(arg0: String@symbol) -> CAST(NIL AS ?String);
          IF fallback THEN
            fn = %(ignored_name) -> NIL;
          ELSE
            fn = resolver?;
          END
          fn(name);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses parser-safe variant names for unions containing function types" do
      ruby_code = <<~RUBY
        Lookup = T.type_alias { T.proc.params(name: Symbol).returns(String) }
        Resolver = T.type_alias { T.any(Lookup, T::Hash[Symbol, String]) }
        sig { params(resolver: Resolver).returns(String) }
        def resolve(resolver)
          "ok"
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Resolver { FunctionValue: FN(String@symbol) -> String, HashMapValue: HashMap<String, String> }
        FN resolve(resolver: Resolver) RETURNS String ->
          "ok";
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Sorbet type parameters to CLEAR generic function signatures" do
      ruby_code = <<~RUBY
        sig do
          type_parameters(:Elem)
            .params(type: Symbol, blk: T.proc.returns(T.type_parameter(:Elem)))
            .returns([Lexer::Token, T::Array[T.type_parameter(:Elem)]])
        end
        def parse_generic(type, &blk)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN parse_generic<Elem>(type: String@symbol, blk: FN() -> Elem) RETURNS Tuple<Token, Elem[]> ->

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

    it "transpiles Sorbet T::Enum classes to CLEAR enums" do
      ruby_code = <<~RUBY
        class Mode < T::Enum
          enums do
            Read = new("read")
            Write = new("write")
          end
        end

        sig { params(mode: Mode).returns(Bool) }
        def read_mode?(mode)
          mode == Mode::Read
        end
      RUBY
      expected_clear = <<~CLEAR
        ENUM Mode { Read, Write }
        FN read_mode?(mode: Mode) RETURNS Bool ->
          (mode == Mode.Read);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end
  end
end
