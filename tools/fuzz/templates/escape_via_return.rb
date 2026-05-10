# Template: collection escapes via RETURN.
# Stresses E2 :always_returned + :heap_ptr_return.
#
# Pattern: build a value of type T inside a function, return it. The fix
# path is heap-promotion at the boundary; if the compiler skips it for
# any T, the caller holds a dangling pointer to a frame buffer.
#
# Type axis intentionally exhaustive: every escape-relevant type
# category exists here so a missing `needs_escape_promotion?` case
# becomes a runtime UAF in CI rather than a silent class of bugs.
# Categories: list (was the only original), set, pool (handles), map
# (string-key non-numeric vs Int-key numeric), struct-with-heap-field,
# union-with-heap-variant. Each category corresponds to a different
# heap-cleanup shape; missing any one of them surfaces a leak/UAF in
# the test runner.

ESCAPE_VIA_RETURN_CELLS = []

[:int, :string,
 :set_int, :set_string,
 :pool, :map_str, :map_int_numeric,
 :struct_with_list, :union_with_heap].each do |elem|
  [:none, :loop, :early_if].each do |body|
    [3, 7].each do |size|
      ESCAPE_VIA_RETURN_CELLS << { elem: elem, body: body, size: size }
    end
  end
end

FuzzGenerator.register(:escape_via_return, cells: ESCAPE_VIA_RETURN_CELLS) do |p|
  size = p[:size]

  # ── Per-type wiring: declared return type, allocation literal,
  # ── append fragment, length+first-element assertions.
  case p[:elem]
  when :int, :string
    zig_type = (p[:elem] == :int) ? "Int64" : "String"
    return_type = "#{zig_type}[]@list"
    decl_init   = "MUTABLE lst: #{return_type} = [];"
    return_var  = "lst"
    append      = ->(v) { "    lst.append(#{v});" }
    values      = (1..size).map { |i| p[:elem] == :int ? "#{i}_i64" : %("v#{i}") }
    len_check   = "ASSERT length(result) == #{size}_i64, \"returned length\";"
    first_check = (p[:elem] == :int) ?
                  "ASSERT result[0] == 1_i64, \"first element\";" :
                  'ASSERT eql?(result[0], "v1"), "first element";'
    type_decl   = ""

  when :set_int, :set_string
    zig_type = (p[:elem] == :set_int) ? "Int64" : "String"
    return_type = "#{zig_type}[]@set"
    decl_init   = "MUTABLE s: #{return_type} = Set[];"
    return_var  = "s"
    append      = ->(v) { "    s.insert(#{v});" }
    values      = (1..size).map { |i| p[:elem] == :set_int ? "#{i}_i64" : %("v#{i}") }
    len_check   = "ASSERT result.length() == #{size}_i64, \"returned set length\";"
    first_check = ""  # sets are unordered; length suffices
    type_decl   = ""

  when :pool
    return_type = "Point[100]@pool"
    decl_init   = "MUTABLE p: #{return_type} = [];"
    return_var  = "p"
    append      = ->(_v, i = nil) { i ||= 1; "    pid = p.insert(Point{ x: #{i}.0, y: #{i}.0 });" }
    values      = (1..size).to_a
    len_check   = "ASSERT result.length() == #{size}_i64, \"returned pool length\";"
    first_check = ""
    type_decl   = "STRUCT Point { x: Float64, y: Float64 }\n\n"

  when :map_str
    return_type = "HashMap<Int64>"
    decl_init   = "MUTABLE m: #{return_type} = {};"
    return_var  = "m"
    append      = ->(v) { "    m[#{v[:k]}] = #{v[:val]};" }
    values      = (1..size).map { |i| { k: %("k#{i}"), val: "#{i}_i64" } }
    len_check   = "ASSERT result.length() == #{size}_i64, \"returned map length\";"
    first_check = "ASSERT result[\"k1\"] == 1_i64, \"first map value\";"
    type_decl   = ""

  when :map_int_numeric
    return_type = "Int64[Int64]@map"
    decl_init   = "MUTABLE m: #{return_type} = {};"
    return_var  = "m"
    append      = ->(v) { "    m[#{v[:k]}] = #{v[:val]};" }
    values      = (1..size).map { |i| { k: "#{i}_i64", val: "#{i*10}_i64" } }
    len_check   = "ASSERT result.length() == #{size}_i64, \"returned numeric-map length\";"
    first_check = "ASSERT result[1_i64] == 10_i64, \"first numeric-map value\";"
    type_decl   = ""

  when :struct_with_list
    return_type = "Container"
    decl_init   = "MUTABLE c = Container{ items: [] };"
    return_var  = "c"
    append      = ->(v) { "    c.items.append(#{v});" }
    values      = (1..size).map { |i| "#{i}_i64" }
    len_check   = "ASSERT result.items.length() == #{size}_i64, \"returned struct.items length\";"
    first_check = "ASSERT result.items[0] == 1_i64, \"first items element\";"
    type_decl   = "STRUCT Container { items: Int64[]@list }\n\n"

  when :union_with_heap
    return_type = "Wrap"
    decl_init   = "MUTABLE lst: Int64[]@list = [];"
    return_var  = "Wrap{ Has: lst }"
    append      = ->(v) { "    lst.append(#{v});" }
    values      = (1..size).map { |i| "#{i}_i64" }
    len_check   = <<~CHK.strip
      PARTIAL MATCH result START
        Wrap.Has AS xs -> ASSERT xs.length() == #{size}_i64, "returned union variant length";,
        DEFAULT -> ASSERT 1_i64 == 0_i64, "expected Has variant";
      END
    CHK
    first_check = ""
    type_decl   = "UNION Wrap { Empty, Has: Int64[]@list }\n\n"
  end

  body = case p[:body]
  when :none
    values.each_with_index.map { |v, _| append.call(v) }.join("\n")
  when :loop
    if p[:elem] == :int
      "    FOR i IN (1_i64 ..= #{size}_i64) DO\n        lst.append(i);\n    END"
    else
      values.each_with_index.map { |v, _| append.call(v) }.join("\n")
    end
  when :early_if
    half = (size / 2).clamp(1, size)
    front = values.first(half).map { |v| append.call(v) }.join("\n")
    rest  = values.drop(half).map  { |v| append.call(v) }.join("\n")
    "#{front}\n    IF #{half}_i64 < 0_i64 THEN\n        RETURN #{return_var};\n    END\n#{rest}"
  end

  <<~CHT
    #{type_decl}FN make() RETURNS !#{return_type} ->
        #{decl_init}
    #{body}
        RETURN #{return_var};
    END

    FN main() RETURNS Void ->
        result = make();
        #{len_check}
        #{first_check}
        RETURN;
    END
  CHT
end
