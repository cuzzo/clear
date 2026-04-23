# CLEAR source formatter.
#
# Status: v1.1.
#
# v1.1 implements:
#   - Parse validation (refuse-on-error).
#   - Lossless tokenization preserving raw text (strings, comments, etc.).
#   - Intra-line spacing canonicalization:
#       * space around binary operators, `=`, after `,` and `;`
#       * no space inside `()` / `[]` / `{}`
#       * no space around `.` or `::`
#       * tense sigils (`!` `?` `%` `~`) attach to following type/sigil
#       * unary `-` / `!` / `~` attach at expression-start positions
#       * call/index attach: `foo(`, `foo[`, `)(`, `](`, `][`
#       * type annotation `:` — no space before, one space after
#   - Comment spacing: trailing `--` has 2 spaces before, 1 space after.
#   - FN one-liner expansion (§7): every FN becomes multi-line with body
#     statements split on `;` boundaries.
#   - STRUCT / UNION / ENUM (§3.8): one field/variant per line.
#   - 2-space indent recomputed from block structure (opens: `{` `THEN` `DO`
#     `->` line-terminal; closes: `END` `}` line-leading; outdents:
#     `ELSE` `ELSE_IF` `CATCH` `DEFAULT` line-leading).
#   - Blank-line normalization: collapse 3+ to 2, exactly one blank before
#     CATCH/DEFAULT, strip trailing blanks.
#   - Idempotent: fmt(fmt(x)) == fmt(x).
#
# Deferred to v1.2:
#   - FN signature forced wrap when >120 chars (§3.1).
#   - WITH forced wraps: 2+ captures, 1-cap >120, ON-clause shape (§3.2, §3.3).
#   - Pipeline forced wraps incl. `s> RECOVER` extra indent (§3.4, §3.7).
#   - Method chain forced wrap (§3.5).
#   - Pipeline/chain assignment drop when first line >80 (§3.6).
#
# Deferred to v2:
#   - Warn-only 120-char width reports.
#   - Ambiguous-comment-attachment detection + refuse-to-write.
#   - Continuation indent for arbitrary expression wrap.
#   - Integer `_` separator normalization.

require_relative '../ast/lexer'
require_relative '../ast/parser'
require 'strscan'
require 'set'

class Formatter
  class Error < StandardError; end

  INDENT = '  '

  # Tokens after which `-`/`!`/`~` is unary (attaches to the following token).
  EXPR_START_KEYWORDS = %w[
    RETURN IF THEN ELSE ELSE_IF WHILE DO FOR IN BG
    RAISE ASSERT OR AS CATCH DEFAULT MATCH WHEN
    TAP RECOVER EXIT PASS PRUNE GIVE TAKES COPY MOVE
    CLONE FREEZE LINK RESOLVE START YIELD
    SELECT WHERE INDEX REDUCE ORDER_BY LIMIT SKIP UNNEST
    DISTINCT EACH FIND ANY ALL COUNT SUM AVERAGE MIN MAX
    CONCURRENT SHARD TAKE_WHILE WINDOW JOIN MUTABLE
    ASSERT_RAISES CAPTURES SEQUENCE TRUE FALSE NIL
    NEXT CAST
  ].to_set.freeze

  EXPR_START_SYMS = [
    '(', '[', '{', ',', ';', '=', '<', '>', '+', '*', '/', '%', '?', ':'
  ].to_set.freeze

  EXPR_START_OPS = %w[
    == != <= >= && || ** += -= *= /= :: -> s>
    .. ..< ..<= ..= %* %+ %- !* !+ !-
  ].to_set.freeze

  OPEN_TERMINAL   = %w[-> { THEN DO].freeze
  CLOSE_LEADING   = %w[END }].freeze
  OUTDENT_LEADING = %w[ELSE ELSE_IF CATCH DEFAULT].freeze
  BLANK_BEFORE    = %w[CATCH DEFAULT].freeze

  # Keywords that attach directly to a following `(` — no space inserted.
  # Everything else gets a space between keyword and `(`.
  ATTACH_PAREN_AFTER = %w[
    WITH RETRY WINDOW RECOVER JOIN SHARD REDUCE
    ASSERT ASSERT_RAISES CAST
  ].to_set.freeze

  def self.format(source)
    new(source).format
  end

  def initialize(source)
    @source = source
  end

  def format
    validate_parse!
    tokens = FormatLexer.new(@source).tokenize
    Emitter.new(tokens).emit
  end

  private

  def validate_parse!
    ts = ::Lexer.new(@source).tokenize
    ::Parser.new(ts, @source).parse
  rescue => e
    raise Error, "parse error: #{e.message}"
  end
end

