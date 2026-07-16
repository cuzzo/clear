# typed: false
require "rspec"
require_relative "../ruby/backends/transpiler"

RSpec.describe "generic protocol declarations" do
  def transpile(source)
    ZigTranspiler.new.transpile(source)
  end

  it "parses associated types and method requirements as a reusable bound" do
    source = <<~CLEAR
      PROTOCOL Lookup<Key, Value> {
        METHOD get(self: Self, key: Key) RETURNS !?Value;
        METHOD put!(MUTABLE self: Self, key: Key, value: Value) RETURNS !Void;
      }
      STRUCT Box<S: Lookup> { storage: S }
      FN main() RETURNS Void -> PASS END
    CLEAR

    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    protocol = program.statements.first
    expect(protocol).to be_a(AST::ProtocolDef)
    expect(protocol.associated_types.map(&:name)).to eq(%w[Key Value])
    expect(protocol.requirements.map(&:name)).to eq(%w[get put!])
    expect(protocol.requirements.last.params.first.mutable).to be(true)
    expect { transpile(source) }.not_to raise_error
  end

  it "rejects duplicate protocol requirements at the declaration" do
    expect {
      transpile(<<~CLEAR)
        PROTOCOL Named {
          METHOD name(self: Self) RETURNS String;
          METHOD name(self: Self) RETURNS String;
        }
      CLEAR
    }.to raise_error(CompilerError, /declares 'name' more than once/i)
  end

  it "supports public FN predicates with an implicit Void requirement" do
    source = "PUB PROTOCOL Predicate { FN valid?(self: Self); }"
    protocol = ClearParser.new(Lexer.new(source).tokenize, source).parse.statements.first
    requirement = protocol.requirements.first

    expect(protocol.visibility).to eq(:pub)
    expect(requirement.name).to eq("valid?")
    expect(requirement.is_method).to be(false)
    expect(requirement.return_type.void?).to be(true)
    expect { transpile(source) }.not_to raise_error
  end

  it "does not allow a user protocol to replace an intrinsic protocol" do
    expect {
      transpile("PROTOCOL Map { METHOD count(self: Self) RETURNS Int64; }")
    }.to raise_error(CompilerError, /Duplicate protocol declaration 'Map'/)
  end

  it "rejects duplicate associated types at the declaration" do
    expect {
      transpile("PROTOCOL Lookup<Key, Key> { METHOD get(self: Self) RETURNS Key; }")
    }.to raise_error(CompilerError, /Duplicate type parameter 'Key'/)
  end

  it "still rejects a bound that names no declared protocol" do
    expect {
      transpile("STRUCT Box<S: Missing> { storage: S }")
    }.to raise_error(CompilerError, /Unknown generic protocol Missing/)
  end
end
