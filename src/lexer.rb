require 'strscan'
require 'set'

class Lexer
  Token = Struct.new(:type, :value, :line, :column)

  # We use a hash for O(1) lookups
  KEYWORDS = %w[
      VAR MUTABLE SET
      FN RETURN RETURNS USE
      IF THEN ELSE ELSE_IF END
      WHILE DO BREAK CONTINUE
      CAST AS
      STRUCT TRUE FALSE NIL
      ASSERT RAISE CATCH EXIT DIE
      MOD OR
    ].to_set

  def initialize(source)
    @s = StringScanner.new(source)
    @line = 1
    @column = 1
    @tokens = []
  end

  def tokenize
    until @s.eos?
      # 1. Snapshot start column before scanning
      start_col = @column

      case
      # --- SKIPPABLE (No Token Generated) = MANUAL ADVANCE!!!
      when @s.scan(/\s+/) then advance_pos(@s.matched)
      when @s.scan(/--.*$/) then advance_pos(@s.matched)

      # --- TOKENS (Auto-advance via add) ---
      # TODO: Change range syntax to ..< and ..=
      when @s.scan(/\.\./) then add(:RANGE, '..', start_col)
      when @s.scan(/->/) then add(:ARROW, '->', start_col)
      when @s.scan(/s>/) then add(:SMOOTH, 's>', start_col)
      when @s.scan(/OR/) then add(:OR_RESCUE, 'OR', start_col)
      when @s.scan(/==/) then add(:CHAR, '==', start_col)
      when @s.scan(/>=/) then add(:CHAR, '>=', start_col)
      when @s.scan(/<=/) then add(:CHAR, '<=', start_col)
      when @s.scan(/!=/) then add(:CHAR, '!=', start_col)
      when @s.scan(/&&/) then add(:CHAR, '&&', start_col)
      when @s.scan(/\*\*/) then add(:CHAR, '**', start_col)
      when @s.scan(/\|\|/) then add(:CHAR, '||', start_col)

      when @s.scan(/"""((?:.|\n)*?)"""/)
        # Extract content, but 'add' will use @s.matched to count lines correctly
        content = @s.matched[3..-4]
        add(:STRING, content, start_col)

      when @s.scan(/[=+\-*\/<>&|!.,;(){}\[\]:]/)
        add(:CHAR, @s.matched, start_col)

      when @s.scan(/%/)
        add(:PERCENT, '%', start_col)

      when @s.scan(/[a-zA-Z_@]\w*(!(?!=))?/)
        word = @s.matched
        if KEYWORDS.include?(word)
          add(:KEYWORD, word, start_col)
        elsif word =~ /^[A-Z]/
          add(:TYPE_ID, word, start_col)
        else
          add(:VAR_ID, word, start_col)
        end

      when @s.scan(/0x[0-9a-fA-F]+/)
        val = @s.matched.to_i(16)
        raise_if_byte_overflow(val)
        add(:BYTE, val, start_col)

      when @s.scan(/0o[0-7]+/)
        val = @s.matched.to_i(8)
        raise_if_byte_overflow(val)
        add(:BYTE, val, start_col)

      when @s.scan(/0b[0-1]+/)
        val = @s.matched.to_i(2)
        raise_if_byte_overflow(val)
        add(:BYTE, val, start_col)

      when @s.scan(/\d+(\.(?!\.)\d*)?/)
        add(:NUMBER, @s.matched.to_f, start_col)

      when @s.scan(/"[^"]*"/)
        add(:STRING, @s.matched[1..-2], start_col)

      else
        raise "Unexpected char: #{@s.peek(1)} on line #{@line}:#{@column}"
      end
    end

    # Manually push EOF (don't use add() here as there is nothing matched)
    @tokens << Token.new(:EOF, nil, @line, @column)
    @tokens
  end

  private # ============================

  def add(type, val, col)
    @tokens << Token.new(type, val, @line, col)
    # Automatically update position based on the last matched string
    advance_pos(@s.matched)
  end

  def advance_pos(str)
    return unless str # Guard clause for safety

    newlines = str.count("\n")
    if newlines > 0
      @line += newlines
      last_newline_index = str.rindex("\n")
      @column = (str.length - last_newline_index)
    else
      @column += str.length
    end
  end

  def raise_if_byte_overflow(val)
    if val > 255
      raise "Lexer Error: Byte literal #{@s.matched} exceeds 255."
    end
  end
end

