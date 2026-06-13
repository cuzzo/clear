# Template: loop-local binding whose CleanupClassifier entry uses an
# alloc with cleanup semantics (today: :cleanup runtime dispatch; under
# the "one allocator per collection" target: should be :frame with the
# loop arena mark/rewind keeping the lifetime tight).
#
# Surfaces the LoopFrameAnalysis frame-decl detection gap:
#   `local_frame_decls` recognises bindings whose `storage == :frame`
#   (post-escape-analysis) as needing per-iteration mark/rewind. But a
#   cleanup-alloc-frame binding -- e.g. a STRUCT-literal bound inside a
#   loop body where one field is an owned-string ArrayList -- is NOT
#   currently surfaced as frame-local, so the per-iteration arena rewind
#   is not synthesised. Today the runtime `cleanupAlloc` vtable bridges
#   the gap; the target architecture removes that vtable. When the
#   bridge goes away, this template must still compile + run leak-free.
#
# Shape:
#   FN main() RETURNS !Void ->
#     MUTABLE i: Int64 = 0_i64;
#     WHILE i < 3_i64 DO
#       holder = Holder { items = ["one".COPY, "two".COPY], tag = "t".COPY };
#       IF holder.items.length() < 0_i64 THEN RAISE "x"; END
#       i = i + 1_i64;
#     END
#     RETURN;
#   END
#
# Axes:
#   carrier       ∈ {direct_list, struct_with_list, struct_with_optional_string, struct_with_map}
#   loop_kind     ∈ {while, for_range}
#   element_shape ∈ {string_elems, int_elems}

LLCA_CELLS = []
%i[direct_list struct_with_list struct_with_optional_string struct_with_map].each do |c|
  %i[while for_range].each do |l|
    %i[string_elems int_elems].each do |e|
      LLCA_CELLS << { carrier: c, loop_kind: l, element_shape: e }
    end
  end
end

FuzzGenerator.register(:loop_local_cleanup_alloc, cells: LLCA_CELLS) do |p|
  elem_zig = p[:element_shape] == :string_elems ? "String" : "Int64"
  elem_val = p[:element_shape] == :string_elems ? 'COPY "x"' : "1_i64"

  carrier_decl, inner = case p[:carrier]
  when :direct_list
    [
      "",
      "MUTABLE holder: #{elem_zig}[]@list = List[];\n            holder.append(#{elem_val});\n            IF holder.length() < 0_i64 THEN RAISE \"unreached\"; END",
    ]
  when :struct_with_list
    carrier_init = "Holder{ items: [#{elem_val}], tag: COPY \"t\" }"
    carrier_peek = "holder.items.length()"
    [
      "STRUCT Holder { items: #{elem_zig}[], tag: String }",
      "holder = #{carrier_init};\n            IF #{carrier_peek} < 0_i64 THEN RAISE \"unreached\"; END",
    ]
  when :struct_with_optional_string
    item_peek = p[:element_shape] == :string_elems ? "holder.tag.length()" : "(holder.item OR 1_i64).toString().length()"
    carrier_init = "Holder{ item: #{elem_val}, tag: COPY \"t\" }"
    [
      "STRUCT Holder { item: ?#{elem_zig}, tag: String }",
      "holder = #{carrier_init};\n            IF #{item_peek} < 0_i64 THEN RAISE \"unreached\"; END",
    ]
  when :struct_with_map
    map_peek = p[:element_shape] == :string_elems ? "holder.items.count()" : "(holder.items[\"k\"] OR 1_i64).toString().length()"
    carrier_init = "Holder{ items: { \"k\": #{elem_val} }, tag: COPY \"t\" }"
    [
      "STRUCT Holder { items: HashMap<#{elem_zig}>, tag: String }",
      "holder = #{carrier_init};\n            IF #{map_peek} < 0_i64 THEN RAISE \"unreached\"; END",
    ]
  end

  loop_block = case p[:loop_kind]
  when :while
    <<~LOOP.chomp
      MUTABLE i: Int64 = 0_i64;
          WHILE i < 3_i64 DO
              #{inner}
              i = i + 1_i64;
          END
    LOOP
  when :for_range
    <<~LOOP.chomp
      FOR i IN (0_i64 ..< 3_i64) DO
              #{inner}
          END
    LOOP
  end

  <<~CHT
    #{carrier_decl}

    FN main() RETURNS !Void ->
        #{loop_block}
        RETURN;
    END
  CHT
end
