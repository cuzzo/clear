class CompilerError < StandardError
  attr_reader :token, :original_message, :source_code

  def initialize(token, message, source_code)
    @token = token
    @original_message = message
    @source_code = source_code
    # Calculate the fancy message immediately so standard `puts e` works
    super(build_message)
  end

  private

  def build_message
    line_num = @token.line
    col_num = @token.column

    # Handle case where source code isn't provided or file is empty
    return "[Error] #{@original_message} (Line #{line_num}, Col #{col_num})" if @source_code.nil? || @source_code.empty?

    lines = @source_code.split("\n")

    # Guard against EOF or out of bounds lines
    raw_line = lines[line_num - 1] || ""

    # 1. Header
    out = "\n\e[31m[Compiler Error]\e[0m #{@original_message}\n"
    out += "\e[90mLocation:\e[0m Line #{line_num}, Column #{col_num}\n\n"

    # 2. The Code Snippet
    # Calculate gutter width based on line number digits (e.g. "100" needs more space than "9")
    gutter_width = line_num.to_s.length

    # Line above (empty gutter)
    out += "  #{' ' * gutter_width} | \n"

    # The actual line of code
    out += "  #{line_num} | #{raw_line}\n"

    # The Pointer (Caret)
    # We need to account for tabs in the source line to align the caret correctly
    # Simple approach: Swap tabs for spaces in the prefix calculation
    prefix = raw_line[0...col_num-1] || ""
    visual_offset = prefix.gsub("\t", "  ").length # Assuming tab = 2 spaces, adjust if needed

    out += "  #{' ' * gutter_width} | \e[31m#{' ' * visual_offset}^\e[0m\n"
    out += "  #{' ' * gutter_width} | \n"

    out
  end
end

