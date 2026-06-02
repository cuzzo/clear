# Template: access path expression matrix.
#
# Covers field/index/optional access paths that feed lowering expression arms
# and ownership materialization. These are source-level positive programs.

ACCESS_PATH_EXPRESSION_CELLS = []

%i[field index optional_field optional_index map_index set_index nested_field].each do |access|
  %i[local return_value fn_arg branch loop].each do |context|
    ACCESS_PATH_EXPRESSION_CELLS << { access: access, context: context }
  end
end

def apx_prelude(access)
  case access
  when :field, :optional_field, :nested_field
    "STRUCT Box { label: String }\nSTRUCT Wrap { box: Box }\n"
  when :optional_index
    "FN maybeList(flag: Bool) RETURNS ?String[]@list ->\n    IF flag THEN\n        xs: String[]@list = [COPY \"abc\", COPY \"de\"];\n        RETURN xs;\n    END\n    RETURN NIL;\nEND\n"
  else
    ""
  end
end

def apx_setup(access)
  case access
  when :field
    'b: Box = Box{ label: COPY "abc" };'
  when :index
    'xs: String[] = [COPY "abc", COPY "de"];'
  when :optional_field
    'maybe: ?Box = Box{ label: COPY "abc" };'
  when :optional_index
    'maybe: ?String[]@list = maybeList(TRUE);'
  when :map_index
    'm: HashMap<String> = {"a": COPY "abc"};'
  when :set_index
    'MUTABLE s: String[]@set = Set[]; s.insert("abc");'
  when :nested_field
    'w: Wrap = Wrap{ box: Box{ label: COPY "abc" } };'
  end
end

def apx_type(access)
  case access
  when :optional_field, :optional_index, :map_index, :set_index then "?String"
  else "String"
  end
end

def apx_expr(access)
  case access
  when :field then "b.label"
  when :index then "xs[0_i64]"
  when :optional_field then "maybe?.label"
  when :optional_index then "maybe?[0_i64]"
  when :map_index then "m[\"a\"]"
  when :set_index then "s[\"abc\"]"
  when :nested_field then "w.box.label"
  end
end

def apx_return_expr(access)
  %i[map_index set_index].include?(access) ? "COPY (#{apx_expr(access)} OR COPY \"\")" : "COPY #{apx_expr(access)}"
end

def apx_observe(access, name)
  %i[optional_field optional_index map_index set_index].include?(access) ? "(#{name} OR COPY \"\").length()" : "#{name}.length()"
end

FuzzGenerator.register(:access_path_expression_matrix, cells: ACCESS_PATH_EXPRESSION_CELLS) do |p|
  ty = apx_type(p[:access])
  expr = apx_expr(p[:access])
  setup = apx_setup(p[:access])
  prelude = apx_prelude(p[:access])

  case p[:context]
  when :local
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          #{setup}
          v: #{ty} = #{expr};
          ASSERT #{apx_observe(p[:access], "v")} == 3_i64, "access local";
          RETURN;
      END
    CHT
  when :return_value
    ret_expr = apx_return_expr(p[:access])
    <<~CHT
      #{prelude}FN build() RETURNS #{ty} ->
          #{setup}
          RETURN #{ret_expr};
      END

      FN main() RETURNS Void ->
          v: #{ty} = build();
          ASSERT #{apx_observe(p[:access], "v")} == 3_i64, "access return";
          RETURN;
      END
    CHT
  when :fn_arg
    optional_access = %i[optional_field optional_index map_index set_index].include?(p[:access])
    arg_type = optional_access ? "?String" : "String"
    <<~CHT
      #{prelude}FN observe(x: #{arg_type}) RETURNS Int64 ->
          RETURN #{optional_access ? '(x OR COPY "").length()' : 'x.length()'};
      END

      FN main() RETURNS Void ->
          #{setup}
          ASSERT observe(#{expr}) == 3_i64, "access arg";
          RETURN;
      END
    CHT
  when :branch
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          #{setup}
          MUTABLE n: Int64 = 0_i64;
          IF TRUE THEN
              v: #{ty} = #{expr};
              n = #{apx_observe(p[:access], "v")};
          ELSE
              n = 99_i64;
          END
          ASSERT n == 3_i64, "access branch";
          RETURN;
      END
    CHT
  when :loop
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          #{setup}
          MUTABLE i: Int64 = 0_i64;
          MUTABLE total: Int64 = 0_i64;
          WHILE i < 2_i64 DO
              v: #{ty} = #{expr};
              total = total + #{apx_observe(p[:access], "v")};
              i = i + 1_i64;
          END
          ASSERT total == 6_i64, "access loop";
          RETURN;
      END
    CHT
  end
end
