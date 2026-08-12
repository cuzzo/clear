# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require_relative "spec_helper"

RSpec.describe "current CLEAR language lowering" do
  def transpile(source)
    RubyToClear.transpile(source)
  end

  it "emits Inline Pivot collection types recursively" do
    translator = RubyToClear::Transpiler.new("")

    expect(translator.inline_collection_type("Int64[]")).to eq("[]Int64")
    expect(translator.inline_collection_type("Int64[][]")).to eq("[List, List]Int64")
    expect(translator.inline_collection_type("String[]@set")).to eq("[Set]String")
    expect(translator.inline_collection_type("HashMap<String, Tuple<String, Int64>[]>")).to(
      eq("{String}[]Tuple<String, Int64>")
    )
    expect(translator.inline_collection_type("?(HashMap<String, Int64[]>)")).to eq("?{String}[]Int64")
    expect(translator.inline_collection_type("HashMap<String, Int64>@shared:locked")).to(
      eq("{String}@shared:locked Int64")
    )
  end

  it "preserves symbolic element representation in collections" do
    clear = transpile(<<~RUBY)
      SYMBOLS = T.let([:alpha, :beta].freeze, T::Array[Symbol])
    RUBY

    expect(clear).to include("symbols: [2]String@symbol")
  end

  it "emits frozen literal constant arrays as immutable fixed storage" do
    clear = transpile(<<~RUBY)
      VALUES = T.let(%i[ALPHA OR_ELSE OMEGA].freeze, T::Array[Symbol])
    RUBY

    expect(clear).to include("values: [3]String@symbol = [:ALPHA, symbol(\"OR_ELSE\"), :OMEGA]")
    expect(clear).not_to include("MUTABLE values")
  end

  it "keeps frozen non-collection constants immutable" do
    config = { "helpers" => { "regex_literal" => "compilerRegexCompile" } }
    clear = RubyToClear.transpile(<<~RUBY, helper_config: config)
      PATTERN = T.let(/word/.freeze, Regexp)
      PATTERN
    RUBY

    expect(clear).to include('compilerRegexCompile("word")')
    expect(clear).not_to include("pattern:", "MUTABLE pattern")
  end

  it "inlines static regex-constant patterns into interpolated regexes" do
    config = {
      "helpers" => {
        "regex_literal" => "compilerRegexCompile",
        "regex_interpolated_literal" => "compilerRegexCompile",
      },
    }
    clear = RubyToClear.transpile(<<~'RUBY', helper_config: config)
      SUFFIX = T.let(/i8|i16/.freeze, Regexp)
      def literal
        /value_(#{SUFFIX})/
      end
    RUBY

    expect(clear).to include('compilerRegexCompile("value_(${"i8|i16"})")')
    expect(clear).not_to include("compilerRegexPattern(suffix)")
  end

  it "does not confuse Ruby predicate punctuation with an optional grouped type" do
    clear = transpile(<<~RUBY)
      class Bag
        extend T::Sig
        sig { params(seen: T.nilable(T::Set[String])).returns(T::Boolean) }
        def ready?(seen)
          !seen.nil?
        end
      end
    RUBY

    expect(clear).to include("FN bag__ready?(self: Bag, seen: ?[Set]String) RETURNS Bool")
    expect(clear).not_to include("ready?self")
  end

  it "uses explicit EXISTS refinement for optional Ruby truthiness" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      sig { params(value: T.nilable(String)).returns(String) }
      def present(value)
        if value
          value
        else
          ""
        end
      end
    RUBY

    expect(clear).to include("IF value EXISTS AS value_value THEN")
    expect(clear).not_to include("IF value AS value_value THEN")
  end

  it "retains inferred optional Ruby values with the current :? binding syntax" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      sig { returns(T.nilable(String)) }
      def maybe_name
        nil
      end

      sig { returns(String) }
      def name_or_default
        value = maybe_name
        if value
          value
        else
          "default"
        end
      end
    RUBY

    expect(clear).to include("MUTABLE value: ?String = maybe_name();")
  end

  it "keeps Ruby locals branch-local when lowering case arms" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      sig { params(tag: String).void }
      def scan_escape(tag)
        case tag
        when "x"
          hex = "ff"
          hex.length
        when "u"
          hex = "ffff"
          hex.length
        end
      end
    RUBY

    expect(clear.scan("MUTABLE hex =").length).to eq(2)
    expect(clear).not_to match(/\n\s+hex = "ffff"/)
  end

  it "maps Ruby byte lengths to CLEAR byte lengths" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      sig { params(value: String).returns(Integer) }
      def source_bytes(value)
        value.bytesize
      end
    RUBY

    expect(clear).to include("RETURN value.bytes();")
    expect(clear).not_to include("bytesize")
  end

  it "replaces Ruby encoding tags with explicit CLEAR UTF-8 validation" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      sig { params(value: String).returns(String) }
      def checked_utf8(value)
        source = value.dup.force_encoding(Encoding::UTF_8)
        raise "invalid UTF-8" unless source.valid_encoding?
        source
      end
    RUBY

    expect(clear).to match(/source = \(?COPY value\)?;/)
    expect(clear).to include("source.validUtf8?()")
    expect(clear).not_to include("force_encoding", "valid_encoding?", "Encoding")
  end

  it "uses a scanner's matched value when T.must wraps StringScanner#scan" do
    config = {
      "helpers" => {
        "regex_literal" => "compilerRegexCompile",
        "scanner_new" => "compilerRegexScanner",
        "scanner_scan" => "compilerRegexScan",
        "scanner_scan_value" => "compilerRegexScanValue",
        "scanner_pos" => "compilerRegexPosition"
      },
      "scanner_receivers" => ["scanner"]
    }
    clear = RubyToClear.transpile(<<~RUBY, helper_config: config)
      require "strscan"
      extend T::Sig
      sig { params(source: String).returns(String) }
      def opening(source)
        scanner = StringScanner.new(source)
        raw = T.must(scanner.scan(/\"\"\"/))
        raise if scanner.pos == 0
        raw
      end
    RUBY

    expect(clear).to include("compilerRegexScanValue(scanner, compilerRegexCompile")
    expect(clear).to include("compilerRegexPosition(scanner)")
    expect(clear).to include("UNWRAP (compilerRegexScanValue(scanner")
    expect(clear).not_to include("raw = compilerRegexScan(scanner")
    expect(clear).not_to include('panic("T.must failed")')
  end

  it "copies scanner-backed strings when a Ruby local retains them" do
    config = {
      "helpers" => {
        "scanner_matched" => "compilerRegexMatched",
        "scanner_peek" => "compilerRegexPeek",
        "scanner_getch" => "compilerRegexGetch",
        "scanner_capture" => "compilerRegexCapture",
      },
      "scanner_receivers" => ["scanner", "scanner()"],
    }

    clear = RubyToClear.transpile(<<~RUBY, helper_config: config)
      word = scanner.matched
      prefix = scanner.peek(2)
      char = scanner.getch
      capture = scanner[1]
    RUBY

    expect(clear).to include("MUTABLE word = COPY compilerRegexMatched(scanner())")
    expect(clear).to include("MUTABLE prefix = COPY compilerRegexPeek(scanner(), 2)")
    expect(clear).to include("MUTABLE char = COPY compilerRegexGetch(scanner())")
    expect(clear).to include("MUTABLE capture = COPY compilerRegexCapture(scanner(), 1)")
  end

  it "makes Ruby raises source-visible fallible CLEAR returns" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      sig { returns(String) }
      def fail
        raise "no value"
      end
    RUBY

    expect(clear).to include("FN fail() RETURNS !String")
  end

  it "uses the current logical and bitwise operator vocabulary" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      sig { params(a: Integer, b: Integer, left: T::Boolean, right: T::Boolean).returns(Integer) }
      def operators(a, b, left, right)
        raise unless left && right || left
        (((a & b) | (a ^ b)) << 1) >> 1
      end
    RUBY

    expect(clear).to include("(left AND right) OR left")
    expect(clear).to include("a BIT_AND b")
    expect(clear).to include("a XOR b")
    expect(clear).to include("BIT_OR")
    expect(clear).to include("<< 1", ">> 1")
    expect(clear).not_to include("&&", "||")
  end

  it "maps Ruby Integer#bit_length to CLEAR's numeric method" do
    clear = transpile(<<~RUBY)
      value = T.let(255, Integer)
      value.bit_length
    RUBY

    expect(clear).to include("value.bitLength()")
  end

  it "keeps the Int64 minimum lexable while preserving its exact value" do
    clear = transpile(<<~RUBY)
      VALUE = -9_223_372_036_854_775_808

      def minimum
        VALUE
      end
    RUBY

    expect(clear).to include("(-9223372036854775807 - 1)")
    expect(clear).not_to include("-9223372036854775808")
  end

  it "inlines scalar constants in default arguments" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      DEFAULT_LIMIT = T.let(32 * 6, Integer)

      sig { params(limit: Integer).returns(Integer) }
      def limit_or_default(limit = DEFAULT_LIMIT)
        limit
      end
    RUBY

    expect(clear).to include("limit_value: Int64 = (32 * 6)")
    expect(clear).not_to include("limit_value: Int64 = COPY default_limit")
  end

  it "does not terminate a nested class declaration aggregate as an expression" do
    clear = transpile(<<~RUBY)
      class Outer
        Item = Struct.new(:value)
        class Item
          X = T.let(1, Integer)
          Y = T.let(2, Integer)

          extend T::Sig
          sig { returns(Integer) }
          def value_or_x
            value || X
          end
        end
      end
    RUBY

    expect(clear).to include("FN item__value_or_x")
    expect(clear).to include("self.value")
    expect(clear).not_to include("value()")
    expect(clear).not_to match(/END;/)
  end

  it "lowers typed Ruby tuple literals and positions to native CLEAR tuples" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      sig { params(pair: [String, Integer]).returns(String) }
      def first(pair)
        pair[0]
      end

      sig { returns([String, Integer]) }
      def make
        ["ok", 1]
      end

      sig { params(xs: T::Array[Integer]).returns(T::Array[[String, Integer]]) }
      def pairs(xs)
        xs.map { |x| [x.to_s, x] }
      end
    RUBY

    expect(clear).to include("pair: Tuple<String, Int64>")
    expect(clear).to include("RETURN COPY pair._0;")
    expect(clear).to include('RETURN CAST(Tuple{"ok", 1} AS Tuple<String, Int64>);')
    expect(clear).to include("RETURNS ![]Tuple<String, Int64>")
    expect(clear).to include("SELECT CAST(Tuple{_.toString(), _} AS Tuple<String, Int64>)")
  end

  it "rejects dynamic or out-of-bounds tuple indexing instead of emitting array access" do
    dynamic = <<~RUBY
      extend T::Sig
      sig { params(pair: [String, Integer], index: Integer).returns(T.untyped) }
      def item(pair, index)
        pair[index]
      end
    RUBY
    out_of_bounds = <<~RUBY
      extend T::Sig
      sig { params(pair: [String, Integer]).returns(T.untyped) }
      def item(pair)
        pair[2]
      end
    RUBY

    expect { transpile(dynamic) }.to raise_error(
      RubyToClear::Transpiler::TranspilationError,
      /Tuple access requires one literal position/
    )
    expect { transpile(out_of_bounds) }.to raise_error(
      RubyToClear::Transpiler::TranspilationError,
      /Tuple position 2 is outside 0\.\.\.2/
    )
  end

  it "emits explicit mutable borrows and removes bang identifiers" do
    clear = transpile(<<~RUBY)
      class Box
        extend T::Sig
        sig { params(values: T::Array[Integer]).void }
        def initialize(values)
          @values = values
        end

        sig { params(value: Integer).void }
        def add!(value)
          @values << value
        end
      end

      extend T::Sig
      sig { void }
      def run
        box = Box.new([])
        box.add!(1)
      end
    RUBY

    expect(clear).to include("FN box__add_mut(MUTABLE self: Box, value: Int64) RETURNS Void")
    expect(clear).to include("REQUIRES self: LOCAL")
    expect(clear).to include("WITH POLYMORPHIC self AS MUTABLE rtoc_self_view")
    expect(clear).to include("&rtoc_self_view.values.append(COPY value);")
    expect(clear).to match(/MUTABLE rtoc_empty_list_\d+: \[\]Int64 = List\[\]/)
    expect(clear).to include("box__add_mut(&box, 1);")
    expect(clear).not_to match(/FN [^(\s]+!/)
  end

  it "keeps read-only polymorphic self views immutable" do
    clear = transpile(<<~RUBY)
      class Box
        extend T::Sig
        sig { params(value: Integer).void }
        def initialize(value)
          @value = value
        end

        sig { returns(Integer) }
        def value
          @value
        end
      end
    RUBY

    expect(clear).to match(
      /FN box__value\(self: Box\).*?WITH POLYMORPHIC self AS rtoc_self_view.*?RETURN rtoc_self_view\.value;/m
    )
  end

  it "honors value-class metadata without inventing reference ownership" do
    clear = transpile(<<~RUBY)
      # ruby-to-clear: value
      class Point
        extend T::Sig

        sig { params(x: Integer).void }
        def initialize(x)
          @x = x
        end

        sig { returns(Integer) }
        def value
          @x
        end
      end
    RUBY

    expect(clear).to include("FN point__new(x: Int64) RETURNS Point ->")
    expect(clear).not_to include("Point@multiowned")
    expect(clear).not_to include("WITH POLYMORPHIC self")
  end

  it "moves fresh constructor values into reference ownership without copying" do
    clear = transpile(<<~RUBY)
      class Box
        extend T::Sig
        sig { params(value: String).void }
        def initialize(value)
          @value = value
        end
      end
    RUBY

    expect(clear).to include("FN box__new(value: String) RETURNS Box@multiowned")
    expect(clear).to include("RETURN self @multiowned;")
    expect(clear).not_to include("RETURN COPY self @multiowned;")
  end

  it "orders instance capability requirements before reentrant effects" do
    clear = transpile(<<~RUBY)
      class Walker
        extend T::Sig
        sig { params(value: Integer).returns(Integer) }
        def descend(value)
          return value if value == 0

          descend(value - 1)
        end
      end
    RUBY

    expect(clear).to match(
      /RETURNS Int64\n  REQUIRES self: LOCAL\n  EFFECTS REENTRANT\n->/
    )
  end

  it "does not mark parameters mutable merely because they are compared" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      sig { params(value: Integer, suffix: String).returns(T::Boolean) }
      def in_range?(value, suffix)
        value >= 0 && value <= 255 && suffix == "u8"
      end
    RUBY

    expect(clear).to include("FN in_range?(value: Int64, suffix: String) RETURNS Bool")
    expect(clear).not_to include("MUTABLE value")
    expect(clear).not_to include("MUTABLE suffix")
  end

  it "captures locals mutably when a closure calls a mutating instance method" do
    clear = transpile(<<~RUBY)
      class Cursor
        extend T::Sig
        sig { void }
        def initialize
          @position = T.let(0, Integer)
        end

        sig { returns(Integer) }
        def advance
          @position += 1
        end
      end

      extend T::Sig
      sig { params(block: T.proc.returns(Integer)).returns(Integer) }
      def nested(&block)
        yield
      end

      sig { returns(Integer) }
      def scan
        cursor = Cursor.new
        nested { cursor.advance }
      end
    RUBY

    expect(clear).to include("USE(MUTABLE cursor)")
    expect(clear).to include("cursor__advance(&cursor)")
  end

  it "seeds non-optional constructor fields from optional fallback expressions" do
    clear = transpile(<<~RUBY)
      class Budget
        extend T::Sig
        sig { void }
        def initialize; end
      end

      class Scanner
        extend T::Sig
        sig { params(budget: T.nilable(Budget)).void }
        def initialize(budget = nil)
          @budget = T.let(budget || Budget.new, Budget)
        end
      end
    RUBY

    # Retained identity v4: an @multiowned field is a keep edge - the plain
    # spelling is native; the compiler derives the edge op.
    expect(clear).to match(/Scanner\{ budget: \(budget OR_ELSE budget__new\(\)\) \}/)
    expect(clear).not_to include("Scanner{ budget: NIL }")
  end

  it "marks escaping owned collection results fallible and propagates them" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      sig { params(xs: T::Array[Integer]).returns(T::Array[Integer]) }
      def copy_values(xs)
        xs.map { |x| x }
      end

      sig { params(xs: T::Array[Integer]).returns(Integer) }
      def copied_count(xs)
        copy_values(xs).length
      end
    RUBY

    expect(clear).to include("FN copy_values(xs: []Int64) RETURNS ![]Int64")
    expect(clear).to include("FN copied_count(xs: []Int64) RETURNS !Int64")
    expect(clear).to include("(TRY (copy_values(xs))).length()")
  end

  it "carries owned-collection fallibility through function values" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      sig do
        params(fn: T.proc.params(x: Integer).returns(T::Array[String]), x: Integer)
          .returns(T::Array[String])
      end
      def invoke(fn, x)
        fn.call(x)
      end
    RUBY

    expect(clear).to include("fn_value: FN(Int64) -> ![]String")
    expect(clear).to include("RETURNS ![]String")
    expect(clear).to include("RETURN TRY (fn_value(x));")
  end

  it "hoists fallible owned results returned by one-expression blocks" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      sig { params(block: T.proc.returns(T::Array[String])).returns(T::Array[String]) }
      def nested(&block)
        yield
      end

      sig { returns(T::Array[String]) }
      def tokens
        ["token"]
      end

      sig { returns(T::Array[String]) }
      def scan
        nested { tokens }
      end
    RUBY

    expect(clear).to match(/%\(\) -> \{\n\s+rtoc_lambda_result_\d+ = TRY \(tokens\(\)\);\n\s+rtoc_lambda_result_\d+\n\s*\}/)
  end

  it "lowers statically-known string concatenation to $+" do
    clear = transpile(<<~RUBY)
      extend T::Sig
      sig { params(a: String, b: String).returns(String) }
      def join2(a, b)
        a + b
      end

      sig { params(prefix: String, value: T.nilable(String)).returns(String) }
      def keyed(prefix, value)
        (prefix + "\\0") + (value || "\\1")
      end

      sig { params(x: Integer, y: Integer).returns(Integer) }
      def add(x, y)
        x + y
      end
    RUBY

    expect(clear).to include("RETURN (a $+ b);")
    # String literals emit their VALUE (Prism unescaped), so Ruby "\0"
    # and "\1" are the control bytes 0x00/0x01, spelled as hex escapes.
    expect(clear).to include('RETURN (((prefix $+ "\\x00")) $+ ((value OR_ELSE "\\x01")));')
    expect(clear).to include("RETURN (x + y);")
  end

  it "emits a two-member union for T.any(Symbol, String) aliases" do
    clear = transpile(<<~RUBY)
      Value = T.type_alias { T.any(Symbol, String) }

      sig { params(value: Value).returns(Value) }
      def keep(value)
        value
      end
    RUBY

    expect(clear).to include("UNION Value { SymbolValue: String@symbol, StringValue: String }")
    expect(clear).to include("FN keep(value: Value) RETURNS Value ->")
    expect(clear).not_to include("value: String@symbol")
  end

  it "narrows string-or-symbol unions with a real type test instead of a blind cast" do
    clear = transpile(<<~RUBY)
      Value = T.type_alias { T.any(Symbol, String) }

      sig { params(value: Value).returns(T.nilable(String)) }
      def string_value(value)
        return value if value.is_a?(String)
        nil
      end
    RUBY

    expect(clear).to include("IF value IS_A String AS string THEN")
    expect(clear).to include("RETURN COPY string;")
    expect(clear).to include("RETURN NIL;")
    expect(clear).not_to include("CAST(value AS String)")
  end

  it "keeps string-or-symbol hash keys collapsed to String@symbol" do
    clear = transpile(<<~RUBY)
      FieldMap = T.type_alias { T::Hash[T.any(String, Symbol), String] }

      sig { params(fields: FieldMap).returns(Integer) }
      def count(fields)
        fields.length
      end
    RUBY

    expect(clear).to include("fields: {String@symbol}String")
    expect(clear).not_to include("UNION FieldMapKey")
  end

  it "keeps element optionality inside collections distinct from optional collections" do
    clear = transpile(<<~RUBY)
      sig { params(values: T::Array[T.nilable(String)], maybe: T.nilable(T::Array[String])).returns(Void) }
      def walk(values, maybe)
      end
    RUBY

    expect(clear).to include("values: []?String")
    expect(clear).to include("maybe: ?[]String")
  end

  it "resolves namespaced constants to their defining file, not the namespace home" do
    require "tmpdir"
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "widgets.rb"), <<~RUBY)
        # typed: strict
        module Widgets
          Registry = {}
        end
      RUBY
      File.write(File.join(dir, "gadget.rb"), <<~RUBY)
        # typed: strict
        require "sorbet-runtime"

        module Widgets
          # ruby-to-clear: pub
          Gadget = Struct.new(:label, keyword_init: true) do
            extend T::Sig

            sig { returns(T::Boolean) }
            def labeled
              !!self[:label]
            end
          end
        end
      RUBY

      clear = RubyToClear.transpile_file(File.join(dir, "gadget.rb"))

      # `self[:label]` types the receiver as Widgets::Gadget; the dependency
      # is the defining file (this one), never the namespace home widgets.rb.
      expect(clear).not_to include("widgets.clear")
      expect(clear).not_to include("REQUIRE")
    end
  end

  describe "factory: struct defaults and frozen constant inlining" do
    let(:caps_ruby) do
      <<~RUBY
        # ruby-to-clear: value
        class Caps
          extend T::Sig

          sig { returns(Symbol) }
          attr_reader :mode

          sig { params(mode: Symbol).void }
          def initialize(mode: :affine)
            @mode = mode
            freeze
          end

          AFFINE = T.let(Caps.new(mode: :affine).freeze, Caps)
        end
      RUBY
    end

    it "lowers factory: lambda defaults to the same construction-site default as default:" do
      clear = transpile(caps_ruby + <<~RUBY)
        class Node < T::Struct
          const :name, Symbol
          const :caps, Caps, factory: -> { Caps::AFFINE }
        end

        extend T::Sig

        sig { params(name: Symbol).returns(Node) }
        def build(name)
          Node.new(name: name)
        end
      RUBY

      expect(clear).to include("RETURN Node{ name: COPY name, caps: caps__new(:affine) };")
    end

    it "drops factory defaults it cannot statically unwrap instead of guessing" do
      multi_statement = transpile(caps_ruby + <<~RUBY)
        class Node < T::Struct
          const :name, Symbol
          const :caps, Caps, factory: -> { audit; Caps::AFFINE }
        end

        extend T::Sig

        sig { params(name: Symbol).returns(Node) }
        def build(name)
          Node.new(name: name)
        end
      RUBY

      non_lambda = transpile(caps_ruby + <<~RUBY)
        class Node < T::Struct
          const :name, Symbol
          const :caps, Caps, factory: CAPS_FACTORY
        end

        extend T::Sig

        sig { params(name: Symbol).returns(Node) }
        def build(name)
          Node.new(name: name)
        end
      RUBY

      # The omitted field is left for the CLEAR compiler to report as a
      # missing struct field, rather than fabricating a default.
      expect(multi_statement).to include("RETURN Node{ name: COPY name };")
      expect(non_lambda).to include("RETURN Node{ name: COPY name };")
    end

    it "inlines frozen non-array constants at use sites instead of emitting top-level storage" do
      clear = transpile(caps_ruby + <<~RUBY)
        extend T::Sig

        sig { returns(Caps) }
        def fallback
          Caps::AFFINE
        end
      RUBY

      # Top-level storage for a runtime-constructed value is rejected by the
      # CLEAR compiler (MODULE_SCOPE_OWNED_VALUE); the frozen constant must
      # substitute its construction expression at each reference.
      expect(clear).not_to match(/^affine/)
      expect(clear).not_to include("MUTABLE affine")
      expect(clear).to include("RETURN caps__new(:affine);")
    end

    it "inlines unqualified frozen constant references inside the defining class" do
      clear = transpile(<<~RUBY)
        # ruby-to-clear: value
        class Caps
          extend T::Sig

          sig { returns(Symbol) }
          attr_reader :mode

          sig { params(mode: Symbol).void }
          def initialize(mode: :affine)
            @mode = mode
            freeze
          end

          AFFINE = T.let(Caps.new(mode: :affine).freeze, Caps)

          sig { returns(Caps) }
          def self.fallback
            AFFINE
          end
        end
      RUBY

      expect(clear).not_to match(/^affine/)
      expect(clear).to include("RETURN caps__new(:affine);")
    end

    it "inlines frozen constants referenced across required files" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "caps.rb"), caps_ruby)
        source_path = File.join(dir, "user.rb")
        File.write(source_path, <<~RUBY)
          require_relative "./caps"

          extend T::Sig

          sig { returns(Caps) }
          def fallback
            Caps::AFFINE
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)

        expect(clear).not_to include("affine =")
        expect(clear).to include("caps__new(:affine)")
      end
    end

    it "keeps frozen literal arrays as fixed storage rather than inlining" do
      clear = transpile(<<~RUBY)
        ORDERS = T.let(["", "!", "?"].freeze, T::Array[String])

        extend T::Sig

        sig { params(order: String).returns(T::Boolean) }
        def valid?(order)
          ORDERS.include?(order)
        end
      RUBY

      expect(clear).to include('orders: [3]String = ["", "!", "?"]')
      expect(clear).to include("orders.contains?(order)")
    end
  end

end
