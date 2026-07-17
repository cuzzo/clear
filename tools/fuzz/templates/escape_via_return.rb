# Template: a value escapes via RETURN.
#
# TWO axes, both exhaustive for the "escape via return" scope:
#
#  1. value TYPE  -- elem ∈ {int,string,set,pool,map,struct,union}
#                    crossed with body context + size. Pinned to the
#                    `ident` return shape (RETURN <var>).
#  2. return-expression SHAPE -- the namesake axis. `return_value_is_heap?`
#     branches per AST shape of the returned expression: a bare var, a
#     list/hash literal, a string literal, a concat, a call result, a
#     multi-branch return. Each shape is its own `return_value_is_heap?`
#     case arm; before this expansion only `ident` was ever generated.
#
# The COPY-of-collection-index return shape is marked :compile_error:
# `RETURN COPY x[i]` for a collection element currently lowers COPY to a
# []T slice that does not match the ArrayList return type. Real bug,
# tracked separately.

ESCAPE_VIA_RETURN_CELLS = []

# Axis 1: value type x body x size (return shape pinned to :ident).
# set_int / set_string / pool / map_int_numeric returns are active:
# `RETURNS !T@set` / `!T@pool` mis-lowers -- the Zig return type is
# ArrayList but the value is a Set/Pool (bug #54, also documented in
# return_value_modality's override table, which owns the type-breadth
# axis properly). escape_via_return keeps the WORKING element types for
# body-context coverage and owns the return-SHAPE axis below.
EVR_DEV_ELEMS = [].freeze
[:int, :string,
 :set_int, :set_string,
 :pool, :map_str, :map_int_numeric,
 :struct_with_list, :union_with_heap].each do |elem|
  [:none, :loop, :early_if].each do |body|
    [3, 7].each do |size|
      cell = { elem: elem, body: body, size: size, return_shape: :ident }
      cell[:expected] = :pass if EVR_DEV_ELEMS.include?(elem)
      ESCAPE_VIA_RETURN_CELLS << cell
    end
  end
end

# Axis 2: return-expression shape (the under-tested namesake axis).
[:list_literal, :hash_literal, :str_literal, :concat,
 :call_result, :if_branches,
 :indirect_struct, :indirect_struct_string].each do |shape|
  ESCAPE_VIA_RETURN_CELLS << { return_shape: shape }
end
# COPY of collection fields and indexes is supported; COPY always produces a
# distinct owned value instead of a shallow aggregate alias.
ESCAPE_VIA_RETURN_CELLS << { return_shape: :field_copy }
ESCAPE_VIA_RETURN_CELLS << { return_shape: :index_copy }

# Axis-2 renderer: one self-contained program per return-expression shape.
# Each shape is a distinct `return_value_is_heap?` case arm.
def escape_via_return_shape_cell(shape)
  case shape
  when :list_literal
    <<~CHT
      FN make() RETURNS !Int64[] ->
          RETURN [1_i64, 2_i64, 3_i64];
      END

      FN main() RETURNS Void ->
          result = make();
          ASSERT length(result) == 3_i64, "return list literal";
          RETURN;
      END
    CHT
  when :hash_literal
    <<~CHT
      FN make() RETURNS !HashMap<Int64> ->
          RETURN {};
      END

      FN main() RETURNS Void ->
          result = make();
          ASSERT result.count() == 0_i64, "return hash literal";
          RETURN;
      END
    CHT
  when :str_literal
    <<~CHT
      FN make() RETURNS !String ->
          RETURN COPY "literal";
      END

      FN main() RETURNS Void ->
          result = make();
          ASSERT result == "literal", "return string literal";
          RETURN;
      END
    CHT
  when :concat
    <<~CHT
      FN make(a: String, b: String) RETURNS !String ->
          RETURN a $+ b;
      END

      FN main() RETURNS Void ->
          result = make("he", "llo");
          ASSERT result == "hello", "return concat";
          RETURN;
      END
    CHT
  when :call_result
    <<~CHT
      FN inner() RETURNS !Int64[]@list ->
          MUTABLE xs: Int64[]@list = [];
          &xs.append(9_i64);
          RETURN xs;
      END

      FN make() RETURNS !Int64[]@list ->
          RETURN inner();
      END

      FN main() RETURNS Void ->
          result = make();
          ASSERT result.length() == 1_i64, "return call result";
          RETURN;
      END
    CHT
  when :if_branches
    <<~CHT
      FN make(flag: Bool) RETURNS !Int64[]@list ->
          MUTABLE a: Int64[]@list = [];
          &a.append(1_i64);
          MUTABLE b: Int64[]@list = [];
          &b.append(2_i64);
          &b.append(3_i64);
          IF flag THEN RETURN a; END
          RETURN b;
      END

      FN main() RETURNS Void ->
          r1 = make(TRUE);
          ASSERT r1.length() == 1_i64, "return if-branch then";
          r2 = make(FALSE);
          ASSERT r2.length() == 2_i64, "return if-branch else";
          RETURN;
      END
    CHT
  when :field_copy
    <<~CHT
      STRUCT Holder { items: Int64[]@list }

      FN make() RETURNS !Int64[]@list ->
          MUTABLE xs: Int64[]@list = [];
          &xs.append(3_i64);
          hld = Holder{ items: xs };
          RETURN COPY hld.items;
      END

      FN main() RETURNS Void ->
          result = make();
          ASSERT result.length() == 1_i64, "return field copy";
          RETURN;
      END
    CHT
  when :index_copy
    <<~CHT
      FN make() RETURNS !Int64[]@list ->
          MUTABLE inner: Int64[]@list = [];
          &inner.append(2_i64);
          MUTABLE outer: Int64[][]@list = [];
          &outer.append(inner);
          MUTABLE missing: Int64[]@list = [];
          RETURN COPY (outer[0_i64] OR_ELSE missing);
      END

      FN main() RETURNS Void ->
          result = make();
          ASSERT result.length() == 1_i64, "return index copy";
          RETURN;
      END
    CHT
  when :indirect_struct
    <<~CHT
      STRUCT Cfg { setting: Int64 }

      FN make() RETURNS !Cfg @boxed ->
          cfg = Cfg{ setting: 7_i64 };
          RETURN cfg;
      END

      FN main() RETURNS Void ->
          c = make();
          ASSERT c.setting == 7_i64, "return @boxed struct";
          RETURN;
      END
    CHT
  when :indirect_struct_string
    <<~CHT
      STRUCT Person { name: String }

      FN make() RETURNS !Person @boxed ->
          p = Person{ name: COPY "alice" };
          RETURN p;
      END

      FN main() RETURNS Void ->
          r = make();
          ASSERT r.name == "alice", "return @boxed struct w/ String field";
          RETURN;
      END
    CHT
  end
end

FuzzGenerator.register(:escape_via_return, cells: ESCAPE_VIA_RETURN_CELLS) do |p|
  # Axis 2 dispatch: return-expression-shape cells are self-contained.
  if p[:return_shape] && p[:return_shape] != :ident
    next escape_via_return_shape_cell(p[:return_shape])
  end

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
                  "ASSERT (result[0] OR_ELSE 0_i64) == 1_i64, \"first element\";" :
                  'ASSERT eql?(result[0] OR_ELSE "", "v1"), "first element";'
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
    append      = ->(_v, i = nil) { i ||= 1; "    p.insert(Point{ x: #{i}.0, y: #{i}.0 });" }
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
    return_type = "HashMap<Int64, Int64>"
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
