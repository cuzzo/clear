module Puck
  # Stateless terminal helpers shared by run.rb and compile.rb. Nothing in here
  # assumes a particular visualizer layout; callers compose these into their
  # own rendering.
  module Terminal
    MIN_WIDTH = 70
    MIN_HEIGHT = 10

    # Best-effort terminal size. Falls back through TTY::Screen, winsize ioctls,
    # `stty size`, then $LINES / $COLUMNS, then a sane default. Always returns
    # at least [MIN_HEIGHT, MIN_WIDTH] so layout math never goes negative.
    def self.size
      return [TTY::Screen.height, TTY::Screen.width] if defined?(TTY::Screen)

      [STDOUT, STDIN, IO.console].compact.each do |io|
        rows, cols = io.winsize
        return [rows, cols] if rows.positive? && cols.positive?
      rescue SystemCallError, IOError
        next
      end

      rows, cols = `stty size 2>/dev/null`.split.map(&:to_i)
      return [rows, cols] if rows&.positive? && cols&.positive?

      rows = (ENV["LINES"] || 24).to_i
      cols = (ENV["COLUMNS"] || 80).to_i
      [[rows, MIN_HEIGHT].max, [cols, MIN_WIDTH].max]
    end

    def self.clear_and_home(interactive)
      return "" unless interactive
      return "" if ENV["TERM"] == "dumb"

      if defined?(TTY::Cursor)
        TTY::Cursor.clear_screen + TTY::Cursor.move_to(0, 0)
      else
        "\e[2J\e[H"
      end
    end

    def self.setup_cursor
      return unless STDOUT.tty?
      return if ENV["TERM"] == "dumb"

      if defined?(TTY::Cursor)
        print TTY::Cursor.hide
      else
        print "\e[?25l\e[0m"
      end
    end

    def self.restore_cursor
      return unless STDOUT.tty?
      return if ENV["TERM"] == "dumb"

      if defined?(TTY::Cursor)
        print TTY::Cursor.show
      else
        print "\e[?25h\e[0m"
      end
      print "\n"
      STDOUT.flush
    end

    def self.truncate(text, width)
      text = text.to_s
      text.length > width ? text[0, width] : text
    end

    # Pinned-to-bottom controls block used by both run.rb and compile.rb so
    # the runners have a consistent footer. The dividers span the full
    # screen width:
    #
    #     # --- CONTROLS --------------------------------------- #
    #     <keys>
    #     # --------------------------------------------------- #
    #
    # Returns 3 lines. Caller is responsible for reserving the rows.
    def self.controls_block(keys, width)
      top = "# --- CONTROLS "
      bottom_open = "# "
      close = " #"

      top_fill = [width - top.length - close.length, 3].max
      bottom_fill = [width - bottom_open.length - close.length, 3].max

      [
        top + ("-" * top_fill) + close,
        keys,
        bottom_open + ("-" * bottom_fill) + close
      ]
    end

    CONTROLS_HEIGHT = 3

    # Read one action from the terminal. Returns one of:
    #   :step, :back, :quit, :tokenize, :parse, :compile, :home, :end, nil
    # `reader` is a TTY::Reader instance if available, else nil (raw STDIN).
    def self.read_action(reader)
      key = reader ? reader.read_keypress : (STDIN.tty? ? STDIN.getch : STDIN.read(1))

      case key
        when " ", "\r", "\n" then :step
        when :backspace, "", "\b" then :back
        when "q", "", nil then :quit
        when "t" then :tokenize
        when "p" then :parse
        when "c" then :compile
        when "g", :home then :home
        when "G", :end then :end
        else nil
      end
    end
  end
end
