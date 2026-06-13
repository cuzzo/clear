require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)

# Coverage for emit_flow_stmt and flow_body_terminates? branches in
# mir_emitter.rb. These fire only when a polymorphic-mutate WITH body
# contains structured control flow (IF/ELSE, nested scopes) — the
# emitter rewrites RETURNs inside that body to flow-state assignments,
# so each statement-shape needs its own emit branch.
RSpec.describe "polymorphic-flow body shape emission" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  it "emits an IF/ELSE inside the flow body, threading return_kind into both arms" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN bumpOrZero!(MUTABLE c: Counter) RETURNS !Int64 ->
        WITH POLYMORPHIC c AS x {
          IF x.value > 0 THEN
            n = x.value + 1;
            x.value = n;
            RETURN n;
          ELSE
            RETURN 0;
          END
        }
      END
    CLEAR

    # Both arms of the IF must rewrite RETURN to a flow-state set
    # (`__flow.* = .{ .kind = .ret_commit, .ret = ... }`); the
    # emitter wraps each arm in `if (...) { ... } else { ... }`.
    expect(zig).to include(".kind = .ret_commit")
    expect(zig).to include(".ret = 0")
    expect(zig).to match(/if \(.*\) \{.*else \{/m)
  end

  it "emits an IF without ELSE inside the flow body" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN earlyExit!(MUTABLE c: Counter) RETURNS !Int64 ->
        WITH POLYMORPHIC c AS x {
          IF x.value > 0 THEN
            RETURN 7;
          END
          RETURN 0;
        }
      END
    CLEAR

    # Single-arm IF emits without an `else { ... }` block — the
    # post-IF RETURN handles the fall-through case.
    expect(zig).to include("if ((x.value > 0))")
    expect(zig).to include(".ret = 7")
    expect(zig).to include(".ret = 0")
  end

  it "emits a nested ScopeBlock (e.g. WITH RESTRICT) inside the flow body" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN bumpRestricted!(MUTABLE c: Counter) RETURNS !Int64 ->
        WITH POLYMORPHIC c AS x {
          MUTABLE local = x.value;
          WITH RESTRICT local {
            local = local + 1;
          }
          x.value = local;
          RETURN local;
        }
      END
    CLEAR

    # WITH RESTRICT lowers to a MIR::ScopeBlock. The flow-body
    # emitter must recurse into it via emit_body_flow so the inner
    # statements respect the polymorphic flow context.
    expect(zig).to include("polymorphicMutateFlow")
    expect(zig).to include(".ret = local")
  end

  it "ON GuardFail PASS produces a non-terminating fail-body, requiring the fallthrough emit" do
    # PASS lowers to an empty fail body. flow_body_terminates? returns
    # false on empty arrays, which forces emit_polymorphic_mutate_flow
    # to append the explicit skip_no_commit assignment (mir_emitter:308).
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN check?(c: Counter) RETURNS !Bool ->
        WITH POLYMORPHIC c AS x GUARD x.value > 0 {
          RETURN TRUE;
        } ON GuardFail PASS
        RETURN FALSE;
      END
    CLEAR

    expect(zig).to include(".kind = .skip_no_commit")
  end
end
