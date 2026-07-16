# typed: false
require "rspec"
require_relative "../ruby/annotator/phases/resolution_phase"
require_relative "../ruby/annotator/annotator"

RSpec.describe "generic implementation resolution" do
  def parse(source, file: "cache.clear")
    tokens = Lexer.new(source, file: file).tokenize
    ClearParser.new(tokens, source).parse
  end

  def resolve(source, file: "cache.clear", root_scope: nil)
    program = parse(source, file: file)
    session = Annotator::Phases::ResolutionSession.new(
      importer: nil,
      source_dir: File.dirname(file),
      source_code: source,
      root_scope: root_scope,
      install_builtins: true,
    )
    session.resolve!(program)
  end

  it "binds implementation parameters positionally and inherits owner bounds" do
    facts = resolve(<<~CLEAR)
      STRUCT Cache<Store: SHARED Map> { values: Store }
      IMPLEMENTATION Cache<M> {
        METHOD get(self: Cache<M>) RETURNS Void -> PASS END
      }
    CLEAR

    resolution = facts.implementation_resolutions.fetch(0)
    binding = resolution.bindings.fetch(0)
    expect(resolution.owner.name).to eq("Cache")
    expect(binding.position).to eq(0)
    expect(binding.local_param.name).to eq("M")
    expect(binding.owner_param.name).to eq("Store")
    expect(binding.owner_param.bounds.first.type.resolved).to eq(:Map)
    expect(binding.owner_param.bounds.first.type).to be_polymorphic_shared
  end

  it "accepts a nongeneric owner without binders" do
    facts = resolve("STRUCT User { id: Int64 } IMPLEMENTATION User {}")
    expect(facts.implementation_resolutions.first.bindings).to eq([])
  end

  it "rejects missing and extra owner binders with the declared arity" do
    expect {
      resolve("STRUCT Cache<M: Map> { value: M } IMPLEMENTATION Cache {}")
    }.to raise_error(CompilerError, /IMPLEMENTATION Cache expects 1 owner binder.*M.*got 0/m)

    expect {
      resolve("STRUCT Cache<M: Map> { value: M } IMPLEMENTATION Cache<M, K> {}")
    }.to raise_error(CompilerError, /IMPLEMENTATION Cache expects 1 owner binder.*got 2/m)
  end

  it "rejects duplicate, bounded, and type-shadowing implementation binders" do
    expect {
      resolve("STRUCT Pair<A, B> { a: A, b: B } IMPLEMENTATION Pair<T, T> {}")
    }.to raise_error(CompilerError, /binds 'T' more than once/)

    expect {
      resolve("STRUCT Cache<M: Map> { value: M } IMPLEMENTATION Cache<M: Map> {}")
    }.to raise_error(CompilerError, /binder 'M' must not repeat or replace/)

    expect {
      resolve("STRUCT Item { id: Int64 } STRUCT Cache<M> { value: M } IMPLEMENTATION Cache<Item> {}")
    }.to raise_error(CompilerError, /binder 'Item' shadows a visible type/)
  end

  it "rejects unknown, non-local, duplicate, and wrong-file implementations" do
    expect {
      resolve("IMPLEMENTATION Missing {}")
    }.to raise_error(CompilerError, /Cannot implement unknown type 'Missing'/)

    scope = Scope.new
    scope.declare_type(:Imported, Schemas::StructSchema.new)
    expect {
      resolve("IMPLEMENTATION Imported {}", root_scope: scope)
    }.to raise_error(CompilerError, /Cannot add inherent methods to non-local type 'Imported'/)

    expect {
      resolve("STRUCT User { id: Int64 } IMPLEMENTATION User {} IMPLEMENTATION User {}")
    }.to raise_error(CompilerError, /already has an inherent IMPLEMENTATION/)

    owner = parse("STRUCT User { id: Int64 }", file: "models/user.clear")
    implementation = parse("IMPLEMENTATION User {}", file: "extensions/user.clear")
    program = AST::Program.new(owner.token, owner.statements + implementation.statements)
    session = Annotator::Phases::ResolutionSession.new(
      importer: nil,
      source_dir: ".",
      source_code: "",
      install_builtins: true,
    )
    expect {
      session.resolve!(program)
    }.to raise_error(CompilerError, /Cannot implement 'User' in extensions\/user.clear.*models\/user.clear/m)
  end

  it "rejects generic parameters that shadow nominal types regardless of declaration order" do
    expect {
      resolve(<<~CLEAR)
        FN identity<User>(value: User) RETURNS User -> RETURN value; END
        STRUCT User { id: Int64 }
      CLEAR
    }.to raise_error(CompilerError, /Type parameter 'User' shadows a visible nominal type/)
  end

  it "keeps one nominal type identity regardless of bounds" do
    expect {
      resolve(<<~CLEAR)
        STRUCT Cache<M: Map> { value: M }
        STRUCT Cache<L: List> { value: L }
      CLEAR
    }.to raise_error(CompilerError, /Duplicate type declaration 'Cache'/)
  end

  it "rejects wrong generic arity in a function signature before its body matters" do
    source = <<~CLEAR
      STRUCT Cache<M: Map> { value: M }
      FN inspect<T, K>(cache: Cache<T, K>) RETURNS Void -> PASS END
    CLEAR

    expect {
      SemanticAnnotator.new.annotate!(parse(source))
    }.to raise_error(CompilerError, /'Cache' expects 1 type argument.*got 2/)
  end
end
