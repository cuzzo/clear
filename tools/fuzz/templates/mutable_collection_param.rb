# Template: MUTABLE collection passed as a parameter and mutated by the callee.
# Stresses E2 :mutable_list_param_escape and INV-CROSS-FRAME-PARAM-ALLOC.
#
# Pattern: a function takes MUTABLE xs: T[]@list, appends to it, returns. The
# caller's list crosses a frame boundary as a pointer; if the caller frame-
# allocated it, the buffer relocates on grow and the callee sees stale state
# (or the post-call read sees a freed buffer).

MUTABLE_PARAM_CELLS = []

[:list, :set, :map].each do |collection|
  [:int, :string].each do |elem|
    [:none, :outer_loop].each do |context|
      [1, 4].each do |calls|
        MUTABLE_PARAM_CELLS << { collection: collection, elem: elem, context: context, calls: calls }
      end
    end
  end
end

FuzzGenerator.register(:mutable_collection_param, cells: MUTABLE_PARAM_CELLS) do |p|
  zig_type = (p[:elem] == :int) ? "Int64" : "String"
  type_decl = case p[:collection]
              when :list then "#{zig_type}[]@list"
              when :set then "#{zig_type}[]@set"
              when :map then "HashMap<#{zig_type}>"
              end

  mutation = case p[:collection]
             when :list
               push_value = (p[:elem] == :int) ? "99_i64" : '"hello"'
               "&xs.append(#{push_value});"
             when :set
               p[:elem] == :int ? "&xs.insert(xs.length());" : "&xs.insert(xs.length().toString());"
             when :map
               push_value = (p[:elem] == :int) ? "99_i64" : '"hello"'
               "xs[\"k\" $+ xs.count().toString()] = #{push_value};"
             end

  # `xs.append` is fallible (OOM) so callee must declare !Void.
  callee = <<~CHT.chomp
    FN add(MUTABLE xs: #{type_decl}) RETURNS !Void ->
        #{mutation}
        RETURN;
    END
  CHT

  call_block = case p[:context]
  when :none
    (1..p[:calls]).map { "    add(&lst);" }.join("\n")
  when :outer_loop
    "    FOR i IN (1_i64 ..= #{p[:calls]}_i64) DO\n        add(&lst);\n    END"
  end

  expected_len = p[:calls]
  len_expr = p[:collection] == :map ? "lst.count()" : "length(lst)"

  <<~CHT
    #{callee}

    FN main() RETURNS Void ->
        MUTABLE lst: #{type_decl} = #{p[:collection] == :map ? '{}' : '[]'};
    #{call_block}
        ASSERT #{len_expr} == #{expected_len}_i64, "collection length after mutating calls";
        RETURN;
    END
  CHT
end
