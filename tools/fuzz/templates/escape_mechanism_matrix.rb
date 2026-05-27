# Template: direct AST-bound escape mechanisms.
#
# The broader modality templates cover deep value-shape matrices for return,
# TAKES, struct-field store, and list append. This template owns the missing
# mechanism axis: every AST shape that can make a binding escape its declaring
# frame should have at least one end-to-end fuzz cell.

ESCAPE_MECHANISM_CELLS = [
  { mechanism: :return_string },
  { mechanism: :return_list },
  { mechanism: :yield_string_stream },
  { mechanism: :bg_capture_string },
  { mechanism: :bg_stream_capture_outer },
  { mechanism: :outer_assignment_loop },
  { mechanism: :outer_field_store_loop },
  { mechanism: :outer_index_store_loop },
  { mechanism: :list_append_loop },
  { mechanism: :set_insert_loop },
  { mechanism: :map_put_loop },
  { mechanism: :pool_insert_loop },
  { mechanism: :collection_literal_return },
  { mechanism: :function_arg },
  { mechanism: :takes_arg },
  { mechanism: :give_arg },
  { mechanism: :call_return_receiver },
  { mechanism: :or_rescue_return_receiver },
  { mechanism: :return_nested_struct_list },
  { mechanism: :return_recursive_union_payload },
  { mechanism: :outer_store_nested_array },
  { mechanism: :bg_capture_recursive_aggregate },
  { mechanism: :do_capture_string },
  { mechanism: :takes_recursive_aggregate },
  { mechanism: :loop_carry_nested_map },
].freeze

