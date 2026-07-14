require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)

RSpec.describe "ClearParser task prefixes" do
  def parse_statement(source)
    ClearParser.new(Lexer.new(source).tokenize, source).send(:parse_statement)
  end

  it "returns explicit defaults for an unprefixed DO branch" do
    branch = parse_statement("DO { work() }").branches.first

    expect([branch.stack_size, branch.pinned, branch.parallel, branch.can_smash])
      .to eq([nil, false, false, false])
  end

  it "accumulates the shared prefix dimensions for DO and BG" do
    branch = parse_statement("DO { @micro:pinned:parallel:canSmash -> work() }").branches.first
    expect([branch.stack_size, branch.pinned, branch.parallel, branch.can_smash])
      .to eq([:micro, true, true, true])

    bg = parse_statement("BG { @large:parallel:arena:canSmash -> work(); }")
    expect([bg.stack_size, bg.pinned, bg.parallel, bg.arena_mode, bg.can_smash])
      .to eq([:large, true, true, true, true])
    expect(bg.prefix_token.text!).to eq("@large")
    expect(bg.can_smash_token.text!).to eq("canSmash")
  end

  it "retains prefix-specific duplicate and typo diagnostics" do
    expect { parse_statement("DO { @micro:large -> work() }") }
      .to raise_error(ParserError, /Duplicate stack size/)
    expect { parse_statement("BG { @micor -> work(); }") }
      .to raise_error(ParserError, /Unknown BG prefix/)
    expect { parse_statement("DO { @micro:pined -> work() }") }
      .to raise_error(ParserError, /Unknown branch prefix/)
  end
end
