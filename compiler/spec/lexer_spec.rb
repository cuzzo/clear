require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer) # Adjust path to matches your file structure

RSpec.describe Lexer do
  # Helper to make expectations readable
  # Usage: expect_token(tokens[0], :VAR_ID, "x", 1, 5)
  def expect_token(token, type, value, line, col)
    expect(token.type).to eq(type)
    expect(token.value).to eq(value)
    expect(token.line).to eq(line)
    expect(token.column).to eq(col)
  end

  describe "#tokenize" do
    it "tokenizes a simple variable assignment with correct columns" do
      #                  123456789
      lexer = Lexer.new("x = 42")
      tokens = lexer.tokenize

      # x
      expect_token(tokens[0], :VAR_ID, "x", 1, 1)
      # =
      expect_token(tokens[1], :CHAR, "=", 1, 3)
      # 42
      expect_token(tokens[2], :INT64, 42, 1, 5)
      # EOF
      expect(tokens[3].type).to eq(:EOF)
    end

    it "distinguishes Identifiers, Types, and Keywords" do
      # IF is a keyword, If is a Type, if is a var
      lexer = Lexer.new("IF If if")
      tokens = lexer.tokenize

      expect_token(tokens[0], :KEYWORD, "IF", 1, 1)
      expect_token(tokens[1], :TYPE_ID, "If", 1, 4)
      expect_token(tokens[2], :VAR_ID, "if", 1, 7)
    end

    it "tokenizes SNAPSHOT as a keyword (used by `WITH SNAPSHOT x AS y`)" do
      tokens = Lexer.new("WITH SNAPSHOT x AS y").tokenize
      expect_token(tokens[0], :KEYWORD, "WITH", 1, 1)
      expect_token(tokens[1], :KEYWORD, "SNAPSHOT", 1, 6)
      expect_token(tokens[2], :VAR_ID,  "x", 1, 15)
      expect_token(tokens[3], :KEYWORD, "AS", 1, 17)
      expect_token(tokens[4], :VAR_ID,  "y", 1, 20)
    end

    it "handles whitespace and newlines correctly" do
      source = <<~CODE
        x
          = 10
      CODE
      lexer = Lexer.new(source)
      tokens = lexer.tokenize

      # x (Line 1, Col 1)
      expect_token(tokens[0], :VAR_ID, "x", 1, 1)
      # = (Line 2, Col 3 -- indented by 2 spaces)
      expect_token(tokens[1], :CHAR, "=", 2, 3)
      # 10 (Line 2, Col 5)
      expect_token(tokens[2], :INT64, 10, 2, 5)
    end

    it "skips comments but tracks position" do
      #                  123456789012345678
      lexer = Lexer.new("IF # comment\n x")
      tokens = lexer.tokenize

      expect_token(tokens[0], :KEYWORD, "IF", 1, 1)
      # Should skip comment and newline, landing on x at Line 2, Col 2 (space + x)
      expect_token(tokens[1], :VAR_ID, "x", 2, 2)
    end

    describe "String handling" do
      it "handles simple strings" do
        lexer = Lexer.new(' "Hello" ')
        tokens = lexer.tokenize
        expect_token(tokens[0], :STRING, "Hello", 1, 2)
      end

      it "handles triple-quoted multiline strings and updates line/col" do
        # """
        #  A
        # """
        # IF
        source = "\"\"\"\n A\n\"\"\"\nIF"
        lexer = Lexer.new(source)
        tokens = lexer.tokenize

        # String token starts at 1:1
        expect(tokens[0].type).to eq(:STRING)
        expect(tokens[0].line).to eq(1)
        expect(tokens[0].column).to eq(1)
        expect(tokens[0].value).to eq("\n A\n")

        # The next token (IF) should be on Line 4
        # Line 1: """
        # Line 2:  A
        # Line 3: """
        # Line 4: IF
        expect_token(tokens[1], :KEYWORD, "IF", 4, 1)
      end
    end

    describe "Prefixed Integer Literals (0x, 0o, 0b)" do
      it "parses hex as PREFIXED_INT" do
        expect_token(Lexer.new("0xFF").tokenize[0],   :PREFIXED_INT, 255, 1, 1)
        expect_token(Lexer.new("0x100").tokenize[0],  :PREFIXED_INT, 256, 1, 1)
      end

      it "parses binary as PREFIXED_INT" do
        expect_token(Lexer.new("0b101").tokenize[0],       :PREFIXED_INT, 5,   1, 1)
        expect_token(Lexer.new("0b100000000").tokenize[0], :PREFIXED_INT, 256, 1, 1)
      end

      it "parses octal as PREFIXED_INT" do
        expect_token(Lexer.new("0o7").tokenize[0],   :PREFIXED_INT, 7,   1, 1)
        expect_token(Lexer.new("0o755").tokenize[0], :PREFIXED_INT, 493, 1, 1)
      end

      it "raises error on suffixed literal overflow" do
        expect { Lexer.new("0xFF_i8").tokenize }.to raise_error(/overflows i8/)
        expect { Lexer.new("0o755_u8").tokenize }.to raise_error(/overflows u8/)
        expect { Lexer.new("0x1FFFFFFFF_u32").tokenize }.to raise_error(/overflows u32/)
      end
    end

    describe "Digit-group separators" do
      it "parses `_` as a separator in plain ints" do
        expect_token(Lexer.new("1_000").tokenize[0],        :INT64, 1000, 1, 1)
        expect_token(Lexer.new("1_000_000").tokenize[0],    :INT64, 1_000_000, 1, 1)
        expect_token(Lexer.new("12_345_678").tokenize[0],   :INT64, 12_345_678, 1, 1)
      end

      it "parses `_` as a separator in suffixed ints" do
        expect_token(Lexer.new("1_000_i32").tokenize[0],    :INT32, 1000, 1, 1)
        expect_token(Lexer.new("1_234_567_u32").tokenize[0], :UINT32, 1_234_567, 1, 1)
      end

      it "parses `_` as a separator in plain floats" do
        expect_token(Lexer.new("1_000.5").tokenize[0],            :NUMBER, 1000.5, 1, 1)
        expect_token(Lexer.new("3.141_592").tokenize[0],          :NUMBER, 3.141592, 1, 1)
        expect_token(Lexer.new("1_234.567_89").tokenize[0],       :NUMBER, 1234.56789, 1, 1)
      end

      it "parses `_` as a separator in suffixed floats" do
        expect_token(Lexer.new("3.141_592_f64").tokenize[0],      :NUMBER, 3.141592, 1, 1)
        expect_token(Lexer.new("1_234.5_f32").tokenize[0],        :FLOAT32, 1234.5, 1, 1)
      end

      it "parses `_` as a separator in hex/oct/bin (no suffix ambiguity)" do
        # 0xDEAD_BEEF must be parsed as hex with a separator, NOT hex + suffix
        # "BEEF" — the suffix pattern is closed to i8..f64.
        expect_token(Lexer.new("0xDEAD_BEEF").tokenize[0],  :PREFIXED_INT, 0xDEADBEEF, 1, 1)
        expect_token(Lexer.new("0b1010_0101").tokenize[0],  :PREFIXED_INT, 0b10100101, 1, 1)
        expect_token(Lexer.new("0o12_34").tokenize[0],      :PREFIXED_INT, 0o1234, 1, 1)
      end

      it "allows hex + suffix with separator in the hex body" do
        expect_token(Lexer.new("0xFF_FF_u32").tokenize[0],  :UINT32, 0xFFFF, 1, 1)
      end
    end

    it "handles complex operators" do
      lexer = Lexer.new(".. -> |> OR_ELSE OR AND")
      tokens = lexer.tokenize

      expect(tokens.map(&:type)).to eq([
        :RANGE, :ARROW, :SMOOTH, :OR_ELSE, :KEYWORD, :KEYWORD, :EOF
      ])
    end

    it "handles tight spacing (operators next to identifiers)" do
      #                  12345
      lexer = Lexer.new("x=1+y")
      tokens = lexer.tokenize

      expect_token(tokens[0], :VAR_ID, "x", 1, 1)
      expect_token(tokens[1], :CHAR,   "=", 1, 2)
      expect_token(tokens[2], :INT64, 1, 1, 3)
      expect_token(tokens[3], :CHAR,   "+", 1, 4)
      expect_token(tokens[4], :VAR_ID, "y", 1, 5)
    end
  end

  describe "String Interpolation" do
    it "interpolates a variable in the middle of a string" do
      # Source: "Hello ${name}!"
      # Logic:  "Hello " + (name) + "!"
      lexer = Lexer.new('"Hello ${name}!"')
      tokens = lexer.tokenize

      # 1. First String Part
      expect_token(tokens[0], :STRING, "Hello ", 1, 1)

      # 2. Injection: + (
      expect(tokens[1].type).to eq(:CHAR); expect(tokens[1].value).to eq("+")
      expect(tokens[2].type).to eq(:CHAR); expect(tokens[2].value).to eq("(")

      # 3. The Variable inside
      # Note: Inner tokens will reset to Line 1 Col 1 because of the sub-lexer
      expect(tokens[3].type).to eq(:VAR_ID)
      expect(tokens[3].value).to eq("name")

      # 4. Injection: ) +
      expect(tokens[4].type).to eq(:CHAR); expect(tokens[4].value).to eq(")")
      expect(tokens[5].type).to eq(:CHAR); expect(tokens[5].value).to eq("+")

      # 5. The Final String Part
      expect_token(tokens[6], :STRING, "!", 1, 15) # Columns resume correctly after advance_pos
    end

    it "handles interpolation at the start (forces empty string prefix)" do
      # Source: "${x}"
      # Logic:  "" + (x) + ""
      # We need that initial "" so the VM treats it as String Concatenation, not Math.
      lexer = Lexer.new('"${x}"')
      tokens = lexer.tokenize

      # 1. Empty String Prefix
      expect_token(tokens[0], :STRING, "", 1, 1)

      # 2. Connector
      expect(tokens[1].value).to eq("+")

      # 3. Variable
      expect(tokens[3].value).to eq("x")

      # 4. Trailing Empty String (Standard for this lexer logic)
      expect(tokens.last.type).to eq(:EOF)
      expect(tokens[-2].type).to eq(:STRING)
      expect(tokens[-2].value).to eq("")
    end

    it "handles complex expressions inside interpolation" do
      # Source: "Result: ${x + 10}"
      # Logic:  "Result: " + (x + 10) + ""
      lexer = Lexer.new('"Result: ${x + 10}"')
      tokens = lexer.tokenize

      # Validate the stream structure
      types = tokens.map(&:type)
      expect(types).to eq([
        :STRING,          # "Result: "
        :CHAR, :CHAR,     # + (
        :VAR_ID, :CHAR, :INT64, # x + 10 (The expression)
        :CHAR, :CHAR,     # ) +
        :STRING,          # ""
        :EOF
      ])

      expect(tokens[5].value).to eq(10)
    end

    it "handles multiple interpolations" do
      # Source: "A ${x} B ${y}"
      # Logic:  "A " + (x) + " B " + (y) + ""
      lexer = Lexer.new('"A ${x} B ${y}"')
      tokens = lexer.tokenize

      # Filter to just the strings and vars to verify order
      meaningful = tokens.select { |t| [:STRING, :VAR_ID].include?(t.type) }
      values = meaningful.map(&:value)

      expect(values).to eq(["A ", "x", " B ", "y", ""])
    end

    it "ignores literal percent signs" do
      lexer = Lexer.new('"100% Correct"')
      tokens = lexer.tokenize
      expect(tokens.size).to eq(2) # STRING + EOF
      expect(tokens[0].value).to eq("100% Correct")
    end

    it "ignores bare dollar signs not followed by {" do
      lexer = Lexer.new('"costs $5"')
      tokens = lexer.tokenize
      expect(tokens.size).to eq(2) # STRING + EOF
      expect(tokens[0].value).to eq("costs $5")
    end

    it "handles nested braces (hashes) inside interpolation" do
      # Source: "Map: ${ {a:1} }"
      # The lexer must be smart enough to match the OUTER closing brace
      lexer = Lexer.new('"Map: ${ {a:1} }"')
      tokens = lexer.tokenize

      # Just check that it parsed the whole thing without erroring on the first '}'
      str_token = tokens[0]
      expect(str_token.value).to eq("Map: ")

      # Check we got the chars inside
      inner_content = tokens[3..-4] # Skip prefix/suffix tokens
      inner_values = inner_content.map(&:value)
      expect(inner_values).to include("{", "a", ":", 1.0, "}")
    end
  end

  describe "Compound Assignment Operators" do
    it "tokenizes +=" do
      tokens = Lexer.new("x += 1;").tokenize
      expect(tokens[1].type).to eq(:COMPOUND_ASSIGN)
      expect(tokens[1].value).to eq("+=")
    end

    it "tokenizes -=" do
      tokens = Lexer.new("x -= 1;").tokenize
      expect(tokens[1].type).to eq(:COMPOUND_ASSIGN)
      expect(tokens[1].value).to eq("-=")
    end

    it "tokenizes *=" do
      tokens = Lexer.new("x *= 2;").tokenize
      expect(tokens[1].type).to eq(:COMPOUND_ASSIGN)
      expect(tokens[1].value).to eq("*=")
    end

    it "tokenizes /=" do
      tokens = Lexer.new("x /= 2;").tokenize
      expect(tokens[1].type).to eq(:COMPOUND_ASSIGN)
      expect(tokens[1].value).to eq("/=")
    end
  end

  describe "? predicate suffix" do
    it "includes ? in identifier when followed by (" do
      tokens = Lexer.new("check?(x)").tokenize
      expect(tokens[0].type).to eq(:VAR_ID)
      expect(tokens[0].value).to eq("check?")
      expect(tokens[1].value).to eq("(")
    end

    it "does NOT include ? when not followed by (" do
      tokens = Lexer.new("value?").tokenize
      expect(tokens[0].type).to eq(:VAR_ID)
      expect(tokens[0].value).to eq("value")
      expect(tokens[1].type).to eq(:CHAR)
      expect(tokens[1].value).to eq("?")
    end

    it "does NOT include ? before . (optional chaining)" do
      tokens = Lexer.new("value?.field").tokenize
      expect(tokens[0].value).to eq("value")
      expect(tokens[1].value).to eq("?")
      expect(tokens[2].value).to eq(".")
    end

    it "preserves ? in pipeline RHS (parser restores from OptionalUnwrap)" do
      require_relative "../ruby/ast/parser" unless defined?(ClearParser)
      require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)
      src = <<~CLEAR
        FN check?(n: Float64) RETURNS Bool -> RETURN n > 0.0; END
        FN main() RETURNS Void -> result = 5.0 |> check?; RETURN; END
      CLEAR
      tokens = Lexer.new(src).tokenize
      ast = ClearParser.new(tokens, src).parse
      main = ast.statements.find { |s| s.respond_to?(:name) && s.name == "main" }
      bind = main.body.find { |s| s.respond_to?(:name) && s.name == "result" }
      expect(bind.value).to be_a(AST::BinaryOp)
      expect(bind.value.right).to be_a(AST::Identifier)
      expect(bind.value.right.name).to eq("check?")
    end
  end

  describe "! mutation suffix" do
    it "includes ! in identifier" do
      tokens = Lexer.new("mutate!(x)").tokenize
      expect(tokens[0].type).to eq(:VAR_ID)
      expect(tokens[0].value).to eq("mutate!")
    end

    it "includes ! without parens (pipeline)" do
      tokens = Lexer.new("x |> mutate!").tokenize
      expect(tokens[2].type).to eq(:VAR_ID)
      expect(tokens[2].value).to eq("mutate!")
    end

    it "does NOT include != (not-equal operator)" do
      tokens = Lexer.new("x != y").tokenize
      expect(tokens[0].value).to eq("x")
      expect(tokens[1].value).to eq("!=")
    end
  end
end
