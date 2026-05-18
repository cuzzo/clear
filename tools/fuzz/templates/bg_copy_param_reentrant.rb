# Template: COPY of an @list PARAMETER captured into a BG whose body
# calls a REENTRANT fn (the COPY flows through the reentrant call's
# ctx deep-copy).
#
# Sibling of bg_capture_typing.rb: that one covers COPY-@list-param-
# into-BG where the BG body calls a NON-reentrant callee and the
# param is consumed directly. This one adds the missing axis the
# register-VM R3 BGSPAWN arm exercises -- the BG body recursively
# calls a `EFFECTS REENTRANT:MAX_DEPTH` fn passing `COPY <@list
# param>`. That path hit a distinct compiler bug: the COPY-into-BG
# deep-copy lowering hard-codes the ArrayList `.items` shape instead
# of the comptime `@hasField(@TypeOf(x),"items")` resilient access
# every other @list read uses, so a slice-represented @list param
# yields Zig `no member named 'items' in '[]i64'`.
#
# See docs/agents/vm-bugs.md "COPY of an @list PARAM into a BG ...
# unguarded .items" (57f23367) and
# transpile-tests/known-failing/bgcopy_list_param_reentrant_items.cht.
#
# SCOPED OUT until that bug is fixed (mirrors bg_capture_typing's
# :int-only / Bug #8 precedent): CALLEES is [] so no cells are
# generated and the stable matrix stays green. When the standalone
# fix lands, set `CALLEES = [:reentrant]` -- the generator below is
# ready and the cells become the regression lock (positive: must
# compile AND run).

BG_COPY_PARAM_REENTRANT_CELLS = []

# Re-enable: CALLEES = [:reentrant]  (when 57f23367 is fixed)
CALLEES = [].freeze

CALLEES.each do |callee|
  [:int].each do |elem|
    [3, 6].each do |depth|
      BG_COPY_PARAM_REENTRANT_CELLS << { callee: callee, elem: elem, depth: depth }
    end
  end
end

FuzzGenerator.register(:bg_copy_param_reentrant, cells: BG_COPY_PARAM_REENTRANT_CELLS) do |p|
  zig  = (p[:elem] == :int) ? "Int64" : "String"
  lt   = "#{zig}[]@list"
  push = (p[:elem] == :int) ? "1_i64" : '"a"'
  n    = p[:depth]

  <<~CHT
    FN consume(xs: #{lt}) RETURNS Int64 -> RETURN xs.length(); END

    FN worker!(sl: #{lt}, depth: Int64) RETURNS !Int64 EFFECTS REENTRANT:MAX_DEPTH(8) ->
        IF depth <= 0_i64 THEN RETURN consume(sl); END
        f: ~Int64 = BG { @service ->
            worker!(COPY sl, depth - 1_i64) OR RAISE;
        };
        RETURN NEXT f;
    END

    FN main() RETURNS !Void ->
        MUTABLE xs: #{lt} = List[];
        xs.append(#{push});
        n: Int64 = worker!(GIVE xs, #{n}_i64) OR RAISE;
        ASSERT n == 1_i64, "COPY @list param through reentrant BG";
        RETURN;
    END
  CHT
end
