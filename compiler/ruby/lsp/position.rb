# typed: strict
require "sorbet-runtime"
module LSP
  # Converts CLEAR's 1-based (line, column, length) tokens to LSP's
  # 0-based (line, character) positions. The two coordinate systems
  # disagree on:
  #
  #   1. Origin: CLEAR is 1-based; LSP is 0-based.
  #   2. Encoding: LSP characters are UTF-16 code units. CLEAR tokens
  #      hold byte columns from the source. For ASCII source they're
  #      equivalent; for UTF-8 strings, `é` is one byte but two UTF-16
  #      code units (still — most CLEAR source is ASCII so this only
  #      bites on string literals or comments with multi-byte chars).
  #
  # We expose two entry points: `range_for(token, length, source)` for
  # tokens (used by Diagnostics) and `range_for_span(span, source)` for
  # Edits (used by CodeActions).
  module Position
    extend T::Sig
    TokenLike = T.type_alias { T.untyped }
    SpanLike = T.type_alias { T.untyped }
    PositionHash = T.type_alias { T::Hash[Symbol, Integer] }
    RangeHash = T.type_alias { T::Hash[Symbol, PositionHash] }
    WirePositionHash = T.type_alias { T::Hash[T.any(String, Symbol), Integer] }
    WireRangeHash = T.type_alias { T::Hash[T.any(String, Symbol), WirePositionHash] }

    # Convert a CLEAR token + length into an LSP `Range` hash.
    # `source` is the full document text (needed for the UTF-16
    # column calculation). When `source` is nil or the line is pure
    # ASCII, this falls through to the fast byte-equals-character
    # path.
    sig { params(token: TokenLike, length: Integer, source: T.nilable(String)).returns(RangeHash) }
    def self.range_for(token, length, source = nil)
      line = token.line - 1
      col_start_byte = token.column - 1
      col_end_byte   = col_start_byte + length

      line_text = line_at(source, line)
      start_char = byte_to_utf16(line_text, col_start_byte)
      end_char   = byte_to_utf16(line_text, col_end_byte)

      {
        start: { line: line, character: start_char },
        end:   { line: line, character: end_char },
      }
    end

    # Convert a Span (file/line/col/length, with possibly multi-line
    # extent) into an LSP `Range`. CLEAR Spans currently always live
    # on a single line; if that changes, the helper extends naturally.
    sig { params(span: SpanLike, source: T.nilable(String)).returns(RangeHash) }
    def self.range_for_span(span, source = nil)
      start_line = span.line - 1
      end_line   = span.end_line - 1
      start_byte = span.col - 1
      end_byte   = span.end_col - 1

      start_text = line_at(source, start_line)
      end_text = start_line == end_line ? start_text : line_at(source, end_line)

      {
        start: { line: start_line, character: byte_to_utf16(start_text, start_byte) },
        end:   { line: end_line,   character: byte_to_utf16(end_text,   end_byte) },
      }
    end

    # Test whether an LSP position falls within an LSP range.
    sig { params(position: WirePositionHash, range: WireRangeHash).returns(T::Boolean) }
    def self.position_in_range?(position, range)
      pl = T.must(position[:line] || position["line"])
      pc = T.must(position[:character] || position["character"])
      start_pos = T.must(range[:start] || range["start"])
      end_pos = T.must(range[:end] || range["end"])
      sl = T.must(start_pos[:line] || start_pos["line"])
      sc = T.must(start_pos[:character] || start_pos["character"])
      el = T.must(end_pos[:line] || end_pos["line"])
      ec = T.must(end_pos[:character] || end_pos["character"])
      return false if pl < sl || pl > el
      return false if pl == sl && pc < sc
      return false if pl == el && pc > ec
      true
    end

    # ---- internals ----

    # Return the substring of `source` for the given 0-based line, or
    # nil if out of bounds. We split lazily to keep large documents
    # cheap for single-token lookups.
    sig { params(source: T.nilable(String), line_idx: Integer).returns(T.nilable(String)) }
    def self.line_at(source, line_idx)
      return nil unless source
      lines = source.lines
      return nil if line_idx < 0 || line_idx >= lines.size
      lines.fetch(line_idx).chomp
    end

    # Given a line of text and a byte offset, return the UTF-16 code
    # unit count from the start of the line. ASCII-only lines short-
    # circuit to the byte count. For multi-byte source, walk the line's
    # codepoints and sum their UTF-16 widths.
    sig { params(line_text: T.nilable(String), byte_offset: Integer).returns(Integer) }
    def self.byte_to_utf16(line_text, byte_offset)
      return byte_offset if line_text.nil? || line_text.ascii_only?

      bytes = 0
      utf16 = 0
      line_text.each_char do |ch|
        break if bytes >= byte_offset
        bytes += ch.bytesize
        # Codepoints above U+FFFF take two UTF-16 code units (surrogate
        # pair); below, one. Ruby's String#each_char yields one Unicode
        # character per iteration, so counting code units means a per-
        # char dispatch on codepoint magnitude.
        utf16 += ch.ord > 0xFFFF ? 2 : 1
      end
      utf16
    end
  end
end