# -----------------------------------------------------------------------
# Lossless tokenizer.
#
# Unlike the main Lexer, this one preserves the raw source text of every
# token (including quotes around strings and interpolation expressions).
# String tokens are kept opaque: we don't decode escapes or desugar `${}`.
# -----------------------------------------------------------------------
class Formatter::FormatLexer
  Token = Struct.new(:type, :raw, :line, :col)

  NUMERIC_SUFFIX_RE = /i8|i16|i32|i64|u8|u16|u32|u64|f32|f64/.freeze

  def initialize(source)
    @src = source
    @s = StringScanner.new(source)
    @line = 1
    @col  = 1
    @out  = []
  end

  def tokenize
    until @s.eos?
      sl, sc = @line, @col
      case
      when m = @s.scan(/[ \t]+/)             then push(:WS, m, sl, sc)
      when m = @s.scan(/\r?\n/)              then push(:NL, m, sl, sc)
      when m = @s.scan(/--[^\n]*/)           then push(:COMMENT, m, sl, sc)
      when m = @s.scan(/"""(?:.|\n)*?"""/m)  then push(:STRING, m, sl, sc)
      when @s.peek(1) == '"'
        raw = consume_string
        push(:STRING, raw, sl, sc)
      when m = @s.scan(/->|s>|==|!=|>=|<=|&&|\|\||\*\*|\+=|-=|\*=|\/=|::|\.\.<=|\.\.=|\.\.<|\.\.\.|\.\.|%\*|%\+|%-|!\*|!\+|!-/)
        push(:OP, m, sl, sc)
      when m = @s.scan(/[=+\-*\/<>&|!.,;(){}\[\]:?~%]/)
        push(:SYM, m, sl, sc)
      when m = @s.scan(/[a-zA-Z_@]\w*[!?]?/)
        if ::Lexer::KEYWORDS.include?(m)
          push(:KEYWORD, m, sl, sc)
        elsif m =~ /\A[A-Z]/
          push(:TYPE_ID, m, sl, sc)
        else
          push(:VAR_ID, m, sl, sc)
        end
      # Numeric literals: support `_` as a digit group separator. The type
      # suffix (if any) is closed: i8/i16/i32/i64/u8/u16/u32/u64/f32/f64.
      # Patterns mirror the main Lexer so FormatLexer preserves the exact
      # source text (including separators).
      when m = @s.scan(/0x[0-9a-fA-F]+(?:_[0-9a-fA-F]+)*(?:_#{NUMERIC_SUFFIX_RE})?\b/o)
        push(:NUM, m, sl, sc)
      when m = @s.scan(/0o[0-7]+(?:_[0-7]+)*(?:_#{NUMERIC_SUFFIX_RE})?\b/o)
        push(:NUM, m, sl, sc)
      when m = @s.scan(/0b[0-1]+(?:_[0-1]+)*(?:_#{NUMERIC_SUFFIX_RE})?\b/o)
        push(:NUM, m, sl, sc)
      when m = @s.scan(/\d+(?:_\d+)*\.\d+(?:_\d+)*(?:_#{NUMERIC_SUFFIX_RE})?\b/o)
        push(:NUM, m, sl, sc)
      when m = @s.scan(/\d+(?:_\d+)*(?:_#{NUMERIC_SUFFIX_RE})?\b/o)
        push(:NUM, m, sl, sc)
      else
        raise Formatter::Error, "lex error at #{@line}:#{@col} near #{@s.peek(10).inspect}"
      end
    end
    @out
  end

  private

  # Consume balanced `"..."` string including `\` escapes and `${...}`
  # interpolation (which may nest braces). Returns raw source text
  # (including the surrounding quotes). Advances the scanner.
  def consume_string
    start = @s.pos
    @s.getch # opening quote
    depth = 0
    until @s.eos?
      c = @s.peek(1)
      if c == '\\'
        @s.getch
        @s.getch unless @s.eos?
        next
      end
      if depth == 0 && c == '"'
        @s.getch
        break
      end
      if c == '$' && @s.peek(2) == '${'
        @s.getch; @s.getch
        depth += 1
        next
      end
      if depth > 0 && c == '{'
        @s.getch
        depth += 1
        next
      end
      if depth > 0 && c == '}'
        @s.getch
        depth -= 1
        next
      end
      @s.getch
    end
    # NOTE: StringScanner#pos is a BYTE offset. Use byteslice so multi-byte
    # characters earlier in the source (e.g., `—` in comments) don't shift
    # the string-literal slice off its actual boundaries.
    @src.byteslice(start...@s.pos)
  end

  def push(type, raw, line, col)
    @out << Token.new(type, raw, line, col)
    advance(raw)
  end

  def advance(s)
    nl = s.count("\n")
    if nl > 0
      @line += nl
      last = s.rindex("\n")
      @col = s.length - last
    else
      @col += s.length
    end
  end
end

# -----------------------------------------------------------------------
# Emitter.
#
# Operates on a lossless token stream:
#   1. Drops :WS tokens; we regenerate spacing from scratch.
#   2. Applies structural transformations that may insert :NL tokens
#      (FN expansion, STRUCT/UNION/ENUM one-per-line).
#   3. Renders: walks tokens, emits canonical spacing, tracks block depth
#      for indent, normalizes blank lines, places comments.
# -----------------------------------------------------------------------
class Formatter::Emitter
  INDENT          = Formatter::INDENT
  OPEN_TERMINAL   = Formatter::OPEN_TERMINAL
  CLOSE_LEADING   = Formatter::CLOSE_LEADING
  OUTDENT_LEADING = Formatter::OUTDENT_LEADING
  BLANK_BEFORE    = Formatter::BLANK_BEFORE

  def initialize(tokens)
    @tokens = tokens
  end

  def emit
    toks = @tokens.reject { |t| t.type == :WS }
    toks = collapse_newlines(toks)
    toks = canonicalize_numerics(toks)
    toks = expand_fn_blocks(toks)
    toks = expand_then_do_blocks(toks)
    toks = expand_with_blocks(toks)
    toks = expand_pipelines(toks)
    toks = expand_method_chains(toks)
    toks = expand_bg_do_blocks(toks)
    toks = expand_record_types(toks)
    toks = expand_call_args(toks)
    toks = collapse_newlines(toks)
    render(toks)
  end

  private

  # ---- numeric literal canonicalization (§8) ----------------------------
  #
  # Decimal numeric literals get canonical `_` separators when either side
  # of the decimal has more than 4 digits. Integer side groups from the
  # right (`1_234_567`); fractional side groups from the left
  # (`0.123_456`). Numbers at or below 4 digits are canonicalized WITHOUT
  # separators (so `1_234` -> `1234` and `1000000` -> `1_000_000`). Type
  # suffixes (`_i32`, `_f64`, ...) are preserved. Hex/oct/bin literals
  # are left untouched — convention there varies (groups of 4, 3, 8) and
  # we leave the user's choice in place.
  def canonicalize_numerics(toks)
    toks.map do |t|
      next t unless t.type == :NUM
      Formatter::FormatLexer::Token.new(:NUM, canonicalize_numeric(t.raw), t.line, t.col)
    end
  end

  NUM_SUFFIX_TAIL_RE = /_(i8|i16|i32|i64|u8|u16|u32|u64|f32|f64)\z/.freeze

  def canonicalize_numeric(raw)
    return raw if raw.start_with?('0x', '0o', '0b')

    suffix = ''
    body = raw
    if (m = raw.match(NUM_SUFFIX_TAIL_RE))
      suffix = m[0]
      body = raw[0...m.begin(0)]
    end

    if body.include?('.')
      int_part, frac_part = body.split('.', 2)
      int_digits  = int_part.tr('_', '')
      frac_digits = frac_part.tr('_', '')
      int_out  = int_digits.length  > 4 ? group_from_right(int_digits)  : int_digits
      frac_out = frac_digits.length > 4 ? group_from_left(frac_digits) : frac_digits
      "#{int_out}.#{frac_out}#{suffix}"
    else
      digits = body.tr('_', '')
      out    = digits.length > 4 ? group_from_right(digits) : digits
      "#{out}#{suffix}"
    end
  end

  def group_from_right(digits)
    digits.reverse.scan(/.{1,3}/).join('_').reverse
  end

  def group_from_left(digits)
    digits.scan(/.{1,3}/).join('_')
  end

  # ---- pre-passes on the token stream ---------------------------------

  # Collapse runs of 3+ consecutive :NL into 2.
  def collapse_newlines(toks)
    out = []
    run = 0
    toks.each do |t|
      if t.type == :NL
        run += 1
        out << t if run <= 2
      else
        run = 0
        out << t
      end
    end
    out
  end

  # For each top-level `FN ... -> ... END` (or any nested FN), ensure that
  # the body is multi-line: a newline follows `->` and precedes `END`, and
  # statements in between are split on `;` boundaries.
  def expand_fn_blocks(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      if t.type == :KEYWORD && t.raw == 'FN'
        i = emit_fn_block(out, toks, i)
      else
        out << t
        i += 1
      end
    end
    out
  end

  # Emits a FN block starting at index `start` (token = 'FN') into `out`.
  # Returns the index after the matching `END`.
  def emit_fn_block(out, toks, start)
    # Copy up to and including the `->` that ends the signature.
    arrow_idx = find_fn_arrow(toks, start)
    unless arrow_idx
      out << toks[start]
      return start + 1
    end

    po, pc = find_fn_parens(toks, start, arrow_idx)
    if should_wrap_fn_sig?(toks, start, arrow_idx, po, pc)
      emit_fn_signature_wrapped(out, toks, start, arrow_idx, po, pc)
    else
      (start..arrow_idx).each { |j| out << toks[j] }
    end

    # Ensure exactly one :NL after the arrow (strip any blank line directly
    # after the signature — bodies start immediately at +1 indent).
    insert_nl(out)

    # Walk body, tracking depth, until matching END at depth 0.
    depth = 0
    j = arrow_idx + 1
    j = skip_nls(toks, j)
    body_start = out.length
    while j < toks.length
      tj = toks[j]
      if tj.type == :KEYWORD && tj.raw == 'END' && depth == 0
        break
      end
      # Nested END-terminated constructs: only the keywords whose scope
      # actually closes with END. Brace-terminated blocks (WITH/MATCH/
      # STRUCT/UNION/ENUM/BG) are handled by the `{`/`}` branches below.
      # Filter WITH (`CATCH Input WITH(...)`) is not a block opener.
      if tj.type == :KEYWORD && %w[FN IF WHILE FOR TEST WHEN].include?(tj.raw)
        if tj.raw == 'FN'
          j = emit_fn_block(out, toks, j)
          next
        else
          depth += 1
          out << tj
          j += 1
          next
        end
      end
      if tj.type == :KEYWORD && tj.raw == 'END'
        depth -= 1
        out << tj
        j += 1
        next
      end
      if tj.type == :SYM && tj.raw == '{'
        depth += 1
        out << tj
        j += 1
        next
      end
      if tj.type == :SYM && tj.raw == '}'
        depth -= 1
        out << tj
        j += 1
        next
      end
      # Statement boundary: `;` at depth 0 — force newline after it and
      # skip exactly one following source NL (it's redundant with the one
      # I just inserted). Additional source NLs pass through as blank lines.
      if tj.type == :SYM && tj.raw == ';' && depth == 0
        out << tj
        j += 1
        insert_nl(out)
        j += 1 if j < toks.length && toks[j].type == :NL
        next
      end
      # ELSE / ELSE_IF / CATCH / DEFAULT at this depth: ensure they start
      # on a new line.
      if tj.type == :KEYWORD && Formatter::OUTDENT_LEADING.include?(tj.raw) && depth == 0
        insert_nl(out)
        out << tj
        j += 1
        next
      end
      out << tj
      j += 1
    end

    # Strip any trailing NLs in the body and insert exactly one before END.
    if body_start < out.length
      out.pop while out.last && out.last.type == :NL && out.length > body_start
      insert_nl(out)
    end
    if j < toks.length
      out << toks[j]  # END
      j += 1
    end
    j
  end

  def skip_nls(toks, j)
    j += 1 while j < toks.length && toks[j].type == :NL
    j
  end

  # Locate the opening/closing parens of the FN param list. Returns
  # [po, pc] (both may be nil for FNs with no parens, though in CLEAR
  # they are mandatory).
  def find_fn_parens(toks, fn_idx, arrow_idx)
    po = nil; pc = nil; depth = 0
    j = fn_idx + 1
    while j < arrow_idx
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '('
          po ||= j
          depth += 1
        when ')'
          depth -= 1
          pc = j if depth == 0 && po
        end
      end
      j += 1
    end
    [po, pc]
  end

  # Wrap triggers (§3.1):
  #   (a) source already has NL between `(` and `)` (preserve wrap).
  #   (b) projected single-line length > 120 chars.
  def should_wrap_fn_sig?(toks, start, arrow_idx, po, pc)
    return false unless po && pc
    return true if (po + 1 ... pc).any? { |j| toks[j].type == :NL }
    inline = toks[start..arrow_idx].reject { |t| t.type == :NL }
    format_line_body(inline).length > 120
  end

  # Emit a wrapped FN signature:
  #   FN name(
  #     p1: T,
  #     p2: T
  #   )
  #   RETURNS T ->
  def emit_fn_signature_wrapped(out, toks, start, arrow_idx, po, pc)
    # Tokens from FN through and including `(`.
    (start..po).each { |j| out << toks[j] }

    insert_nl(out)
    out << phantom(:INDENT_OPEN)

    depth = 0
    j = po + 1
    j = skip_nls(toks, j)
    while j < pc
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then depth += 1; out << t; j += 1; next
        when ')', ']', '}' then depth -= 1; out << t; j += 1; next
        when ','
          if depth == 0
            out << t; j += 1
            insert_nl(out)
            j = skip_nls(toks, j)
            next
          end
        end
      end
      if t.type == :NL
        j += 1
        next
      end
      out << t
      j += 1
    end

    out << phantom(:INDENT_CLOSE)
    insert_nl(out)
    out << toks[pc]  # `)`
    insert_nl(out)

    # Emit RETURNS ... -> on its own line.
    j = pc + 1
    j = skip_nls(toks, j)
    while j <= arrow_idx
      t = toks[j]
      if t.type == :NL
        j += 1
        next
      end
      out << t
      j += 1
    end
  end

  def find_fn_arrow(toks, fn_idx)
    depth = 0
    j = fn_idx + 1
    while j < toks.length
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[' then depth += 1
        when ')', ']' then depth -= 1
        when '{', '}', ',', ';'
          return nil if depth == 0
        end
      elsif t.type == :OP && t.raw == '->' && depth == 0
        return j
      elsif t.type == :KEYWORD && t.raw == 'END' && depth == 0
        return nil
      end
      j += 1
    end
    nil
  end

  # Expand one-liner IF / WHILE / FOR blocks that use THEN or DO...END.
  # Detects blocks where no newline appears between the opening keyword and
  # the matching END, and expands them so the body is on its own line(s).
  # Multi-line forms are left untouched.
  def expand_then_do_blocks(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      if t.type == :KEYWORD && %w[IF WHILE FOR].include?(t.raw)
        end_idx = one_liner_end(toks, i)
        if end_idx
          i = expand_if_while_for(out, toks, i, end_idx)
        else
          out << t
          i += 1
        end
      else
        out << t
        i += 1
      end
    end
    out
  end

  # Returns the index of the matching END if and only if no :NL appears
  # anywhere between `start` and that END (i.e., the whole construct is
  # a single source line). Otherwise nil.
  def one_liner_end(toks, start)
    depth = 0
    j = start + 1
    while j < toks.length
      t = toks[j]
      return nil if t.type == :NL
      if t.type == :KEYWORD
        case t.raw
        when 'IF', 'WHILE', 'FOR', 'TEST', 'WHEN', 'FN'
          depth += 1
        when 'END'
          return j if depth == 0
          depth -= 1
        end
      elsif t.type == :SYM
        case t.raw
        when '{' then depth += 1
        when '}' then depth -= 1
        end
      end
      j += 1
    end
    nil
  end

  # Expand a one-liner `IF/WHILE/FOR ... THEN|DO ... END` between indices
  # `start` (keyword) and `end_idx` (matching END). Emits into `out` and
  # returns the index after END.
  def expand_if_while_for(out, toks, start, end_idx)
    # Find the THEN or DO terminator at depth 0.
    term_idx = nil
    depth = 0
    (start + 1...end_idx).each do |j|
      t = toks[j]
      if t.type == :SYM && t.raw == '('      then depth += 1
      elsif t.type == :SYM && t.raw == ')'   then depth -= 1
      elsif t.type == :SYM && t.raw == '['   then depth += 1
      elsif t.type == :SYM && t.raw == ']'   then depth -= 1
      elsif t.type == :KEYWORD && %w[THEN DO].include?(t.raw) && depth == 0
        term_idx = j
        break
      end
    end
    unless term_idx
      # No terminator found — don't rewrite.
      out << toks[start]
      return start + 1
    end

    # Copy up through the terminator.
    (start..term_idx).each { |j| out << toks[j] }
    insert_nl(out)

    # Walk body tokens. Split `;` boundaries; outdent ELSE/ELSE_IF.
    depth = 0
    j = term_idx + 1
    body_start = out.length
    while j < end_idx
      tj = toks[j]
      if tj.type == :SYM && tj.raw == '('      then depth += 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == ')'      then depth -= 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == '['      then depth += 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == ']'      then depth -= 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == '{'      then depth += 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == '}'      then depth -= 1; out << tj; j += 1; next end

      if tj.type == :SYM && tj.raw == ';' && depth == 0
        out << tj
        j += 1
        insert_nl(out)
        next
      end
      if tj.type == :KEYWORD && %w[ELSE ELSE_IF].include?(tj.raw) && depth == 0
        insert_nl(out)
        out << tj
        j += 1
        next
      end
      out << tj
      j += 1
    end

    # Strip any trailing NLs in body; insert exactly one before END.
    if body_start < out.length
      out.pop while out.last && out.last.type == :NL && out.length > body_start
      insert_nl(out)
    end
    out << toks[end_idx]  # END
    end_idx + 1
  end

  # ---- WITH forced wraps (§3.2, §3.3) -----------------------------------
  #
  # A block WITH has the shape `WITH caps... { body } [ON clause...]`. Two
  # triggers force multi-line layout:
  #   (a) 2+ capture clauses (comma-separated) — captures split onto their
  #       own lines, body at +2, `}` at +1.
  #   (b) any trailing ON ... / RETRY ... clause after `}` — `}` moves to
  #       its own line at +1, ON moves to +1, body at +2.
  # Both triggers can combine. `CATCH Input WITH(...)` filter uses
  # `WITH(`; it is NOT a block WITH and we leave it alone.
  def expand_with_blocks(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      if t.type == :KEYWORD && t.raw == 'WITH' && with_is_block?(toks, i)
        i = emit_with_block(out, toks, i)
      else
        out << t
        i += 1
      end
    end
    out
  end

  def with_is_block?(toks, idx)
    j = idx + 1
    while j < toks.length && [:NL, :COMMENT].include?(toks[j].type)
      j += 1
    end
    return true if j >= toks.length
    !(toks[j].type == :SYM && toks[j].raw == '(')
  end

  def emit_with_block(out, toks, start)
    brace_idx = find_with_open_brace(toks, start)
    unless brace_idx
      out << toks[start]
      return start + 1
    end
    close_idx = find_matching_close_brace(toks, brace_idx)
    unless close_idx
      out << toks[start]
      return start + 1
    end

    # Captures between WITH and `{`; count top-level commas + 1.
    cap_count = 1
    depth = 0
    (start + 1 ... brace_idx).each do |j|
      t = toks[j]
      next unless t.type == :SYM
      case t.raw
      when '(', '[' then depth += 1
      when ')', ']' then depth -= 1
      when ','      then cap_count += 1 if depth == 0
      end
    end

    on_end = consume_on_clause(toks, close_idx + 1)
    has_on = on_end > close_idx + 1
    multi_cap = cap_count >= 2

    unless multi_cap || has_on
      out << toks[start]
      return start + 1
    end

    # ---- apply wrap ----------------------------------------------------
    out << toks[start]  # WITH

    if multi_cap
      insert_nl(out)
      out << phantom(:INDENT_OPEN)
      depth = 0
      j = start + 1
      j = skip_nls(toks, j)
      while j < brace_idx
        t = toks[j]
        if t.type == :NL
          j += 1
          next
        end
        if t.type == :SYM && t.raw == ',' && depth == 0
          out << t
          j += 1
          insert_nl(out)
          j = skip_nls(toks, j)
          next
        end
        if t.type == :SYM
          case t.raw
          when '(', '[' then depth += 1
          when ')', ']' then depth -= 1
          end
        end
        out << t
        j += 1
      end
      out << toks[brace_idx]  # `{`
      # Body is at (captures:+1) + (`{`:+1) = +2 naturally.
    else
      # Single cap, has_on. Emit capture tokens as-is up to and including `{`.
      (start + 1 .. brace_idx).each { |j| out << toks[j] }
      # Body needs +2 but `{` only gives +1; add extra marker.
      out << phantom(:INDENT_OPEN)
    end

    insert_nl(out)
    j = skip_nls(toks, brace_idx + 1)
    while j < close_idx
      out << toks[j]
      j += 1
    end
    out.pop while out.last && out.last.type == :NL
    insert_nl(out)
    out << toks[close_idx]  # `}`

    if has_on
      # Emit ON clause tokens on their own line at +1.
      insert_nl(out)
      j = close_idx + 1
      j = skip_nls(toks, j)
      while j < on_end
        t = toks[j]
        j += 1
        next if t.type == :NL
        out << t
      end
    end

    # Attach INDENT_CLOSE to the end of the current line (after last code).
    # Source NL / trailing whitespace handles line termination from here.
    out << phantom(:INDENT_CLOSE)

    has_on ? on_end : close_idx + 1
  end

  def find_with_open_brace(toks, start)
    depth = 0
    j = start + 1
    while j < toks.length
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[' then depth += 1
        when ')', ']' then depth -= 1
        when '{' then return j if depth == 0
        end
      end
      j += 1
    end
    nil
  end

  def find_matching_close_brace(toks, open_idx)
    depth = 0
    j = open_idx + 1
    while j < toks.length
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '{' then depth += 1
        when '}'
          return j if depth == 0
          depth -= 1
        end
      end
      j += 1
    end
    nil
  end

  # Starting at `start` (one past `}`), attach any trailing
  # ON / RETRY segments. Returns the index of the last token of the ON
  # clause (usually a NL), or `start` if no clause. Does NOT advance past
  # NLs that follow the final ON segment — those blank lines belong to
  # the enclosing scope.
  def consume_on_clause(toks, start)
    cursor = start
    loop do
      peek = skip_nls(toks, cursor)
      break if peek >= toks.length
      t = toks[peek]
      break unless t.type == :KEYWORD && on_keyword?(t.raw)
      cursor = consume_on_segment(toks, peek)
    end
    cursor
  end

  def on_keyword?(raw)
    %w[ON RETRY POSSIBLE_DEADLOCK POSSIBLE_LOCK_CYCLE].include?(raw)
  end

  def consume_on_segment(toks, start)
    depth = 0
    j = start
    while j < toks.length
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then depth += 1
        when ')', ']', '}' then depth -= 1
        end
      end
      if t.type == :NL && depth == 0
        return j
      end
      j += 1
    end
    j
  end

  def phantom(type)
    Formatter::FormatLexer::Token.new(type, '', 0, 0)
  end

  # ---- Method chain wrap (§3.5) ------------------------------------------
  #
  # `.a().b().c()...` chains with 4+ segments OR total chain length > 80
  # chars wrap, one `.seg` per line at +1 from the receiver. A segment is
  # `.name` optionally followed by `(args)` or `[index]`.
  def expand_method_chains(toks)
    out = []
    i = 0
    while i < toks.length
      if method_chain_start?(toks, i, out)
        segments, chain_end = scan_chain_segments(toks, i)
        if segments.length >= 4 || chain_length_estimate(toks, segments) > 80
          insert_nl(out)
          out << phantom(:INDENT_OPEN)
          segments.each_with_index do |seg, k|
            insert_nl(out) if k > 0
            (seg[:start]...seg[:end]).each do |j|
              next if toks[j].type == :NL
              out << toks[j]
            end
          end
          out << phantom(:INDENT_CLOSE)
          i = chain_end
          next
        end
      end
      out << toks[i]
      i += 1
    end
    out
  end

  def method_chain_start?(toks, i, out)
    return false unless toks[i].type == :SYM && toks[i].raw == '.'
    prev = last_nontrivial_in_out(out)
    return false unless prev
    [:VAR_ID, :TYPE_ID].include?(prev.type) ||
      (prev.type == :SYM && [')', ']'].include?(prev.raw))
  end

  def last_nontrivial_in_out(out)
    j = out.length - 1
    while j >= 0
      t = out[j]
      break unless [:NL, :COMMENT, :INDENT_OPEN, :INDENT_CLOSE].include?(t.type)
      j -= 1
    end
    j >= 0 ? out[j] : nil
  end

  def scan_chain_segments(toks, start_idx)
    segments = []
    i = start_idx
    while i < toks.length && toks[i].type == :SYM && toks[i].raw == '.'
      seg_start = i
      i += 1
      # The segment name (identifier).
      break unless i < toks.length && [:VAR_ID, :TYPE_ID].include?(toks[i].type)
      i += 1
      # Optional (args) or [index].
      while i < toks.length && toks[i].type == :SYM && ['(', '['].include?(toks[i].raw)
        i = skip_matched_brackets(toks, i)
      end
      segments << { start: seg_start, end: i }
      # Skip any NLs between segments (chain may already be wrapped).
      while i < toks.length && toks[i].type == :NL
        i += 1
      end
    end
    [segments, segments.last ? segments.last[:end] : start_idx]
  end

  def skip_matched_brackets(toks, open_idx)
    opener = toks[open_idx].raw
    closer = (opener == '(') ? ')' : ']'
    depth = 0
    j = open_idx
    while j < toks.length
      t = toks[j]
      if t.type == :SYM
        if t.raw == opener then depth += 1
        elsif t.raw == closer
          depth -= 1
          return j + 1 if depth == 0
        end
      end
      j += 1
    end
    j
  end

  def chain_length_estimate(toks, segments)
    total = 0
    segments.each do |seg|
      (seg[:start]...seg[:end]).each do |j|
        t = toks[j]
        next if t.type == :NL
        total += t.raw.length
      end
    end
    total
  end

  # ---- Long call arg wrap (§3.9) -----------------------------------------
  #
  # A `(args)` call-list or `Type{fields}` struct-literal wraps when:
  #   (a) the interior already contains a newline (multi-line arg — e.g. a
  #       nested wrapped call), OR
  #   (b) the projected inline length (opener..closer) exceeds 120 chars.
  # When wrapped: opener stays on current line; each top-level arg on its
  # own line at +1; closer on its own line back at the call column.
  # Processed bottom-up via recursive descent so an inner wrap can trigger
  # an outer wrap.
  def expand_call_args(toks)
    process_call_arg_range(toks, 0, toks.length)
  end

  def process_call_arg_range(toks, start, stop)
    out = []
    prev_emitted = nil
    i = start
    while i < stop
      t = toks[i]
      kind = call_opener_kind(toks, i, prev_emitted)
      if kind
        closer = kind == :paren ? ')' : '}'
        close_idx = find_matching_paren_or_brace(toks, i, t.raw, closer)
        if close_idx && close_idx < stop
          inner = process_call_arg_range(toks, i + 1, close_idx)
          if call_args_need_wrap?(t.raw, inner, toks[close_idx].raw, out)
            emit_wrapped_args(out, t, inner, toks[close_idx])
          else
            out << t
            out.concat(inner)
            out << toks[close_idx]
          end
          prev_emitted = toks[close_idx]
          i = close_idx + 1
          next
        end
      end
      out << t
      prev_emitted = t unless [:NL, :COMMENT, :INDENT_OPEN, :INDENT_CLOSE].include?(t.type)
      i += 1
    end
    out
  end

  # :paren, :struct_lit, or nil. `prev_emitted` is the last non-whitespace
  # non-marker token we emitted into `out` (context for the opener).
  def call_opener_kind(toks, idx, prev_emitted)
    t = toks[idx]
    return nil unless t.type == :SYM
    if t.raw == '('
      return nil unless prev_emitted
      return :paren if [:VAR_ID, :TYPE_ID].include?(prev_emitted.type)
      return :paren if prev_emitted.type == :SYM && [')', ']'].include?(prev_emitted.raw)
      # Keywords that attach `(`, like `WITH(...)`, RETRY(...), RECOVER(...).
      return :paren if prev_emitted.type == :KEYWORD && Formatter::ATTACH_PAREN_AFTER.include?(prev_emitted.raw)
      return nil
    elsif t.raw == '{'
      return :struct_lit if prev_emitted && prev_emitted.type == :TYPE_ID
      return nil
    end
    nil
  end

  def find_matching_paren_or_brace(toks, open_idx, opener, closer)
    depth = 0
    j = open_idx
    while j < toks.length
      t = toks[j]
      if t.type == :SYM
        if t.raw == opener then depth += 1
        elsif t.raw == closer
          depth -= 1
          return j if depth == 0
        end
      end
      j += 1
    end
    nil
  end

  def call_args_need_wrap?(opener, inner, closer, out)
    return true if inner.any? { |t| t.type == :NL }
    prefix_len = current_line_length_in_out(out)
    call_len   = opener.length + format_line_body(inner).length + closer.length
    (prefix_len + call_len) > 120
  end

  # Approximate the projected length of the current output line (tokens
  # since the last NL). Ignores indent markers and NLs.
  def current_line_length_in_out(out)
    start = out.length - 1
    while start >= 0 && out[start].type != :NL
      start -= 1
    end
    segment = out[(start + 1)..] || []
    segment = segment.reject { |t| [:INDENT_OPEN, :INDENT_CLOSE, :NL].include?(t.type) }
    format_line_body(segment).length
  end

  def emit_wrapped_args(out, open_tok, inner, close_tok)
    # `{` is an OPEN_TERMINAL that the renderer already treats as +1
    # depth; `}` is CLOSE_LEADING that does -1. `(` and `)` are neither,
    # so the phantom markers provide the depth step for them.
    use_markers = (open_tok.raw == '(')

    out << open_tok
    insert_nl(out)
    out << phantom(:INDENT_OPEN) if use_markers

    depth = 0
    j = 0
    # Skip any leading NLs from `inner` so we don't emit a blank line
    # right after `(` / `{`.
    j += 1 while j < inner.length && inner[j].type == :NL
    while j < inner.length
      t = inner[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then depth += 1; out << t; j += 1; next
        when ')', ']', '}' then depth -= 1; out << t; j += 1; next
        when ','
          if depth == 0
            out << t
            j += 1
            insert_nl(out)
            j += 1 if j < inner.length && inner[j].type == :NL
            next
          end
        end
      end
      out << t
      j += 1
    end

    out.pop while out.last && out.last.type == :NL
    out << phantom(:INDENT_CLOSE) if use_markers
    insert_nl(out)
    out << close_tok
  end

  # ---- BG / DO multi-statement wrap (§3.10) ------------------------------
  #
  # `BG { ... }` (and `DO { ... }` fork-join branches) must be multi-line
  # when the body contains 2+ statements. Single-statement bodies stay
  # inline if they fit. Capability form `BG { @micro -> stmt }` is single
  # statement and stays inline.
  def expand_bg_do_blocks(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      if t.type == :KEYWORD && %w[BG DO].include?(t.raw)
        brace_idx = find_bg_brace(toks, i)
        if brace_idx
          close_idx = find_matching_close_brace(toks, brace_idx)
          if close_idx && count_statements_in_block(toks, brace_idx, close_idx) >= 2
            i = emit_bg_do_wrapped(out, toks, i, brace_idx, close_idx)
            next
          end
        end
      end
      out << t
      i += 1
    end
    out
  end

  def find_bg_brace(toks, start)
    j = start + 1
    while j < toks.length && [:NL, :COMMENT].include?(toks[j].type)
      j += 1
    end
    return j if j < toks.length && toks[j].type == :SYM && toks[j].raw == '{'
    nil
  end

  def count_statements_in_block(toks, open_brace, close_brace)
    depth = 0
    count = 0
    has_tokens = false
    (open_brace + 1 ... close_brace).each do |j|
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then depth += 1
        when ')', ']', '}' then depth -= 1
        when ';'
          if depth == 0
            count += 1 if has_tokens
            has_tokens = false
            next
          end
        end
      end
      next if [:NL, :COMMENT].include?(t.type)
      has_tokens = true
    end
    count += 1 if has_tokens
    count
  end

  def emit_bg_do_wrapped(out, toks, kw_idx, brace_idx, close_idx)
    # Emit BG/DO keyword through and including `{`, stripping any NLs.
    (kw_idx..brace_idx).each do |j|
      next if toks[j].type == :NL
      out << toks[j]
    end
    insert_nl(out)

    depth = 0
    j = brace_idx + 1
    j = skip_nls(toks, j)
    body_start = out.length
    while j < close_idx
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then depth += 1; out << t; j += 1; next
        when ')', ']', '}' then depth -= 1; out << t; j += 1; next
        when ';'
          if depth == 0
            out << t
            j += 1
            insert_nl(out)
            j += 1 if j < toks.length && toks[j].type == :NL
            next
          end
        end
      end
      out << t
      j += 1
    end

    if body_start < out.length
      out.pop while out.last && out.last.type == :NL && out.length > body_start
      insert_nl(out)
    end
    out << toks[close_idx]
    close_idx + 1
  end

  # ---- Pipeline forced wraps (§3.4, §3.7) --------------------------------
  #
  # When a pipeline chain has 2+ `s>` stages (at the same expression depth,
  # before any `;` / `,` / closing bracket), each stage renders on its own
  # line at +1 from the receiver.
  #
  # `s> RECOVER(...)` gets one extra indent level relative to its sibling
  # stages:  users s> a s> RECOVER(default) s> b  ->
  #   users
  #     s> a
  #     s> RECOVER(default)    <-- +1 more
  #     s> b
  def expand_pipelines(toks)
    chains = find_s_chains(toks)
    return toks if chains.empty?

    s_to_chain = {}
    chains.each { |c| c[:s_idxs].each { |idx| s_to_chain[idx] = c } }
    recover_s = detect_recover_stages(toks, chains)

    out = []
    i = 0
    while i < toks.length
      chain = s_to_chain[i]
      if chain && chain[:s_idxs].first == i
        i = emit_chain(out, toks, chain, recover_s)
      else
        out << toks[i]
        i += 1
      end
    end
    out
  end

  def find_s_chains(toks)
    chains = []
    i = 0
    while i < toks.length
      if toks[i].type == :OP && toks[i].raw == 's>'
        s_idxs = [i]
        depth = 0
        j = i + 1
        while j < toks.length
          t = toks[j]
          if t.type == :SYM
            case t.raw
            when '(', '[', '{' then depth += 1
            when ')', ']', '}'
              if depth == 0
                break
              else
                depth -= 1
              end
            when ',', ';'
              break if depth == 0
            end
          elsif t.type == :OP && t.raw == 's>' && depth == 0
            s_idxs << j
          end
          j += 1
        end
        chains << { s_idxs: s_idxs, end_idx: j } if s_idxs.length >= 2
        i = j
      else
        i += 1
      end
    end
    chains
  end

  def detect_recover_stages(toks, chains)
    result = {}
    chains.each do |c|
      c[:s_idxs].each do |idx|
        j = idx + 1
        j += 1 while j < toks.length && toks[j].type == :NL
        if j < toks.length && toks[j].type == :KEYWORD && toks[j].raw == 'RECOVER'
          result[idx] = true
        end
      end
    end
    result
  end

  # Emit a wrapped pipeline chain. Each stage on its own line at +1
  # (relative to receiver). Stages that are `s> RECOVER(...)` get an
  # additional +1. Strips source NLs inside stages so the canonical
  # layout wins regardless of the input layout.
  def emit_chain(out, toks, chain, recover_s)
    s_idxs  = chain[:s_idxs]
    end_idx = chain[:end_idx]

    insert_nl(out)
    out << phantom(:INDENT_OPEN)

    s_idxs.each_with_index do |s_idx, k|
      next_bound = s_idxs[k + 1] || end_idx
      recover    = recover_s[s_idx]

      insert_nl(out) if k > 0
      out << phantom(:INDENT_OPEN) if recover

      out << toks[s_idx]  # s>

      (s_idx + 1 ... next_bound).each do |j|
        next if toks[j].type == :NL  # discard source NLs inside a stage
        out << toks[j]
      end

      out << phantom(:INDENT_CLOSE) if recover
    end

    out << phantom(:INDENT_CLOSE)
    end_idx
  end

  # Split STRUCT / UNION / ENUM blocks so each field/variant is its own line.
  def expand_record_types(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      if t.type == :KEYWORD && %w[STRUCT UNION ENUM].include?(t.raw)
        i = emit_record_type(out, toks, i)
      else
        out << t
        i += 1
      end
    end
    out
  end

  def emit_record_type(out, toks, start)
    # Copy tokens until the opening `{`.
    j = start
    while j < toks.length
      t = toks[j]
      out << t
      j += 1
      break if t.type == :SYM && t.raw == '{'
    end
    return j if j >= toks.length

    # Canonicalize: exactly one NL after `{`, one NL after each top-level
    # `,`, one NL before `}`. Internal NLs/comments (e.g., default-method
    # FN declarations with leading comments in UNION bodies) are preserved.
    insert_nl(out)
    j = skip_nls(toks, j)

    depth = 0
    body_start = out.length
    while j < toks.length
      t = toks[j]
      if t.type == :SYM && t.raw == '{'
        depth += 1; out << t; j += 1; next
      end
      if t.type == :SYM && t.raw == '}'
        if depth == 0
          break
        else
          depth -= 1; out << t; j += 1; next
        end
      end
      if t.type == :SYM && t.raw == '(' then depth += 1; out << t; j += 1; next end
      if t.type == :SYM && t.raw == ')' then depth -= 1; out << t; j += 1; next end
      if t.type == :SYM && t.raw == '[' then depth += 1; out << t; j += 1; next end
      if t.type == :SYM && t.raw == ']' then depth -= 1; out << t; j += 1; next end
      if t.type == :SYM && t.raw == ',' && depth == 0
        out << t; j += 1
        insert_nl(out)
        j += 1 if j < toks.length && toks[j].type == :NL
        next
      end
      out << t
      j += 1
    end

    if body_start < out.length
      out.pop while out.last && out.last.type == :NL && out.length > body_start
      insert_nl(out)
    end
    if j < toks.length
      out << toks[j]  # `}`
      j += 1
    end
    j
  end

  # Ensure the last token in `out` is exactly one :NL. If the last token
  # is already :NL, leave it. Otherwise append a fresh :NL.
  def insert_nl(out)
    return if out.last && out.last.type == :NL
    out << Formatter::FormatLexer::Token.new(:NL, "\n", 0, 0)
  end

  # ---- rendering ------------------------------------------------------

  # Walks the transformed token stream and produces the final string.
  # Maintains: indent depth, per-line buffers, last non-comment code token
  # (for spacing decisions). `:INDENT_OPEN` / `:INDENT_CLOSE` phantom tokens
  # adjust depth for forced wraps where no `{` / `END` drives the change.
  def render(toks)
    lines = tokens_to_lines(toks)
    lines = ensure_blank_before_catch(lines)
    lines = drop_trailing_blanks(lines)

    depth = 0
    out = +""
    lines.each do |raw_line|
      pre_delta, post_delta, line = split_indent_markers(raw_line)
      depth = [depth + pre_delta, 0].max

      if line.empty?
        out << "\n"
        depth = [depth + post_delta, 0].max
        next
      end

      first = first_code(line)
      last  = last_code(line)

      line_depth = depth
      if first && CLOSE_LEADING.include?(first.raw)
        depth = [depth - 1, 0].max
        line_depth = depth
      elsif first && OUTDENT_LEADING.include?(first.raw)
        line_depth = [depth - 1, 0].max
      end

      out << (INDENT * line_depth)
      out << format_line_body(line)
      out << "\n"

      if last && OPEN_TERMINAL.include?(last.raw)
        depth += 1
      end
      depth = [depth + post_delta, 0].max
    end
    out
  end

  # Extract INDENT_OPEN/INDENT_CLOSE markers from a line. Markers that
  # appear before any code token adjust depth BEFORE the line renders
  # (pre_delta); markers that appear after code adjust depth after
  # (post_delta). Returns [pre_delta, post_delta, filtered_line].
  def split_indent_markers(line)
    pre = 0
    post = 0
    filtered = []
    seen_code = false
    line.each do |t|
      if t.type == :INDENT_OPEN
        seen_code ? post += 1 : pre += 1
      elsif t.type == :INDENT_CLOSE
        seen_code ? post -= 1 : pre -= 1
      else
        filtered << t
        seen_code = true if t.type != :COMMENT
      end
    end
    [pre, post, filtered]
  end

  def tokens_to_lines(toks)
    lines = []
    cur = []
    toks.each do |t|
      if t.type == :NL
        lines << cur
        cur = []
      else
        cur << t
      end
    end
    lines << cur unless cur.empty?
    lines
  end

  def first_code(line)
    line.find { |t| t.type != :COMMENT }
  end

  def last_code(line)
    line.reverse.find { |t| t.type != :COMMENT }
  end

  def ensure_blank_before_catch(lines)
    out = []
    lines.each do |line|
      fc = first_code(line)
      if fc && BLANK_BEFORE.include?(fc.raw) && !out.empty?
        # Strip any existing trailing blanks and insert exactly one.
        out.pop while out.last && out.last.empty?
        out << [] unless out.empty?
      end
      out << line
    end
    out
  end

  def drop_trailing_blanks(lines)
    lines = lines.dup
    lines.pop while lines.last && lines.last.empty?
    lines
  end

  # Emit a line's tokens with canonical intra-line spacing.
  # Comments get 2-space prefix if inline, 1 space after `--`.
  def format_line_body(line)
    buf = +""
    prev = nil  # previous emitted *code* token
    line.each_with_index do |t, idx|
      if t.type == :COMMENT
        # Trailing (inline) comment if any code precedes on this line.
        body = canonicalize_comment(t.raw)
        if prev
          buf << '  '
          buf << body
        else
          # Standalone leading comment on its own line.
          buf << body
        end
        next
      end
      if prev
        buf << ' ' if needs_space?(prev, t, line, idx)
      end
      buf << t.raw
      prev = t
    end
    buf
  end

  # Normalize a `--...` comment: exactly one space after `--`, trailing
  # whitespace stripped. `--` alone (empty comment) stays `--`.
  def canonicalize_comment(raw)
    body = raw[2..].to_s
    body = body.rstrip
    return '--' if body.empty?
    body = body.sub(/\A\s+/, '')
    "-- #{body}"
  end

  # Spacing decision between two adjacent code tokens A (prev) and B (cur).
  def needs_space?(a, b, line, b_idx)
    # Capability attach (§4): @X flush-attaches to a type token when the
    # position is a type context (struct field, param type, RETURNS type).
    # Value position (`1 @locked`, `foo() @locked`) keeps the space.
    if b.type == :VAR_ID && b.raw.start_with?('@')
      type_like_prev = a.type == :TYPE_ID || (a.type == :SYM && a.raw == ']')
      return false if type_like_prev && in_type_context?(line, b_idx - 1)
    end

    # No space inside opening/closing brackets.
    return false if a.type == :SYM && ['(', '[', '{'].include?(a.raw)
    return false if b.type == :SYM && [')', ']', '}'].include?(b.raw)

    # No space around `.` or `::`.
    return false if a.type == :SYM && a.raw == '.'
    return false if b.type == :SYM && b.raw == '.'
    return false if a.type == :OP  && a.raw == '::'
    return false if b.type == :OP  && b.raw == '::'

    # Call / index attach.
    if b.type == :SYM && b.raw == '('
      return false if [:VAR_ID, :TYPE_ID].include?(a.type)
      return false if a.type == :SYM && [')', ']'].include?(a.raw)
      return false if a.type == :KEYWORD && Formatter::ATTACH_PAREN_AFTER.include?(a.raw)
    end
    if b.type == :SYM && b.raw == '['
      return false if [:VAR_ID, :TYPE_ID].include?(a.type)
      return false if a.type == :SYM && [')', ']'].include?(a.raw)
    end

    # No space before `,` or `;`.
    if b.type == :SYM && (b.raw == ',' || b.raw == ';')
      return false
    end

    # Type annotation `:` — no space before, space after (default).
    if b.type == :SYM && b.raw == ':'
      return false
    end

    # Tense sigils (`!` `?` `%` `~`) attach to following type / sigil.
    if a.type == :SYM && %w[! ? % ~].include?(a.raw)
      if b.type == :TYPE_ID
        return false
      end
      if b.type == :SYM && %w[! ? % ~].include?(b.raw)
        return false
      end
      # Unary use at expression start: attach.
      if unary_context?(line, b_idx - 1)
        return false
      end
    end

    # Unary `-` at expression start: attach (e.g., `-1`).
    if a.type == :SYM && a.raw == '-' && unary_context?(line, b_idx - 1)
      return false
    end

    # `%` as modulus needs space; as sigil handled above. Default: space.

    # Default: one space.
    true
  end

  # Scan back from `line[idx]` to determine whether the position is a
  # type-annotation context. Returns true if the nearest non-nested
  # separator is `:` or `RETURNS`; false for `=` / `,` / `;` / start.
  def in_type_context?(line, idx)
    depth = 0
    j = idx
    while j >= 0
      t = line[j]
      j -= 1
      next if [:NL, :COMMENT, :INDENT_OPEN, :INDENT_CLOSE].include?(t.type)
      if t.type == :SYM
        case t.raw
        when ')', ']', '}' then depth += 1
        when '(', '[', '{'
          depth -= 1
          return false if depth < 0
        when ',', ';', '='
          return false if depth == 0
        when ':'
          return true if depth == 0
        end
      elsif t.type == :KEYWORD && t.raw == 'RETURNS' && depth == 0
        return true
      end
    end
    false
  end

  # Is position `a_idx` in `line` a unary-operator context — i.e., does
  # the token at `a_idx` appear at the start of an expression?
  #
  # This is true when the previous non-comment token is one of a set of
  # keywords/symbols/operators that end an expression.
  def unary_context?(line, a_idx)
    j = a_idx - 1
    while j >= 0
      prev = line[j]
      j -= 1
      next if prev.type == :COMMENT
      case prev.type
      when :KEYWORD
        return Formatter::EXPR_START_KEYWORDS.include?(prev.raw)
      when :SYM
        return true if Formatter::EXPR_START_SYMS.include?(prev.raw)
        return false
      when :OP
        return true if Formatter::EXPR_START_OPS.include?(prev.raw)
        return false
      else
        return false
      end
    end
    true  # start of line — treat as expression start
  end
end
