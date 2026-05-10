# Template: collection escapes via RETURN.
# Stresses E2 :always_returned + :heap_ptr_return.
#
# Pattern: build a collection inside a function, return it. The fix path is
# `promoteList`/heap-promotion at the boundary; if the compiler skips it, the
# caller holds a dangling pointer to a frame buffer.

ESCAPE_VIA_RETURN_CELLS = []

[:int, :string].each do |elem|
  [:none, :loop, :early_if].each do |body|
    [3, 7].each do |size|
      ESCAPE_VIA_RETURN_CELLS << { elem: elem, body: body, size: size }
    end
  end
end

FuzzGenerator.register(:escape_via_return, cells: ESCAPE_VIA_RETURN_CELLS) do |p|
  zig_type = (p[:elem] == :int) ? "Int64" : "String"
  type_decl = "#{zig_type}[]@list"

  values = (1..p[:size]).map do |i|
    p[:elem] == :int ? "#{i}_i64" : %("v#{i}")
  end

  body = case p[:body]
  when :none
    values.map { |v| "    lst.append(#{v});" }.join("\n")
  when :loop
    if p[:elem] == :int
      "    FOR i IN (1_i64 ..= #{p[:size]}_i64) DO\n        lst.append(i);\n    END"
    else
      values.map { |v| "    lst.append(#{v});" }.join("\n")
    end
  when :early_if
    half = (p[:size] / 2).clamp(1, p[:size])
    front = values.first(half).map { |v| "    lst.append(#{v});" }.join("\n")
    rest  = values.drop(half).map  { |v| "    lst.append(#{v});" }.join("\n")
    "#{front}\n    IF #{half}_i64 < 0_i64 THEN\n        RETURN lst;\n    END\n#{rest}"
  end

  expected_len = if p[:body] == :loop && p[:elem] == :int
    p[:size]
  else
    p[:size]
  end

  first_check = if p[:elem] == :int
    "ASSERT result[0] == 1_i64, \"first element\";"
  else
    'ASSERT eql?(result[0], "v1"), "first element";'
  end

  <<~CHT
    FN make() RETURNS !#{type_decl} ->
        MUTABLE lst: #{type_decl} = [];
    #{body}
        RETURN lst;
    END

    FN main() RETURNS Void ->
        result = make();
        ASSERT length(result) == #{expected_len}_i64, "returned list length";
        #{first_check}
        RETURN;
    END
  CHT
end
