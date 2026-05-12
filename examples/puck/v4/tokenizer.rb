require 'strscan'

# Our token that holds semantic meaning from raw code
Token = Struct.new(:type, :value)

# 1. Tokenizer: Break raw puck code into semantic tokens
class Tokenizer
  def initialize(code)
    @scanner = StringScanner.new(code)
  end

  # Scan the raw code string until the end, extract tokens along the way
  def tokenize
    tokens = []
    until @scanner.eos?
      next if @scanner.skip(/\s+/) # Tokens are separated by whitespace

      if match = @scanner.scan(/\d+/)
        tokens << Token.new(:INTEGER, match.to_i)

      elsif match = @scanner.scan(/:=|[()+\-*\/%=,;]/)
        tokens << Token.new(:OPERATOR, match)

      elsif match = @scanner.scan(/PROCEDURE|RETURN|IF|THEN|LOOP|EXIT|END|SYSCALL|[a-zA-Z_]\w*/)
        keywords = {
          "PROCEDURE" => :PROCEDURE,
          "RETURN" => :RETURN,
          "IF" => :IF,
          "THEN" => :THEN,
          "LOOP" => :LOOP,
          "EXIT" => :EXIT,
          "END" => :END,
          "SYSCALL" => :SYSCALL,
        }
        type = keywords.fetch(match, :SYMBOL)
        tokens << Token.new(type, match)
      else
        raise "Unexpected character #{@scanner.peek(1).inspect} at position #{@scanner.pos}"
      end
    end

    return tokens
  end
end
