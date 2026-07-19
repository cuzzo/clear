require "rspec"

require_relative "../ruby/semantic/lifecycle_plan"
require_relative "../ruby/backends/transpiler"

RSpec.describe Semantic::LifecyclePlan do
  let(:no_schema) { ->(_name) { nil } }

  it "keeps lifecycle identity stable across stack, frame, and heap placement" do
    stack = Type.new(:String)
    frame = Type.new(:String, location: :frame)
    heap = Type.new(:String, location: :heap)

    expect([stack, frame, heap].map(&:lifecycle_type_key).uniq.length).to eq(1)
    expect(stack.semantic_type_key).not_to eq(heap.semantic_type_key)
  end

  it "pairs drop and copy behavior for owned, borrowed, static, RC, and generic values" do
    owned = Semantic::LifecyclePlanner.plan(Type.new(:String), no_schema)
    borrowed = Semantic::LifecyclePlanner.plan(Type.new(:String, location: :borrow), no_schema)
    symbol = Semantic::LifecyclePlanner.plan(Type.new("String@symbol"), no_schema)
    shared = Semantic::LifecyclePlanner.plan(Type.new(:Box, ownership: :shared), no_schema)
    generic = Semantic::LifecyclePlanner.plan(Type.new(:T), no_schema)

    expect([owned.drop_strategy, owned.copy_strategy]).to eq([:semantic, :deep_clone])
    expect([borrowed.drop_strategy, borrowed.copy_strategy]).to eq([:none, :deep_clone])
    expect([symbol.drop_strategy, symbol.copy_strategy]).to eq([:none, :bit_copy])
    expect([shared.drop_strategy, shared.copy_strategy]).to eq([:release, :retain])
    expect([generic.drop_strategy, generic.copy_strategy]).to eq([:generic, :generic])
  end

  it "treats a foreign pointer view as a non-owning bit-copy handle" do
    foreign_view = Semantic::LifecyclePlanner.plan(Type.new("[]@c Int64"), no_schema)

    expect([foreign_view.drop_strategy, foreign_view.copy_strategy]).to eq([:none, :bit_copy])
  end

  it "does not treat a fully concrete StreamStep specialization as an unresolved generic" do
    step = Semantic::LifecyclePlanner.plan(Type.new("StreamStep<?Int64>"), no_schema)
    projection = Semantic::LifecyclePlanner.plan(Type.new("M::Value"), no_schema)

    expect([step.drop_strategy, step.copy_strategy]).to eq([:none, :bit_copy])
    expect([projection.drop_strategy, projection.copy_strategy]).to eq([:generic, :generic])
  end

  it "lets ownership wrappers govern closeable payloads without losing exact final cleanup" do
    resource = Schemas::ResourceSchema.new(close_plan: Schemas::ResourceClosePlan.method("close"))
    schema = ->(name) { name.to_sym == :Probe ? resource : nil }

    direct = Semantic::LifecyclePlanner.plan(Type.new(:Probe), schema)
    shared = Semantic::LifecyclePlanner.plan(Type.new(:Probe, ownership: :shared), schema)
    multiowned = Semantic::LifecyclePlanner.plan(Type.new(:Probe, ownership: :multiowned), schema)
    split_stream = Semantic::LifecyclePlanner.plan(Type.new("~?Int64[] @split"), no_schema)

    expect([direct.drop_strategy, direct.copy_strategy]).to eq([:resource_close, :forbidden])
    expect([shared.drop_strategy, shared.copy_strategy]).to eq([:release, :retain])
    expect([multiowned.drop_strategy, multiowned.copy_strategy]).to eq([:release, :retain])
    expect([split_stream.drop_strategy, split_stream.copy_strategy]).to eq([:semantic, :retain])
  end

  it "separates a static literal expression from the mutable binding that comes to own replacements" do
    token = Lexer::Token.new(:VAR_ID, "content", 1, 1)
    literal_type = Type.new("Byte[0]", location: :rodata)
    binding = AST::VarDecl.new(token, "content", literal_type, nil, true)
    binding.var_mutated = true

    expression = Semantic::LifecyclePlanner.plan(literal_type, no_schema)
    slot = Semantic::LifecyclePlanner.plan_binding(literal_type, binding, no_schema)

    expect([expression.drop_strategy, expression.copy_strategy]).to eq([:none, :deep_clone])
    expect([slot.drop_strategy, slot.copy_strategy]).to eq([:semantic, :deep_clone])
  end

  it "keeps a reassigned optional interned-symbol slot bit-copy and no-drop" do
    token = Lexer::Token.new(:VAR_ID, "suffix_ownership", 1, 1)
    symbol_type = Type.new("?String@symbol")
    binding = AST::VarDecl.new(token, "suffix_ownership", symbol_type, nil, true)
    binding.var_mutated = true

    expression = Semantic::LifecyclePlanner.plan(symbol_type, no_schema)
    slot = Semantic::LifecyclePlanner.plan_binding(symbol_type, binding, no_schema)

    expect([expression.drop_strategy, expression.copy_strategy]).to eq([:none, :bit_copy])
    expect([slot.drop_strategy, slot.copy_strategy]).to eq([:none, :bit_copy])
  end

  it "fails closed when MIR asks for a type annotation did not inventory" do
    registry = Semantic::LifecycleRegistry.empty
    expect { registry.fetch(Type.new(:String)) }
      .to raise_error(RuntimeError, /missing annotation lifecycle plan/)
  end

  it "inventories intermediate optional payloads inside fallible returns before MIR cleanup" do
    source = <<~CLEAR
      STRUCT Descriptor {
        kind: String@symbol,
        text: String,
        before: ?String,
        after: ?String
      }

      FN descriptor(flag: Bool) RETURNS !?Descriptor ->
        IF flag THEN
          RETURN Descriptor{ kind: :item, text: COPY "value", before: NIL, after: NIL };
        END
        RETURN NIL;
      END

      FN consume() RETURNS !Void ->
        value: Descriptor = TRY UNWRAP descriptor(TRUE);
        print(value.text);
        RETURN;
      END

      FN main() RETURNS Void ->
        RETURN;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.not_to raise_error
  end

  it "inventories typed map keys as well as values before MIR lowering" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        MUTABLE scores: {String}Int64 = {"apple": 1};
        scores["pear"] = 2;
        ASSERT UNWRAP scores["apple"] == 1;
        RETURN;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.not_to raise_error
  end

  it "transfers an owned OR_ELSE fallback only inside the selected branch" do
    source = <<~CLEAR
      FN makeList() RETURNS []@sharded(2) Int64 ->
        MUTABLE values: []@sharded(2) Int64 = [];
        &values.append(4);
        RETURN values;
      END

      FN maybeList(flag: Bool) RETURNS ![]@sharded(2) Int64 ->
        IF flag THEN RETURN makeList(); END
        RAISE "missing";
      END

      FN choose() RETURNS []@sharded(2) Int64 ->
        MUTABLE fallback: []@sharded(2) Int64 = [];
        &fallback.append(4);
        RETURN maybeList(FALSE) OR_ELSE fallback;
      END

      FN main() RETURNS Void ->
        values = choose();
        ASSERT values.length() == 1;
      END
    CLEAR

    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to include("var fallback_moved = false;")
    expect(zig).to include("catch __owned_branch_")
    expect(zig).to match(/fallback_moved = true;\n\s*break :__owned_branch_transfer_\d+ fallback;/)
  end


  it "does not synthesize reassignment cleanup for optional interned symbols" do
    source = <<~CLEAR
      STRUCT Suffix { ownership: ?String@symbol }

      FN normalize(suffix: Suffix) RETURNS String@symbol ->
        MUTABLE ownership: ?String@symbol = COPY suffix.ownership;
        FOR capability IN ["shared", "affine"] DO
          IF capability == "shared" THEN
            ownership = :shared;
          ELSE
            ownership = :affine;
          END
        END
        RETURN UNWRAP ownership;
      END

      FN main() RETURNS Void ->
        ASSERT normalize(Suffix{ ownership: NIL }) == :affine;
        RETURN;
      END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.not_to raise_error
  end

  it "keeps explicit COPY into an optional interned-symbol field non-owning" do
    source = <<~CLEAR
      STRUCT Suffix { ownership: ?String@symbol }

      FN assign(MUTABLE suffix: Suffix, ownership: ?String@symbol) RETURNS Void ->
        suffix.ownership = COPY ownership;
        RETURN;
      END

      FN main() RETURNS Void -> RETURN; END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.not_to raise_error
  end

  it "tracks ownership acquired by a mutable optional initialized to NIL" do
    source = <<~CLEAR
      STRUCT Token { text: String }

      FN choose(flag: Bool, token: ?Token) RETURNS ?Token ->
        MUTABLE branch_value: ?Token = NIL;
        IF flag THEN
          branch_value = COPY token;
        ELSE
          branch_value = NIL;
        END
        result: ?Token = branch_value;
        RETURN result;
      END

      FN main() RETURNS Void -> RETURN; END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.not_to raise_error
  end

  it "does not transfer inferred optional symbol bindings into typed branch slots" do
    source = <<~CLEAR
      FN source_symbol() RETURNS ?String@symbol -> RETURN :shared; END

      FN choose_symbol(flag: Bool) RETURNS ?String@symbol ->
        inferred:? = source_symbol();
        MUTABLE branch_value: ?String@symbol = NIL;
        IF flag THEN
          branch_value = inferred;
        ELSE
          branch_value = NIL;
        END
        RETURN branch_value;
      END

      FN main() RETURNS Void -> RETURN; END
    CLEAR

    expect { ZigTranspiler.new.transpile(source) }.not_to raise_error
  end
end
