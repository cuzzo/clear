require "rspec"
require_relative "../src/lexer" # Adjust path to matches your file structure

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
      #                  1234567890
      lexer = Lexer.new("VAR x = 42")
      tokens = lexer.tokenize

      # VAR
      expect_token(tokens[0], :KEYWORD, "VAR", 1, 1)
      # x
      expect_token(tokens[1], :VAR_ID, "x", 1, 5)
      # =
      expect_token(tokens[2], :CHAR, "=", 1, 7)
      # 42
      expect_token(tokens[3], :NUMBER, 42.0, 1, 9)
      # EOF (Position is end of string + 1 usually, or last char)
      expect(tokens[4].type).to eq(:EOF)
    end

    it "distinguishes Identifiers, Types, and Keywords" do
      # IF is a keyword, If is a Type, if is a var
      lexer = Lexer.new("IF If if")
      tokens = lexer.tokenize

      expect_token(tokens[0], :KEYWORD, "IF", 1, 1)
      expect_token(tokens[1], :TYPE_ID, "If", 1, 4)
      expect_token(tokens[2], :VAR_ID, "if", 1, 7)
    end

    it "handles whitespace and newlines correctly" do
      source = <<~CODE
        VAR x
          = 10
      CODE
      lexer = Lexer.new(source)
      tokens = lexer.tokenize

      # VAR (Line 1, Col 1)
      expect_token(tokens[0], :KEYWORD, "VAR", 1, 1)
      # x (Line 1, Col 5)
      expect_token(tokens[1], :VAR_ID, "x", 1, 5)
      # = (Line 2, Col 3 -- indented by 2 spaces)
      expect_token(tokens[2], :CHAR, "=", 2, 3)
      # 10 (Line 2, Col 5)
      expect_token(tokens[3], :NUMBER, 10.0, 2, 5)
    end

    it "skips comments but tracks position" do
      #                  123456789012345_12
      lexer = Lexer.new("VAR -- comment\n x")
      tokens = lexer.tokenize

      expect_token(tokens[0], :KEYWORD, "VAR", 1, 1)
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
        # VAR
        source = "\"\"\"\n A\n\"\"\"\nVAR"
        lexer = Lexer.new(source)
        tokens = lexer.tokenize

        # String token starts at 1:1
        expect(tokens[0].type).to eq(:STRING)
        expect(tokens[0].line).to eq(1)
        expect(tokens[0].column).to eq(1)
        expect(tokens[0].value).to eq("\n A\n")

        # The next token (VAR) should be on Line 4
        # Line 1: """
        # Line 2:  A
        # Line 3: """
        # Line 4: VAR
        expect_token(tokens[1], :KEYWORD, "VAR", 4, 1)
      end
    end

    describe "Byte Literals" do
      it "parses Hex bytes" do
        lexer = Lexer.new("0xFF")
        tokens = lexer.tokenize
        expect_token(tokens[0], :BYTE, 255, 1, 1)
      end

      it "parses Binary bytes" do
        lexer = Lexer.new("0b101")
        tokens = lexer.tokenize
        expect_token(tokens[0], :BYTE, 5, 1, 1)
      end

      it "parses Octal bytes" do
        lexer = Lexer.new("0o7") # Note: Your regex for octal was 0b[0-7] in the code provided
        # Wait, standard octal is usually 0o or 0, but your code had:
        # when @s.scan(/0b[0-7]+/) -> .to_i(8)
        # I will test against your specific implementation:
        lexer = Lexer.new("0o7")
        tokens = lexer.tokenize
        expect_token(tokens[0], :BYTE, 7, 1, 1)
      end

      it "raises error on Hex overflow (> 255)" do
        lexer = Lexer.new("0x100") # 256
        expect { lexer.tokenize }.to raise_error(/Lexer Error: Byte literal 0x100 exceeds 255/)
      end

      it "raises error on Binary overflow (> 255)" do
        lexer = Lexer.new("0b100000000") # 256 in binary (9 bits)
        expect { lexer.tokenize }.to raise_error(/Lexer Error/)
      end
    end

    it "handles complex operators" do
      lexer = Lexer.new(".. -> s> OR || &&")
      tokens = lexer.tokenize

      expect(tokens.map(&:type)).to eq([
        :RANGE, :ARROW, :SMOOTH, :OR_RESCUE, :CHAR, :CHAR, :EOF
      ])
    end

    it "handles tight spacing (operators next to identifiers)" do
      #                  12345
      lexer = Lexer.new("x=1+y")
      tokens = lexer.tokenize

      expect_token(tokens[0], :VAR_ID, "x", 1, 1)
      expect_token(tokens[1], :CHAR,   "=", 1, 2)
      expect_token(tokens[2], :NUMBER, 1.0, 1, 3)
      expect_token(tokens[3], :CHAR,   "+", 1, 4)
      expect_token(tokens[4], :VAR_ID, "y", 1, 5)
    end
  end

  describe "String Interpolation" do
    it "interpolates a variable in the middle of a string" do
      # Source: "Hello %{name}!"
      # Logic:  "Hello " + (name) + "!"
      lexer = Lexer.new('"Hello %{name}!"')
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
      # Source: "%{x}"
      # Logic:  "" + (x) + ""
      # We need that initial "" so the VM treats it as String Concatenation, not Math.
      lexer = Lexer.new('"%{x}"')
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
      # Source: "Result: %{x + 10}"
      # Logic:  "Result: " + (x + 10) + ""
      lexer = Lexer.new('"Result: %{x + 10}"')
      tokens = lexer.tokenize

      # Validate the stream structure
      types = tokens.map(&:type)
      expect(types).to eq([
        :STRING,          # "Result: "
        :CHAR, :CHAR,     # + (
        :VAR_ID, :CHAR, :NUMBER, # x + 10 (The expression)
        :CHAR, :CHAR,     # ) +
        :STRING,          # ""
        :EOF
      ])

      expect(tokens[5].value).to eq(10.0)
    end

    it "handles multiple interpolations" do
      # Source: "A %{x} B %{y}"
      # Logic:  "A " + (x) + " B " + (y) + ""
      lexer = Lexer.new('"A %{x} B %{y}"')
      tokens = lexer.tokenize

      # Filter to just the strings and vars to verify order
      meaningful = tokens.select { |t| [:STRING, :VAR_ID].include?(t.type) }
      values = meaningful.map(&:value)

      expect(values).to eq(["A ", "x", " B ", "y", ""])
    end

    it "ignores literal percent signs" do
      # Source: "100% Correct"
      lexer = Lexer.new('"100% Correct"')
      tokens = lexer.tokenize

      expect(tokens.size).to eq(2) # STRING + EOF
      expect(tokens[0].type).to eq(:STRING)
      expect(tokens[0].value).to eq("100% Correct")
    end

    it "handles nested braces (hashes) inside interpolation" do
      # Source: "Map: %{ {a:1} }"
      # The lexer must be smart enough to match the OUTER closing brace
      lexer = Lexer.new('"Map: %{ {a:1} }"')
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
end
