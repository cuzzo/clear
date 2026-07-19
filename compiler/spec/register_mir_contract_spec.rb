require "rspec"
require_relative "../../examples/minivm/vm_golden_harness"

RSpec.describe "register MIR ownership contracts" do
  def compile_register(source)
    MiniVM::Golden.register.compile(source, source_dir: Dir.pwd)
  end

  def lower(source)
    importer = ModuleImporter.new(base_dir: Dir.pwd)
    result = CompilerFrontend.compile(source, importer: importer, source_dir: Dir.pwd)
    MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      lifecycle_registry: result.lifecycle_registry,
      fn_sigs: result.fn_sigs,
      moved_guard_info: result.moved_guard_info,
      importer: importer,
      source_dir: Dir.pwd,
      target: :bc,
    )).lower_program(result.ast)
  end

  it "accepts cleanup for owned collection results returned by BC intrinsics" do
    expect {
      compile_register(<<~CLEAR)
        FN main() RETURNS Void ->
          words = "apple banana".split(" ");
          MUTABLE scores = {"apple": 1_i64};
          keys = scores.keys();
          values = scores.values();
          ASSERT words.length() == 2, "split";
          ASSERT keys.length() == 1, "keys";
          ASSERT values.length() == 1, "values";
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "distinguishes owned collection results from frame-arena strings" do
    split_sig = T.must(IntrinsicRegistry.lookup(STD_LIB, "split"))
    to_string_sig = IntrinsicRegistry.overloads(STD_LIB, "toString").first

    split_effect = MIR::InlineBc.new(:split, [], split_sig).ownership_effect
    string_effect = MIR::InlineBc.new(:toString, [], to_string_sig).ownership_effect

    expect(split_effect.produces_owned).to be(true)
    expect(string_effect.produces_owned).to be(false)
  end

  it "searches typed WITH bodies containing lexer tokens for return flow" do
    expect {
      compile_register(<<~CLEAR)
        STRUCT Counter { value: Int64 }

        FN valueOf(MUTABLE counter: Counter) RETURNS !Int64 ->
          WITH POLYMORPHIC counter AS inner {
            value = inner.value;
            RETURN value;
          }
        END

        FN main() RETURNS !Void ->
          MUTABLE counter = Counter{ value: 7_i64 };
          value = valueOf(&counter) OR_ELSE RAISE;
          ASSERT value == 7_i64, "value";
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "lowers cleanup-bearing fallible captures through their success type" do
    expect {
      lower(<<~CLEAR)
        FN makeLabel() RETURNS !String ->
          RETURN "ready";
        END

        FN main() RETURNS Void ->
          IF makeLabel() IS_OK AS label THEN
            ASSERT label == "ready", "label";
          END
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "treats receiver-state tokens as scalar leaves during return search" do
    token = Lexer.new("value").tokenize.first
    expect(MIRLowering.new.send(:ast_contains_return?, token)).to be(false)
  end
end
