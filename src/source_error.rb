class SourceError < StandardError
  attr_reader :token, :original_message, :source_code

  def initialize(token, message, source_code)
    @token = token
    @original_message = message
    @source_code = source_code
    super(build_message)
  end

  # Child classes override this for the header title
  def error_type; "Error"; end

  private

  def build_message
    # Handle EOF or missing token
    if @token.nil? || @token.type == :EOF
      return "\n\e[31m[#{error_type}]\e[0m #{@original_message} (at End of File)\n"
    end

    line_num = @token.line
    col_num = @token.column

    return "[#{error_type}] #{@original_message} (Line #{line_num})" if @source_code.nil? || @source_code.empty?

    lines = @source_code.split("\n")
    raw_line = lines[line_num - 1] || ""

    # 1. Header
    out = "\n\e[31m[#{error_type}]\e[0m #{@original_message}\n"
    out += "\e[90mLocation:\e[0m Line #{line_num}, Column #{col_num}\n\n"

    # 2. The Code Snippet
    gutter_width = line_num.to_s.length
    out += "  #{' ' * gutter_width} | \n"
    out += "  #{line_num} | #{raw_line}\n"

    # 3. The Caret
    prefix = raw_line[0...col_num-1] || ""
    visual_offset = prefix.gsub("\t", "  ").length

    out += "  #{' ' * gutter_width} | \e[31m#{' ' * visual_offset}^\e[0m\n"
    out += "  #{' ' * gutter_width} | \n"

    out
  end
end

class ParserError < SourceError
  def error_type; "Parser Error"; end
end

class CompilerError < SourceError
  def error_type; "Compiler Error"; end
end

