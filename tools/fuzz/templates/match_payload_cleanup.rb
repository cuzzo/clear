# Template: MATCH-AS / MATCH-TAKES payload-cleanup matrix.
#
# Drives CleanupClassifier.walk_match_as_bindings + match_as_entry_for
# through every union-variant payload shape. The MATCH source is consumed
# via `PARTIAL MATCH TAKES`, so the AS-binding inherits a cleanup contract
# (the source's defer transfers to the binding).
#
# Targets the uncovered match_as_entry_for arms in cleanup_classifier.rb:
#   inline-struct variant, slice/list variant, map variant, string variant.
#
# `mode` axis: :takes consumes the union (was_moved -> walk_match_as_bindings
# fires); :borrow keeps it (plain PARTIAL MATCH, AS binding is a borrow).

MATCH_PAYLOAD_CELLS = []
%i[string list inline_struct map].each do |payload|
  %i[takes borrow].each do |mode|
    MATCH_PAYLOAD_CELLS << { payload: payload, mode: mode }
  end
end

FuzzGenerator.register(:match_payload_cleanup, cells: MATCH_PAYLOAD_CELLS) do |p|
  # Union definition + the canonical builder for the chosen variant.
  union_def, build, variant, observe = case p[:payload]
  when :string
    ["UNION Box { Nil, Payload: String }",
     'Box{ Payload: COPY "hello" }',
     "Box.Payload",
     'ASSERT x == "hello", "match string payload";']
  when :list
    ["UNION Box { Nil, Payload: Int64[]@list }",
     "Box{ Payload: built }",
     "Box.Payload",
     'ASSERT x.length() == 3_i64, "match list payload";']
  when :inline_struct
    ["UNION Box { Nil, Payload { label: String, count: Int64 } }",
     'Box.Payload{ label: "tag", count: 5_i64 }',
     "Box.Payload",
     'ASSERT x.label == "tag", "match inline-struct payload";']
  when :map
    ["UNION Box { Nil, Payload: HashMap<Int64> }",
     "Box{ Payload: built }",
     "Box.Payload",
     'ASSERT x.count() == 2_i64, "match map payload";']
  end

  # Pre-build heap collection payloads into a local before constructing
  # the union (string + inline-struct construct inline).
  prelude = case p[:payload]
  when :list
    <<~PRE.chomp
      MUTABLE built: Int64[]@list = [];
          built.append(1_i64);
          built.append(2_i64);
          built.append(3_i64);
    PRE
  when :map
    <<~PRE.chomp
      MUTABLE built: HashMap<Int64> = {};
          built["a"] = 1_i64;
          built["b"] = 2_i64;
    PRE
  else
    ""
  end

  match_kw = p[:mode] == :takes ? "PARTIAL MATCH TAKES" : "PARTIAL MATCH"

  if p[:mode] == :takes
    # TAKES: the union is consumed by a helper fn that owns it.
    <<~CHT
      #{union_def}

      FN consume!(TAKES b: Box) RETURNS Void ->
          #{match_kw} b START
              #{variant} AS x -> #{observe},
              DEFAULT -> ASSERT FALSE, "expected Payload variant";
          END
          RETURN;
      END

      FN main() RETURNS Void ->
          #{prelude.empty? ? '' : prelude + "\n    "}boxed = #{build};
          consume!(boxed);
          RETURN;
      END
    CHT
  else
    # Borrow: MATCH AS over a local; the binding borrows the payload.
    <<~CHT
      #{union_def}

      FN main() RETURNS Void ->
          #{prelude.empty? ? '' : prelude + "\n    "}boxed = #{build};
          #{match_kw} boxed START
              #{variant} AS x -> #{observe},
              DEFAULT -> ASSERT FALSE, "expected Payload variant";
          END
          RETURN;
      END
    CHT
  end
end
