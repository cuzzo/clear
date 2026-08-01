require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)

# V5-3a wiring: the annotator stamps each KEEP node with the physical op the
# OwnershipEdgePlanner selects from the source carrier (the ONE writer). No
# carrier normalization; a plain payload is a payload_copy, never an Rc.
RSpec.describe "KEEP carrier_op stamping" do
  def keep_op(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new.annotate!(ast)
    found = nil
    ast.statements.select { |s| s.is_a?(AST::FunctionDef) }.each do |fn|
      AST.each_locatable(fn.body, descend_functions: true) { |n| found ||= n if n.is_a?(AST::KeepNode) }
    end
    found&.carrier_op
  end

  KEEP_OP_PRE = "STRUCT User { name: String }\nFN obs(u: User) RETURNS Int64 -> RETURN u.name.length(); END\n"

  it "stamps rc_retain for KEEP of an @multiowned local" do
    src = KEEP_OP_PRE + "FN main() RETURNS Void -> s = User{ name: \"a\" } @multiowned; t = KEEP s; WITH s { ASSERT obs(s)==1; } WITH t { ASSERT obs(t)==1; } RETURN; END"
    expect(keep_op(src)).to eq(:rc_retain)
  end

  it "stamps arc_retain for KEEP of an @shared local" do
    src = KEEP_OP_PRE + "FN main() RETURNS Void -> s = User{ name: \"a\" } @shared; t = KEEP s; WITH s { ASSERT obs(s)==1; } WITH t { ASSERT obs(t)==1; } RETURN; END"
    expect(keep_op(src)).to eq(:arc_retain)
  end

  it "marks KEEP of a carrier-polymorphic param as deferred_specialization" do
    src = "STRUCT User { name: String }\nFN sink(TAKES u: User) RETURNS Void -> RETURN; END\nFN foo(TAKES u: User) RETURNS Void -> sink(KEEP u); sink(u); RETURN; END\nFN main() RETURNS Void -> foo(User{ name: \"a\" }); RETURN; END"
    expect(keep_op(src)).to eq(:deferred_specialization)
  end
end
