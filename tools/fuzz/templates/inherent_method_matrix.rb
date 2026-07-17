# Owner-scoped METHOD composition. These cells exercise the semantic boundary
# that ordinary free FN never participates in dot lookup, while owner and
# method-local generic binders remain independently scoped.

INHERENT_METHOD_CELLS = [
  { shape: :nongeneric },
  { shape: :owner_generic },
  { shape: :method_generic },
  { shape: :same_name_two_owners },
  { shape: :owner_static_fn },
  { shape: :free_fn_dot, expected: :compile_error },
  { shape: :missing_self, expected: :compile_error },
  { shape: :shadow_owner, expected: :compile_error },
].freeze

FuzzGenerator.register(:inherent_method_matrix, cells: INHERENT_METHOD_CELLS) do |p|
  case p[:shape]
  when :nongeneric
    <<~CLEAR
      STRUCT Item { value: Int64 }
      IMPLEMENTATION Item { METHOD get(self) RETURNS Int64 -> RETURN self.value; END }
      FN main() RETURNS Void -> item = Item{ value: 7_i64 }; ASSERT item.get() == 7_i64; END
    CLEAR
  when :owner_generic
    <<~CLEAR
      STRUCT Box<T> { value: T }
      IMPLEMENTATION Box<T> { METHOD get(self) RETURNS T -> RETURN self.value; END }
      FN main() RETURNS Void -> box = Box<Int64>{ value: 7_i64 }; ASSERT box.get() == 7_i64; END
    CLEAR
  when :method_generic
    <<~CLEAR
      STRUCT Box<T> { value: T }
      IMPLEMENTATION Box<T> {
        METHOD replace<N>(self, value: N) RETURNS Box<N> -> RETURN Box<N>{ value: value }; END
      }
      FN main() RETURNS Void -> box = Box<Int64>{ value: 7_i64 }; ASSERT box.replace("ok").value == "ok"; END
    CLEAR
  when :same_name_two_owners
    <<~CLEAR
      STRUCT Left { value: Int64 }
      STRUCT Right { value: Int64 }
      IMPLEMENTATION Left { METHOD get(self) RETURNS Int64 -> RETURN self.value; END }
      IMPLEMENTATION Right { METHOD get(self) RETURNS Int64 -> RETURN self.value; END }
      FN main() RETURNS Void ->
        left = Left{ value: 3_i64 }; right = Right{ value: 4_i64 };
        ASSERT left.get() + right.get() == 7_i64;
      END
    CLEAR
  when :owner_static_fn
    <<~CLEAR
      STRUCT Item { value: Int64 }
      IMPLEMENTATION Item {
        FN create(value: Int64) RETURNS Item -> RETURN Item{ value: value }; END
        METHOD get(self) RETURNS Int64 -> RETURN self.value; END
      }
      FN main() RETURNS Void -> item = Item::create(7_i64); ASSERT item.get() == 7_i64; END
    CLEAR
  when :free_fn_dot
    {
      source: <<~CLEAR,
        STRUCT Item { value: Int64 }
        FN get(item: Item) RETURNS Int64 -> RETURN item.value; END
        FN main() RETURNS Void -> item = Item{ value: 7_i64 }; ASSERT item.get() == 7_i64; END
      CLEAR
      error_code: :DOT_CALL_REQUIRES_METHOD,
    }
  when :missing_self
    {
      source: <<~CLEAR,
        STRUCT Item { value: Int64 }
        IMPLEMENTATION Item { METHOD get() RETURNS Int64 -> RETURN 7_i64; END }
      CLEAR
      error_code: :IMPLEMENTATION_METHOD_NEEDS_SELF,
    }
  when :shadow_owner
    {
      source: <<~CLEAR,
        STRUCT Box<T> { value: T }
        IMPLEMENTATION Box<T> { METHOD replace<T>(self, value: T) RETURNS T -> RETURN value; END }
      CLEAR
      error_code: :IMPLEMENTATION_MEMBER_SHADOWS_OWNER,
    }
  end
end
