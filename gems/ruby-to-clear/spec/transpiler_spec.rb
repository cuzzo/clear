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
      expect_transpile('x = 10; "count: #{x}" " total"', "MUTABLE x = 10;\n\"count: ${x} total\";")
      expect_transpile("x = 10; \"count: \#{x}\" \\\n  \" total\"", "MUTABLE x = 10;\n\"count: ${x} total\";")
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
        FN helper(value: Auto) RETURNS !Auto ->
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

    it "transpiles predicate collection blocks" do
      expect_transpile("nums = []; nums.reject { |x| x < 2 }", "MUTABLE nums = [];\nnums |> WHERE !((_ < 2));")
      expect_transpile("nums = []; nums.any? { |x| x > 5 }", "MUTABLE nums = [];\nnums |> ANY (_ > 5);")
      expect_transpile("nums = []; nums.all? { |x| x > 0 }", "MUTABLE nums = [];\nnums |> ALL (_ > 0);")
      expect_transpile("nums = []; nums.find { |x| x == 3 }", "MUTABLE nums = [];\nnums |> FIND (_ == 3);")
      expect_transpile("nums = []; nums.detect { |x| x == 3 }", "MUTABLE nums = [];\nnums |> FIND (_ == 3);")
    end

    it "transpiles projection collection blocks" do
      expect_transpile("nums = []; nums.filter_map { |x| maybe(x) }", "MUTABLE nums = [];\nnums |> SELECT maybe(_) |> WHERE _ != NIL;")
      expect_transpile("groups = []; groups.flat_map { |g| g.items }", "MUTABLE groups = [];\ngroups |> UNNEST _.items();")
      expect_transpile("items = []; items.sort_by { |item| item.name }", "MUTABLE items = [];\nitems |> ORDER_BY _.name();")
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

    it "transpiles common File and Dir stdlib calls to CLEAR primitives or thin adapters" do
      expect_transpile('File.read("a.txt")', 'readFile("a.txt");')
      expect_transpile('File.readlines("a.txt")', 'readFile("a.txt").split("\n");')
      expect_transpile('File.foreach("a.txt")', 'readFile("a.txt").split("\n");')
      expect_transpile('File.foreach("a.txt") { |line| puts line }', 'readFile("a.txt").split("\n") |> EACH { puts(_); };')
      expect_transpile('File.write("a.txt", body)', 'writeFile("a.txt", body());')
      expect_transpile('File.exist?(path)', 'fileExists?(path());')
      expect_transpile('File.join(root, "src", name)', 'joinPath(root(), "src", name());')
      expect_transpile('File.expand_path("../x", base)', 'expandPath("../x", base());')
      expect_transpile('File.basename(path)', 'baseName(path());')
      expect_transpile('File.dirname(path)', 'dirName(path());')
      expect_transpile('Dir.glob(File.join(root, "*.rb"))', 'globPaths(joinPath(root(), "*.rb"));')
      expect_transpile('Dir.children(path)', 'listDir(path());')
      expect_transpile('Dir.entries(path)', 'listAll(path());')
      expect_transpile('Dir.pwd', 'currentDirectory();')
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

    it "transpiles Set constructors to CLEAR set-producing expressions" do
      expect_transpile('Set.new', 'Set[];')
      expect_transpile('Set.new([1, 2, 1])', '[1, 2, 1] |> DISTINCT _;')
      expect_transpile('Set.new(items) { |item| item.name }', 'items() |> SELECT _.name() |> DISTINCT _;')
      expect_transpile('Set[:a, :b]', '[.a, .b] |> DISTINCT _;')
    end

    it "rejects Ruby regexp global match state instead of hiding it behind an adapter" do
      expect {
        RubyToClear.transpile("Regexp.last_match(1)")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /implicit regexp match state/)
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
      expect(res.strip).to eq("# [UNSUPPORTED: ClassVariableWriteNode at 1:0] Unsupported node ClassVariableWriteNode\n# @@count = 0")
    end

    it "keeps supported statements around unsupported inner statements in lax mode" do
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
          # [UNSUPPORTED: ClassVariableWriteNode at 3:2] Unsupported node ClassVariableWriteNode
          # @@count = 1
          after();
        END
      CLEAR

      expect(RubyToClear.transpile(ruby_code, raise_on_error: false).strip).to eq(expected_clear.strip)
    end

    it "keeps supported method structure around unsupported body statements in lax mode" do
      ruby_code = <<~RUBY
        def build
          value = 1
          @@count = value
          value
        end
      RUBY
      expected_clear = <<~CLEAR
        FN build() RETURNS !Auto ->
          MUTABLE value = NIL;
          value = 1;
          # [UNSUPPORTED: ClassVariableWriteNode at 3:2] Unsupported node ClassVariableWriteNode
          # @@count = value
          value;
        END
      CLEAR

      expect(RubyToClear.transpile(ruby_code, raise_on_error: false).strip).to eq(expected_clear.strip)
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
      expect(res.strip).to eq("# [UNSUPPORTED: RegularExpressionNode at 1:0] Regular expressions are not supported\n# /pattern/")
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

    it "translates static keyword parameters as ordinary CLEAR parameters" do
      ruby_code = <<~RUBY
        def my_func(a, b:, c: 1)
          b
        end
      RUBY
      expected_clear = <<~CLEAR
        FN my_func(a: Auto, b: Auto, c = 1: Auto) RETURNS !Auto ->
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

    it "raises error on inline rescue modifier" do
      expect {
        RubyToClear.transpile("do_something rescue handle_error")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Exception handling \(rescue\) is not supported/)
    end
  end

  describe "dynamic Ruby blocker validation" do
    it "raises on dynamic and reflection calls instead of emitting Ruby-shaped CLEAR" do
      {
        "send(:foo)" => /dynamic dispatch/,
        "public_send(:foo)" => /dynamic dispatch/,
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

    it "comments dynamic/reflection calls in lax mode with refactor guidance" do
      result = RubyToClear.transpile("send(:foo)", raise_on_error: false)
      expect(result.strip).to eq(<<~CLEAR.strip)
        # [UNSUPPORTED: CallNode at 1:0] send is a Ruby dynamic/reflection call: dynamic dispatch; replace with a closed case/table over known method names
        # send(:foo)
      CLEAR
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

    it "compiles richer Sorbet collection and union types" do
      ruby_code = <<~RUBY
        sig { params(items: T::Array[String], table: T::Hash[String, Integer], seen: T::Set[Symbol], maybe: T.any(String, NilClass)).returns(T::Hash[String, T::Array[Integer]]) }
        def typed(items, table, seen, maybe)
          table
        end
      RUBY
      expected_clear = <<~CLEAR
        FN typed(items: String[], table: HashMap<String, Int64>, seen: String@symbol[]@set, maybe: ?String) RETURNS HashMap<String, Int64[]> ->
          table;
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
        FN bound() RETURNS !Auto ->
          MUTABLE x = NIL;
          x = 1;
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
