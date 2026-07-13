# Template: hoist edge matrix.
#
# Source-level coverage for nested allocating expressions that must become
# named MIR bindings before ownership/cleanup checking. These cells deliberately
# put owned values in expression positions where lowering must hoist rather than
# make a local special-case decision.

HOIST_EDGE_CELLS = []

%i[string_concat list_call struct_literal union_literal].each do |shape|
  %i[return_value local_init struct_field list_append fn_arg if_branch or_fallback loop_body].each do |context|
    expected = :pass
    expected = :compile_error if context == :list_append && shape == :list_call
    HOIST_EDGE_CELLS << { shape: shape, context: context, expected: expected }
  end
end

%i[string_concat struct_literal union_literal].each do |shape|
  %i[collection_literal match_subject nested_aggregate].each do |context|
    HOIST_EDGE_CELLS << { shape: shape, context: context }
  end
end
HOIST_EDGE_CELLS << { shape: :string_concat, context: :while_condition }
HOIST_EDGE_CELLS << { shape: :list_call, context: :return_or_fallback }

def hem_prelude(shape)
  case shape
  when :struct_literal
    "STRUCT Box { label: String }\n"
  when :union_literal
    "UNION Slot { Empty, Text: String }\n"
  else
    ""
  end
end

def hem_type(shape)
  case shape
  when :string_concat then "String"
  when :list_call then "Int64[]@list"
  when :struct_literal then "Box"
  when :union_literal then "Slot"
  end
end

def hem_helpers(shape)
  list_helper = <<~CHT
    FN mkList() RETURNS !Int64[]@list ->
        MUTABLE xs: Int64[]@list = [];
        xs.append(1_i64);
        xs.append(2_i64);
        RETURN xs;
    END
  CHT
  fail_helper = <<~CHT
    FN failValue() RETURNS !#{hem_type(shape)} ->
        RAISE "no";
    END
  CHT
  "#{hem_prelude(shape)}#{list_helper}#{fail_helper}"
end

def hem_expr(shape)
  case shape
  when :string_concat then 'COPY "a" $+ COPY "b"'
  when :list_call then 'mkList() OR_ELSE RAISE'
  when :struct_literal then 'Box{ label: COPY "a" $+ COPY "b" }'
  when :union_literal then 'Slot{ Text: COPY "a" $+ COPY "b" }'
  end
end

def hem_fallback(shape)
  case shape
  when :string_concat then 'COPY "f" $+ COPY "b"'
  when :list_call then 'mkList() OR_ELSE RAISE'
  when :struct_literal then 'Box{ label: COPY "f" $+ COPY "b" }'
  when :union_literal then 'Slot{ Text: COPY "f" $+ COPY "b" }'
  end
end

def hem_observe(shape, name)
  case shape
  when :string_concat then "#{name}.length()"
  when :list_call then "#{name}.length()"
  when :struct_literal then "#{name}.label.length()"
  when :union_literal then "1_i64"
  end
end

