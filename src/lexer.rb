require 'strscan'

# ==========================================
# 2. LEXER
# ==========================================
class Lexer
  Token = Struct.new(:type, :value, :line)

  # We use a hash for O(1) lookups
  # TODO: Should MOD be a keyword ???
  KEYWORDS = %w[
      VAR SET
      FN RETURN RETURNS USE
      IF THEN ELSE ELSE_IF END
      WHILE DO BREAK CONTINUE
      CAST AS
      STRUCT TRUE FALSE NIL
      ASSERT RAISE CATCH EXIT DIE
      MOD OR
    ].map { |k| [k, true] }.to_h

  def initialize(source)
    @s = StringScanner.new(source)
    @line = 1
    @tokens = []
  end

  def tokenize
    until @s.eos?
      case
      when @s.scan(/\s+/)
        @line += @s.matched.count("\n")

      when @s.scan(/--.*$/)
        # Comment - ignore

      when @s.scan(/->/) then add(:ARROW, '->')
      when @s.scan(/s>/) then add(:SMOOTH, 's>')
      when @s.scan(/OR/) then add(:OR_RESCUE, 'OR')
      when @s.scan(/==/) then add(:CHAR, '==')
      when @s.scan(/>=/) then add(:CHAR, '>=')
      when @s.scan(/<=/) then add(:CHAR, '<=')
      when @s.scan(/!=/) then add(:CHAR, '!=')
      when @s.scan(/&&/) then add(:CHAR, '&&')
      when @s.scan(/\*\*/) then add(:CHAR, '**')
      when @s.scan(/\|\|/) then add(:CHAR, '||')

      # Triple Quote Strings (Multiline)
      # Match """ then anything (non-greedy) until the next """
      # Must come before the match for single quotes below
      when @s.scan(/"""((?:.|\n)*?)"""/)
        # 1. Extract content (strip the surrounding """)
        content = @s.matched[3..-4]

        # 2. Update line counter (Crucial for error messages!)
        # We count how many newlines were inside the string
        @line += content.count("\n")

        add(:STRING, content)

      # Operators and Punctuation
      when @s.scan(/[=+\-*\/<>&|!.,;(){}\[\]:]/)
        add(:CHAR, @s.matched)

      when @s.scan(/%/)
        add(:PERCENT, '%')

      # Identifiers (The logic here is critical)
      when @s.scan(/[a-zA-Z_@]\w*/)
        word = @s.matched
        if KEYWORDS[word]
          add(:KEYWORD, word)
        elsif word =~ /^[A-Z]/
          add(:TYPE_ID, word) # Uppercase start = Type
        else
          add(:VAR_ID, word)  # Lowercase start = Var
        end

      # Hexadecimal (0xFF) - MUST come before generic number
      when @s.scan(/0x[0-9a-fA-F]+/)
        val = @s.matched.to_i(16) # Ruby handles the hex conversion
        # TODO: Handle size at assignment, not here.
        if val > 255
          raise "Lexer Error: Byte literal #{@s.matched} exceeds 255."
        end
        add(:BYTE, val)

      # Octal (0o77)
      when @s.scan(/0b[0-7]+/)
        val = @s.matched.to_i(8)
        if val > 255
          raise "Lexer Error: Byte literal #{@s.matched} exceeds 255."
        end
        add(:BYTE, val)

      # Binary (0b101)
      when @s.scan(/0b[0-1]+/)
        val = @s.matched.to_i(2)
        if val > 255
          raise "Lexer Error: Byte literal #{@s.matched} exceeds 255."
        end
        add(:BYTE, val)

      when @s.scan(/\d+\.?\d*/)
        add(:NUMBER, @s.matched.to_f)

      when @s.scan(/"[^"]*"/)
        add(:STRING, @s.matched[1..-2])

      else
        raise "Unexpected char: #{@s.peek(1)} on line #{@line}"
      end
    end
    add(:EOF, nil)
    @tokens
  end

  def add(type, val)
    @tokens << Token.new(type, val, @line)
  end
end

