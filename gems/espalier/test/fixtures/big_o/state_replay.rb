# parse_statement(n) = speculate(n) + parse_value(n)
# speculate(n) = parse_value(n) + O(1), and parse_value(n) = parse_statement(n - 1) + O(1).
# Therefore parse_statement(n) = 2 * parse_statement(n - 1) + O(1).
class ReplayCursor
  def initialize(tokens)
    @tokens = tokens
    @cursor = 0
  end

  def parse_statement
    speculate
    parse_value
  end

  def speculate
    checkpoint = @cursor
    parse_value
    @cursor = checkpoint
  end

  def parse_value
    return if @cursor >= @tokens.length

    @tokens[@cursor]
    @cursor += 1
    parse_statement
  end
end
