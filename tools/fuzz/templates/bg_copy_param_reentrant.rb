# COPY of an @list parameter captured into a BG whose body calls a
# REENTRANT fn. All cells positive (must compile and run).

BG_COPY_PARAM_REENTRANT_CELLS = []

CALLEES = [:reentrant].freeze

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
