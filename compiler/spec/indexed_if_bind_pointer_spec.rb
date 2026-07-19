require "rspec"

require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "indexed IF-bind pointer lowering" do
  def transpile(source)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd)
  end

  let(:union_definition) do
    <<~CLEAR
      UNION Value {
        Nil,
        IntVal: Int64,
        Str: String
      }
    CLEAR
  end

  it "borrows a plain map union slot with getPtr before matching it" do
    zig = transpile(<<~CLEAR)
      #{union_definition}

      FN main() RETURNS Int64 ->
        MUTABLE values: {String}Value = {};
        values["answer"] = Value{ IntVal: 42_i64 };
        IF values["answer"] EXISTS AS value THEN
          RETURN PARTIAL MATCH value START
            Value.IntVal AS number -> number,
            DEFAULT -> -1_i64
          END;
        END
        RETURN -2_i64;
      END
    CLEAR

    expect(zig).to include('values.getPtr("answer")')
    expect(zig).to include("switch (value.*)")
    expect(zig).not_to include('values.get("answer")')
  end

  it "borrows a list union slot with getAtPtrOpt before matching it" do
    zig = transpile(<<~CLEAR)
      #{union_definition}

      FN main() RETURNS Int64 ->
        MUTABLE values: []Value = [];
        &values.append(Value{ IntVal: 42_i64 });
        IF values[0_i64] EXISTS AS value THEN
          RETURN PARTIAL MATCH value START
            Value.IntVal AS number -> number,
            DEFAULT -> -1_i64
          END;
        END
        RETURN -2_i64;
      END
    CLEAR

    expect(zig).to include("CheatLib.getAtPtrOpt(&values, 0)")
    expect(zig).to include("switch (value.*)")
    expect(zig).not_to include("CheatLib.getAtOpt(values, 0)")
  end
end
