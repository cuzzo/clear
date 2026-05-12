require 'strscan'

# Our token that holds semantic meaning from raw code
Token = Struct.new(:type, :value)

# 1. Tokenizer: Break raw puck code into semantic tokens
class Tokenizer
  KEYWORDS = %w[
    PROCEDURE RETURN
    IF THEN
    LOOP EXIT
    END SYSCALL
  ].freeze

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

      elsif match = @scanner.scan(/"[^"]*"/)
        tokens << Token.new(:STRING, match[1...-1])

      elsif match = @scanner.scan(/:=|[()+\-*\/%=,;]/)
        tokens << Token.new(:OPERATOR, match)

      elsif match = @scanner.scan(/[a-zA-Z_]\w*/)
        type = KEYWORDS.include?(match) ? match.to_sym : :SYMBOL
        tokens << Token.new(type, match)
      else
        raise "Unexpected character #{@scanner.peek(1).inspect} at position #{@scanner.pos}"
      end
    end

    return tokens
  end
end
