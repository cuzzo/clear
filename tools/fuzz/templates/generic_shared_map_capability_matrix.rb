# Capability families are selected at binding time while the generic body is
# checked once against SHARED Map. Positive cells compile and run through Zig;
# negative cells prove that the synchronization boundary cannot be omitted.

GENERIC_SHARED_MAP_CAPABILITY_CELLS = [
  { family: :locked },
  { family: :write_locked },
  { family: :versioned },
  { family: :sharded },
  { family: :direct_index, expected: :compile_error },
  { family: :direct_method, expected: :compile_error },
  { family: :plain_with, expected: :compile_error },
  { family: :unshared, expected: :compile_error },
].freeze

FuzzGenerator.register(:generic_shared_map_capability_matrix, cells: GENERIC_SHARED_MAP_CAPABILITY_CELLS) do |cell|
  capability = {
    locked: "@shared:locked",
    write_locked: "@shared:writeLocked",
    versioned: "@shared:versioned",
    sharded: "@shared:sharded(2):writeLocked",
  }[cell[:family]]

  if capability
    <<~CLEAR
      STRUCT Cache<M: SHARED Map> { values: M }
      IMPLEMENTATION Cache<M> {
        METHOD put!(MUTABLE self, key: M::Key, TAKES value: M::Value) RETURNS !Void ->
          WITH POLYMORPHIC self.values AS values { values[key] = value; }
        END
      }
      FN main() RETURNS !Void ->
        storage: {String}#{capability} Int64 = {};
        MUTABLE cache = Cache<{String}#{capability} Int64>{ values: storage };
        cache.put!("key", 9_i64);
      END
    CLEAR
  else
    source = case cell[:family]
    when :direct_index
      <<~CLEAR
        FN bad<M: SHARED Map>(map: M, key: M::Key) RETURNS ?M::Value -> RETURN COPY map[key]; END
        FN main() RETURNS Void -> PASS END
      CLEAR
    when :direct_method
      <<~CLEAR
        FN bad<M: SHARED Map>(map: M, key: M::Key) RETURNS Bool -> RETURN map.contains?(key); END
        FN main() RETURNS Void -> PASS END
      CLEAR
    when :plain_with
      <<~CLEAR
        FN bad<M: SHARED Map>(map: M) RETURNS Void -> WITH map AS view { PASS } END
        FN main() RETURNS Void -> PASS END
      CLEAR
    when :unshared
      <<~CLEAR
        STRUCT Cache<M: SHARED Map> { values: M }
        FN bad(cache: Cache<{String}Int64>) RETURNS Void -> PASS END
        FN main() RETURNS Void -> PASS END
      CLEAR
    end
    {
      source: source,
      error_code: cell[:family] == :unshared ? :GENERIC_SHARED_BOUND_FAILED : :GENERIC_SHARED_MAP_REQUIRES_WITH,
    }
  end
end
