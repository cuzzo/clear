# Template: WHILE-bind / IF-bind capture-cleanup matrix.
#
# Drives CleanupClassifier.walk_capture_bindings: a WHILE-bind or IF-bind
# captures the Some(T) payload of an ownership-transferring call. When T
# needs cleanup (heap string, list, struct-with-heap-field), the captured
# binding inherits a per-iteration / per-branch cleanup contract.
#
# Targets the uncovered each_capture_binding + walk_capture_bindings
# arms in cleanup_classifier.rb (the WhileBindLoop / IfBind cases, the
# wrapped_type extraction, the elem_zig_type fill).
#
# `form` axis  : :while drains a list via .pop(); :if takes one .pop().
# `elem` axis  : the list element type — each is a distinct cleanup shape.

BIND_CAPTURE_CELLS = []
[:string, :struct, :list].each do |elem|
  [:while, :if].each do |form|
    BIND_CAPTURE_CELLS << { family: :owned_payload, elem: elem, form: form }
  end
end

[:multiowned, :shared].each do |ownership|
  [:list_index, :map_index, :pool_index, :optional_var, :optional_field].each do |source|
    BIND_CAPTURE_CELLS << { family: :rc_borrow, ownership: ownership, source: source }
  end
  [:while, :if].each do |form|
    BIND_CAPTURE_CELLS << { family: :rc_pop, ownership: ownership, form: form }
  end
  BIND_CAPTURE_CELLS << { family: :rc_map_values, ownership: ownership }
  BIND_CAPTURE_CELLS << { family: :rc_call, ownership: ownership }
  BIND_CAPTURE_CELLS << { family: :rc_copy, ownership: ownership }
  BIND_CAPTURE_CELLS << { family: :rc_clone, ownership: ownership }
  BIND_CAPTURE_CELLS << { family: :rc_share, ownership: ownership }
  BIND_CAPTURE_CELLS << { family: :rc_multi_bind, ownership: ownership }
end

FuzzGenerator.register(:bind_capture_cleanup, cells: BIND_CAPTURE_CELLS) do |p|
  if p[:family] != :owned_payload
    cap = p[:ownership] == :shared ? "@shared" : "@multiowned"
    type_decl = "STRUCT RefItem { value: Int64 }\n"

    case p[:family]
    when :rc_borrow
      setup, lookup = case p[:source]
                      when :list_index
                        ["MUTABLE source: RefItem#{cap}[]@list = [];\n    source.append(RefItem{ value: 7_i64 } #{cap});", "source[0_i64]"]
                      when :map_index
                        ["MUTABLE source: HashMap<RefItem#{cap}> = {};\n    source[\"item\"] = RefItem{ value: 7_i64 } #{cap};", "source[\"item\"]"]
                      when :pool_index
                        ["MUTABLE source: RefItem#{cap}[4]@pool = [];\n    id = source.insert(RefItem{ value: 7_i64 } #{cap});", "source[id]"]
                      when :optional_var
                        ["MUTABLE source: ?RefItem#{cap} = RefItem{ value: 7_i64 } #{cap};", "source"]
                      when :optional_field
                        type_decl += "STRUCT RefHolder { item: ?RefItem#{cap} }\n"
                        ["MUTABLE source = RefHolder{ item: RefItem{ value: 7_i64 } #{cap} };", "source.item"]
                      end

      <<~CHT
        #{type_decl}
        FN main() RETURNS Void ->
            #{setup}
            IF #{lookup} AS item THEN ASSERT item.value == 7_i64, "first borrowed bind"; END
            IF #{lookup} AS item THEN ASSERT item.value == 7_i64, "owner survived bind"; END
            RETURN;
        END
      CHT
    when :rc_pop
      bind = if p[:form] == :while
        <<~CLEAR.chomp
          MUTABLE total = 0_i64;
              WHILE source.pop() AS item DO total += item.value; END
              ASSERT total == 15_i64, "owned RC pop cleanup";
        CLEAR
      else
        <<~CLEAR.chomp
          IF source.pop() AS item THEN ASSERT item.value == 8_i64, "owned RC pop cleanup";
              ELSE ASSERT FALSE, "expected RC item"; END
        CLEAR
      end
      <<~CHT
        #{type_decl}
        FN main() RETURNS Void ->
            MUTABLE source: RefItem#{cap}[]@list = [];
            source.append(RefItem{ value: 7_i64 } #{cap});
            source.append(RefItem{ value: 8_i64 } #{cap});
            #{bind}
            RETURN;
        END
      CHT
    when :rc_map_values
      <<~CHT
        #{type_decl}
        FN main() RETURNS Void ->
            MUTABLE source: HashMap<RefItem#{cap}> = {};
            source["item"] = RefItem{ value: 7_i64 } #{cap};
            values = source.values();
            ASSERT values[0_i64]?.value == 7_i64, "materialized RC map values";
            IF source["item"] AS item THEN ASSERT item.value == 7_i64, "map retained owner"; END
            RETURN;
        END
      CHT
    when :rc_call
      <<~CHT
        #{type_decl}
        FN makeRef(flag: Bool) RETURNS ?RefItem#{cap} ->
            IF flag THEN RETURN RefItem{ value: 7_i64 } #{cap}; END
            RETURN NIL;
        END
        FN main() RETURNS Void ->
            IF makeRef(TRUE) AS item THEN ASSERT item.value == 7_i64, "owned optional call bind"; END
            RETURN;
        END
      CHT
    when :rc_copy
      <<~CHT
        #{type_decl}
        FN main() RETURNS Void ->
            MUTABLE source: ?RefItem#{cap} = RefItem{ value: 7_i64 } #{cap};
            IF COPY source AS item THEN ASSERT item.value == 7_i64, "owned optional COPY bind"; END
            IF source AS item THEN ASSERT item.value == 7_i64, "COPY retained source owner"; END
            RETURN;
        END
      CHT
    when :rc_clone
      <<~CHT
        #{type_decl}
        FN main() RETURNS Void ->
            source: ?RefItem#{cap} = RefItem{ value: 7_i64 } #{cap};
            IF CLONE source AS item THEN ASSERT item.value == 7_i64, "owned optional CLONE bind"; END
            IF source AS item THEN ASSERT item.value == 7_i64, "CLONE retained source owner"; END
            RETURN;
        END
      CHT
    when :rc_share
      <<~CHT
        #{type_decl}
        FN main() RETURNS Void ->
            source: ?RefItem#{cap} = RefItem{ value: 7_i64 } #{cap};
            IF SHARE source AS item THEN ASSERT item.value == 7_i64, "owned optional SHARE bind"; END
            RETURN;
        END
      CHT
    when :rc_multi_bind
      <<~CHT
        #{type_decl}
        FN main() RETURNS Void ->
            MUTABLE left: ?RefItem#{cap} = RefItem{ value: 7_i64 } #{cap};
            MUTABLE right: ?RefItem#{cap} = RefItem{ value: 8_i64 } #{cap};
            IF (left AS l) AND (right AS r) THEN ASSERT l.value + r.value == 15_i64, "borrowed multi-bind"; END
            IF (left AS l) AND (right AS r) THEN ASSERT l.value + r.value == 15_i64, "owners survived multi-bind"; END
            RETURN;
        END
      CHT
    end
  else
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
end
