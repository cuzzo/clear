# Template: target-resolved C scalar aliases inside ordinary CLEAR collections,
# plus the non-owning foreign pointer/view boundary.

C_FFI_TARGET_TYPES = [
  ["TargetInt", "1"], ["TargetUInt", "1"],
  ["TargetLong", "1"], ["TargetULong", "1"],
  ["TargetLongLong", "1"], ["TargetULongLong", "1"],
  ["TargetUInt@size", "1"], ["TargetInt@size", "1"],
].freeze

C_FFI_TYPE_CELLS = C_FFI_TARGET_TYPES.product(%i[fixed list pool set map stream]).map do |(type, literal), collection|
  { type: type, literal: literal, collection: collection }
end
C_FFI_TYPE_CELLS.concat([
  { foreign: :bounded_view, expected: :pass },
  { foreign: :direct_index, expected: :compile_error },
  { foreign: :safe_view, expected: :compile_error },
  { foreign: :legacy_method_view, expected: :compile_error },
  { foreign: :invalid_length, expected: :compile_error },
  { foreign: :escaping_view, expected: :compile_error },
])
C_FFI_TYPE_CELLS.freeze

FuzzGenerator.register(:c_ffi_type_matrix, cells: C_FFI_TYPE_CELLS) do |p|
  if p[:foreign] == :bounded_view
    next <<~CLEAR
      FN first(values: []@c Int64, count: TargetUInt@size) RETURNS Int64 ->
        WITH UNSAFE VIEW values LENGTH count AS bounded {
          RETURN bounded[0_i64] OR_ELSE 0_i64;
        }
      END

      FN main() RETURNS Void -> RETURN; END
    CLEAR
  end
  if p[:foreign] == :direct_index
    next <<~CLEAR
      FN invalid(values: []@c Int64) RETURNS Int64 ->
        RETURN values[0_i64] OR_ELSE 0_i64;
      END

      FN main() RETURNS Void -> RETURN; END
    CLEAR
  end
  if p[:foreign] == :safe_view
    next <<~CLEAR
      FN invalid(values: []@c Int64) RETURNS Void ->
        WITH VIEW values AS bounded {
          _ = bounded.length();
        }
        RETURN;
      END

      FN main() RETURNS Void -> RETURN; END
    CLEAR
  end
  if p[:foreign] == :legacy_method_view
    next <<~CLEAR
      FN invalid(values: []@c Int64, count: TargetUInt@size) RETURNS Int64 ->
        RETURN values.view(count)[0_i64] OR_ELSE 0_i64;
      END

      FN main() RETURNS Void -> RETURN; END
    CLEAR
  end
  if p[:foreign] == :invalid_length
    next <<~CLEAR
      FN invalid(values: []@c Int64) RETURNS Void ->
        WITH UNSAFE VIEW values LENGTH "unknown" AS bounded {
          _ = bounded.length();
        }
        RETURN;
      END

      FN main() RETURNS Void -> RETURN; END
    CLEAR
  end
  if p[:foreign] == :escaping_view
    next <<~CLEAR
      FN invalid(values: []@c Int64, count: TargetUInt@size) RETURNS Int64[] ->
        WITH UNSAFE VIEW values LENGTH count AS bounded {
          RETURN bounded;
        }
      END

      FN main() RETURNS Void -> RETURN; END
    CLEAR
  end

  type = p.fetch(:type)
  value = p.fetch(:literal)
  body = case p.fetch(:collection)
  when :fixed
    "values: [2]#{type} = [#{value}, #{value}]; ASSERT values[1_i64] == #{value}, \"target fixed\";"
  when :list
    "MUTABLE values: [List]#{type} = List[]; &values.append(#{value}); ASSERT values.length() == 1_i64, \"target list\";"
  when :pool
    "MUTABLE values: [Pool(2)]#{type} = Pool[]; &values.insert(#{value}); ASSERT values.length() == 1_i64, \"target pool\";"
  when :set
    "MUTABLE values: [Set]#{type} = Set[]; &values.insert(#{value}); ASSERT values.contains?(#{value}), \"target set\";"
  when :map
    "MUTABLE values: {String}#{type} = {}; values[\"value\"] = #{value}; ASSERT (values[\"value\"] OR_ELSE 0) == #{value}, \"target map\";"
  when :stream
    "values: [~]#{type} = BG STREAM { YIELD #{value}; CLOSE; }; IF NEXT values EXISTS AS item THEN ASSERT item == #{value}, \"target stream\"; ELSE ASSERT FALSE, \"target stream item exists\"; END"
  else
    raise "unknown C FFI collection #{p.inspect}"
  end

  <<~CLEAR
    FN main() RETURNS Void ->
      #{body}
      RETURN;
    END
  CLEAR
end