FuzzGenerator.register(:hoist_edge_matrix, cells: HOIST_EDGE_CELLS) do |p|
  ty = hem_type(p[:shape])
  expr = hem_expr(p[:shape])
  helpers = hem_helpers(p[:shape])

  case p[:context]
  when :return_value
    <<~CHT
      #{helpers}
      FN build() RETURNS !#{ty} ->
          RETURN #{expr};
      END

      FN main() RETURNS !Void ->
          v: #{ty} = build() OR_ELSE RAISE;
          ASSERT #{hem_observe(p[:shape], "v")} >= 1_i64, "hoist return";
          RETURN;
      END
    CHT
  when :local_init
    <<~CHT
      #{helpers}
      FN main() RETURNS !Void ->
          v: #{ty} = #{expr};
          ASSERT #{hem_observe(p[:shape], "v")} >= 1_i64, "hoist local";
          RETURN;
      END
    CHT
  when :struct_field
    <<~CHT
      #{helpers}
      STRUCT Holder { value: #{ty} }
      FN main() RETURNS !Void ->
          h: Holder = Holder{ value: #{expr} };
          ASSERT #{hem_observe(p[:shape], "h.value")} >= 1_i64, "hoist field";
          RETURN;
      END
    CHT
  when :list_append
    <<~CHT
      #{helpers}
      FN main() RETURNS !Void ->
          MUTABLE out: #{ty}[]@list = [];
          out.append(#{expr});
          ASSERT out.length() == 1_i64, "hoist list append";
          RETURN;
      END
    CHT
  when :fn_arg
    <<~CHT
      #{helpers}
      FN observe(x: #{ty}) RETURNS Int64 -> RETURN #{hem_observe(p[:shape], "x")}; END

      FN main() RETURNS !Void ->
          ASSERT observe(#{expr}) >= 1_i64, "hoist fn arg";
          RETURN;
      END
    CHT
  when :if_branch
    <<~CHT
      #{helpers}
      FN main() RETURNS !Void ->
          MUTABLE n: Int64 = 0_i64;
          IF TRUE THEN
              v: #{ty} = #{expr};
              n = #{hem_observe(p[:shape], "v")};
          ELSE
              n = 99_i64;
          END
          ASSERT n >= 1_i64, "hoist if branch";
          RETURN;
      END
    CHT
  when :or_fallback
    <<~CHT
      #{helpers}
      FN main() RETURNS !Void ->
          v: #{ty} = failValue() OR_ELSE #{hem_fallback(p[:shape])};
          ASSERT #{hem_observe(p[:shape], "v")} >= 1_i64, "hoist fallback";
          RETURN;
      END
    CHT
  when :loop_body
    <<~CHT
      #{helpers}
      FN main() RETURNS !Void ->
          MUTABLE i: Int64 = 0_i64;
          MUTABLE total: Int64 = 0_i64;
          WHILE i < 2_i64 DO
              v: #{ty} = #{expr};
              total = total + #{hem_observe(p[:shape], "v")};
              i = i + 1_i64;
          END
          ASSERT total >= 2_i64, "hoist loop";
          RETURN;
      END
    CHT
  when :collection_literal
    <<~CHT
      #{helpers}
      FN main() RETURNS !Void ->
          values: #{ty}[] = [#{expr}];
          ASSERT #{hem_observe(p[:shape], "values[0_i64]")} >= 1_i64, "hoist collection literal";
          RETURN;
      END
    CHT
  when :match_subject
    <<~CHT
      #{helpers}
      UNION Wrap { Empty, Item: #{ty} }

      FN main() RETURNS !Void ->
          w = Wrap{ Item: #{expr} };
          MUTABLE n: Int64 = 0_i64;
          PARTIAL MATCH w START
              Wrap.Item AS x -> n = #{hem_observe(p[:shape], "x")};,
              DEFAULT -> n = 99_i64;
          END
          ASSERT n >= 1_i64, "hoist match subject";
          RETURN;
      END
    CHT
  when :nested_aggregate
    <<~CHT
      #{helpers}
      STRUCT Holder { values: #{ty}[] }
      FN main() RETURNS !Void ->
          h = Holder{ values: [#{expr}] };
          ASSERT #{hem_observe(p[:shape], "h.values[0_i64]")} >= 1_i64, "hoist nested aggregate";
          RETURN;
      END
    CHT
  when :while_condition
    <<~CHT
      FN nonempty(s: String) RETURNS Bool -> RETURN s.length() > 0_i64; END

      FN main() RETURNS !Void ->
          MUTABLE count: Int64 = 0_i64;
          WHILE count < 1_i64 AND nonempty(COPY "a" $+ COPY "b") DO
              count = count + 1_i64;
          END
          ASSERT count == 1_i64, "hoist while condition";
          RETURN;
      END
    CHT
  when :return_or_fallback
    <<~CHT
      #{helpers}
      FN build(flag: Bool) RETURNS !#{ty} ->
          IF flag THEN
              RETURN #{expr};
          END
          RAISE "no";
      END

      FN main() RETURNS !Void ->
          v: #{ty} = build(FALSE) OR_ELSE #{hem_fallback(p[:shape])};
          ASSERT #{hem_observe(p[:shape], "v")} >= 1_i64, "hoist return or fallback";
          RETURN;
      END
    CHT
  end
end
