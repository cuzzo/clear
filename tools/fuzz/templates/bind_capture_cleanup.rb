# Template: WHILE-bind / IF-bind capture-cleanup matrix.
#
# Drives CleanupClassifier.walk_capture_bindings: a WHILE-bind or IF-bind
# captures the Some(T) payload of an ownership-transferring call. When T
# needs cleanup (heap string, list, struct-with-heap-field), the captured
# binding inherits a per-iteration / per-branch cleanup contract.
#
# Targets the uncovered each_capture_binding + walk_capture_bindings
# arms in promotion_plan.rb (the WhileBindLoop / IfBind cases, the
# wrapped_type extraction, the elem_zig_type fill).
#
# `form` axis  : :while drains a list via .pop(); :if takes one .pop().
# `elem` axis  : the list element type — each is a distinct cleanup shape.

BIND_CAPTURE_CELLS = []
[:string, :struct, :list].each do |elem|
  [:while, :if].each do |form|
    BIND_CAPTURE_CELLS << { elem: elem, form: form }
  end
end

FuzzGenerator.register(:bind_capture_cleanup, cells: BIND_CAPTURE_CELLS) do |p|
  # Per-element-type wiring: type_decl (extra STRUCT defs), source_type
  # (the `MUTABLE src: <source_type> = []` annotation), push_vals, and an
  # observation on the captured binding.
  type_decl, source_type, push_vals, observe =
    case p[:elem]
    when :string
      ["",
       "String[]@list",
       ['COPY "a"', 'COPY "b"', 'COPY "c"'],
       'ASSERT v.length() >= 0_i64, "captured string";']
    when :struct
      ["STRUCT Item { name: String }\n\n",
       "Item[]@list",
       ['Item{ name: COPY "a" }', 'Item{ name: COPY "b" }', 'Item{ name: COPY "c" }'],
       'ASSERT v.name.length() >= 0_i64, "captured struct";']
    when :list
      ["",
       "Int64[][]@list",
       ['bindCaptureList(1_i64)', 'bindCaptureList(2_i64)', 'bindCaptureList(3_i64)'],
       'ASSERT v.length() == 1_i64, "captured list";']
    end

  helper = if p[:elem] == :list
             <<~CHT
               FN bindCaptureList(n: Int64) RETURNS Int64[]@list ->
                   MUTABLE xs: Int64[]@list = [];
                   xs.append(n);
                   RETURN xs;
               END

             CHT
           else
             ""
           end

  # Build the population block for the source list.
  populate = push_vals.map { |s| "    src.append(#{s});" }.join("\n")

  drain =
    if p[:form] == :while
      <<~DR.chomp
        MUTABLE seen = 0_i64;
            WHILE src.pop() AS v DO
                #{observe}
                seen = seen + 1_i64;
            END
            ASSERT seen == 3_i64, "drained all three";
      DR
    else
      <<~DR.chomp
        IF src.pop() AS v THEN
                #{observe}
            ELSE
                ASSERT FALSE, "expected a popped value";
            END
      DR
    end

  <<~CHT
    #{type_decl}#{helper}FN main() RETURNS Void ->
        MUTABLE src: #{source_type} = [];
    #{populate}
        #{drain}
        RETURN;
    END
  CHT
end
