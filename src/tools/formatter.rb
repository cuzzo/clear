# typed: strict
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
#   - Comment spacing: trailing `#` has 2 spaces before, 1 space after.
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
#   - Pipeline forced wraps incl. `|> RECOVER` extra indent (§3.4, §3.7).
#   - Method chain forced wrap (§3.5).
#   - Pipeline/chain assignment drop when first line >80 (§3.6).
#
# Deferred to v2:
#   - Warn-only 120-char width reports.
#   - Ambiguous-comment-attachment detection + refuse-to-write.
#   - Continuation indent for arbitrary expression wrap.
#   - Integer `_` separator normalization.

require "sorbet-runtime"

require_relative '../ast/lexer'
require_relative '../ast/parser'
require_relative 'method_rewriter'
require_relative 'predicate_rewriter'
require_relative 'lint_fix_rewriter'
require 'strscan'
require 'set'

class Formatter
    extend T::Sig

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
    == != <= >= && || ** += -= *= /= :: -> |>
    .. ..< ..<= ..= %* %+ %- !* !+ !-
  ].to_set.freeze

  OPEN_TERMINAL   = %w[-> { THEN DO START].freeze
  CLOSE_LEADING   = %w[END }].freeze
  OUTDENT_LEADING = %w[ELSE ELSE_IF CATCH DEFAULT].freeze
  BLANK_BEFORE    = %w[CATCH DEFAULT].freeze

  # Keywords that attach directly to a following `(` — no space inserted.
  # Everything else gets a space between keyword and `(`.
  ATTACH_PAREN_AFTER = %w[
    WITH RETRY WINDOW RECOVER JOIN SHARD REDUCE CONCURRENT
    ASSERT ASSERT_RAISES CAST
  ].to_set.freeze

  sig { params(source: String).returns(T.nilable(String)) }
  def self.format(source)
    new(source).format
  end

  sig { params(source: String).void }
  def initialize(source)
    @source = source
  end

  sig { returns(T.nilable(String)) }
  def format
    validate_parse!
    # Lint-fix pre-pass: drop unused MUTABLE keywords and redundant
    # `: Type` annotations. Runs first so subsequent rewriters see
    # the cleanest source. Falls back to the original on annotation
    # failure (fmt must format files with errors).
    rewritten = LintFixRewriter.rewrite(@source)
    # Predicate canonicalization runs before METHOD-UFCS rewriting:
    # `x == NIL` -> `x.nil?()` may produce a new prefix call site
    # that MethodRewriter then converts to UFCS form. Doing them in
    # the reverse order would miss the second pass.
    rewritten = PredicateRewriter.rewrite(rewritten)
    rewritten = MethodRewriter.rewrite(rewritten)
    tokens = FormatLexer.new(rewritten).tokenize
    Emitter.new(tokens).emit
  end

  private

  sig { returns(T.nilable(AST::Program)) }
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
    extend T::Sig

  Token = Struct.new(:type, :raw, :line, :col)

  NUMERIC_SUFFIX_RE = /i8|i16|i32|i64|u8|u16|u32|u64|f32|f64/.freeze

  sig { params(source: String).void }
  def initialize(source)
    @src = source
    @s = T.let(StringScanner.new(source), StringScanner)
    @line = T.let(1, Integer)
    @col  = T.let(1, Integer)
    @out  = T.let([], T::Array[T.untyped])
  end

  sig { returns(T.nilable(Array)) }
  def tokenize
    until @s.eos?
      sl, sc = @line, @col
      case
      when m = @s.scan(/[ \t]+/)             then push(:WS, m, sl, sc)
      when m = @s.scan(/\r?\n/)              then push(:NL, m, sl, sc)
      when m = @s.scan(/#[^\n]*/)            then push(:COMMENT, m, sl, sc)
      when m = @s.scan(/"""(?:.|\n)*?"""/m)  then push(:STRING, m, sl, sc)
      when @s.peek(1) == '"'
        raw = consume_string
        push(:STRING, raw, sl, sc)
      when m = @s.scan(/->|\|>|==|!=|>=|<=|&&|\|\||\*\*|\+=|-=|\*=|\/=|::|\.\.<=|\.\.=|\.\.<|\.\.\.|\.\.|%\*|%\+|%-|!\*|!\+|!-/)
        push(:OP, m, sl, sc)
      when m = @s.scan(/[=+\-*\/<>&|!.,;(){}\[\]:?~%]/)
        push(:SYM, m, sl, sc)
      when m = @s.scan(/[a-zA-Z_@$]\w*[!?]?/)
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
  sig { returns(String) }
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

  sig { params(type: Symbol, raw: String, line: Integer, col: Integer).returns(Integer) }
  def push(type, raw, line, col)
    @out << Token.new(type, raw, line, col)
    advance(raw)
  end

  sig { params(s: String).returns(Integer) }
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
    extend T::Sig

  INDENT          = Formatter::INDENT
  OPEN_TERMINAL   = Formatter::OPEN_TERMINAL
  CLOSE_LEADING   = Formatter::CLOSE_LEADING
  OUTDENT_LEADING = Formatter::OUTDENT_LEADING
  BLANK_BEFORE    = Formatter::BLANK_BEFORE

  # State for emitting one FN signature. Reek flagged the
  # (toks, start, arrow_idx, po, pc) clump across 5 methods.
  FnSig = Data.define(:toks, :start, :arrow_idx, :po, :pc)

  sig { params(tokens: Array).void }
  def initialize(tokens)
    @tokens = tokens
  end

  sig { returns(String) }
  def emit
    toks = @tokens.reject { |t| t.type == :WS }
    toks = collapse_newlines(toks)
    toks = canonicalize_numerics(toks)
    toks = expand_match_blocks(toks)
    toks = expand_fn_blocks(toks)
    toks = expand_then_do_blocks(toks)
    toks = expand_with_blocks(toks)
    toks = expand_pipelines(toks)
    toks = expand_concurrent_drops(toks)
    toks = expand_method_chains(toks)
    toks = expand_bg_do_blocks(toks)
    toks = expand_record_types(toks)
    toks = expand_call_args(toks)
    toks = nl_after_end(toks)
    toks = collapse_newlines(toks)
    render(toks)
  end

  # `END` always opens a new line. Whatever follows (a continuation
  # statement, an outer END, an `;`-less return-expression) belongs on
  # its own line at the corresponding indent. Without this pass, an
  # inner-IF inside a MATCH arm body emitted `END RETURN "false";`
  # because no walker forced a break after END. (Repro:
  # examples/json_parser/jsonToString JBool arm.) Excludes the case
  # where END is followed by a close-bracket — `BG { ... END }` keeps
  # the `}` on the next render line via CLOSE_LEADING anyway.
  sig { params(toks: Array).returns(Array) }
  def nl_after_end(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      out << t
      if t.type == :KEYWORD && t.raw == 'END'
        k = i + 1
        k += 1 while k < toks.length && [:COMMENT].include?(toks[k].type)
        if k < toks.length
          nxt = toks[k]
          should_nl = !(nxt.type == :NL ||
                       (nxt.type == :SYM && [')', ']', '}', ';'].include?(nxt.raw)))
          insert_nl(out) if should_nl
        end
      end
      i += 1
    end
    out
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
  sig { params(toks: Array).returns(Array) }
  def canonicalize_numerics(toks)
    toks.map do |t|
      next t unless t.type == :NUM
      Formatter::FormatLexer::Token.new(:NUM, canonicalize_numeric(t.raw), t.line, t.col)
    end
  end

  NUM_SUFFIX_TAIL_RE = /_(i8|i16|i32|i64|u8|u16|u32|u64|f32|f64)\z/.freeze

  sig { params(raw: String).returns(String) }
  def canonicalize_numeric(raw)
    return raw if raw.start_with?('0x', '0o', '0b')

    suffix = ''
    body = raw
    if (m = raw.match(NUM_SUFFIX_TAIL_RE))
      suffix = m[0]
      body = raw[0...m.begin(0)]
    end

    has_decimal = body.include?('.')

    # Strip the default-type suffixes:
    #   * integer literals default to i64, so `42_i64` -> `42`
    #   * decimal literals default to f64, so `1.0_f64` -> `1.0`
    # Other suffixes (i32, u8, f32, ...) are kept -- they encode a
    # non-default type that the suffix is the only way to express.
    # `1_f64` (integer with float suffix) is NOT stripped: dropping it
    # would silently change the type to i64.
    if suffix == '_i64' && !has_decimal
      suffix = ''
    elsif suffix == '_f64' && has_decimal
      suffix = ''
    end

    if has_decimal
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

  sig { params(digits: String).returns(String) }
  def group_from_right(digits)
    digits.reverse.scan(/.{1,3}/).join('_').reverse
  end

  sig { params(digits: String).returns(String) }
  def group_from_left(digits)
    digits.scan(/.{1,3}/).join('_')
  end

  # ---- pre-passes on the token stream ---------------------------------

  # Collapse runs of 3+ consecutive :NL into 2.
  sig { params(toks: Array).returns(Array) }
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

  # ---- MATCH layout (§3.7) ---------------------------------------------
  #
  # `[PARTIAL] MATCH expr START arm, arm, ..., DEFAULT -> stmt; END`
  # — expand to multi-line form with arms one-per-line at MATCH+1 indent.
  # Multi-statement arms (multiple `;` after `->`) put the body on its
  # own lines at MATCH+2 indent. The body lifts back to arm-depth via a
  # phantom INDENT_CLOSE before the trailing `,` (or before END for the
  # last arm). DEFAULT in arm position is wrapped in INDENT_OPEN/CLOSE
  # phantoms so its OUTDENT_LEADING render rule (used for CATCH/DEFAULT
  # in TRY/CATCH) is canceled — in MATCH it is just an arm pattern at
  # arm-depth.
  sig { params(toks: Array).returns(Array) }
  def expand_match_blocks(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      if t.type == :KEYWORD && t.raw == 'START' && match_block_start?(toks, i)
        end_idx = find_match_block_end(toks, i)
        if end_idx
          i = emit_match_block(out, toks, i, end_idx)
          next
        end
      end
      out << t
      i += 1
    end
    out
  end

  # True when the `START` keyword at `idx` belongs to a `MATCH ... START`
  # construct (not `SYNC POLICY START`). Walks back at depth 0 and looks
  # for `MATCH` before any statement boundary; returns false if it sees
  # `POLICY` first.
  sig { params(toks: Array, idx: Integer).returns(T::Boolean) }
  def match_block_start?(toks, idx)
    depth = 0
    j = idx - 1
    while j >= 0
      t = toks[j]
      if t.type == :KEYWORD
        return true if t.raw == 'MATCH'
        return false if t.raw == 'POLICY'
        return false if %w[FN END THEN DO ELSE ELSE_IF CATCH].include?(t.raw)
      end
      if t.type == :SYM
        case t.raw
        when ')', ']', '}' then depth += 1
        when '(', '[', '{'
          depth -= 1
          return false if depth < 0
        when ';'
          return false if depth.zero?
        end
      end
      j -= 1
    end
    false
  end

  # Find the END that closes the MATCH block whose START is at `start_idx`.
  # Tracks nested keyword blocks (anything that opens a matching END) and
  # bracket depth so a stray `END` inside a nested IF/FOR isn't mistaken
  # for the closer.
  sig { params(toks: Array, start_idx: Integer).returns(T.nilable(Integer)) }
  def find_match_block_end(toks, start_idx)
    bdepth = 0
    kdepth = 0
    j = start_idx + 1
    while j < toks.length
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then bdepth += 1
        when ')', ']', '}' then bdepth -= 1
        end
      elsif bdepth.zero? && t.type == :KEYWORD
        case t.raw
        when 'IF', 'WHILE', 'FOR', 'TEST', 'WHEN', 'FN', 'START'
          kdepth += 1
        when 'END'
          return j if kdepth.zero?
          kdepth -= 1
        end
      end
      j += 1
    end
    nil
  end

  # Lay out a MATCH block from `start_idx` (`START`) to `end_idx` (`END`).
  sig { params(out: Array, toks: Array, start_idx: Integer, end_idx: Integer).returns(Integer) }
  def emit_match_block(out, toks, start_idx, end_idx)
    out << toks[start_idx]
    insert_nl(out)

    arms = scan_match_arms(toks, start_idx + 1, end_idx)
    arms.each do |arm|
      emit_match_arm(out, toks, arm)
    end

    out << toks[end_idx]
    end_idx + 1
  end

  # Returns a list of arm hashes: { start:, end:, arrow:, sep:, multi: }.
  # `start..end` covers the arm tokens (excluding the trailing separator).
  # `sep` is the index of the separating `,` (or nil for the last arm).
  # `arrow` is the index of the arm's top-level `->` (or nil for bare
  # arms like `DEFAULT` followed by an unparenthesized expression).
  # `multi` is true if the arm body has more than one statement or
  # contains a nested keyword block (IF/FOR/WHILE/...).
  sig { params(toks: Array, start: Integer, stop: Integer).returns(Array) }
  def scan_match_arms(toks, start, stop)
    arms = []
    arm_start = skip_nls(toks, start)
    return arms if arm_start >= stop

    bdepth = 0
    kdepth = 0
    arrow_idx = nil
    j = arm_start
    while j < stop
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then bdepth += 1
        when ')', ']', '}' then bdepth -= 1
        when ','
          if bdepth.zero? && kdepth.zero?
            arms << build_match_arm(toks, arm_start, j, arrow_idx, j)
            arm_start = skip_nls(toks, j + 1)
            j = arm_start
            arrow_idx = nil
            next
          end
        end
      elsif t.type == :OP && t.raw == '->' && bdepth.zero? && kdepth.zero?
        arrow_idx ||= j
      elsif t.type == :KEYWORD && bdepth.zero?
        case t.raw
        when 'IF', 'WHILE', 'FOR', 'TEST', 'WHEN', 'FN', 'START'
          kdepth += 1
        when 'END'
          kdepth -= 1 if kdepth.positive?
        end
      end
      j += 1
    end
    arms << build_match_arm(toks, arm_start, stop, arrow_idx, nil) if arm_start < stop
    arms
  end

  sig { params(toks: Array, s: Integer, e: Integer, arrow: T.nilable(Integer), sep: T.nilable(Integer)).returns(Hash) }
  def build_match_arm(toks, s, e, arrow, sep)
    body_end = sep || e
    semi_count = 0
    has_block = false
    has_comment = false
    bdepth = 0
    kdepth = 0
    if arrow
      ((arrow + 1)...body_end).each do |k|
        t = toks[k]
        if t.type == :COMMENT
          # `#` line comments inside an arm body MUST keep their own
          # line. Without this, copy_arm_tokens drops the NL separator
          # between the comment and the body, producing
          # `Pat ->  # tag stmt;,` which Zig-of-CLEAR cannot parse —
          # the comment extends to end-of-line and eats the body.
          has_comment = true if bdepth.zero? && kdepth.zero?
        elsif t.type == :SYM
          case t.raw
          when '(', '[', '{' then bdepth += 1
          when ')', ']', '}' then bdepth -= 1
          when ';'
            semi_count += 1 if bdepth.zero? && kdepth.zero?
          end
        elsif t.type == :KEYWORD && bdepth.zero?
          case t.raw
          when 'IF', 'WHILE', 'FOR', 'TEST', 'WHEN', 'FN', 'START'
            has_block = true if kdepth.zero?
            kdepth += 1
          when 'END'
            kdepth -= 1 if kdepth.positive?
          end
        end
      end
    end
    multi = semi_count > 1 || has_block || has_comment
    { start: s, end: e, body_end: body_end, arrow: arrow, sep: sep, multi: multi }
  end

  # Emit one arm: pattern, `->`, body, separator. Wraps DEFAULT in
  # INDENT_OPEN/CLOSE phantoms to neutralize its OUTDENT_LEADING render
  # rule. Multi-line arms emit body on its own lines at +1 indent and
  # close the indent before the separator.
  sig { params(out: Array, toks: Array, arm: Hash).returns(Array) }
  def emit_match_arm(out, toks, arm)
    s, e, body_end, arrow, sep, multi =
      arm[:start], arm[:end], arm[:body_end], arm[:arrow], arm[:sep], arm[:multi]

    leader = first_code_at(toks, s, body_end)
    cancel_outdent = leader && leader.type == :KEYWORD &&
                     OUTDENT_LEADING.include?(leader.raw)

    # KEEP_INDENT on the leader line tells render to skip its
    # OUTDENT_LEADING outdent — DEFAULT in MATCH is an arm pattern, not
    # a CATCH/TRY-style outdent.
    out << phantom(:KEEP_INDENT) if cancel_outdent

    if arrow && multi
      copy_arm_tokens(out, toks, s, arrow + 1)
      insert_nl(out)
      emit_match_body(out, toks, arrow + 1, body_end)
      # Drop trailing NL so the `,` (or INDENT_CLOSE) sits on the same
      # line as the body's last `;`. Without this, the comma orphan-
      # lands on its own line.
      out.pop while out.last && out.last.type == :NL
      out << phantom(:INDENT_CLOSE)
      out << toks[sep] if sep
    else
      copy_arm_tokens(out, toks, s, body_end)
      out << toks[sep] if sep
    end

    insert_nl(out)
  end

  sig { params(toks: Array, s: Integer, e: Integer).returns(Formatter::FormatLexer::Token) }
  def first_code_at(toks, s, e)
    j = s
    while j < e
      t = toks[j]
      return t unless [:NL, :COMMENT, :WS, :INDENT_OPEN, :INDENT_CLOSE].include?(t.type)
      j += 1
    end
    nil
  end

  sig { params(out: Array, toks: Array, s: Integer, e: Integer).returns(Range) }
  def copy_arm_tokens(out, toks, s, e)
    (s...e).each do |k|
      t = toks[k]
      next if t.type == :NL
      out << t
    end
  end

  # Emit a multi-statement arm body at +1 indent, splitting at `;` at
  # depth 0. The arm-separator `,` (or the closing END for the last
  # arm) is emitted by the caller, so we never look past `e` here.
  # Preserves source NLs inside nested blocks so expand_then_do_blocks
  # still sees the user's multi-line shape; collapses redundant NLs at
  # arm-body top-level since `;` already inserts one.
  sig { params(out: Array, toks: Array, s: Integer, e: Integer).returns(T.untyped) }
  def emit_match_body(out, toks, s, e)
    bdepth = 0
    kdepth = 0
    j = skip_nls(toks, s)
    while j < e
      t = toks[j]
      if t.type == :NL
        # Collapse adjacent NLs but keep one. This preserves user line
        # breaks (between END of a nested block and the next statement)
        # without producing the orphan blank lines that arise from the
        # source-NL after a `;` we just NL-terminated ourselves.
        out << t unless out.last && out.last.type == :NL
        j += 1
        next
      end
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then bdepth += 1; out << t; j += 1; next
        when ')', ']', '}' then bdepth -= 1; out << t; j += 1; next
        when ';'
          if bdepth.zero? && kdepth.zero?
            out << t
            j += 1
            insert_nl(out)
            next
          end
        end
      elsif t.type == :KEYWORD && bdepth.zero?
        case t.raw
        when 'IF', 'WHILE', 'FOR', 'TEST', 'WHEN', 'FN', 'START'
          kdepth += 1
        when 'END'
          kdepth -= 1 if kdepth.positive?
        end
      end
      out << t
      j += 1
    end
  end

  # For each top-level `FN ... -> ... END` (or any nested FN), ensure that
  # the body is multi-line: a newline follows `->` and precedes `END`, and
  # statements in between are split on `;` boundaries.
  sig { params(toks: Array).returns(Array) }
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
  sig { params(out: Array, toks: Array, start: Integer).returns(Integer) }
  def emit_fn_block(out, toks, start)
    # Copy up to and including the `->` that ends the signature.
    arrow_idx = find_fn_arrow(toks, start)
    unless arrow_idx
      out << toks[start]
      return start + 1
    end

    po, pc = find_fn_parens(toks, start, arrow_idx)
    sig = FnSig.new(toks: toks, start: start, arrow_idx: arrow_idx, po: po, pc: pc)
    # A function signature with REQUIRES or EFFECTS uses the metadata-wrap
    # layout: each clause keyword (RETURNS, REQUIRES, EFFECTS) on its own
    # line at 1-space indent (HALF_INDENT), then `->` at FN level. Mirrors
    # the visual scope of Ruby's public/private outdent.
    if has_fn_signature_metadata?(sig)
      emit_fn_signature_metadata_wrapped(out, sig)
    elsif should_wrap_fn_sig?(sig)
      emit_fn_signature_wrapped(out, sig)
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
      if tj.type == :KEYWORD && %w[FN IF WHILE FOR TEST WHEN START].include?(tj.raw)
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
        j = emit_stmt_terminator(out, toks, j)
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

  sig { params(toks: Array, j: Integer).returns(Integer) }
  def skip_nls(toks, j)
    j += 1 while j < toks.length && toks[j].type == :NL
    j
  end

  # Locate the opening/closing parens of the FN param list. Returns
  # [po, pc] (both may be nil for FNs with no parens, though in CLEAR
  # they are mandatory).
  sig { params(toks: Array, fn_idx: Integer, arrow_idx: Integer).returns(Array) }
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
  sig { params(sig: Formatter::Emitter::FnSig).returns(T::Boolean) }
  def should_wrap_fn_sig?(sig)
    return false unless sig.po && sig.pc
    return true if (sig.po + 1 ... sig.pc).any? { |j| sig.toks[j].type == :NL }
    inline = sig.toks[sig.start..sig.arrow_idx].reject { |t| t.type == :NL }
    format_line_body(inline).length > 120
  end

  # Emit a wrapped FN signature:
  #   FN name(
  #     p1: T,
  #     p2: T
  #   )
  #   RETURNS T ->
  sig { params(out: Array, sig: Formatter::Emitter::FnSig).returns(T.untyped) }
  def emit_fn_signature_wrapped(out, sig)
    toks = sig.toks
    # Tokens from FN through and including `(`.
    (sig.start..sig.po).each { |j| out << toks[j] }

    insert_nl(out)
    out << phantom(:INDENT_OPEN)

    depth = 0
    j = sig.po + 1
    j = skip_nls(toks, j)
    while j < sig.pc
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
    out << toks[sig.pc]  # `)`
    insert_nl(out)

    # Emit RETURNS ... -> on its own line.
    j = sig.pc + 1
    j = skip_nls(toks, j)
    while j <= sig.arrow_idx
      t = toks[j]
      if t.type == :NL
        j += 1
        next
      end
      out << t
      j += 1
    end
  end

  # Function-level metadata clauses that trigger the multi-line wrap.
  # RETURNS is included so RETURNS comes along when REQUIRES is present;
  # by itself, RETURNS uses the legacy inline form.
  FN_METADATA_KEYWORDS = %w[RETURNS REQUIRES EFFECTS].freeze
  FN_METADATA_TRIGGERS = %w[REQUIRES EFFECTS].freeze

  # True when the signature between `)` (pc) and `->` (arrow_idx) contains
  # at least one trigger keyword (REQUIRES or EFFECTS today).
  sig { params(sig: Formatter::Emitter::FnSig).returns(T::Boolean) }
  def has_fn_signature_metadata?(sig)
    return false unless sig.pc && sig.arrow_idx
    (sig.pc + 1...sig.arrow_idx).any? do |j|
      sig.toks[j].type == :KEYWORD && FN_METADATA_TRIGGERS.include?(sig.toks[j].raw)
    end
  end

  # Emit a FN signature with metadata clauses on their own lines:
  #
  #     FN name(p1: T, p2: T)
  #      RETURNS R
  #      REQUIRES x: LOCKED
  #     ->
  #
  # The `->` lands at FN-level (column 0) on its own line. Body indent
  # then opens at +1 from FN-level via OPEN_TERMINAL on `->`.
  sig { params(out: Array, sig: Formatter::Emitter::FnSig).returns(Array) }
  def emit_fn_signature_metadata_wrapped(out, sig)
    toks = sig.toks
    # 1. Emit `FN name(...)`. Reuse existing param-wrapping rules so a
    # long param list still expands correctly.
    if sig.po && sig.pc && should_wrap_fn_sig?(sig)
      emit_fn_params_only_wrapped(out, sig)
    elsif sig.pc
      (sig.start..sig.pc).each { |j| out << toks[j] }
    else
      (sig.start..sig.arrow_idx - 1).each { |j| out << toks[j] }
    end
    insert_nl(out)

    # 2. One line per metadata clause. Each clause runs from its keyword
    # to (but not including) the next clause keyword or `->`.
    if sig.pc
      collect_fn_metadata_clauses(toks, sig.pc + 1, sig.arrow_idx).each do |clause_toks|
        out << phantom(:HALF_INDENT)
        clause_toks.each { |t| out << t unless t.type == :NL }
        insert_nl(out)
      end
    end

    # 3. `->` on its own line at FN level.
    out << toks[sig.arrow_idx]
  end

  # Emit the FN keyword through to `)` only, wrapping params if the
  # existing rules say to. Mirrors emit_fn_signature_wrapped but stops at
  # `)` instead of running through `->`.
  sig { params(out: Array, sig: Formatter::Emitter::FnSig).returns(Array) }
  def emit_fn_params_only_wrapped(out, sig)
    toks = sig.toks
    (sig.start..sig.po).each { |j| out << toks[j] }
    insert_nl(out)
    out << phantom(:INDENT_OPEN)

    depth = 0
    j = sig.po + 1
    j = skip_nls(toks, j)
    while j < sig.pc
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
    out << toks[sig.pc]
  end

  # Split tokens between `)` and `->` into per-clause groups. Each clause
  # starts at one of FN_METADATA_KEYWORDS and runs until the next.
  sig { params(toks: Array, start: Integer, stop: Integer).returns(Array) }
  def collect_fn_metadata_clauses(toks, start, stop)
    clauses = []
    current = nil
    (start...stop).each do |j|
      t = toks[j]
      if t.type == :KEYWORD && FN_METADATA_KEYWORDS.include?(t.raw)
        clauses << current if current && !current.empty?
        current = [t]
      elsif current
        current << t
      end
    end
    clauses << current if current && !current.empty?
    clauses
  end

  sig { params(toks: Array, fn_idx: Integer).returns(T.nilable(Integer)) }
  def find_fn_arrow(toks, fn_idx)
    depth = 0
    j = fn_idx + 1
    while j < toks.length
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[' then depth += 1
        when ')', ']' then depth -= 1
        when '{', '}', ';'
          return nil if depth == 0
        end
        # `,` is permitted at depth 0 — REQUIRES clauses use it
        # (`REQUIRES x, y: LOCKED`). The arrow only ever appears as
        # the FN-body opener at top level, so a comma can't be confused
        # for it.
      elsif t.type == :OP && t.raw == '->' && depth == 0
        return j
      elsif t.type == :KEYWORD && t.raw == 'END' && depth == 0
        return nil
      end
      j += 1
    end
    nil
  end

  # Expand IF / WHILE / FOR blocks where any branch has its body inline
  # with the THEN/DO/ELSE keyword. Two triggers:
  #   1. The whole construct fits on a single source line (`one_liner_end`
  #      returns non-nil).
  #   2. At least one branch's THEN/DO/ELSE is followed by inline body
  #      tokens (multi-line IF/ELSE_IF chain where each branch is a
  #      one-liner — repro from examples/json_parser/parseString).
  # Already-multi-line forms (every branch already has its body on its
  # own line) are left untouched.
  sig { params(toks: Array).returns(Array) }
  def expand_then_do_blocks(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      if t.type == :KEYWORD && %w[IF WHILE FOR].include?(t.raw)
        end_idx = one_liner_end(toks, i) || branch_end_for_inline_expansion(toks, i)
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

  # Returns the index of the matching END for the IF/WHILE/FOR at `start`
  # iff at least one of its branches (THEN / ELSE / ELSE_IF / DO) is
  # followed inline (no NL) by body code rather than NL, END, ELSE,
  # or ELSE_IF. Otherwise nil.
  sig { params(toks: Array, start: Integer).returns(T.nilable(Integer)) }
  def branch_end_for_inline_expansion(toks, start)
    end_idx = matching_end(toks, start)
    return nil unless end_idx
    bdepth = 0
    kdepth = 0
    j = start + 1
    while j < end_idx
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then bdepth += 1
        when ')', ']', '}' then bdepth -= 1
        end
      elsif t.type == :KEYWORD && bdepth.zero?
        case t.raw
        when 'IF', 'WHILE', 'FOR', 'TEST', 'WHEN', 'FN'
          kdepth += 1
        when 'END'
          kdepth -= 1 if kdepth.positive?
        when 'THEN', 'DO', 'ELSE'
          if kdepth.zero?
            k = j + 1
            k += 1 while k < end_idx && toks[k].type == :COMMENT
            return end_idx if k < end_idx && toks[k].type != :NL &&
                              !(toks[k].type == :KEYWORD &&
                                %w[END ELSE ELSE_IF].include?(toks[k].raw))
          end
        end
      end
      j += 1
    end
    nil
  end

  # Find matching END for the IF/WHILE/FOR at `start` (no NL constraint).
  # Returns nil if unmatched.
  #
  # `START` opens a `MATCH ... START ... END` block (also `SYNC POLICY
  # START ... END`). Without counting it as a kdepth-bumper, a nested
  # MATCH inside an IF body has its own `END` mistaken for the outer
  # IF's `END`, truncating expand_if_while_for's scope so any ELSE_IF
  # branches end up outside the body walk -- and thus formatted
  # asymmetrically with the leading IF arm. Treating every `START`
  # uniformly here makes IF / ELSE_IF / ELSE bodies all flow through
  # the same THEN/DO inline-body expansion in the body walk.
  sig { params(toks: Array, start: Integer).returns(T.nilable(Integer)) }
  def matching_end(toks, start)
    bdepth = 0
    kdepth = 0
    j = start + 1
    while j < toks.length
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then bdepth += 1
        when ')', ']', '}' then bdepth -= 1
        end
      elsif bdepth.zero? && t.type == :KEYWORD
        case t.raw
        when 'IF', 'WHILE', 'FOR', 'TEST', 'WHEN', 'FN', 'START'
          kdepth += 1
        when 'END'
          return j if kdepth.zero?
          kdepth -= 1
        end
      end
      j += 1
    end
    nil
  end

  # Returns the index of the matching END if and only if no :NL appears
  # anywhere between `start` and that END (i.e., the whole construct is
  # a single source line). Otherwise nil.
  sig { params(toks: Array, start: Integer).returns(T.nilable(Integer)) }
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
  sig { params(out: Array, toks: Array, start: Integer, end_idx: Integer).returns(Integer) }
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
    # Track BOTH bracket depth (`(`, `[`, `{`) AND keyword-block depth
    # so that a `;` belonging to an inner one-liner block
    # (`IF cond THEN a; b; END`) doesn't get torn into separate lines.
    # block_depth tracks IF/WHILE/FOR/TEST/WHEN — the constructs that
    # OPEN a new keyword block. THEN/DO/ELSE_IF do NOT bump it: they're
    # mid-block markers in the SAME enclosing IF, and treating them as
    # block-openers breaks multi-branch IF chains where each ELSE_IF's
    # own THEN would falsely nest. (Repro: examples/json_parser
    # parseString, where the IF/ELSE_IF chain staggered.)
    depth = 0
    block_depth = 0
    j = term_idx + 1
    j += 1 while j < end_idx && toks[j].type == :NL
    body_start = out.length
    while j < end_idx
      tj = toks[j]
      if tj.type == :SYM && tj.raw == '('      then depth += 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == ')'      then depth -= 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == '['      then depth += 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == ']'      then depth -= 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == '{'      then depth += 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == '}'      then depth -= 1; out << tj; j += 1; next end

      if tj.type == :KEYWORD
        case tj.raw
        when 'IF', 'WHILE', 'FOR', 'TEST', 'WHEN', 'FN' then block_depth += 1
        when 'END' then block_depth -= 1 if block_depth > 0
        end
      end

      if tj.type == :NL
        # Collapse adjacent NLs but preserve user-written line breaks
        # inside nested blocks so further passes still see structure.
        out << tj unless out.last && out.last.type == :NL
        j += 1
        next
      end

      if tj.type == :SYM && tj.raw == ';' && depth.zero? && block_depth.zero?
        j = emit_stmt_terminator(out, toks, j)
        next
      end
      if tj.type == :KEYWORD && %w[ELSE ELSE_IF].include?(tj.raw) && depth.zero? && block_depth.zero?
        insert_nl(out)
        out << tj
        j += 1
        # `ELSE` with an inline body (`ELSE x = 0;`) — push body to its
        # own line. ELSE_IF's body comes after THEN, handled below.
        if tj.raw == 'ELSE'
          k = j
          k += 1 while k < end_idx && toks[k].type == :COMMENT
          if k < end_idx && toks[k].type != :NL &&
             !(toks[k].type == :KEYWORD && %w[END ELSE ELSE_IF].include?(toks[k].raw))
            insert_nl(out)
          end
        end
        next
      end
      # THEN/DO with an inline body (`IF c THEN s;` continuation in a
      # multi-line chain) — push body onto its own line so the indent
      # ladder doesn't stagger. (Repro: examples/json_parser
      # parseString, where each `ELSE_IF cond THEN stmt;` was a one-
      # liner in a multi-line chain, and the missing NL collapsed the
      # whole ladder against the IF column.)
      if tj.type == :KEYWORD && %w[THEN DO].include?(tj.raw) &&
         depth.zero? && block_depth.zero?
        out << tj
        j += 1
        k = j
        k += 1 while k < end_idx && toks[k].type == :COMMENT
        if k < end_idx && toks[k].type != :NL &&
           !(toks[k].type == :KEYWORD && %w[END ELSE ELSE_IF].include?(toks[k].raw))
          insert_nl(out)
        end
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
  sig { params(toks: Array).returns(Array) }
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

  sig { params(toks: Array, idx: Integer).returns(T::Boolean) }
  def with_is_block?(toks, idx)
    j = idx + 1
    while j < toks.length && [:NL, :COMMENT].include?(toks[j].type)
      j += 1
    end
    return true if j >= toks.length
    !(toks[j].type == :SYM && toks[j].raw == '(')
  end

  sig { params(out: Array, toks: Array, start: Integer).returns(Integer) }
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

  sig { params(toks: Array, start: Integer).returns(T.nilable(Integer)) }
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

  sig { params(toks: Array, open_idx: Integer).returns(T.nilable(Integer)) }
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
  sig { params(toks: Array, start: Integer).returns(Integer) }
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

  sig { params(raw: String).returns(T::Boolean) }
  def on_keyword?(raw)
    %w[ON RETRY POSSIBLE_DEADLOCK POSSIBLE_LOCK_CYCLE].include?(raw)
  end

  sig { params(toks: Array, start: Integer).returns(Integer) }
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

  sig { params(type: Symbol).returns(Formatter::FormatLexer::Token) }
  def phantom(type)
    Formatter::FormatLexer::Token.new(type, '', 0, 0)
  end

  # ---- CONCURRENT multi-arg chain drop (§3.11) ---------------------------
  #
  # `CONCURRENT(p1, p2) EACH { body }` with 2+ params drops the trailing
  # pipeline keyword (EACH / WHERE / SELECT / etc.) to its own line at +1
  # from the `CONCURRENT` line. Exact column alignment with CONCURRENT is
  # not reachable in a depth-based renderer, so +1 depth is the canonical
  # approximation.
  sig { params(toks: Array).returns(Array) }
  def expand_concurrent_drops(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      if t.type == :KEYWORD && t.raw == 'CONCURRENT'
        paren_open = skip_ws_nl(toks, i + 1)
        if paren_open && toks[paren_open].type == :SYM && toks[paren_open].raw == '('
          paren_close = find_matching_paren_or_brace(toks, paren_open, '(', ')')
          if paren_close && count_depth0_commas(toks, paren_open, paren_close) >= 1
            next_kw = skip_ws_nl(toks, paren_close + 1)
            if next_kw && toks[next_kw].type == :KEYWORD && pipeline_op_keyword?(toks[next_kw].raw)
              # Emit `CONCURRENT(...)` as-is (stripping NLs inside args;
              # args are already wrapped by expand_call_args if long).
              (i..paren_close).each { |j| out << toks[j] }
              insert_nl(out)
              out << phantom(:INDENT_OPEN)
              stage_end = find_concurrent_stage_end(toks, next_kw)
              (next_kw...stage_end).each do |j|
                next if toks[j].type == :NL
                out << toks[j]
              end
              out << phantom(:INDENT_CLOSE)
              i = stage_end
              next
            end
          end
        end
      end
      out << t
      i += 1
    end
    out
  end

  sig { params(toks: Array, start: Integer).returns(Integer) }
  def skip_ws_nl(toks, start)
    j = start
    while j < toks.length && [:NL].include?(toks[j].type)
      j += 1
    end
    j < toks.length ? j : nil
  end

  sig { params(toks: Array, open_idx: Integer, close_idx: Integer).returns(Integer) }
  def count_depth0_commas(toks, open_idx, close_idx)
    depth = 0
    n = 0
    ((open_idx + 1)...close_idx).each do |j|
      t = toks[j]
      next unless t.type == :SYM
      case t.raw
      when '(', '[', '{' then depth += 1
      when ')', ']', '}' then depth -= 1
      when ','           then (n += 1 if depth == 0)
      end
    end
    n
  end

  sig { params(raw: String).returns(T::Boolean) }
  def pipeline_op_keyword?(raw)
    %w[EACH WHERE SELECT FIND ANY ALL COUNT SUM AVERAGE MIN MAX REDUCE
       ORDER_BY LIMIT SKIP UNNEST DISTINCT TAP TAKE_WHILE WINDOW JOIN SHARD].include?(raw)
  end

  # Stage ends at the next `|>` at the SAME depth, a `;`, or an unmatched
  # closing bracket. Inside nested `{}` / `()` the content is opaque.
  sig { params(toks: Array, start: Integer).returns(Integer) }
  def find_concurrent_stage_end(toks, start)
    depth = 0
    j = start
    while j < toks.length
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then depth += 1
        when ')', ']', '}'
          return j if depth == 0
          depth -= 1
        when ';'
          return j if depth == 0
        end
      elsif t.type == :OP && t.raw == '|>' && depth == 0
        return j
      end
      j += 1
    end
    j
  end

  # ---- Method chain wrap (§3.5) ------------------------------------------
  #
  # `.a().b().c()...` chains with 4+ segments OR total chain length > 80
  # chars wrap, one `.seg` per line at +1 from the receiver. A segment is
  # `.name` optionally followed by `(args)` or `[index]`.
  sig { params(toks: Array).returns(Array) }
  def expand_method_chains(toks)
    out = []
    i = 0
    while i < toks.length
      if method_chain_start?(toks, i, out)
        segments, chain_end = scan_chain_segments(toks, i)
        if segments.length >= 4 || chain_length_estimate(toks, segments) > 80
          dropped = maybe_drop_assignment_rhs(out)
          insert_nl(out)
          out << phantom(:INDENT_OPEN)
          segments.each_with_index do |seg, k|
            insert_nl(out) if k > 0
            # Strip NLs that are between segment tokens at the chain's
            # top level — those are line breaks the user put between
            # `.foo()` and `.bar()` that the renderer is about to
            # supply itself. NLs nested inside the segment's argument
            # list (`.foo(BG { @parallel -> ...\n... })`) must be
            # preserved: they belong to the argument's own multi-line
            # layout, not to the chain. Without this depth guard, the
            # whole BG body collapsed onto one line.
            # (Repro: benchmarks/concurrent/14_nested_lock pre-fix.)
            seg_depth = 0
            (seg[:start]...seg[:end]).each do |j|
              t = toks[j]
              if t.type == :SYM
                case t.raw
                when '(', '[', '{' then seg_depth += 1
                when ')', ']', '}' then seg_depth -= 1
                end
              end
              next if t.type == :NL && seg_depth.zero?
              out << t
            end
          end
          out << phantom(:INDENT_CLOSE)
          out << phantom(:INDENT_CLOSE) if dropped
          i = chain_end
          next
        end
      end
      out << toks[i]
      i += 1
    end
    out
  end

  sig { params(toks: Array, i: Integer, out: Array).returns(T::Boolean) }
  def method_chain_start?(toks, i, out)
    return false unless toks[i].type == :SYM && toks[i].raw == '.'
    prev = last_nontrivial_in_out(out)
    return false unless prev
    [:VAR_ID, :TYPE_ID].include?(prev.type) ||
      (prev.type == :SYM && [')', ']'].include?(prev.raw))
  end

  sig { params(out: Array).returns(Formatter::FormatLexer::Token) }
  def last_nontrivial_in_out(out)
    j = out.length - 1
    while j >= 0
      t = out[j]
      break unless [:NL, :COMMENT, :INDENT_OPEN, :INDENT_CLOSE].include?(t.type)
      j -= 1
    end
    j >= 0 ? out[j] : nil
  end

  sig { params(toks: Array, start_idx: Integer).returns(Array) }
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

  sig { params(toks: Array, open_idx: Integer).returns(Integer) }
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

  sig { params(toks: Array, segments: Array).returns(Integer) }
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
  sig { params(toks: Array).returns(Array) }
  def expand_call_args(toks)
    process_call_arg_range(toks, 0, toks.length)
  end

  sig { params(toks: Array, start: Integer, stop: Integer).returns(Array) }
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
  sig { params(toks: Array, idx: Integer, prev_emitted: T.nilable(Formatter::FormatLexer::Token)).returns(T.nilable(Symbol)) }
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

  sig { params(toks: Array, open_idx: Integer, opener: String, closer: String).returns(Integer) }
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

  sig { params(opener: String, inner: Array, closer: String, out: Array).returns(T::Boolean) }
  def call_args_need_wrap?(opener, inner, closer, out)
    return true if inner.any? { |t| t.type == :NL }
    prefix_len = current_line_length_in_out(out)
    call_len   = opener.length + format_line_body(inner).length + closer.length
    (prefix_len + call_len) > 120
  end

  # Approximate the projected length of the current output line (tokens
  # since the last NL). Ignores indent markers and NLs.
  sig { params(out: Array).returns(Integer) }
  def current_line_length_in_out(out)
    start = out.length - 1
    while start >= 0 && out[start].type != :NL
      start -= 1
    end
    segment = out[(start + 1)..] || []
    segment = segment.reject { |t| [:INDENT_OPEN, :INDENT_CLOSE, :NL].include?(t.type) }
    format_line_body(segment).length
  end

  sig { params(out: Array, open_tok: Formatter::FormatLexer::Token, inner: Array, close_tok: Formatter::FormatLexer::Token).returns(Array) }
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
  sig { params(toks: Array).returns(Array) }
  def expand_bg_do_blocks(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      if t.type == :KEYWORD && %w[BG DO].include?(t.raw)
        brace_idx = find_bg_brace(toks, i)
        if brace_idx
          close_idx = find_matching_close_brace(toks, brace_idx)
          if close_idx && bg_body_needs_wrap?(toks, brace_idx, close_idx)
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

  # A BG/DO body needs the multi-line wrap when it has 2+ statements
  # at the top level OR when its single statement opens a nested block
  # (`FOR ... DO ... END`, `IF ... THEN ... END`, etc). Without the
  # second condition, a body like `BG { @parallel -> FOR ... DO ... END }`
  # was being skipped by the wrap pass and ended up collapsed onto a
  # single 600-char line by `collapse_newlines`. The DO/THEN check
  # specifically targets that case while leaving short trivial bodies
  # like `BG { @micro -> doWork(); }` inline.
  sig { params(toks: Array, brace_idx: Integer, close_idx: Integer).returns(T::Boolean) }
  def bg_body_needs_wrap?(toks, brace_idx, close_idx)
    return true if count_statements_in_block(toks, brace_idx, close_idx) >= 2
    body_has_top_level_block?(toks, brace_idx, close_idx)
  end

  sig { params(toks: Array, brace_idx: Integer, close_idx: Integer).returns(T::Boolean) }
  def body_has_top_level_block?(toks, brace_idx, close_idx)
    depth = 0
    (brace_idx + 1 ... close_idx).each do |j|
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then depth += 1
        when ')', ']', '}' then depth -= 1
        end
      elsif t.type == :KEYWORD && depth.zero? && %w[DO THEN].include?(t.raw)
        return true
      end
    end
    false
  end

  sig { params(toks: Array, start: Integer).returns(T.nilable(Integer)) }
  def find_bg_brace(toks, start)
    j = start + 1
    while j < toks.length && [:NL, :COMMENT].include?(toks[j].type)
      j += 1
    end
    return j if j < toks.length && toks[j].type == :SYM && toks[j].raw == '{'
    nil
  end

  sig { params(toks: Array, open_brace: Integer, close_brace: Integer).returns(Integer) }
  def count_statements_in_block(toks, open_brace, close_brace)
    # Counts top-level `;` inside the BG/DO `{ ... }` body to decide
    # whether it's a one-liner or needs the multi-line wrap.
    #
    # Treats `DO`/`THEN ... END` as nested (anything inside them is a
    # single sub-statement at the BG level). Also treats a single
    # top-level statement that opens a DO/THEN block — e.g.
    # `FOR i IN ... DO ... END` or `IF cond THEN ... END` — as one
    # statement: count it once even though it has no terminating `;`.
    # Without this, BGs like
    # `BG { @parallel -> FOR i IN ... DO a; b; END }` (single FOR at
    # the BG level, multiple `;` inside its DO body) used to mis-count
    # as multi-statement and trigger the wrap, which then collapsed
    # the FOR's DO body into a 300-char mess.
    # (Repro: benchmarks/concurrent/14_nested_lock pre-fix.)
    depth = 0
    block_depth = 0
    count = 0
    has_tokens = false
    saw_block_at_top = false
    (open_brace + 1 ... close_brace).each do |j|
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then depth += 1
        when ')', ']', '}' then depth -= 1
        when ';'
          if depth.zero? && block_depth.zero?
            count += 1 if has_tokens
            has_tokens = false
            saw_block_at_top = false
            next
          end
        end
      elsif t.type == :KEYWORD
        case t.raw
        when 'DO', 'THEN'
          saw_block_at_top = true if depth.zero? && block_depth.zero?
          block_depth += 1
        when 'END'
          block_depth -= 1 if block_depth > 0
        end
      end
      next if [:NL, :COMMENT].include?(t.type)
      has_tokens = true
    end
    count += 1 if has_tokens
    count
  end

  sig { params(out: Array, toks: Array, kw_idx: Integer, brace_idx: Integer, close_idx: Integer).returns(Integer) }
  def emit_bg_do_wrapped(out, toks, kw_idx, brace_idx, close_idx)
    # Emit BG/DO keyword through and including `{`, stripping any NLs.
    (kw_idx..brace_idx).each do |j|
      next if toks[j].type == :NL
      out << toks[j]
    end
    insert_nl(out)

    # `BG { @parallel -> body }` — the leading `@xxx ->` is a strategy
    # tag whose `->` opens body indent (OPEN_TERMINAL on `->`) but has
    # no matching END inside the BG body; the `}` only closes the `{`.
    # Without compensation the body's depth never unwinds and every
    # statement after the BG ends up one column too deep. Detect that
    # shape and emit a balancing INDENT_CLOSE before `}`.
    needs_arrow_balance = bg_body_has_strategy_arrow?(toks, brace_idx, close_idx)

    depth = 0
    block_depth = 0
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
          # Insert NL on `;` only at the BG-level top — inside a
          # `DO ... END` or `THEN ... END` block, leave the `;` to be
          # handled by the inner block's own expansion (expand_then_do_blocks
          # runs earlier in the pipeline). Without this guard, the FOR
          # body in `BG { @parallel -> FOR i IN ... DO a; b; END }`
          # would be torn apart.
          if depth.zero? && block_depth.zero?
            j = emit_stmt_terminator(out, toks, j)
            next
          end
        end
      elsif t.type == :KEYWORD
        case t.raw
        when 'DO', 'THEN' then block_depth += 1
        when 'END' then block_depth -= 1 if block_depth > 0
        end
      end
      out << t
      j += 1
    end

    if body_start < out.length
      out.pop while out.last && out.last.type == :NL && out.length > body_start
      out << phantom(:INDENT_CLOSE) if needs_arrow_balance
      insert_nl(out)
    end
    out << toks[close_idx]
    close_idx + 1
  end

  # True if the BG/DO body opens with a strategy-tag arrow at top
  # level (`@parallel ->`, `@micro ->`, ...). The `->` raises render
  # depth via OPEN_TERMINAL but the body has no END to lower it back,
  # so we need an explicit INDENT_CLOSE before `}`.
  sig { params(toks: Array, brace_idx: Integer, close_idx: Integer).returns(T::Boolean) }
  def bg_body_has_strategy_arrow?(toks, brace_idx, close_idx)
    bdepth = 0
    j = brace_idx + 1
    j += 1 while j < close_idx && [:NL, :COMMENT].include?(toks[j].type)
    while j < close_idx
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then bdepth += 1
        when ')', ']', '}' then bdepth -= 1
        end
      elsif t.type == :OP && t.raw == '->' && bdepth.zero?
        return true
      elsif t.type == :KEYWORD && bdepth.zero? &&
            %w[FN IF WHILE FOR TEST WHEN START].include?(t.raw)
        return false
      end
      return false if t.type == :SYM && t.raw == ';' && bdepth.zero?
      j += 1
    end
    false
  end

  # ---- Pipeline forced wraps (§3.4, §3.7) --------------------------------
  #
  # When a pipeline chain has 2+ `|>` stages (at the same expression depth,
  # before any `;` / `,` / closing bracket), each stage renders on its own
  # line at +1 from the receiver.
  #
  # `|> RECOVER(...)` gets one extra indent level relative to its sibling
  # stages:  users |> a |> RECOVER(default) |> b  ->
  #   users
  #     |> a
  #     |> RECOVER(default)    <-- +1 more
  #     |> b
  sig { params(toks: Array).returns(Array) }
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

  sig { params(toks: Array).returns(Array) }
  def find_s_chains(toks)
    chains = []
    i = 0
    while i < toks.length
      if toks[i].type == :OP && toks[i].raw == '|>'
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
          elsif t.type == :OP && t.raw == '|>' && depth == 0
            s_idxs << j
          end
          j += 1
        end
        starts_on_continuation = i > 0 && toks[i - 1].type == :NL
        chains << { s_idxs: s_idxs, end_idx: j } if s_idxs.length >= 2 || starts_on_continuation
        i = j
      else
        i += 1
      end
    end
    chains
  end

  sig { params(toks: Array, chains: Array).returns(Hash) }
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
  # (relative to receiver). Stages that are `|> RECOVER(...)` get an
  # additional +1. Strips source NLs inside stages so the canonical
  # layout wins regardless of the input layout.
  #
  # §3.6 assignment drop: if the receiver line (`x = receiver` or
  # `x: T = receiver`) exceeds 80 chars, drop the RHS to its own line
  # at +1, chain at +2.
  sig { params(out: Array, toks: Array, chain: Hash, recover_s: Hash).returns(Integer) }
  def emit_chain(out, toks, chain, recover_s)
    s_idxs  = chain[:s_idxs]
    end_idx = chain[:end_idx]

    dropped = maybe_drop_assignment_rhs(out)

    insert_nl(out)
    out << phantom(:INDENT_OPEN)

    s_idxs.each_with_index do |s_idx, k|
      next_bound = s_idxs[k + 1] || end_idx
      recover    = recover_s[s_idx]

      insert_nl(out) if k > 0
      out << phantom(:INDENT_OPEN) if recover

      out << toks[s_idx]  # |>

      (s_idx + 1 ... next_bound).each do |j|
        next if toks[j].type == :NL  # discard source NLs inside a stage
        out << toks[j]
      end

      out << phantom(:INDENT_CLOSE) if recover
    end

    out << phantom(:INDENT_CLOSE)
    out << phantom(:INDENT_CLOSE) if dropped
    end_idx
  end

  # §3.6: when `x = receiver ...` or `x: T = receiver ...` overflows 80
  # chars, insert a NL + INDENT_OPEN right after the `=` so the receiver
  # drops onto its own line at +1. Returns true when applied (caller must
  # emit a matching INDENT_CLOSE after the chain).
  sig { params(out: Array).returns(T::Boolean) }
  def maybe_drop_assignment_rhs(out)
    return false if current_line_length_in_out(out) <= 80
    eq_idx = find_assignment_eq_on_current_line(out)
    return false unless eq_idx

    nl_tok   = Formatter::FormatLexer::Token.new(:NL, "\n", 0, 0)
    open_tok = phantom(:INDENT_OPEN)
    out.insert(eq_idx + 1, nl_tok, open_tok)
    true
  end

  sig { params(out: Array).returns(Integer) }
  def find_assignment_eq_on_current_line(out)
    start = out.length - 1
    while start >= 0 && out[start].type != :NL
      start -= 1
    end
    depth = 0
    eq_idx = nil
    ((start + 1)...out.length).each do |i|
      t = out[i]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then depth += 1
        when ')', ']', '}' then depth -= 1
        when '='           then (eq_idx = i if depth == 0)
        end
      end
    end
    eq_idx
  end

  # Split STRUCT / UNION / ENUM blocks so each field/variant is its own line.
  sig { params(toks: Array).returns(Array) }
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

  sig { params(out: Array, toks: Array, start: Integer).returns(Integer) }
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
  sig { params(out: Array).returns(T.nilable(Array)) }
  def insert_nl(out)
    return if out.last && out.last.type == :NL
    out << Formatter::FormatLexer::Token.new(:NL, "\n", 0, 0)
  end

  # Emit `;` at index `j` as a statement terminator, then a newline.
  # MATCH arms have the shape `Pat -> stmt;,` where the `,` is the
  # arm separator — keep it on the same line as `;`. Without this,
  # `;` forced a NL and the orphan `,` landed on its own line.
  # Also handles the idempotent case where prior formatting already
  # left a NL between `;` and `,`.
  sig { params(out: Array, toks: Array, j: Integer).returns(Integer) }
  def emit_stmt_terminator(out, toks, j)
    out << toks[j]  # `;`
    j += 1
    k = j
    k += 1 while k < toks.length && toks[k].type == :NL
    if k < toks.length && toks[k].type == :SYM && toks[k].raw == ','
      out << toks[k]
      j = k + 1
    end
    insert_nl(out)
    j += 1 if j < toks.length && toks[j].type == :NL
    j
  end

  # ---- rendering ------------------------------------------------------

  # Walks the transformed token stream and produces the final string.
  # Maintains: indent depth, per-line buffers, last non-comment code token
  # (for spacing decisions). `:INDENT_OPEN` / `:INDENT_CLOSE` phantom tokens
  # adjust depth for forced wraps where no `{` / `END` drives the change.
  sig { params(toks: Array).returns(String) }
  def render(toks)
    lines = tokens_to_lines(toks)
    lines = ensure_blank_before_catch(lines)
    lines = drop_trailing_blanks(lines)

    depth = 0
    out = +""
    lines.each do |raw_line|
      half_indent = raw_line.any? { |t| t.type == :HALF_INDENT }
      keep_indent = raw_line.any? { |t| t.type == :KEEP_INDENT }
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
      outdent_leading = false
      if first && CLOSE_LEADING.include?(first.raw)
        depth = [depth - 1, 0].max
        line_depth = depth
      elsif !keep_indent && first && OUTDENT_LEADING.include?(first.raw)
        depth = [depth - 1, 0].max
        line_depth = depth
        outdent_leading = true
      end

      if half_indent
        # Function-signature metadata clause (RETURNS / REQUIRES / EFFECTS)
        # — render at exactly 1 space regardless of depth.
        out << " "
      else
        out << (INDENT * line_depth)
      end
      out << format_line_body(line)
      out << "\n"

      if last && OPEN_TERMINAL.include?(last.raw)
        depth += 1
      elsif outdent_leading
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
  sig { params(line: Array).returns(Array) }
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
      elsif t.type == :HALF_INDENT
        # Marker only; consumed by render's half_indent flag.
      elsif t.type == :KEEP_INDENT
        # Marker only; consumed by render's keep_indent flag.
      else
        filtered << t
        seen_code = true if t.type != :COMMENT
      end
    end
    [pre, post, filtered]
  end

  sig { params(toks: Array).returns(Array) }
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

  sig { params(line: Array).returns(T.nilable(Formatter::FormatLexer::Token)) }
  def first_code(line)
    line.find { |t| t.type != :COMMENT }
  end

  sig { params(line: Array).returns(T.nilable(Formatter::FormatLexer::Token)) }
  def last_code(line)
    line.reverse.find { |t| t.type != :COMMENT }
  end

  sig { params(lines: Array).returns(Array) }
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

  sig { params(lines: Array).returns(Array) }
  def drop_trailing_blanks(lines)
    lines = lines.dup
    lines.pop while lines.last && lines.last.empty?
    lines
  end

  # Emit a line's tokens with canonical intra-line spacing.
  # Comments get 2-space prefix if inline, 1 space after `#`.
  sig { params(line: Array).returns(String) }
  def format_line_body(line)
    @generic_bracket_indices = compute_generic_bracket_indices(line)
    @struct_lit_brace_indices = compute_struct_lit_brace_indices(line)
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

  # Pre-pass: identify which `<` / `>` tokens on this line are
  # generic-type brackets (rather than comparison operators) so
  # `needs_space?` can attach them tightly.
  #
  # A `<` is a generic open when:
  #   - the previous code token is a TYPE_ID (`Foo<...>`), AND
  #   - a matching `>` exists later on the line, AND
  #   - the span between them contains only TYPE_IDs, `,`, sigils,
  #     and nested `<>` pairs (no `(` `)` `[` `]` `{` `}` `=` etc).
  #
  # Returns a Set of token indices that are generic brackets (both
  # opens and closes).
  sig { params(line: Array).returns(Set) }
  def compute_generic_bracket_indices(line)
    set = Set.new
    line.each_with_index do |t, i|
      next unless t.type == :SYM && t.raw == '<'
      prev = preceding_code_token(line, i)
      next unless prev && prev.type == :TYPE_ID
      close_idx = find_generic_close_idx(line, i + 1)
      next unless close_idx
      set << i
      set << close_idx
    end
    set
  end

  # Walk forward from `start_idx` looking for the `>` that closes a
  # generic span opened just before. Tracks nested `<>` depth. Returns
  # the close index, or nil if anything that disqualifies the span as
  # a generic appears (call/index/struct-lit brackets, `=`, etc).
  sig { params(line: Array, start_idx: Integer).returns(Integer) }
  def find_generic_close_idx(line, start_idx)
    depth = 1
    i = start_idx
    while i < line.length
      t = line[i]
      if t.type == :SYM
        case t.raw
        when '<' then depth += 1
        when '>'
          depth -= 1
          return i if depth.zero?
        when '(', ')', '[', ']', '{', '}'
          return nil
        when '='
          return nil
        end
      end
      i += 1
    end
    nil
  end

  sig { params(line: Array, idx: Integer).returns(T.nilable(Formatter::FormatLexer::Token)) }
  def preceding_code_token(line, idx)
    j = idx - 1
    while j >= 0
      t = line[j]
      return t unless [:COMMENT, :INDENT_OPEN, :INDENT_CLOSE].include?(t.type)
      j -= 1
    end
    nil
  end

  # True when `line` contains a STRUCT / UNION / ENUM keyword at any
  # depth before token index `idx`. Used to disambiguate struct-body
  # `{` (`STRUCT Foo {`) from struct-literal `{` (`Foo{ ... }`).
  sig { params(line: Array, idx: Integer).returns(T::Boolean) }
  def line_has_struct_decl_keyword?(line, idx)
    line.first(idx).any? do |t|
      t.type == :KEYWORD && %w[STRUCT UNION ENUM].include?(t.raw)
    end
  end

  # Pre-pass: identify which `{` / `}` token indices on this line
  # belong to a struct literal (`Foo{ field: v }`), as opposed to a
  # block scope, hash literal, or struct-decl body.
  #
  # A `{` is a struct-literal open when:
  #   - the previous code token is a TYPE_ID, AND
  #   - the line does NOT introduce a STRUCT / UNION / ENUM
  #     declaration (in which case `{` is the body open).
  #
  # The matching `}` is found by simple `{` / `}` brace counting.
  sig { params(line: Array).returns(Set) }
  def compute_struct_lit_brace_indices(line)
    set = Set.new
    line.each_with_index do |t, i|
      next unless t.type == :SYM && t.raw == '{'
      prev = preceding_code_token(line, i)
      next unless prev && prev.type == :TYPE_ID
      next if line_has_struct_decl_keyword?(line, i)
      close_idx = find_matching_brace(line, i + 1)
      next unless close_idx
      set << i
      set << close_idx
    end
    set
  end

  sig { params(line: Array, start_idx: Integer).returns(T.nilable(Integer)) }
  def find_matching_brace(line, start_idx)
    depth = 1
    i = start_idx
    while i < line.length
      t = line[i]
      if t.type == :SYM
        case t.raw
        when '{' then depth += 1
        when '}'
          depth -= 1
          return i if depth.zero?
        end
      end
      i += 1
    end
    nil
  end

  # Normalize a `#...` comment: ensure AT LEAST one space after `#`,
  # preserving additional spaces the user wrote. Trailing whitespace
  # stripped. `#` alone stays `#`.
  #
  # Why preserve extra leading spaces? ASCII tables, indented prose,
  # and code samples in comment bodies use leading whitespace as
  # layout. Collapsing `#   row` to `# row` destroys alignment in
  # tables like:
  #
  #   # COL_A   | COL_B
  #   #   row1  | x
  #   #   row2  | y
  #
  # User-typed indent is meaningful; only synthesize the missing
  # first space when the user wrote `#text` with no separator.
  sig { params(raw: String).returns(String) }
  def canonicalize_comment(raw)
    body = raw[1..].to_s
    body = body.rstrip
    return '#' if body.empty?
    return "# #{body}" unless body.start_with?(' ', "\t")
    "##{body}"
  end

  # Spacing decision between two adjacent code tokens A (prev) and B (cur).
  sig { params(a: Formatter::FormatLexer::Token, b: Formatter::FormatLexer::Token, line: Array, b_idx: Integer).returns(T::Boolean) }
  def needs_space?(a, b, line, b_idx)
    # Capability attach (§4): @X flush-attaches to a type token when the
    # position is a type context (struct field, param type, RETURNS type).
    # Value position (`1 @locked`, `foo() @locked`) keeps the space.
    if b.type == :VAR_ID && b.raw.start_with?('@')
      type_like_prev = a.type == :TYPE_ID || (a.type == :SYM && a.raw == ']')
      return false if type_like_prev && in_type_context?(line, b_idx - 1)
    end

    # Struct-literal brace padding override (`Foo{ field: v }`):
    # add space after the `{` and before the matching `}`, EXCEPT
    # when they're the empty pair `Foo{}`. Sits before the generic
    # "no space inside brackets" rule below so the override wins.
    if @struct_lit_brace_indices && !@struct_lit_brace_indices.empty?
      a_idx = b_idx - 1
      a_is_struct_open = a_idx >= 0 &&
                         @struct_lit_brace_indices.include?(a_idx) &&
                         line[a_idx]&.raw == '{'
      b_is_struct_close = @struct_lit_brace_indices.include?(b_idx) &&
                          b.type == :SYM && b.raw == '}'
      empty_pair = a_is_struct_open && b_is_struct_close
      return true if a_is_struct_open && !empty_pair
      return true if b_is_struct_close && !empty_pair
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

    # Struct literal attach: `Foo{ field: v }`. The TYPE_ID-then-`{`
    # pattern is a struct literal UNLESS this line opens a STRUCT /
    # UNION / ENUM declaration, in which case `{` is the body open
    # and needs its leading space (`STRUCT Foo {`).
    if b.type == :SYM && b.raw == '{' && a.type == :TYPE_ID &&
       !line_has_struct_decl_keyword?(line, b_idx)
      return false
    end

    # Generic-bracket attach: `Foo<T, U>`. Detected per-line by
    # `compute_generic_bracket_indices`; the indices are stamped on
    # `@generic_bracket_indices` while `format_line_body` runs.
    if @generic_bracket_indices
      a_idx = b_idx - 1
      a_is_generic = a_idx >= 0 && @generic_bracket_indices.include?(a_idx)
      b_is_generic = @generic_bracket_indices.include?(b_idx)
      # `Foo<` — no space between the type and the generic-open `<`.
      if b_is_generic && b.raw == '<'
        return false
      end
      # `<Bar` — no space immediately inside the generic open.
      if a_is_generic && a.raw == '<'
        return false
      end
      # `Bar>` — no space before the generic close.
      if b_is_generic && b.raw == '>'
        return false
      end
    end

    # No space before `,` or `;`.
    if b.type == :SYM && (b.raw == ',' || b.raw == ';')
      return false
    end

    # Type annotation `:` — no space before, space after (default).
    if b.type == :SYM && b.raw == ':'
      return false
    end

    # Inline capability chain (`@shared:locked`, `@pool:shared:locked`):
    # no space after `:` when it chains off an `@cap` binding. The chain
    # is `@cap (: ident)+` — walk back through alternating colons and
    # identifiers; if the leftmost identifier starts with `@`, suppress
    # the space between this `:` and the next ident.
    if a.type == :SYM && a.raw == ':' && capability_chain_colon?(line, b_idx - 1)
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

  # Walk back from a `:` at `colon_idx` through alternating
  # `:identifier` segments. Returns true iff the chain bottoms out at
  # a `@cap` VAR_ID (i.e., `@cap (: ident)+ :`). A segment may carry a
  # parenthesized argument (`@sharded(8)`, `@shared:sharded(128):locked`);
  # we skip a trailing `(...)` group before falling back to the ident.
  # Used to decide whether a `:` belongs to an inline capability chain
  # rather than a normal type annotation.
  sig { params(line: Array, colon_idx: Integer).returns(T::Boolean) }
  def capability_chain_colon?(line, colon_idx)
    j = colon_idx
    while j >= 0
      t = line[j]
      return false unless t.type == :SYM && t.raw == ':'
      k = j - 1
      while k >= 0 && [:NL, :COMMENT, :INDENT_OPEN, :INDENT_CLOSE].include?(line[k].type)
        k -= 1
      end
      return false if k < 0
      # Skip a trailing `(...)` (e.g., `@sharded(8)`).
      if line[k].type == :SYM && line[k].raw == ')'
        k = skip_paren_group_back(line, k)
        return false if k < 0
        while k >= 0 && [:NL, :COMMENT, :INDENT_OPEN, :INDENT_CLOSE].include?(line[k].type)
          k -= 1
        end
        return false if k < 0
      end
      prev = line[k]
      return true if prev.type == :VAR_ID && prev.raw.start_with?('@')
      return false unless prev.type == :VAR_ID || prev.type == :TYPE_ID
      j = k - 1
      while j >= 0 && [:NL, :COMMENT, :INDENT_OPEN, :INDENT_CLOSE].include?(line[j].type)
        j -= 1
      end
    end
    false
  end

  # Walk back from a `)` at `idx` to the matching `(`. Returns the index
  # before the `(` (i.e., one to the left), or -1 if no match.
  sig { params(line: Array, idx: Integer).returns(Integer) }
  def skip_paren_group_back(line, idx)
    depth = 0
    j = idx
    while j >= 0
      t = line[j]
      if t.type == :SYM
        case t.raw
        when ')' then depth += 1
        when '('
          depth -= 1
          return j - 1 if depth.zero?
        end
      end
      j -= 1
    end
    -1
  end

  # Scan back from `line[idx]` to determine whether the position is a
  # type-annotation context. Returns true if the nearest non-nested
  # separator is `:` or `RETURNS`; false for `=` / `,` / `;` / start.
  sig { params(line: Array, idx: Integer).returns(T::Boolean) }
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
  sig { params(line: Array, a_idx: Integer).returns(T::Boolean) }
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
