require "rspec"
require_relative "../../ruby/lsp/position" unless defined?(LSP::Position)

RSpec.describe LSP::Position do
  Token = Struct.new(:line, :column, :value, keyword_init: true)

  describe ".range_for" do
    it "converts a 1-based ASCII token to a 0-based UTF-16 range" do
      tok = Token.new(line: 1, column: 5, value: "foo")
      r = LSP::Position.range_for(tok, 3, "    foo\n")
      expect(r).to eq(
        start: { line: 0, character: 4 },
        end:   { line: 0, character: 7 },
      )
    end

    it "shifts the range to a higher line" do
      tok = Token.new(line: 3, column: 1, value: "x")
      r = LSP::Position.range_for(tok, 1, "a\nb\nx\n")
      expect(r[:start][:line]).to eq(2)
      expect(r[:end][:line]).to eq(2)
    end

    it "falls through to byte offsets when source isn't supplied" do
      tok = Token.new(line: 1, column: 5, value: "foo")
      r = LSP::Position.range_for(tok, 3, nil)
      expect(r).to eq(
        start: { line: 0, character: 4 },
        end:   { line: 0, character: 7 },
      )
    end

    it "uses nil source by default" do
      tok = Token.new(line: 1, column: 2, value: "x")
      expect(LSP::Position.range_for(tok, 1)).to eq(
        start: { line: 0, character: 1 },
        end:   { line: 0, character: 2 },
      )
    end

    it "treats UTF-8 multi-byte chars as 1 UTF-16 code unit when below U+FFFF" do
      # `é` is 2 bytes (0xC3 0xA9) but 1 UTF-16 code unit.
      # Line text: "  é foo"; the `f` of `foo` is at byte column 5
      # but UTF-16 character 4 (because `é` counts as 1).
      line = "  é foo\n"
      tok = Token.new(line: 1, column: 6, value: "foo")  # 1-based byte col
      r = LSP::Position.range_for(tok, 3, line)
      expect(r[:start][:character]).to eq(4)
      expect(r[:end][:character]).to eq(7)
    end

    it "treats supplementary-plane chars as 2 UTF-16 code units" do
      # 🎉 is U+1F389 (4 bytes UTF-8 / 2 UTF-16 surrogates).
      line = "🎉 foo\n"
      tok = Token.new(line: 1, column: 6, value: "foo")  # `f` at byte col 6
      r = LSP::Position.range_for(tok, 3, line)
      # `🎉` = 2 UTF-16 + space (1) = 3 UTF-16 chars → `f` is char 3
      expect(r[:start][:character]).to eq(3)
      expect(r[:end][:character]).to eq(6)
    end

    it "rounds byte offsets inside a UTF-8 character to the next UTF-16 boundary" do
      tok = Token.new(line: 1, column: 2, value: "")
      r = LSP::Position.range_for(tok, 0, "éx\n")
      expect(r).to eq(
        start: { line: 0, character: 1 },
        end:   { line: 0, character: 1 },
      )
    end

    it "counts U+10000 as the first supplementary-plane codepoint" do
      tok = Token.new(line: 1, column: 5, value: "x")
      r = LSP::Position.range_for(tok, 1, "\u{10000}x\n")
      expect(r).to eq(
        start: { line: 0, character: 2 },
        end:   { line: 0, character: 3 },
      )
    end

    it "counts U+FFFF as one UTF-16 code unit" do
      tok = Token.new(line: 1, column: 4, value: "x")
      r = LSP::Position.range_for(tok, 1, "\u{FFFF}x\n")
      expect(r).to eq(
        start: { line: 0, character: 1 },
        end:   { line: 0, character: 2 },
      )
    end
  end

  describe ".range_for_span" do
    let(:span_class) do
      Struct.new(:file, :line, :col, :length, keyword_init: true) do
        def end_line; line; end
        def end_col;  col + length; end
      end
    end

    it "converts a single-line Span to an LSP range" do
      span = span_class.new(file: nil, line: 2, col: 3, length: 5)
      r = LSP::Position.range_for_span(span, "row1\n  hello\n")
      expect(r).to eq(
        start: { line: 1, character: 2 },
        end:   { line: 1, character: 7 },
      )
    end

    it "uses source text for UTF-16 columns in a single-line Span" do
      span = span_class.new(file: nil, line: 1, col: 4, length: 3)
      expect(LSP::Position.range_for_span(span, "é foo\n")).to eq(
        start: { line: 0, character: 2 },
        end:   { line: 0, character: 5 },
      )
    end

    it "uses nil source by default" do
      span = span_class.new(file: nil, line: 1, col: 2, length: 3)
      expect(LSP::Position.range_for_span(span)).to eq(
        start: { line: 0, character: 1 },
        end:   { line: 0, character: 4 },
      )
    end

    it "handles a multi-line Span via end_line override" do
      multi_span = Object.new
      def multi_span.line; 2; end
      def multi_span.end_line; 4; end
      def multi_span.col; 4; end
      def multi_span.end_col; 6; end
      r = LSP::Position.range_for_span(multi_span, "a\n é start\nmiddle\n🎉 end\n")
      expect(r).to eq(
        start: { line: 1, character: 2 },
        end:   { line: 3, character: 3 },
      )
    end
  end

  describe ".position_in_range?" do
    let(:range) {
      { start: { line: 2, character: 4 }, end: { line: 2, character: 10 } }
    }

    it "returns true for a position inside the range" do
      expect(LSP::Position.position_in_range?({ line: 2, character: 6 }, range)).to be true
    end

    it "does not apply start or end columns to middle lines" do
      multi_line = { start: { line: 2, character: 4 }, end: { line: 4, character: 10 } }
      expect(LSP::Position.position_in_range?({ line: 3, character: 0 }, multi_line)).to be true
      expect(LSP::Position.position_in_range?({ line: 3, character: 99 }, multi_line)).to be true
    end

    it "returns false above the range's start line" do
      expect(LSP::Position.position_in_range?({ line: 1, character: 100 }, range)).to be false
    end

    it "returns false below the range's end line" do
      expect(LSP::Position.position_in_range?({ line: 3, character: 0 }, range)).to be false
    end

    it "respects start-of-line column boundaries" do
      expect(LSP::Position.position_in_range?({ line: 2, character: 3 }, range)).to be false
      expect(LSP::Position.position_in_range?({ line: 2, character: 4 }, range)).to be true
    end

    it "respects end-of-line column boundaries" do
      expect(LSP::Position.position_in_range?({ line: 2, character: 10 }, range)).to be true
      expect(LSP::Position.position_in_range?({ line: 2, character: 11 }, range)).to be false
    end

    it "accepts string-keyed positions (LSP wire format)" do
      expect(LSP::Position.position_in_range?({ "line" => 2, "character" => 6 }, range)).to be true
    end
  end

  describe ".line_at" do
    it "returns the requested line without its trailing newline" do
      expect(LSP::Position.line_at("a\nbb\nccc\n", 0)).to eq("a")
      expect(LSP::Position.line_at("a\nbb\nccc\n", 1)).to eq("bb")
    end

    it "returns nil when out of bounds" do
      expect(LSP::Position.line_at("a\n", 1)).to be_nil
      expect(LSP::Position.line_at("a\n", 5)).to be_nil
      expect(LSP::Position.line_at("a\n", -1)).to be_nil
    end

    it "returns nil when source is nil" do
      expect(LSP::Position.line_at(nil, 0)).to be_nil
    end
  end
end
