require "rspec"

require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "AsyncResultShape" do
  it "boxes declared fallible payloads behind the Promise transport boundary" do
    affine = AsyncResultShape.promise(Type.new("!String"))
    shared = AsyncResultShape.promise(Type.new("!?Int64"), shared: true)

    expect(affine.boxes_fallible_payload?).to be(true)
    expect(affine.payload_zig_type).to eq("CheatLib.AsyncFallible([]const u8)")
    expect(affine.handle_zig_type).to eq("CheatLib.Promise(CheatLib.AsyncFallible([]const u8))")
    expect(shared.handle_zig_type).to eq("CheatLib.SharedPromise(CheatLib.AsyncFallible(?i64))")
    expect(AsyncResultShape.promise(Type.new(:String)).boxes_fallible_payload?).to be(false)
  end

  it "preserves the item tense envelope for physical promise lists" do
    promise_list = Type.new("~!String[]", collection: :list)
    item = AsyncResultShape.promise_list_item(promise_list).payload_type

    expect(item.error_union?).to be(true)
    expect(item.success_type.string?).to be(true)
    expect(promise_list.zig_type).to eq(
      "std.ArrayListUnmanaged(CheatLib.Promise(CheatLib.AsyncFallible([]const u8)))",
    )
  end

  it "rejects item extraction from non-linear type expressions" do
    expression = Type.new("~!String").shape.expression

    expect(TypeExpressionTree.linear_item_envelope(expression)).to be_nil
  end

  it "renders fallible parameters with an explicit Zig error set" do
    expect(Type.new("!PlannedValue").zig_type(is_param: true)).to eq("anyerror!PlannedValue")
    expect(Type.new("!~PlannedValue").zig_type(is_param: true)).to eq(
      "anyerror!CheatLib.Promise(PlannedValue)",
    )
  end

  it "keeps a future payload failure distinct through BG and NEXT lowering" do
    src = <<~CLEAR
      FN risky() RETURNS !String -> RETURN COPY "ok"; END
      FN main() RETURNS !Void ->
        pending: ~!String = BG { risky(); };
        retained:! = NEXT pending;
        ASSERT TRY retained == "ok";
        RETURN;
      END
    CLEAR

    out = ZigTranspiler.new.transpile(src)
    expect(out).to include("CheatLib.Promise(CheatLib.AsyncFallible([]const u8))")
    expect(out).to include("inner.result = .{ .value =")
    expect(out).to include(".next()).value")
  end

  it "retains a fallible Void payload instead of discarding its error union" do
    src = <<~CLEAR
      FN risky() RETURNS !Void -> RETURN; END
      FN main() RETURNS !Void ->
        pending:~ = BG { risky(); };
        TRY (NEXT pending);
        RETURN;
      END
    CLEAR

    out = ZigTranspiler.new.transpile(src)
    expect(out).to include("CheatLib.Promise(CheatLib.AsyncFallible(void))")
    expect(out).to include("inner.result = .{ .value = risky(")
    expect(out).to include(".next()).value")
  end

  it "lowers BG returning a list as Promise<List<T>>, not list-of-promises" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        xs: ~Int64[]@list = BG {
          MUTABLE out: []Int64 = [];
          &out.append(1_i64);
          out;
        };
        ys: []Int64 = NEXT xs;
        ASSERT ys[0_i64] == 1_i64, "promise of list";
        RETURN;
      END
    CLEAR

    out = ZigTranspiler.new.transpile(src)
    expect(out).to include("CheatLib.Promise(std.ArrayListUnmanaged(i64)).spawn")
    expect(out).to include("var ys = try xs.next()")
    expect(out).not_to include("for (xs.items)")
  end

  it "publishes a literal String as an owned promise result" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        promise:~ = BG { "hello"; };
        result = NEXT promise;
        ASSERT result == "hello";
      END
    CLEAR

    out = ZigTranspiler.new.transpile(src)
    expect(out).to include("CheatLib.Promise([]const u8)")
    expect(out).to include("const result: []const u8 = try promise.next()")
    expect(out).to include("CheatLib.free")
  end
end
