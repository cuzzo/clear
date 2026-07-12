# typed: strict
require "sorbet-runtime"

require 'strscan'
require 'set'

class Lexer
    extend T::Sig

  Token = Struct.new(:type, :value, :line, :column)

  # We use a hash for O(1) lookups
  KEYWORDS = T.let(%w[
      MUTABLE
      FN METHOD RETURN RETURNS USE
      IF THEN ELSE ELSE_IF END COMPTIME IS_A EXISTS IS_OK IS_READY
      WHILE DO FOR IN BG NEXT BREAK CONTINUE
      CAST AS
      STRUCT ENUM UNION TRUE FALSE NIL Auto
      ASSERT RAISE CATCH EXIT DIE PASS PRUNE
      MOD AND OR OR_ELSE
      REQUIRE
      SELECT WHERE INDEX REDUCE ORDER_BY LIMIT SKIP UNNEST DISTINCT EACH TAP FIND ANY ALL COUNT SUM AVERAGE MIN MAX CONCURRENT SHARD TAKE_WHILE WINDOW JOIN RECOVER COLLECT
      GIVE TAKES COPY MOVE CLONE SHARE LINK RESOLVE FREEZE
      WITH EXCLUSIVE RESTRICT BORROWED ON RETRY POSSIBLE_DEADLOCK POSSIBLE_LOCK_CYCLE VIEW MATERIALIZED SNAPSHOT GUARD PRE DEBUG_POST
      POLYMORPHIC SHARED SYNC POLICY
      REQUIRES
      MATCH PARTIAL START DEFAULT WHEN
      PUB PRIVATE
      EXTERN FROM EFFECTS CLOSE REQUIRES
      STREAM YIELD
      TIGHT
      TEST THAT STUB BENCHMARK SMASH PROFILE ASSERT_RAISES CAPTURES SEQUENCE
      PENDING BEFORE AFTER LET TAGS
    ].to_set, T::Set[String])

  sig { params(source: String).void }
  def initialize(source)
    @s = T.let(StringScanner.new(source), StringScanner)
    @line = T.let(1, Integer)
    @column = T.let(1, Integer)
    @tokens = T.let([], T::Array[Token])
  end

  sig { returns(T::Array[Token]) }
  def tokenize
    until @s.eos?
      # 1. Snapshot start column before scanning
      start_col = @column

      case
      # --- SKIPPABLE (No Token Generated) = MANUAL ADVANCE!!!
      when @s.scan(/\s+|#.*$/) then advance_pos(@s.matched)

      # --- TOKENS (Auto-advance via add) ---
      when @s.scan(/\.\.\./) then add(:ELLIPSIS, '...', start_col)
      when @s.scan(/\.\.<=/) then add(:RANGE_INCL, '..<=', start_col)
      when @s.scan(/\.\.=/) then add(:RANGE_INCL, '..=', start_col)
      when @s.scan(/\.\.</) then add(:RANGE_EXCL, '..<', start_col)
      when @s.scan(/\.\./) then add(:RANGE, '..', start_col)
      when @s.scan(/->/) then add(:ARROW, '->', start_col)
      when @s.scan(/\|>/) then add(:SMOOTH, '|>', start_col)
      when @s.scan(/OR_ELSE\b/) then add(:OR_ELSE, 'OR_ELSE', start_col)
      when @s.scan(/==/) then add(:CHAR, '==', start_col)
      when @s.scan(/>=/) then add(:CHAR, '>=', start_col)
      when @s.scan(/<=/) then add(:CHAR, '<=', start_col)
      when @s.scan(/!=/) then add(:CHAR, '!=', start_col)
      when @s.scan(/&&/) then add(:LEGACY_LOGICAL, '&&', start_col)
      when @s.scan(/\*\*/) then add(:CHAR, '**', start_col)
      when @s.scan(/\|\|/) then add(:LEGACY_LOGICAL, '||', start_col)
      when @s.scan(/%\*/) then add(:CHAR, '%*', start_col)
      when @s.scan(/%\+/) then add(:CHAR, '%+', start_col)
      when @s.scan(/%-/)  then add(:CHAR, '%-', start_col)
      when @s.scan(/!\*/) then add(:CHAR, '!*', start_col)
      when @s.scan(/!\+/) then add(:CHAR, '!+', start_col)
      when @s.scan(/!-/)  then add(:CHAR, '!-', start_col)
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

      when @s.scan(/[a-zA-Z_@$]\w*(!(?!=)|\?(?=\())?/)
        word = @s.matched
        if KEYWORDS.include?(word)
          add(:KEYWORD, word, start_col)
        elsif word =~ /^[A-Z]/
          add(:TYPE_ID, word, start_col)
        else
          add(:VAR_ID, word, start_col)
        end

      # Numeric literals support `_` as a digit separator (e.g. 1_000_000,
      # 3.141_592, 0xDEAD_BEEF). Separators are stripped for the value.
      # The type suffix set is closed (see NUMERIC_SUFFIX_RE) to disambiguate
      # hex digit groups from a suffix — `0xDEAD_BEEF` is hex separators,
      # `0xff_u32` is hex + suffix. The suffix-bearing regex runs before
      # the plain form so the suffix is captured when present.
      when @s.scan(/0x[0-9a-fA-F]+(?:_[0-9a-fA-F]+)*_(#{NUMERIC_SUFFIX_RE})\b/o)
        val = strip_digit_separators(@s.matched, @s[1]).to_i(16)
        add_prefixed_int(val, @s[1], start_col)

      when @s.scan(/0x[0-9a-fA-F]+(?:_[0-9a-fA-F]+)*/)
        add(:PREFIXED_INT, @s.matched.tr('_', '').to_i(16), start_col)

      when @s.scan(/0o[0-7]+(?:_[0-7]+)*_(#{NUMERIC_SUFFIX_RE})\b/o)
        val = strip_digit_separators(@s.matched, @s[1]).to_i(8)
        add_prefixed_int(val, @s[1], start_col)

      when @s.scan(/0o[0-7]+(?:_[0-7]+)*/)
        add(:PREFIXED_INT, @s.matched.tr('_', '').to_i(8), start_col)

      when @s.scan(/0b[0-1]+(?:_[0-1]+)*_(#{NUMERIC_SUFFIX_RE})\b/o)
        val = strip_digit_separators(@s.matched, @s[1]).to_i(2)
        add_prefixed_int(val, @s[1], start_col)

      when @s.scan(/0b[0-1]+(?:_[0-1]+)*/)
        add(:PREFIXED_INT, @s.matched.tr('_', '').to_i(2), start_col)

      when @s.scan(/\d+(?:_\d+)*\.\d+(?:_\d+)*_(#{NUMERIC_SUFFIX_RE})\b/o)
        val = strip_digit_separators(@s.matched, @s[1]).to_f
        suffix = @s[1]
        case suffix
        when 'f32' then add(:FLOAT32, val, start_col)
        when 'f64' then add(:NUMBER, val, start_col)
        else raise "Lexer Error: Unknown float suffix '_#{suffix}' at line #{@line}:#{@column}"
        end

      when @s.scan(/\d+(?:_\d+)*\.\d+(?:_\d+)*/)
        add(:NUMBER, @s.matched.tr('_', '').to_f, start_col)

      when @s.scan(/\d+(?:_\d+)*_(#{NUMERIC_SUFFIX_RE})\b/o)
        body = strip_digit_separators(@s.matched, @s[1])
        add_prefixed_int(body.to_i, @s[1], start_col)

      when @s.scan(/\d+(?:_\d+)*/)
        add(:INT64, @s.matched.tr('_', '').to_i, start_col)

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

  sig { params(start_col: Integer).void }
  def read_interpolated_string(start_col)
    buffer = ""
    chunk_start_col = T.let(start_col, Integer) # Track where the *current* text buffer started

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
        when 'x'                        # \xHH hex byte
          hex = @s.scan(/[0-9a-fA-F]{2}/)
          raise "Lexer Error: \\x requires exactly 2 hex digits at line #{@line}:#{@column}" unless hex
          advance_pos(hex)
          buffer << hex.to_i(16).chr
        when 'u'                        # \u{HHHH} unicode codepoint -> UTF-8
          raise "Lexer Error: \\u requires {hex} at line #{@line}:#{@column}" unless @s.peek(1) == '{'
          @s.getch; advance_pos('{')
          hex = @s.scan(/[0-9a-fA-F]{1,6}/)
          raise "Lexer Error: invalid \\u{} escape at line #{@line}:#{@column}" unless hex
          advance_pos(hex)
          raise "Lexer Error: unclosed \\u{} at line #{@line}:#{@column}" unless @s.peek(1) == '}'
          @s.getch; advance_pos('}')
          buffer << hex.to_i(16).chr(Encoding::UTF_8)
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
        sub_tokens.pop if T.must(sub_tokens.last).type == :EOF
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
        raise "Lexer Error: Unclosed string starting at line #{start_col}" if @s.eos?
      end
    end
  end

  sig { returns(String) }
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

  sig { params(type: Symbol, val: T.any(Float, Integer, String), col: Integer).returns(Integer) }
  def add(type, val, col)
    @tokens << Token.new(type, val, @line, col)
    # Automatically update position based on the last matched string
    advance_pos(@s.matched)
  end

  sig { params(str: String).returns(Integer) }
  def advance_pos(str)
    return unless str # Guard clause for safety

    newlines = str.count("\n")
    if newlines > 0
      @line += newlines
      last_newline_index = str.rindex("\n")
      @column = (str.length - T.must(last_newline_index))
    else
      @column += str.length
    end
  end

  # Closed set of numeric type suffixes. Matches a word boundary so the
  # suffix can't absorb a following identifier.
  NUMERIC_SUFFIX_RE = T.let(/i8|i16|i32|i64|u8|u16|u32|u64|f32|f64/.freeze, Regexp)

  # Strip digit-group separators (underscores) from a numeric literal's
  # matched text. Removes the trailing `_<suffix>` (passed in) first so
  # we don't strip the underscore that introduces the type suffix. Any
  # base prefix (`0x`, `0o`, `0b`) is preserved.
  sig { params(matched: String, suffix: String).returns(String) }
  def strip_digit_separators(matched, suffix)
    body = matched.sub(/_#{Regexp.escape(suffix)}\z/, '')
    body.tr('_', '')
  end

  INT_SUFFIX_RANGES = T.let({
    'u8'  => 0..255,
    'i8'  => -128..127,
    'i16' => -32_768..32_767,
    'u16' => 0..65_535,
    'i32' => -2_147_483_648..2_147_483_647,
    'u32' => 0..4_294_967_295,
    'i64' => -9_223_372_036_854_775_808..9_223_372_036_854_775_807,
    'u64' => 0..((2**64) - 1),
  }.freeze, T::Hash[String, T::Range[Integer]])

  sig { params(val: Integer, suffix: String, start_col: Integer).returns(T.nilable(Integer)) }
  def add_prefixed_int(val, suffix, start_col)
    range = INT_SUFFIX_RANGES[suffix]
    raise "Lexer Error: Unknown numeric suffix '_#{suffix}' at line #{@line}:#{@column}" unless range || suffix == 'f32' || suffix == 'f64'
    if range && !range.include?(val)
      raise "Lexer Error: Literal #{@s.matched} overflows #{suffix} (range #{range})"
    end
    case suffix
    when 'i64' then add(:INT64,   val,        start_col)
    when 'u8'  then add(:BYTE,    val,        start_col)
    when 'i8'  then add(:INT8,    val,        start_col)
    when 'i16' then add(:INT16,   val,        start_col)
    when 'i32' then add(:INT32,   val,        start_col)
    when 'u16' then add(:UINT16,  val,        start_col)
    when 'u32' then add(:UINT32,  val,        start_col)
    when 'u64' then add(:UINT64,  val,        start_col)
    when 'f32' then add(:FLOAT32, val.to_f,   start_col)
    when 'f64' then add(:NUMBER,  val.to_f,   start_col)
    end
  end

end
