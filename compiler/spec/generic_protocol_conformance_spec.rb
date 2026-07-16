# typed: false
require "rspec"
require_relative "../ruby/annotator/annotator"
require_relative "../ruby/ast/diagnostic_buckets"

RSpec.describe "explicit generic protocol conformances" do
  class ImportedProtocolResolutionSession < Annotator::Phases::ResolutionSession
    def install_imported_protocol(protocol)
      register_protocol!(protocol)
    end
  end

  def annotate(source)
    program = ClearParser.new(Lexer.new(source, file: "conformance.clear").tokenize, source).parse
    SemanticAnnotator.new.annotate!(program)
    program
  end

  def expect_error(source, pattern)
    expect { annotate(source) }.to raise_error(CompilerError, pattern)
  end

  it "validates concrete and generic conformances through semantic types" do
    concrete = <<~CLEAR
      PROTOCOL Sized { METHOD size(self: Self) RETURNS Int64; }
      STRUCT Box { value: Int64 }
      IMPLEMENTATION Sized FOR Box {
        METHOD size(self) RETURNS Int64 -> RETURN self.value; END
      }
      FN main() RETURNS Void -> PASS END
    CLEAR
    generic = <<~CLEAR
      PROTOCOL Lookup<Key, Value> {
        METHOD get(self: Self, key: Key) RETURNS ?Value;
      }
      STRUCT Store<K, V> { last_key: ?K fallback: ?V }
      IMPLEMENTATION<K, V> Lookup<K, V> FOR Store<K, V> {
        METHOD get(self, key: K) RETURNS ?V -> RETURN NIL; END
      }
      FN main() RETURNS Void -> PASS END
    CLEAR

    expect { annotate(concrete) }.not_to raise_error
    program = annotate(generic)
    annotator = SemanticAnnotator.new
    annotator.annotate!(ClearParser.new(Lexer.new(generic).tokenize, generic).parse)
    resolution = annotator.annotation_products.resolution
    expect(resolution).not_to be_nil
    resolution = resolution
    conformance = resolution.conformance_resolutions.fetch(0)
    expect(conformance.owner_name).to eq("Store")
    expect(conformance.owner_generic_params.map(&:name)).to eq(%w[K V])
    expect(conformance.associated_types.transform_values(&:resolved)).to eq(Key: :K, Value: :V)
    expect(program.statements.grep(AST::FunctionDef).map(&:name)).to include("__conformance_Lookup_Store_get")
  end

  it "allows a locally owned protocol to adapt a target scalar" do
    expect {
      annotate(<<~CLEAR)
        PROTOCOL Sized { METHOD size(self: Self) RETURNS Int64; }
        IMPLEMENTATION Sized FOR Int64 {
          METHOD size(self) RETURNS Int64 -> RETURN self; END
        }
        FN main() RETURNS Void -> PASS END
      CLEAR
    }.not_to raise_error
  end

  it "enforces the orphan rule for imported protocol and type facts" do
    protocol_source = "PROTOCOL ForeignNamed { METHOD name(self: Self) RETURNS String; }"
    protocol = ClearParser.new(Lexer.new(protocol_source).tokenize, protocol_source).parse.statements.first
    source = <<~CLEAR
      IMPLEMENTATION ForeignNamed FOR ForeignUser {
        METHOD name(self) RETURNS String -> RETURN "foreign"; END
      }
    CLEAR
    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    root = Scope.new
    root.install_type(:ForeignUser, Schemas::StructSchema.new)
    session = ImportedProtocolResolutionSession.new(
      importer: nil,
      source_dir: Dir.pwd,
      source_code: source,
      root_scope: root,
    )
    session.install_imported_protocol(protocol)

    expect { session.resolve!(program) }.to raise_error(CompilerError, /owns neither side/i)
  end

  it "rejects unknown, orphaned, duplicate, and wrong-arity headers" do
    expect_error(<<~CLEAR, /unknown protocol Missing/i)
      STRUCT User { id: Int64 }
      IMPLEMENTATION Missing FOR User { METHOD name(self) RETURNS Int64 -> RETURN 1_i64; END }
    CLEAR
    expect_error(<<~CLEAR, /unknown type MissingOwner/i)
      PROTOCOL Named { METHOD name(self: Self) RETURNS String; }
      IMPLEMENTATION Named FOR MissingOwner { METHOD name(self) RETURNS String -> RETURN "x"; END }
    CLEAR
    expect_error(<<~CLEAR, /already has a Named conformance/i)
      PROTOCOL Named { METHOD name(self: Self) RETURNS String; }
      STRUCT User { id: Int64 }
      IMPLEMENTATION Named FOR User { METHOD name(self) RETURNS String -> RETURN "x"; END }
      IMPLEMENTATION Named FOR User { METHOD name(self) RETURNS String -> RETURN "y"; END }
    CLEAR
    expect_error(<<~CLEAR, /Lookup expects 2 associated type argument\(s\), got 1/i)
      PROTOCOL Lookup<Key, Value> { METHOD get(self: Self, key: Key) RETURNS ?Value; }
      STRUCT User { id: Int64 }
      IMPLEMENTATION Lookup<String> FOR User { METHOD get(self, key: String) RETURNS ?Int64 -> RETURN NIL; END }
    CLEAR
    expect_error(<<~CLEAR, /owner Pair expects 2 type argument\(s\), got 1/i)
      PROTOCOL Named { METHOD name(self: Self) RETURNS String; }
      STRUCT Pair<K, V> { key: K value: V }
      IMPLEMENTATION<K> Named FOR Pair<K> { METHOD name(self) RETURNS String -> RETURN "x"; END }
    CLEAR
  end

  it "reports all missing and extra requirements together" do
    expect_error(<<~CLEAR, /2 incompatible requirement.*name: missing.*extra: not declared by Named/m)
      PROTOCOL Named {
        METHOD name(self: Self) RETURNS String;
      }
      STRUCT User { id: Int64 }
      IMPLEMENTATION Named FOR User {
        METHOD extra(self) RETURNS String -> RETURN "x"; END
      }
    CLEAR
  end

  it "checks member kind, arity, ownership, mutability, and return type" do
    prefix = <<~CLEAR
      PROTOCOL Store<Key, Value> {
        METHOD put!(MUTABLE self: Self, TAKES key: Key, value: Value) RETURNS !Void;
      }
      STRUCT Box<K, V> { marker: Int64 }
    CLEAR
    cases = {
      "expected METHOD, found FN" => "FN put!(MUTABLE self: Box<K, V>, TAKES key: K, value: V) RETURNS !Void -> RETURN; END",
      "expected 3 parameter(s), found 2" => "METHOD put!(MUTABLE self, TAKES key: K) RETURNS !Void -> RETURN; END",
      "parameter 1 is incompatible" => "METHOD put!(self, TAKES key: K, value: V) RETURNS !Void -> RETURN; END",
      "parameter 2 is incompatible" => "METHOD put!(MUTABLE self, key: K, value: V) RETURNS !Void -> RETURN; END",
      "expected RETURNS !Void, found Void" => "METHOD put!(MUTABLE self, TAKES key: K, value: V) RETURNS Void -> RETURN; END",
    }

    cases.each do |message, member|
      expect_error(<<~CLEAR, /#{Regexp.escape(message)}/)
        #{prefix}
        IMPLEMENTATION<K, V> Store<K, V> FOR Box<K, V> { #{member} }
      CLEAR
    end
  end

  it "checks duplicate members, receiver presence, and conformance binders" do
    base = <<~CLEAR
      PROTOCOL Named { METHOD name(self: Self) RETURNS String; }
      STRUCT User { id: Int64 }
    CLEAR
    expect_error(<<~CLEAR, /declares 'name' more than once/i)
      #{base}
      IMPLEMENTATION Named FOR User {
        METHOD name(self) RETURNS String -> RETURN "x"; END
        METHOD name(self) RETURNS String -> RETURN "y"; END
      }
    CLEAR
    expect_error(<<~CLEAR, /METHOD 'name'.*must declare self as its first parameter/i)
      #{base}
      IMPLEMENTATION Named FOR User { METHOD name(value: User) RETURNS String -> RETURN "x"; END }
    CLEAR
    expect_error(<<~CLEAR, /Duplicate type parameter 'T' in generic conformance/i)
      PROTOCOL Pairing<K, V> { METHOD pair(self: Self, key: K) RETURNS V; }
      STRUCT Pair<T, U> { left: T right: U }
      IMPLEMENTATION<T, T> Pairing<T, T> FOR Pair<T, T> {
        METHOD pair(self, key: T) RETURNS T -> RETURN key; END
      }
    CLEAR
    expect_error(<<~CLEAR, /shadows built-in type/i)
      PROTOCOL Named { METHOD name(self: Self) RETURNS String; }
      STRUCT Holder<T> { value: T }
      IMPLEMENTATION<String> Named FOR Holder<String> {
        METHOD name(self) RETURNS String -> RETURN "x"; END
      }
    CLEAR
    expect_error(<<~CLEAR, /Unknown generic protocol Missing/i)
      PROTOCOL Named { METHOD name(self: Self) RETURNS String; }
      STRUCT Holder<T> { value: T }
      IMPLEMENTATION<T: Missing> Named FOR Holder<T> {
        METHOD name(self) RETURNS String -> RETURN "x"; END
      }
    CLEAR
    expect_error(<<~CLEAR, /Member 'name'.*redeclares owner parameter 'T'/i)
      PROTOCOL Named { METHOD name(self: Self) RETURNS String; }
      STRUCT Holder<T> { value: T }
      IMPLEMENTATION<T> Named FOR Holder<T> {
        METHOD name<T>(self) RETURNS String -> RETURN "x"; END
      }
    CLEAR
    expect_error(<<~CLEAR, /Type parameter 'User' shadows a visible nominal type/i)
      PROTOCOL Named { METHOD name(self: Self) RETURNS String; }
      STRUCT User { id: Int64 }
      STRUCT Holder<T> { value: T }
      IMPLEMENTATION<User> Named FOR Holder<User> {
        METHOD name(self) RETURNS String -> RETURN "x"; END
      }
    CLEAR
  end

  it "registers every conformance diagnostic in the generics tooling bucket" do
    expect(DiagnosticBuckets.covered_codes).to include(
      :CONFORMANCE_UNKNOWN_PROTOCOL,
      :CONFORMANCE_UNKNOWN_OWNER,
      :CONFORMANCE_ORPHAN,
      :CONFORMANCE_DUPLICATE,
      :CONFORMANCE_PROTOCOL_ARITY,
      :CONFORMANCE_OWNER_ARITY,
      :CONFORMANCE_REQUIREMENTS,
    )
  end
end
