# typed: strict
require "sorbet-runtime"

require 'strscan'
require 'set'
require_relative "frontend_resource_budget"

class Lexer
    extend T::Sig

  MAX_INTERPOLATION_DEPTH = 64

  class Error < StandardError; end

  # Half-open source range: start is inclusive and end is immediately after
  # the token. The first four fields remain in their historical positions so
  # direct Token.new calls in compiler clients stay source-compatible.
  Token = Struct.new(
    :type, :value, :line, :column,
    :file, :start_offset, :end_offset, :end_line, :end_column,
  )

  class TokenPayloadError < TypeError; end

  class Token
    extend T::Sig

    TEXT_TYPES = T.let(%i[
      ARROW CHAR COMPOUND_ASSIGN DOUBLE_COLON ELLIPSIS KEYWORD LEGACY_LOGICAL
      OR_ELSE PERCENT RANGE RANGE_EXCL RANGE_INCL SMOOTH STRING TYPE_ID VAR_ID
    ].freeze, T::Array[Symbol])
    INTEGER_TYPES = T.let(%i[
      BYTE INT8 INT16 INT32 INT64 PREFIXED_INT UINT16 UINT32 UINT64
    ].freeze, T::Array[Symbol])
    FLOAT_TYPES = T.let(%i[FLOAT32 NUMBER].freeze, T::Array[Symbol])

    sig { returns(String) }
    def text!
      payload = value
      return payload if TEXT_TYPES.include?(type) && payload.is_a?(String)

      raise TokenPayloadError, payload_error("text", "String")
    end

    sig { returns(Integer) }
    def integer!
      payload = value
      return payload if INTEGER_TYPES.include?(type) && payload.is_a?(Integer)

      raise TokenPayloadError, payload_error("integer", "Integer")
    end

    sig { returns(Float) }
    def float!
      payload = value
      return payload if FLOAT_TYPES.include?(type) && payload.is_a?(Float)

      raise TokenPayloadError, payload_error("float", "Float")
    end

    sig { returns(Integer) }
    def start_line = line

    sig { returns(Integer) }
    def start_column = column

    sig { returns(Integer) }
    def byte_length
      return end_offset - start_offset if start_offset && end_offset

      value.to_s.bytesize
    end

    private

    sig { params(accessor: String, expected_class: String).returns(String) }
    def payload_error(accessor, expected_class)
      "#{type.inspect} token at #{line}:#{column} has no #{accessor} payload " \
        "(expected #{expected_class}, got #{value.class})"
    end
  end

  # We use a hash for O(1) lookups
  KEYWORDS = T.let(%w[
      MUTABLE
      FN METHOD RETURN RETURNS USE
      IF THEN ELSE ELSE_IF END COMPTIME IS_A EXISTS IS_OK IS_READY
      WHILE DO FOR IN BG NEXT BREAK CONTINUE
      CAST AS
      STRUCT ENUM UNION IMPLEMENTATION TRUE FALSE NIL Auto
      ASSERT RAISE CATCH EXIT DIE PASS PRUNE
      MOD AND OR OR_ELSE
      REQUIRE
      SELECT WHERE INDEX REDUCE ORDER_BY LIMIT SKIP UNNEST DISTINCT EACH TAP FIND ANY ALL COUNT SUM AVERAGE MIN MAX CONCURRENT SHARD TAKE_WHILE WINDOW JOIN RECOVER COLLECT
      GIVE TAKES COPY MOVE CLONE SHARE LINK RESOLVE FREEZE
      WITH EXCLUSIVE RESTRICT BORROWED ON RETRY POSSIBLE_DEADLOCK POSSIBLE_LOCK_CYCLE VIEW MATERIALIZED UNSAFE LENGTH SNAPSHOT GUARD PRE DEBUG_POST
      POLYMORPHIC SHARED SYNC POLICY
      REQUIRES
      MATCH PARTIAL START DEFAULT WHEN
      PUB PRIVATE
      EXTERN FROM EFFECTS CLOSE REQUIRES ABI CALLCONV HEADER LINK
      STREAM YIELD YIELDS
      TIGHT
      TEST THAT STUB BENCHMARK SMASH PROFILE ASSERT_RAISES CAPTURES SEQUENCE
      PENDING BEFORE AFTER LET TAGS
    ].to_set, T::Set[String])

  sig do
    params(
      source: String,
      interpolation_depth: Integer,
      file: T.nilable(String),
      start_line: Integer,
      start_column: Integer,
      start_offset: Integer,
      budget: T.nilable(FrontendResourceBudget),
    ).void
  end
  def initialize(source, interpolation_depth: 0, file: nil, start_line: 1, start_column: 1, start_offset: 0, budget: nil)
    source = source.dup.force_encoding(Encoding::UTF_8)
    raise Error, "Lexer Error: source is not valid UTF-8" unless source.valid_encoding?

    @s = T.let(StringScanner.new(source), StringScanner)
    @line = T.let(start_line, Integer)
    @column = T.let(start_column, Integer)
    @base_offset = T.let(start_offset, Integer)
    @file = T.let(file, T.nilable(String))
    @budget = T.let(budget || FrontendResourceBudget.new, FrontendResourceBudget)
    begin
      @budget.check_source!(source)
    rescue FrontendResourceBudget::Exceeded => e
      raise Error, "Lexer Error: frontend #{e.kind} resource limit exceeded (limit #{e.limit})"
    end
    @tokens = T.let([], T::Array[Token])
    @interpolation_depth = T.let(interpolation_depth, Integer)
  end

  sig { returns(T::Array[Token]) }
  def tokenize
    until @s.eos?
      # 1. Snapshot start column before scanning
      start_line = @line
      start_col = @column
      start_offset = current_offset

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
      when @s.scan(/\$\+/) then add(:CHAR, '$+', start_col)
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
        else raise Error, "Lexer Error: Unknown float suffix '_#{suffix}' at line #{@line}:#{@column}"
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
        read_interpolated_string(start_line, start_col, start_offset)

      else
        raise Error, "Lexer Error: Unexpected char: #{@s.peek(1).inspect} on line #{@line}:#{@column}"
      end
    end

    # Manually push EOF (don't use add() here as there is nothing matched)
    @tokens << source_token(:EOF, nil, @line, @column, current_offset, @line, @column, current_offset)
    @tokens
  end

  private

  sig { params(start_line: Integer, start_col: Integer, start_offset: Integer).void }
  def read_interpolated_string(start_line, start_col, start_offset)
    buffer = ""
    chunk_start_line = T.let(start_line, Integer)
    chunk_start_col = T.let(start_col, Integer)
    chunk_start_offset = T.let(start_offset, Integer)

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
          raise Error, "Lexer Error: \\x requires exactly 2 hex digits at line #{@line}:#{@column}" unless hex
          advance_pos(hex)
          buffer << hex.to_i(16).chr
        when 'u'                        # \u{HHHH} unicode codepoint -> UTF-8
          raise Error, "Lexer Error: \\u requires {hex} at line #{@line}:#{@column}" unless @s.peek(1) == '{'
          @s.getch; advance_pos('{')
          hex = @s.scan(/[0-9a-fA-F]{1,6}/)
          raise Error, "Lexer Error: invalid \\u{} escape at line #{@line}:#{@column}" unless hex
          advance_pos(hex)
          raise Error, "Lexer Error: unclosed \\u{} at line #{@line}:#{@column}" unless @s.peek(1) == '}'
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
        @tokens << source_token(:STRING, buffer, chunk_start_line, chunk_start_col,
          chunk_start_offset, @line, @column, current_offset)
        break

      elsif @s.peek(2) == '${'
        # String interpolation: ${expr}
        # Desugared to concatenation: "..." $+ (expr) $+ "..."

        if @interpolation_depth >= MAX_INTERPOLATION_DEPTH
          raise Error, "Lexer Error: string interpolation nesting exceeds #{MAX_INTERPOLATION_DEPTH} levels"
        end

        # 1. Emit current buffer
        interpolation_line = @line
        interpolation_col = @column
        interpolation_offset = current_offset
        @tokens << source_token(:STRING, buffer, chunk_start_line, chunk_start_col,
          chunk_start_offset, @line, @column, current_offset)
        buffer = ""

        # 2. Consume ${
        @s.getch; @s.getch
        advance_pos('${')

        # 3. Inject connector tokens: $+ (
        @tokens << source_token(:CHAR, '$+', interpolation_line, interpolation_col,
          interpolation_offset, interpolation_line, interpolation_col, interpolation_offset)
        @tokens << source_token(:CHAR, '(', interpolation_line, interpolation_col,
          interpolation_offset, interpolation_line, interpolation_col, interpolation_offset)

        # 4. Sub-lex the expression inside braces
        expr_line = @line
        expr_column = @column
        expr_offset = current_offset
        expr_source = extract_balanced_brace_content
        sub_lexer = Lexer.new(
          expr_source,
          interpolation_depth: @interpolation_depth + 1,
          file: @file,
          start_line: expr_line,
          start_column: expr_column,
          start_offset: expr_offset,
          budget: @budget,
        )
        sub_tokens = @budget.nested { sub_lexer.tokenize }
        sub_tokens.pop
        @tokens.concat(sub_tokens)

        # 5. Inject closer tokens: ) $+
        @tokens << source_token(:CHAR, ')', @line, @column, current_offset,
          @line, @column, current_offset)
        @tokens << source_token(:CHAR, '$+', @line, @column, current_offset,
          @line, @column, current_offset)

        chunk_start_line = @line
        chunk_start_col = @column
        chunk_start_offset = current_offset

      elsif @s.peek(1) == '$'
        # Bare $ (not followed by {) — literal character
        buffer << @s.getch
        advance_pos('$')
      else
        if @s.eos?
          raise Error, "Lexer Error: Unclosed string starting at line #{start_line}:#{start_col}"
        end
      end
    end
  end

  sig { returns(String) }
  def extract_balanced_brace_content
    content = ""
    depth = 1
    state = T.let(:code, Symbol)
    escaped = T.let(false, T::Boolean)

    until @s.eos?
      if state == :code && @s.peek(3) == '"""'
        raw = T.must(@s.scan(/"""/))
        content << raw
        advance_pos(raw)
        state = :triple_string
        next
      end

      ch = @s.getch
      break unless ch

      if state == :comment
        content << ch
        advance_pos(ch)
        state = :code if ch == "\n"
        next
      end

      if state == :string
        content << ch
        advance_pos(ch)
        if escaped
          escaped = false
        elsif ch == '\\'
          escaped = true
        elsif ch == '"'
          state = :code
        end
        next
      end

      if state == :triple_string
        content << ch
        advance_pos(ch)
        if ch == '"' && @s.peek(2) == '""'
          tail = T.must(@s.scan(/""/))
          content << tail
          advance_pos(tail)
          state = :code
        end
        next
      end

      if ch == '#'
        state = :comment
      elsif ch == '"'
        state = :string
      elsif ch == '{'
        depth += 1
      elsif ch == '}'
        depth -= 1
        if depth == 0
          advance_pos(ch)
          return content
        end
      end
      content << ch
      advance_pos(ch)
    end

    raise Error, "Lexer Error: Unclosed interpolation %{...}"
  end

  sig { params(type: Symbol, val: T.any(Float, Integer, String), col: Integer).returns(Integer) }
  def add(type, val, col)
    start_line = @line
    start_offset = current_offset - @s.matched.bytesize
    # Automatically update position based on the last matched string
    advance_pos(@s.matched)
    @tokens << source_token(type, val, start_line, col, start_offset,
      @line, @column, current_offset)
    current_offset
  end

  sig { returns(Integer) }
  def current_offset
    @base_offset + @s.pos
  end

  sig do
    params(
      type: Symbol,
      value: T.untyped,
      line: Integer,
      column: Integer,
      start_offset: Integer,
      end_line: Integer,
      end_column: Integer,
      end_offset: Integer,
    ).returns(Token)
  end
  def source_token(type, value, line, column, start_offset, end_line, end_column, end_offset)
    Token.new(type, value, line, column, @file, start_offset, end_offset, end_line, end_column)
  end

  sig { params(str: String).returns(Integer) }
  def advance_pos(str)
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
    raise Error, "Lexer Error: Unknown numeric suffix '_#{suffix}' at line #{@line}:#{@column}" unless range || suffix == 'f32' || suffix == 'f64'
    if range && !range.include?(val)
      raise Error, "Lexer Error: Literal #{@s.matched} overflows #{suffix} (range #{range})"
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
