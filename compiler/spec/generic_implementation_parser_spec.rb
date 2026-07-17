# typed: false
require "rspec"
require_relative "../ruby/ast/parser"

RSpec.describe "bounded generics and IMPLEMENTATION parsing" do
  def parse(source, file: "cache.clear")
    tokens = Lexer.new(source, file: file).tokenize
    ClearParser.new(tokens, source).parse
  end

  it "preserves simple and intersected bounds on struct parameters" do
    node = parse("STRUCT Cache<M: SHARED Map, K: Hashable & Equality> { values: M }").statements.first

    expect(node).to be_a(AST::StructDef)
    expect(node.type_params).to eq(["M", "K"])
    expect(node.generic_params.map(&:name)).to eq(["M", "K"])
    expect(node.generic_params[0].bounds.map { |bound| bound.type.resolved }).to eq([:Map])
    expect(node.generic_params[0].bounds.first.type).to be_polymorphic_shared
    expect(node.generic_params[1].bounds.map { |bound| bound.type.resolved }).to eq([:Hashable, :Equality])
    expect(node.generic_params[0].token.file).to eq("cache.clear")
  end

  it "preserves bounds on generic functions and unions" do
    ast = parse(<<~CLEAR)
      FN lookup<M: Map>(map: M) RETURNS Void -> PASS END
      UNION Result<T: Serializable> { Value: T }
    CLEAR

    fn = ast.statements[0]
    union = ast.statements[1]
    expect(fn.generic_params.first.bounds.first.type.resolved).to eq(:Map)
    expect(union.generic_params.first.bounds.first.type.resolved).to eq(:Serializable)
  end

  it "parses owner binders, generic methods, and static functions" do
    node = parse(<<~CLEAR).statements.first
      IMPLEMENTATION Cache<M> {
        PUB METHOD map<N>(self: Cache<M>, fn: FN(M) -> N) RETURNS []N ->
          RETURN [];
        END
        PRIVATE FN make(map: M) RETURNS Cache<M> ->
          PASS
        END
      }
    CLEAR

    expect(node).to be_a(AST::ImplementationDef)
    expect(node.owner_name).to eq("Cache")
    expect(node.owner_token.file).to eq("cache.clear")
    expect(node.binders.map(&:name)).to eq(["M"])
    expect(node.members.map(&:name)).to eq(["map", "make"])
    expect(node.members.map(&:visibility)).to eq([:pub, :private])
    expect(node.members.map(&:is_method)).to eq([true, false])
    expect(node.members.first.generic_params.map(&:name)).to eq(["N"])
    expect(node.members.all? { |member| member.source_range.file == "cache.clear" }).to be(true)
  end

  it "parses a nongeneric owner and an empty implementation" do
    node = parse("IMPLEMENTATION User {}").statements.first

    expect(node.owner_name).to eq("User")
    expect(node.binders).to eq([])
    expect(node.members).to eq([])
  end

  it "rejects data declarations inside an implementation" do
    expect {
      parse("IMPLEMENTATION Cache<M> { value: M }")
    }.to raise_error(ParserError, /Expected FN, METHOD, or \} in IMPLEMENTATION/)
  end
end
