# Template: collection sink escape matrix.
#
# Covers owned values stored into every collection-family sink. Existing
# modality templates cover return/struct/list deeply; this template fills the
# set/map/pool/literal escape-sink axis.

COLLECTION_SINK_ESCAPE_CELLS = []

%i[string struct_owned union_owned].each do |shape|
  %i[list_append set_insert map_put pool_insert literal_return literal_local].each do |sink|
    COLLECTION_SINK_ESCAPE_CELLS << { shape: shape, sink: sink }
  end
end

# A union's lifecycle is type-wide, not variant-local. Scalar variants of a
# union that can also hold String still cross a TAKES/append boundary as owned
# composite values and require verifier-visible materialization.
COLLECTION_SINK_ESCAPE_CELLS << { shape: :union_mixed, sink: :list_append }

def csem_prelude(shape)
  case shape
  when :struct_owned
    "STRUCT Item { label: String }\n"
  when :union_owned
    "UNION Item { Empty, Text: String }\n"
  when :union_mixed
    "UNION Item { Empty, Text: String, Count: Int64, Number: Float64 }\n"
  else
    ""
  end
end

def csem_type(shape)
  case shape
  when :string then "String"
  when :struct_owned, :union_owned, :union_mixed then "Item"
  end
end

def csem_value(shape, suffix = "a")
  case shape
  when :string then "COPY \"#{suffix}\""
  when :struct_owned then "Item{ label: COPY \"#{suffix}\" }"
  when :union_owned then "Item{ Text: COPY \"#{suffix}\" }"
  when :union_mixed then "Item{ Text: COPY \"#{suffix}\" }"
  end
end

def csem_observe(shape, expr)
  case shape
  when :string then "#{expr}.length()"
  when :struct_owned then "#{expr}.label.length()"
  when :union_owned, :union_mixed then "1_i64"
  end
end

FuzzGenerator.register(:collection_sink_escape_matrix, cells: COLLECTION_SINK_ESCAPE_CELLS) do |p|
  ty = csem_type(p[:shape])
  prelude = csem_prelude(p[:shape])
  val = csem_value(p[:shape])

  case p[:sink]
  when :list_append
    if p[:shape] == :union_mixed
      <<~CHT
        #{prelude}FN main() RETURNS Void ->
            MUTABLE out: []Item = [];
            &out.append(Item{ Text: COPY "owned" });
            &out.append(Item{ Count: 7 });
            &out.append(Item{ Number: 1.5 });
            ASSERT out.length() == 3_i64, "mixed union list sink";
            RETURN;
        END
      CHT
    else
      <<~CHT
        #{prelude}FN main() RETURNS Void ->
            MUTABLE out: []#{ty} = [];
            &out.append(#{val});
            ASSERT out.length() == 1_i64, "collection list sink";
            RETURN;
        END
      CHT
    end
  when :set_insert
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          MUTABLE out: [Set]#{ty} = [];
          &out.insert(#{val});
          ASSERT out.length() == 1_i64, "collection set sink";
          RETURN;
      END
    CHT
  when :map_put
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          MUTABLE out: {String}#{ty} = {};
          out["k"] = #{val};
          ASSERT out.count() == 1_i64, "collection map sink";
          RETURN;
      END
    CHT
  when :pool_insert
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          MUTABLE out: [Pool(8)]#{ty} = [];
          _ = &out.insert(#{val});
          ASSERT out.length() == 1_i64, "collection pool sink";
          RETURN;
      END
    CHT
  when :literal_return
    <<~CHT
      #{prelude}FN build() RETURNS ![]#{ty} ->
          RETURN [#{val}, #{csem_value(p[:shape], "b")}];
      END

      FN main() RETURNS Void ->
          out: []#{ty} = build() OR_ELSE RAISE;
          ASSERT out.length() == 2_i64, "collection literal return";
          RETURN;
      END
    CHT
  when :literal_local
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          out: []#{ty} = [#{val}, #{csem_value(p[:shape], "b")}];
          ASSERT out.length() == 2_i64, "collection literal local";
          RETURN;
      END
    CHT
  end
end
