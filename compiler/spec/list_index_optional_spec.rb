require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "optional @list indexing" do
  UNSAFE_SOURCE = <<~CLEAR
    STRUCT Item { name: Int64 }
    FN main() RETURNS Void ->
      MUTABLE items: Item[]@list = [];
      items.append(Item{ name: 7 });
      value = items[0].name;
      ASSERT value == 7;
    END
  CLEAR

  SAFE_SOURCE = UNSAFE_SOURCE.sub("items[0].name", "items[0]?.name")

  CHAIN_SOURCE = <<~CLEAR
    STRUCT Profile { name: Int64 }
    STRUCT Item { profile: Profile }
    FN main() RETURNS Void ->
      MUTABLE items: Item[]@list = [];
      items.append(Item{ profile: Profile{ name: 7 } });
      value = items[0]?.profile.name;
      ASSERT value == 7;
    END
  CLEAR

  def parse(source)
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  end

  def annotate(source)
    ast = parse(source)
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    ast
  end

  it "types an indexed list read as an optional element" do
    ast = annotate(SAFE_SOURCE)
    value_decl = ast.statements.fetch(1).body.fetch(2)
    index = value_decl.value.target.target

    expect(index).to be_a(AST::GetIndex)
    expect(index.full_type!.optional?).to be(true)
    expect(index.full_type!.wrapped_type&.resolved).to eq(:Item)
    expect(value_decl.value.full_type!.optional?).to be(true)
  end

  it "rejects plain field chaining and offers an automatic ?. edit" do
    FixCollector.enable!
    begin
      annotate(UNSAFE_SOURCE) rescue CompilerError
      finding = FixCollector.drain.find { |item| item.message.include?("without safe navigation") }

      expect(finding).not_to be_nil
      fix = finding.fixes.fetch(0)
      edit = fix.edits.fetch(0)
      expect(fix.confidence).to eq(:auto)
      expect(edit.replacement).to eq("?")
      expect(edit.span.line).to eq(5)
      expect(edit.span.col).to eq(19)
      expect(edit.span.length).to eq(0)
    ensure
      FixCollector.disable!
    end
  end

  it "lowers a safe list read to the bounds-safe optional runtime accessor" do
    zig = ZigTranspiler.new(source_dir: Dir.pwd).transpile(SAFE_SOURCE, source_dir: Dir.pwd)

    expect(zig).to include("CheatLib.getAtOpt(items, 0)")
    expect(zig).to include("if (CheatLib.getAtOpt(items, 0)) |_r|")
  end

  it "lets one ?. guard a continuous chain of non-optional members" do
    expect { annotate(CHAIN_SOURCE) }.not_to raise_error
    zig = ZigTranspiler.new(source_dir: Dir.pwd).transpile(CHAIN_SOURCE, source_dir: Dir.pwd)

    expect(zig).to include("CheatLib.getAtOpt(items, 0)")
    expect(zig).to include("_r.profile")
    expect(zig).to include("_r.name")
  end

  it "conditionally mutates an indexed element through ?. without evaluating a missing RHS" do
    source = <<~CLEAR
      STRUCT Item { name: Int64 }
      FN main() RETURNS Void ->
        MUTABLE items: Item[]@list = [];
        items.append(Item{ name: 1_i64 });
        items[0]?.name = 7_i64;
        items[9]?.name = 99_i64;
        ASSERT (items[0]?.name OR_ELSE 0_i64) == 7_i64;
      END
    CLEAR

    zig = ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd)
    expect(zig).to include("CheatLib.getAtPtrOpt(&items, 0)")
    expect(zig).to include("CheatLib.getAtPtrOpt(&items, 9)")
    expect(zig).to match(/if \(CheatLib\.getAtPtrOpt\(&items, 0\)\) \|__conditional_mut_\d+\|/)
  end

  it "conditionally mutates an optional struct field in place" do
    source = <<~CLEAR
      STRUCT Child { value: Int64 }
      STRUCT Parent { child: ?Child }
      FN main() RETURNS Void ->
        MUTABLE parent = Parent{ child: Child{ value: 1_i64 } };
        parent.child?.value = 8_i64;
        ASSERT (parent.child?.value OR_ELSE 0_i64) == 8_i64;
      END
    CLEAR

    zig = ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd)
    expect(zig).to include("CheatLib.getOptionalPtr(&parent.child)")
  end

  it "keeps the single safe boundary through an intrinsic method call" do
    source = <<~CLEAR
      STRUCT Item { name: String }
      FN main() RETURNS Void ->
        MUTABLE items: Item[]@list = [];
        items.append(Item{ name: COPY "abc" });
        size = items[0]?.name.length() OR_ELSE 0_i64;
        ASSERT size == 3_i64;
      END
    CLEAR

    zig = ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd)
    expect(zig).to include("@as(?[]const u8, _r.name)")
    expect(zig).to include("@as(?i64,")
  end

  it "requires another ?. when a member introduces a new optional boundary" do
    source = CHAIN_SOURCE
      .sub("profile: Profile", "profile: ?Profile")
      .sub("items[0]?.profile.name", "items[0]?.profile.name")

    expect { annotate(source) }
      .to raise_error(CompilerError, /field 'name'.*without safe navigation/i)
    expect { annotate(source.sub("profile.name", "profile?.name")) }.not_to raise_error
  end

  it "preserves @node on the element nested inside the optional" do
    type = Type.new(:"Node[]@list")
    type.elem_ownership = :node
    result = FunctionReturn.variant(:OptionalOfElement).resolve(type, [], nil)

    expect(result.optional?).to be(true)
    expect(result.wrapped_type&.node?).to be(true)
    expect(result.zig_type).to eq("CheatLib.NodeRef(Node)")
  end
end
