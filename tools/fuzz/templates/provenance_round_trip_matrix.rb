# Template: provenance round-trip matrix.
#
# Every value in CLEAR lowers to the same Zig representation regardless of who
# owns it -- an owned String, a `@rodata` literal, a `String@symbol`, and a
# borrow into a container are all []const u8. Ownership is therefore a fact the
# compiler must CARRY, and the recurring failure is a site that re-derives it
# from expression shape and gets it wrong: a view given an owning cleanup, so
# storage someone else still owns is freed.
#
# Six of the eleven bugs the self-hosting effort surfaced were that one
# mistake wearing different hats -- a map read, a rodata list, a symbol union
# payload, an optional unwrap, a struct field, an extern borrow. Nothing in the
# corpus read a non-Copy value back OUT of a container and let it drop, which is
# the shape they all share.
#
# Axes:
#   provenance -- what the value actually is, and therefore who may free it;
#   container  -- what it is read back out of;
#   exit       -- how it leaves, since each exit picks a different lowering path
#                 (plain bind, returned through a frame boundary, read twice so
#                 the second read sees whatever the first one left behind).
#
# A cell that frees a static or a borrow shows up as an arena free check panic,
# a double free, or a leak; one that drops a cleanup it owed shows up as a leak.

# `symbol` is an axis again: a `String@symbol` is now CheatLib.Symbol, a
# distinct type whose drop is a no-op, so "is this element the container's to
# free" has one answer everywhere instead of three.
PROVENANCE_ROUND_TRIP_CELLS = []
%i[owned rodata symbol].each do |provenance|
  %i[map list struct_field optional].each do |container|
    %i[bind_drop return_it reread].each do |exit_shape|
      PROVENANCE_ROUND_TRIP_CELLS << {
        provenance: provenance,
        container: container,
        exit: exit_shape,
      }
    end
  end
end

FuzzGenerator.register(:provenance_round_trip_matrix, cells: PROVENANCE_ROUND_TRIP_CELLS) do |p|
  # The element type and the expression that produces one. `@symbol` and a bare
  # literal are static: freeing either is invalid. `COPY` makes an owned heap
  # string that MUST be freed exactly once.
  elem_type, make_value, expected = case p[:provenance]
  when :owned  then ["String", 'COPY "alpha"', '"alpha"']
  # A bare literal IS the rodata case: same `String` type as the owned one, no
  # COPY, so nothing was allocated and nothing may be freed. The provenance is
  # the value's history, not a spelling on the type.
  when :rodata then ["String", '"alpha"', '"alpha"']
  when :symbol then ["String@symbol", ':alpha', ':alpha']
  end

  # Build the container and the expression that reads one value back out.
  setup, read_expr, read_again = case p[:container]
  when :map
    ["MUTABLE holder: {String}#{elem_type} = {};\n    holder[\"k\"] = #{make_value};",
     'holder["k"]', 'holder["k"]']
  when :list
    ["MUTABLE holder: []#{elem_type} = [];\n    &holder.append(#{make_value});",
     "holder[0]", "holder[0]"]
  when :struct_field
    ["MUTABLE holder = Wrapper{ slot: #{make_value} };",
     "holder.slot", "holder.slot"]
  when :optional
    ["MUTABLE holder: ?#{elem_type} = #{make_value};",
     "holder", "holder"]
  end

  wrapper_def = p[:container] == :struct_field ? "STRUCT Wrapper { slot: #{elem_type} }\n\n" : ""

  # An optional container yields `?T` from every read; the others yield `?T`
  # only for map/list indexing. A struct field is always present.
  optional_read = %i[map list optional].include?(p[:container])
  bind = optional_read ? "UNWRAP (#{read_expr})" : read_expr
  bind_again = optional_read ? "UNWRAP (#{read_again})" : read_again

  body = case p[:exit]
  when :bind_drop
    # Bind it and let the binding go out of scope. If the read handed back a
    # view and the binding claimed ownership, this frees the container's value.
    <<~BODY.chomp
      MUTABLE seen: #{elem_type} = #{bind};
          ASSERT seen == #{expected}, "round-tripped value is intact";
    BODY
  when :return_it
    # Out through a frame boundary: a frame-allocated view cannot escape, and a
    # borrow returned as owned dangles once the frame rewinds.
    <<~BODY.chomp
      MUTABLE seen: #{elem_type} = escape();
          ASSERT seen == #{expected}, "returned value survives its frame";
    BODY
  when :reread
    # Read twice. The first read is what frees a container-owned value; the
    # second is what observes the damage -- exactly how the const rule-index
    # bug presented, where one lookup poisoned every later one.
    <<~BODY.chomp
      MUTABLE first: #{elem_type} = #{bind};
          ASSERT first == #{expected}, "first read is intact";
          MUTABLE second: #{elem_type} = #{bind_again};
          ASSERT second == #{expected}, "second read sees what the first left";
    BODY
  end

  if p[:exit] == :return_it
    <<~CHT
      #{wrapper_def}FN escape() RETURNS #{elem_type} ->
          #{setup}
          RETURN #{bind};
      END

      FN main() RETURNS Void ->
          #{body}
      END
    CHT
  else
    <<~CHT
      #{wrapper_def}FN main() RETURNS Void ->
          #{setup}
          #{body}
      END
    CHT
  end
end
