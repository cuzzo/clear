require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# Step 2 of the alloc-as-FAULT plan (puck-clear-bugs.md #3/#12):
# compute_can_fail! also computes fn.alloc_fault -- "this fn allocates
# (direct, or via a callee whose fault channel is NOT locally
# terminated)". A FAULT, not an ERROR: it never forces RETURNS !T
# (step 4), but it does ride the Zig !T path (step 3). This spec pins
# the computation + the #11 channel-termination authority for faults.
RSpec.describe "alloc_fault (allocation FAULT axis)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def fn(ast, name)
    ast.statements.find { |s| s.respond_to?(:name) && s.name == name }
  end

  it "is false for a pure non-allocating function" do
    ast = annotate(<<~CLEAR)
      FN addOne(x: Int64) RETURNS Int64 ->
        RETURN x + 1_i64;
      END
    CLEAR
    expect(fn(ast, "addOne").alloc_fault).to eq(false)
  end

  it "is true for a function that allocates (list append)" do
    ast = annotate(<<~CLEAR)
      FN build() RETURNS []Int64 ->
        MUTABLE xs: []Int64 = [];
        &xs.append(7_i64);
        RETURN xs;
      END
    CLEAR
    expect(fn(ast, "build").alloc_fault).to eq(true)
  end

  it "is true for an explicit deep COPY" do
    ast = annotate(<<~CLEAR)
      FN duplicate(value: String) RETURNS String ->
        RETURN COPY value;
      END
    CLEAR
    expect(fn(ast, "duplicate").alloc_fault).to eq(true)
    expect(fn(ast, "duplicate").error_fallible).to eq(false)
  end

  it "propagates transitively through a bare (non-absorbed) call" do
    ast = annotate(<<~CLEAR)
      FN build() RETURNS []Int64 ->
        MUTABLE xs: []Int64 = [];
        &xs.append(7_i64);
        RETURN xs;
      END
      FN viaBare() RETURNS Int64 ->
        ys = build();
        RETURN length(ys);
      END
    CLEAR
    expect(fn(ast, "viaBare").alloc_fault).to eq(true)
  end

  it "does NOT propagate when the alloc callee's fault channel is OR_ELSE-absorbed (#11 authority)" do
    ast = annotate(<<~CLEAR)
      FN build() RETURNS []Int64 ->
        MUTABLE xs: []Int64 = [];
        &xs.append(7_i64);
        RETURN xs;
      END
      FN viaAbsorbed(flag: Bool) RETURNS Int64 ->
        zs = build() OR_ELSE PASS;
        IF flag THEN RETURN 1_i64; END
        RETURN 0_i64;
      END
    CLEAR
    # viaAbsorbed itself does not allocate; the only allocating callee
    # is reached via `build() OR_ELSE PASS`, so the fault channel terminates
    # there and must not propagate.
    expect(fn(ast, "viaAbsorbed").alloc_fault).to eq(false)
  end
end
