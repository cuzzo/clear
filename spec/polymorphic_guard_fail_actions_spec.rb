require "rspec"
require_relative "../src/backends/transpiler"

# Coverage for guard_fail_flow_body action branches (mir_lowering.rb
# 2992-3006). The existing transpile-tests fixture exercises the
# RETURN-action variant; this spec covers the other four — PASS,
# RAISE, EXIT-with-message, and a { ... } block — on a polymorphic
# mutate flow (the WITH-EXCLUSIVE lock path uses a separate
# guard_fail_body and doesn't hit these lines).

RSpec.describe "polymorphic-flow ON GuardFail action variants" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  it "lowers ON GuardFail PASS as an empty fail-body (silent skip-no-commit)" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN check?(c: Counter) RETURNS !Bool ->
        WITH POLYMORPHIC c AS x GUARD x.value > 0 {
          RETURN TRUE;
        } ON GuardFail PASS
        RETURN FALSE;
      END
    CLEAR

    # PASS lowers to no body statements; the polymorphic flow falls
    # through to skip_no_commit. The wrapping fn must still compile.
    expect(zig).to include("polymorphicMutateFlow")
    expect(zig).to include(".kind = .skip_no_commit")
  end

  it "lowers ON GuardFail RAISE with the GuardFail error name" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN check?(c: Counter) RETURNS !Bool ->
        WITH POLYMORPHIC c AS x GUARD x.value > 0 {
          RETURN TRUE;
        } ON GuardFail RAISE
        RETURN FALSE;
      END
    CLEAR

    # The raise-action emits a setError into the runtime context with
    # the static "WITH GUARD predicate failed" message and flips the
    # flow kind to raise_no_commit.
    expect(zig).to include("ErrorName.GuardFail")
    expect(zig).to include("WITH GUARD predicate failed")
    expect(zig).to include(".kind = .raise_no_commit")
    expect(zig).not_to include(".kind = .ret_no_commit, .ret = {}")
  end

  it "lowers ON GuardFail EXIT with a custom message" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN check?(c: Counter) RETURNS !Bool ->
        WITH POLYMORPHIC c AS x GUARD x.value > 0 {
          RETURN TRUE;
        } ON GuardFail EXIT "custom guard fail"
        RETURN FALSE;
      END
    CLEAR

    # EXIT with an explicit message lowers the message expression
    # and threads it into setError; the message string must appear
    # in the emitted Zig.
    expect(zig).to include("ErrorName.GuardFail")
    expect(zig).to include("custom guard fail")
    expect(zig).to include(".kind = .raise_no_commit")
    expect(zig).not_to include(".kind = .ret_no_commit, .ret = {}")
  end

  it "lowers ON GuardFail -> { ... } block as the fail-body statements" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN check?(c: Counter) RETURNS Bool ->
        WITH POLYMORPHIC c AS x GUARD x.value > 0 {
          RETURN TRUE;
        } ON GuardFail -> {
          RETURN FALSE;
        }
      END
    CLEAR

    # The action-block lowers via lower_body; the inner RETURN runs
    # under the polymorphic flow context and is rewritten to a
    # ret_commit assignment + a bare return. Both markers must
    # appear in the fail-body region of the emitted Zig.
    expect(zig).to include("polymorphicMutateFlow")
    expect(zig).to include(".kind = .ret_commit")
    expect(zig).to include(".ret = false")
  end
end
