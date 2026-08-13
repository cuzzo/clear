# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe RubyToClear::Transpiler do
  def expect_transpile(ruby_code, expected_clear)
    result = RubyToClear.transpile(ruby_code)
    expect(result.strip).to eq(expected_clear.strip)
  end

  it "groups nilable collection signatures so the collection, not its elements, is optional" do
    ruby_code = <<~RUBY
      sig { params(items: T.nilable(T::Array[String]), seen: T.nilable(T::Set[String])).void }
      def inspect_collections(items = nil, seen = nil)
      end
    RUBY

    clear = RubyToClear.transpile(ruby_code)
    expect(clear).to include("FN inspect_collections(items: ?[]String = NIL, seen: ?[Set]String = NIL) RETURNS Void ->")
    expect(clear).to include("FN inspect_collections(items: ?[]String = NIL, seen: ?[Set]String = NIL) RETURNS Void ->")
  end

  it "uses parser-safe generated names for leading-underscore function parameters" do
    ruby_code = <<~RUBY
      sig { params(_name: String, ignored_name: String).returns(String) }
      def choose(_name, ignored_name)
        _name
      end
    RUBY
    expected_clear = <<~CLEAR
      FN choose(ignored_name_2: String, ignored_name: String) RETURNS String ->
        RETURN COPY ignored_name_2;
      END
    CLEAR
    expect_transpile(ruby_code, expected_clear)
  end

    it "wraps values stored through typed hash union boundaries" do
    ruby_code = <<~RUBY
      class Item < T::Struct
      end
      Lookup = T.type_alias { T.nilable(T.any(Item, T::Array[Item])) }
      Table = T.type_alias { T::Hash[String, Lookup] }

      sig { params(items: T::Array[Item]).returns(Table) }
      def build(items)
        out = T.let({}, Table)
        out["items"] = items
        out
      end
    RUBY
    expected_clear = <<~CLEAR
      STRUCT Item {

      }
      UNION Lookup { Item: Item, ArrayValue: []Item }
      FN build(items: []Item) RETURNS !{String}?Lookup ->
        MUTABLE out: {String}?Lookup = {};
        out["items"] = Lookup{ ArrayValue: COPY items };
        RETURN out;
      END
    CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "wraps typed hash literal values at union boundaries" do
      ruby_code = <<~RUBY
        Metadata = T.type_alias { T::Hash[Symbol, T.nilable(T.any(String, Integer, T::Boolean))] }
        sig { params(maybe_count: T.nilable(Integer)).returns(Metadata) }
        def metadata(maybe_count)
          data = T.let({ name: "x", count: 1, ready: false, maybe: maybe_count }, Metadata)
          data
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include(":name: MetadataValue{ StringValue: COPY \"x\" }")
      expect(clear).to include(":count: MetadataValue{ Int64Value: 1 }")
      expect(clear).to include(":ready: MetadataValue{ BoolValue: FALSE }")
      expect(clear).to include(":maybe: ruby_wrap_optional_Int64_MetadataValue(maybe_count)")
      expect(clear).to include("FN ruby_wrap_optional_Int64_MetadataValue(value: ?Int64) RETURNS ?MetadataValue ->")
    end

    it "propagates contextual types into nested hash literals" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(String, Symbol, T::Boolean) }
        Entry = T.type_alias { T::Hash[Symbol, Value] }
        VALUES = T.let(
          { item: { severity: :error, template: "Oops" } }.freeze,
          T::Hash[Symbol, Entry]
        )
        sig { params(code: Symbol).returns(T.nilable(Entry)) }
        def value(code)
          VALUES[code]
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include(":item: CAST({")
      expect(clear).to include(":severity: Value{ SymbolValue: :error }")
      expect(clear).to include(':template: Value{ StringValue: COPY "Oops" }')
      expect(clear).to include("AS {String@symbol}Value)")
      expect(clear).to include("AS {String@symbol}{String@symbol}Value))[code]")
    end

    it "wraps scalar operands compared with generated unions" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(String, Symbol) }
        sig { params(value: Value).returns(T::Boolean) }
        def wildcard(value)
          value == :wildcard
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Value { StringValue: String, SymbolValue: String@symbol }
        FN wildcard(value: Value) RETURNS Bool ->
          RETURN ruby_union_scalar_equal_Value_String_symbol(value, :wildcard);
        END
        FN ruby_union_scalar_equal_Value_String_symbol(value: Value, expected: String@symbol) RETURNS Bool ->
          IF value IS_A String@symbol AS equality_payload THEN
            RETURN equality_payload == expected;
          END
          FALSE;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses distinct scalar equality helpers for optional and required unions" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(String, Symbol) }
        sig { params(value: T.nilable(Value)).returns(T::Boolean) }
        def optional_wildcard(value)
          value == :wildcard
        end
        sig { params(value: Value).returns(T::Boolean) }
        def required_wildcard(value)
          value == :wildcard
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include(
        "ruby_union_scalar_equal_optional_Value_String_symbol(value, :wildcard)"
      )
      expect(clear).to include(
        "FN ruby_union_scalar_equal_optional_Value_String_symbol(value: ?Value, expected: String@symbol)"
      )
      expect(clear).to include("IF value EXISTS AS equality_value THEN")
      expect(clear).to include("IF equality_value IS_A String@symbol AS equality_payload THEN")
      expect(clear).to include(
        "ruby_union_scalar_equal_Value_String_symbol(value, :wildcard)"
      )
      expect(clear).to include(
        "FN ruby_union_scalar_equal_Value_String_symbol(value: Value, expected: String@symbol)"
      )
    end

    it "folds redundant runtime Set checks from typed optional sets" do
      ruby_code = <<~RUBY
        sig { params(values: T.nilable(T::Set[Symbol])).returns(T::Boolean) }
        def populated_set?(values)
          return false unless values.is_a?(Set)

          !values.empty?
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).not_to include("IS_A [Set]")
      expect(clear).to include("IF !((values != NIL)) THEN")
    end

    it "captures narrowed union payloads in returning ternaries" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(String, Symbol) }
        sig { params(value: Value).returns(T.nilable(String)) }
        def string_value(value)
          value.is_a?(String) ? value : nil
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("UNION Value { StringValue: String, SymbolValue: String@symbol }")
      expect(clear).to include("IF value IS_A String AS string THEN")
      expect(clear).to include("RETURN COPY string;")
      expect(clear).to include("RETURN NIL;")
    end

    it "coerces object-or-false return unions at predicate boundaries" do
      ruby_code = <<~RUBY
        class Parser
          extend T::Sig

          sig { returns(T.any(String, FalseClass)) }
          def match!
            ready? ? "token" : false
          end

          sig { void }
          def scan
            while match!
              work
            end
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("WHILE castReturnValueToBool(parser__match_mut(rtoc_self_view)) DO")
      expect(clear).to include("IF value IS_A Bool AS cast_payload THEN")
      expect(clear).to include("RETURN TRUE;")
    end

    it "coerces statically truthy Ruby objects in boolean AND operands" do
      ruby_code = <<~RUBY
        class Token < T::Struct
        end
        sig { params(name: String, token: Token).returns(T::Boolean) }
        def available?(name, token)
          name && token
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN (TRUE AND TRUE);")
    end

  it "keeps generated constant storage distinct from same-named functions" do
    ruby_code = <<~RUBY
      REGISTRY_VALUES = T.let({}, T::Hash[String, String])

      sig { returns(T::Hash[String, String]) }
      def registry_values
        REGISTRY_VALUES
      end
    RUBY
    expected_clear = <<~CLEAR
      MUTABLE registry_values_value: {String}String = {};
      FN registry_values() RETURNS !{String}String ->
        RETURN registry_values_value;
      END
    CLEAR
    expect_transpile(ruby_code, expected_clear)
  end

  it "uses generated storage names for forward constant references" do
    ruby_code = <<~RUBY
      def sentinel
        SUFFIX_DECLINE
      end
      SUFFIX_DECLINE = T.let(:suffix_decline, Symbol)
    RUBY

    clear = RubyToClear.transpile(ruby_code)
    expect(clear).to include("suffix_decline;")
    expect(clear).not_to include("SUFFIX_DECLINE;")
  end

  it "constructs heap-owning data API constants inside their accessors" do
    ruby_code = <<~RUBY
      # ruby-to-clear: data-only
      module AST
        # ruby-to-clear: data-api
        NAMES = T.let(["left", "right"], T::Array[String])
      end
    RUBY

    clear = RubyToClear.transpile(ruby_code)
    expect(clear).to include(
      "PUB FN ruby_constant_names() RETURNS []String ->\n" \
        "  RETURN CAST([\"left\", \"right\"] AS []String);\n" \
        "END"
    )
    expect(clear).not_to include("MUTABLE names")
    expect(clear).not_to match(/^names(?:\\s|:)/)
  end

  it "narrows self-assigned T.must locals without emitting reassignment" do
    ruby_code = <<~RUBY
      value = T.let(maybe_value, T.nilable(String))
      value = T.must(value)
      value.length
    RUBY

    clear = RubyToClear.transpile(ruby_code)
    expect(clear).to include("MUTABLE value: ?String = maybe_value();")
    expect(clear).to include("MUTABLE value_value: String = value?;")
    expect(clear).to include("value_value.codepointCount();")
    expect(clear).not_to include("value = value?")
  end

  it "lowers indexed ||= writes through generated struct fields" do
    ruby_code = <<~RUBY
      Item = Struct.new(:names) do
        sig { returns(T::Array[String]) }
        def names
          self[:names] ||= []
        end
      end
    RUBY
    expected_clear = <<~CLEAR
      STRUCT Item {
        names: []String
      }

      FN item__names(self: Item) RETURNS ![]String ->
        self.names = (self.names OR_ELSE List[]);
        RETURN self.names;
      END
    CLEAR
    expect_transpile(ruby_code, expected_clear)
  end

  it "materializes expression receivers before indexed writes" do
    clear = RubyToClear.transpile(<<~RUBY)
      def set_slot(value)
        Thread.current[:slot] = value
      end
    RUBY

    expect(clear).to include("MUTABLE rtoc_index_receiver_1 = Thread.current();")
    expect(clear).to include("rtoc_index_receiver_1[:slot] = COPY value;")
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
      expect_transpile("a && b", "(a() AND b());")
      expect_transpile("a || b", "(a() OR b());")
    end

    it "uses a nil check for an optional value on the left of boolean and" do
      ruby_code = <<~RUBY
        class Holder < T::Struct
          prop :value, T.nilable(String)

          sig { returns(T::Boolean) }
          def present?
            @value && true
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Holder {
          value: ?String
        }

        FN holder__present?(self: Holder) RETURNS Bool ->
          RETURN ((self.value != NIL) AND TRUE);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "unwraps optional unions and dispatches shared fields in boolean and" do
      ruby_code = <<~RUBY
        class Left < T::Struct
          const :token, String
        end
        class Right < T::Struct
          const :token, String
        end
        Reg = T.type_alias { T.any(Left, Right) }

        sig { params(reg: T.nilable(Reg)).returns(T::Boolean) }
        def token_present?(reg)
          reg && !reg.token.empty?
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN ((reg != NIL) AND !((MATCH reg START Reg.Left AS item -> (item.token.length() == 0), Reg.Right AS item -> (item.token.length() == 0) END)));")
    end

    it "preserves optional union narrowing after an and exit guard" do
      ruby_code = <<~RUBY
        class Left < T::Struct
          const :token, String
        end
        class Right < T::Struct
          const :token, String
        end
        Reg = T.type_alias { T.any(Left, Right) }

        sig { params(reg: T.nilable(Reg)).returns(T.nilable(String)) }
        def selected_token(reg)
          return unless reg && reg.token
          reg.token
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF reg EXISTS AS reg_value THEN")
      expect(clear).to include("IF (MATCH reg_value START Reg.Left AS item -> item.token, Reg.Right AS item -> item.token END) THEN")
      expect(clear).to include("RETURN (MATCH reg_value START Reg.Left AS item -> item.token, Reg.Right AS item -> item.token END);")
    end

    it "narrows an optional field after a nil predicate in boolean or" do
      ruby_code = <<~RUBY
        class Token < T::Struct
          const :type, Symbol
        end

        class Holder < T::Struct
          const :token, T.nilable(Token)

          sig { returns(T::Boolean) }
          def eof?
            @token.nil? || @token.type == :EOF
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Token {
          type: String@symbol
        }
        STRUCT Holder {
          token: ?Token
        }

        FN holder__eof?(self: Holder) RETURNS Bool ->
          RETURN ((self.token == NIL) OR (((self.token)?).type == :EOF));
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "infers collection shapes from instance fields" do
      ruby_code = <<~RUBY
        class Source < T::Struct
          const :text, String

          sig { returns(String) }
          def first_line
            lines = @text.split("\\n")
            lines[0] || ""
          end
        end
      RUBY
      # `lines[0]` is optional in CLEAR (an out-of-range index yields NIL,
      # exactly as Ruby's `a[999]` is nil), so the source's `|| ""` fallback
      # is live code and must survive translation. It previously did not:
      # an indexed array read was inferred as a bare element type, which
      # made the `|| ""` look dead and silently dropped it - AND emitted
      # `RETURN lines[0];` from a `RETURNS String` function, which the
      # frontend rejects outright (?String vs String).
      expected_clear = <<~CLEAR
        STRUCT Source {
          text: String
        }

        FN source__first_line(self: Source) RETURNS String ->
          MUTABLE lines = self.text.split("\\n");
          IF lines[0] != NIL THEN
          RETURN COPY (lines[0])?;
          ELSE
          RETURN "";
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "preserves optional field narrowing after a compound exit guard" do
      ruby_code = <<~RUBY
        class Token < T::Struct
          const :type, Symbol
        end

        class Holder < T::Struct
          const :token, T.nilable(Token)

          sig { returns(Symbol) }
          def token_type
            if @token.nil? || @token.type == :EOF
              return :EOF
            end

            @token.type
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Token {
          type: String@symbol
        }
        STRUCT Holder {
          token: ?Token
        }

        FN holder__token_type(self: Holder) RETURNS String@symbol ->
          IF self.token EXISTS AS token_value THEN
            IF (token_value.type == :EOF) THEN
              RETURN :EOF;
            ELSE
              RETURN token_value.type;
            END
          ELSE
            RETURN :EOF;
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
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

          FN emit__op(self: Emit, default_name: Auto) RETURNS Auto ->
            IF self.bc_op != NIL THEN
            RETURN self.bc_op;
            ELSE
            RETURN COPY default_name;
            END
          END
        CLEAR
      )
    end

    it "folds unreachable Ruby fallbacks for known truthy object types" do
      ruby_code = <<~RUBY
        sig { params(value: String).returns(String) }
        def keep(value)
          value || "fallback"
        end
      RUBY
      expected_clear = <<~CLEAR
        FN keep(value: String) RETURNS String ->
          RETURN value;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "folds nil checks on known non-optional values" do
      ruby_code = <<~RUBY
        sig { params(value: String).returns(T::Boolean) }
        def missing(value)
          value.nil?
        end
      RUBY
      expected_clear = <<~CLEAR
        FN missing(value: String) RETURNS Bool ->
          RETURN FALSE;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "keeps parenthesized single expressions expression-safe" do
      expect_transpile(
        "x = (str.length - T.must(last_newline_index))",
        "MUTABLE x = ((str().length() - last_newline_index()));"
      )
    end

    it "transpiles string interpolations" do
      expect_transpile('x = 10; "count: #{x}"', "MUTABLE x = 10;\n\"count: ${x.toString()}\";")
      expect_transpile('x = 10; "count: #{x + 1}"', "MUTABLE x = 10;\n\"count: ${(x + 1).toString()}\";")
      expect_transpile('x = 10; "count: #{x}" " total"', "MUTABLE x = 10;\n\"count: ${x.toString()} total\";")
      expect_transpile("x = 10; \"count: \#{x}\" \\\n  \" total\"", "MUTABLE x = 10;\n\"count: ${x.toString()} total\";")
    end

    it "hoists an assignment used inside string interpolation into a value block" do
      # Ruby's assignment is expression-valued (`x = y` evaluates to `y`),
      # but CLEAR's assignment has no expression form at all (no AssignExpr
      # node anywhere in the parser - matches the language's "immutable by
      # default" design), and a value block's ${...} interpolation slot is
      # lexed as a genuine parenthesized sub-expression (Lexer#
      # read_interpolated_string desugars "...${e}..." to "..." $+ (e) $+
      # "...") - it cannot contain a bare assignment statement. Without the
      # fix this produced a literal "self.n = ..." (or "x = ...") inside the
      # ${...} slot, which the real CLEAR parser rejects outright
      # (`Expected ), got =`) - confirmed via the real corpus fingerprint
      # (34 files, mir/lower/pipeline/pipeline_host.rb's
      # `"__concurrent_select_promises_#{@stream_select_counter += 1}"`).
      expect_transpile(
        "x = 0; \"n_\#{x += 1}\"",
        "MUTABLE x = 0;\n\"n_${{ MUTABLE rtoc_value_block_marker = 0; x = (x + 1); x.toString() }}\";"
      )
      expect_transpile(
        "x = 0; \"n_\#{x = x + 5}\"",
        "MUTABLE x = 0;\n\"n_${{ MUTABLE rtoc_value_block_marker = 0; x = (x + 5); x.toString() }}\";"
      )
    end

    it "rewrites self to the WITH POLYMORPHIC alias inside a hoisted interpolation assignment" do
      # The second half of the same bug: parenthesizing the assignment isn't
      # enough on its own inside an instance method - the hoisted "self.n =
      # ..." write is rejected by the borrow checker ([ASSIGN_WHILE_
      # BORROWED]) because instance methods route field access through a
      # WITH POLYMORPHIC self AS MUTABLE rtoc_self_view alias, and only that
      # alias (not the outer borrowed `self`) may be assigned through.
      # local_aliasable_instance_body's self -> rtoc_self_view rewrite is a
      # whole-method-body TEXT scan that historically treated a quoted
      # string as fully opaque, so it never reached inside ${...} even
      # though that's real CLEAR code, not string content, once the CLEAR
      # lexer gets it.
      ruby_code = <<~RUBY
        class Counter
          def initialize
            @n = 0
          end

          sig { returns(String) }
          def next_label
            "item_\#{@n += 1}"
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include(
        '"item_${{ MUTABLE rtoc_value_block_marker = 0; rtoc_self_view.n = (rtoc_self_view.n + 1); rtoc_self_view.n.toString() }}"'
      )
      expect(clear).not_to include("self.n")
    end

    it "extracts a string payload from a union for interpolation" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(String, Integer) }
        sig { params(value: Value).returns(String) }
        def label(value)
          "\#{value}?"
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include('"${castValueToString(value)}?"')
      expect(clear).to include("FN castValueToString(value: Value) RETURNS String")
    end

    it "preserves a local's declared union type after reassignment" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(String, Integer) }
        Item = Struct.new(:name) do
          sig { returns(String) }
          def name
            super
          end
        end
        sig { params(value: Value).returns(Item) }
        def make(value)
          name = value
          name = "\#{name}?"
          Item.new(name)
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("name = Value{ StringValue: COPY \"${castValueToString(name)}?\" }")
      expect(clear).to include("Item{ name: castValueToString(COPY name) }")
    end

    it "converts a union payload to a typed hash key" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(String, Integer) }
        sig { params(values: T::Hash[String, Integer], key: Value).returns(T.nilable(Integer)) }
        def lookup(values, key)
          values[key]
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("values[castValueToString(key)]")
    end

    it "generates a typed hash conversion for an array of pairs" do
      ruby_code = <<~RUBY
        sig { params(pairs: T::Array[[String, Integer]]).returns(T::Hash[String, Integer]) }
        def index_pairs(pairs)
          pairs.to_h
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("ruby_pairs_to_hash_String_Int64(pairs)")
      expect(clear).to include("FN ruby_pairs_to_hash_String_Int64(pairs: []Tuple<String, Int64>) RETURNS {String}Int64 ->")
    end

    it "uses a self T.let assignment as local type metadata" do
      ruby_code = <<~RUBY
        def annotate
          values = []
          values = T.let(values, T::Array[String])
          values
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).not_to include("values = COPY values")
    end

    it "marks methods mutating when their Ruby blocks mutate self" do
      ruby_code = <<~RUBY
        class Parser
          def consume
            @position += 1
          end
          def process(items)
            items.each { consume }
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN parser__process(MUTABLE self: Parser")
      expect(clear).to include("parser__consume(&rtoc_self_view)")
    end

    it "marks methods mutating when they call a registered mutator through an instance field" do
      ruby_code = <<~RUBY
        class Registry
          def declare(name)
            @names << name
          end
        end

        class Host
          def initialize
            @registry = T.let(Registry.new, Registry)
          end

          def register(name)
            @registry.declare(name)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN host__register(MUTABLE self: Host")
      expect(clear).to include("registry__declare(&rtoc_self_view.registry, name)")
    end

    it "lowers a typed value-or-nil ternary through an optional branch slot" do
      ruby_code = <<~RUBY
        class Token < T::Struct
        end
        sig { params(tokens: T::Array[Token], use_token: T::Boolean).returns(T.nilable(Token)) }
        def previous(tokens, use_token)
          token = use_token ? tokens[0] : nil
          token
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE token_branch_value: ?Token = NIL")
      expect(clear).not_to include("MUTABLE token = IF")
    end

    it "narrows an optional local required by a compound and condition" do
      ruby_code = <<~RUBY
        class Token < T::Struct
          const :line, Integer
        end
        sig { params(enabled: T::Boolean, token: T.nilable(Token)).returns(T.nilable(Integer)) }
        def line_if_enabled(enabled, token)
          if enabled && token
            token.line
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("(token != NIL)")
      expect(clear).to include("token.line")
      expect(clear).not_to include("(token?).line")
    end

    it "emits CLEAR triple-quoted strings for Ruby heredocs" do
      ruby_code = <<~RUBY
        source = <<~CLEAR
          FN main() ->
            RETURN;
          END
        CLEAR
      RUBY
      # A squiggly heredoc strips the common indent; the emitted escaped
      # literal carries exactly that dedented content.
      expected_clear = <<~'CLEAR'
        MUTABLE source = "FN main() ->\n  RETURN;\nEND\n";
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
      expect_transpile("a = 1; b = 2; a << b", "MUTABLE a = 1;\nMUTABLE b = 2;\n(a << b);")
      expect_transpile("a = 5; b = 2; a % b", "MUTABLE a = 5;\nMUTABLE b = 2;\n(a MOD b);")
      expect_transpile("a = T.let(Set.new, T::Set[Integer]); a << 1", "MUTABLE a: [Set]Int64 = Set[];\n&a.insert(1);")
      expect_transpile("rank = 1; rank = -rank", "MUTABLE rank = 1;\nrank = (-rank);")
      expect_transpile("rank = 1; rank = +rank", "MUTABLE rank = 1;\nrank = (+rank);")
      expect_transpile("nums = []; x = 1; !nums.include?(x)", "MUTABLE nums = List[];\nMUTABLE x = 1;\n!(nums.contains?(x));")
    end

    it "maps Ruby stdout and stderr writes to CLEAR print" do
      expect_transpile('$stderr.puts "problem"', 'print("problem");')
      expect_transpile('$stdout.puts "ready"', 'print("ready");')
    end

    it "lowers Ruby string repetition through the configured runtime helper" do
      expect_transpile(
        'width = 3; " " * width',
        "MUTABLE width = 3;\ncompilerRepeatString(\" \", width);"
      )
    end

    it "lowers Ruby regex match operators to syntax-valid CLEAR calls in lax mode" do
      expect_transpile("word =~ /^[A-Z]/", 'regexMatch?(word(), "^[A-Z]");')
      expect_transpile("word !~ /^[A-Z]/", '!(regexMatch?(word(), "^[A-Z]"));')
    end

    it "lowers static Ruby type predicates to CLEAR type predicates" do
      expect_transpile("node.is_a?(AST::Identifier)", 'node() IS_A Identifier;')
      expect_transpile("node.respond_to?(:line)", 'respondsTo?(node(), "line");')
    end

    it "lowers a type-based case/when condition chain to IS_A, not value equality" do
      ruby_code = <<~RUBY
        class Bar < T::Struct
          const :x, Integer
        end
        class Baz < T::Struct
          const :y, Integer
        end
        class Foo
          def walk(node)
            current = node
            loop do
              case current
              when Bar, Baz
                current = current
              else
                break
              end
            end
            current
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      # Ruby `case x when SomeClass` is `SomeClass === x`, i.e. `x.is_a?(SomeClass)`.
      expect(clear).to include("IF (current IS_A Bar) OR (current IS_A Baz) THEN")
      expect(clear).not_to include("current == Bar")
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
        FN schemas__struct?<T>(schema: T) RETURNS Auto ->
          RETURN T IS_A StructSchema;
        END
        # End Ruby module Schemas
        MUTABLE schema = NIL;
        schemas__struct?(NIL);
      CLEAR

      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers self.class calls to known class methods" do
      ruby_code = <<~RUBY
        class Signature
          def self.copy_value(value)
            value
          end

          def copy(value)
            self.class.copy_value(value)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Signature {

        }

        FN signature__copy_value(value: Auto) RETURNS Auto ->
          RETURN COPY value;
        END
        FN signature__copy(self: Signature, value: Auto) RETURNS Auto
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN signature__copy_value(value);
        }
        END
      CLEAR

      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers self.class calls to singleton-class methods" do
      ruby_code = <<~RUBY
        class Parser
          @gradual_mode = false

          class << self
            def gradual_mode
              @gradual_mode
            end
          end

          def mode
            self.class.gradual_mode
          end
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN parser__gradual_mode()")
      expect(clear).to include("FN parser__mode(self: Parser) RETURNS Auto")
      expect(clear).to include("parser__gradual_mode();")
      expect(clear).to include("MUTABLE gradual_mode_value: Bool = FALSE;")
      expect(clear).to include("FN parser__gradual_mode() RETURNS Auto ->")
      expect(clear).not_to include('(\"Parser\").gradual_mode()')
    end

    it "copies symbol parameters into struct fields" do
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

        FN entry__initialize(MUTABLE self: Entry, visibility: String@symbol) RETURNS Void ->
          self.visibility = COPY visibility;
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

        FN entry__initialize(MUTABLE self: Entry) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {

        }
        END
        FN entry__new() RETURNS Entry@multiowned ->
          MUTABLE self = Entry{};
          entry__initialize(&self);
          RETURN self @multiowned;
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

        FN typeCapabilities__same?(self: TypeCapabilities, ownership: Auto) RETURNS Auto
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN ownership IS_A TypeCapabilityUnset;
        }
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "wraps scalar sentinels before lowering union identity checks" do
      ruby_code = <<~RUBY
        Result = T.type_alias { T.any(Integer, Symbol) }
        STOP = T.let(:stop, Symbol)
        sig { params(result: Result).returns(T::Boolean) }
        def stopped?(result)
          result.equal?(STOP)
        end
      RUBY

      result = RubyToClear.transpile(ruby_code, raise_on_error: true)
      expect(result).to include("RETURN (result == Result{ SymbolValue: COPY :stop });")
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
        FN typeCapabilities__unset?(self: TypeCapabilities, ownership: ?TypeCapabilitiesMaybeSymbol = TypeCapabilitiesMaybeSymbol{ TypeCapabilityUnset: COPY TypeCapabilityUnset{} }) RETURNS Bool
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN ((ownership != NIL) AND (ownership IS_A TypeCapabilityUnset));
        }
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
      expect(clear).to include("IF value IS_A String@symbol AS cast_payload THEN")
      expect(clear).to include("RETURN NIL;")
    end

    it "transpiles index access and assignments" do
      expect_transpile("states = {}; key = 1; states[key]", "MUTABLE states = {};\nMUTABLE key = 1;\nstates[key];")
      expect_transpile("states = {}; key = 1; value = 2; states[key] = value", "MUTABLE states = {};\nMUTABLE key = 1;\nMUTABLE value = 2;\nstates[key] = value;")
      expect_transpile("line = 'abc'; line[0]", "MUTABLE line = \"abc\";\nline.substr(0, 1);")
      expect_transpile("T.cast(token.value, String)[0]", "CAST(token().value() AS String).substr(0, 1);")
      expect_transpile("line = 'abc'; line[1, 2]", "MUTABLE line = \"abc\";\nline.substr(1, 2);")
      expect_transpile("line = 'abc'; line[1..2]", "MUTABLE line = \"abc\";\nline.substr(1, ((2 - 1) + 1));")
      expect_transpile("line = 'abc'; line[1..]", "MUTABLE line = \"abc\";\nline.substr(1, (line.length() - 1));")
      expect_transpile("parts = split_name; parts.drop(1)", "MUTABLE parts = split_name();\nparts |> SKIP 1;")
    end

    it "transpiles standard method calls" do
      expect_transpile("pattern = 'abc'; scan(pattern)", "MUTABLE pattern = \"abc\";\nscan(pattern);")
      expect_transpile("obj = nil; pattern = 'abc'; obj.scan(pattern)", "MUTABLE obj = NIL;\nMUTABLE pattern = \"abc\";\nNIL.scan(pattern);")
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
          RETURN symbol(core_str);
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
          RETURN symbol((CAST(name AS String)));
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
          RETURN COPY CAST(name AS String);
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
        FN count_name(count_value: Int64) RETURNS String ->
          RETURN COPY count_value.toString();
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

        FN item__display(self: Item) RETURNS String ->
          RETURN COPY CAST(self.kind AS String);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers String#strip#to_sym as a symbol conversion" do
      expect_transpile(
        'part = " Name "; part.strip.to_sym',
        "MUTABLE part = \" Name \";\nsymbol(part.trim());"
      )
      expect_transpile(
        'parts = T.let([" A "], T::Array[String]); parts.map { |part| part.strip.to_sym }',
        "MUTABLE parts: []String = [\" A \"];\nparts |> SELECT symbol(_.trim());"
      )
      expect_transpile(
        'compilerRegexCapture(generic_match, 2).split(",").map { |part| part.strip.to_sym }',
        '(compilerRegexCapture(generic_match(), 2)).split(",") |> SELECT symbol(_.trim());'
      )
    end

    it "lowers supported String character deletion and float conversion" do
      expect_transpile(
        'value = "1_2.5"; value.tr("_", "").to_f',
        'MUTABLE value = "1_2.5";' + "\n(value.replace(\"_\", \"\").toFloat() OR_ELSE 0.0);"
      )
    end

    it "rejects splat arguments instead of emitting a runtime helper" do
      expect {
        RubyToClear.transpile("T.unsafe(node_class).new(start_token, *args)")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /Splat arguments require an explicit call shape/)
    end

    it "lowers splats inside array literals as concatenated array segments" do
      expect_transpile(
        "tail = [2, 3]; values = [1, *tail, 4]",
        "MUTABLE tail = [2, 3];\nMUTABLE values = ([1] + tail + [4]);"
      )
    end

    it "lowers a splatted conditional array segment through the expression-IF path, not the statement path" do
      # visit_array_node's splat branch called plain visit(element.expression)
      # on the splatted node - the generic, STATEMENT-oriented dispatcher -
      # instead of expression_argument_code (used two lines below for every
      # other array element), which has the dedicated IfNode branch that
      # renders bare, semicolon-free branches. Concatenating a statement-
      # rendered "IF ... THEN x; ELSE y; END" with `+ [...]` produces a real
      # parser error (`Expected END, got ;`) once the surrounding constructor
      # nesting is deep enough that the array literal's own element type
      # can't be inferred (confirmed real corpus fingerprint: 34 files,
      # mir/lower/pipeline/pipeline_range_lowerer.rb's find_fold_plan
      # splatting `*(if prefix.item_owned then plan.marks else [] end)`
      # ahead of two more MIR::Set/BreakStmt elements it can't unify a type
      # with, unlike this file's shallower, single-type-inferable splat
      # tests above).
      ruby_code = <<~RUBY
        class Plan < T::Struct
          extend T::Sig
          const :name, String

          sig { returns(T::Array[String]) }
          def marks
            [name]
          end
        end

        TailA = Struct.new(:label)
        TailB = Struct.new(:value)
        Let = Struct.new(:name, :init)
        FoldPlan = Struct.new(:acc_init_stmts, :loop_acc_stmts, keyword_init: true)

        sig { params(owned: T::Boolean, item_name: String, pred: String).returns(FoldPlan) }
        def build(owned, item_name, pred)
          FoldPlan.new(
            acc_init_stmts: [Let.new("result", nil)],
            loop_acc_stmts: [pred, [
              *(if owned
                  Plan.new(name: item_name).marks
                else
                  []
                end),
              TailA.new("a"),
              TailB.new("b"),
            ]],
          )
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include(
        "((IF owned THEN\n    TRY (plan__marks((Plan{ name: COPY item_name })))\n  ELSE\n    List[]\n  END) + " \
        "[TailA{ label: \"a\" }, TailB{ value: \"b\" }])"
      )
    end

    it "lowers simple block parameter destructuring inside lambdas" do
      expect_transpile(
        "fields.each_with_object({}) { |(kv, t), h| h[kv.first] = t }",
        <<~CLEAR
          fields().each_with_object({}, %(tuple_param_0, h) -> {
            MUTABLE kv = tuple_param_0._0;
            MUTABLE t = tuple_param_0._1;
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
          MUTABLE y = 2;
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
          deactivate_mut();
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
        MUTABLE token = IF method?() THEN
          {
          MUTABLE rtoc_value_block_marker = 0;
          is_method = TRUE;
          consume(symbol("METHOD"))
        }
        ELSE
          consume(symbol("FN"))
        END;
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

    it "narrows optional assignment predicates" do
      ruby_code = <<~RUBY
        sig { returns(T.nilable(String)) }
        def next_item; nil; end
        if (item = next_item)
          item.strip
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code, raise_on_error: true)
      expect(clear).to include("IF item EXISTS AS item_value THEN")
      expect(clear).to include("item_value.trim();")
    end

    it "keeps returns when optional guard rewrites wrap the final function body" do
      ruby_code = <<~RUBY
        sig { params(node: T.nilable(String)).returns(String) }
        def present_value(node)
          return "none" unless node
          node
        end
      RUBY
      expected_clear = <<~CLEAR
        FN present_value(node: ?String) RETURNS String ->
          IF node EXISTS AS node_value THEN
            RETURN COPY node_value;
          ELSE
            RETURN "none";
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "unwraps non-union optional locals in truthy branches" do
      ruby_code = <<~RUBY
        sig { returns(String) }
        def selected_name
          name = T.let("name", T.nilable(String))
          return name if name

          return "fallback"
        end
      RUBY
      expected_clear = <<~CLEAR
        FN selected_name() RETURNS String ->
          MUTABLE name: ?String = "name";
          IF name EXISTS AS name_value THEN
            RETURN name_value;
          END
          RETURN "fallback";
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "unwraps optional parameters in truthy branches" do
      ruby_code = <<~RUBY
        sig { params(name: T.nilable(String)).void }
        def use_name(name)
          puts(name) if name
        end
      RUBY
      expected_clear = <<~CLEAR
        FN use_name(name: ?String) RETURNS Void ->
          IF name EXISTS AS name_value THEN
            puts(name_value);
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "unwraps optional parameters in returning ternaries" do
      ruby_code = <<~RUBY
        sig { params(name: T.nilable(String)).returns(T::Boolean) }
        def known_name?(name)
          name ? known?(name) : false
        end
      RUBY
      expected_clear = <<~CLEAR
        FN known_name?(name: ?String) RETURNS Bool ->
          IF name EXISTS AS name_value THEN
            RETURN known?(name_value);
          ELSE
            RETURN FALSE;
          END
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

    it "keeps indexed writes with expression if values expression-safe inside blocks" do
      ruby_code = <<~RUBY
        Raw = T.type_alias { T.any(T::Array[T.untyped], T::Hash[String, T.untyped]) }
        reg = T.let({}, T::Hash[String, Raw])
        out = T.let({}, T::Hash[String, T.untyped])
        registry_map = {}
        reg.each do |name, entry|
          out[name] =
            if entry.is_a?(Array)
              entry.map { |e| convert_entry(name, e, registry_map) }
            elsif entry.is_a?(Hash)
              convert_entry(name, entry, registry_map)
            end
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Raw { ArrayValue: []@multiowned Any, AnyMultiowned: Any@multiowned }
        MUTABLE reg: {String}Raw = {};
        MUTABLE out: Any@multiowned = {};
        MUTABLE registry_map = {};
        reg.keys() |> EACH {
          MUTABLE entry: Raw = (reg[_] OR_ELSE CAST(panic("missing hash key") AS Raw));
        out[_] = IF entry IS_A []Any THEN
          entry |> SELECT convert_entry(_, _, registry_map)
        ELSE_IF entry IS_A {}Any THEN
          convert_entry(_, entry, registry_map)
        ELSE
          NIL
        END;
        };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "keeps runtime type-test if call argument branches expression-only" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(Type, FunctionSignature, Symbol) }

        sig { params(val: Value).returns(Type) }
        def normalize(val)
          keep(
            if val.is_a?(Type)
              val
            elsif val.is_a?(FunctionSignature)
              from_function_signature(val)
            else
              fallback(val)
            end
          )
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Value { Type: Type, FunctionSignature: FunctionSignature, SymbolValue: String@symbol }
        FN normalize(val: Value) RETURNS Type ->
          RETURN keep(IF val IS_A Type THEN
            val
          ELSE_IF val IS_A FunctionSignature THEN
            from_function_signature(val)
          ELSE
            fallback(val)
          END);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Type.from_function_signature through typed CLEAR helpers" do
      ruby_code = <<~RUBY
        sig { params(signature: FunctionSignature).returns(Type) }
        def normalize(signature)
          Type.from_function_signature(signature)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN normalize(signature: FunctionSignature) RETURNS Type ->
          RETURN CAST(rubyToClearTypeFromFunctionSignature(CAST(signature AS FunctionSignature)) AS Type);
        END
        FN rubyToClearTypeFromFunctionSignature(signature: FunctionSignature) RETURNS Type@multiowned ->
          function_type_from_parts(functionSignature__params(signature) |> SELECT param__type(_), functionSignature__return_type(signature), functionSignature__reentrant(signature), signature);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Type.from_function_signature arguments in expression branches" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(Type, FunctionSignature) }
        sig { params(value: Value).returns(Type) }
        def normalize(value)
          if value.is_a?(FunctionSignature)
            Type.from_function_signature(value)
          else
            value
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF value IS_A FunctionSignature AS function_signature THEN")
      expect(clear).to include("rubyToClearTypeFromFunctionSignature(CAST(function_signature AS FunctionSignature))")
    end

    it "preserves Type helper ownership for multiowned destinations" do
      node = Prism.parse("value").value.statements.body.first
      transpiler = described_class.new("")
      code = "CAST(rubyToClearTypeFromFunctionSignature(CAST(value AS FunctionSignature)) AS Type)"

      wrapped = transpiler.send(
        :wrap_argument_for_parameter_type,
        code,
        node,
        "Type@multiowned"
      )
      expect(wrapped).to eq("rubyToClearTypeFromFunctionSignature(CAST(value AS FunctionSignature))")
    end

    it "lowers runtime type-test field assignments to statement branches" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(Type, FunctionSignature, Symbol) }

        sig { params(val: Value).returns(Type) }
        def normalize(val)
          @type_object = T.let(
            if val.is_a?(Type)
              val
            elsif val.is_a?(FunctionSignature)
              from_function_signature(val)
            else
              fallback(val)
            end,
            T.nilable(Type)
          )
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Value { Type: Type, FunctionSignature: FunctionSignature, SymbolValue: String@symbol }
        FN normalize(val: Value) RETURNS Type ->
          IF val IS_A Type AS type THEN
            self.type_object = COPY type;
          ELSE
            IF val IS_A FunctionSignature AS function_signature THEN
              self.type_object = from_function_signature(function_signature);
            ELSE
              self.type_object = fallback(val);
            END
          END
          RETURN UNWRAP (IF val IS_A Type THEN
            val
          ELSE_IF val IS_A FunctionSignature THEN
            from_function_signature(val)
          ELSE
            fallback(val)
          END);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses statement branches for typed ivar runtime-test assignments" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(Type, FunctionSignature, Symbol) }
        class Holder
          sig { params(value: Value).returns(Type) }
          def store(value)
            @stored = T.let(
              if value.is_a?(Type)
                value
              elsif value.is_a?(FunctionSignature)
                Type.from_function_signature(value)
              else
                fallback(value)
              end,
              T.nilable(Type)
            )
            T.must(@stored)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF value IS_A Type AS type THEN")
      expect(clear).not_to include("self.stored = IF")
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
        MUTABLE value = IF a() THEN
          left()
        ELSE
          {
          MUTABLE rtoc_value_block_marker = 0;
          seen = TRUE;
          right()
        }
        END;
      CLEAR
      expect(RubyToClear.transpile(ruby_code, raise_on_error: false).strip).to eq(expected_clear.strip)
    end

    it "terminates expression if statements nested inside statement if bodies" do
      ruby_code = <<~RUBY
        def children(node, skip)
          if node
            if node.copy?
              skip ? [] : [node.value].compact
            else
              [node.left, node.right].compact
            end
          else
            []
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        FN children(node: Auto, skip_value: Auto) RETURNS Auto ->
          IF node THEN
            IF node.copy?() THEN
              IF skip_value THEN
                RETURN List[];
              ELSE
                RETURN ([node.value()]);
              END
            ELSE
              RETURN ([node.left(), node.right()]);
            END
          ELSE
            RETURN List[];
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
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
          deactivate_mut();
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
        IF (val == :a) THEN
          1;
        ELSE_IF (val == :b) THEN
          2;
        ELSE
          99;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses statement control flow for mutating case arms in effect blocks" do
      ruby_code = <<~RUBY
        sig { params(values: T::Array[Integer], out: T::Array[Integer]).void }
        def collect(values, out)
          values.each do |value|
            case value
            when 1
              out << value
            else
              out << 0
            end
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF (_ == 1) THEN")
      expect(clear).to include("out.append(_);")
      expect(clear).not_to include("PARTIAL MATCH _ START")
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

    it "uses statement control flow for typed union case returns" do
      ruby_code = <<~RUBY
        class Left < T::Struct
        end
        class Right < T::Struct
        end
        Result = T.type_alias { T.any(Left, Right) }

        sig { returns(T.nilable(Left)) }
        def maybe_left
          Left.new
        end

        sig { params(kind: Symbol).returns(Result) }
        def pick_result(kind)
          case kind
          when :left then Left.new
          when :maybe then maybe_left
          else Right.new
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF (kind == :left) THEN")
      expect(clear).to include("RETURN Result{ Left: COPY Left{} };")
      expect(clear).to include("RETURN Result{ Left: COPY UNWRAP (maybe_left()) };")
      expect(clear).to include("RETURN Result{ Right: COPY Right{} };")
    end

    it "uses statement control flow for heap-valued case returns" do
      ruby_code = <<~RUBY
        sig { params(root: Symbol, parts: T::Array[String], context: String).returns(String) }
        def render_path(root, parts, context)
          case root
          when :static
            parts.join(".")
          when :context
            ([context] + parts).join(".")
          else
            raise "unknown root"
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF (root == :static) THEN")
      expect(clear).to include('RETURN parts.join(".");')
      expect(clear).to include('RETURN (([context] + parts)).join(".");')
      expect(clear).not_to include("RETURN PARTIAL MATCH root START")
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

    it "lowers multi-statement case arms used as values" do
      ruby_code = <<~RUBY
        value = case kind
                when :a
                  prepare
                  1
                else
                  cleanup
                  2
                end
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE value = PARTIAL MATCH kind() START
          :a -> {
            MUTABLE rtoc_value_block_marker = 0;
            prepare();
            1
          },
          DEFAULT -> {
            MUTABLE rtoc_value_block_marker = 0;
            cleanup();
            2
          }
        END;
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

    it "lowers statementful case expression arms to value blocks in lax mode" do
      ruby_code = <<~RUBY
        result = case val
        when :a
          seen = true
          1
        end
      RUBY
      expect(RubyToClear.transpile(ruby_code, raise_on_error: false).strip).to eq(<<~CLEAR.strip)
        MUTABLE result = PARTIAL MATCH val() START
          :a -> {
            MUTABLE rtoc_value_block_marker = 0;
            MUTABLE seen = TRUE;
            1
          },
          DEFAULT -> NIL
        END;
      CLEAR
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
          RETURN yield(node);
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
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "preserves empty Ruby modules without inventing namespace syntax" do
      expect_transpile("module Empty; end", "# Ruby module Empty")
    end

    it "hoists module constants declared after methods for CLEAR lexical visibility" do
      ruby_code = <<~RUBY
        module Registry
          extend T::Sig

          sig { params(key: Symbol).returns(T.nilable(Integer)) }
          def self.lookup(key)
            VALUES[key]
          end

          VALUES = T.let({ one: 1 }, T::Hash[Symbol, Integer])
        end
      RUBY
      expected_clear = <<~CLEAR
        # Ruby module Registry
        MUTABLE values: {String@symbol}Int64 = {:one: 1};
        FN registry__lookup(key: String@symbol) RETURNS ?Int64 ->
          RETURN COPY values[key];
        END
        # End Ruby module Registry
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles Struct.new definition and constructor call mapping" do
      ruby_code = <<~RUBY
        Token = Struct.new(:type, :value, :line, :column)
        t = Token.new(:ELLIPSIS, '...', 1, 1)
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Token {
          type: String@symbol,
          value: String,
          line: Int64,
          column: Int64
        }
        MUTABLE t = Token{ type: :ELLIPSIS, value: "...", line: 1, column: 1 };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "preserves the enclosing class after a blockless Struct.new constant" do
      ruby_code = <<~RUBY
        class Lexer
          Token = Struct.new(:type)

          sig { params(source: String).void }
          def initialize(source)
            @source = source
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Lexer {
          source: String
        }

        STRUCT Token {
          type: Any@multiowned
        }
        FN lexer__initialize(MUTABLE self: Lexer, source: String) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.source = COPY source;
        }
        END
        FN lexer__new(source: String) RETURNS Lexer@multiowned ->
          MUTABLE self = Lexer{ source: COPY source };
          lexer__initialize(&self, source);
          RETURN self @multiowned;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses typed Struct.new accessors to refine generated field storage" do
      ruby_code = <<~RUBY
        Item = Struct.new(:name, :count) do
          sig { returns(String) }
          def name
            self[:name]
          end

          sig { params(value: Integer).void }
          def count=(value)
            self[:count] = value
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("name: String")
      expect(clear).to include("count: Int64")
    end

    it "uses typed factory parameters to refine positional Struct.new fields" do
      ruby_code = <<~RUBY
        module Ops
          Entry = Struct.new(:name, :items)

          module DSL
            sig { params(name: String, items: T::Array[String]).returns(Entry) }
            def self.entry(name, items)
              Entry.new(name, items)
            end
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("name: String")
      expect(clear).to include("items: []String")
    end

    it "honors explicit Struct.new raw field type overrides" do
      ruby_code = <<~RUBY
        Item = Struct.new(:name) do
          # ruby-to-clear: field-type name=Any
          sig { returns(String) }
          def name
            self[:name].to_s
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("name: Any")
    end

    it "transpiles instance methods inside Struct.new assignment blocks" do
      ruby_code = <<~RUBY
        FunctionDef = Struct.new(:name, :return_type) do
          def raw_name
            name
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT FunctionDef {
          name: Any@multiowned,
          return_type: Any@multiowned
        }

        FN functionDef__raw_name(self: FunctionDef) RETURNS Auto ->
          RETURN self.name;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers self index access to fields inside Struct.new assignment blocks" do
      ruby_code = <<~RUBY
        StructField = Struct.new(:type, :default, keyword_init: true) do
          def default
            self[:default]
          end

          def default=(value)
            self[:default] = value
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT StructField {
          type: Any@multiowned,
          default: Any@multiowned
        }

        FN structField__default(self: StructField) RETURNS Auto ->
          RETURN COPY self.default;
        END
        FN structField__set_default(MUTABLE self: StructField, value: Auto) RETURNS Auto ->
          self.default = COPY value;
          RETURN value;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "copies a borrowed non-trivially-copyable field read back through a Sorbet type-annotation-only self-assignment getter" do
      # Sorbet's idiom for a memoizing getter's implicit return is `@field =
      # T.let(@field, SomeType); ` as the method's ONLY statement - a self-
      # assignment whose sole purpose is the type annotation, matched by
      # lambda_statement_node?'s WriteNode branch in render_returning_
      # statement. That branch computed the return value via expression_
      # argument_code + wrap_argument_for_parameter_type but never called
      # materialize_borrowed_code (unlike the generic-expression branch a
      # few lines below it), so a borrowed field of a non-trivially-copyable
      # union type escaped as a bare, uncopied read - real corpus:
      # LSP::DocumentStore's Struct.new-generated `cached_findings` getter
      # ("Cannot return borrowed value without COPY... is not implicitly
      # copyable").
      ruby_code = <<~RUBY
        Findings = T.type_alias { T.nilable(T.any(Symbol, String)) }
        Doc = Struct.new(:findings, keyword_init: true) do
          sig { returns(Findings) }
          def cached_findings
            @cached_findings = T.let(@cached_findings, Findings)
          end
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN COPY self.cached_findings;")
    end

    it "copies borrowed values stored through self index writers" do
      ruby_code = <<~RUBY
        Item = Struct.new(:value) do
          sig { params(value: String).void }
          def value=(value)
            self[:value] = value
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("self.value = COPY value;")
    end

    it "drops Struct.new initializer super calls while preserving field normalization" do
      ruby_code = <<~RUBY
        Param = Struct.new(:type, keyword_init: true) do
          def initialize(**kw)
            super
            t = T.let(self[:type], T.nilable(Symbol))
            self[:type] = t || :Any
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Param {
          type: Any@multiowned
        }

        FN param__initialize(MUTABLE self: Param, kw: {String@symbol}Auto = {}) RETURNS Void ->
          MUTABLE t: ?String@symbol = COPY self.type;
          self.type = (t OR_ELSE :Any);
        END
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
          takes: Any@multiowned
        }
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "marks generated type-alias unions public with a ruby-to-clear annotation" do
      ruby_code = <<~RUBY
        class Type
          # ruby-to-clear: pub
          TypeInput = T.type_alias { T.any(Type, Symbol, String) }
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("PUB UNION TypeTypeInput { TypeMultiowned: Type@multiowned, SymbolValue: String@symbol, StringValue: String }")
    end

    it "makes generated unions public when exposed by public struct fields" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(String, Integer) }

        # ruby-to-clear: pub
        class Envelope < T::Struct
          const :value, Value
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("PUB UNION Value { StringValue: String, Int64Value: Int64 }")
      expect(clear).to include("PUB STRUCT Envelope")
      expect(clear).to include("value: Value")
    end

    it "marks generated class structs, methods, and constructors public with a ruby-to-clear annotation" do
      ruby_code = <<~RUBY
        # ruby-to-clear: pub
        class ZigType
          sig { params(source: String).void }
          def initialize(source)
            @source = T.let(source, String)
          end

          sig { returns(String) }
          def source
            @source
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        PUB STRUCT ZigType {
          source: String
        }

        PUB FN zigType__initialize(MUTABLE self: ZigType, source: String) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.source = COPY source;
        }
        END
        PUB FN zigType__source(self: ZigType) RETURNS String
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN COPY rtoc_self_view.source;
        }
        END
        PUB FN zigType__new(source: String) RETURNS ZigType@multiowned ->
          MUTABLE self = ZigType{ source: COPY source };
          zigType__initialize(&self, source);
          RETURN self @multiowned;
        END
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
      # An indexed read is optional in CLEAR, so a field access on one needs
      # safe navigation; `?.` is the operator for it.
      expect(clear).to include("params[rtoc_idx]?.takes;")
      expect(clear).not_to include("params[rtoc_idx].takes()")
    end

    it "lowers symbol indexes on known Struct.new values to field access" do
      ruby_code = <<~RUBY
        Capability = Struct.new(:var_node)

        sig { params(capability: Capability).returns(T.untyped) }
        def capability_node(capability)
          capability[:var_node]
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("capability.var_node;")
      expect(clear).not_to include("capability[:var_node]")
    end

    it "preserves typed array elements inside each_with_object blocks" do
      ruby_code = <<~RUBY
        class Param < T::Struct
          const :name, String
          const :symbol, T.nilable(String)
        end

        sig { params(params: T::Array[Param]).returns(T::Hash[String, String]) }
        def live_param_symbols(params)
          params.each_with_object({}) do |param, symbols|
            symbols[param.name] = param.symbol if param.symbol
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("params |> REDUCE({})")
      # `EXISTS AS symbol_value` already unwrapped; the frontend rejects a
      # second UNWRAP with UNWRAP_NON_OPTIONAL.
      expect(clear).to include("acc[_.name] = COPY symbol_value;")
      expect(clear).not_to include("UNWRAP (COPY symbol_value)")
      expect(clear).not_to include(".name()")
      expect(clear).not_to include(".symbol()")
    end

    it "transpiles keyword constructors for statically known struct fields" do
      ruby_code = <<~RUBY
        Token = Struct.new(:type, :value, keyword_init: true)
        t = Token.new(type: :IDENT, value: "name")
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Token {
          type: Any@multiowned,
          value: Any@multiowned
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
          type: Any@multiowned,
          value: Any@multiowned
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

        FN param__type(self: Param) RETURNS Auto ->
          RETURN COPY self.type;
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

        FN action__copy(self: Action) RETURNS Auto ->
          RETURN Action{ name: COPY self.name };
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

        FN zigType__error_union?(self: ZigType) RETURNS Auto
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN rtoc_self_view.flag;
        }
        END
        FN zigType__fallible_return_type(self: ZigType) RETURNS Auto
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN zigType__error_union?(rtoc_self_view);
        }
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

        FN type__initialize(MUTABLE self: Type, raw: Auto) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.raw = COPY raw;
        }
        END
        FN type__new(raw: Auto) RETURNS Type@multiowned ->
          MUTABLE self = Type{ raw: raw };
          type__initialize(&self, raw);
          RETURN self @multiowned;
        END
        FN type__raw_value(self: Type) RETURNS Auto
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN rtoc_self_view.raw;
        }
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "merges same-file Struct.new reopening fields into one declaration" do
      ruby_code = <<~RUBY
        Item = Struct.new(:name)

        class Item
          sig { params(tags: T::Array[String]).void }
          def tags=(tags)
            @tags = tags
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear.scan(/^STRUCT Item/).length).to eq(1)
      expect(clear).to include("name: Any")
      expect(clear).to include("tags:")
      expect(clear).to include("FN item__set_tags(MUTABLE self: Item, tags_value: []String) RETURNS Void ->")
    end

    it "expands mixin instance methods per including struct" do
      ruby_code = <<~RUBY
        module Named
          sig { returns(String) }
          def label
            name
          end
        end

        Left = Struct.new(:name) { include Named }
        Right = Struct.new(:name) { include Named }
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN left__label(self: Left) RETURNS String ->")
      expect(clear).to include("FN right__label(self: Right) RETURNS String ->")
      expect(clear).not_to match(/^FN label\(/)
      expect(clear).not_to include("include(Named)")
    end

    it "adds CLEAR bang names to mutating methods expanded from mixins" do
      ruby_code = <<~RUBY
        module Memoized
          def cached_value
            @cached_value = @cached_value
          end
        end

        Item = Struct.new(:cached_value) { include Memoized }
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN item__cached_value(MUTABLE self: Item) RETURNS Auto ->")
    end

    it "uses legal CLEAR names for mutating predicate methods" do
      ruby_code = <<~RUBY
        class Item
          def ready?
            @ready = true
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN item__ready?(MUTABLE self: Item) RETURNS Auto")
    end

    it "adds typed mixin storage to including structs" do
      ruby_code = <<~RUBY
        module Memoized
          def cached
            @cached = T.let(@cached, T.nilable(String))
          end
        end

        Item = Struct.new(:name) { include Memoized }
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("cached: ?String")
    end

    it "lets later class reopenings override Struct.new mixin methods" do
      ruby_code = <<~RUBY
        module Named
          def label
            "mixin"
          end
        end

        Item = Struct.new(:name) { include Named }
        class Item
          def label
            name
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear.scan(/^FN .*label\(/).length).to eq(1)
      expect(clear).to include("self.name;")
      expect(clear).not_to include('"mixin";')
    end

    it "adds bang names only in CLEAR for Ruby methods that mutate self" do
      ruby_code = <<~RUBY
        class Slot
          def replace(value)
            @value = value
          end

          def update(value)
            replace(value)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN slot__replace(MUTABLE self: Slot, value: Auto)")
      expect(clear).to include("slot__replace(&rtoc_self_view, value);")
    end

    it "disambiguates an inferred bang from an existing Ruby bang sibling" do
      ruby_code = <<~RUBY
        class Value
          def current
            @current ||= 0
          end

          def current!
            current
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN value__current(MUTABLE self: Value)")
      expect(clear).to include("FN value__current_mut(MUTABLE self: Value)")
      expect(clear).to include("value__current(&rtoc_self_view);")
    end

    it "preserves function field types when assigning them to locals" do
      ruby_code = <<~RUBY
        class Callback
          sig { params(writer: T.proc.params(value: String).void).void }
          def initialize(writer)
            @writer = T.let(writer, T.proc.params(value: String).void)
          end

          def run(value)
            writer = @writer
            writer.call(value)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("writer: COPY writer")
      expect(clear).to include("MUTABLE writer = COPY rtoc_self_view.writer;")
      expect(clear).to include("writer(value);")
      expect(clear).not_to include("writer.call")
    end

    it "does not collect nested class fields on the outer class" do
      ruby_code = <<~RUBY
        class Outer
          class Inner
            def initialize(value)
              @value = value
            end
          end

          def initialize(state)
            @state = state
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Outer {
          state: Any
        }

        STRUCT Inner {
          value: Any
        }

        FN inner__initialize(MUTABLE self: Inner, value: Auto) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.value = COPY value;
        }
        END
        FN inner__new(value: Auto) RETURNS Inner@multiowned ->
          MUTABLE self = Inner{ value: value };
          inner__initialize(&self, value);
          RETURN self @multiowned;
        END
        FN outer__initialize(MUTABLE self: Outer, state: Auto) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.state = COPY state;
        }
        END
        FN outer__new(state: Auto) RETURNS Outer@multiowned ->
          MUTABLE self = Outer{ state: state };
          outer__initialize(&self, state);
          RETURN self @multiowned;
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

        FN a__take(self: A, other: B) RETURNS Int64
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN b__copy(other);
        }
        END
        FN a__copy(self: A) RETURNS Auto
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN 1;
        }
        END
        STRUCT B {

        }

        FN b__copy(self: B) RETURNS Auto
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN 2;
        }
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
      expect(clear).to include("FN a__initialize(MUTABLE self: A, value: Auto) RETURNS Void")
      expect(clear).to include("FN b__initialize(MUTABLE self: B, value: Auto) RETURNS Void")
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

    it "emits parser-safe names for qualified T::Struct declarations" do
      ruby_code = <<~RUBY
        class Annotator::Phases::TypeAnalysisSession < T::Struct
          const :active, T::Boolean
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)

      expect(clear).to include("STRUCT TypeAnalysisSession {")
      expect(clear).not_to include("STRUCT Annotator::Phases::TypeAnalysisSession")
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
          items: []String@symbol
        }
        Parts{ array: FALSE, name: NIL, items: List[] };
        Parts{ array: TRUE, name: NIL, items: List[] };
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
          variants: [Set]String
        }

        FN enumSchema__initialize(MUTABLE self: EnumSchema) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.variants = Set[];
        }
        END
        FN enumSchema__new() RETURNS EnumSchema@multiowned ->
          MUTABLE self = EnumSchema{ variants: Set[] };
          enumSchema__initialize(&self);
          RETURN self @multiowned;
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
          RETURN Action{ name: COPY name };
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "does not copy an immediate symbol-valued constructor expression" do
      ruby_code = <<~RUBY
        class Result < T::Struct
          const :kind, Symbol
        end

        sig { params(shared: T::Boolean).returns(Result) }
        def build(shared)
          Result.new(kind: shared ? :shared : :local)
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN Result{ kind: IF shared_value THEN")
      expect(clear).not_to include("kind: COPY IF")
    end

    it "keeps identity for borrowed parameters stored in untyped @multiowned constructor fields" do
      ruby_code = <<~RUBY
        class Step < T::Struct
          const :value, T.untyped
        end

        sig { params(value: String).returns(Step) }
        def build(value)
          Step.new(value: value)
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Step {
          value: Any@multiowned
        }
        FN build(value: String) RETURNS Step ->
          RETURN Step{ value: value };
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
          items: []String
        }

        FN shape__copy(self: Shape) RETURNS Shape ->
          RETURN Shape{ name: self.name, items: COPY self.items };
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

        FN shape__resolved(self: Shape) RETURNS String@symbol ->
          MUTABLE current_raw = COPY self.raw;
          IF current_raw IS_A FunctionSignature AS function_signature THEN
            RETURN function_signature.return_type().to_sym();
          ELSE
          IF current_raw IS_A String@symbol AS string_symbol THEN
              RETURN string_symbol;
          ELSE
              RETURN :Any;
          END
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

        FN shape__resolved(self: Shape) RETURNS String@symbol ->
          MUTABLE current_raw = COPY self.raw;
          IF current_raw IS_A FunctionSignature AS function_signature THEN
            RETURN function_signature.return_type().to_sym();
          ELSE
          IF current_raw IS_A String AS string THEN
              RETURN symbol(string);
          ELSE
          IF current_raw IS_A String@symbol AS string_symbol THEN
                RETURN string_symbol;
          ELSE
                RETURN :Any;
          END
          END
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers is_a? expressions on nilable unions with an optional unwrap" do
      ruby_code = <<~RUBY
        Raw = T.type_alias { T.nilable(T.any(Symbol, T::Array[Symbol])) }

        sig { params(raw: Raw).returns(T::Boolean) }
        def fixed(raw)
          raw.is_a?(Array)
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Raw { SymbolValue: String@symbol, ArrayValue: []String@symbol }
        FN fixed(raw: ?Raw) RETURNS Bool ->
          RETURN ((raw != NIL) AND (raw IS_A []String@symbol));
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
        FN stmt(type: String@symbol, block: ?StmtRule = NIL) RETURNS StmtRule ->
          RETURN COPY UNWRAP (block);
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
      expect_transpile(
        "lit.field_tokens = fields",
        "MUTABLE rtoc_writer_receiver_1 = lit();\nrtoc_writer_receiver_1.field_tokens = fields();"
      )
    end

    it "copies copyable parameters assigned through attribute writers" do
      ruby_code = <<~RUBY
        class Contract < T::Struct
          prop :module_alias, T.nilable(String), default: nil
        end

        class Signature
          sig { params(contract: Contract).void }
          def initialize(contract)
            @contract = T.let(contract, Contract)
          end

          sig { params(module_alias: T.nilable(String)).void }
          def replace(module_alias)
            @contract.module_alias = module_alias
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("rtoc_self_view.contract.module_alias = COPY module_alias;")
    end

    it "maps keyword calls to positional calls when method parameters are known" do
      ruby_code = <<~RUBY
        def parse_function_def(visibility = :package, is_method: false)
          visibility
        end

        parse_function_def(:package, is_method: true)
      RUBY
      expected_clear = <<~CLEAR
        FN parse_function_def(visibility: Auto = :package, is_method: Auto = FALSE) RETURNS Auto ->
          RETURN COPY visibility;
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
        FN typeShape__from_core(shape_str: Auto) RETURNS Auto ->
          RETURN typeShape__parse_generic_shape(shape_str, TRUE, FALSE);
        END
        FN typeShape__parse_generic_shape(shape_str: Auto, array: Auto, map: Auto) RETURNS Auto ->
          RETURN COPY shape_str;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "maps keyword calls to class methods from the enclosing class body" do
      ruby_code = <<~RUBY
        class Parser
          def self.rule(type, action:, pattern: [])
            type
          end

          RULES = [rule(:KEYWORD, action: :parse)]
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE rules: []Any = [rule(:KEYWORD, :parse, List[])];")
    end

    it "uses a mutable local copy for reassigned Ruby parameters" do
      ruby_code = <<~RUBY
        def choose(flag: false)
          flag = true unless flag
          flag
        end

        choose(flag: true)
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN choose(flag_input: Auto = FALSE) RETURNS Auto ->")
      expect(clear).to include("MUTABLE flag = COPY flag_input;")
      expect(clear).to include("choose(TRUE);")
      expect(clear).not_to include("FN choose!")
    end

    it "detects captured parameter reassignment inside blocks" do
      ruby_code = <<~RUBY
        sig { params(value: String).returns(String) }
        def consume(value)
          loop do
            value = value.strip
            break
          end
          value
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code, raise_on_error: true)
      expect(clear).to include("FN consume(value_input: String) RETURNS String ->")
      expect(clear).to include("MUTABLE value = COPY value_input;")
      expect(clear).not_to include("FN consume!")
    end

    it "uses optional fallback for ||= on nilable non-booleans" do
      ruby_code = <<~RUBY
        sig { params(fallback: String).returns(String) }
        def choose(fallback)
          value = T.let(nil, T.nilable(String))
          value ||= fallback
          T.must(value)
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code, raise_on_error: true)
      expect(clear).to include("value = (value OR_ELSE fallback);")
      expect(clear).not_to include("value = (value || fallback)")
    end

    it "does not leak branch-local declarations into the outer CLEAR scope" do
      ruby_code = <<~RUBY
        class Left < T::Struct
        end
        class Right < T::Struct
        end
        Value = T.type_alias { T.any(Left, Right) }
        sig { params(flag: T::Boolean).returns(Value) }
        def choose(flag)
          if flag
            value = T.let(Left.new, Value)
            return value
          end
          value = T.let(Right.new, Value)
          value
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code, raise_on_error: true)
      expect(clear.scan("MUTABLE value: Value =").length).to eq(2)
      expect(clear).not_to include("\n  value = Value{ Right:")
    end

    it "narrows union payloads in Ruby case arms" do
      ruby_code = <<~RUBY
        Left = Struct.new(:name)
        Right = Struct.new(:name)
        Value = T.type_alias { T.any(Left, Right) }
        sig { params(value: Value).returns(String) }
        def name_of(value)
          case value
          when Left
            value.name
          when Right
            value.name
          end
          "done"
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code, raise_on_error: true)
      expect(clear).to include("IF value IS_A Left AS left THEN")
      expect(clear).to include("ELSE_IF value IS_A Right AS right THEN")
    end

    it "emits module type aliases with their flattened reference names" do
      ruby_code = <<~RUBY
        module AST
          Value = T.type_alias { T.any(String, Symbol) }
          Entry = Struct.new(:value) do
            sig { returns(Value) }
            def value = self[:value]
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code, raise_on_error: true)
      expect(clear).to include("UNION Value { StringValue: String, SymbolValue: String@symbol }")
      expect(clear).to include("value: Value")
      expect(clear).not_to include("UNION ASTValue")
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
        FN typeShape__from_core(core_str: String, auto: Bool = FALSE) RETURNS String ->
          RETURN COPY core_str;
        END
        MUTABLE flag = TRUE;
        typeShape__from_core("Int64", flag);
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
        FN configure(a: Auto = 1, b: Auto = 2, c: Auto = 3) RETURNS Auto ->
          RETURN COPY c;
        END
        configure(1, 2, 4);
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers unmapped keyword calls to a final hash argument" do
      expect_transpile(
        "error!(token, :CODE, value: current.value, type: current.type)",
        "error_mut(token(), :CODE, {:value: current().value(), :type: current().type()});"
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

        FN type__initialize(MUTABLE self: Type, raw_input: Auto, ownership: Auto = NIL, sync_value: Auto = NIL) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {

        }
        END
        FN type__new(raw_input: Auto, ownership: Auto = NIL, sync: Auto = NIL) RETURNS Type@multiowned ->
          MUTABLE self = Type{};
          type__initialize(&self, raw_input, ownership, sync);
          RETURN self @multiowned;
        END
        type__new(:Int64, NIL, :atomic);
        type__new(:String);
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "unwraps optional values passed to required struct fields" do
      ruby_code = <<~RUBY
        class Token < T::Struct
        end
        class Holder < T::Struct
          const :token, Token
        end
        Value = T.type_alias { T.any(String, Integer) }
        class LabelHolder < T::Struct
          const :label, String
        end
        Payload = T.type_alias { T.any(String, Symbol) }
        class PayloadBox < T::Struct
          const :payload, Payload
        end

        sig { returns(T.nilable(Token)) }
        def maybe_token
          Token.new
        end

        sig { returns(Holder) }
        def build_holder
          Holder.new(token: maybe_token)
        end

        sig { returns(T.nilable(Value)) }
        def maybe_value
          "label"
        end

        sig { returns(LabelHolder) }
        def build_label_holder
          LabelHolder.new(label: maybe_value)
        end

        sig { params(box: T.nilable(PayloadBox)).returns(LabelHolder) }
        def label_from_box(box)
          LabelHolder.new(label: box&.payload)
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN Holder{ token: UNWRAP (COPY maybe_token()) };")
      expect(clear).to include("LabelHolder{ label: castOptionalValueToString(COPY maybe_value()) }")
      expect(clear).to include("FN castOptionalValueToString(value: ?Value) RETURNS String ->")
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

    it "preserves array constraints on otherwise untyped lambda parameters" do
      ruby_code = <<~RUBY
        rule = lambda do |args|
          args[0]
        end
      RUBY
      expected_clear = <<~CLEAR
        MUTABLE rule = %(args: []Any) -> args[0];
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "resolves constant class calls before colliding instance methods" do
      ruby_code = <<~RUBY
        class Predicate
          sig { params(value: Symbol).returns(T::Boolean) }
          def self.active?(value)
            value == :active
          end
        end

        class OtherPredicate
          sig { params(value: Symbol).returns(T::Boolean) }
          def self.active?(value)
            false
          end
        end

        class Check
          sig { params(value: Symbol).returns(T::Boolean) }
          def active?(value)
            Predicate.active?(value)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN predicate__active?(value);")
      expect(clear).not_to include("check__active?(Predicate, value)")
    end

    it "types inferred scalar constants so repeated reads remain copyable" do
      ruby_code = <<~RUBY
        FIRST_ID = 11

        sig { returns(Integer) }
        def reset
          current = FIRST_ID
          FIRST_ID
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE current = 11;")
      expect(clear).to include("MUTABLE current = 11;")
      expect(clear).to include("RETURN 11;")
    end

    it "lowers returning case arms with setup statements to statement control flow" do
      ruby_code = <<~RUBY
        sig { params(kind: Symbol, value: T.nilable(Integer)).returns(T::Boolean) }
        def active(kind, value)
          case kind
          when :check
            current = value
            current ? current > 0 : false
          else
            false
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF (kind == :check) THEN")
      expect(clear).to include("MUTABLE current: ?Int64 = value;")
      expect(clear).not_to include("RETURN PARTIAL MATCH")
    end

    it "captures self for instance-method calls inside lambdas" do
      ruby_code = <<~RUBY
        class Parser
          def current
            1
          end

          def parse
            consume do
              current
            end
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN consume(%() USE(rtoc_self_view) -> parser__current(rtoc_self_view));")
    end

    it "captures mutable self for mutating instance calls inside lambdas" do
      ruby_code = <<~RUBY
        class Parser
          def advance
            @pos = 1
          end

          def parse
            consume do
              advance
            end
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN consume(%() USE(MUTABLE rtoc_self_view) -> parser__advance(&rtoc_self_view));")
    end

    it "captures referenced enclosing parameters inside lambdas" do
      ruby_code = <<~RUBY
        class Parser
          def parse(as_param)
            consume do
              as_param ? current : fallback
            end
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("consume(%() USE(as_param) ->")
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

    it "flattens module singleton storage into shared CLEAR variables" do
      ruby_code = <<~RUBY
        module Registry
          @next_id = T.let(1, Integer)

          def self.take
            value = @next_id
            @next_id += 1
            value
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        # Ruby module Registry
        MUTABLE next_id: Int64 = 1;
        FN registry__take() RETURNS Auto ->
          MUTABLE value = COPY next_id;
          next_id = (next_id + 1);
          RETURN value;
        END
        # End Ruby module Registry
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

        MUTABLE gradual_mode_value: ?Bool = FALSE;
        FN parser__initialize(MUTABLE self: Parser) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.value = 1;
        }
        END
        FN parser__gradual_mode() RETURNS Auto ->
          RETURN COPY gradual_mode_value;
        END
        FN parser__set_gradual_mode(value: Auto) RETURNS Auto ->
          gradual_mode_value = COPY value;
          RETURN COPY value;
        END
        FN parser__new() RETURNS Parser@multiowned ->
          MUTABLE self = Parser{ value: 1 };
          parser__initialize(&self);
          RETURN self @multiowned;
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
        FN parser__rule(name: Auto) RETURNS Auto ->
          RETURN Rule{ name: COPY name };
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

    it "types transform_values's block parameter as the bare Hash value, not a [key, value] pair" do
      # Most Hash block methods (each, each_pair, select, map, ...) yield a
      # [key, value] pair; transform_values/each_value and transform_keys/
      # each_key are the exceptions - they yield a single, bare value or
      # key. block_parameter_types previously ignored which method was
      # being called and always built a Tuple<Key, Value> block-parameter
      # type, which broke the moment that parameter was iterated/mapped as
      # if it held its own real (array) shape: `Cannot SELECT from non-
      # list type Tuple<...>` was a real corpus symptom (annotator/helpers/
      # function_signature.rb's `generic_bounds.transform_values { |bounds|
      # bounds.map { ... } }`, 57 files sharing this one root cause).
      ruby_code = <<~RUBY
        sig { params(h: T::Hash[Symbol, T::Array[Integer]]).returns(T::Hash[Symbol, T::Array[Integer]]) }
        def transform(h)
          h.transform_values { |bounds| bounds.map { |b| b + 1 } }
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("bounds: []Int64")
      expect(clear).not_to include("Tuple<")
      expect(clear).to include("bounds |> SELECT (_ + 1)")
    end

    it "types transform_keys's block parameter as the bare Hash key, not a [key, value] pair" do
      ruby_code = <<~RUBY
        sig { params(h: T::Hash[Symbol, Integer]).returns(T::Hash[String, Integer]) }
        def rename(h)
          h.transform_keys { |k| k.to_s }
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("k: String@symbol")
      expect(clear).not_to include("Tuple<")
    end

    it "lowers non-local returns from each_value to explicit CLEAR iteration" do
      ruby_code = <<~RUBY
        extend T::Sig
        sig { params(values: T::Hash[String, Integer]).returns(T.nilable(Integer)) }
        def first_positive(values)
          values.each_value do |value|
            return value if value > 0
          end
          nil
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to match(/FOR rtoc_each_item_\d+ IN values\.values\(\) DO/)
      # each_value's block parameter is the bare Hash value (Int64 here,
      # a primitive) - block_parameter_types previously mistyped it as
      # Tuple<String,Int64> (the [key, value] pair shape correct for
      # each/each_pair but not each_value/transform_values), which made
      # this COPY look load-bearing when it was really just redundant
      # copying of an already-trivially-Copy primitive.
      expect(clear).to match(/RETURN rtoc_each_item_\d+;/)
      expect(clear).not_to include("unsupportedRuby")
    end

    it "uses imported zero-argument initializer metadata" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "worker.rb"), <<~RUBY)
          class Worker
            def initialize
              @ready = false
            end
          end
        RUBY
        source_path = File.join(dir, "runner.rb")
        File.write(source_path, "require_relative './worker'\nWorker.new\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq(<<~CLEAR.strip)
          REQUIRE "worker.clear"
          worker__new();
        CLEAR
      end
    end

    it "fills omitted trailing Struct.new members with nil" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ast.rb"), "module AST\n  Triple = Struct.new(:left, :right, :extra)\nend\n")
        source_path = File.join(dir, "parser.rb")
        File.write(source_path, "require_relative './ast'\nAST::Triple.new(1, 2)\n")

        expect(RubyToClear.transpile_file(source_path)).to include("Triple{ left: 1, right: 2, extra: NIL }")
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

    it "resolves a constructor's keyword arguments across files with no require_relative (relies on load order)" do
      Dir.mktmpdir do |tmp|
        # Nest under a "ruby" root so the ancestor-dir search bounds to this
        # directory (metadata_source_ancestor_dirs' ruby_root cutoff) instead
        # of falling back to its first-3-ancestors default and climbing out
        # into the real filesystem above the tmpdir.
        dir = File.join(tmp, "ruby")
        Dir.mkdir(dir)
        File.write(File.join(dir, "fixable_error.rb"), <<~RUBY)
          class Edit
            def initialize(span:, replacement:)
              @span = span
              @replacement = replacement
            end
          end
        RUBY
        source_path = File.join(dir, "state.rb")
        File.write(source_path, "Edit.new(span: 1, replacement: \"x\")\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq(<<~CLEAR.strip)
          REQUIRE "fixable_error.clear"
          edit__new(1, "x");
        CLEAR
      end
    end

    it "does not guess a constructor's cross-file location when the class name is declared in more than one file" do
      Dir.mktmpdir do |tmp|
        # Nest under a "ruby" root so the ancestor-dir search bounds to this
        # directory (metadata_source_ancestor_dirs' ruby_root cutoff) instead
        # of falling back to its first-3-ancestors default and climbing out
        # into the real filesystem above the tmpdir.
        dir = File.join(tmp, "ruby")
        Dir.mkdir(dir)
        File.write(File.join(dir, "a.rb"), "class Edit\n  def initialize(span:, replacement:)\n  end\nend\n")
        Dir.mkdir(File.join(dir, "sub"))
        File.write(File.join(dir, "sub", "b.rb"), "class Edit\n  def initialize(span:, replacement:)\n  end\nend\n")
        source_path = File.join(dir, "state.rb")
        File.write(source_path, "Edit.new(span: 1, replacement: \"x\")\n")

        expect { RubyToClear.transpile_file(source_path) }.to raise_error(
          RubyToClear::Transpiler::TranspilationError, /Keyword arguments are not supported for this constructor/
        )
      end
    end

    it "renders imported struct defaults after local constructor metadata is available" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "item.rb"), <<~RUBY)
          class Item < T::Struct
            const :name, String
            const :options, Options, default: Options.new(kind: :affine)
          end
        RUBY
        source_path = File.join(dir, "runner.rb")
        File.write(source_path, <<~RUBY)
          require_relative './item'

          class Options
            def initialize(kind: nil)
              @kind = kind
            end
          end

          Item.new(name: "value")
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include("Item{ name: \"value\", options: options__new(:affine) }")
        expect(clear).not_to include("unsupportedRuby")
      end
    end

    it "expands required mixins and emits their signature unions in the including file" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ast.rb"), "module AST\nend\n")
        File.write(File.join(dir, "helper.rb"), <<~RUBY)
          require_relative './ast'
          module Helper
            sig { params(node: AST::Node, code_or_message: T.any(String, Symbol)).returns(String) }
            def describe(node, code_or_message)
              "ok"
            end
          end
        RUBY
        source_path = File.join(dir, "parser.rb")
        File.write(source_path, <<~RUBY)
          require_relative './helper'
          Parser = Struct.new(:flag) do
            include Helper
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include("UNION CodeOrMessage { StringValue: String, SymbolValue: String@symbol }")
        expect(clear).to include("FN parser__describe(self: Parser, node: Node, code_or_message: CodeOrMessage) RETURNS String ->")
        expect(clear).not_to include("UNION Node")
      end
    end

    it "uses imported interface variants to wrap constructor fields" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "mir.rb"), <<~RUBY)
          module MIR
            module Emittable
            end
            module Expr
              include Emittable
            end
            Call = Struct.new(:name) do
              include Expr
            end
            Holder = Struct.new(:expr) do
              sig { returns(Emittable) }
              def expr
                self[:expr]
              end
            end
            Body = T.type_alias { T.any(Emittable, T::Array[Emittable]) }
            DeferHolder = Struct.new(:body) do
              sig { returns(Body) }
              def body
                self[:body]
              end
            end
          end
        RUBY
        source_path = File.join(dir, "lowerer.rb")
        File.write(source_path, <<~RUBY)
          require_relative './mir'
          sig { params(name: String).returns(MIR::Holder) }
          def build(name)
            MIR::Holder.new(MIR::Call.new(name))
          end
          sig { params(name: String).returns(MIR::DeferHolder) }
          def build_defer(name)
            MIR::DeferHolder.new(MIR::Call.new(name))
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include("Holder{ expr: Emittable{ Call: COPY Call{ name: COPY name } } }")
        expect(clear).to include("Body{ Emittable: COPY CAST(COPY Call{ name: COPY name } AS Emittable) }")
        expect(clear).not_to include("Body{ Call:")
        expect(clear).not_to include("UNION Emittable")
      end
    end

    it "mangles local types that collide with imported dependency types" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "upstream.rb"), <<~RUBY)
          module Upstream
            Node = Struct.new(:name)
          end
        RUBY
        source_path = File.join(dir, "consumer.rb")
        File.write(source_path, <<~RUBY)
          require_relative './upstream'
          module Consumer
            Node = Struct.new(:value)
            sig { params(value: Integer).returns(Consumer::Node) }
            def self.local(value)
              Node.new(value)
            end
            sig { params(name: String).returns(Upstream::Node) }
            def self.imported(name)
              Upstream::Node.new(name)
            end
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include("STRUCT ConsumerNode")
        expect(clear).to include("RETURNS ConsumerNode")
        expect(clear).to include("RETURN ConsumerNode{ value: COPY value }")
        expect(clear).to include("RETURN Node{ name: COPY name }")
      end
    end

    it "preserves mangled type names across transitive dependencies" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ast.rb"), <<~RUBY)
          module AST
            Node = Struct.new(:name)
          end
        RUBY
        File.write(File.join(dir, "mir.rb"), <<~RUBY)
          require_relative './ast'
          module MIR
            Node = Struct.new(:value)
          end
        RUBY
        source_path = File.join(dir, "consumer.rb")
        File.write(source_path, <<~RUBY)
          require_relative './mir'
          sig { params(value: Integer).returns(MIR::Node) }
          def build(value)
            MIR::Node.new(value)
          end
        RUBY

        middle = RubyToClear.transpile_file(File.join(dir, "mir.rb"))
        clear = RubyToClear.transpile_file(source_path)
        expect(middle).to include("STRUCT MIRNode")
        expect(clear).to include("RETURNS MIRNode")
        expect(clear).to include("RETURN MIRNode{ value: COPY value }")
      end
    end

    it "uses require_relative T::Struct field types for field readers" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "type.rb"), <<~RUBY)
          class FunctionType < T::Struct
            const :source_signature, T.nilable(BasicObject), default: nil
          end

          class Box
            sig { returns(T.nilable(FunctionType)) }
            def function_type
              FunctionType.new
            end
          end
        RUBY
        source_path = File.join(dir, "function_signature.rb")
        File.write(source_path, <<~RUBY)
          require_relative './type'

          sig { params(box: Box).returns(T.untyped) }
          def source_signature(box)
            function_type = box.function_type
            return nil unless function_type

            function_type.source_signature
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include("MUTABLE function_type: ?FunctionType = box__function_type(box);")
        expect(clear).to include("RETURN KEEP function_type_value.source_signature;")
        expect(clear).not_to include("source_signature()")
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

    it "emits deterministic package boundaries for modular dependencies" do
      Dir.mktmpdir do |dir|
        source_root = File.join(dir, "compiler", "ruby")
        FileUtils.mkdir_p(source_root)
        File.write(File.join(source_root, "parser_rules.rb"), "class Rule < T::Struct\n  const :name, Symbol\nend\n")
        source_path = File.join(source_root, "parser.rb")
        File.write(source_path, "require_relative './parser_rules'\nclass Parser\nend\n")
        config = RubyToClear::HelperConfig.new("modular_dependency_root" => "compiler/ruby")
        package = RubyToClear::HelperConfig.dependency_package_name("parser_rules.clear")

        expect(RubyToClear.transpile_file(source_path, helper_config: config).strip).to eq(<<~CLEAR.strip)
          REQUIRE "pkg:#{package}" AS parser_rules
        CLEAR
      end
    end

    it "emits dependencies for types referenced only by Sorbet signatures" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "type.rb"), <<~RUBY)
          class Type
            sig { returns(T::Boolean) }
            def primitive?
              true
            end
          end
        RUBY
        source_path = File.join(dir, "classifier.rb")
        File.write(source_path, <<~RUBY)
          sig { params(type: Type).returns(T::Boolean) }
          def classify(type)
            type.primitive?
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include('REQUIRE "type.clear"')
        expect(clear).to include("primitive?(type);")
        expect(clear).not_to include("type.primitive?()")
      end
    end

    it "preserves storage fields from no-expand mixins" do
      ruby_code = <<~RUBY
        # ruby-to-clear: no-expand
        module Locatable
          sig { returns(T.nilable(String)) }
          def matched_signature
            @matched_signature = T.let(@matched_signature, T.nilable(String))
          end
        end

        Node = Struct.new(:token) do
          include Locatable
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("STRUCT Node {\n  token: Token,\n  matched_signature: ?String\n}")
      expect(clear).not_to include("FN matched_signature(")
    end

    it "uses the singleton-method prefix for the generated Locatable walker" do
      ruby_code = <<~RUBY
        module AST
          module Locatable; end

          Node = Struct.new(:child) do
            include Locatable
          end

          def self.each_locatable(root, descend_functions: false, &visitor)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("PUB FN aST__each_locatable(")
      expect(clear).to include("MUTABLE descend_functions: Bool")
      expect(clear).to include("aST__each_locatable(rtoc_walk_child, &descend_functions, visitor);")
      expect(clear).not_to include("PUB FN each_locatable(")
    end

    it "exports explicitly marked singleton APIs from data-only modules" do
      ruby_code = <<~RUBY
        # ruby-to-clear: data-only
        module AST
          # ruby-to-clear: data-api
          sig { params(node: Node).returns(T.nilable(Identifier)) }
          def self.root_identifier(node)
            node
          end

          def self.host_only(node)
            node
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN aST__root_identifier(")
      expect(clear).not_to include("host_only")
    end

    it "uses metadata from no-require require_relative calls without emitting CLEAR requires" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ast.rb"), "module AST\n  Pair = Struct.new(:left, :right, keyword_init: true)\nend\n")
        source_path = File.join(dir, "parser.rb")
        File.write(source_path, "require_relative './ast' # ruby-to-clear: no-require\nAST::Pair.new(left: 1, right: 2)\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq("Pair{ left: 1, right: 2 };")
      end
    end

    it "does not infer generated dependencies from skipped Ruby-only declarations" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lsp"))
        File.write(File.join(dir, "lsp", "logger.rb"), "class Logger; end\n")
        source_path = File.join(dir, "main.rb")
        File.write(source_path, <<~RUBY)
          # ruby-to-clear: skip
          $logger = T.let(Logger.new, Logger)

          sig { params(value: String).returns(String) }
          def identity(value)
            value
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).not_to include("lsp/logger.clear")
        expect(clear).to include("FN identity(")
      end
    end

    it "propagates constructor raises nested inside iterator blocks" do
      ruby_code = <<~RUBY
        class CheckedSet
          sig { params(values: T::Array[Symbol]).void }
          def initialize(values)
            values.each { |value| raise "bad" if value == :bad }
          end

          sig { returns(CheckedSet) }
          def self.empty
            new([])
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN checkedSet__empty() RETURNS !CheckedSet@multiowned")
      expect(clear).to include("RETURN TRY (checkedSet__new(")
    end

    it "does not redeclare structs for imported class extensions" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "signature.rb"), <<~RUBY)
          class Signature
            def initialize(facts)
              @facts = facts
            end
          end
        RUBY
        source_path = File.join(dir, "signature_returns.rb")
        File.write(source_path, <<~RUBY)
          require_relative './signature'

          class Signature
            def facts_value
              @facts
            end
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include('REQUIRE "signature.clear"')
        expect(clear).to include("FN signature__facts_value(self: Signature) RETURNS Auto")
        expect(clear).not_to include("STRUCT Signature")
      end
    end

    it "does not redeclare imported Struct.new constants when reopening them" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "field.rb"), "Field = Struct.new(:name)\n")
        source_path = File.join(dir, "field_extension.rb")
        File.write(source_path, <<~RUBY)
          require_relative "./field"

          class Field
            def name_string
              name.to_s
            end
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include('REQUIRE "field.clear"')
        expect(clear).to include("FN field__name_string(self: Field) RETURNS Auto ->")
        expect(clear).not_to include("STRUCT Field")
      end
    end

    it "preserves imported field types when reopening classes with field reads" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "signature.rb"), <<~RUBY)
          class Signature
            class Facts < T::Struct
              prop :return_def, BasicObject, default: nil
            end

            sig { params(facts: Facts).void }
            def initialize(facts)
              @facts = T.let(facts, Facts)
            end
          end
        RUBY
        source_path = File.join(dir, "signature_returns.rb")
        File.write(source_path, <<~RUBY)
          require_relative './signature'

          class Signature
            def return_def
              @facts.return_def
            end
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include("RETURN KEEP rtoc_self_view.facts.return_def;")
        expect(clear).not_to include("return_def()")
        expect(clear).not_to include("STRUCT Signature")
      end
    end

    it "uses imported Struct.new block methods before same-named fields" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ast.rb"), <<~RUBY)
          module AST
            Identifier = Struct.new(:name) do
              extend T::Sig

              sig { returns(String) }
              def name
                self[:name].to_s
              end
            end
          end
        RUBY
        source_path = File.join(dir, "function_signature.rb")
        File.write(source_path, <<~RUBY)
          require_relative './ast' # ruby-to-clear: no-require

          Item = T.type_alias { T.any(String, AST::Identifier) }

          sig { params(item: Item).returns(String) }
          def read_name(item)
            if item.is_a?(AST::Identifier)
              item.name
            else
              item
            end
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include("IF item IS_A Identifier AS identifier THEN")
        expect(clear).to include("name(identifier);")
        expect(clear).not_to include("identifier.name;")
      end
    end

    it "uses prefixed calls for duplicate imported Struct.new methods" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ast.rb"), <<~RUBY)
          module AST
            Identifier = Struct.new(:name) do
              def name = self[:name].to_s
            end
            FuncCall = Struct.new(:name) do
              def name = self[:name].to_s
            end
          end
        RUBY
        source_path = File.join(dir, "parser.rb")
        File.write(source_path, <<~RUBY)
          require_relative './ast'
          sig { params(identifier: AST::Identifier).returns(String) }
          def read_name(identifier)
            identifier.name
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        # A Struct.new reader with a same-named field lowers to direct
        # field access — no disambiguating wrapper call is needed.
        expect(clear).to include("RETURN identifier.name;")
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
          schemas__struct?(NIL);
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
        expect(clear).to include("UNION SchemasUnionSchemaVariantValue { TypeMultiowned: Type@multiowned, SymbolValue: String@symbol, StringValue: String, InlineStructVariantMultiowned: InlineStructVariant@multiowned }")
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
        expect(clear).to include("castSchemasUnionSchemaVariantValueToOptionalTypeTypeInput(value_value)")
        expect(clear).to include("FN castSchemasUnionSchemaVariantValueToOptionalTypeTypeInput(value: SchemasUnionSchemaVariantValue) RETURNS ?TypeTypeInput ->")
        expect(clear).to include("PARTIAL MATCH value START")
        expect(clear).not_to include("value IS_A TypeTypeInput")
      end
    end

    it "references an imported AST Node union without redeclaring it" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ast.rb"), <<~RUBY)
          module AST
            class Left < T::Struct
            end
            class Right < T::Struct
            end
            Node = T.type_alias { T.any(Left, Right) }
            ReturnValue = T.type_alias { T.any(String, Symbol) }
          end
        RUBY
        source_path = File.join(dir, "parser.rb")
        File.write(source_path, <<~RUBY)
          require_relative "./ast"

          sig { params(node: AST::Node).returns(AST::Node) }
          def keep(node)
            node
          end

          sig { returns(T.any(Integer, Float)) }
          def choose
            1
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include('REQUIRE "ast.clear"')
        expect(clear).to include("FN keep(node: Node) RETURNS Node")
        expect(clear).not_to include("UNION Node")
        expect(clear).to include("UNION LocalReturnValue")
        expect(clear).not_to match(/^UNION ReturnValue /)
      end
    end

    it "casts a generated union to a generated subset union" do
      ruby_code = <<~RUBY
        Source = T.type_alias { T.nilable(T.any(String, Symbol, Integer)) }
        Target = T.type_alias { T.any(String, Symbol) }

        sig { params(value: Source).returns(Target) }
        def narrow(value)
          T.cast(value, Target)
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("castOptionalSourceToTarget(value)")
      expect(clear).to include("PARTIAL MATCH value? START")
      expect(clear).to include("Source.StringValue AS cast_payload -> RETURN Target{ StringValue: COPY cast_payload }")
      expect(clear).to include("Source.SymbolValue AS cast_payload -> RETURN Target{ SymbolValue: COPY cast_payload }")
      expect(clear).to include('DEFAULT -> panic("Invalid cast to Target");')
    end

    it "keeps arrays of hashes array-shaped after runtime narrowing" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.any(T::Hash[String, Integer], T::Array[T::Hash[String, Integer]]) }

        sig { params(value: Value).returns(Integer) }
        def size(value)
          return value.length if value.is_a?(Array)
          0
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF value IS_A []{String}Int64 AS array THEN")
      expect(clear).to include("RETURN array.length()")
    end

    it "copies borrowed collection locals when returning them" do
      ruby_code = <<~RUBY
        sig { returns(T::Hash[String, Integer]) }
        def cached
          values = T.let({}, T::Hash[String, Integer])
          return values
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN values;")
    end

    it "panics instead of returning NIL for failed non-optional nested union casts" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "type.rb"), <<~RUBY)
          class Type
            TypeInput = T.type_alias { T.any(Type, Symbol, String) }
          end
        RUBY
        File.write(File.join(dir, "schemas.rb"), <<~RUBY)
          require_relative './type'

          module Schemas
            class InlineStructVariant
            end

            class UnionSchema
              VariantValue = T.type_alias { T.any(Type::TypeInput, Schemas::InlineStructVariant) }
            end
          end
        RUBY
        source_path = File.join(dir, "coerce.rb")
        File.write(source_path, <<~RUBY)
          require_relative './schemas'

          sig { params(value: Schemas::UnionSchema::VariantValue).returns(Type::TypeInput) }
          def cast_variant(value)
            T.cast(value, Type::TypeInput)
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include("FN castSchemasUnionSchemaVariantValueToTypeTypeInput(value: SchemasUnionSchemaVariantValue) RETURNS TypeTypeInput ->")
        expect(clear).to include('panic("Invalid cast to TypeTypeInput")')
        expect(clear).not_to include("RETURN NIL;")
      end
    end

    it "upgrades ownership when a setter returns its plain argument into a multiowned type" do
      ruby_code = <<~RUBY
        class SymbolEntry
        end

        class ScopeBindings
          sig { void }
          def initialize
            @entries = T.let({}, T::Hash[String, SymbolEntry])
          end

          sig { params(name: String, entry: SymbolEntry).returns(SymbolEntry) }
          def []=(name, entry)
            @entries[name] = entry
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURNS SymbolEntry@multiowned")
      expect(clear).to match(/MUTABLE rtoc_owned_return_\d+: SymbolEntry@multiowned = entry;\n\s*RETURN rtoc_owned_return_\d+;/)
      expect(clear).to include("rtoc_self_view.entries[name] = entry;")
    end

    it "retains an already-multiowned borrowed read returned out of a function" do
      ruby_code = <<~RUBY
        class SymbolEntry
        end

        class ScopeBindings
          sig { void }
          def initialize
            @entries = T.let({}, T::Hash[String, SymbolEntry])
          end

          sig { params(name: String).returns(T.nilable(SymbolEntry)) }
          def [](name)
            @entries[name]
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN KEEP rtoc_self_view.entries[name];")
    end

    it "assigns through a statement MATCH when a case arm jumps instead of yielding a value" do
      ruby_code = <<~RUBY
        class Dims
          sig { params(dim: T.nilable(Symbol), a: Symbol, b: Symbol).returns(T.nilable(Symbol)) }
          def pick(dim, a, b)
            current = case dim
            when :ownership then a
            when :sync then b
            else return nil
            end
            current
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE current_branch_value: ?String@symbol = NIL;")
      expect(clear).to include("current_branch_value = COPY a;")
      expect(clear).to include("DEFAULT ->\n      RETURN NIL;")
      expect(clear).to include("MUTABLE current: String@symbol = current_branch_value?;")
      expect(clear).not_to include("MUTABLE current = PARTIAL MATCH")
    end

    it "widens a nil-coalesced narrower union into a wider parameter union" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "type.rb"), <<~RUBY)
          class Type
            TypeInput = T.type_alias { T.any(Type, Symbol, String) }
            ConstructionInput = T.type_alias { T.any(TypeInput, Expr) }

            sig { params(raw_input: ConstructionInput).void }
            def initialize(raw_input)
              @raw = raw_input
            end

            sig { returns(TypeInput) }
            def self.any_input = :Any
          end

          class Expr
          end
        RUBY
        source_path = File.join(dir, "param.rb")
        File.write(source_path, <<~RUBY)
          require_relative './type'

          class Param
            sig { params(given: T.nilable(Type::TypeInput)).returns(Type) }
            def build(given)
              Type.new(given || Type.any_input)
            end
          end
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include("castTypeTypeInputToTypeConstructionInput((given OR_ELSE type__any_input()))")
      end
    end

    it "wraps nested union payloads when reassigning typed locals" do
      ruby_code = <<~RUBY
        class Type
          TypeInput = T.type_alias { T.any(Type, Symbol, String) }
        end

        FieldMetadataValue = T.type_alias { T.any(Type::TypeInput, TrueClass) }
        value = T.let(nil, T.nilable(FieldMetadataValue))
        value = :Any
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("UNION TypeTypeInput { TypeMultiowned: Type@multiowned, SymbolValue: String@symbol, StringValue: String }")
      expect(clear).to include("UNION FieldMetadataValue { TypeMultiowned: Type@multiowned, SymbolValue: String@symbol, StringValue: String, BoolValue: Bool }")
      expect(clear).to include("value = FieldMetadataValue{ SymbolValue: :Any };")
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
        # An indexed read is optional in CLEAR, so a field access on one needs
      # safe navigation; `?.` is the operator for it.
      expect(clear).to include("params[rtoc_idx]?.takes;")
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
          FN signature__value_string(self: Signature) RETURNS Auto
            REQUIRES self: LOCAL
          ->
          WITH POLYMORPHIC self AS rtoc_self_view {
              RETURN COPY CAST(rtoc_self_view.value AS String);
          }
          END
        CLEAR
      end
    end

    it "uses constructor metadata from guarded require_relative calls" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "lexer.rb"), "class Lexer\n  def initialize(source)\n  end\nend\n")
        source_path = File.join(dir, "parser_spec.rb")
        File.write(source_path, "require_relative './lexer' unless defined?(Lexer)\nLexer.new(src)\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq(<<~CLEAR.strip)
          REQUIRE "lexer.clear"
          lexer__new(src());
        CLEAR
      end
    end

    it "uses imported initialize keyword metadata from require_relative calls" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "type.rb"), "class Type\n  def initialize(raw_input, ownership: nil, sync: nil)\n  end\nend\n")
        source_path = File.join(dir, "schema.rb")
        File.write(source_path, "require_relative './type' unless defined?(Type)\nType.new(:Int64, sync: :atomic)\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq(<<~CLEAR.strip)
          REQUIRE "type.clear"
          type__new(:Int64, NIL, :atomic);
        CLEAR
      end
    end

    it "emits direct constructor dependencies discovered through transitive metadata" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "type.rb"), <<~RUBY)
          class Type
            def initialize(name)
            end
          end
        RUBY
        File.write(File.join(dir, "bridge.rb"), "require_relative './type'\n")
        source_path = File.join(dir, "consumer.rb")
        File.write(source_path, "require_relative './bridge'\nType.new(name)\n")

        expect(RubyToClear.transpile_file(source_path).strip).to eq(<<~CLEAR.strip)
          REQUIRE "bridge.clear"
          REQUIRE "type.clear"
          type__new(name());
        CLEAR
      end
    end

    it "resolves aliases before bottom-loaded cyclic metadata dependencies" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "type.rb"), <<~RUBY)
          class Type
            TypeInput = T.type_alias { T.any(Type, Symbol) }

            sig { params(raw: Symbol).void }
            def initialize(raw)
              @raw = T.let(raw, Symbol)
            end
          end

          require_relative './signature'
        RUBY
        File.write(File.join(dir, "signature.rb"), <<~RUBY)
          require_relative './type'

          class Signature
            sig { params(return_type: T.nilable(Type::TypeInput)).void }
            def initialize(return_type: nil)
            end
          end
        RUBY
        source_path = File.join(dir, "use_signature.rb")
        File.write(source_path, <<~RUBY)
          require_relative './type'
          require_relative './signature'

          value = Type.new(:Int64)
          Signature.new(return_type: value)
        RUBY

        clear = RubyToClear.transpile_file(source_path)
        expect(clear).to include("signature__new(TypeTypeInput{ TypeMultiowned: COPY value });")
      end
    end

    it "keeps ownership of local storage classes across cyclic extension metadata" do
      Dir.mktmpdir do |dir|
        owner_path = File.join(dir, "owner.rb")
        File.write(owner_path, <<~RUBY)
          class Owner
            def initialize(value)
              @value = value
            end
          end
          require_relative './owner_extension' # ruby-to-clear: no-require
        RUBY
        File.write(File.join(dir, "owner_extension.rb"), <<~RUBY)
          require_relative './owner'
          class Owner
            def extra
              @value
            end
          end
        RUBY

        clear = RubyToClear.transpile_file(owner_path)
        expect(clear).to include("STRUCT Owner")
        expect(clear).to include("value: Any")
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

        FN calc__initialize(MUTABLE self: Calc, start_value: Auto) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.val = COPY start_value;
        }
        END
        FN calc__add(MUTABLE self: Calc, n: Auto) RETURNS Auto
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.val = (rtoc_self_view.val + n);
            RETURN (rtoc_self_view.val + n);
        }
        END
        FN calc__new(start: Auto) RETURNS Calc@multiowned ->
          MUTABLE self = Calc{ val: start };
          calc__initialize(&self, start);
          RETURN self @multiowned;
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
      expect(clear).to include("FN type__apply_capabilities_mut(MUTABLE self: Type, value: Auto) RETURNS Auto")
      expect(clear).to include("FN type__set_ownership(MUTABLE self: Type, value: Auto) RETURNS Auto")
      expect(clear).to include("FN type__stamp(MUTABLE self: Type, value: Auto) RETURNS Auto")
      expect(clear).to include("FN type__ownership(self: Type) RETURNS Auto")
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
      expect(clear).to include("FN type__accepts?(self: Type, other: Auto) RETURNS Auto")
      expect(clear).not_to include("FN accepts?(MUTABLE self: Type")
    end

    it "lowers self.class from the enclosing CLEAR type" do
      clear = RubyToClear.transpile(<<~RUBY)
        class Item
          def type_name
            self.class
          end
        end
      RUBY

      expect(clear).to include('"Item";')
      expect(clear).not_to include("self.class()")
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

        FN pair__equals?(self: Pair, other: Auto) RETURNS Auto
          REQUIRES self: LOCAL
          EFFECTS REENTRANT
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN (other AND (other.left() == left()));
        }
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

        FN type__inner(self: Type) RETURNS Type@multiowned
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            MUTABLE rtoc_owned_return_1: Type@multiowned = rtoc_self_view;
            RETURN rtoc_owned_return_1;
        }
        END
        FN type__fixed?(self: Type) RETURNS Bool
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN TRUE;
        }
        END
        FN type__bounded?(self: Type) RETURNS Bool
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN { MUTABLE rtoc_value_block_marker = 0; MUTABLE rtoc_local_receiver_2 = type__inner(rtoc_self_view);
            type__fixed?(rtoc_local_receiver_2) };
        }
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
        PRIVATE FN tools__helper(value: Auto) RETURNS Auto ->
          RETURN COPY value;
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
        PRIVATE FN tools__helper(value: Auto) RETURNS Auto ->
          RETURN COPY value;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "emits annotated module instance methods for standalone CLEAR modules" do
      ruby_code = <<~RUBY
        # ruby-to-clear: emit-module-methods
        module Helpers
          sig { params(value: String).returns(String) }
          def normalize(value)
            value.strip
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        # Ruby module Helpers
        FN normalize(value: String) RETURNS String ->
          RETURN value.trim();
        END
        # End Ruby module Helpers
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "does not expand skipped mixin includes" do
      ruby_code = <<~RUBY
        module Helpers
          def helper
            1
          end
        end

        class Worker
          include Helpers # ruby-to-clear: skip

          def run
            2
          end
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN worker__run(self: Worker) RETURNS Auto")
      expect(clear).not_to include("FN helper")
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
        FN tools__walk(n: Auto) RETURNS Auto EFFECTS REENTRANT ->
          IF (n == 0) THEN
            RETURN 0;
          END
          RETURN tools__walk((n - 1));
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "propagates initializer reentrancy to generated constructor wrappers" do
      ruby_code = <<~RUBY
        class Node
          # ruby-to-clear: effects reentrant
          def initialize(value)
            @value = value
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include(
        "FN node__initialize(MUTABLE self: Node, value: Auto) RETURNS Void\n" \
          "  REQUIRES self: LOCAL\n" \
          "  EFFECTS REENTRANT"
      )
      expect(clear).to include(
        "FN node__new(value: Auto) RETURNS Node@multiowned EFFECTS REENTRANT"
      )
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
        FN tools__value() RETURNS Int64 EFFECTS REENTRANT ->
          RETURN 1;
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

        FN type__accepts?(self: Type, other: Type) RETURNS Bool
          REQUIRES self: LOCAL
          EFFECTS REENTRANT
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            IF (rtoc_self_view == other) THEN
              RETURN TRUE;
            END
            RETURN type__accepts?(other, rtoc_self_view);
        }
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
        FN tools__clear_entry() RETURNS Auto ->
          RETURN 1;
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

        FN tools__helper(value: Auto) RETURNS Auto ->
          RETURN COPY value;
        END
        FN tools__run(self: Tools) RETURNS Auto
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN tools__helper(1);
        }
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
          tokens: []Token
        }

        FN lexer__initialize(MUTABLE self: Lexer, source: Auto) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.s = Scanner{ source: source, pos: 0 };
            rtoc_self_view.line = 1;
            rtoc_self_view.tokens = List[];
        }
        END
        FN lexer__new(source: Auto) RETURNS Lexer@multiowned ->
          MUTABLE self = Lexer{ line: 1, s: Scanner{ source: COPY source, pos: 0 }, tokens: List[] };
          lexer__initialize(&self, source);
          RETURN self @multiowned;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses initializer signature types for directly assigned fields" do
      ruby_code = <<~RUBY
        class Source
          sig { params(text: String, token: T.nilable(Token)).void }
          def initialize(text, token)
            @text = text
            @token = token
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Source {
          text: String,
          token: ?Token
        }

        FN source__initialize(MUTABLE self: Source, text: String, token: ?Token) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.text = COPY text;
            rtoc_self_view.token = COPY token;
        }
        END
        FN source__new(text: String, token: ?Token) RETURNS Source@multiowned ->
          MUTABLE self = Source{ text: COPY text, token: COPY token };
          source__initialize(&self, text, token);
          RETURN self @multiowned;
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
          fields: {String@symbol}String
        }

        FN inlineStructVariant__initialize(MUTABLE self: InlineStructVariant, fields: {String@symbol}String) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.fields = COPY fields;
        }
        END
        FN inlineStructVariant__new(fields: {String@symbol}String) RETURNS InlineStructVariant@multiowned ->
          MUTABLE self = InlineStructVariant{ fields: COPY fields };
          inlineStructVariant__initialize(&self, fields);
          RETURN self @multiowned;
        END
        # End Ruby module Schemas
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "preserves constructor parameter types while deriving nested field defaults" do
      ruby_code = <<~RUBY
        class IntrinsicArgSpec
          RawArgSpecEntry = T.type_alias { T.any(Symbol, String) }
          RawArgSpec = T.type_alias { T.nilable(T.any(RawArgSpecEntry, T::Array[RawArgSpecEntry])) }
        end

        class Facts < T::Struct
          prop :fixed, T::Boolean, default: false
        end

        class Signature
          sig { params(arg_spec: IntrinsicArgSpec::RawArgSpec).void }
          def initialize(arg_spec: nil)
            @facts = T.let(Facts.new(fixed: arg_spec.is_a?(Array)), Facts)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION IntrinsicArgSpecRawArgSpecEntry { SymbolValue: String@symbol, StringValue: String }
        UNION IntrinsicArgSpecRawArgSpec { SymbolValue: String@symbol, StringValue: String, ArrayValue: []IntrinsicArgSpecRawArgSpecEntry }
        STRUCT Facts {
          fixed: Bool
        }
        STRUCT Signature {
          facts: Facts
        }

        FN signature__initialize(MUTABLE self: Signature, arg_spec: ?IntrinsicArgSpecRawArgSpec = NIL) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.facts = Facts{ fixed: ((arg_spec != NIL) AND (arg_spec IS_A []IntrinsicArgSpecRawArgSpecEntry)) };
        }
        END
        FN signature__new(arg_spec: ?IntrinsicArgSpecRawArgSpec = NIL) RETURNS Signature@multiowned ->
          MUTABLE self = Signature{ facts: Facts{ fixed: (((COPY arg_spec) != NIL) AND ((COPY arg_spec) IS_A []IntrinsicArgSpecRawArgSpecEntry)) } };
          signature__initialize(&self, arg_spec);
          RETURN self @multiowned;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "keeps identity for initializer params inside nested @multiowned constructor placeholder fields" do
      ruby_code = <<~RUBY
        class Facts < T::Struct
          prop :return_def, BasicObject, default: nil
        end

        class Signature
          sig { params(return_def: BasicObject).void }
          def initialize(return_def: nil)
            @facts = T.let(Facts.new(return_def: return_def), Facts)
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Facts {
          return_def: Any@multiowned
        }
        STRUCT Signature {
          facts: Facts
        }

        FN signature__initialize(MUTABLE self: Signature, return_def: Any = NIL) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.facts = Facts{ return_def: return_def };
        }
        END
        FN signature__new(return_def: Any = NIL) RETURNS Signature@multiowned ->
          MUTABLE self = Signature{ facts: Facts{ return_def: return_def } };
          signature__initialize(&self, return_def);
          RETURN self @multiowned;
        END
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
          static_methods: {String}{String@symbol}SchemasResourceSchemaStaticMethodValue
        }

        UNION SchemasResourceSchemaStaticMethodValue { ArrayValue: []String@symbol, SymbolValue: String@symbol, StringValue: String, BoolValue: Bool }
        FN resourceSchema__initialize(MUTABLE self: ResourceSchema, static_methods: {String}{String@symbol}SchemasResourceSchemaStaticMethodValue) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.static_methods = COPY static_methods;
        }
        END
        FN resourceSchema__new(static_methods: {String}{String@symbol}SchemasResourceSchemaStaticMethodValue) RETURNS ResourceSchema@multiowned ->
          MUTABLE self = ResourceSchema{ static_methods: COPY static_methods };
          resourceSchema__initialize(&self, static_methods);
          RETURN self @multiowned;
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

        FN zigType__initialize(MUTABLE self: ZigType, source: String) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.source = COPY source;
        }
        END
        FN zigType__new(source: String) RETURNS ZigType@multiowned ->
          MUTABLE self = ZigType{ source: COPY source };
          zigType__initialize(&self, source);
          RETURN self @multiowned;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "copies optional custom-type parameters stored directly in instance fields" do
      ruby_code = <<~RUBY
        class Box
          sig { params(value: T.nilable(Payload)).void }
          def initialize(value)
            @value = T.let(value, T.nilable(Payload))
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Box {
          value: ?Payload
        }

        FN box__initialize(MUTABLE self: Box, value: ?Payload) RETURNS Void
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {
            rtoc_self_view.value = COPY value;
        }
        END
        FN box__new(value: ?Payload) RETURNS Box@multiowned ->
          MUTABLE self = Box{ value: COPY value };
          box__initialize(&self, value);
          RETURN self @multiowned;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end
  end

  describe "method translations via registry" do
    it "transpiles map and collect" do
      ruby_code = "nums = []; nums.map { |x| x * 2 }"
      expected_clear = "MUTABLE nums = List[];\nnums |> SELECT (_ * 2);"
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles map and select with block arguments" do
      expect_transpile("nums = []; nums.map(&:to_s)", "MUTABLE nums = List[];\nnums |> SELECT _.toString();")
      expect_transpile("nums = []; nums.select(&:even?)", "MUTABLE nums = List[];\nnums |> WHERE _.even?();")
      expect_transpile('words = []; words.map(&:strip)', "MUTABLE words = List[];\nwords |> SELECT _.trim();")
      expect_transpile('words = []; words.map(&:to_sym)', "MUTABLE words = List[];\nwords |> SELECT symbol(_);")
    end

    it "transpiles select and filter" do
      ruby_code = "nums = []; nums.select { |x| x > 5 }"
      expected_clear = "MUTABLE nums = List[];\nnums |> WHERE (_ > 5);"
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles predicate collection blocks" do
      expect_transpile("nums = []; nums.reject { |x| x < 2 }", "MUTABLE nums = List[];\nnums |> WHERE !((_ < 2));")
      expect_transpile("nums = []; nums.any?", "MUTABLE nums = List[];\nnums |> ANY _;")
      expect_transpile("nums = []; nums.any? { |x| x > 5 }", "MUTABLE nums = List[];\nnums |> ANY (_ > 5);")
      expect_transpile("nums = []; nums.all?", "MUTABLE nums = List[];\nnums |> ALL _;")
      expect_transpile("nums = []; nums.all? { |x| x > 0 }", "MUTABLE nums = List[];\nnums |> ALL (_ > 0);")
      expect_transpile("items.any?(&:fatal?)", "items() |> ANY _.fatal?();")
      expect_transpile("items.count(&:fatal?)", "items() |> COUNT _.fatal?();")
      expect_transpile("nums = []; nums.find { |x| x == 3 }", "MUTABLE nums = List[];\nnums |> FIND (_ == 3);")
      expect_transpile("nums = []; nums.detect { |x| x == 3 }", "MUTABLE nums = List[];\nnums |> FIND (_ == 3);")
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
          RETURN type.any?();
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles projection collection blocks" do
      expect_transpile("nums = []; nums.collect { |x| x * 2 }", "MUTABLE nums = List[];\nnums |> SELECT (_ * 2);")
      expect_transpile("nums = []; nums.filter_map { |x| maybe(x) }", "MUTABLE nums = List[];\nnums |> SELECT:? maybe(_) |> WHERE _ != NIL;")
      expect_transpile("nums = []; nums.filter { |x| x > 2 }", "MUTABLE nums = List[];\nnums |> WHERE (_ > 2);")
      expect_transpile("groups = []; groups.flat_map { |g| g.items }", "MUTABLE groups = List[];\ngroups |> UNNEST _.items();")
      expect_transpile("items = []; items.sort_by { |item| item.name }", "MUTABLE items = List[];\nitems |> ORDER_BY _.name();")
      expect_transpile("items = []; items.sort", "MUTABLE items = List[];\nitems |> ORDER_BY _;")
    end

    it "rejects sort with a custom comparator block" do
      # No register("sort") entry existed at all before this - a bare
      # .sort (no block) fell through to a generic passthrough call, emitting
      # `receiver.sort()` and assuming an inherent method CLEAR arrays don't
      # have (real corpus: incremental/dependency_snapshot.rb's
      # `paths.map { ... }.uniq.sort.map { ... }`, "[UNKNOWN_INHERENT_METHOD]
      # Type String[] has no inherent METHOD named 'sort'").
      expect {
        RubyToClear.transpile("items = []; items.sort { |a, b| b <=> a }")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /sort with a custom comparator block is not supported/)
    end

    it "parenthesizes pipeline-valued binary operands" do
      ruby_code = "head + items.map { |item| item }.sort_by { |item| item }"
      expected_clear = "(head() + ((items() |> SELECT _) |> ORDER_BY _));"
      expect_transpile(ruby_code, expected_clear)
    end

    it "parenthesizes pipeline-valued boolean operands" do
      expect_transpile("enabled && items.any?(&:fatal?)", "(enabled() AND (items() |> ANY _.fatal?()));")
      expect_transpile("ready || items.any?(&:fatal?)", "(ready() OR (items() |> ANY _.fatal?()));")
    end

    it "projects hash key-value blocks through the key pipeline" do
      ruby_code = <<~RUBY
        sig { params(items: T::Hash[String, Integer]).returns(T::Array[[String, Integer]]) }
        def pairs(items)
          items.map { |key, value| [key, value] }
        end
      RUBY
      expected_clear = <<~CLEAR
        FN pairs(items: {String}Int64) RETURNS ![]Tuple<String, Int64> ->
          MUTABLE rtoc_tuple_return_1 = ( { MUTABLE rtoc_tuple_results = CAST([] AS []Tuple<String, Int64>); items.keys() |> EACH { &rtoc_tuple_results.append(COPY CAST(Tuple{_, (items[_] OR_ELSE CAST(panic("missing hash key") AS Int64))} AS Tuple<String, Int64>)); }; rtoc_tuple_results } );
          RETURN rtoc_tuple_return_1;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "filters typed hash keys with both block parameters" do
      ruby_code = <<~RUBY
        sig { params(items: T::Hash[Symbol, T::Hash[Symbol, Integer]], kind: Integer).returns(T::Array[Symbol]) }
        def keys_for_kind(items, kind)
          items.select { |_, metadata| metadata[:kind] == kind }.keys
        end
      RUBY
      expected_clear = <<~CLEAR
        FN keys_for_kind(items: {String@symbol}{String@symbol}Int64, kind: Int64) RETURNS ![]String@symbol ->
          RETURN items.keys() |> WHERE ((items[_] OR_ELSE CAST(panic("missing hash key") AS {String@symbol}Int64))[:kind] == kind);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "copies borrowed parameters stored in typed union hashes" do
      ruby_code = <<~RUBY
        Value = T.type_alias { T.nilable(T.any(String, Symbol)) }
        sig { params(out: T::Hash[Symbol, Value], template: String).void }
        def store(out, template)
          out[:template] = template
        end
      RUBY
      expected_clear = <<~CLEAR
        UNION Value { StringValue: String, SymbolValue: String@symbol }
        FN store(MUTABLE out: {String@symbol}?Value, template: String) RETURNS Void ->
          out[:template] = Value{ StringValue: COPY template };
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "marks parameters mutated inside inline Ruby blocks as mutable" do
      ruby_code = <<~RUBY
        sig { params(seen: T::Set[String], names: T::Array[String]).void }
        def remember(seen, names)
          names.each { |name| seen << name }
        end

        seen = T.let(Set.new, T::Set[String])
        remember(seen, ["one"])
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN remember(MUTABLE seen: [Set]String, names: []String) RETURNS Void ->")
      expect(clear).to include("&seen.insert(COPY _);")
      expect(clear).to include("remember(&seen, [\"one\"]);")
    end

    it "does not mark an outer parameter mutable when a block parameter shadows it" do
      ruby_code = <<~RUBY
        sig { params(seen: T::Set[String], groups: T::Array[T::Set[String]]).returns(T::Set[String]) }
        def touch(seen, groups)
          groups.each { |seen| seen << "inside" }
          seen
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN touch(seen: [Set]String, groups: [][Set]String)")
      expect(clear).not_to include("FN touch(MUTABLE seen:")
    end

    it "wraps first assignments to explicitly typed union locals" do
      ruby_code = <<~RUBY
        class Left < T::Struct
        end
        class Right < T::Struct
        end
        Value = T.type_alias { T.any(Left, Right) }
        value = T.let(Left.new, Value)
      RUBY

      result = RubyToClear.transpile(ruby_code, raise_on_error: true)
      expect(result).to include("MUTABLE value: Value = Value{ Left: COPY Left{} }")
    end

    it "preserves Struct initializer defaults for omitted fields" do
      ruby_code = <<~RUBY
        Entry = Struct.new(:items, :enabled, keyword_init: true) do
          def initialize(**kw)
            super
            self[:items] = [] if self[:items].nil?
            self[:enabled] = false if self[:enabled].nil?
          end
        end
        entry = Entry.new
      RUBY

      result = RubyToClear.transpile(ruby_code, raise_on_error: true)
      expect(result).to include("MUTABLE entry = Entry{ items: List[], enabled: FALSE };")
    end

    it "copies indexed values stored by constructors" do
      ruby_code = <<~RUBY
        Box = Struct.new(:value)
        sig { params(items: T::Hash[String, Symbol], key: String).returns(Box) }
        def build(items, key)
          Box.new(items[key])
        end
      RUBY

      result = RubyToClear.transpile(ruby_code, raise_on_error: true)
      expect(result).to include("Box{ value: COPY items[key] }")
    end

    it "routes Ruby string percent formatting through the compiler helper" do
      config = {
        "prelude" => ["EXTERN FN compilerFormatTemplate(template: String) RETURNS String FROM \"compiler_regex\";"],
        "helpers" => { "string_format" => "compilerFormatTemplate" }
      }
      result = RubyToClear.transpile(<<~RUBY, helper_config: config)
        sig { params(template: String, values: T.untyped).returns(String) }
        def render(template, values)
          template % values
        end
      RUBY

      expect(result).to include("compilerFormatTemplate(template);")
      expect(result).not_to include("template % values")
    end

    it "routes heterogeneous inspect through the compiler helper" do
      config = {
        "prelude" => ["EXTERN FN compilerInspectValue() RETURNS String FROM \"compiler_regex\";"],
        "helpers" => { "inspect_value" => "compilerInspectValue" }
      }
      result = RubyToClear.transpile("def render(value); value.inspect; end", helper_config: config)

      expect(result).to include("compilerInspectValue();")
      expect(result).not_to include(".inspect()")
    end


    it "uses positional access for tuple first and last symbol procs" do
      ruby_code = <<~RUBY
        sig { params(items: T::Array[[String, Integer]]).returns(T::Array[[String, Integer]]) }
        def ordered(items)
          items.sort_by(&:last)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN ordered(items: []Tuple<String, Int64>) RETURNS ![]Tuple<String, Int64> ->
          RETURN items |> ORDER_BY _._1;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "projects tuple arrays with map symbol procs" do
      ruby_code = <<~RUBY
        sig { params(items: T::Array[[String, Integer]]).returns(T::Array[String]) }
        def names(items)
          items.map(&:first)
        end
      RUBY
      expected_clear = <<~CLEAR
        FN names(items: []Tuple<String, Int64>) RETURNS ![]String ->
          RETURN items |> SELECT _._0;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "preserves projected tuple types through sort_by symbol procs" do
      ruby_code = <<~RUBY
        sig { params(items: T::Array[String]).returns(T::Array[[String, Integer]]) }
        def indexed(items)
          items.map { |item| [T.cast(item, String), 1] }.sort_by(&:last)
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN (items |> SELECT CAST(Tuple{CAST(_ AS String), 1} AS Tuple<String, Int64>)) |> ORDER_BY _._1;")
      expect(clear).to include("RETURN (items |> SELECT CAST(Tuple{CAST(_ AS String), 1} AS Tuple<String, Int64>)) |> ORDER_BY _._1;")
    end

    it "retains typed hash constant shapes for method dispatch" do
      ruby_code = <<~RUBY
        ITEMS = T.let({}, T::Hash[String, Integer])

        sig { returns(T::Array[[String, Integer]]) }
        def pairs
          ITEMS.map { |key, value| [key, value] }
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE rtoc_tuple_return_1 = ( { MUTABLE rtoc_tuple_results = CAST([] AS []Tuple<String, Int64>); items.keys() |> EACH { &rtoc_tuple_results.append(COPY CAST(Tuple{_, (items[_] OR_ELSE CAST(panic(\"missing hash key\") AS Int64))} AS Tuple<String, Int64>)); }; rtoc_tuple_results } );")
      expect(clear).to include("MUTABLE rtoc_tuple_return_1 = ( { MUTABLE rtoc_tuple_results = CAST([] AS []Tuple<String, Int64>); items.keys() |> EACH { &rtoc_tuple_results.append(COPY CAST(Tuple{_, (items[_] OR_ELSE CAST(panic(\"missing hash key\") AS Int64))} AS Tuple<String, Int64>)); }; rtoc_tuple_results } );")
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
        MUTABLE items = List[];
        MUTABLE rtoc_idx = 0;
        WHILE rtoc_idx < items.length() DO
            IF (items[rtoc_idx] == NIL) THEN
              rtoc_idx = rtoc_idx + 1;
          CONTINUE;
            END
            puts(items[rtoc_idx]);
          rtoc_idx = rtoc_idx + 1;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "preserves typed struct field reads inside effect-only each blocks" do
      ruby_code = <<~RUBY
        class Rule < T::Struct
          const :type, Symbol
        end

        sig { params(rules: T::Array[Rule]).void }
        def visit_rules(rules)
          rules.each { |rule| puts rule.type }
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Rule {
          type: String@symbol
        }
        FN visit_rules(rules: []Rule) RETURNS Void ->
          FOR _ IN rules DO
          puts(_.type);
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "types heterogeneous fixed array literals as tuples" do
      ruby_code = <<~RUBY
        sig { params(type: Symbol, value: T.nilable(String)).void }
        def build_key(type, value)
          key = [type, value]
        end
      RUBY
      expected_clear = <<~CLEAR
        FN build_key(type: String@symbol, value: ?String) RETURNS Void ->
          MUTABLE key: Tuple<String@symbol, ?String> = CAST(Tuple{type, value} AS Tuple<String@symbol, ?String>);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses helper-config union metadata to narrow imported struct fields" do
      ruby_code = <<~RUBY
        sig { params(token: Token).returns(String) }
        def string_value(token)
          value = token.value
          return value if value.is_a?(String)

          ""
        end
      RUBY
      helper_config = {
        "struct_fields" => { "Token" => { "value" => "TokenValue" } },
        "unions" => { "TokenValue" => ["String", "Int64"] },
        "union_variants" => { "TokenValue" => { "String" => "Str", "Int64" => "Int" } }
      }
      expected_clear = <<~CLEAR
        FN string_value(token: Token) RETURNS String ->
          MUTABLE value = COPY token.value;
          IF value IS_A String AS string THEN
            RETURN string;
          END
          RETURN "";
        END
      CLEAR
      result = RubyToClear.transpile(ruby_code, helper_config: helper_config)
      expect(result.strip).to eq(expected_clear.strip)
    end

    it "transpiles mutating map and sum pipeline terminals" do
      ruby_code = "nums = []; nums.map! { |x| y = x + 1; y }"
      expected_clear = <<~CLEAR
        MUTABLE nums = List[];
        nums = nums |> SELECT {
          MUTABLE y = (_ + 1);
          y
        };
      CLEAR
      expect_transpile(ruby_code, expected_clear)

      expect_transpile("nums = []; nums.sum", "MUTABLE nums = List[];\nnums |> SUM _;")
      expect_transpile("items = []; items.sum { |item| item.value }", "MUTABLE items = List[];\nitems |> SUM _.value();")
    end

    it "lowers array concat through a generated typed helper" do
      ruby_code = <<~RUBY
        values = T.let([1], T::Array[Integer])
        values.concat([2])
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("values = ruby_array_concat_Int64(values, [2]);")
      expect(clear).to include("FN ruby_array_concat_Int64(left: []Int64, right: []Int64) RETURNS []Int64 ->")
    end

    it "transpiles reduce and inject" do
      ruby_code = "nums = []; nums.reduce(0) { |acc, x| acc + x }"
      expected_clear = "MUTABLE nums = List[];\nnums |> REDUCE(0) (acc + _);"
      expect_transpile(ruby_code, expected_clear)
      expect_transpile("nums = []; nums.inject(0) { |acc, x| acc + x }", "MUTABLE nums = List[];\nnums |> REDUCE(0) (acc + _);")

      ruby_code = "nums = []; nums.reduce(0) { |acc, x| next_value = acc + x; next_value }"
      expected_clear = <<~CLEAR
        MUTABLE nums = List[];
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
      expected_clear = "MUTABLE nums = List[];\nMUTABLE x = 1;\nnums.contains?(x);"
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles hash key predicates" do
      expect_transpile("table = {}; table.key?(:name); table.has_key?(:name)", <<~CLEAR)
        MUTABLE table = {};
        table.contains?(:name);
        table.contains?(:name);
      CLEAR
    end

    it "transpiles each" do
      ruby_code = "nums = []; nums.each { |x| puts x }"
      expected_clear = "MUTABLE nums = List[];\nFOR _ IN nums DO\nputs(_);\nEND"
      expect_transpile(ruby_code, expected_clear)

      ruby_code = "nums = []; nums.each { |x| puts x; audit x }"
      expected_clear = <<~CLEAR
        MUTABLE nums = List[];
        FOR _ IN nums DO
          puts(_);
          audit(_);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles receiver-transform iteration helpers" do
      expect_transpile("nums = []; nums.reverse_each { |x| puts x }", <<~CLEAR)
        MUTABLE nums = List[];
        MUTABLE rtoc_reverse_items_1: []Any = nums;
        MUTABLE rtoc_reverse_i_2 = rtoc_reverse_items_1.length() - 1;
        WHILE rtoc_reverse_i_2 >= 0 DO
          puts((rtoc_reverse_items_1[rtoc_reverse_i_2])?);
          rtoc_reverse_i_2 = rtoc_reverse_i_2 - 1;
        END
      CLEAR
      expect_transpile("map = {}; map.each_key { |key| puts key }", "MUTABLE map = {};\nFOR _ IN map.keys() DO\nputs(_);\nEND")
      expect_transpile("map = {}; map.each_value { |value| puts value }", "MUTABLE map = {};\nFOR _ IN map.values() DO\nputs(_);\nEND")
    end

    it "lowers typed hash each with key and value block parameters" do
      ruby_code = <<~RUBY
        sig { params(input: T::Hash[String, T::Array[String]]).returns(T::Hash[String, T::Array[String]]) }
        def copy_map(input)
          copied = T.let({}, T::Hash[String, T::Array[String]])
          input.each do |name, values|
            copied[name] = values.dup
          end
          copied
        end
      RUBY
      expected_clear = <<~CLEAR
        FN copy_map(input: {String}[]String) RETURNS !{String}[]String ->
          MUTABLE copied: {String}[]String = {};
          input.keys() |> EACH {
          MUTABLE values: []String = (input[_] OR_ELSE CAST(panic("missing hash key") AS []String));
          copied[_] = COPY values;
          };
          RETURN copied;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "transpiles common File and Dir stdlib calls to CLEAR primitives or thin adapters" do
      expect_transpile('File.read("a.txt")', "REQUIRE \"pkg:fs\"\nTRY (read(\"a.txt\"));")
      expect_transpile('File.readlines("a.txt")', "REQUIRE \"pkg:fs\"\nTRY (readLines(\"a.txt\"));")
      expect_transpile('File.foreach("a.txt")', "REQUIRE \"pkg:fs\"\nTRY (readLines(\"a.txt\"));")
      expect_transpile('File.foreach("a.txt") { |line| puts line }', "REQUIRE \"pkg:fs\"\nFOR _ IN TRY (readLines(\"a.txt\")) DO\nputs(_);\nEND")
      expect_transpile('File.write("a.txt", body)', "REQUIRE \"pkg:fs\"\nTRY (write(\"a.txt\", body()));")
      expect_transpile('File.binwrite("a.txt", bytes)', "REQUIRE \"pkg:fs\"\nTRY (write(\"a.txt\", bytes()));")
      expect_transpile('File.size(path)', "REQUIRE \"pkg:fs\"\nTRY (size(path()));")
      expect_transpile('File.exist?(path)', "REQUIRE \"pkg:fs\"\nexists?(path());")
      expect_transpile('File.exists?(path)', "REQUIRE \"pkg:fs\"\nexists?(path());")
      expect_transpile('File.file?(path)', "REQUIRE \"pkg:fs\"\nfile?(path());")
      expect_transpile('File.directory?(path)', "REQUIRE \"pkg:fs\"\ndir?(path());")
      expect_transpile('File.mtime(path)', "REQUIRE \"pkg:fs\"\nTRY (mtime(path()));")
      expect_transpile('File.delete(path)', "REQUIRE \"pkg:fs\"\nTRY (delete(path()));")
      expect_transpile('File.readlink(path)', "REQUIRE \"pkg:fs\"\nTRY (readLink(path()));")
      expect_transpile('File.symlink(target, link)', "REQUIRE \"pkg:fs\"\nTRY (symlink(target(), link()));")
      expect_transpile('File.symlink?(path)', "REQUIRE \"pkg:fs\"\nsymlink?(path());")
      expect_transpile('File.join(root, "src", name)', "REQUIRE \"pkg:path\"\njoin(root(), \"src\", name());")
      expect_transpile('File.expand_path("../x", base)', "REQUIRE \"pkg:path\"\nexpand(\"../x\", base());")
      expect_transpile('File.basename(path)', "REQUIRE \"pkg:path\"\nbasename(path());")
      expect_transpile('File.dirname(path)', "REQUIRE \"pkg:path\"\ndirname(path());")
      expect_transpile('Dir.glob(File.join(root, "*.rb"))', "REQUIRE \"pkg:fs\"\nREQUIRE \"pkg:path\"\nTRY (glob(join(root(), \"*.rb\")));")
      expect_transpile('Dir.exist?(path)', "REQUIRE \"pkg:fs\"\ndir?(path());")
      expect_transpile('Dir.exists?(path)', "REQUIRE \"pkg:fs\"\ndir?(path());")
      expect_transpile('Dir.children(path)', "REQUIRE \"pkg:fs\"\nTRY (list(path()));")
      expect_transpile('Dir.entries(path)', "REQUIRE \"pkg:fs\"\nTRY (listAll(path()));")
      expect_transpile('Dir.pwd', "REQUIRE \"pkg:fs\"\nTRY (pwd());")
    end

    it "elides Kernel Array coercion for an existing array value" do
      expect_transpile("def normalize(items); Array(items); end", <<~CLEAR)
        FN normalize(items: Auto) RETURNS Auto ->
          RETURN items;
        END
      CLEAR
    end

    it "omits superclass constructor calls from generated struct initializers" do
      ruby_code = <<~RUBY
        class Failure < StandardError
          sig { params(message: String).void }
          def initialize(message)
            @message = T.let(message, String)
            super(message)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE self = Failure{ message: COPY message };")
      expect(clear).not_to include("super(")
    end

    it "uses flattened storage for module constant paths" do
      ruby_code = <<~RUBY
        module Registry
          CATEGORIES = T.let([:syntax], T::Array[Symbol])
        end
        module Consumer
          CATEGORIES = Registry::CATEGORIES
        end
        VALUES = Registry::CATEGORIES
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE categories: []String@symbol = [:syntax];")
      expect(clear).to include("MUTABLE values: []String@symbol = categories;")
      expect(clear).not_to include("Registry.CATEGORIES")
      expect(clear).not_to include("MUTABLE categories = categories")
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
          MUTABLE body = TRY (read(path));
          TRY (write(out, body));
          RETURN body;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "propagates File call fallibility through helper calls inside iterator blocks" do
      ruby_code = <<~RUBY
        class Snapshot
          extend T::Sig

          sig { params(path: String).returns(String) }
          def self.digest(path)
            File.read(path)
          end

          sig { params(paths: T::Array[String]).returns(T::Array[String]) }
          def self.capture(paths)
            paths.map { |path| digest(path) }
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)

      expect(clear).to include("FN snapshot__capture(paths: []String) RETURNS ![]String")
      expect(clear).to include("paths |> SELECT TRY (snapshot__digest(_))")
    end

    it "propagates fallibility transitively through a receiver-qualified constant call, and mirrors it from initialize onto new" do
      # propagate_transitive_fallibility!'s call-graph walk only followed
      # no-receiver calls - precise for sibling/self/free-function calls
      # without needing receiver-type inference, but it meant a constructor
      # that becomes fallible ONLY by calling another class's method
      # directly (`SomeClass.raising_method(...)`, a receiver-QUALIFIED
      # call) never joined @inherently_fallible_methods, so external call
      # sites to that SAME constructor never got wrapped in TRY - even
      # though the constructor's OWN body-lowering correctly detected and
      # TRY-wrapped the identical fallibility internally (real corpus:
      # annotator/helpers/function_signature.rb's FunctionSignature#dup
      # calling FunctionSignature.new(...), where #initialize itself calls
      # FunctionSignature.copy_requires_for_import(...) directly - "Cannot
      # infer `copy` from a fallible value" once other methods on the class
      # gained enough real dispatch to make the compile reach this line).
      # Also covers the "initialize becomes fallible only via the fixpoint,
      # not a direct raise" case for the initialize->new mirror, which the
      # one-time seeding pass alone can't handle.
      ruby_code = <<~RUBY
        class Helper
          extend T::Sig
          sig { params(x: Integer).returns(Integer) }
          def self.risky(x)
            raise "bad" if x < 0
            x
          end
        end

        class Widget
          extend T::Sig
          sig { params(value: Integer).void }
          def initialize(value:)
            @value = Helper.risky(value)
          end
        end

        class Container
          extend T::Sig
          sig { params(w: Widget).returns(Widget) }
          def rebuild(w)
            Widget.new(value: 1)
          end
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("TRY (widget__new(1));")
    end

    it "supports an explicit fallible directive for recursive calls whose effect comes from typed receivers" do
      ruby_code = <<~RUBY
        class Renderer
          extend T::Sig

          # ruby-to-clear: fallible
          sig { params(value: Integer).returns(String) }
          def self.render(value)
            return "done" if value <= 0

            render(value - 1)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN renderer__render(value: Int64) RETURNS !String")
      expect(clear).to include("RETURN TRY (renderer__render((value - 1)));")
    end

    it "propagates fallibility through an owned class-method chain with an optional result" do
      ruby_code = <<~RUBY
        class Registry
          extend T::Sig

          sig { params(code: Symbol).returns(T.nilable(String)) }
          def self.template(code)
            raise "unknown" if code == :unknown

            nil
          end

          sig { params(code: Symbol).returns(T.nilable(String)) }
          def self.lookup(code)
            template(code)
          end

          sig { params(code: Symbol).returns(T.nilable(String)) }
          def self.format(code)
            lookup(code)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN registry__template(code: String@symbol) RETURNS !?String")
      expect(clear).to include("FN registry__lookup(code: String@symbol) RETURNS !?String")
      expect(clear).to include("RETURN TRY (registry__template(code));")
      expect(clear).to include("FN registry__format(code: String@symbol) RETURNS !?String")
      expect(clear).to include("RETURN TRY (registry__lookup(code));")
    end

    it "propagates inferred collection fallibility into recursive class-method calls" do
      ruby_code = <<~RUBY
        class Traversal
          extend T::Sig

          sig { params(value: Integer).returns(T::Array[Integer]) }
          def self.children(value)
            value > 0 ? [value - 1] : []
          end

          sig { params(value: Integer).returns(Integer) }
          def self.depth(value)
            maximum = T.let(0, Integer)
            children(value).each do |child|
              nested = depth(child)
              maximum = nested if nested > maximum
            end
            maximum
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN traversal__depth(value: Int64) RETURNS !Int64")
      expect(clear).to include("FOR _ IN (TRY (traversal__children(value))) DO")
      expect(clear).to include("MUTABLE nested = TRY (traversal__depth(_));")
    end

    it "propagates fallibility through explicit self class-method dispatch" do
      ruby_code = <<~RUBY
        class Cascade
          extend T::Sig

          sig { params(value: Integer).returns(Integer) }
          def self.leaf(value)
            raise "negative" if value < 0

            value
          end

          sig { params(value: Integer).returns(Integer) }
          def self.middle(value)
            self.leaf(value)
          end

          sig { params(value: Integer).returns(Integer) }
          def self.entry(value)
            self.middle(value)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN cascade__middle(value: Int64) RETURNS !Int64")
      expect(clear).to include("RETURN TRY (cascade__leaf(value));")
      expect(clear).to include("FN cascade__entry(value: Int64) RETURNS !Int64")
      expect(clear).to include("RETURN TRY (cascade__middle(value));")
      expect(clear).not_to include("self.leaf(")
      expect(clear).not_to include("self.middle(")
    end

    it "keeps nested owner identities qualified during transitive propagation" do
      ruby_code = <<~RUBY
        module Outer
          class Nested
            extend T::Sig

            sig { params(value: Integer).returns(Integer) }
            def self.risky(value)
              raise "negative" if value < 0

              value
            end

            sig { params(value: Integer).returns(Integer) }
            def self.entry(value)
              risky(value)
            end
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN nested__entry(value: Int64) RETURNS !Int64")
      expect(clear).to include("RETURN TRY (nested__risky(value));")
    end

    it "propagates imported transitive class-method fallibility across a qualified call" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "ruby")
        Dir.mkdir(dir)
        File.write(File.join(dir, "provider.rb"), <<~RUBY)
          class Provider
            extend T::Sig

            sig { params(value: Integer).returns(Integer) }
            def self.risky(value)
              raise "negative" if value < 0

              value
            end

            sig { params(value: Integer).returns(Integer) }
            def self.normalize(value)
              risky(value)
            end
          end
        RUBY
        root = File.join(dir, "consumer.rb")
        File.write(root, <<~RUBY)
          require_relative "./provider"

          class Consumer
            extend T::Sig

            sig { params(value: Integer).returns(Integer) }
            def self.call(value)
              Provider.normalize(value)
            end
          end
        RUBY

        clear = RubyToClear.transpile_file(root)
        expect(clear).to include("FN consumer__call(value: Int64) RETURNS !Int64")
        expect(clear).to include("RETURN TRY (provider__normalize(value));")
      end
    end

    it "preserves an explicitly qualified constant owner in the fallibility graph" do
      ruby_code = <<~RUBY
        module Outer
          class Helper
            extend T::Sig

            sig { params(value: Integer).returns(Integer) }
            def self.risky(value)
              raise "negative" if value < 0

              value
            end
          end
        end

        class Consumer
          extend T::Sig

          sig { params(value: Integer).returns(Integer) }
          def self.call(value)
            Outer::Helper.risky(value)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN consumer__call(value: Int64) RETURNS !Int64")
      expect(clear).to include("RETURN TRY (helper__risky(value));")
    end

    it "does not transfer a free function's fallibility to a same-named owned method" do
      ruby_code = <<~RUBY
        def normalize(value)
          raise "bad" if value < 0
          value
        end

        class Safe
          extend T::Sig

          sig { params(value: Integer).returns(Integer) }
          def self.normalize(value)
            value
          end

          sig { params(value: Integer).returns(Integer) }
          def self.call(value)
            Safe.normalize(value)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN safe__normalize(value);")
      expect(clear).not_to include("RETURN TRY (safe__normalize(value));")
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
          RETURN TRY (read(path));
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
      expect_transpile('s = " x "; s.rstrip', "MUTABLE s = \" x \";\nregexReplaceAll(s, \"\\\\s+\\\\z\", \"\");")
      expect_transpile('s = "abc"; s.start_with?("a")', "MUTABLE s = \"abc\";\ns.startsWith?(\"a\");")
      expect_transpile('s = "abc"; s.end_with?("c")', "MUTABLE s = \"abc\";\ns.endsWith?(\"c\");")
      expect_transpile('s = "abc"; s.start_with?("a", "b")', "MUTABLE s = \"abc\";\n(s.startsWith?(\"a\") OR s.startsWith?(\"b\"));")
      expect_transpile('s = "abc"; s.end_with?("b", "c")', "MUTABLE s = \"abc\";\n(s.endsWith?(\"b\") OR s.endsWith?(\"c\"));")
      expect_transpile('s = "abc"; s.index("b")', "MUTABLE s = \"abc\";\ns.indexOf(\"b\");")
      expect_transpile('s = "a"; s.lines', "MUTABLE s = \"a\";\ns.split(\"\\n\");")
      expect_transpile('parts = []; parts.join', "MUTABLE parts = List[];\nparts.join(\"\");")
    end

    it "parenthesizes cast expression receivers before method calls" do
      ruby_code = <<~RUBY
        sig { params(value: Symbol).returns(String) }
        def trim_symbol(value)
          value.to_s.strip
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("(CAST(value AS String)).trim();")
      expect_transpile(":name.to_s.length", "(CAST((:name) AS String)).codepointCount();")
      transpiler = RubyToClear::Transpiler.new("")
      expect(transpiler.method_receiver_code("CAST(items AS String[])")).to eq("(CAST(items AS String[]))")
    end

    it "uses receiver-shape tracking for overloaded collection and string calls" do
      expect_transpile('[1].size', "([1]).length();")
      expect_transpile('items = []; items.empty?', "MUTABLE items = List[];\n(items.length() == 0);")
      expect_transpile('items = []; items.size', "MUTABLE items = List[];\nitems.length();")
      expect_transpile('{ a: 1 }.length', "({:a: 1}).count();")
      expect_transpile('table = {}; table.empty?', "MUTABLE table = {};\n(table.count() == 0);")
      expect_transpile('table = {}; table.size', "MUTABLE table = {};\ntable.count();")
      expect_transpile('"abc".empty?', "(\"abc\".length() == 0);")
      expect_transpile('name = "abc"; name.empty?', "MUTABLE name = \"abc\";\n(name.length() == 0);")
      expect_transpile('name = "abc"; name.split("b")', "MUTABLE name = \"abc\";\nname.split(\"b\");")
      expect_transpile('name = "abc"; name.delete_prefix("a")', "MUTABLE name = \"abc\";\nname.deletePrefix(\"a\");")
      expect_transpile('items = []; copy = items.dup', "MUTABLE items = List[];\nMUTABLE copy = COPY items;")
      expect_transpile('name = "abc"; copy = name.dup', "MUTABLE name = \"abc\";\nMUTABLE copy = COPY name;")
    end

    it "tracks receiver shapes through typed values and call results" do
      expect_transpile('items = T.let([], T::Array[String]); items.size', "MUTABLE items: []String = ( { MUTABLE rtoc_empty_list_1: []String = List[]; rtoc_empty_list_1 } );\nitems.length();")
      expect_transpile('name = T.must("abc"); name.size', "MUTABLE name = \"abc\";\nname.codepointCount();")
      expect_transpile('n = text.to_i', "MUTABLE n = TRY (text().toInt());")
      expect_transpile('lines = File.readlines(path); lines.size', "REQUIRE \"pkg:fs\"\nMUTABLE lines = TRY (readLines(path()));\nlines.length();")
      expect_transpile('name = "a:b"; parts = name.split(":"); parts.size', "MUTABLE name = \"a:b\";\nMUTABLE parts = name.split(\":\");\nparts.length();")
      expect_transpile('table = {}; keys = table.keys; keys.size', "MUTABLE table = {};\nMUTABLE keys = table.keys();\nkeys.length();")
      expect_transpile('items = []; mapped = items.map { |item| item }; mapped.size', "MUTABLE items = List[];\nMUTABLE mapped = items |> SELECT _;\nmapped.length();")
      expect_transpile('pairs = []; pairs.any? { |w, t| match?(t, w) }', "MUTABLE pairs = List[];\npairs |> ANY match?(_._1, _._0);")
      expect_transpile('table = {}; pairs = []; pairs.each { |k, v| table[k] = v }', "MUTABLE table = {};\nMUTABLE pairs = List[];\nFOR _ IN pairs DO\ntable[_._0] = _._1;\nEND")
      expect_transpile("shape = get_shape; shape.map", "MUTABLE shape = get_shape();\nshape.map();")
    end

    it "extracts integer payloads before applying Ruby to_i to unions" do
      config = {
        "struct_fields" => { "Token" => { "value" => "TokenValue" } },
        "unions" => { "TokenValue" => ["String", "Int64", "Float64"] },
        "union_variants" => { "TokenValue" => { "String" => "Str", "Int64" => "Int", "Float64" => "Float" } }
      }
      ruby_code = <<~RUBY
        sig { params(token: Token).returns(Integer) }
        def numeric_value(token)
          token.value.to_i
        end
      RUBY

      result = RubyToClear.transpile(ruby_code, helper_config: config, raise_on_error: true)
      expect(result).to include("castTokenValueToInt64(token.value)")
      expect(result).to include("FN castTokenValueToInt64(value: TokenValue) RETURNS Int64")
    end

    it "statically lowers simple nil and type/reflection checks when receiver shape is known" do
      expect_transpile('items = []; items.nil?', "MUTABLE items = List[];\nFALSE;")
      expect_transpile('nil.is_a?(NilClass)', "TRUE;")
      expect_transpile('true.is_a?(Boolean)', "TRUE;")
      expect_transpile('1.is_a?(Numeric)', "TRUE;")
      expect_transpile(':name.is_a?(Symbol)', "TRUE;")
      expect_transpile('"abc".is_a?("String")', "TRUE;")
      expect_transpile('items = []; items.is_a?(Array)', "MUTABLE items = List[];\nTRUE;")
      expect_transpile('items = []; items.is_a?(Hash)', "MUTABLE items = List[];\nFALSE;")
      expect_transpile(
        'items = unknown; items.is_a?(Set)',
        "MUTABLE items = unknown();\nitems IS_A [Set]Any;"
      )
      expect_transpile('items = []; items.respond_to?("size")', "MUTABLE items = List[];\nTRUE;")
      expect_transpile('table = {}; table.respond_to?(:keys)', "MUTABLE table = {};\nTRUE;")
      expect_transpile('table = {}; table.respond_to?(:strip)', "MUTABLE table = {};\nFALSE;")
    end

    it "keeps runtime is_a? checks when a block receiver type is unknown" do
      ruby_code = <<~RUBY
        def array?(values)
          values.any? { |value| value.is_a?(Array) }
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code, raise_on_error: true)

      expect(clear).to include("IS_A []@multiowned Any")
    end

    it "expands dynamic is_a? predicates over closed static type arrays" do
      ruby_code = <<~RUBY
        LEAVES = [String, Symbol].freeze
        def leaf?(node)
          LEAVES.any? { |klass| node.is_a?(klass) }
        end
      RUBY
      expected_clear = <<~CLEAR
        leaves = [String, Symbol];
        FN leaf?(node: Auto) RETURNS Auto ->
          RETURN (node IS_A String OR node IS_A String@symbol);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers lexer scalar conversions with explicit helpers when Ruby needs a base or codepoint" do
      expect_transpile('hex.to_i(16)', "TRY (hex().toInt(16));")
      expect_transpile('hex.to_i(16).chr', "codepointToString((TRY (hex().toInt(16))));")
      expect_transpile('hex.to_i(16).chr(Encoding::UTF_8)', "codepointToString((TRY (hex().toInt(16))));")
    end

    it "makes unchecked Ruby integer conversions explicit CLEAR failures" do
      ruby_code = <<~RUBY
        sig { params(text: String).returns(Integer) }
        def parse_decimal(text)
          text.to_i
        end

        sig { params(text: String).returns(Integer) }
        def parse_hex(text)
          text.to_i(16)
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code, raise_on_error: true)
      expect(clear).to include("FN parse_decimal(text: String) RETURNS !Int64")
      expect(clear).to include("RETURN TRY (text.toInt());")
      expect(clear).to include("FN parse_hex(text: String) RETURNS !Int64")
      expect(clear).to include("RETURN TRY (text.toInt(16));")
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
        "MUTABLE items = get_items();\nitems IS_A []@multiowned Any;"
      )
      expect_transpile(
        'items = get_items; items.is_a?(Hash)',
        "MUTABLE items = get_items();\nitems IS_A {}Any;"
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
          RETURN T IS_A {}Any;
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
        UNION Value { StringValue: String, HashMapValue: {String@symbol}Int64 }
        FN hash_value?(value: Value) RETURNS Bool ->
          RETURN value IS_A {String@symbol}Int64;
        END
      CLEAR

      expect_transpile(ruby_code, expected_clear)
    end

    it "flattens nested union aliases for runtime collection predicates" do
      ruby_code = <<~RUBY
        RawEntry = T.type_alias { T::Hash[Symbol, Integer] }
        RawRegistryEntry = T.type_alias { T.any(RawEntry, T::Array[RawEntry]) }
        RawEmitInput = T.type_alias { T.nilable(T.any(RawRegistryEntry, Symbol, String)) }

        sig { params(value: RawEmitInput).returns(T::Boolean) }
        def hash_emit?(value)
          value.is_a?(Hash)
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("UNION RawEmitInput { HashMapValue: {String@symbol}Int64, ArrayValue: []{String@symbol}Int64, SymbolValue: String@symbol, StringValue: String }")
      expect(clear).to include("RETURN ((value != NIL) AND (value IS_A {String@symbol}Int64));")
      expect(clear).not_to include("HashMap<Any>")
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
      expect_transpile('Set.new([1, 2, 1])', '( { MUTABLE rtoc_pipe_src = [1, 2, 1]; rtoc_pipe_src |> DISTINCT _ } );')
      expect_transpile('Set.new(items) { |item| item.name }', '( { MUTABLE rtoc_pipe_src = items(); rtoc_pipe_src |> SELECT _.name() |> DISTINCT _ } );')
      expect_transpile('Set[:a, :b]', '[:a, :b] |> DISTINCT _;')
      expect_transpile('items.to_set', 'items() |> DISTINCT _;')
    end

    it "resolves the absolute-path spelling ::Set.new through the same registry lowering as Set.new" do
      # Prism's ConstantPathNode#full_name includes the leading "::" for an
      # absolute reference (real corpus case: semantic/local_binding_facts.rb's
      # `names = T.let(::Set.new, T::Set[String])`) - registry_receiver_name
      # passed that through unstripped, so the lookup key never matched the
      # registered "Set" receiver and this fell all the way through to
      # "Constructor call needs known field names" instead of reusing the
      # working Set.new lowering above.
      expect_transpile('::Set.new', 'Set[];')
    end

    it "lowers keyed uniq and typed Hash#to_a pipelines" do
      expect_transpile('items = []; items.uniq { |item| item.name }', "MUTABLE items = List[];\nitems |> DISTINCT _.name();")

      ruby_code = <<~RUBY
        sig { params(entries: T::Hash[String, Integer]).returns(T::Array[[String, Integer]]) }
        def pairs(entries)
          entries.to_a
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE rtoc_tuple_return_1 = ( { MUTABLE rtoc_tuple_results = CAST([] AS []Tuple<String, Int64>); entries.keys() |> EACH { &rtoc_tuple_results.append(COPY CAST(Tuple{COPY _, COPY (entries[_] OR_ELSE CAST(panic(\"missing hash key\") AS Int64))} AS Tuple<String, Int64>)); }; rtoc_tuple_results } );")
    end

    it "uses set insertion in generated set union helpers" do
      ruby_code = <<~RUBY
        left = T.let(Set.new, T::Set[String])
        right = T.let(Set.new, T::Set[String])
        merged = left | right
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("result.insert(COPY _);")
      expect(clear).not_to include("result.append(COPY _);")
    end

    it "lowers Hash#dig through optional nested accesses" do
      expected_clear = <<~CLEAR.chomp
        (IF registry()[name()] != NIL THEN
          ((registry()[name()])?)[:kind]
        ELSE
          NIL
        END);
      CLEAR
      expect_transpile("registry.dig(name, :kind)", expected_clear)
    end

    it "rejects Ruby regexp global match state instead of hiding it behind an adapter" do
      expect {
        RubyToClear.transpile("Regexp.last_match(1)")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /implicit regexp match state/)
    end
  end

  describe "unsupported/incorrect nodes in strict and lax mode" do
    it "translates ensure to DEFER so cleanup runs on both exit paths" do
      ruby_code = <<~RUBY
        def scoped
          enter
          work
        ensure
          leave
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code, raise_on_error: true)
      expect(clear).to include("DEFER leave();")
      expect(clear.index("DEFER leave();")).to be < clear.index("enter();")
    end

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
          RETURN value;
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
        "scanner().scan(\"0x_(${\"i32|u32\"})\\\\b\");"
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
        compilerRegexScan(scanner, compilerRegexCompile("0x_(${"i32|u32"})\\\\b"));
        compilerRegexReplaceFirst(compilerRegexMatched(scanner), compilerRegexCompile("_${compilerRegexEscape(suffix())}\\\\z"), "");
        compilerRegexCapture(scanner, 1);
        compilerRegexMatch(word(), compilerRegexCompile("^[A-Z]"));
        compilerCodepointToString((TRY (hex().toInt(16))));
      CLEAR
    end

    it "emits only reachable native extern declarations" do
      config = {
        "prelude" => [
          "EXTERN STRUCT NativeScanner FROM \"native\";",
          "EXTERN FN nativeScan(scanner: NativeScanner) RETURNS Bool FROM \"native\";",
          "EXTERN FN unusedNative() RETURNS Int64 FROM \"native\";",
        ],
        "helpers" => { "scanner_scan" => "nativeScan" },
        "scanner_receivers" => ["scanner"],
      }

      result = RubyToClear.transpile("scanner.scan(/x/)", helper_config: config)

      expect(result).to include("EXTERN STRUCT NativeScanner")
      expect(result).to include("EXTERN FN nativeScan")
      expect(result).not_to include("unusedNative")
    end

    it "uses helper config to choose concrete untyped parameter surfaces" do
      config = { "untyped_type" => "Any" }

      result = RubyToClear.transpile(<<~RUBY, helper_config: config)
        sig { params(block: T.proc.params(x: T.untyped).returns(T.untyped)).void }
        def walk(code, *args, **kwargs, &block)
        end
      RUBY

      expect(result.strip).to eq(<<~CLEAR.strip)
        FN walk(code: Any, args: []Any = [], kwargs: {String@symbol}Any = {}, block: FN(Any) -> Any) RETURNS Void ->

        END
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
          MUTABLE match: ?CompilerRegexScanner = compilerRegexMatchData(word, compilerRegexCompile("^([A-Z]+)(\\\\d+)$"));
          IF match EXISTS AS match_value THEN
            RETURN symbol(compilerRegexCapture(match_value, 1));
          ELSE
            RETURN NIL;
          END
        END
      CLEAR
    end

    it "resolves a zero-arg .match as a struct field read instead of erroring as a broken String#match call" do
      # register("match") unconditionally required exactly 1 argument and
      # raised "match expects 1 argument" otherwise - but a 0-arg .match can
      # never be a valid String#match/Regexp#match call (both require the
      # pattern), so it can only be a same-named struct field this generic
      # entry shadowed (real corpus: ast/syntax_typo_scanner.rb's
      # `TypoRule#match` field, read via `r.match` inside a
      # `RULES.each do |r| ... end` block, RULES being a module constant).
      source = <<~RUBY
        class TypoRule < T::Struct
          const :match, String
        end
        rule = TypoRule.new(match: "a")
        rule.match
      RUBY
      clear = RubyToClear.transpile(source)
      expect(clear).to include("rule.match;")
    end

    it "infers an each-block element type from a constant's fixed-size array type, not just a declared parameter type" do
      # array_element_type_for_receiver only recognized the SUFFIX array
      # convention (`T[]`) used by declared parameter types - a constant's
      # own inferred type is stored in CLEAR's PREFIX convention instead
      # (`[]T`, or `[N]T` for a literal CLEAR infers a known fixed length
      # for), so a block param iterating a constant array got no element
      # type at all and any field/method resolution needing that type
      # failed silently.
      source = <<~RUBY
        class Rule < T::Struct
          const :match, String
        end
        RULES = T.let([Rule.new(match: "a")].freeze, T::Array[Rule])
        RULES.each { |r| puts r.match }
      RUBY
      clear = RubyToClear.transpile(source)
      expect(clear).to include("puts(_.match)")
    end

    it "uses a syntax-valid placeholder for defined? in expression position in lax mode" do
      res = RubyToClear.transpile("unless defined?(Lexer)\nend", raise_on_error: false)
      expect(res.strip).to eq(<<~CLEAR.strip)
        IF !(TRUE) THEN

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
        "MUTABLE keywords: [Set]String = [\"A\"];\nkeywords.contains?(\"A\");"
      )
    end

    it "hoists class constants referenced by earlier methods" do
      ruby_code = <<~RUBY
        class Parser
          def accepts?(value)
            VALUES.include?(value)
          end

          VALUES = %w[A B].freeze
        end
      RUBY

      result = RubyToClear.transpile(ruby_code, raise_on_error: true)
      expect(result.index('values = ["A", "B"]')).to be < result.index('FN parser__accepts?')
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

    it "allows the method registry to identify regex-valued receivers" do
      config = {
        "helpers" => {
          "regex_literal" => "compilerRegexCompile",
          "regex_match_data" => "compilerRegexMatchData"
        }
      }
      ruby_code = <<~RUBY
        PATTERN = /item/
        match = PATTERN.match("an item")
      RUBY

      clear = RubyToClear.transpile(ruby_code, helper_config: config)
      expect(clear).to include('compilerRegexMatchData("an item", compilerRegexCompile("item"))')
    end

    it "folds constant gsub blocks into a plain replacement" do
      expect_transpile(
        "str = ''; str.gsub('a') { 'b' }",
        "MUTABLE str = \"\";\nstr.replace(\"a\", \"b\");"
      )
    end

    it "lowers regex gsub blocks with explicit scanner-backed captures" do
      ruby_code = <<~RUBY
        sig { params(source: String).returns(String) }
        def renumber(source)
          source.gsub(/item-(\\d+)/) do
            number = T.must(Regexp.last_match(1)).to_i
            "value-\#{number + 1}"
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("rtoc_gsub_scanner_")
      expect(clear).not_to match(/MUTABLE rtoc_gsub_scanner_\d+/)
      expect(clear).to include("scannerScan(rtoc_gsub_scanner_")
      expect(clear).to include("scannerCapture(rtoc_gsub_scanner_")
      expect(clear).to include("WHILE !(scannerEos(")
    end

    it "keeps receiver package imports when regex gsub is lowered" do
      result = RubyToClear.transpile('File.basename(path, ".clear").gsub(/[^a]/, "_")', raise_on_error: false)

      expect(result.strip).to eq(<<~CLEAR.strip)
        REQUIRE "pkg:path"
        regexReplaceAll((basename(path(), ".clear")), "[^a]", "_");
      CLEAR
    end

    it "lowers sub method calls" do
      expect_transpile(
        "str = ''; str.sub('a', 'b')",
        "MUTABLE str = \"\";\nreplaceFirst(str, \"a\", \"b\");"
      )
    end

    it "extracts string union payloads for sub and configured replacement helpers" do
      config = {
        "struct_fields" => { "Token" => { "value" => "TokenValue" } },
        "unions" => { "TokenValue" => ["String", "Int64"] },
        "union_variants" => { "TokenValue" => { "String" => "Str", "Int64" => "Int" } },
        "helpers" => {
          "regex_literal" => "compileRegex",
          "regex_replace_first" => "replaceRegexFirst"
        }
      }
      ruby_code = <<~RUBY
        sig { params(token: Token).returns(Symbol) }
        def sigil_name(token)
          token.value.sub('@', '').to_sym
        end
      RUBY

      result = RubyToClear.transpile(ruby_code, helper_config: config, raise_on_error: true)
      expect(result).to include("RETURN symbol((replaceRegexFirst(castTokenValueToString(token.value), compileRegex(\"@\"), \"\")));")
      expect(result).to include("IF value IS_A String AS cast_payload THEN")
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

    it "lowers transform_values to a rebuilt HashMap, both as a literal block and a symbol-to-proc" do
      # transform_values had no native CLEAR lowering at all (`./clear build`
      # on `h.transform_values(...)` standalone: TYPO_SUGGESTION_REJECTED,
      # not a real HashMap method) - unlike each_pair/map/select, it fell
      # through to the generic "emit the Ruby method name verbatim" path,
      # which only looked like plausible CLEAR source text until something
      # tried to build it (corpus's #1 fingerprint, 97 files:
      # ARGUMENT_TYPE_ERROR downstream of the malformed call). Rebuilds a
      # fresh HashMap by iterating .keys(), matching Ruby's non-mutating
      # transform_values (transform_values! would need its own in-place
      # lowering - not attempted here, no corpus caller uses it).
      expect_transpile(
        "h = {a: 1, b: 2}; h.transform_values { |v| v + 1 }",
        'MUTABLE h = {:a: 1, :b: 2};' + "\n( { MUTABLE rtoc_transform_values_result_1: {Any}Any = {}; " \
          "FOR rtoc_key IN h.keys() DO rtoc_transform_values_result_1[rtoc_key] = { MUTABLE rtoc_value_block_marker = 0;\n" \
          "  MUTABLE v: Any = (h[rtoc_key] OR_ELSE panic(\"missing hash key\"));\n(v + 1)\n" \
          '}; END rtoc_transform_values_result_1 } );'
      )

      # `&:size` - unlike .map's array-oriented `_` placeholder convention,
      # transform_values needs its own placeholder handling since a hash
      # value isn't an array element.
      expect_transpile(
        'h = {a: "x", b: "yy"}; h.transform_values(&:size)',
        'MUTABLE h = {:a: "x", :b: "yy"};' + "\n( { MUTABLE rtoc_transform_values_result_1: {Any}Any = {}; " \
          'FOR rtoc_key IN h.keys() DO rtoc_transform_values_result_1[rtoc_key] = ' \
          '(h[rtoc_key] OR_ELSE panic("missing hash key")).size(); END rtoc_transform_values_result_1 } );'
      )
    end

    it "lowers transform_values with a declared result type that differs from the source Hash's value type" do
      # The one real subtlety hash_map_value_stage's array counterpart
      # doesn't have to solve: a HashMap literal's value type is a
      # separately-declared slot at `{}` construction, and it is NOT
      # necessarily the same as the source Hash's own value type (real
      # corpus case: function_signature.rb's `generic_bounds.
      # transform_values { |bounds| bounds.map { |bound| Type.new(bound) } }`
      # changes what's stored per key, not just each value in place).
      ruby_code = <<~RUBY
        sig { params(h: T::Hash[Symbol, Integer]).returns(T::Hash[Symbol, String]) }
        def build(h)
          h.transform_values { |v| v.to_s }
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN build(h: {String@symbol}Int64) RETURNS !{String@symbol}String ->")
      expect(clear).to include("MUTABLE rtoc_transform_values_result_1: {String@symbol}String = {};")
      expect(clear).to include("MUTABLE v: Int64 = (h[rtoc_key] OR_ELSE CAST(panic(\"missing hash key\") AS Int64));")
      expect(clear).to include("v.toString()")
    end

    it "lowers transform_keys to a rebuilt HashMap keyed by the block's result" do
      expect_transpile(
        "h = {a: 1, b: 2}; h.transform_keys { |k| k.to_s }",
        'MUTABLE h = {:a: 1, :b: 2};' + "\n( { MUTABLE rtoc_transform_keys_result_1: {String}Any = {}; " \
          "FOR rtoc_key IN h.keys() DO rtoc_transform_keys_result_1[{ MUTABLE rtoc_value_block_marker = 0;\n" \
          "  MUTABLE k: Any = rtoc_key;\nCAST(k AS String)\n}] = " \
          '(h[rtoc_key] OR_ELSE panic("missing hash key")); END rtoc_transform_keys_result_1 } );'
      )
    end

    it "raises error on enumerable helpers that need unavailable Ruby semantics" do
      expect {
        RubyToClear.transpile("pairs = []; pairs.each_pair { |key, value| puts key }")
      }.to raise_error(RubyToClear::Transpiler::TranspilationError, /each_pair requires a statically known hash receiver/)

      # transform_values/transform_keys decline (rather than raise) when the
      # receiver type isn't statically known as a Hash, unlike each_pair -
      # a real corpus call site (protocol_projection_resolver.rb's `issue`
      # method) calls `values.transform_values(&:to_s)` on a `**values`
      # keyword-splat parameter (genuinely T.untyped, no way to statically
      # resolve it as a Hash even though it obviously is one at runtime);
      # raising here regressed G1 on that file, cascading to 101 more files
      # that depend on it. Declining falls through to the same generic
      # method-call rendering these calls always got before this file
      # registered transform_values/transform_keys at all.
      expect_transpile(
        "list = []; list.transform_values { |v| v }",
        "MUTABLE list = List[];\nlist.transform_values(%(v) -> v);"
      )
      expect_transpile(
        "list = []; list.transform_keys { |k| k }",
        "MUTABLE list = List[];\nlist.transform_keys(%(k) -> k);"
      )

      expect_transpile(
        "pairs = {a: 1}; pairs.each_pair { |key, value| puts value }",
        'MUTABLE pairs = {:a: 1};' + "\npairs.keys() |> EACH {\n  MUTABLE value: Any = (pairs[_] OR_ELSE panic(\"missing hash key\"));\nputs(value);\n};"
      )

      expect_transpile(
        "items = []; items.each_with_index { |item, index| puts item }",
        "MUTABLE items = List[];\nMUTABLE rtoc_idx = 0;\nWHILE rtoc_idx < items.length() DO\n  puts(items[rtoc_idx]);\n  rtoc_idx = rtoc_idx + 1;\nEND"
      )

      expect_transpile(
        'text = "ab"; text.each_char.with_index { |char, index| puts char }',
        'MUTABLE text = "ab";' + "\nMUTABLE rtoc_idx = 0;\nWHILE rtoc_idx < text.length() DO\n  puts(text.substr(rtoc_idx, 1));\n  rtoc_idx = rtoc_idx + 1;\nEND"
      )

      clear = RubyToClear.transpile('text = "ab"; text.each_char.with_index { |char, index| next if char == "a"; puts char }')
      expect(clear).to match(/rtoc_idx = rtoc_idx \+ 1;\s+CONTINUE;/)

      expect_transpile(
        "loop { tick; break unless keep_going }",
        "WHILE TRUE DO\n  tick();\n  IF !(keep_going()) THEN\n    BREAK;\n  END\nEND"
      )
    end

    it "binds a nontrivial each_with_index receiver once and coerces indexed aliases" do
      ruby_code = <<~RUBY
        class Collector
          sig { params(values: T::Array[String]).returns(T::Array[String]) }
          def load(values)
            values
          end

          sig { params(values: T::Array[String]).returns(T::Set[String]) }
          def collect(values)
            result = T.let(Set.new, T::Set[String])
            names = T.let([], T::Array[String])
            load(values).each_with_index do |value, index|
              result << value
              names << value
            end
            result
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear.scan("collector__load(rtoc_self_view, values)").length).to eq(1)
      expect(clear).to match(/MUTABLE rtoc_each_items_\d+ = \(TRY \(collector__load\(rtoc_self_view, values\)\)\);/)
      expect(clear).to match(/WHILE rtoc_idx < rtoc_each_items_\d+\.length\(\) DO/)
      expect(clear).to match(/result\.insert\(COPY rtoc_each_items_\d+\[rtoc_idx\]\?\)/)
      expect(clear).to match(/names\.append\(COPY rtoc_each_items_\d+\[rtoc_idx\]\?\)/)
      expect(clear).not_to include("UNWRAP (UNWRAP")
    end

    it "lowers destructured each_with_index parameters" do
      expect_transpile(
        "items = []; items.each_with_index { |(name, count), index| puts name }",
        "MUTABLE items = List[];\nMUTABLE rtoc_idx = 0;\nWHILE rtoc_idx < items.length() DO\n  puts(items[rtoc_idx][0]);\n  rtoc_idx = rtoc_idx + 1;\nEND"
      )
    end

    it "lowers each_with_index.count through the indexed-enumerator chain, like the sibling all?/any? cases" do
      # indexed_enumerator_value_chain's whitelist (call_lowerer.rb) had every
      # .each_with_index.X chain shape except count - a real corpus case
      # (annotator/helpers/function_analysis.rb's `args.each_with_index.count
      # { |arg, i| ... }`) fell through to the plain each_with_index registry
      # entry, which unconditionally requires a block on each_with_index
      # itself and raised "each_with_index without a block is not supported".
      source = <<~RUBY
        class Foo
          extend T::Sig
          sig { params(args: T::Array[Integer]).returns(Integer) }
          def counted(args)
            args.each_with_index.count { |arg, i| arg == i }
          end
        end
      RUBY
      clear = RubyToClear.transpile(source)
      expect(clear).to include("MUTABLE rtoc_indexed_output_3 = 0;")
      expect(clear).to include("IF (rtoc_indexed_items_1[rtoc_indexed_i_2] == rtoc_indexed_i_2) THEN\n        rtoc_indexed_output_3 = rtoc_indexed_output_3 + 1;\n      END")
      expect(clear).to include("rtoc_indexed_output_3\n    };")
    end

    it "copies borrowed index values appended to an owning container" do
      ruby_code = 'items = ["a"]; out = []; out << items[0]'
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("out.append(COPY items[0]);")
    end

    it "materializes Set#to_a as a regular array" do
      ruby_code = 'items = T.let(Set.new, T::Set[String]); values = items.to_a'
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE values = items |> SELECT COPY _;")
    end

    it "translates multi-statement pipeline blocks with implicit final expression values" do
      ruby_code = "list = []; list.map { |x| y = x * 2; y + 1 }"
      expected_clear = <<~CLEAR
        MUTABLE list = List[];
        list |> SELECT {
          MUTABLE y = (_ * 2);
          (y + 1)
        };
      CLEAR
      expect_transpile(ruby_code, expected_clear)

      ruby_code = "list = []; list.select { |x| y = x * 2; y > 10 }"
      expected_clear = <<~CLEAR
        MUTABLE list = List[];
        list |> WHERE {
          MUTABLE y = (_ * 2);
          (y > 10)
        };
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "preserves a blockless reverse_each as a reversed enumerable" do
      ruby_code = "items = T.let([], T::Array[String]); items.reverse_each.reduce('') { |out, item| out + item }"
      clear = RubyToClear.transpile(ruby_code)

      expect(clear).to include("items.reverse() |> REDUCE(\"\")")
    end

    it "lowers filter_map chained from a blockless each_with_index" do
      ruby_code = <<~RUBY
        sig { params(items: T::Array[String], skipped: Integer).returns(T::Array[String]) }
        def retain_other_items(items, skipped)
          items.each_with_index.filter_map { |item, index| item unless index == skipped }
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)

      expect(clear).to include("MUTABLE rtoc_indexed_value_")
      expect(clear).to match(/IF rtoc_indexed_value_\d+ EXISTS AS rtoc_indexed_value_\d+_value THEN/)
    end

    it "lowers flat_map chained from a blockless each_with_index" do
      ruby_code = <<~RUBY
        sig { params(items: T::Array[String]).returns(T::Array[String]) }
        def duplicate_first(items)
          items.each_with_index.flat_map do |item, index|
            next [item] unless index.zero?
            [item, item]
          end
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)

      expect(clear).to include("MUTABLE rtoc_indexed_value_")
      expect(clear).to include("FOR rtoc_indexed_flattened_")
    end

    it "does not route typed class methods through same-named Enumerable providers" do
      ruby_code = <<~RUBY
        class Planner
          extend T::Sig
          sig { params(source: String).returns(String) }
          def self.select(source)
            source
          end
        end

        result = Planner.select("plain")
      RUBY
      clear = RubyToClear.transpile(ruby_code)

      expect(clear).to include('planner__select("plain")')
    end

    it "lowers a map block's nonlocal return through a statement loop instead of a SELECT stage" do
      # `return` inside a block returns from the ENCLOSING METHOD in Ruby,
      # which a `|> SELECT` stage cannot express - so the value has to be
      # produced by a statement loop a RETURN can escape (the same shape
      # hash.each's nonlocal_return branch already uses). Real corpus:
      # mir/fsm_transform/emit.rb's `prior.map { |c| ...; return nil if
      # m.nil?; m }`, previously rejected outright.
      clear = RubyToClear.transpile("list = []; list.map { |x| return x }")
      expect(clear).to include("FOR rtoc_map_item_1 IN list DO")
      expect(clear).to include("RETURN rtoc_map_item_1;")

      source = <<~RUBY
        class M
          extend T::Sig
          sig { params(p: T::Array[String]).returns(T.nilable(T::Array[String])) }
          def go(p)
            p.map { |c| m = lookup(c); return nil if m.nil?; m }
          end
          sig { params(c: String).returns(T.nilable(String)) }
          def lookup(c); c.empty? ? nil : c; end
        end
      RUBY
      guarded = RubyToClear.transpile(source)
      # The accumulator carries the block's own result type (an empty List[]
      # gives CLEAR nothing to infer from), and the element is unwrapped at
      # the append because CLEAR does not narrow the optional across the
      # guard's RETURN.
      expect(guarded).to include("MUTABLE rtoc_map_results_2: []String = List[];")
      expect(guarded).to include("&rtoc_map_results_2.append(COPY UNWRAP (m));")
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
        FN swap_vars(a_input: Auto, b_input: Auto) RETURNS Auto ->
          MUTABLE a = COPY a_input;
          MUTABLE b = COPY b_input;
          a, b = [b, a];
          RETURN [b, a];
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
          MUTABLE x: Int64 = 0_i64;
          IF cond THEN
            x = 42;
          END
          RETURN x;
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
          RETURN x;
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
      expect(clear).to include("FN walk(values: []?Value) RETURNS Void ->")
      expect(clear).to include("IF vt EXISTS AS vt_value THEN")
      expect(clear).to include("IF vt_value IS_A String AS string THEN")
      expect(clear).not_to include("vt??")
    end

    it "does not turn nested optional guard tail statements into function returns" do
      ruby_code = <<~RUBY
        sig { params(values: T::Array[T.nilable(String)]).returns(T::Boolean) }
        def any_present(values)
          i = T.let(0, Integer)
          while i < values.length
            value = values.fetch(i)
            unless value
              i += 1
              next
            end
            if value == "yes"
              return true
            end
            i += 1
          end
          return false
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF value EXISTS AS value_value THEN")
      expect(clear).to include("i = (i + 1);")
      expect(clear).not_to include("RETURN i =")
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
      expect(clear).to include("IF vt_value IS_A String AS string THEN")
      expect(clear).to include("keep(vt_value);")
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
      expect(clear).to include("IF value EXISTS AS value_value THEN")
      expect(clear).to include("RETURN keep(value_value);")
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
      expect(clear).to include("IF value EXISTS AS value_value THEN")
      expect(clear).to include("RETURN keep(value_value);")
      expect(clear).not_to include("RETURN keep(value);")
    end

    it "parenthesizes T.must receivers before field access" do
      ruby_code = <<~RUBY
        class Token < T::Struct
          const :value, String
        end

        sig { params(token: T.nilable(Token)).returns(String) }
        def token_value(token)
          T.must(token).value
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN COPY (UNWRAP (token)).value;")
      expect(clear).not_to include("token?.value")
    end

    it "keeps T.must unwraps on non-union optional locals inside truthy guards" do
      ruby_code = <<~RUBY
        sig { params(value: Integer).returns(Integer) }
        def keep(value)
          value
        end

        sig { returns(Integer) }
        def first_positive
          value = T.cast(1, T.nilable(Integer))
          if value
            return keep(T.must(value))
          end

          0
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF value EXISTS AS value_value THEN")
      expect(clear).to include("RETURN keep(value_value);")
      expect(clear).not_to include('panic("T.must failed")')
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
      expect(clear).to include("MUTABLE items: []?String = List[];")
      expect(clear).to include("items.length();")
    end

    it "preserves an optional predeclared type across concrete branch assignments" do
      ruby_code = <<~RUBY
        class Item < T::Struct
        end
        sig { params(flag: T::Boolean).returns(T.nilable(Item)) }
        def build(flag)
          item = T.let(nil, T.nilable(Item))
          item = Item.new if flag
          item
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear.scan("MUTABLE item: ?Item = NIL;").length).to eq(1)
      expect(clear).to include("item = Item{};")
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
      # Ruby's no-default `fetch` raises on a missing index, so its result
      # is NOT optional - an indexed read in CLEAR is, so it needs UNWRAP to
      # match (the bare form is rejected: "Cannot infer `x` from an optional
      # value").
      expect(clear).to include("MUTABLE item = COPY UNWRAP (items[0]);")
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
      expect(clear).to include("MUTABLE fields = COPY schema.fields;")
      expect(clear).to include("MUTABLE values: []StructField@multiowned = fields.values();")
      # Ruby's no-default `fetch` raises on a missing index, so its result
      # is NOT optional - an indexed read in CLEAR is, so it needs UNWRAP to
      # match (the bare form is rejected: "Cannot infer `x` from an optional
      # value").
      expect(clear).to include("MUTABLE field = COPY UNWRAP (values[i]);")
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
      expect(clear).to include("IF schema IS_A StructSchema AS struct_schema THEN")
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
      expect(clear).to include("use_schema(Schema{ StructSchemaMultiowned: COPY struct_schema });")
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
          MUTABLE shape_str = after_error_str;
          RETURN shape_str;
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
          MUTABLE other = COPY kind;
          RETURN other;
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
        FN test_fn(p_input: Auto) RETURNS Auto ->
          MUTABLE p = COPY p_input;
          p = 10;
          RETURN 10;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "marks parameters as MUTABLE when their fields are assigned" do
      ruby_code = <<~RUBY
        def set_enabled(target, value)
          target.enabled = value
        end
        set_enabled(target, true)
      RUBY
      expected_clear = <<~CLEAR
        FN set_enabled(MUTABLE target: Auto, value: Auto) RETURNS Auto ->
          target.enabled = COPY value;
          RETURN value;
        END
        set_enabled(target(), TRUE);
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
        "error_mut({:code: :BAD});"
      )
    end

    it "translates static keyword parameters as ordinary CLEAR parameters" do
      ruby_code = <<~RUBY
        def my_func(a, b:, c: 1)
          b
        end
      RUBY
      expected_clear = <<~CLEAR
        FN my_func(a: Auto, b: Auto, c: Auto = 1) RETURNS Auto ->
          RETURN COPY b;
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
        FN emit(code: Auto, args: []Auto = [], kwargs: {String@symbol}Auto = {}) RETURNS Auto ->
          RETURN format(code, args, kwargs);
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
        FN emit(code: Auto, args: []Auto = [], kwargs: {String@symbol}Auto = {}) RETURNS Auto ->
          RETURN format(code, args, kwargs);
        END
        emit(:BAD, [], mergeKwargs({:value: name()}, kwargs()));
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "merges keyword splats when the call signature is dynamic" do
      expect_transpile(
        "kw = { name: 'value' }; report(code: :BAD, **kw, level: :error)",
        "MUTABLE kw = {:name: \"value\"};\nreport(mergeKwargs(mergeKwargs({:code: :BAD}, kw), {:level: :error}));"
      )
    end
  end

  describe "exception handling (rescue) validation" do
    it "lowers simple begin-rescue expressions as value recovery" do
      expect_transpile(
        "begin; do_something; rescue; handle_error; end",
        "(do_something() OR_ELSE handle_error());"
      )
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
          RETURN 1;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers inline rescue modifiers as value recovery" do
      expect_transpile(
        "do_something rescue handle_error",
        "(do_something() OR_ELSE handle_error());"
      )
    end

    it "lowers function-boundary StandardError rescue as a default catch" do
      ruby_code = <<~RUBY
        sig { returns(T::Boolean) }
        def safe
          work
        rescue StandardError
          false
        end
      RUBY
      expected_clear = <<~CLEAR
        FN safe() RETURNS Bool ->
          RETURN work();
        CATCH Transient, Input, System, NotFound, Permission, Canceled
          RETURN FALSE;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "translates typed Ruby exception dispatch to a typed CATCH arm" do
      clear = RubyToClear.transpile("def safe; work; rescue ParseError; false; end")
      expect(clear).to include("CATCH ParseError")
      expect(clear).to include("RETURN FALSE;")
    end
  end

  describe "dynamic Ruby blocker validation" do
    it "lowers static method aliases as typed forwarding functions" do
      ruby_code = <<~RUBY
        class Key
          sig { params(other: Key).returns(T::Boolean) }
          def eql?(other); true; end
          alias == eql?
        end
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Key {

        }

        FN key__eql?(self: Key, other: Key) RETURNS Bool
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN TRUE;
        }
        END
        FN key__equals?(self: Key, other: Key) RETURNS Bool ->
          key__eql?(self, other);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "folds statically resolvable defined queries" do
      expect_transpile("value = 1; defined?(value)", "MUTABLE value = 1;\nTRUE;")
    end

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
      expect_transpile("x = 10; x ||= 5", "MUTABLE x = 10;\nx = (x OR 5);")
      expect_transpile("x ||= 5", "MUTABLE x = 5;")
      expect_transpile("x &&= 5", "MUTABLE x = 5;")
      expect_transpile("x = true; x &&= false", "MUTABLE x = TRUE;\nx = (x AND FALSE);")
      expect_transpile("@val = 10; @val += 5", "self.val = 10;\nself.val = (self.val + 5);")
      expect_transpile("@type_object ||= fallback", "self.type_object = (self.type_object OR fallback());")
      expect_transpile("@enabled &&= flag", "self.enabled = (self.enabled AND flag());")
    end

    it "uses optional fallback for typed non-Boolean instance ||= writes" do
      ruby_code = <<~RUBY
        class Memo
          sig { returns(T.nilable(String)) }
          def value
            @value = T.let(@value, T.nilable(String))
            @value ||= fallback
          end
        end
      RUBY

      expect(RubyToClear.transpile(ruby_code)).to include("rtoc_self_view.value = (rtoc_self_view.value OR_ELSE fallback());")
    end

    it "copies typed instance fields across explicit return boundaries" do
      ruby_code = <<~RUBY
        class Holder
          sig { returns(T.nilable(String)) }
          def value
            @value = T.let(@value, T.nilable(String))
            return @value
          end
        end
      RUBY

      expect(RubyToClear.transpile(ruby_code)).to include("RETURN COPY rtoc_self_view.value;")
    end

    it "unwraps stable optional receivers for safe navigation" do
      ruby_code = <<~RUBY
        class Holder
          sig { returns(T.nilable(Type)) }
          def raw_type
            @type = T.let(@type, T.nilable(Type))
            @type&.raw
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF rtoc_self_view.type != NIL THEN")
      expect(clear).to include("RETURN ((rtoc_self_view.type)?).raw();")
    end

    it "lowers safe navigation as a nil check in a boolean and operand" do
      ruby_code = <<~RUBY
        class Holder
          sig { returns(T::Boolean) }
          def valid?
            @type = T.let(@type, T.nilable(Type))
            true && @type&.optional?
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN (TRUE AND ((rtoc_self_view.type != NIL) AND ((rtoc_self_view.type)?).optional?()));")
    end

    it "lowers safe navigation equality with a non-optional literal as a nil guard" do
      ruby_code = <<~RUBY
        class Parser
          sig { returns(T::Boolean) }
          def opening?
            peek_at(1)&.value == "("
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN ((peek_at(1) != NIL) AND (((peek_at(1))?).value() == \"(\"));")
    end

    it "keeps if-expression values expression-shaped in compound assignments" do
      ruby_code = <<~RUBY
        def full_type
          @type_object ||= if bool_binops.include?(op)
            build_bool
          else
            build_any
          end
        end
      RUBY
      expected_clear = <<~CLEAR
        FN full_type() RETURNS Auto ->
          self.type_object = (self.type_object OR IF bool_binops().contains?(op()) THEN
            build_bool()
          ELSE
            build_any()
          END);
          RETURN self.type_object;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "uses statement assignment for ternaries returning known structs" do
      ruby_code = <<~RUBY
        class Value < T::Struct
          const :number, Integer
        end

        sig { params(flag: T::Boolean, left: Value, right: Value).returns(Value) }
        def choose(flag, left, right)
          selected = flag ? left : right
          selected
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE selected_branch_value: ?Value = NIL;")
      expect(clear).to include("IF flag THEN\n    selected_branch_value = COPY left;\n  ELSE\n    selected_branch_value = COPY right;\n  END")
    end

    it "does not double-wrap optional struct ternary branch slots" do
      ruby_code = <<~RUBY
        class Value < T::Struct
          const :number, Integer
        end

        sig { params(flag: T::Boolean, left: T.nilable(Value), right: T.nilable(Value)).returns(T.nilable(Value)) }
        def choose(flag, left, right)
          selected = flag ? left : right
          selected
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE selected_branch_value: ?Value = NIL;")
      expect(clear).to include("MUTABLE selected: ?Value = selected_branch_value;")
      expect(clear).not_to include("??Value")
    end

    it "narrows optional ternary values without an expression AS binding" do
      ruby_code = <<~RUBY
        sig { params(missing: T.nilable(Integer)).returns(Integer) }
        def detail(missing)
          value = missing ? missing + 1 : 0
          value
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF missing != NIL THEN")
      expect(clear).to include("(missing + 1)")
      expect(clear).not_to include("IF missing AS")
    end

    it "narrows a truthy-guard ternary's local into a plain call argument, not a ?-unwrap" do
      # The real-world shape that broke 56 independent files: passing the
      # narrowed local as a CALL ARGUMENT (not just a binary-op operand).
      # `emit ? IntrinsicContract.from_emit(emit, @contract.params) : ...`.
      ruby_code = <<~RUBY
        sig { params(name: String).returns(Integer) }
        def make(name)
          name.length
        end

        sig { params(name: T.nilable(String)).returns(Integer) }
        def build(name)
          result = name ? make(name) : 0
          result
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF name != NIL THEN")
      expect(clear).to include("make(name)")
      expect(clear).not_to include("make(name?)")
    end

    it "narrows a safe-navigation-or local receiver in place, not via ?-rename" do
      # `x = a&.method || fallback` (assignment position) lowers to a
      # MUTABLE default declaration followed by
      # `IF a != NIL THEN x = a.method END`. For a bare local a, CLEAR's own
      # IF narrows it in place (same treatment as the truthy-guard ternary);
      # `a?` there is UNWRAP_NON_OPTIONAL. (Return/expression-position
      # `a&.method || fallback` routes through a separate OR_ELSE lowering
      # path with the same underlying bug, not covered by this fix.)
      ruby_code = <<~RUBY
        sig { params(v: Integer).returns(Integer) }
        def double(v)
          v * 2
        end

        sig { params(desc: T.nilable(Integer)).returns(Integer) }
        def pick(desc)
          result = desc&.itself || double(5)
          result
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF desc != NIL THEN")
      expect(clear).not_to include("desc?")
    end

    it "narrows optional values in the false branch of a nil predicate ternary" do
      ruby_code = <<~RUBY
        sig { params(value: T.nilable(Integer)).returns(Integer) }
        def selected(value)
          value.nil? ? 0 : value
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF (value == NIL) THEN")
      expect(clear).to include("RETURN COPY value;")
    end

    it "uses a branch slot for string ternary assignments" do
      ruby_code = <<~RUBY
        sig { params(flag: T::Boolean, name: String).returns(String) }
        def detail(flag, name)
          value = flag ? "name=\#{name}" : "none"
          value
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE value: String = \"\";")
      expect(clear).to match(/IF flag THEN\n\s+value = "name=\$\{name\}";\n\s+ELSE\n\s+value = "none";/)
    end

    it "narrows optional values inside string branch-slot assignments" do
      ruby_code = <<~RUBY
        sig { params(value: T.nilable(Symbol)).returns(String) }
        def detail(value)
          rendered = value ? "value=\#{value}" : "none"
          rendered
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF value EXISTS AS value_value THEN")
      expect(clear).to include("IF value EXISTS AS value_value THEN")
    end

    it "narrows String index results after a break guard" do
      ruby_code = <<~RUBY
        sig { params(template: String).returns(T::Array[Symbol]) }
        def keys(template)
          keys = T.let([], T::Array[Symbol])
          offset = T.let(0, Integer)
          loop do
            start_index = template.index("%{", offset)
            break unless start_index
            keys << template[(start_index + 2)...].to_sym
          end
          keys
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF start_index EXISTS AS start_index_value THEN")
      expect(clear).to include("start_index_value + 2")
    end

    it "narrows optional values after a raise guard" do
      ruby_code = <<~RUBY
        sig { params(value: T.nilable(String)).returns(Integer) }
        def length(value)
          Kernel.raise "missing" unless value
          value.length
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF value EXISTS AS value_value THEN")
      # Ruby String#length counts characters — CLEAR maps it to
      # codepointCount(), not byte length().
      expect(clear).to include("value_value.codepointCount()")
      expect(clear).to include('panic("missing")')
    end

    it "translates optional parameters in def signatures" do
      expect_transpile("def my_func(a, b = 42); end", "FN my_func(a: Auto, b: Auto = 42) RETURNS Auto ->\n\nEND")
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
          IF T IS_A BinaryOp THEN
            RETURN COPY node;
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
          IF !(node IS_A BinaryOp) THEN
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
          IF node IS_A BinaryOp AS binary_op THEN
            binary_op;
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "preserves typed array literal metadata through branch reassignment for later narrowing" do
      ruby_code = <<~RUBY
        class Identifier
          sig { returns(String) }
          def name
            "x"
          end
        end

        LifetimeSource = T.type_alias { T.any(String, Symbol) }
        LifetimeInputItem = T.type_alias { T.any(LifetimeSource, Identifier) }
        LifetimeInput = T.type_alias { T.nilable(T.any(LifetimeInputItem, T::Array[LifetimeInputItem])) }

        sig { params(val: LifetimeInput).returns(T::Array[LifetimeSource]) }
        def normalize_lifetime(val)
          return [] if val.nil?
          raw = T.let([], T::Array[LifetimeInputItem])
          if val.is_a?(Array)
            raw = val
          else
            raw = [T.cast(T.must(val), LifetimeInputItem)]
          end
          out = T.let([], T::Array[LifetimeSource])
          i = T.let(0, Integer)
          while i < raw.length
            item = raw.fetch(i)
            if item.is_a?(Identifier)
              out << item.name
            elsif item.is_a?(Symbol)
              out << item.to_s
            else
              out << item
            end
            i += 1
          end
          out
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF item IS_A Identifier AS identifier THEN")
      expect(clear).to include("&out.append(LifetimeSource{ StringValue: COPY identifier__name(identifier) });")
      expect(clear).to include("&out.append(LifetimeSource{ StringValue: COPY CAST(string_symbol AS String) });")
    end

    it "prefers explicit instance methods over same-named struct fields" do
      ruby_code = <<~RUBY
        Identifier = Struct.new(:name) do
          extend T::Sig

          sig { returns(String) }
          def name
            self[:name].to_s
          end
        end

        Item = T.type_alias { T.any(String, Identifier) }

        sig { params(item: Item).returns(String) }
        def read_name(item)
          if item.is_a?(Identifier)
            item.name
          else
            item
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF item IS_A Identifier AS identifier THEN")
      expect(clear).to include("name(identifier);")
      expect(clear).not_to include("identifier.name;")
    end

    it "finds explicit instance methods through namespaced receiver lookup aliases" do
      ruby_code = <<~RUBY
        module AST
          Identifier = Struct.new(:name) do
            extend T::Sig

            sig { returns(String) }
            def name
              self[:name].to_s
            end
          end
        end

        Item = T.type_alias { T.any(String, AST::Identifier) }

        sig { params(item: Item).returns(String) }
        def read_name(item)
          if item.is_a?(AST::Identifier)
            item.name
          else
            item
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF item IS_A Identifier AS identifier THEN")
      expect(clear).to include("name(identifier);")
      expect(clear).not_to include("identifier.name;")
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
          IF node IS_A Identifier AS identifier THEN
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
        expect(clear).to include("IF node IS_A BinaryOp AS binary_op THEN")
        expect(clear).to include("binary_op.op;")
        expect(clear).not_to include("binary_op.op()")
      end
    end

    it "uses the Locatable union for locals cast to its AST::Node alias" do
      ruby_code = <<~RUBY
        module AST
          module Locatable; end
          Identifier = Struct.new(:token, :name) { include Locatable }
          GetField = Struct.new(:token, :target) { include Locatable }
          Node = T.type_alias { Locatable }

          sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
          def self.identifier_target?(node)
            return false unless node.is_a?(AST::GetField)
            target = T.cast(node.target, AST::Node)
            target.is_a?(AST::Identifier)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE target: Locatable = CAST(get_field.target AS Locatable);")
      expect(clear).not_to include("UNION Node")
      expect(clear).not_to include("castNodeToLocatable")
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
          IF node IS_A BinaryOp AS binary_op THEN
            binary_op.op();
          ELSE
            RETURN;
          END
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "materializes mutable narrowed bindings after is_a? exit guards" do
      ruby_code = <<~RUBY
        class Item < T::Struct
          prop :used, T::Boolean, default: false

          sig { void }
          def mark!
            @used = true
          end
        end

        class Other < T::Struct
        end

        Node = T.type_alias { T.any(Item, Other) }
        sig { params(node: Node).void }
        def validate(node)
          return unless node.is_a?(Item)
          node.mark!
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF node IS_A Item AS item THEN")
      expect(clear).to include("MUTABLE item_mutable = COPY item;")
      expect(clear).to include("item__mark_mut(&item_mutable);")
      expect(clear).not_to include("item__mark_mut(&item);")
    end

    it "records preceding local types before narrowing a returning guard" do
      ruby_code = <<~RUBY
        Node = T.type_alias { T.any(AST::BinaryOp, AST::Identifier) }
        sig { params(raw: T.untyped).returns(T::Boolean) }
        def binary?(raw)
          node = T.cast(raw, Node)
          return false unless node.is_a?(AST::BinaryOp)
          true
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE node: Node")
      expect(clear).to include("IF node IS_A BinaryOp AS binary_op THEN")
      expect(clear).to include("RETURN TRUE")
    end

    it "retains the common branch type through T.must on a ternary" do
      ruby_code = <<~RUBY
        class Token < T::Struct
          const :value, String
        end
        sig { params(flag: T::Boolean).returns(T.nilable(Token)) }
        def consume(flag)
          nil
        end
        sig { params(flag: T::Boolean).returns(String) }
        def value(flag)
          (T.must(flag ? consume(true) : consume(false))).value
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include(").value;")
      expect(clear).not_to include(").value();")
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
        FN configure(items: []String, options: {String}Int64) RETURNS Void ->

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
        FN my_method(x: Int64, y: ?String, z: []Token) RETURNS Void ->

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
        FN typed(items: []String, table: {String}Int64, seen: [Set]String@symbol, maybe: ?String) RETURNS !{String}[]Int64 ->
          RETURN COPY table;
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
        FN names(entries: []Entry) RETURNS ![]String ->
          RETURN entries |> SELECT _.type;
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
        FN edge_types(f: Float64, n: Void, b: Bool, t: Bool, f2: Bool, any_t: Auto, arr: Any, hash: Any, set: Any, raw: Auto, anything: Auto, broad: Any, either: ?Either, unknown_maybe: ?Auto, enumerable: []String) RETURNS Void ->

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
        UNION PatternItem { StringValue: String, SymbolValue: String@symbol, HashMapValue: {String@symbol}String@symbol }
        UNION PatternCapture { Node: Node, Type: Type, StringValue: String, SymbolValue: String@symbol, Int64Value: Int64, Float64Value: Float64, BoolValue: Bool }
        UNION SigilAttrsValue { SymbolValue: String@symbol, BoolValue: Bool }
        FN typed_aliases(item: PatternItem, pattern: []PatternItem, capture: ?PatternCapture, attrs: {String@symbol}SigilAttrsValue) RETURNS ?PatternCapture ->
          RETURN COPY capture;
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
        FN fetch_value(table: {String@symbol}Int64, key: String) RETURNS Int64 ->
          MUTABLE value = UNWRAP (table[symbol(key)]);
          RETURN value;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers Ruby fetch calls to Clear indexing" do
      expect_transpile(
        'items = T.let([], T::Array[T.nilable(String)]); item = items.fetch(0)',
        "MUTABLE items: []?String = List[];\nMUTABLE item: ?String = items[0];"
      )
      expect_transpile(
        'items = T.let([], T::Array[String]); item = items.fetch(0)',
        "MUTABLE items: []String = ( { MUTABLE rtoc_empty_list_1: []String = List[]; rtoc_empty_list_1 } );\nMUTABLE item = UNWRAP (items[0]);"
      )
      expect_transpile(
        'table = T.let({}, T::Hash[String, Integer]); value = table.fetch("missing", 0)',
        "MUTABLE table: {String}Int64 = {};\nMUTABLE value = (table[\"missing\"] OR_ELSE 0);"
      )
      expect_transpile(
        'table = T.let({}, T::Hash[String, Integer]); value = table.fetch("present")',
        "MUTABLE table: {String}Int64 = {};\nMUTABLE value = table[\"present\"]?;"
      )
      expect_transpile(
        'value = {"present" => 1}.fetch("present")',
        "MUTABLE value = {\"present\": 1}[\"present\"]?;"
      )
      frozen_map = RubyToClear.transpile(<<~RUBY)
        ORDER = T.let({ micro: 0, large: 1 }.freeze, T::Hash[Symbol, Integer])
        sig { params(name: Symbol).returns(Integer) }
        def order(name)
          ORDER.fetch(name, 0)
        end
      RUBY
      expect(frozen_map).to include(
        '(CAST({:micro: 0, :large: 1} AS {String@symbol}Int64))[name] OR_ELSE 0'
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
      expect(clear).to include("MUTABLE item: ?String = COPY items[0];")
      expect(clear).to include("(item == NIL);")
    end

    it "keeps multi-statement fetch fallback blocks lazy and value-producing" do
      ruby_code = <<~RUBY
        sig { params(table: T::Hash[String, Integer], key: String).returns(Integer) }
        def fetch_value(table, key)
          table.fetch(key) do
            fallback = key.length
            fallback + 1
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN (table[key] OR_ELSE {")
      expect(clear).to include("MUTABLE fallback = key.codepointCount();")
      expect(clear).to include("(fallback + 1)")
    end

    it "uses statement assignments for nested value conditionals with binding predicates" do
      ruby_code = <<~RUBY
        class Box < T::Struct
          const :value, String
        end

        sig { params(flag: T::Boolean, maybe: T.nilable(String)).returns(Box) }
        def choose_box(flag, maybe)
          result = if flag
            if maybe
              Box.new(value: maybe)
            else
              Box.new(value: "missing")
            end
          else
            Box.new(value: "disabled")
          end
          result
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF maybe EXISTS AS maybe_value THEN")
      expect(clear).to include("result_branch_value = Box{ value: COPY maybe_value };")
      expect(clear).not_to include("result_branch_value = IF maybe EXISTS")
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
        MUTABLE items: []String = ( { MUTABLE rtoc_empty_list_1: []String = List[]; rtoc_empty_list_1 } );
        MUTABLE table: {String}Int64 = {};
        MUTABLE maybe: ?String = COPY CAST(value AS ?String);
        MUTABLE sure = COPY maybe?;
        MUTABLE unsafe = COPY sure;
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "lowers T.cast from Any to a concrete CLEAR cast" do
      ruby_code = <<~RUBY
        class Box < T::Struct
          const :payload, T.nilable(BasicObject), default: nil
        end

        box = Box.new(payload: raw)
        T.cast(box.payload, T.nilable(String))
      RUBY
      expected_clear = <<~CLEAR
        STRUCT Box {
          payload: ?Any@multiowned
        }
        MUTABLE box = Box{ payload: raw() };
        CAST(KEEP box.payload AS ?String);
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "does not re-wrap an explicit cast assigned to a typed local" do
      ruby_code = <<~RUBY
        TokenValue = T.type_alias { T.any(String, Integer) }
        class Token < T::Struct
          const :value, TokenValue
        end
        sig { params(token: Token).void }
        def assign_name(token)
          name = T.let("", String)
          name = T.cast(token.value, String)
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("name = COPY castTokenValueToString(token.value);")
      expect(clear).not_to include("castTokenValueToString(castTokenValueToString")
    end

    it "preserves explicit symbol casts across collection boundaries" do
      ruby_code = "keys.each { |key| symbol_key = T.cast(key, Symbol) }"
      expected_clear = "FOR _ IN keys() DO\nMUTABLE symbol_key: String@symbol = COPY CAST(_ AS String@symbol);\nEND"
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
        FN type__schema_resolver() RETURNS ?String ->
          RETURN "x";
        END
        MUTABLE resolver: ?String = type__schema_resolver();
        MUTABLE sure = COPY resolver?;
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "preserves T.let type metadata on constants" do
      # Top-level storage for a runtime-built map is illegal in CLEAR
      # (MODULE_SCOPE_OWNED_VALUE), so the frozen constant inlines its
      # construction at use sites; the T.let metadata still drives the
      # symbol-key literal spelling.
      ruby_code = <<~RUBY
        TABLE = T.let({ a: "A" }.freeze, T::Hash[Symbol, String])

        extend T::Sig

        sig { returns(T.nilable(String)) }
        def lookup
          TABLE[:a]
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)

      expect(clear).not_to include("table:")
      expect(clear).to include('(CAST({:a: "A"} AS {String@symbol}String))[:a]')
    end

    it "keeps typed string arrays distinct from string receivers" do
      ruby_code = 'parts = T.let(["a", "b"], T::Array[String]); parts[0]; parts[1].to_sym'
      expected_clear = <<~CLEAR
        MUTABLE parts: []String = ["a", "b"];
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
        UNION Raw { FunctionSignature: FunctionSignature, ArrayValue: []@multiowned Any, SymbolValue: String@symbol, StringValue: String }
        STRUCT Shape {
          raw: Raw
        }

        FN shape__make(name: String) RETURNS Shape ->
          MUTABLE raw_symbol = symbol(name);
          RETURN Shape{ raw: Raw{ SymbolValue: COPY raw_symbol } };
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
          RETURN 1;
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

        PRIVATE FN thing__run(self: Thing) RETURNS Auto
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN 1;
        }
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "drops Sorbet helper and ancestor declarations" do
      ruby_code = <<~RUBY
        module Bridge
          extend T::Helpers
          requires_ancestor { Owner }
          interface!
        end
      RUBY
      expected_clear = <<~CLEAR
        # Ruby module Bridge
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
        FN passthrough(table: {String}Int64) RETURNS !{String}Int64 ->
          RETURN COPY table;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "resolves aliases from enclosing classes in nested T::Struct fields" do
      ruby_code = <<~RUBY
        class Outer
          Table = T.type_alias { T::Hash[String, Integer] }

          class Facts < T::Struct
            prop :table, Table, factory: -> { {} }
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("table: {String}Int64")
      expect(clear).not_to include("table: Table")
    end

    it "omits Ruby-only constant visibility scaffolding" do
      ruby_code = <<~RUBY
        class Outer
          class Nested < T::Struct
            const :name, String
          end

          private_constant(:Nested)
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("STRUCT Nested")
      expect(clear).not_to include("private_constant")
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
        FN typeCapabilities__keep(self: TypeCapabilities, ownership: ?TypeCapabilitiesMaybeSymbol = TypeCapabilitiesMaybeSymbol{ TypeCapabilityUnset: COPY TypeCapabilityUnset{} }) RETURNS ?TypeCapabilitiesMaybeSymbol
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN COPY ownership;
        }
        END
        STRUCT TypePlacementUnset {

        }
        STRUCT TypePlacement {

        }

        UNION TypePlacementMaybeSymbol { TypePlacementUnset: TypePlacementUnset, SymbolValue: String@symbol }
        FN typePlacement__keep(self: TypePlacement, provenance: ?TypePlacementMaybeSymbol = TypePlacementMaybeSymbol{ TypePlacementUnset: COPY TypePlacementUnset{} }) RETURNS ?TypePlacementMaybeSymbol
          REQUIRES self: LOCAL
        ->
        WITH POLYMORPHIC self AS rtoc_self_view {
            RETURN COPY provenance;
        }
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
      expect(clear).to include("UNION TypeTypeNodeInput { TypeMultiowned: Type@multiowned, SymbolValue: String@symbol, StringValue: String }")
      expect(clear).not_to include("TypeInput: TypeInput")
    end

    it "qualifies method parameter aliases when multiple owners use the same name" do
      ruby_code = <<~RUBY
        class Source
          TypeInput = T.type_alias { T.any(Symbol, String) }

          sig { params(value: TypeInput).returns(TypeInput) }
          def self.normalize(value)
            value
          end
        end

        class Other
          TypeInput = T.type_alias { T.any(Integer, String) }
        end

        Source.normalize(:ready)
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("UNION SourceTypeInput { SymbolValue: String@symbol, StringValue: String }")
      expect(clear).to include("normalize(SourceTypeInput{ SymbolValue: :ready });")
      expect(clear).not_to include("OtherTypeInput{")
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

    it "wraps interpolated symbols for generated union constructor parameters" do
      ruby_code = <<~RUBY
        class Type
          TypeInput = T.type_alias { T.any(Type, Symbol, String) }

          sig { params(raw: TypeInput).void }
          def initialize(raw)
            @raw = T.let(raw, TypeInput)
          end
        end

        sig { params(name: String).returns(Type) }
        def optional_type(name)
          Type.new(:"?\#{name}")
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include('type__new(TypeTypeInput{ SymbolValue: COPY symbol("?${name}") })')
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
      expect(clear).to include("RETURN typeCapabilities__with(rtoc_self_view, TypeCapabilitiesMaybeSymbol{ SymbolValue: :affine }, NIL);")
      expect(clear).to include("FN typeCapabilities__with(self: TypeCapabilities, ownership: ?TypeCapabilitiesMaybeSymbol = TypeCapabilitiesMaybeSymbol{ TypeCapabilityUnset: COPY TypeCapabilityUnset{} }, sync_value: ?TypeCapabilitiesMaybeSymbol = TypeCapabilitiesMaybeSymbol{ TypeCapabilityUnset: COPY TypeCapabilityUnset{} }) RETURNS ?TypeCapabilitiesMaybeSymbol")
    end

    it "wraps array payloads whose elements need nested union aliases" do
      ruby_code = <<~RUBY
        class Node < T::Struct
        end

        LifetimeSource = T.type_alias { T.any(String, Symbol) }
        LifetimeInput = T.type_alias { T.nilable(T.any(LifetimeSource, Node, T::Array[T.any(LifetimeSource, Node)])) }

        sig { params(value: LifetimeInput).returns(Void) }
        def accept(value)
        end

        sig { params(values: T::Array[LifetimeSource]).returns(Void) }
        def call(values)
          accept(values)
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("accept(LifetimeInput{ ArrayValue: values |> SELECT castLifetimeSourceToLifetimeInputArrayItem(_) });")
      expect(clear).to include("FN castLifetimeSourceToLifetimeInputArrayItem(value: LifetimeSource) RETURNS LifetimeInputArrayItem ->")
    end

    it "wraps narrowed union payloads assigned through attribute writers" do
      ruby_code = <<~RUBY
        Raw = T.type_alias { T.nilable(T.any(Symbol, String)) }

        class Box < T::Struct
          prop :raw, Raw
        end

        sig { params(box: Box, value: Raw).returns(Void) }
        def store_raw(box, value)
          if value.is_a?(Symbol)
            box.raw = value
          elsif value.is_a?(String)
            box.raw = value
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("box.raw = COPY Raw{ SymbolValue: COPY string_symbol };")
      expect(clear).to include("box.raw = COPY Raw{ StringValue: COPY string };")
      expect(clear).not_to include("box.raw = NIL")
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
      # An indexed array read is ?String, so feeding it a String-typed union
      # payload slot must unwrap first - the bare form the old expectation
      # pinned is rejected by the frontend (UNION_PAYLOAD_MISMATCH: expects
      # String, got ?String).
      expect(clear).to include("RETURN keep(Raw{ StringValue: COPY UNWRAP (items[0]) });")
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
        FN parse_array_capacity(raw_capacity: ?String) RETURNS !?ArrayCapacity ->
          IF raw_capacity EXISTS AS raw_capacity_value THEN
            IF (raw_capacity_value == "?") THEN
              RETURN ArrayCapacity{ SymbolValue: :STREAM_OPEN };
            END
            RETURN ArrayCapacity{ Int64Value: TRY (raw_capacity_value.toInt()) };
          ELSE
            RETURN NIL;
          END
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
          RETURN COPY key;
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "makes a final tuple literal an explicit typed return" do
      ruby_code = <<~RUBY
        Result = T.type_alias { [Symbol, T.nilable(String)] }
        sig { params(value: Symbol).returns(Result) }
        def result_for(value)
          [value, nil]
        end
      RUBY
      # The nil tuple slot's cast type must match the declared return type
      # (?String), not the literal-only inferred Void - a Tuple<..., Void>
      # cast here would be a genuine type mismatch against the function's own
      # `RETURNS Tuple<String@symbol, ?String>` signature.
      expected_clear = <<~CLEAR
        FN result_for(value: String@symbol) RETURNS Tuple<String@symbol, ?String> ->
          RETURN CAST(Tuple{value, NIL} AS Tuple<String@symbol, ?String>);
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
          RETURN resolver(name);
        END
      CLEAR
      expect_transpile(ruby_code, expected_clear)
    end

    it "narrows Proc#call on optional function receivers through an unwrapped local" do
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

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF resolver EXISTS AS resolver_value THEN")
      expect(clear).to include("RETURN resolver_value(name);")
      expect(clear).not_to include("resolver(name)")
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
          MUTABLE fn = COPY resolver?;
          RETURN fn(name);
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
          MUTABLE fn = COPY resolver?;
          RETURN fn(name);
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
            fn = COPY resolver?;
          END
          RETURN fn(name);
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
        UNION Resolver { FunctionValue: FN(String@symbol) -> String, HashMapValue: {String@symbol}String }
        FN resolve(resolver: Resolver) RETURNS String ->
          RETURN "ok";
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
        FN parse_generic<Elem>(type: String@symbol, blk: FN() -> Elem) RETURNS Tuple<Token, []Elem> ->

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

        class Selection
          extend T::Sig
          sig { returns(Mode) }
          attr_reader :mode
          sig { params(mode: Mode).void }
          def initialize(mode)
            @mode = T.let(mode, Mode)
          end
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("ENUM Mode { Read, Write }")
      expect(clear).to include("mode: Mode")
      expect(clear).not_to include("Mode@multiowned")
    end

    it "preserves enum constant paths inside Ruby modules" do
      ruby_code = <<~RUBY
        module Schemas
          class Kind < T::Enum
            enums do
              Method = new("method")
            end
          end

          def self.default_kind
            Kind::Method
          end
        end
      RUBY
      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("ENUM Kind { Method }")
      expect(clear).to include("Kind.Method;")
      expect(clear).not_to include("method_value")
    end

    it "resolves enum constant paths before their declaration in a module" do
      ruby_code = <<~RUBY
        module Schemas
          def self.default_kind
            ResourceCloseCallKind::Method
          end

          class ResourceCloseCallKind < T::Enum
            enums do
              Method = new("method")
            end
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN ResourceCloseCallKind.Method;")
      expect(clear).not_to include("method_value")
    end
  end

  describe "typed IR vertical slice" do
    def transpile_with_ir(source)
      program = Prism.parse(source).value
      transpiler = RubyToClear::Transpiler.new(source)
      clear = transpiler.transpile(program)
      [clear, transpiler.typed_ir]
    end

    it "resolves bare nested mixin edges through their qualified owner" do
      transpiler = described_class.new("")
      class_includes = transpiler.instance_variable_get(:@class_includes)
      mixin_includes = transpiler.instance_variable_get(:@mixin_includes)
      mixin_fields = transpiler.instance_variable_get(:@mixin_fields)
      class_includes["MIR::Call"] << "Expr"
      mixin_fields["MIR::Expr"] = {}
      mixin_fields["MIR::Emittable"] = {}
      mixin_includes["MIR::Expr"] << "Emittable"

      expect(transpiler.send(:transitive_includes, "MIR::Call")).to include("MIR::Expr", "MIR::Emittable")
    end

    it "preserves resolved calls whose names overlap framework DSL methods" do
      source = <<~RUBY
        class FunctionPath < T::Struct
          const :parts, T::Array[String]
          sig { params(parts: T::Array[String]).returns(FunctionPath) }
          def self.context(parts)
            FunctionPath.new(parts: parts)
          end
        end
        sig { params(parts: T::Array[String]).returns(FunctionPath) }
        def context_path(parts)
          FunctionPath.context(parts)
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      call = ir.calls.values.find { |fact| fact.target.name == "context" }
      expect(call.target.owner).to eq("FunctionPath")
      expect(call.dispatch).to eq(:class)
      expect(clear).to include("RETURN functionPath__context(parts);")
      expect(clear).not_to include("RETURN ;")
    end

    it "resolves a call through an optional narrowing to a concrete target" do
      source = <<~RUBY
        class Action < T::Struct
          extend T::Sig
          sig { returns(Integer) }
          def count = 1
        end
        sig { params(action: T.nilable(Action)).returns(Integer) }
        def count_action(action)
          return 0 unless action
          action.count
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      call = ir.calls.values.find { |fact| fact.target.name == "count" }
      expect(call.dispatch).to eq(:instance)
      expect(call.receiver_type.to_clear).to eq("Action")
      expect(clear).to include("count(action_value)")
      expect(ir.validate!).to be(true)
    end

    it "preserves a T.cast block binding for resolved field access" do
      source = <<~RUBY
        class Item < T::Struct
          const :name, String
        end
        sig { params(values: T::Array[T.untyped]).returns(T::Array[String]) }
        def names(values)
          values.map do |value|
            item = T.cast(value, Item)
            item.name
          end
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      field = ir.fields.values.find { |fact| fact.field.name == "name" }
      expect(field.receiver_type.to_clear).to eq("Item")
      expect(field.field_type.to_clear).to eq("String")
      expect(clear).to include("item.name")
    end

    it "preserves explicit Sorbet casts when legacy inference is less precise" do
      source = <<~RUBY
        sig { params(entry: T::Hash[Symbol, T.untyped]).returns(String) }
        def template(entry)
          T.cast(entry[:template], String)
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("CAST(entry[:template] AS String)")
    end

    it "represents Sorbet prop reads and writes as fields" do
      source = <<~RUBY
        class Box < T::Struct
          prop :value, String
        end
        sig { params(box: Box, value: String).returns(String) }
        def replace(box, value)
          box.value = value
          box.value
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      accesses = ir.fields.values.select { |fact| fact.field.name == "value" }
      expect(accesses.map(&:write)).to contain_exactly(true, false)
      expect(clear).to include("box.value = COPY value")
      expect(clear).to include("RETURN COPY box.value")
    end

    it "keeps same-named instance and class methods as distinct symbols" do
      source = <<~RUBY
        class Worker
          def run = 1
          def self.run = 2
          def invoke = run
          def self.invoke = run
        end
      RUBY

      _clear, ir = transpile_with_ir(source)
      symbols = ir.functions.values.map(&:symbol).select { |symbol| symbol.name == "run" }
      expect(symbols.map(&:kind)).to contain_exactly(:instance_method, :class_method)
      expect(symbols.map(&:to_s).uniq.length).to eq(2)
      expect(_clear).to include("FN worker__run(self: Worker)")
      expect(_clear).to include("FN worker__class_run()")
    end

    it "resolves qualified constant calls to their declaration owner" do
      source = <<~RUBY
        module Outer
          class Factory
            def self.build = 1
          end
        end
        def make
          Outer::Factory.build
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      call = ir.calls.values.find { |fact| fact.target.name == "build" }
      expect(call.target.owner).to eq("Outer::Factory")
      expect(call.dispatch).to eq(:class)
      expect(clear).to include("build()")
    end

    it "preserves qualified constructor identity when wrapping interface unions" do
      source = <<~RUBY
        module MIR
          module Emittable
          end
          module Expr
            include Emittable
          end
          Call = Struct.new(:name) do
            include Expr
          end
          Body = T.type_alias { T.any(Emittable, T::Array[Emittable]) }
          Holder = Struct.new(:body) do
            sig { returns(Body) }
            def body
              self[:body]
            end
          end
          class Lowerer
            extend T::Sig
            sig { params(name: String).returns(MIR::Call) }
            def make_call(name)
              MIR::Call.new(name)
            end
            sig { params(name: String).returns(MIR::Holder) }
            def build(name)
              MIR::Holder.new(make_call(name))
            end
          end
        end
        sig { params(name: String).returns(MIR::Holder) }
        def build(name)
          MIR::Holder.new(MIR::Call.new(name))
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      constructor = ir.calls.values.find do |fact|
        fact.dispatch == :constructor && fact.target.owner == "MIR::Call"
      end
      expect(constructor.target.kind).to eq(:constructor)
      implicit_call = ir.calls.values.find { |fact| fact.target.name == "make_call" }
      expect(implicit_call.target.owner).to eq("MIR::Lowerer")
      expect(implicit_call.result_type_identity).to eq("MIR::Call")
      expect(clear).to include("Body{ Emittable:")
      expect(clear).to include("Call{ name: COPY name }")
      expect(clear).to match(/Body\{ Emittable: .*lowerer__make_call\(rtoc_self_view, name\)/)
    end

    it "types non-returning fallbacks in optional OR expressions" do
      source = <<~RUBY
        sig { params(values: T::Hash[Symbol, String], key: Symbol).returns(String) }
        def fetch_value(values, key)
          value = values[key] or raise ArgumentError, "missing"
          value
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include('OR CAST(panic("missing") AS String)')
    end

    it "types fields returned as child expressions by their interface" do
      source = <<~RUBY
        module Emittable
          def compact_child_exprs(values)
            values
          end
        end
        Leaf = Struct.new(:value) do
          include Emittable
        end
        Pair = Struct.new(:left, :right) do
          include Emittable
          def child_exprs
            compact_child_exprs([left, right])
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("left: Emittable")
      expect(clear).to include("right: Emittable")
    end

    it "normalizes absolute Sorbet type paths before CLEAR emission" do
      source = <<~RUBY
        module AST
          Param = Struct.new(:name)
        end
        sig { returns(T::Array[::AST::Param]) }
        def params
          []
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("FN params() RETURNS ![]Param ->")
      expect(clear).not_to include("::AST::Param")
    end

    it "ignores empty basename lookup buckets when resolving nested method owners" do
      source = <<~RUBY
        class Container < T::Struct
          class Facts < T::Struct
            sig { returns(Facts) }
            def copy
              Facts.new
            end
          end
          const :facts, Facts
          sig { returns(Facts) }
          def duplicate
            facts.copy
          end
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      call = ir.calls.values.find { |fact| fact.target.name == "copy" }
      expect(call.target.owner).to eq("Container::Facts")
      expect(clear).to include("facts__copy(self.facts)")
      expect(clear).not_to include("self.facts.copy()")
    end

    it "records copy ownership for an owned nonprimitive argument" do
      source = <<~RUBY
        class Sink
          extend T::Sig
          sig { params(value: String).void }
          def self.take(value); end
        end
        sig { params(value: String).void }
        def forward(value)
          Sink.take(value)
        end
      RUBY

      _clear, ir = transpile_with_ir(source)
      call = ir.calls.values.find { |fact| fact.target.name == "take" }
      expect(call.argument_ownership.map(&:mode)).to eq([:copy])
    end

    it "records mutable closure captures once in the shared IR" do
      source = <<~RUBY
        sig { params(value: Integer).returns(Integer) }
        def update(value)
          callback = -> { value = value + 1 }
          callback.call
          value
        end
      RUBY

      _clear, ir = transpile_with_ir(source)
      closure = ir.closures.values.first
      expect(closure.captures).to include("value" => :borrow_mut)
    end

    it "erases heterogeneous literals to Any for T::Array[T.untyped] parameters" do
      source = <<~RUBY
        sig { params(values: T::Array[T.untyped]).returns(Integer) }
        def count(values)
          values.length
        end
        sig { params(receiver: T.untyped, args: T::Array[T.untyped]).returns(Integer) }
        def child_count(receiver, args)
          count([receiver, args])
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include(
        "count([CAST(receiver AS Any), CAST(args AS Any)])"
      )
    end

    it "normalizes splatted contextual arrays before call emission" do
      source = <<~RUBY
        sig { params(values: T::Array[String]).returns(T::Array[String]) }
        def identity(values)
          values
        end
        sig { params(head: String, tail: T::Array[String]).returns(T::Array[String]) }
        def prepend(head, tail)
          identity([head, *tail])
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("RETURN TRY (identity((CAST([head] AS []String) + COPY tail)));")
      expect(clear).not_to include("Splat arguments require")
    end

    it "normalizes symbol-to-proc find blocks through the resolved element type" do
      source = <<~RUBY
        class Fact < T::Struct
          const :active, T::Boolean
        end
        sig { params(values: T::Array[Fact]).returns(T.nilable(Fact)) }
        def first_active(values)
          values.find(&:active)
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("values |> FIND _.active")
    end

    it "keeps same-named mixin storage contracts namespace-qualified" do
      source = <<~RUBY
        module Left
          module Expr
            attr_accessor :left_fact
          end
          LeftNode = Struct.new(:value) do
            include Expr
          end
        end
        module Right
          module Expr
            attr_accessor :right_fact
          end
          RightNode = Struct.new(:value) do
            include Expr
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      left_struct = clear[/STRUCT LeftNode \{.*?\n\}/m]
      right_struct = clear[/STRUCT RightNode \{.*?\n\}/m]
      expect(left_struct).to include("left_fact: Any")
      expect(left_struct).not_to include("right_fact")
      expect(right_struct).to include("right_fact: Any")
      expect(right_struct).not_to include("left_fact")
    end

    it "normalizes an unsigned struct field used by each to an array" do
      source = <<~RUBY
        Bag = Struct.new(:items) do
          sig { returns(Integer) }
          def size
            count = 0
            items.each { |item| count += 1 if item.is_a?(String) }
            count
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("STRUCT Bag {\n  items: []String")
      expect(clear).to include("FOR _ IN self.items DO")
      expect(clear).not_to include("IS_A String")
    end

    it "keeps ivar storage type distinct from a narrower getter return" do
      source = <<~RUBY
        State = Struct.new(:name) do
          sig { returns(T::Boolean) }
          def active
            @active = T.let(nil, T.nilable(T::Boolean)) unless defined?(@active)
            @active == true
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("active: ?Bool")
      expect(clear).to include("FN state__active(MUTABLE self: State) RETURNS Bool ->")
    end

    it "uses a runtime variant test to constrain an unsigned field to its interface union" do
      source = <<~RUBY
        module Emittable
        end
        Lit = Struct.new(:value) do
          include Emittable
          sig { returns(T::Boolean) }
          def literal?
            true
          end
        end
        Holder = Struct.new(:item) do
          sig { returns(T::Boolean) }
          def literal?
            item.is_a?(Lit)
          end
        end
        sig { params(value: Emittable).returns(T::Boolean) }
        def variant_literal?(value)
          value.is_a?(Lit) && value.literal?
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("UNION Emittable { Lit: Lit }")
      expect(clear).to include("STRUCT Holder {\n  item: Emittable")
      expect(clear).to include("value IS_A Lit AS lit")
      expect(clear).to include("lit__literal?(lit)")
    end

    it "keeps narrowed pattern bindings separate from mutability" do
      source = <<~RUBY
        class Entry < T::Struct
          prop :used, T::Boolean, default: false
        end
        sig { params(entry: T.nilable(Entry)).void }
        def mark(entry)
          if entry
            entry.used = true
          end
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      expect(clear).to include("IF entry EXISTS AS entry_value THEN")
      expect(clear).to include("MUTABLE entry_value_mutable = COPY entry_value;")
      expect(clear).not_to include("AS MUTABLE")
      field = ir.fields.values.find { |fact| fact.field.name == "used" && fact.write }
      expect(field.receiver_type.to_clear).to eq("Entry")
    end

    it "materializes mutable narrowed bindings after optional exit guards" do
      source = <<~RUBY
        class Entry < T::Struct
          prop :used, T::Boolean, default: false

          sig { void }
          def mark_read!
            @used = true
          end
        end

        sig { params(entry: T.nilable(Entry)).void }
        def mark(entry)
          return unless entry
          entry.mark_read!
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("IF entry EXISTS AS entry_value THEN")
      expect(clear).to include("MUTABLE entry_value_mutable = COPY entry_value;")
      expect(clear).to include("entry__mark_read_mut(&entry_value_mutable);")
      expect(clear).not_to include("entry__mark_read_mut(&entry_value);")
    end

    it "keeps a multi-statement trailing if in an each block statement-shaped" do
      source = <<~RUBY
        sig { params(values: T::Array[T::Boolean]).void }
        def consume(values)
          values.each do |value|
            if value
              count = 1
              count += 1
            else
              count = 2
              count += 1
            end
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("FOR _ IN values DO")
      expect(clear).to include("IF _ THEN")
      expect(clear).not_to include("If expression branches")
    end

    it "resolves constructor shape through a qualified constant type alias" do
      source = <<~RUBY
        module Plan
          class Shape < T::Struct
            const :name, String
          end
        end
        module Helper
          ShapeAlias = Plan::Shape
        end
        def build_shape
          Helper::ShapeAlias.new(name: "ok")
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include('Shape{ name: "ok" }')
      expect(clear).not_to include("ShapeAlias{")
    end

    it "uses the emitted nominal identity through qualified constant aliases" do
      source = <<~RUBY
        module Plan
          class Transition < T::Struct
            const :name, String
          end
        end
        module Helper
          TransitionAlias = Plan::Transition
          sig { params(value: TransitionAlias).returns(TransitionAlias) }
          def self.identity(value)
            value
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("FN helper__identity(value: Transition) RETURNS Transition")
      expect(clear).not_to include("Plan::Transition")
    end

    it "assigns distinct emitted targets to same-named class methods" do
      source = <<~RUBY
        module Identity
          class BindingId < T::Struct
            sig { returns(BindingId) }
            def self.from_symbol
              new
            end
          end
          class PlaceId < T::Struct
            sig { returns(PlaceId) }
            def self.from_symbol
              new
            end
          end
          sig { returns(BindingId) }
          def self.binding
            BindingId.from_symbol
          end
          sig { returns(PlaceId) }
          def self.place
            PlaceId.from_symbol
          end
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      targets = ir.calls.values.select { |call| call.target.name == "from_symbol" }.map(&:target)
      expect(targets.map(&:owner)).to contain_exactly("Identity::BindingId", "Identity::PlaceId")
      expect(clear).to include("FN bindingId__from_symbol() RETURNS BindingId")
      expect(clear).to include("FN placeId__from_symbol() RETURNS PlaceId")
      expect(clear).to include("bindingId__from_symbol()")
      expect(clear).to include("placeId__from_symbol()")
    end

    it "exports closed attribute helpers for dependency consumers" do
      source = <<~RUBY
        class Type < T::Struct
        end
        class SymbolEntry
          class BindingLifecycleFacts < T::Struct
            const :type, Type
          end
          sig { returns(BindingLifecycleFacts) }
          attr_reader :lifecycle
          lifecycle_attr :type
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("PUB FN symbolEntry__type(self: SymbolEntry) RETURNS Type")
      expect(clear).to include("self.lifecycle.type")
    end

    it "terminates lambdas whose final expression lowers to a statement loop" do
      source = <<~RUBY
        sig { params(blk: T.proc.void).void }
        def with_scope(&blk)
          blk.call
        end
        sig { params(values: T::Array[String]).void }
        def visit_all(values)
          with_scope do
            values.each { |value| value.length }
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to match(/FOR _ IN values DO.*END\n\s+rubyToClearVoid\(\)\n\s*\}/m)
    end

    it "resolves a unique typed target across an explicit dynamic field boundary" do
      source = <<~RUBY
        class Value < T::Struct
          sig { returns(T::Boolean) }
          def ready?
            true
          end
        end
        Entry = Struct.new(:value) do
          sig { returns(T.untyped) }
          def value
            self[:value]
          end
        end
        sig { params(entry: Entry).returns(T::Boolean) }
        def ready_entry?(entry)
          entry.value.ready?
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      call = ir.calls.values.find { |fact| fact.target.name == "ready?" }
      expect(call.target.owner).to eq("Value")
      expect(clear).to include("value__ready?(CAST(entry.value AS Value))")
    end

    it "dispatches through a same-named getter method instead of its backing nilable field, when the getter's own sig narrows away nilability" do
      # struct_field_reader?'s "read this field directly, skip the method
      # call" optimization (proven correct and load-bearing by the two
      # tests above - a Struct.new reader whose sig doesn't narrow the
      # field's type must keep using it) is wrong specifically when the
      # method's OWN sig is more precise than the field's storage type -
      # real corpus case: FunctionSignature#intrinsic_contract, a
      # `sig { returns(IntrinsicContract) }` memoizing getter
      # (`@intrinsic_contract ||= ...`) backed by a `T.nilable(
      # IntrinsicContract)` ivar of the same stripped name. Every call site
      # was resolving through the field branch and using the ivar's nilable
      # type directly - `Cannot access field 'allocation' on optional
      # '?IntrinsicContract' without safe navigation` (the corpus's #1
      # fingerprint, 97 files, after the transform_values fix landed) -
      # instead of dispatching to the getter, whose own return type is
      # genuinely non-nilable.
      source = <<~RUBY
        class Contract < T::Struct
          extend T::Sig
          const :allocates, T::Boolean, default: false
        end

        class Widget
          extend T::Sig

          def initialize
            @contract = T.let(nil, T.nilable(Contract))
          end

          sig { returns(Contract) }
          def contract
            @contract ||= Contract.new
          end

          sig { returns(T::Boolean) }
          def allocates?
            contract.allocates
          end
        end
      RUBY

      clear = RubyToClear.transpile(source)
      expect(clear).to include("RETURN widget__contract(&rtoc_self_view).allocates;")
      expect(clear).not_to include("rtoc_self_view.contract.allocates")
    end

    it "materializes complex aggregate field receivers before persistent updates" do
      source = <<~RUBY
        class Slot < T::Struct
          prop :sources, T::Array[String]
        end
        sig { params(slots: T::Hash[String, Slot], key: String, value: String).void }
        def add_source(slots, key, value)
          T.must(slots[key]).sources << value
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("FN add_source(MUTABLE slots: {String}Slot, key: String, value: String) RETURNS Void ->")
      expect(clear).to include("IF slots[key] EXISTS AS rtoc_map_slot_1 THEN")
      expect(clear).to include("&rtoc_map_slot_1.sources.append(COPY value);")
      expect(clear).to include("panic(\"T.must: map slot is NIL\");")
      expect(clear).not_to match(/\)\.sources\) =/)
    end

    it "nests elsif branches after optional payload bindings" do
      source = <<~RUBY
        sig { params(list: T.nilable(T::Array[String]), key: T.nilable(String)).returns(Integer) }
        def size_for(list, key)
          if list
            list.length
          elsif key
            key.length
          else
            0
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to match(/IF list EXISTS AS list_value THEN.*ELSE\n\s+IF key EXISTS AS key_value THEN/m)
      expect(clear).not_to include("ELSE_IF key AS")
    end

    it "materializes cast receivers required by mutable resolved calls" do
      source = <<~RUBY
        class Value < T::Struct
          prop :ready, T::Boolean, default: false
          sig { void }
          def mark!
            self.ready = true
          end
        end
        Entry = Struct.new(:value)
        sig { params(entry: Entry).void }
        def mark_entry!(entry)
          entry.value.mark!
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      call = ir.calls.values.find { |fact| fact.target.name == "mark!" }
      expect(call.receiver_ownership).to eq(:borrow_mut)
      expect(clear).to include("MUTABLE rtoc_mutable_receiver_1 = CAST(entry.value AS Value)")
      expect(clear).to include("value__mark_mut(&rtoc_mutable_receiver_1)")
    end

    it "normalizes set intersection through an ownership-safe helper" do
      source = <<~RUBY
        sig { params(left: T::Set[String], right: T::Set[String]).returns(T::Set[String]) }
        def intersection(left, right)
          left & right
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("FN ruby_set_intersection_String_set")
      expect(clear).to include("IF right.contains?(_) AND !(result.contains?(_)) THEN")
      expect(clear).to include("ruby_set_intersection_String_set(left, right)")
      expect(clear).not_to include("(left & right)")
    end

    it "propagates Set construction and to_set types into intersection lowering" do
      source = <<~RUBY
        sig { params(values: T::Array[Symbol]).returns(T::Set[Symbol]) }
        def reachable(values)
          possible = Set.new
          possible << :LockTimeout
          expansion = values.to_set
          expansion & possible
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("possible.insert(:LockTimeout)")
      expect(clear).to include("RETURN ruby_set_intersection_String_symbol_set(expansion, possible);")
      expect(clear).not_to include("(expansion & possible)")
    end

    it "keeps a concrete Set element type when another branch constructs an empty Set" do
      source = <<~RUBY
        sig { params(values: T::Array[Symbol], ready: T::Boolean).returns(T::Set[Symbol]) }
        def reachable(values, ready)
          possible = if ready
            Set.new([:LockTimeout])
          else
            Set.new
          end
          values.to_set & possible
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("ruby_set_intersection_String_symbol_set")
      expect(clear).not_to include(" & possible")
    end

    it "hoists mutable receiver materialization before an implicit return" do
      source = <<~RUBY
        class Value < T::Struct
          prop :ready, T::Boolean, default: false
          sig { returns(Value) }
          def mark!
            self.ready = true
            self
          end
        end
        Entry = Struct.new(:value)
        sig { params(entry: Entry).returns(Value) }
        def marked(entry)
          entry.value.mark!
        end
      RUBY

      clear, = transpile_with_ir(source)
      # The materialization is a value block: a single expression in every
      # position, so a bare declaration can never leak into the RETURN.
      expect(clear).to include("RETURN { MUTABLE rtoc_value_block_marker = 0; MUTABLE rtoc_mutable_receiver_1 = CAST(entry.value AS Value);")
      expect(clear).to include("value__mark_mut(&rtoc_mutable_receiver_1) };")
      expect(clear).not_to include("RETURN MUTABLE")
    end

    it "preserves optionality across an untyped callable boundary" do
      source = <<~RUBY
        sig { params(callback: T.nilable(Proc), ready: T::Boolean).returns(T::Boolean) }
        def callable_and_ready?(callback, ready)
          callback && ready
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      function = ir.functions.values.find { |fact| fact.symbol.name == "callable_and_ready?" }
      expect(function.parameters.fetch("callback").to_clear).to eq("?Any")
      expect(clear).to include("callback: ?Any")
      expect(clear).to include("RETURN ((callback != NIL) AND ready);")
    end

    it "hoists a heap-typed memoized ternary result through a value block instead of an inline expression-IF" do
      source = <<~RUBY
        class Box < T::Struct
          const :value, Integer
        end

        class Boxes
          sig { params(value: Integer).returns(Box) }
          def self.wrap(value)
            Box.new(value: value)
          end

          sig { returns(Box) }
          def self.empty
            Box.new(value: 0)
          end
        end

        class Picker
          extend T::Sig

          sig { params(flag: T::Boolean, value: Integer).void }
          def initialize(flag, value)
            @flag = flag
            @value = value
          end

          sig { returns(Box) }
          def box
            @box ||= @flag ? Boxes.wrap(@value) : Boxes.empty
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to match(
        /\{ MUTABLE rtoc_value_block_marker = 0; MUTABLE rtoc_ternary_value_\d+: \?Box = NIL;\n\s+IF rtoc_self_view\.flag THEN\n\s+rtoc_ternary_value_\d+ = boxes__wrap\(rtoc_self_view\.value\);\n\s+ELSE\n\s+rtoc_ternary_value_\d+ = boxes__empty\(\);\n\s+END\n\s+rtoc_ternary_value_\d+\? \}/
      )
      expect(clear).not_to match(/OR IF rtoc_self_view\.flag THEN\n\s+boxes__wrap/)
    end

    it "keeps effectful ternary branches statement-shaped" do
      source = <<~RUBY
        sig { params(flag: T::Boolean, left: T::Set[String], right: T::Set[String], value: String).void }
        def insert_side(flag, left, right, value)
          flag ? left << value : right << value
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to match(/IF flag THEN\n\s+&left\.insert\(COPY value\);\n\s+ELSE\n\s+&right\.insert\(COPY value\);/)
      expect(clear).not_to match(/END;/)
    end

    it "uses resolved Void return types to make ordinary ternary calls statement-shaped" do
      source = <<~RUBY
        sig { params(value: String).void }
        def consume(value); end
        sig { params(flag: T::Boolean, value: String).void }
        def dispatch(flag, value)
          flag ? consume(value) : consume(value)
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to match(/IF flag THEN\n\s+consume\(value\);\n\s+ELSE\n\s+consume\(value\);/)
    end

    it "keeps assignment-valued unless branches expression-shaped" do
      source = <<~RUBY
        sig { params(flag: T::Boolean, value: String).returns(T.nilable(String)) }
        def maybe_value(flag, value)
          owned = T.let(unless flag
            value
          end, T.nilable(String))
          owned
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to match(/MUTABLE owned: \?String = IF !\(flag\) THEN\n\s+value\n\s+ELSE\n\s+NIL\n\s+END;/)
      expect(clear).not_to match(/value;\n\s+ELSE/)
    end

    it "disambiguates value blocks whose first semantic statement is a field write" do
      source = <<~RUBY
        class Entry < T::Struct
          prop :state, Symbol
        end
        sig { params(entry: Entry, flag: T::Boolean).returns(Symbol) }
        def update(entry, flag)
          result = case entry.state
                   when :pending
                     if flag
                       entry.state = :ready
                       :changed
                     else
                       entry.state = :blocked
                       :unchanged
                     end
                   else
                     :ignored
                   end
          result
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("MUTABLE rtoc_value_block_marker = 0;")
      expect(clear).to match(/rtoc_value_block_marker = 0;\n\s+entry\.state = :ready;\n\s+:changed/)
    end

    it "hoists assignments out of compound predicates before narrowing" do
      source = <<~RUBY
        class Entry < T::Struct
          const :name, String
        end
        sig { params(values: T::Array[Entry]).returns(T.nilable(String)) }
        def nested_name(values)
          result = T.let(nil, T.nilable(String))
          if values.length == 1 && (nested = values.first).is_a?(Entry)
            result = nested.name
          end
          result
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to match(/MUTABLE nested: \?Entry = COPY values\.first\(\);\n\s*IF .*\(nested\) IS_A Entry/)
      expect(clear).not_to include("(MUTABLE nested")
    end

    it "normalizes guarded next values that follow pipeline setup statements" do
      source = <<~RUBY
        sig { params(values: T::Array[Integer]).returns(T::Boolean) }
        def bounded?(values)
          values.all? do |value|
            adjusted = value + 1
            next true unless adjusted > 0
            adjusted < 10
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("MUTABLE rtoc_value_block_marker = 0;")
      expect(clear).to include("IF !((adjusted > 0)) THEN TRUE ELSE (adjusted < 10) END")
      expect(clear).not_to include("CONTINUE")
    end

    it "parenthesizes a bare expression-IF that becomes a value block's trailing result" do
      # parse_value_block_expr treats a LEADING IF token as a forced
      # statement (VALUE_BLOCK_STATEMENT_KEYWORDS), routing it through the
      # statement-form IF parser, which requires every branch to be a
      # `;`-terminated statement list - not the bare single-expression-per-
      # branch shape an expression-IF actually has. A guarded-next sequence
      # whose remainder is itself an if/elsif/else (not just a bare value
      # like the spec above) landed as a value block's UNPARENTHESIZED
      # trailing content, producing a real parser error ("Expected `;`...
      # got 'ELSE_IF'") - the corpus's #2 verifier fingerprint (34 files,
      # real case: pipeline_concurrent_lowerer.rb's
      # assignment_targets_placeholder?).
      source = <<~RUBY
        sig { params(values: T::Array[Integer]).returns(T::Boolean) }
        def scan(values)
          values.any? do |member|
            next false if member.nil?

            value = member
            if value > 10
              true
            elsif value > 5
              false
            else
              true
            end
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      # The trailing if/elsif/else must be wrapped in parens - without the
      # fix this is emitted bare and the CLEAR parser rejects it (a value
      # block's own parser treats a leading IF as a forced statement,
      # which cannot accept a single-expression-per-branch shape).
      expect(clear).to match(/\(\s*IF \(value > 10\) THEN\n\s*TRUE\n\s*ELSE_IF \(value > 5\) THEN\n\s*FALSE\n\s*ELSE\n\s*TRUE\n\s*END\)/)
    end

    it "terminates nested pipeline assignments that contain internal control flow" do
      source = <<~RUBY
        sig { params(values: T::Array[String], blocked: T::Hash[String, T::Boolean]).returns(T::Array[String]) }
        def candidates(values, blocked)
          candidates = values.map do |value|
            name = value.strip
            next nil if blocked.key?(name)
            name
          end.compact
          return [] if candidates.empty?
          candidates
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to match(/MUTABLE candidates = .*\|> WHERE _ != NIL;\n\s+IF/m)
    end

    it "makes a final pipeline modifier-unless an optional expression" do
      source = <<~RUBY
        sig { params(values: T::Array[String]).returns(T::Array[String]) }
        def present(values)
          values.map do |value|
            stripped = value.strip
            stripped unless stripped.empty?
          end.compact
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to match(/IF !\(.*stripped\.length\(\) == 0.*\) THEN\n\s+stripped\n\s+ELSE\n\s+NIL\n\s+END/m)
    end

    it "materializes local returns with multiowned element capabilities" do
      source = <<~RUBY
        class Finding; end
        sig { params(findings: T::Array[Finding]).returns(T::Array[Finding]) }
        def drain(findings)
          out = findings.dup
          out
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("FN drain(findings: []Finding@multiowned) RETURNS ![]Finding@multiowned ->")
      expect(clear).to include("MUTABLE out: []Finding@multiowned = COPY findings;")
      expect(clear).to include("RETURN out;")
    end

    it "keeps mutable receiver setup inside array-concat value blocks" do
      source = <<~RUBY
        class Bag < T::Struct
          prop :items, T::Array[String], default: []
          sig { returns(T::Array[String]) }
          def drain
            out = @items
            @items = []
            out
          end
        end
        class Collector < T::Struct
          prop :bag, T.nilable(Bag)
          sig { params(slots: T::Array[String]).returns(T::Array[String]) }
          def collect(slots)
            slots.concat(T.must(bag).drain) if bag
            slots
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      # The receiver materialization travels as a self-contained value block
      # in the argument position — never a bare declaration.
      expect(clear).to match(/ruby_array_concat_String\(slots, \{ MUTABLE rtoc_value_block_marker = 0; MUTABLE rtoc_mutable_receiver_\d+ = .*bag.*; TRY \(bag__drain\(&rtoc_mutable_receiver_\d+\)\) \}\)/)
      expect(clear).not_to match(/ruby_array_concat_String\(slots, MUTABLE rtoc_mutable_receiver/)
    end

    it "lowers optional aggregate writes through typed fields as statement branches" do
      source = <<~RUBY
        class Facts < T::Struct
          prop :effects, T.nilable(T::Array[String])
        end
        class Signature < T::Struct
          prop :facts, Facts
          sig { void }
          def refresh!
            self.facts.effects = self.facts.effects&.dup
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to match(/IF self\.facts\.effects != NIL THEN\n\s+self\.facts\.effects = .*;\n\s+ELSE\n\s+self\.facts\.effects = NIL;/)
      expect(clear).not_to include("self.facts.effects = (IF")
    end

    it "lowers optional constructor fallbacks through typed branch locals" do
      source = <<~RUBY
        class Source < T::Struct
          const :sync, T.nilable(Symbol)
        end
        class Fact < T::Struct
          const :sync, T.nilable(Symbol)
        end
        sig { params(source: Source, fallback: Source).returns(Fact) }
        def fact(source, fallback)
          Fact.new(sync: source.sync || fallback.sync)
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("MUTABLE rtoc_optional_or_source_1: ?String@symbol")
      expect(clear).to include("IF rtoc_optional_or_source_1 != NIL THEN")
      expect(clear).to include("Fact{ sync: ( { MUTABLE")
      expect(clear).not_to include("sync: COPY (IF")
    end

    it "materializes borrowed self through an ownership-qualified return local" do
      source = <<~RUBY
        class Item
          def initialize
            @name = T.let("item", String)
          end
          sig { returns(Item) }
          def refresh!
            @name = @name.strip
            self
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to match(/MUTABLE rtoc_owned_return_\d+: Item@multiowned = rtoc_self_view;\n\s+RETURN rtoc_owned_return_\d+;/)
      expect(clear).not_to include("RETURN COPY self;")
    end

    it "keeps optional mutable void calls statement-shaped" do
      source = <<~RUBY
        class Value < T::Struct
          prop :ready, T::Boolean, default: false
          sig { void }
          def mark!
            self.ready = true
          end
        end
        sig { params(value: T.nilable(Value)).void }
        def mark_optional!(value)
          value&.mark!
        end
      RUBY

      clear, = transpile_with_ir(source)
      # The guard narrows `value`, so it is already a mutable storage path and
      # needs no receiver temp. It used to be unwrapped to `(value?)`, which is
      # not a storage path -- hence the temp -- and which the frontend now
      # rejects as an unwrap of an already-narrowed value.
      expect(clear).to match(/IF value != NIL THEN\n\s+value__mark_mut\(&value\);\n\s*END/m)
      expect(clear).not_to include("(IF value != NIL")
      expect(clear).not_to include("value?")
    end

    it "normalizes static operator reduce forms without reconstructing a block" do
      source = <<~RUBY
        sig { params(values: T::Array[T::Set[Symbol]]).returns(T::Set[Symbol]) }
        def intersection(values)
          values.reduce(:&)
        end
        sig { params(values: T::Array[T::Set[Symbol]]).returns(T::Set[Symbol]) }
        def union(values)
          values.reduce(Set.new, :|)
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("values |> REDUCE(values[0]) (ruby_set_intersection(acc, _))")
      expect(clear).to include("values |> REDUCE(Set[]) (ruby_set_union(acc, _))")
      expect(clear).to include("FN ruby_set_intersection<T>")
      expect(clear).to include("FN ruby_set_union<T>")
    end

    it "keeps Array uniq array-shaped after the DISTINCT terminal" do
      source = <<~RUBY
        class Item; end
        sig { params(values: T::Array[Item]).returns(T::Array[Item]) }
        def unique(values)
          values.uniq
        end
        sig { params(value: Item).returns(T::Array[Item]) }
        def singleton(value)
          [value]
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("RETURN CAST((values |> DISTINCT _) AS []Item@multiowned);")
      expect(clear).to include("RETURN CAST([value] AS []Item@multiowned);")
    end

    it "normalizes immutable literal string sets into compile-time predicates" do
      source = <<~RUBY
        KEYWORDS = T.let(%w[FN RETURN], T::Set[String])
        sig { params(word: String).returns(T::Boolean) }
        def keyword?(word)
          KEYWORDS.include?(word)
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).not_to include("MUTABLE keywords")
      expect(clear).to include("RETURN (word == \"FN\") OR (word == \"RETURN\");")
    end

    it "normalizes array field append to an owned read-modify-write" do
      source = <<~RUBY
        class Box < T::Struct
          prop :items, T::Array[String]
        end
        sig { params(box: Box, value: String).void }
        def add_value(box, value)
          box.items << value
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("&box.items.append(COPY value);")
    end

    it "records and emits aggregate ownership when appending to array fields" do
      source = <<~RUBY
        class Token < T::Struct
          const :value, T.nilable(String)
        end
        class Lexer < T::Struct
          prop :tokens, T::Array[Token]
        end
        sig { params(lexer: Lexer, value: String).void }
        def add_token(lexer, value)
          lexer.tokens << Token.new(value: value)
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      edge = ir.storage_ownership.values.first
      expect(edge.mode).to eq(:copy)
      expect(edge.destination.to_s).to eq("Lexer:field:tokens")
      expect(clear).to include(
        "&lexer.tokens.append(COPY Token{ value: COPY value });"
      )
    end

    it "erases owned capabilities explicitly at plain return boundaries" do
      node = Prism.parse("wrapped").value.statements.body.first
      transpiler = described_class.new("")
      allow(transpiler).to receive(:inferred_clear_type).with(node).and_return("Type@multiowned")
      allow(transpiler).to receive(:stored_borrowed_value?).with(node).and_return(true)

      clear = transpiler.send(:wrap_argument_for_parameter_type, "wrapped", node, "Type")
      expect(clear).to eq("CAST(COPY wrapped AS Type)")
    end

    it "does not re-add COPY to a borrowed value materialize_borrowed_code still reaches at a @multiowned/@shared destination" do
      # materialize_borrowed_code only sees a value here when ownership_
      # upgrade_return_code (tested below) already decided no wrap is
      # needed - e.g. the value's own type is already @symbol, or (in
      # other callers not gated by ownership_upgrade_return_code, like the
      # OrNode/safe-navigation return paths) an already-correctly-owned
      # value. COPY in front of an @multiowned/@shared destination is
      # illegal regardless of which path reaches it, so this guard stays
      # even though the dominant real-corpus case now goes through the
      # wrap instead.
      node = Prism.parse("x = 1\nx").value.statements.body.last
      transpiler = described_class.new("")
      transpiler.instance_variable_set(:@current_param_names, ["x"])

      transpiler.instance_variable_set(:@current_function_return_type, "?FunctionSignature@multiowned")
      expect(transpiler.send(:materialize_borrowed_code, "function_signature", node)).to eq("function_signature")

      transpiler.instance_variable_set(:@current_function_return_type, "?FunctionSignature@shared")
      expect(transpiler.send(:materialize_borrowed_code, "function_signature", node)).to eq("function_signature")

      # A plain (non-multiowned/shared) return type keeps the original
      # COPY - only the reference-counted destination case changes.
      transpiler.instance_variable_set(:@current_function_return_type, "?FunctionSignature")
      expect(transpiler.send(:materialize_borrowed_code, "function_signature", node)).to eq("COPY function_signature")
    end

    it "wraps a borrowed value into a freshly-owned local before returning it as @multiowned/@shared" do
      # RETURN requires the returned value's ownership to match the
      # function's declared return type EXACTLY (same_return_capabilities?,
      # checked before MIR lowering runs) - unlike a @multiowned struct-
      # literal field, there is no call-edge keep-analysis step for a bare
      # RETURN that would upgrade a borrowed value's ownership after the
      # fact. Real corpus case: FunctionSignature.unwrap's `return x if
      # x.is_a?(FunctionSignature)` guard, where `x`'s IS_A-narrowed
      # binding is a plain FunctionSignature but the function's return
      # type resolves to ?FunctionSignature@multiowned - RETURN_MISMATCH
      # was the #1 verifier fingerprint (57 files) until this fix.
      node = Prism.parse("x = 1\nx").value.statements.body.last
      transpiler = described_class.new("")
      transpiler.instance_variable_set(:@current_param_names, ["x"])

      transpiler.instance_variable_set(:@current_function_return_type, "?FunctionSignature@multiowned")
      result = transpiler.send(:ownership_upgrade_return_code, "function_signature", node)
      expect(result).to match(
        /\AMUTABLE (rtoc_owned_return_\d+): \?FunctionSignature@multiowned = function_signature;\nRETURN \1;\z/
      )

      # A plain (non-multiowned/shared) return type needs no wrap at all -
      # the ordinary bare/COPY path in materialize_borrowed_code applies.
      transpiler.instance_variable_set(:@current_function_return_type, "?FunctionSignature")
      expect(transpiler.send(:ownership_upgrade_return_code, "function_signature", node)).to be_nil
    end

    it "does not wrap an already freshly-owned local before returning it as @multiowned" do
      # item = Item.new; item - item's typed-IR access is :owned (a fresh
      # construction), so it already satisfies an @multiowned destination
      # without any wrap; only a BORROWED source (a parameter, or a
      # binding narrowed from one) needs the wrap.
      source = <<~RUBY
        class Item
          def initialize
            @name = T.let("item", String)
          end
        end
        sig { returns(Item) }
        def build_item
          item = Item.new
          item
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      owned_read = ir.values.values.find { |value| value.source_location == 9 && value.category == :place }
      expect(owned_read.access).to eq(:owned)
      expect(clear).to include("RETURN item")
      expect(clear).not_to include("rtoc_owned_return")
    end

    it "moves constructor-owned locals across return boundaries" do
      source = <<~RUBY
        class Item
          def initialize
            @name = T.let("item", String)
          end
        end
        sig { returns(Item) }
        def build_item
          item = Item.new
          item
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      owned_read = ir.values.values.find do |value|
        value.source_location == 9 && value.category == :place
      end
      expect(owned_read.access).to eq(:owned)
      expect(clear).to include("RETURN item")
      expect(clear).not_to include("RETURN COPY item")
    end

    it "copies owned locals when a local alias does not consume their last use" do
      source = <<~RUBY
        sig { params(value: String).returns(String) }
        def retain_source(value)
          owned = value
          alias_value = owned
          owned.empty? ? alias_value : owned
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      edge = ir.storage_ownership.values.find do |ownership|
        ownership.destination.respond_to?(:kind) && ownership.destination.kind == :local
      end
      expect(edge.mode).to eq(:copy)
      expect(clear).to include("MUTABLE alias_value = COPY owned")
    end

    it "normalizes allocating tuple maps before MIR lowering" do
      source = <<~RUBY
        sig { params(values: T::Hash[String, String]).returns(T::Array[[String, String]]) }
        def pairs(values)
          values.to_a
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("MUTABLE rtoc_tuple_return_1 = ( { MUTABLE rtoc_tuple_results = CAST([] AS []Tuple<String, String>); values.keys() |> EACH { &rtoc_tuple_results.append(COPY CAST(Tuple{COPY _, COPY (values[_] OR_ELSE CAST(panic(\"missing hash key\") AS String))} AS Tuple<String, String>)); }; rtoc_tuple_results } );")
      expect(clear).to include("rtoc_tuple_results.append(COPY CAST(")
      expect(clear).to include("MUTABLE rtoc_tuple_return")
      expect(clear).not_to include("|> SELECT CAST([")
    end

    it "unwraps optional symbols without allocating return temporaries" do
      source = <<~RUBY
        class Contract < T::Struct
          const :operation, T.nilable(Symbol), default: nil
          sig { params(fallback: Symbol).returns(Symbol) }
          def operation_or(fallback)
            operation || fallback
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("RETURN (self.operation)?")
      expect(clear).not_to include("COPY symbol(self.operation")
      expect(clear).not_to include("RETURN COPY fallback")
    end

    it "copies typed field reads through Sorbet storage wrappers" do
      source = <<~RUBY
        class Store < T::Struct
          const :entries, T::Hash[Symbol, String]
        end
        class Scope
          def initialize
            @store = T.let(Store.new(entries: {}), Store)
            @entries = T.let(@store.entries, T::Hash[Symbol, String])
          end
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("rtoc_self_view.entries = COPY rtoc_self_view.store.entries;")
      expect(clear).to include("MUTABLE self = Scope{ entries: {}, store: Store{ entries: {} } };")
    end

    it "normalizes branch initialization of owned arrays into accumulator writes" do
      source = <<~RUBY
        sig { params(values: T::Array[String], fallback: String, use_values: T::Boolean).returns(T::Array[String]) }
        def choose_values(values, fallback, use_values)
          selected = T.let([], T::Array[String])
          if use_values
            selected = values
          else
            selected = [fallback]
          end
          selected
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("FOR rtoc_array_item")
      expect(clear).to include("selected.append(COPY rtoc_array_item")
      expect(clear).to include("selected.append(COPY fallback)")
      expect(clear).not_to include("selected = COPY values")
    end

    it "normalizes allocating symbol-to-proc maps into owned accumulators" do
      source = <<~RUBY
        class Spec < T::Struct
          sig { returns(String) }
          def display = "value"
        end
        sig { params(specs: T::Array[Spec]).returns(T::Array[String]) }
        def labels(specs)
          specs.map(&:display)
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("MUTABLE rtoc_tuple_return_1 = ( { MUTABLE rtoc_map_results = CAST([] AS []String); specs |> EACH { &rtoc_map_results.append(COPY spec__display(_)); }; rtoc_map_results } );")
      expect(clear).to include("rtoc_map_results.append(COPY spec__display(_))")
      expect(clear).not_to include("|> SELECT display(_)")
    end


    it "normalizes symbol-returning allocating maps to a valid collection element type" do
      source = <<~RUBY
        class Spec
          sig { returns(Symbol) }
          def resolved = :value
        end
        sig { params(specs: T::Array[Spec]).returns(T::Array[Symbol]) }
        def resolved_symbols(specs)
          specs.map(&:resolved)
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("MUTABLE rtoc_tuple_return_1 = ( { MUTABLE rtoc_map_results = CAST([] AS []String@symbol); specs |> EACH { &rtoc_map_results.append(COPY spec__resolved(_)); }; rtoc_map_results } );")
      expect(clear).not_to include("String@symbol[]")
    end

    it "normalizes reserved struct field identities consistently" do
      source = <<~RUBY
        Entry = Struct.new(:alias, keyword_init: true)
        sig { params(entry: Entry).returns(T.nilable(String)) }
        def alias_for(entry)
          entry[:alias]
        end
      RUBY

      clear, = transpile_with_ir(source)
      expect(clear).to include("alias_value: Any")
      expect(clear).to include("entry.alias_value")
      expect(clear).not_to match(/entry\.alias(?:\s|;|\))/)
    end

    it "uses configured globally unique names for Struct.new declarations" do
      config = RubyToClear::HelperConfig.new(
        "types" => { "Capability" => "ASTCapability" }
      )
      source = <<~RUBY
        Capability = Struct.new(:name)
        sig { params(value: Capability).returns(String) }
        def capability_name(value)
          value.name
        end
      RUBY

      clear = described_class.new(source, helper_config: config).transpile(Prism.parse(source).value)
      expect(clear).to include("STRUCT ASTCapability")
      expect(clear).to include("value: ASTCapability")
      expect(clear).to include("PUB FN aSTCapability__name(self: ASTCapability)")
    end

    it "carries T.cast context into optional fallback operands" do
      source = <<~RUBY
        Capability = Struct.new(:capability)
        sig { params(source: Capability).returns(Symbol) }
        def capability_for(source)
          T.cast(source[:capability] || :infer, Symbol)
        end
      RUBY

      clear, ir = transpile_with_ir(source)
      contextual = ir.contextual_types.values.find { |type| type.to_clear == "String@symbol" }
      expect(contextual).not_to be_nil
      expect(clear).to include("RETURN CAST((CAST(source.capability AS ?String@symbol) OR_ELSE :infer) AS String@symbol);")
    end

    it "copies symbol-array field reads at return position" do
      ruby_code = <<~RUBY
        class Contract < T::Struct
          prop :type_params, T::Array[Symbol]
        end
        class Sig
          sig { void }
          def initialize
            @contract = T.let(Contract.new(type_params: []), Contract)
          end
          sig { returns(T::Array[Symbol]) }
          def type_params = @contract.type_params
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN COPY rtoc_self_view.contract.type_params;")
    end

    it "lowers each_pair struct reflection to a generated union children walker" do
      ruby_code = <<~RUBY
        module Ops
          class Leaf < T::Struct
            const :label, String
          end
          class Pair < T::Struct
            const :left, Leaf
            const :right, T.nilable(Leaf)
          end
          Node = T.type_alias { T.any(Leaf, Pair, String) }

          sig { params(node: Node, out: T::Array[String]).void }
          def self.walk(node, out)
            out << "visited"
            T.unsafe(node).each_pair do |_, v|
              walk(v, out)
            end if node.respond_to?(:each_pair)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FOR rtoc_walk_child_1 IN rtocChildrenNode(node) DO")
      expect(clear).to include("FN rtocChildrenNode(node: Node) RETURNS []Node ->")
      expect(clear).to include("Node.Pair AS v -> RETURN rtocChildrenOfNodePair(v);,")
      expect(clear).to include("&out.append(Node{ Leaf: COPY v.left });")
      expect(clear).to include("IF v.right EXISTS AS rtoc_opt_child THEN")
      expect(clear).not_to include("each_pair requires a statically known hash receiver")
    end

    it "or-assigns struct fields of indexed elements through a read-modify-write and honors public :name" do
      ruby_code = <<~RUBY
        class Param < T::Struct
          prop :symbol, T.nilable(String)
        end
        class Holder
          sig { void }
          def initialize
            @params = T.let([], T::Array[Param])
          end

          private

          sig { params(value: T.nilable(String)).void }
          def adopt!(value)
            @params.each_with_index do |p, idx|
              p[:symbol] ||= value
            end
          end
          public :adopt!
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      # An `EXISTS AS` capture is a BORROW of the container, so neither
      # assigning through it nor storing back to the container while it is
      # live is legal - the frontend rejects both with ASSIGN_WHILE_BORROWED
      # (verified directly). Copy the element out with no binding held,
      # mutate the copy, then write it back.
      expect(clear).to include("IF rtoc_self_view.params[rtoc_idx] != NIL THEN")
      expect(clear).to include("MUTABLE rtoc_field_slot_1 = COPY UNWRAP (rtoc_self_view.params[rtoc_idx]);")
      expect(clear).to include("rtoc_field_slot_1.symbol = (rtoc_field_slot_1.symbol OR_ELSE value);")
      expect(clear).to include("rtoc_self_view.params[rtoc_idx] = rtoc_field_slot_1;")
      expect(clear).not_to include("PRIVATE FN holder__adopt_mut")
    end

    it "keeps set-valued hash types and mutates default-seeded slots through IF-EXISTS" do
      ruby_code = <<~RUBY
        class G
          sig { void }
          def build
            adj = T.let(Hash.new { |h, k| h[k] = Set.new }, T::Hash[Symbol, T::Set[Symbol]])
            T.must(adj[:a]) << :b
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("MUTABLE adj: {String@symbol}[Set]String@symbol = {};")
      expect(clear).to include("IF adj[:a] == NIL THEN")
      expect(clear).to include("adj[:a] = Set[];")
      expect(clear).to include("IF adj[:a] EXISTS AS rtoc_map_slot_1 THEN")
      expect(clear).to include("&rtoc_map_slot_1.insert(:b);")
      expect(clear).not_to include("UNWRAP (adj[:a]) =")
    end
  end

  describe "#block_statement_output?" do
    def block_output?(code)
      described_class.new("").send(:block_statement_output?, code)
    end

    it "is true for a bare statement IF" do
      expect(block_output?("IF x THEN\n  y;\nEND")).to be true
    end

    it "is true for a bare COMPTIME IF" do
      expect(block_output?("COMPTIME IF x THEN\n  y;\nEND")).to be true
    end

    it "is true for a bare WHILE" do
      expect(block_output?("WHILE x DO\n  y;\nEND")).to be true
    end

    it "is true for a bare FOR" do
      expect(block_output?("FOR x IN y DO\n  z;\nEND")).to be true
    end

    it "is true for a bare MATCH" do
      expect(block_output?("MATCH x\nWHEN y -> z\nEND")).to be true
    end

    it "is true for a bare PARTIAL MATCH" do
      expect(block_output?("PARTIAL MATCH x\nWHEN y -> z\nEND")).to be true
    end

    it "is true for a bare TEST block" do
      expect(block_output?("TEST \"x\" DO\n  y;\nEND")).to be true
    end

    it "is true for a bare WHEN block" do
      expect(block_output?("WHEN x DO\n  y;\nEND")).to be true
    end

    it "is true for a bare FN/PRIVATE FN/PUB FN definition" do
      expect(block_output?("FN foo() RETURNS Void ->\n  RETURN;\nEND")).to be true
      expect(block_output?("PRIVATE FN foo() RETURNS Void ->\n  RETURN;\nEND")).to be true
      expect(block_output?("PUB FN foo() RETURNS Void ->\n  RETURN;\nEND")).to be true
    end

    it "is true for a bare STRUCT/UNION/ENUM definition" do
      expect(block_output?("STRUCT Foo {\n  x: Int64\n}")).to be true
      expect(block_output?("UNION Foo { A: Int64 }")).to be true
      expect(block_output?("ENUM Foo { A, B }")).to be true
      expect(block_output?("PUB STRUCT Foo {\n}")).to be true
      expect(block_output?("PUB UNION Foo { A: Int64 }")).to be true
      expect(block_output?("PUB ENUM Foo { A, B }")).to be true
    end

    it "is true for one or more single-line decl prefixes before a block keyword" do
      expect(block_output?("x = 1;\nIF y THEN\n  z;\nEND")).to be true
      expect(block_output?("MUTABLE x = 1;\nIF y THEN\n  z;\nEND")).to be true
      expect(block_output?("x = 1;\ny = 2;\nWHILE z DO\n  w;\nEND")).to be true
      expect(block_output?("x: Int64 = 1;\nIF y THEN\n  z;\nEND")).to be true
    end

    it "is true for a multi-line value-block declaration prefix before a trailing IF (the END; regression)" do
      code = <<~CLEAR.chomp
        elem_zig = { MUTABLE rtoc_value_block_marker = 0; IF elem_t != NIL THEN
          "a"
        ELSE
          "b"
        END };
        IF desc != NIL THEN
          elem_zig = "c";
        END
      CLEAR
      expect(block_output?(code)).to be true
    end

    it "is true for a multi-line parenthesized declaration prefix before a trailing block" do
      code = <<~CLEAR.chomp
        x = (
          1 + 2
        );
        WHILE y DO
          z;
        END
      CLEAR
      expect(block_output?(code)).to be true
    end

    it "is true mixing a single-line prefix, a multi-line prefix, and a trailing block" do
      code = <<~CLEAR.chomp
        a = 1;
        b = {
          2
        };
        IF c THEN
          d;
        END
      CLEAR
      expect(block_output?(code)).to be true
    end

    it "is false for a plain single-line assignment" do
      expect(block_output?("x = 5")).to be false
    end

    it "is false for a multi-line assignment with nothing trailing it" do
      code = <<~CLEAR.chomp
        x = foo(
          bar
        )
      CLEAR
      expect(block_output?(code)).to be false
    end

    it "is false for a multi-line value-block assignment with nothing trailing it" do
      code = <<~CLEAR.chomp
        x = {
          1
        }
      CLEAR
      expect(block_output?(code)).to be false
    end

    it "terminates block-local declarations whose nested value block contains a statement IF" do
      code = <<~CLEAR.chomp
        MUTABLE arg_type = TRY (type__new(castTypeToTypeConstructionInput({
          MUTABLE rtoc_value_block_marker = 0;
          MUTABLE result:? = NIL;
          IF predicate THEN
            result = value();
          ELSE
            result = fallback();
          END
          result?
        })))
      CLEAR
      transpiler = described_class.new("")

      expect(RubyToClear::MethodRegistry.statement_line(code, transpiler)).to eq("#{code};")
    end

    it "is false for a parenthesized expression-if assignment with nothing trailing it" do
      code = <<~CLEAR.chomp
        x = (IF y THEN
          1
        ELSE
          2
        END)
      CLEAR
      expect(block_output?(code)).to be false
    end

    it "is false for a bare call" do
      expect(block_output?("foo(x, y)")).to be false
    end

    it "is false for a bare return statement" do
      expect(block_output?("RETURN x")).to be false
    end

    it "is false for an expression-shaped IF (bare value payload lines)" do
      expect(block_output?("IF x THEN\n  1\nELSE\n  2\nEND")).to be false
    end

    it "is false for an expression-shaped COMPTIME IF" do
      expect(block_output?("COMPTIME IF x THEN\n  1\nELSE\n  2\nEND")).to be false
    end
  end

  describe "self-host non-ownership regressions" do
    it "reads local data-api constants through their generated accessor" do
      ruby_code = <<~RUBY
        module Registry
          # ruby-to-clear: data-api
          VALUES = T.let(%i[one two].freeze, T::Array[Symbol])

          sig { params(value: Symbol).returns(T::Boolean) }
          def self.include?(value)
            VALUES.include?(value)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("PUB FN ruby_constant_values() RETURNS [2]String@symbol")
      expect(clear).to include("RETURN ruby_constant_values().contains?(value);")
      expect(clear).not_to include("RETURN values.contains?(value);")
    end

    it "does not unwrap an optional local after its presence check narrowed it" do
      ruby_code = <<~RUBY
        class Type < T::Struct
          const :element, T.nilable(Type)

          sig { returns(T.nilable(Type)) }
          def element_type
            element
          end
        end

        sig { params(receiver: Type).returns(Type) }
        def resolve(receiver)
          element = receiver.element_type
          element || receiver
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF element != NIL THEN")
      expect(clear).to include("RETURN element;")
      expect(clear).not_to include("RETURN element?;")
    end

    it "qualifies bare sibling calls inside nested modules" do
      ruby_code = <<~RUBY
        module Outer
          module Helpers
            sig { params(value: Integer).returns(Integer) }
            def self.call(value)
              increment(value)
            end

            sig { params(value: Integer).returns(Integer) }
            def self.increment(value)
              value + 1
            end
            private_class_method :increment
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("RETURN helpers__increment(value);")
      expect(clear).not_to include("RETURN increment(value);")
    end

    it "emits explicitly classified tail recursion as REENTRANT:TAIL_CALL" do
      ruby_code = <<~RUBY
        module Walk
          sig { params(value: Integer).returns(Integer) }
          # ruby-to-clear: effects reentrant-tail-call
          def self.finish(value)
            return value if value == 0
            finish(value - 1)
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN walk__finish(value: Int64) RETURNS Int64 EFFECTS REENTRANT:TAIL_CALL ->")
    end

    it "unwraps array bounds when binding Ruby each parameters" do
      ruby_code = <<~RUBY
        sig { params(values: T::Array[Symbol]).returns(T::Set[Symbol]) }
        def collect(values)
          result = T.let(Set.new, T::Set[Symbol])
          values.each do |value|
            next if value == :skip
            result.add(value)
          end
          result
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("&result.insert(COPY values[rtoc_idx]?);")
      expect(clear).not_to include("&result.insert(COPY values[rtoc_idx]);")
    end

    it "preserves element types while iterating fixed arrays" do
      ruby_code = <<~RUBY
        class TypoRule < T::Struct
          const :match, String
        end

        RULES = T.let([
          TypoRule.new(match: "s>"),
          TypoRule.new(match: "=>"),
        ].freeze, T::Array[TypoRule])

        RULES.each do |rule|
          next if rule.match.empty?
          puts rule.match
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("puts(rules[rtoc_idx].match);")
      expect(clear).not_to include("rules[rtoc_idx]?")
      expect(clear).not_to include(".match();")
    end

    it "narrows optional sets before UNNEST pipelines" do
      ruby_code = <<~RUBY
        sig { params(values: T.nilable(T::Set[Symbol])).returns(T::Boolean) }
        def expanded?(values)
          return false unless values
          values.flat_map { |value| [value] }.to_set.include?(:ready)
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("IF values EXISTS AS values_value THEN")
      expect(clear).to include("values_value |> UNNEST")
      expect(clear).not_to include("values |> UNNEST")
    end

    it "preserves explicit collection fields on raw Struct records" do
      ruby_code = <<~RUBY
        module AST
          Program = Struct.new(:statements) do
            # ruby-to-clear: field-type statements=Node[]
          end

          sig { params(program: Program).void }
          def self.walk(program)
            program.statements.each { |_statement| nil }
          end
        end
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("statements: []Node")
      expect(clear).to include("FOR _ IN program.statements DO")
    end

    it "preserves fixed tuple signatures used by destructuring assignments" do
      ruby_code = <<~RUBY
        sig { params(value: Integer).returns([Integer, Integer, Integer]) }
        def advance(value)
          [value + 1, value + 2, value + 3]
        end

        a, b, c = advance(1)
      RUBY

      clear = RubyToClear.transpile(ruby_code)
      expect(clear).to include("FN advance(value: Int64) RETURNS Tuple<Int64, Int64, Int64>")
      expect(clear).to include("a, b, c = advance(1);")
    end
  end
end
