# Template: stream SELECT selector-ownership matrix.
#
# `push` transfers the selected value into the channel; the consumer owns and
# frees every dequeued item. These cells hold the runtime (leak/double-free)
# guarantee for each selector flavor x consumer fusion:
#   - an owned-producing selector must be MOVED into the push (producer must
#     not free it — double free/segfault when it did);
#   - a borrowing projection must push an independent DEEP COPY and free the
#     dequeued source item (leak when it did not);
#   - identity keeps the item's ownership moving into the push.

STREAM_SELECTOR_CELLS = [
  { selector: :owned_unfused },
  { selector: :owned_fused_each },
  { selector: :projection_unfused },
  { selector: :identity_unfused },
].freeze

FuzzGenerator.register(:stream_selector_matrix, cells: STREAM_SELECTOR_CELLS) do |p|
  case p[:selector]
  when :owned_unfused
    # Producer pushes a fresh owned String; WHILE-NEXT consumer frees it.
    <<~CHT
      FN dup(s: String) RETURNS String -> RETURN COPY s; END

      FN main() RETURNS Void ->
          src: [~]String = BG STREAM {
              a: String = COPY "a";
              b: String = COPY "bb";
              YIELD a;
              YIELD b;
          };
          out: [~]String = src |> SELECT dup(_);
          MUTABLE total = 0_i64;
          WHILE NEXT out EXISTS AS item DO
              total = total + item.length();
          END
          ASSERT total == 3_i64, "owned unfused";
          RETURN;
      END
    CHT

  when :owned_fused_each
    <<~CHT
      FN dup(s: String) RETURNS String -> RETURN COPY s; END

      FN main() RETURNS Void ->
          gen: [~]String = BG STREAM {
              MUTABLE i: Int64 = 0;
              WHILE i < 3 DO
                  YIELD i.toString();
                  i = i + 1;
              END
          };
          MUTABLE n: Int64 = 0;
          gen |> SELECT dup(_) |> EACH { n = n + _.length(); };
          ASSERT n == 3, "owned fused";
          RETURN;
      END
    CHT

  when :projection_unfused
    <<~CHT
      STRUCT User { name: String, id: Int64 }

      FN main() RETURNS Void ->
          users: [~]User = BG STREAM {
              YIELD User{ name: COPY "alice", id: 1 };
              YIELD User{ name: COPY "bo", id: 2 };
          };
          names: [~]String = users |> SELECT _.name;
          MUTABLE lens = 0_i64;
          WHILE NEXT names EXISTS AS nm DO
              lens = lens + nm.length();
          END
          ASSERT lens == 7_i64, "projection unfused";
          RETURN;
      END
    CHT

  when :identity_unfused
    <<~CHT
      FN main() RETURNS Void ->
          src: [~]String = BG STREAM {
              a: String = COPY "xyz";
              YIELD a;
          };
          out: [~]String = src |> SELECT _;
          MUTABLE total = 0_i64;
          WHILE NEXT out EXISTS AS item DO
              total = total + item.length();
          END
          ASSERT total == 3_i64, "identity unfused";
          RETURN;
      END
    CHT
  end
end
