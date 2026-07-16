# Bounded grammar/semantic/lowering matrix for the intrinsic Map protocol.
# The positive cells run through Zig so comptime MapFacts and hidden allocator
# forwarding are tested for more than one concrete representation.

GENERIC_MAP_PROTOCOL_CELLS = [
  { shape: :string_index },
  { shape: :numeric_methods },
  { shape: :generic_forwarding },
  { shape: :cleanup_value_copy },
  { shape: :nested_projection },
  { shape: :associated_storage_string },
  { shape: :associated_storage_numeric },
  { shape: :optional_capture_method_boundary },
  { shape: :user_protocol_declaration },
  { shape: :concrete_user_protocol_conformance },
  { shape: :generic_user_protocol_conformance },
  { shape: :shared_user_protocol_conformance },
  { shape: :duplicate_user_protocol_requirement, expected: :compile_error },
  { shape: :user_protocol_conformance_mismatch, expected: :compile_error },
  { shape: :associated_storage_wrong_key, expected: :compile_error },
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
  when :associated_storage_string, :associated_storage_numeric
    key_type = p[:shape] == :associated_storage_string ? "String" : "Int64"
    key = p[:shape] == :associated_storage_string ? '"key"' : "7_i64"
    <<~CLEAR
      STRUCT Index<M: Map> { entries: {M::Key}M::Value }
      IMPLEMENTATION Index<M> {
        METHOD store!(MUTABLE self, key: M::Key, value: M::Value) RETURNS !Void ->
          self.entries[key] = COPY value;
        END
        METHOD load(self, key: M::Key) RETURNS !?M::Value ->
          RETURN COPY self.entries[key];
        END
      }
      FN main() RETURNS !Void ->
        MUTABLE index = Index<{#{key_type}}String>{ entries: {} };
        index.store!(#{key}, "value");
        ASSERT index.load(#{key}) OR_ELSE RAISE OR_ELSE "" == "value";
      END
    CLEAR
  when :associated_storage_wrong_key
    {
      source: <<~CLEAR,
        STRUCT Index<M: Map> { entries: {M::Key}Int64 }
        IMPLEMENTATION Index<M> {
          METHOD bad(self) RETURNS ?Int64 -> RETURN self.entries[TRUE]; END
        }
      CLEAR
      error_code: :TYPE_MISMATCH_ASSIGN,
    }
  when :optional_capture_method_boundary
    <<~CLEAR
      STRUCT Holder { key: ?String }
      IMPLEMENTATION Holder {
        METHOD identity(self, key: String) RETURNS String -> RETURN COPY key; END
        METHOD copied(self) RETURNS !?String ->
          current = COPY self.key;
          IF current EXISTS AS key THEN RETURN self.identity(key); END
          RETURN NIL;
        END
      }
      FN main() RETURNS Void ->
        holder = Holder{ key: COPY "key" };
        ASSERT holder.copied() OR_ELSE RAISE OR_ELSE "" == "key";
      END
    CLEAR
  when :user_protocol_declaration
    <<~CLEAR
      PUB PROTOCOL Lookup<Key, Value> {
        METHOD get(self: Self, key: Key) RETURNS !?Value;
        FN clear!(MUTABLE self: Self) RETURNS !Void;
      }
      STRUCT Holder<S: Lookup> { storage: S }
      FN main() RETURNS Void -> PASS END
    CLEAR
  when :concrete_user_protocol_conformance
    <<~CLEAR
      PROTOCOL Sized { METHOD size(self: Self) RETURNS Int64; }
      STRUCT Box { value: Int64 }
      IMPLEMENTATION Sized FOR Box {
        METHOD size(self) RETURNS Int64 -> RETURN self.value; END
      }
      FN measured<S: Sized>(value: S) RETURNS Int64 -> RETURN value.size(); END
      FN main() RETURNS Void -> ASSERT measured(Box{ value: 8_i64 }) == 8_i64; END
    CLEAR
  when :generic_user_protocol_conformance
    <<~CLEAR
      PROTOCOL Lookup<Key, Value> {
        METHOD get(self: Self, key: Key) RETURNS ?Value;
        FN same(left: Self, right: Self) RETURNS Bool;
      }
      STRUCT Store<K, V> { last_key: ?K fallback: ?V marker: Int64 }
      IMPLEMENTATION Lookup<K, V> FOR Store {
        METHOD get(self, key: K) RETURNS ?V -> RETURN NIL; END
        FN same(left: Store<K, V>, right: Store<K, V>) RETURNS Bool ->
          RETURN left.marker == right.marker;
        END
      }
      FN lookup<S: Lookup>(store: S, key: S::Key) RETURNS ?S::Value ->
        RETURN store.get(key);
      END
      FN main() RETURNS Void ->
        store = Store<String, Int64>{ last_key: NIL, fallback: NIL, marker: 1_i64 };
        ASSERT lookup(store, "missing") == NIL;
        ASSERT same(store, Store<String, Int64>{ last_key: NIL, fallback: NIL, marker: 1_i64 });
      END
    CLEAR
  when :shared_user_protocol_conformance
    <<~CLEAR
      PROTOCOL Sized { METHOD size(self: Self) RETURNS Int64; }
      STRUCT Box { value: Int64 }
      IMPLEMENTATION Sized FOR Box {
        METHOD size(self) RETURNS Int64 -> RETURN self.value; END
      }
      FN measured!<S: SHARED Sized>(MUTABLE value: S) RETURNS !Int64 ->
        WITH POLYMORPHIC value AS view { RETURN view.size(); }
        RETURN 0_i64;
      END
      FN main() RETURNS !Void ->
        MUTABLE value = Box{ value: 8_i64 } @shared:locked;
        ASSERT measured!(value) == 8_i64;
      END
    CLEAR
  when :duplicate_user_protocol_requirement
    {
      source: <<~CLEAR,
        PROTOCOL Named {
          METHOD name(self: Self) RETURNS String;
          METHOD name(self: Self) RETURNS String;
        }
      CLEAR
      error_code: :IMPLEMENTATION_DUPLICATE_MEMBER,
    }
  when :user_protocol_conformance_mismatch
    {
      source: <<~CLEAR,
        PROTOCOL Named { METHOD name(self: Self) RETURNS String; }
        STRUCT User { id: Int64 }
        IMPLEMENTATION Named FOR User {
          METHOD name(self) RETURNS Int64 -> RETURN self.id; END
        }
      CLEAR
      error_code: :CONFORMANCE_REQUIREMENTS,
    }
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
