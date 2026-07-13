# Template: cast/coercion lowering matrix.
#
# CLEAR has mostly implicit MIR casts from annotation/type-context decisions.
# These cells force common coercions from source type annotations and call
# boundaries.

CAST_LOWERING_CELLS = []

%i[var_decl return_value fn_arg list_literal branch_assign].each do |context|
  %i[int_to_float float_to_int byte_to_int int_to_number number_to_float fn_value].each do |shape|
    expected = :pass
    # Function values are first-class at declaration/return/argument
    # boundaries and through branch reassignment. Lists of function values are
    # not yet a valid source shape, so keep that cell as negative coverage.
    expected = :compile_error if shape == :fn_value && context == :list_literal
    CAST_LOWERING_CELLS << { context: context, shape: shape, expected: expected }
  end
end

def clm_source_expr(shape)
  case shape
  when :int_to_float then ["Float64", "1_i64", "1.0"]
  when :float_to_int then ["Int64", "1.0", "1_i64"]
  when :byte_to_int then ["Int64", "1_u8", "1_i64"]
  when :int_to_number then ["Number", "1_i64", "1.0"]
  when :number_to_float then ["Float64", "1.0", "1.0"]
  when :fn_value then ["FN(Int64)->Int64", "inc", "2_i64"]
  end
end

def clm_prelude(shape)
  shape == :fn_value ? "FN inc(x: Int64) RETURNS Int64 -> RETURN x + 1_i64; END\n" : ""
end

FuzzGenerator.register(:cast_lowering_matrix, cells: CAST_LOWERING_CELLS) do |p|
  ty, expr, expected = clm_source_expr(p[:shape])
  prelude = clm_prelude(p[:shape])

  case p[:context]
  when :var_decl
    if p[:shape] == :fn_value
      <<~CHT
        #{prelude}FN main() RETURNS Void ->
            f: #{ty} = #{expr};
            ASSERT f(1_i64) == #{expected}, "cast var fn";
            RETURN;
        END
      CHT
    else
      <<~CHT
        #{prelude}FN main() RETURNS Void ->
            x: #{ty} = #{expr};
            ASSERT x == #{expected}, "cast var";
            RETURN;
        END
      CHT
    end
  when :return_value
    if p[:shape] == :fn_value
      <<~CHT
        #{prelude}FN make() RETURNS #{ty} -> RETURN #{expr}; END
        FN main() RETURNS Void ->
            f: #{ty} = make();
            ASSERT f(1_i64) == #{expected}, "cast return fn";
            RETURN;
        END
      CHT
    else
      <<~CHT
        #{prelude}FN make() RETURNS #{ty} -> RETURN #{expr}; END
        FN main() RETURNS Void ->
            x: #{ty} = make();
            ASSERT x == #{expected}, "cast return";
            RETURN;
        END
      CHT
    end
  when :fn_arg
    if p[:shape] == :fn_value
      <<~CHT
        #{prelude}FN call(f: #{ty}) RETURNS !Int64 REQUIRES f: NON_REENTRANT -> RETURN f(1_i64); END
        FN main() RETURNS Void ->
            ASSERT (call(#{expr}) OR_ELSE 0_i64) == #{expected}, "cast arg fn";
            RETURN;
        END
      CHT
    else
      <<~CHT
        #{prelude}FN observe(x: #{ty}) RETURNS #{ty} -> RETURN x; END
        FN main() RETURNS Void ->
            x: #{ty} = observe(#{expr});
            ASSERT x == #{expected}, "cast arg";
            RETURN;
        END
      CHT
    end
  when :list_literal
    next_expr = p[:shape] == :fn_value ? "inc" : expr
    assert = p[:shape] == :fn_value ? "ASSERT xs[0_i64](1_i64) == #{expected}, \"cast list fn\";" : "ASSERT xs[0_i64] == #{expected}, \"cast list\";"
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          xs: #{ty}[] = [#{next_expr}];
          #{assert}
          RETURN;
      END
    CHT
  when :branch_assign
    assign = p[:shape] == :fn_value ? "x = inc;" : "x = #{expr};"
    assert = p[:shape] == :fn_value ? "ASSERT x(1_i64) == #{expected}, \"cast branch fn\";" : "ASSERT x == #{expected}, \"cast branch\";"
    seed = p[:shape] == :fn_value ? "inc" : expr
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          MUTABLE x: #{ty} = #{seed};
          IF TRUE THEN #{assign} END
          #{assert}
          RETURN;
      END
    CHT
  end
end
