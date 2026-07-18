require "bundler/setup"
require_relative "../ruby/ast/ast"
require_relative "../ruby/mir/alloc"

RSpec.describe AllocHelper do
  let(:classifier) do
    Class.new do
      include AllocHelper
    end.new
  end

  it "classifies current OR_ELSE control nodes as non-allocating" do
    token = Lexer::Token.new(:OR_ELSE, "OR_ELSE", 1, 1)
    nodes = [
      AST::OrElsePass.new(token),
      AST::OrElseRaise.new(token),
      AST::OrElseExit.new(token, nil, nil, nil),
    ]

    expect(nodes).to all(satisfy { |node| !classifier.send(:expression_allocates?, node) })
  end
end
