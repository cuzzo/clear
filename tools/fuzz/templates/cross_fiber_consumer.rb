# Template: cross-fiber NEXT consumer escape promotion.
#
# The producer (BG STREAM / observable accumulator) heap-allocates its
# yielded values because they cross a fiber boundary. The consumer
# binding's storage MUST be heap so cleanup uses the right allocator.
#
# Known compiler bug this template surfaces:
#   When the consumer binding has explicit frame-collection sigil (or
#   defaults to frame), EscapeGraph doesn't promote it to heap despite
#   the cross-fiber data. The :cleanup allocator dispatch bridges today;
#   under the "one collection = one allocator" policy this becomes a
#   leak.
#
# Axes:
#   producer    ∈ {bg_stream_string, observable_find, observable_reduce_int}
#   consumer_ctx ∈ {top_level, in_frame_loop}

CROSS_FIBER_CELLS = []

%i[bg_stream_int bg_stream_string bg_stream_list bg_stream_struct observable_find observable_reduce_int observable_distinct_string].each do |producer|
  %i[top_level in_frame_loop nested_if].each do |consumer_ctx|
    CROSS_FIBER_CELLS << { producer: producer, consumer_ctx: consumer_ctx }
  end
end

FuzzGenerator.register(:cross_fiber_consumer, cells: CROSS_FIBER_CELLS) do |p|
  producer, target, ty, assert = case p[:producer]
  when :bg_stream_int
    [
      "gen: ~Int64[INF] = BG STREAM {\n        MUTABLE k: Int64 = 0_i64;\n        WHILE k < 3_i64 DO YIELD k; k = k + 1_i64; END\n    };",
      "gen", "Int64",
      'final >= 0_i64',
    ]
  when :bg_stream_string
    [
      "gen: ~String[INF] = BG STREAM {\n        MUTABLE k: Int64 = 0_i64;\n        WHILE k < 3_i64 DO YIELD k.toString(); k = k + 1_i64; END\n    };",
      "gen", "String",
      'final.length() > 0_i64',
    ]
  when :bg_stream_list
    [
      "STRUCT PayloadList { items: Int64[]@list }\n\n    gen: ~PayloadList[INF] = BG STREAM {\n        MUTABLE k: Int64 = 0_i64;\n        WHILE k < 3_i64 DO MUTABLE xs: Int64[]@list = []; xs.append(k); YIELD PayloadList{ items: xs }; k = k + 1_i64; END\n    };",
      "gen", "PayloadList",
      'final.items.length() == 1_i64',
    ]
  when :bg_stream_struct
    [
      "STRUCT Payload { value: String }\n\n    gen: ~Payload[INF] = BG STREAM {\n        MUTABLE k: Int64 = 0_i64;\n        WHILE k < 3_i64 DO YIELD Payload{ value: k.toString() }; k = k + 1_i64; END\n    };",
      "gen", "Payload",
      'final.value.length() > 0_i64',
    ]
  when :observable_find
    [
      "gen: ~String[] = BG STREAM {\n        MUTABLE k: Int64 = 0_i64;\n        WHILE k < 3_i64 DO YIELD k.toString(); k = k + 1_i64; END\n    };\n    matched: ~?String@observable = gen |> FIND _.contains?(\"1\");",
      "matched", "?String",
      'final != NIL',
    ]
  when :observable_reduce_int
    [
      "gen: ~Int64[] = BG STREAM {\n        MUTABLE k: Int64 = 0_i64;\n        WHILE k < 3_i64 DO YIELD k; k = k + 1_i64; END\n    };\n    acc: ~Int64@observable = gen |> SUM _;",
      "acc", "Int64",
      'final >= 0_i64',
    ]
  when :observable_distinct_string
    [
      "gen: ~String[] = BG STREAM {\n        MUTABLE k: Int64 = 0_i64;\n        WHILE k < 3_i64 DO YIELD k.toString(); k = k + 1_i64; END\n    };\n    distinct: ~String[]@set:observable = gen |> DISTINCT _;",
      "distinct", "String[]@set",
      'final.length() >= 0_i64',
    ]
  end

  consume = "#{producer}\n    final: #{ty} = NEXT #{target};\n    ASSERT #{assert}, \"cross-fiber consumer\";"

  if p[:consumer_ctx] == :in_frame_loop
    inner = consume.lines.map { |l| "        #{l}" }.join
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE iter: Int64 = 0_i64;
          WHILE iter < 1_i64 DO
      #{inner}
              iter = iter + 1_i64;
          END
          RETURN;
      END
    CHT
  elsif p[:consumer_ctx] == :nested_if
    inner = consume.lines.map { |l| "            #{l}" }.join
    <<~CHT
      FN main() RETURNS Void ->
          IF TRUE THEN
      #{inner}
          END
          RETURN;
      END
    CHT
  else
    <<~CHT
      FN main() RETURNS Void ->
          #{consume}
          RETURN;
      END
    CHT
  end
end
