# Template: OR heap destination matrix.
#
# Targets MIR lowering's heap-destination placement for owned OR/TryCatch/
# optional branches. Every cell is a valid source program; a failure is a
# surfaced compiler bug, not a fuzz harness exception.

OR_HEAP_DESTINATION_CELLS = []

%i[orelse_success orelse_fallback try_success try_fallback].each do |or_kind|
  %i[return_value local_decl struct_field list_append fn_arg branch_expr].each do |sink|
    %i[string concat struct_owned list_owned].each do |shape|
      expected = :pass
      expected = :compile_error if sink == :list_append && shape == :list_owned
      OR_HEAP_DESTINATION_CELLS << { or_kind: or_kind, sink: sink, shape: shape, expected: expected }
    end
  end
end

def ohd_prelude(shape)
  case shape
  when :struct_owned
    "STRUCT Box { label: String }\n"
  else
    ""
  end
end

def ohd_type(shape)
  case shape
  when :string, :concat then "String"
  when :struct_owned then "Box"
  when :list_owned then "Int64[]@list"
  end
end

def ohd_make_body(shape)
  case shape
  when :string
    'out: ?String = COPY "ok"; RETURN out;'
  when :concat
    'out: ?String = COPY "o" + COPY "k"; RETURN out;'
  when :struct_owned
    'out: ?Box = Box{ label: COPY "ok" }; RETURN out;'
  when :list_owned
    "MUTABLE xs: Int64[]@list = [];\n    xs.append(1_i64);\n    xs.append(2_i64);\n    out: ?Int64[]@list = xs;\n    RETURN out;"
  end
end

def ohd_fallback(shape)
  case shape
  when :string
    'COPY "fb"'
  when :concat
    'COPY "f" + COPY "b"'
  when :struct_owned
    'Box{ label: COPY "fb" }'
  when :list_owned
    'fallbackList() OR RAISE'
  end
end

def ohd_fallback_call(shape)
  shape == :list_owned ? "fallbackList()" : ohd_fallback(shape)
end

def ohd_observe(shape, name)
  case shape
  when :string, :concat then "#{name}.length()"
  when :struct_owned then "#{name}.label.length()"
  when :list_owned then "#{name}.length()"
  end
end

def ohd_expected(or_kind, shape)
  success = %i[orelse_success try_success].include?(or_kind)
  case shape
  when :string, :concat, :struct_owned, :list_owned
    success ? 2 : 2
  end
end

def ohd_or_expr(or_kind, shape)
  case or_kind
  when :orelse_success
    "maybeSome(TRUE) OR #{ohd_fallback_call(shape)}"
  when :orelse_fallback
    "maybeSome(FALSE) OR #{ohd_fallback_call(shape)}"
  when :try_success
    "makeFallible(TRUE) OR #{ohd_fallback_call(shape)}"
  when :try_fallback
    "makeFallible(FALSE) OR #{ohd_fallback_call(shape)}"
  end
end

FuzzGenerator.register(:or_heap_destination_matrix, cells: OR_HEAP_DESTINATION_CELLS) do |p|
  ty = ohd_type(p[:shape])
  expr = ohd_or_expr(p[:or_kind], p[:shape])
  prelude = ohd_prelude(p[:shape])
  fallback_helper = p[:shape] == :list_owned ? <<~CHT : ""
    FN fallbackList() RETURNS Int64[]@list ->
        MUTABLE xs: Int64[]@list = [];
        xs.append(7_i64);
        xs.append(8_i64);
        RETURN xs;
    END
  CHT
  helpers = <<~CHT
    #{prelude}#{fallback_helper}
    FN maybeSome(flag: Bool) RETURNS ?#{ty} ->
        IF flag THEN
            #{ohd_make_body(p[:shape])}
        END
        out: ?#{ty} = NIL;
        RETURN out;
    END

    FN makeFallible(flag: Bool) RETURNS !#{ty} ->
        IF flag THEN
            RETURN #{ohd_fallback_call(p[:shape])};
        END
        RAISE "no";
    END

    FN consume(x: #{ty}) RETURNS Int64 ->
        RETURN #{ohd_observe(p[:shape], "x")};
    END
  CHT

  case p[:sink]
  when :return_value
    <<~CHT
      #{helpers}
      FN build() RETURNS #{ty} ->
          RETURN #{expr};
      END

      FN main() RETURNS Void ->
          v: #{ty} = build();
          ASSERT #{ohd_observe(p[:shape], "v")} == #{ohd_expected(p[:or_kind], p[:shape])}_i64, "or heap return";
          RETURN;
      END
    CHT
  when :local_decl
    <<~CHT
      #{helpers}
      FN main() RETURNS Void ->
          v: #{ty} = #{expr};
          ASSERT #{ohd_observe(p[:shape], "v")} == #{ohd_expected(p[:or_kind], p[:shape])}_i64, "or heap local";
          RETURN;
      END
    CHT
  when :struct_field
    <<~CHT
      #{helpers}
      STRUCT Holder { value: #{ty} }
      FN main() RETURNS Void ->
          h: Holder = Holder{ value: #{expr} };
          ASSERT #{ohd_observe(p[:shape], "h.value")} == #{ohd_expected(p[:or_kind], p[:shape])}_i64, "or heap field";
          RETURN;
      END
    CHT
  when :list_append
    <<~CHT
      #{helpers}
      FN main() RETURNS Void ->
          MUTABLE out: #{ty}[]@list = [];
          out.append(#{expr});
          ASSERT out.length() == 1_i64, "or heap list append";
          RETURN;
      END
    CHT
  when :fn_arg
    <<~CHT
      #{helpers}
      FN main() RETURNS Void ->
          ASSERT consume(#{expr}) == #{ohd_expected(p[:or_kind], p[:shape])}_i64, "or heap fn arg";
          RETURN;
      END
    CHT
  when :branch_expr
    <<~CHT
      #{helpers}
      FN main() RETURNS Void ->
          MUTABLE n: Int64 = 0_i64;
          IF TRUE THEN
              v: #{ty} = #{expr};
              n = #{ohd_observe(p[:shape], "v")};
          ELSE
              n = 99_i64;
          END
          ASSERT n == #{ohd_expected(p[:or_kind], p[:shape])}_i64, "or heap branch";
          RETURN;
      END
    CHT
  end
end
