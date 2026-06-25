# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyToClear::Transpiler do
  def expect_transpile(ruby_code, expected_clear)
    result = RubyToClear.transpile(ruby_code)
    expect(result.strip).to eq(expected_clear.strip)
  end

  describe "basic expressions and literals" do
    it "transpiles leaf nodes correctly" do
      expect_transpile("123", "123;")
      expect_transpile('"hello"', '"hello";')
      expect_transpile(":my_sym", ".my_sym;")
      expect_transpile("nil", "NIL;")
      expect_transpile("false", "FALSE;")
      expect_transpile("true", "TRUE;")
    end

    it "transpiles arrays and hashes" do
      expect_transpile("[1, 2, 3]", "[1, 2, 3];")
      expect_transpile("{ a: 1, b: 2 }", "{a: 1, b: 2};")
      expect_transpile('{ "a" => 1 }', '{"a": 1};')
    end

    it "transpiles string interpolations" do
      expect_transpile('x = 10; "count: #{x}"', "MUTABLE x = 10;\n\"count: ${x}\";")
      expect_transpile('x = 10; "count: #{x + 1}"', "MUTABLE x = 10;\n\"count: ${(x + 1)}\";")
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
    end

    it "transpiles index access and assignments" do
      expect_transpile("states = {}; key = 1; states[key]", "MUTABLE states = {};\nMUTABLE key = 1;\nstates[key];")
      expect_transpile("states = {}; key = 1; value = 2; states[key] = value", "MUTABLE states = {};\nMUTABLE key = 1;\nMUTABLE value = 2;\nstates[key] = value;")
    end

    it "transpiles standard method calls" do
      expect_transpile("pattern = 'abc'; scan(pattern)", "MUTABLE pattern = \"abc\";\nscan(pattern);")
      expect_transpile("obj = nil; pattern = 'abc'; obj.scan(pattern)", "MUTABLE obj = NIL;\nMUTABLE pattern = \"abc\";\nobj.scan(pattern);")
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
        MUTABLE val = .a;
        PARTIAL MATCH val START
          .a -> 1;,
          .b -> 2;,
          DEFAULT -> 99;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
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
  end

  describe "classes and methods" do
    it "transpiles Struct.new definition and constructor call mapping" do
      ruby_code = <<~RUBY
        Token = Struct.new(:type, :value, :line, :column)
        t = Token.new(:ELLIPSIS, '...', 1, 1)
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Token {
          type: Auto,
          value: Auto,
          line: Auto,
          column: Auto
        }
        MUTABLE t = Token{ type: .ELLIPSIS, value: "...", line: 1, column: 1 };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
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
          val: Auto
        }

        FN initialize!(MUTABLE self: Calc, start: Auto) RETURNS Void ->
          self.val = start;
        END
        FN add(MUTABLE self: Calc, n: Auto) RETURNS !Auto ->
          self.val = (self.val + n);
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

    it "transpiles reduce and inject" do
      ruby_code = "nums = []; nums.reduce(0) { |acc, x| acc + x }"
      expected_clear = "MUTABLE nums = [];\nnums |> REDUCE(0) (acc + _);"
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
    end
  end

  describe "unsupported/incorrect nodes in strict and lax mode" do
    it "raises error on class variable in strict mode" do
      expect {
        RubyToClear.transpile("@@count = 0")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Unsupported node ClassVariableWriteNode/)
    end

    it "comments out class variable in lax mode" do
      res = RubyToClear.transpile("@@count = 0", raise_on_error: false)
      expect(res.strip).to eq("# [UNSUPPORTED: ClassVariableWriteNode]\n# @@count = 0")
    end
  end

  describe "regular expressions and gsub/sub validation" do
    it "raises error on regex literal in strict mode" do
      expect {
        RubyToClear.transpile("/pattern/")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Regular expressions are not supported/)
    end

    it "comments out regex literal in lax mode" do
      res = RubyToClear.transpile("/pattern/", raise_on_error: false)
      expect(res.strip).to eq("# [UNSUPPORTED: RegularExpressionNode]\n# /pattern/")
    end

    it "raises error on gsub with regex" do
      expect {
        RubyToClear.transpile("str = ''; str.gsub(/pat/, 'replacement')")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /gsub with regex or block is not supported/)
    end

    it "raises error on gsub with block" do
      expect {
        RubyToClear.transpile("str = ''; str.gsub('a') { 'b' }")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /gsub with regex or block is not supported/)
    end

    it "raises error on sub method call" do
      expect {
        RubyToClear.transpile("str = ''; str.sub('a', 'b')")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /gsub\/sub with dynamic regex, block, or invalid arguments is not supported/)
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

    it "raises error on map block with multiple statements" do
      expect {
        RubyToClear.transpile("list = []; list.map { |x| y = x * 2; y + 1 }")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /map block must be a single expression/)
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
        FN swap_vars(MUTABLE a: Auto, MUTABLE b: Auto) RETURNS !Auto ->
          MUTABLE __tmp_multi_0 = b;
          MUTABLE __tmp_multi_1 = a;
          a = __tmp_multi_0;
          b = __tmp_multi_1;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "raises error on non-array value destructuring" do
      expect {
        RubyToClear.transpile("a, b = get_val")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Destructuring is only supported for literal array values/)
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
        FN test_fn(cond: Auto) RETURNS !Auto ->
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
        FN test_fn(MUTABLE p: Auto) RETURNS !Auto ->
          p = 10;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end
  end

  describe "keyword arguments and parameters validation" do
    it "raises error on keyword arguments inside calls" do
      expect {
        RubyToClear.transpile("test_call(a: 1)")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Keyword arguments are not supported/)
    end

    it "raises error on keyword parameters inside method signatures" do
      expect {
        RubyToClear.transpile("def my_func(a: 1); end")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Keyword parameters are not supported/)
    end
  end

  describe "exception handling (rescue) validation" do
    it "raises error on begin-rescue blocks" do
      expect {
        RubyToClear.transpile("begin; do_something; rescue; handle_error; end")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Exception handling \(rescue\) is not supported/)
    end

    it "raises error on inline rescue modifier" do
      expect {
        RubyToClear.transpile("do_something rescue handle_error")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Exception handling \(rescue\) is not supported/)
    end
  end

  describe "compound assignments and optional parameters" do
    it "translates local and instance variable operator writes (+=, ||=, etc.)" do
      expect_transpile("x = 10; x += 5", "MUTABLE x = 10;\nx = (x + 5);")
      expect_transpile("x = 10; x ||= 5", "MUTABLE x = 10;\nx = (x || 5);")
      expect_transpile("@val = 10; @val += 5", "self.val = 10;\nself.val = (self.val + 5);")
    end

    it "translates optional parameters in def signatures" do
      expect_transpile("def my_func(a, b = 42); end", "FN my_func(a: Auto, b = 42: Auto) RETURNS !Auto ->\n\nEND")
    end
  end
end
