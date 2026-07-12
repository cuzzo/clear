# Template: OR_ELSE heap destination matrix.
#
# Targets MIR lowering's heap-destination placement for owned OR_ELSE/TryCatch/
# optional branches. Every cell is a valid source program; a failure is a
# surfaced compiler bug, not a fuzz harness exception.

OR_HEAP_DESTINATION_CELLS = []
OHD_OWNED_VALUE_SHAPES = %i[string concat struct_owned list_owned string_list_owned union_owned nested_owned].freeze

%i[orelse_success orelse_fallback try_success try_fallback].each do |or_kind|
  %i[return_value local_decl struct_field list_append fn_arg branch_expr].each do |sink|
    OHD_OWNED_VALUE_SHAPES.each do |shape|
      expected = :pass
      expected = :compile_error if sink == :list_append && %i[list_owned string_list_owned].include?(shape)
      OR_HEAP_DESTINATION_CELLS << { or_kind: or_kind, sink: sink, shape: shape, expected: expected }
    end
  end
end

def ohd_prelude(shape)
  case shape
  when :struct_owned
    "STRUCT Box { label: String }\n"
  when :union_owned
    "UNION Val { Empty, Text: String, Items: String[]@list }\n"
  when :nested_owned
    "STRUCT Nest { items: String[]@list }\n"
  else
    ""
  end
end

def ohd_shape_helpers(shape)
  return "" unless %i[string_list_owned union_owned nested_owned].include?(shape)

  list_helper = <<~CHT
    FN mkStringList() RETURNS String[]@list ->
        MUTABLE xs: String[]@list = List[];
        xs.append(COPY "a");
        xs.append(COPY "b");
        RETURN xs;
    END
  CHT
  union_helper = shape == :union_owned ? <<~CHT : ""
    FN observeVal(x: Val) RETURNS Int64 ->
        PARTIAL MATCH x START
            Val.Text AS s -> RETURN s.length();,
            Val.Items AS items -> RETURN items.length();,
            DEFAULT -> RETURN 0_i64;
        END
    END
  CHT
  "#{list_helper}#{union_helper}"
end

def ohd_type(shape)
  case shape
  when :string, :concat then "String"
  when :struct_owned then "Box"
  when :list_owned then "Int64[]@list"
  when :string_list_owned then "String[]@list"
  when :union_owned then "Val"
  when :nested_owned then "Nest"
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
    "MUTABLE xs: Int64[]@list = [];\n    xs.append(1_i64);\n    xs.append(2_i64);\n    out: ?(Int64[]@list) = xs;\n    RETURN out;"
  when :string_list_owned
    "out: ?(String[]@list) = mkStringList(); RETURN out;"
  when :union_owned
    "out: ?Val = Val{ Items: mkStringList() }; RETURN out;"
  when :nested_owned
    "out: ?Nest = Nest{ items: mkStringList() }; RETURN out;"
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
    'fallbackList() OR_ELSE RAISE'
  when :string_list_owned
    'mkStringList()'
  when :union_owned
    'Val{ Items: mkStringList() }'
  when :nested_owned
    'Nest{ items: mkStringList() }'
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
  when :string_list_owned then "#{name}.length()"
  when :union_owned then "observeVal(#{name})"
  when :nested_owned then "#{name}.items.length()"
  end
end

def ohd_expected(or_kind, shape)
  success = %i[orelse_success try_success].include?(or_kind)
  case shape
  when :string, :concat, :struct_owned, :list_owned, :string_list_owned, :union_owned, :nested_owned
    success ? 2 : 2
  end
end

def ohd_or_expr(or_kind, shape)
  case or_kind
  when :orelse_success
    "maybeSome(TRUE) OR_ELSE #{ohd_fallback_call(shape)}"
  when :orelse_fallback
    "maybeSome(FALSE) OR_ELSE #{ohd_fallback_call(shape)}"
  when :try_success
    "makeFallible(TRUE) OR_ELSE #{ohd_fallback_call(shape)}"
  when :try_fallback
    "makeFallible(FALSE) OR_ELSE #{ohd_fallback_call(shape)}"
  end
end

FuzzGenerator.register(:or_heap_destination_matrix, cells: OR_HEAP_DESTINATION_CELLS) do |p|
  ty = ohd_type(p[:shape])
  optional_ty = ty.include?("[]") ? "?(#{ty})" : "?#{ty}"
  expr = ohd_or_expr(p[:or_kind], p[:shape])
  prelude = "#{ohd_prelude(p[:shape])}#{ohd_shape_helpers(p[:shape])}"
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
    FN maybeSome(flag: Bool) RETURNS #{optional_ty} ->
        IF flag THEN
            #{ohd_make_body(p[:shape])}
        END
        out: #{optional_ty} = NIL;
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
