require_relative 'terminal'

module Puck
  # Renders the program source with an optional `>` cursor on a focus line and
  # an optional `^^^^` underline under a column span. Used by both run.rb (no
  # span — just the cursor on the current source line) and compile.rb
  # (cursor + span on the current token / AST node).
  class SourceView
    LINE_PREFIX_WIDTH = 7  # "> 001: "

    def initialize(source)
      @lines = source.lines.map(&:chomp)
    end

    attr_reader :lines

    # Render `height` lines as a string. focus_line is 0-indexed; nil means
    # "no cursor, just show the top of the file". span is
    # { line: 0-idx, col_start: 0-idx, col_end: 0-idx exclusive } or nil.
    # If span is given, an extra ^^^^ row is inserted right below the span line.
    def render(width:, height:, focus_line: nil, span: nil)
      start = window_start(focus_line, height)
      rows = []
      idx = start
      while rows.length < height && idx < @lines.length
        rows << render_line(idx, focus_line, width)
        if span && span[:line] == idx
          rows << render_underline(span, width)
        end
        idx += 1
      end
      # Pad to height with blank lines.
      rows.fill("", rows.length...height)
      rows.first(height).join("\n")
    end

    private

    # Pick the top line so the focus line lands ~4 from the top, but clip so we
    # never scroll past the end of the file unless the file is shorter than the
    # window.
    def window_start(focus_line, height)
      focus = focus_line || first_nonblank_line
      raw = [focus - 4, 0].max
      max_start = [@lines.length - height, 0].max
      [raw, max_start].min
    end

    def first_nonblank_line
      @lines.each_with_index { |line, idx| return idx unless line.strip.empty? }
      0
    end

    def render_line(idx, focus_line, width)
      marker = (idx == focus_line) ? ">" : " "
      Terminal.truncate("#{marker} #{format('%03d', idx + 1)}: #{@lines[idx]}", width)
    end

    def render_underline(span, width)
      line_text = @lines[span[:line]] || ""
      col_start = [span[:col_start], 0].max
      col_end = [[span[:col_end], col_start].max, line_text.length].min
      span_len = [col_end - col_start, 1].max
      prefix = " " * (LINE_PREFIX_WIDTH + col_start)
      Terminal.truncate(prefix + ("^" * span_len), width)
    end
  end
end
