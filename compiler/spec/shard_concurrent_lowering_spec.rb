require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "SHARD + CONCURRENT EACH lowering" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def last_concurrent_op(src)
    annotate(src).statements.first.body.last.right
  end

  it "lowers SHARD + CONCURRENT EACH as verifier-visible structural MIR" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
          MUTABLE counts: HashMap<Int64, Int64>@sharded(4) = {};
          (0..<16_i64) |> SHARD(_ MOD 4_i64, counts) |> CONCURRENT EACH {
              counts[_] = (counts[_] OR_ELSE 0_i64) + 1_i64;
          };
      END
    CLEAR

    zig = ZigTranspiler.new.transpile(src)

    expect(zig).to include("CheatLib.BoundedChannel(__ShWork")
    expect(zig).to include("__ShWorker")
    expect(zig).to include("try CheatHeader.spawnBest")
    expect(zig).to include("putDirect(ctx.shard")
    expect(zig).to include("getDirect(ctx.shard")
    expect(zig).not_to include("try counts.put(")
  end

  it "auto-detects a single @sharded map in list-backed CONCURRENT EACH" do
    conc = last_concurrent_op(<<~CLEAR)
      FN main() RETURNS Void ->
          MUTABLE items: Int64[]@list = [];
          items.append(1_i64);
          MUTABLE counts: HashMap<Int64, Int64>@sharded(4) = {};
          items |> CONCURRENT EACH {
              counts[_] = (counts[_] OR_ELSE 0_i64) + 1_i64;
          };
      END
    CLEAR

    expect(conc.shard_context.map_var.name).to eq("counts")
    expect(conc.shard_context.shard_count).to eq(4)
    expect(conc.shard_context.auto_detected).to be true
  end

  it "keeps normal concurrent each when multiple @sharded maps are used" do
    conc = nil
    expect {
      conc = last_concurrent_op(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE items: Int64[]@list = [];
            items.append(1_i64);
            MUTABLE a: HashMap<Int64, Int64>@sharded(4) = {};
            MUTABLE b: HashMap<Int64, Int64>@sharded(4) = {};
            items |> CONCURRENT EACH {
                a[_] = (a[_] OR_ELSE 0_i64) + 1_i64;
                b[_] = (b[_] OR_ELSE 0_i64) + 1_i64;
            };
        END
      CLEAR
    }.to output(/CONCURRENT EACH accesses 2 @sharded maps/).to_stderr

    expect(conc.shard_context).to be_nil
  end

  it "keeps normal concurrent each when the @sharded map is only inspected" do
    conc = last_concurrent_op(<<~CLEAR)
      FN main() RETURNS Void ->
          MUTABLE items: Int64[]@list = [];
          items.append(1_i64);
          MUTABLE counts: HashMap<Int64, Int64>@sharded(4) = {};
          items |> CONCURRENT EACH {
              count = counts.count();
          };
      END
    CLEAR

    expect(conc.shard_context).to be_nil
  end

  it "notes same-map auto-sharding with different key expressions" do
    conc = nil
    expect {
      conc = last_concurrent_op(<<~CLEAR)
        FN main() RETURNS Void ->
            MUTABLE items: Int64[]@list = [];
            items.append(1_i64);
            MUTABLE counts: HashMap<Int64, Int64>@sharded(4) = {};
            items |> CONCURRENT EACH {
                counts[_] = (counts[_] OR_ELSE 0_i64) + 1_i64;
                counts[_ + 1_i64] = (counts[_ + 1_i64] OR_ELSE 0_i64) + 1_i64;
            };
        END
      CLEAR
    }.to output(/different key expressions/).to_stderr

    expect(conc.shard_context.map_var.name).to eq("counts")
  end
end