FuzzGenerator.register(:escape_mechanism_matrix, cells: ESCAPE_MECHANISM_CELLS) do |p|
  case p[:mechanism]
  when :return_string
    <<~CHT
      FN mk() RETURNS !String ->
          s: String = COPY "abc";
          RETURN s;
      END

      FN main() RETURNS Void ->
          out: String = mk() OR RAISE;
          ASSERT out.length() == 3_i64, "return string";
          RETURN;
      END
    CHT

  when :return_list
    <<~CHT
      FN mk() RETURNS !Int64[]@list ->
          MUTABLE xs: Int64[]@list = [];
          xs.append(1_i64);
          RETURN xs;
      END

      FN main() RETURNS Void ->
          out: Int64[]@list = mk() OR RAISE;
          ASSERT out.length() == 1_i64, "return list";
          RETURN;
      END
    CHT

  when :yield_string_stream
    <<~CHT
      FN main() RETURNS Void ->
          s: ~String[INF] = BG STREAM {
              x: String = COPY "abc";
              WHILE TRUE DO YIELD COPY x; END
          };
          out: String = NEXT s;
          ASSERT out.length() == 3_i64, "yield string stream";
          RETURN;
      END
    CHT

  when :bg_capture_string
    <<~CHT
      FN main() RETURNS Void ->
          s: String = COPY "abc";
          f: ~Int64 = BG { s.length(); };
          n: Int64 = NEXT f;
          ASSERT n == 3_i64, "bg capture string";
          RETURN;
      END
    CHT

  when :bg_stream_capture_outer
    <<~CHT
      FN main() RETURNS Void ->
          s: String = COPY "abc";
          st: ~String[INF] = BG STREAM {
              WHILE TRUE DO YIELD COPY s; END
          };
          out: String = NEXT st;
          ASSERT out.length() == 3_i64, "bg stream capture outer";
          RETURN;
      END
    CHT

  when :outer_assignment_loop
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE out: String = COPY "";
          FOR i IN (1_i64 ..= 3_i64) DO
              s: String = i.toString();
              out = s;
          END
          ASSERT out.length() == 1_i64, "outer assignment";
          RETURN;
      END
    CHT

  when :outer_field_store_loop
    <<~CHT
      STRUCT Box { value: String }

      FN main() RETURNS Void ->
          MUTABLE box: Box = Box{ value: COPY "" };
          FOR i IN (1_i64 ..= 3_i64) DO
              s: String = i.toString();
              box.value = s;
          END
          ASSERT box.value.length() == 1_i64, "outer field store";
          RETURN;
      END
    CHT

  when :outer_index_store_loop
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE xs: String[]@list = [];
          xs.append(COPY "seed");
          FOR i IN (1_i64 ..= 3_i64) DO
              s: String = i.toString();
              xs[0_i64] = s;
          END
          ASSERT xs[0_i64].length() == 1_i64, "outer index store";
          RETURN;
      END
    CHT

  when :list_append_loop
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE xs: Int64[][]@list = [];
          FOR i IN (1_i64 ..= 3_i64) DO
              MUTABLE inner: Int64[]@list = [];
              inner.append(i);
              xs.append(inner);
          END
          ASSERT xs.length() == 3_i64, "list append";
          RETURN;
      END
    CHT

  when :set_insert_loop
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE xs: String[]@set = [];
          FOR i IN (1_i64 ..= 3_i64) DO
              s: String = i.toString();
              xs.insert(s);
          END
          ASSERT xs.length() == 3_i64, "set insert";
          RETURN;
      END
    CHT

  when :map_put_loop
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE xs: HashMap<String> = {};
          FOR i IN (1_i64 ..= 3_i64) DO
              s: String = i.toString();
              xs[i.toString()] = s;
          END
          ASSERT xs.count() == 3_i64, "map put";
          RETURN;
      END
    CHT

  when :pool_insert_loop
    <<~CHT
      STRUCT Item { value: String }

      FN main() RETURNS Void ->
          MUTABLE pool: Item[8]@pool = [];
          FOR i IN (1_i64 ..= 3_i64) DO
              s: String = i.toString();
              _ = pool.insert(Item{ value: COPY s });
          END
          ASSERT pool.length() == 3_i64, "pool insert";
          RETURN;
      END
    CHT

  when :collection_literal_return
    <<~CHT
      FN mk() RETURNS !String[] ->
          s: String = COPY "abc";
          RETURN [s];
      END

      FN main() RETURNS Void ->
          xs: String[] = mk() OR RAISE;
          ASSERT xs[0_i64].length() == 3_i64, "collection literal return";
          RETURN;
      END
    CHT

  when :function_arg
    <<~CHT
      FN len(s: String) RETURNS Int64 -> RETURN s.length(); END

      FN main() RETURNS Void ->
          s: String = COPY "abc";
          n: Int64 = len(s);
          ASSERT n == 3_i64, "function arg";
          RETURN;
      END
    CHT

  when :takes_arg
    <<~CHT
      FN len(TAKES s: String) RETURNS Int64 -> RETURN s.length(); END

      FN main() RETURNS Void ->
          s: String = COPY "abc";
          n: Int64 = len(s);
          ASSERT n == 3_i64, "takes arg";
          RETURN;
      END
    CHT

  when :give_arg
    <<~CHT
      FN len(TAKES s: String) RETURNS Int64 -> RETURN s.length(); END

      FN main() RETURNS Void ->
          s: String = COPY "abc";
          n: Int64 = len(GIVE s);
          ASSERT n == 3_i64, "give arg";
          RETURN;
      END
    CHT

  when :call_return_receiver
    <<~CHT
      FN mk() RETURNS !String ->
          s: String = COPY "abc";
          RETURN s;
      END

      FN main() RETURNS Void ->
          MUTABLE xs: String[]@list = [];
          out: String = mk() OR RAISE;
          xs.append(out);
          ASSERT xs[0_i64].length() == 3_i64, "call return receiver";
          RETURN;
      END
    CHT

  when :or_rescue_return_receiver
    <<~CHT
      FN mk() RETURNS !String ->
          s: String = COPY "abc";
          RETURN s;
      END

      FN main() RETURNS Void ->
          MUTABLE xs: String[]@list = [];
          out: String = mk() OR COPY "fallback";
          xs.append(out);
          ASSERT xs[0_i64].length() == 3_i64, "or rescue return receiver";
          RETURN;
      END
    CHT
  when :return_nested_struct_list
    <<~CHT
      STRUCT Inner { name: String }
      STRUCT Outer { items: Inner[]@list }

      FN mk() RETURNS !Outer ->
          MUTABLE xs: Inner[]@list = [];
          xs.append(Inner{ name: COPY "abc" });
          out = Outer{ items: xs };
          RETURN out;
      END

      FN main() RETURNS Void ->
          out: Outer = mk() OR RAISE;
          ASSERT out.items[0_i64].name.length() == 3_i64, "return nested struct list";
          RETURN;
      END
    CHT

  when :return_recursive_union_payload
    <<~CHT
      UNION Node { Nil, One: String, Pair { left: Node @indirect, right: Node @indirect } }

      FN mk() RETURNS !Node ->
          left = Node{ One: COPY "a" };
          right = Node{ One: COPY "b" };
          RETURN Node.Pair{ left: left, right: right };
      END

      FN main() RETURNS Void ->
          n: Node = mk() OR RAISE;
          PARTIAL MATCH n START
              Node.Pair AS p -> ASSERT TRUE, "recursive pair returned";,
              DEFAULT -> ASSERT FALSE, "expected recursive pair";
          END
          RETURN;
      END
    CHT

  when :outer_store_nested_array
    <<~CHT
      STRUCT Box { vals: String[] }

      FN main() RETURNS Void ->
          MUTABLE out: Box[]@list = [];
          FOR i IN (1_i64 ..= 3_i64) DO
              s: String = i.toString();
              b = Box{ vals: [s] };
              out.append(b);
          END
          ASSERT out[2_i64].vals[0_i64].length() == 1_i64, "outer store nested array";
          RETURN;
      END
    CHT

  when :bg_capture_recursive_aggregate
    <<~CHT
      STRUCT Item { label: String }
      STRUCT Holder { items: Item[]@list }

      FN main() RETURNS Void ->
          MUTABLE xs: Item[]@list = [];
          xs.append(Item{ label: COPY "abc" });
          h = Holder{ items: xs };
          f: ~Int64 = BG { h.items[0_i64].label.length(); };
          ASSERT (NEXT f) == 3_i64, "bg capture recursive aggregate";
          RETURN;
      END
    CHT

  when :do_capture_string
    <<~CHT
      FN touch(n: Int64) RETURNS Void -> RETURN; END

      FN main() RETURNS Void ->
          s: String = COPY "abc";
          DO {
              touch(s.length()),
              touch((COPY s).length())
          }
          RETURN;
      END
    CHT

  when :takes_recursive_aggregate
    <<~CHT
      STRUCT Item { label: String }
      STRUCT Holder { items: Item[]@list }

      FN consume(TAKES h: Holder) RETURNS Int64 ->
          RETURN h.items[0_i64].label.length();
      END

      FN main() RETURNS Void ->
          MUTABLE xs: Item[]@list = [];
          xs.append(Item{ label: COPY "abc" });
          h = Holder{ items: xs };
          ASSERT consume(GIVE h) == 3_i64, "takes recursive aggregate";
          RETURN;
      END
    CHT

  when :loop_carry_nested_map
    <<~CHT
      STRUCT Holder { table: HashMap<String> }

      FN main() RETURNS Void ->
          MUTABLE out: Holder[]@list = [];
          FOR i IN (1_i64 ..= 3_i64) DO
              s: String = i.toString();
              h = Holder{ table: { "k": s } };
              out.append(h);
          END
          ASSERT (out[1_i64].table["k"] OR "").length() == 1_i64, "loop carry nested map";
          RETURN;
      END
    CHT
  end
end
