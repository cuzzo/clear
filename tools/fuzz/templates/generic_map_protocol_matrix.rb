# Bounded grammar/semantic/lowering matrix for the intrinsic Map protocol.
# The positive cells run through Zig so comptime MapFacts and hidden allocator
# forwarding are tested for more than one concrete representation.

GENERIC_MAP_PROTOCOL_CELLS = [
  { shape: :string_index },
  { shape: :numeric_methods },
  { shape: :generic_forwarding },
  { shape: :cleanup_value_copy },
  { shape: :nested_projection },
  { shape: :borrowed_value, expected: :compile_error },
  { shape: :non_map_argument, expected: :compile_error },
  { shape: :non_shared_argument, expected: :compile_error },
  { shape: :unknown_associated_type, expected: :compile_error },
  { shape: :unstable_method, expected: :compile_error },
].freeze

FuzzGenerator.register(:generic_map_protocol_matrix, cells: GENERIC_MAP_PROTOCOL_CELLS) do |p|
  case p[:shape]
  when :string_index
    <<~CLEAR
      FN store!<M: Map>(MUTABLE map: M, key: M::Key, TAKES value: M::Value) RETURNS !Void ->
        map[key] = value;
      END
      FN main() RETURNS !Void ->
        MUTABLE values: {String}Int64 = {};
        store!(values, "x", 7_i64);
        ASSERT values["x"] OR_ELSE 0_i64 == 7_i64;
      END
    CLEAR
  when :numeric_methods
    <<~CLEAR
      FN exercise!<M: Map>(MUTABLE map: M, key: M::Key, TAKES value: M::Value) RETURNS !Void ->
        map.put(key, value);
        ASSERT map.contains?(key);
        ASSERT map.count() == 1_i64;
        map.delete(key);
        ASSERT map.empty?();
      END
      FN main() RETURNS !Void ->
        MUTABLE values: {Int64}Int64 = {};
        exercise!(values, 4_i64, 9_i64);
      END
    CLEAR
  when :generic_forwarding
    <<~CLEAR
      FN inner!<M: Map>(MUTABLE map: M, key: M::Key, TAKES value: M::Value) RETURNS !Void ->
        map[key] = value;
      END
      FN outer!<M: Map>(MUTABLE map: M, key: M::Key, TAKES value: M::Value) RETURNS !Void ->
        inner!(map, key, value);
      END
      FN main() RETURNS !Void ->
        MUTABLE values: {String}Int64 = {};
        outer!(values, "x", 3_i64);
        ASSERT values["x"] OR_ELSE 0_i64 == 3_i64;
      END
    CLEAR
  when :cleanup_value_copy
    <<~CLEAR
      FN copyStore!<M: Map>(MUTABLE map: M, key: M::Key, value: M::Value) RETURNS !Void ->
        map.put(key, COPY value);
      END
      FN main() RETURNS !Void ->
        MUTABLE values: {String}String = {};
        copyStore!(values, "state", "ready");
        ASSERT values["state"] OR_ELSE "" == "ready";
      END
    CLEAR
  when :nested_projection
    <<~CLEAR
      FN projectionShape<M: Map>(keys: [2]M::Key, values: []?M::Value) RETURNS Int64 ->
        RETURN keys.length() + values.length();
      END
      FN main() RETURNS Void -> PASS END
    CLEAR
  when :non_map_argument
    {
      source: <<~CLEAR,
        STRUCT User { id: Int64 }
        STRUCT Cache<M: Map> { values: M }
        FN bad(cache: Cache<User>) RETURNS Void -> PASS END
      CLEAR
      error_code: :GENERIC_PROTOCOL_BOUND_FAILED,
    }
  when :borrowed_value
    {
      source: <<~CLEAR,
        FN invalid!<M: Map>(MUTABLE map: M, key: M::Key, value: M::Value) RETURNS !Void ->
          map[key] = value;
        END
      CLEAR
      error_code: :TAKES_NEEDS_OWNED_BORROW,
    }
  when :non_shared_argument
    {
      source: <<~CLEAR,
        STRUCT Cache<M: SHARED Map> { values: M }
        FN bad(cache: Cache<{String}Int64>) RETURNS Void -> PASS END
      CLEAR
      error_code: :GENERIC_SHARED_BOUND_FAILED,
    }
  when :unknown_associated_type
    {
      source: "FN bad<M: Map>(value: M::Missing) RETURNS Void -> PASS END",
      error_code: :GENERIC_UNKNOWN_ASSOCIATED_TYPE,
    }
  when :unstable_method
    {
      source: "FN bad<M: Map>(map: M) RETURNS Void -> map.keys(); END",
      error_code: :GENERIC_MAP_METHOD_UNKNOWN,
    }
  end
end
