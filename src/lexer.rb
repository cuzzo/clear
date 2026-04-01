require 'strscan'
require 'set'

class Lexer
  Token = Struct.new(:type, :value, :line, :column)

  # We use a hash for O(1) lookups
  KEYWORDS = %w[
      MUTABLE
      FN RETURN RETURNS USE
      IF THEN ELSE ELSE_IF END
      WHILE DO FOR IN BG NEXT BREAK CONTINUE
      CAST AS
      STRUCT ENUM UNION TRUE FALSE NIL
      ASSERT RAISE CATCH EXIT DIE PASS PRUNE
      MOD OR
      REQUIRE
      SELECT WHERE INDEX REDUCE ORDER_BY LIMIT UNNEST DISTINCT EACH FIND ANY ALL COUNT SUM AVERAGE MIN MAX CONCURRENT SHARD
      GIVE TAKES COPY MOVE LINK RESOLVE
      WITH EXCLUSIVE RESTRICT
      MATCH START DEFAULT WHEN IFF
      PUB PRIVATE
      EXTERN FROM EFFECTS CLOSE
      STREAM YIELD
      TIGHT
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
      when @s.scan(/\.\.\./) then add(:ELLIPSIS, '...', start_col)
      when @s.scan(/\.\.<=/) then add(:RANGE_INCL, '..<=', start_col)
      when @s.scan(/\.\.=/) then add(:RANGE_INCL, '..=', start_col)
      when @s.scan(/\.\.</) then add(:RANGE_EXCL, '..<', start_col)
      when @s.scan(/\.\./) then add(:RANGE, '..', start_col)
      when @s.scan(/->/) then add(:ARROW, '->', start_col)
      when @s.scan(/s>/) then add(:SMOOTH, 's>', start_col)
      when @s.scan(/OR\b/) then add(:OR_RESCUE, 'OR', start_col)
      when @s.scan(/==/) then add(:CHAR, '==', start_col)
      when @s.scan(/>=/) then add(:CHAR, '>=', start_col)
      when @s.scan(/<=/) then add(:CHAR, '<=', start_col)
      when @s.scan(/!=/) then add(:CHAR, '!=', start_col)
      when @s.scan(/&&/) then add(:CHAR, '&&', start_col)
      when @s.scan(/\*\*/) then add(:CHAR, '**', start_col)
      when @s.scan(/\|\|/) then add(:CHAR, '||', start_col)
      when @s.scan(/\+=/) then add(:COMPOUND_ASSIGN, '+=', start_col)
      when @s.scan(/-=/)  then add(:COMPOUND_ASSIGN, '-=', start_col)
      when @s.scan(/\*=/) then add(:COMPOUND_ASSIGN, '*=', start_col)
      when @s.scan(/\/=/) then add(:COMPOUND_ASSIGN, '/=', start_col)
      when @s.scan(/_/) then add(:VAR_ID, '_', start_col)

      when @s.scan(/"""((?:.|\n)*?)"""/)
        # Extract content, but 'add' will use @s.matched to count lines correctly
        content = @s.matched[3..-4]
        add(:STRING, content, start_col)

      when @s.scan(/::/) then add(:DOUBLE_COLON, '::', start_col)

      when @s.scan(/[=+\-*\/<>&|!.,;(){}\[\]:?~]/)
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

      when @s.scan(/(\d+)_([a-zA-Z0-9]+)/)
        val_str = @s[1]
        suffix = @s[2]
        val = val_str.to_i

        case suffix
        when 'i64'
          add(:INT64, val, start_col)
        when 'f64'
          add(:NUMBER, val.to_f, start_col)
        when 'u8'
          raise_if_byte_overflow(val)
          add(:BYTE, val, start_col)
        when 'i8'  then add(:INT8,   val, start_col)
        when 'i16' then add(:INT16,  val, start_col)
        when 'i32' then add(:INT32,  val, start_col)
        when 'u16' then add(:UINT16, val, start_col)
        when 'u32' then add(:UINT32, val, start_col)
        when 'u64' then add(:UINT64, val, start_col)
        when 'f32' then add(:FLOAT32, val.to_f, start_col)
        else
          raise "Lexer Error: Unknown numeric suffix '_#{suffix}' at line #{@line}:#{@column}"
        end

      when @s.scan(/\d+\.\d+_([a-zA-Z0-9]+)/)
        # Float literal with type suffix: 3.14_f32, 1.0_f64
        val = @s.matched.split('_')[0].to_f
        suffix = @s[1]
        case suffix
        when 'f32' then add(:FLOAT32, val, start_col)
        when 'f64' then add(:NUMBER, val, start_col)
        else raise "Lexer Error: Unknown float suffix '_#{suffix}' at line #{@line}:#{@column}"
        end

      when @s.scan(/\d+\.\d+/)
        # Float literal (has decimal point): 3.14, 0.5
        add(:NUMBER, @s.matched.to_f, start_col)

      when @s.scan(/\d+/)
        # Integer literal (no decimal): 42, 1000
        add(:INT64, @s.matched.to_i, start_col)

      when @s.scan(/"/)
        advance_pos(@s.matched) # Advance past the opening quote
        read_interpolated_string(start_col)

      else
        raise "Unexpected char: #{@s.peek(1)} on line #{@line}:#{@column}"
      end
    end

    # Manually push EOF (don't use add() here as there is nothing matched)
    @tokens << Token.new(:EOF, nil, @line, @column)
    @tokens
  end

  private

  def read_interpolated_string(start_col)
    buffer = ""
    chunk_start_col = start_col # Track where the *current* text buffer started

    loop do
      # Scan until we hit a quote, backslash, or interpolation start ($)
      text = @s.scan(/[^"\\$]+/)
      if text
        buffer << text
        advance_pos(text)
      end

      # Handle escape sequences
      if @s.peek(1) == '\\'
        @s.getch # consume backslash
        advance_pos('\\')
        ch = @s.getch
        advance_pos(ch) if ch
        case ch
        when 'n'  then buffer << "\n"   # actual newline byte (0x0A)
        when 't'  then buffer << "\t"   # actual tab byte (0x09)
        when '"'  then buffer << '"'
        when '\\' then buffer << '\\'
        when 'r'  then buffer << "\r"   # actual CR byte (0x0D)
        when '0'  then buffer << "\0"   # actual null byte (0x00)
        else buffer << '\\' << (ch || '')
        end
        next
      end

      # Check what stopped us
      if @s.peek(1) == '"'
        # End of String
        @s.getch # Consume "
        advance_pos('"')
        @tokens << Token.new(:STRING, buffer, @line, chunk_start_col)
        break

      elsif @s.peek(2) == '${'
        # String interpolation: ${expr}
        # Desugared to concatenation: "..." + (expr) + "..."

        # 1. Emit current buffer
        @tokens << Token.new(:STRING, buffer, @line, chunk_start_col)
        buffer = ""

        # 2. Consume ${
        @s.getch; @s.getch
        advance_pos('${')

        # 3. Inject connector tokens: + (
        @tokens << Token.new(:CHAR, '+', @line, @column)
        @tokens << Token.new(:CHAR, '(', @line, @column)

        # 4. Sub-lex the expression inside braces
        expr_source = extract_balanced_brace_content
        sub_lexer = Lexer.new(expr_source)
        sub_tokens = sub_lexer.tokenize
        sub_tokens.pop if sub_tokens.last.type == :EOF
        @tokens.concat(sub_tokens)

        # 5. Inject closer tokens: ) +
        @tokens << Token.new(:CHAR, ')', @line, @column)
        @tokens << Token.new(:CHAR, '+', @line, @column)

        chunk_start_col = @column

      elsif @s.peek(1) == '$'
        # Bare $ (not followed by {) — literal character
        buffer << @s.getch
        advance_pos('$')
      else
        if @s.eos?
          raise "Lexer Error: Unclosed string starting at line #{start_col}"
        end
        buffer << @s.getch
        advance_pos('"')
      end
    end
  end

  def extract_balanced_brace_content
    content = ""
    depth = 1

    until @s.eos?
      # Scan safe chars
      text = @s.scan(/[^\{\}]+/)
      if text
        content << text
        advance_pos(text)
      end

      if @s.peek(1) == '{'
        depth += 1
        content << @s.getch
        advance_pos('{')
      elsif @s.peek(1) == '}'
        depth -= 1
        if depth == 0
          @s.getch # Consume final closing brace
          advance_pos('}')
          return content
        else
          content << @s.getch
          advance_pos('}')
        end
      end
    end

    raise "Lexer Error: Unclosed interpolation %{...}"
  end

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

