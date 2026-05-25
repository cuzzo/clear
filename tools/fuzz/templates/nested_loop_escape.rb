# Template: a loop-LOCAL collection escapes into an outer collection.
# Stresses the loop-frame promotion path (commit 9fa21926: "cover escaping
# frame collections in loops"). Pre-fix, only loop-local Strings were
# promoted to heap on escape; lists/maps/arrays leaked or UAF'd.
#
# Pattern:
#   MUTABLE outer: <wrap-type>[]@list = [];
#   FOR ... DO
#       MUTABLE inner: Int64[]@list = [];   # loop-local, frame
#       inner.append(...);
#       outer.append(<wrap inner>);         # escape -> must heap-promote
#   END
#
# The `wrap_kind` axis captures HOW the inner collection is presented to the
# outer container's mutator:
#   :bare         -> outer.append(inner)
#   :struct_field -> outer.append(Item{ data: inner })
#   :union_payload-> outer.append(Item.Some(inner))
#
# `:bare` was the only shape exercised before; the docs/agents/bug9-forensic.md
# investigation found that both the struct- and union-wrapped escapes evade
# escape analysis (the walkers each catch only half the AST shape). Today the
# new wrapped cells fail by design; once the walkers are unified they should
# all pass.

NESTED_LOOP_ESCAPE_CELLS = []

[:list, :array, :set, :map].each do |inner_kind|
  [:while, :for].each do |loop_kind|
    [1, 3].each do |outer_iters|
      [:bare, :struct_field, :union_payload].each do |wrap_kind|
        cell = {
          inner_kind: inner_kind,
          loop_kind: loop_kind,
          iters: outer_iters,
          wrap_kind: wrap_kind,
        }
        cell[:expected] = :compile_error if wrap_kind == :bare && [:list, :set].include?(inner_kind)
        NESTED_LOOP_ESCAPE_CELLS << cell
      end
    end
  end
end

FuzzGenerator.register(:nested_loop_escape, cells: NESTED_LOOP_ESCAPE_CELLS) do |p|
  decls = []
  inner_type = case p[:inner_kind]
               when :list then "Int64[]@list"
               when :array then "Int64[]"
               when :set then "Int64[]@set"
               when :map then "HashMap<Int64>"
               end
  outer_elem_type =
    case p[:wrap_kind]
    when :bare          then inner_type
    when :struct_field  then "Item"
    when :union_payload then "Item"
    end

  case p[:wrap_kind]
  when :struct_field
    decls << "STRUCT Item { data: #{inner_type} }"
  when :union_payload
    decls << "UNION Item { None, Some: #{inner_type} }"
  end

  outer_decl = "MUTABLE outer: #{outer_elem_type}[]@list = [];"

  # The escape expression — what we hand to outer.append(...).
  append_arg =
    case p[:wrap_kind]
    when :bare          then "inner"
    when :struct_field  then "Item{ data: inner }"
    when :union_payload then "Item{ Some: inner }"
    end

  inner_block =
    case p[:inner_kind]
    when :list
      <<~BODY.chomp
                MUTABLE inner: Int64[]@list = [];
                inner.append(i);
                inner.append(i + 1_i64);
                outer.append(#{append_arg});
      BODY
    when :array
      <<~BODY.chomp
                inner: Int64[] = [i, i + 1_i64];
                outer.append(#{append_arg});
      BODY
    when :set
      <<~BODY.chomp
                MUTABLE inner: Int64[]@set = [];
                inner.insert(i);
                inner.insert(i + 1_i64);
                outer.append(#{append_arg});
      BODY
    when :map
      <<~BODY.chomp
                MUTABLE inner: HashMap<Int64> = {};
                inner["a"] = i;
                inner["b"] = i + 1_i64;
                outer.append(#{append_arg});
      BODY
    end

  loop_block =
    case p[:loop_kind]
    when :while
      <<~LOOP.chomp
            MUTABLE i: Int64 = 0_i64;
            WHILE i < #{p[:iters]}_i64 DO
        #{inner_block}
                i = i + 1_i64;
            END
      LOOP
    when :for
      <<~LOOP.chomp
            FOR i IN (0_i64 ..< #{p[:iters]}_i64) DO
        #{inner_block}
            END
      LOOP
    end

  # Element reader for the assertions: walk past the wrapping shape.
  first_inner_len =
    case p[:wrap_kind]
    when :bare
      p[:inner_kind] == :map ? "outer[0_i64].count()" : "length(outer[0_i64])"
    when :struct_field
      p[:inner_kind] == :map ? "outer[0_i64].data.count()" : "length(outer[0_i64].data)"
    when :union_payload then "2_i64"
    end

  first_inner_elem =
    case p[:wrap_kind]
    when :bare
      p[:inner_kind] == :map ? "0_i64" : "outer[0_i64][0_i64]"
    when :struct_field
      p[:inner_kind] == :map ? "0_i64" : "outer[0_i64].data[0_i64]"
    when :union_payload then "0_i64"
    end

  decl_block = decls.empty? ? "" : decls.join("\n") + "\n\n"

  <<~CHT
    #{decl_block}FN main() RETURNS Void ->
        #{outer_decl}
    #{loop_block}
        ASSERT length(outer) == #{p[:iters]}_i64, "outer list length";
        ASSERT #{first_inner_len} == 2_i64, "first inner length";
        ASSERT #{first_inner_elem} == 0_i64, "first inner first element";
        RETURN;
    END
  CHT
end
