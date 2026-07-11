require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "RC ownership through optional collection bindings" do
  def annotate(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    ast
  end

  it "preserves map value ownership through indexed optional lookup" do
    source = <<~CLEAR
      STRUCT Item { value: Int64 }
      FN main() RETURNS Void ->
        MUTABLE items: HashMap<Item@multiowned> = {};
        items["x"] = Item{ value: 1_i64 } @multiowned;
        IF items["x"] AS item THEN ASSERT item.value == 1_i64; END
      END
    CLEAR

    fn = annotate(source).statements.last
    bind = fn.body.last
    lookup = bind.bindings.first.expr.full_type!

    expect(lookup.optional?).to be(true)
    expect(lookup.wrapped_type&.ownership).to eq(:multiowned)
    expect(bind.bindings.first.symbol.type.ownership).to eq(:multiowned)
  end

  it "preserves list element ownership through pop" do
    source = <<~CLEAR
      STRUCT Item { value: Int64 }
      FN main() RETURNS Void ->
        MUTABLE items: Item@shared[]@list = [];
        items.append(Item{ value: 1_i64 } @shared);
        WHILE items.pop() AS item DO ASSERT item.value == 1_i64; END
      END
    CLEAR

    fn = annotate(source).statements.last
    loop = fn.body.last
    result = loop.condition.full_type!

    expect(result.optional?).to be(true)
    expect(result.wrapped_type&.ownership).to eq(:shared)
  end

  it "preserves element ownership through a borrowed slice" do
    source = <<~CLEAR
      STRUCT Item { value: Int64 }
      FN main() RETURNS Void ->
        MUTABLE items: Item@multiowned[]@list = [];
        items.append(Item{ value: 1_i64 } @multiowned);
        window = items[0_i64..<1_i64];
        ASSERT window.length() == 1_i64;
      END
    CLEAR

    fn = annotate(source).statements.last
    window = fn.body.fetch(2)

    expect(window.symbol.type.element_type&.ownership).to eq(:multiowned)
    expect(window.symbol.borrowed_alias).to be(true)
  end

  it "returns an owned list with RC elements from map values" do
    source = <<~CLEAR
      STRUCT Item { value: Int64 }
      FN main() RETURNS Void ->
        MUTABLE items: HashMap<Item@multiowned> = {};
        items["x"] = Item{ value: 1_i64 } @multiowned;
        values = items.values();
        ASSERT values[0_i64]?.value == 1_i64;
      END
    CLEAR

    fn = annotate(source).statements.last
    values = fn.body.fetch(2)

    expect(values.symbol.type.list_collection?).to be(true)
    expect(values.symbol.type.element_type&.ownership).to eq(:multiowned)
  end

  it "keeps ownership in optional coercions and threads runtime allocation into helpers" do
    source = <<~CLEAR
      STRUCT Item { value: Int64 }
      FN make() RETURNS ?Item@multiowned ->
        RETURN Item{ value: 1_i64 } @multiowned;
      END
      FN main() RETURNS Void ->
        IF make() AS item THEN ASSERT item.value == 1_i64; END
      END
    CLEAR

    zig = ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd)

    expect(zig).to include("fn make(rt: *Runtime)")
    expect(zig).to include("@as(?CheatLib.Rc(Item)")
  end

  it "retains an optional RC payload inside COPY's capture scope" do
    source = <<~CLEAR
      STRUCT Item { value: Int64 }
      FN main() RETURNS Void ->
        MUTABLE source: ?Item@multiowned = Item{ value: 1_i64 } @multiowned;
        IF COPY source AS item THEN ASSERT item.value == 1_i64; END
        IF source AS item THEN ASSERT item.value == 1_i64; END
      END
    CLEAR

    zig = ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd)

    expect(zig).to match(/if \(source\) \|__copy_rc_\d+\| @as\(\?CheatLib\.Rc\(Item\), CheatLib\.rcRetain/)
    expect(zig).not_to match(/rcRetain\(Item, __copy_rc_\d+\);\n.*if \(source\)/m)
  end

  it "retains an optional RC payload inside CLONE's capture scope" do
    source = <<~CLEAR
      STRUCT Item { value: Int64 }
      FN main() RETURNS Void ->
        source: ?Item@shared = Item{ value: 1_i64 } @shared;
        IF CLONE source AS item THEN ASSERT item.value == 1_i64; END
        IF source AS item THEN ASSERT item.value == 1_i64; END
      END
    CLEAR

    zig = ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd)

    expect(zig).to match(/if \(source\) \|__clone_rc_\d+\| @as\(\?CheatLib\.Arc\(Item\), CheatLib\.arcRetain/)
  end
end
