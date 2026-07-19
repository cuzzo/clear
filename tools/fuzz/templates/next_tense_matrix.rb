# Template: `NEXT` across inferred future/stream handles and the tense wrappers
# it exposes.  Futures and streams intentionally remain inference-friendly;
# the *result* of NEXT still has to make optional/error handling visible.

NEXT_TENSE_CELLS = [
  { shape: :future },
  { shape: :finite_stream },
  { shape: :finite_optional_item },
  { shape: :finite_fallible_item },
  { shape: :open_stream_optional_item },
  { shape: :implicit_future, expected: :compile_error },
  { shape: :implicit_future_call, expected: :compile_error },
  { shape: :implicit_stream, expected: :compile_error },
  { shape: :implicit_stream_pipeline },
].freeze

FuzzGenerator.register(:next_tense_matrix, cells: NEXT_TENSE_CELLS) do |p|
  case p.fetch(:shape)
  when :future
    <<~CLEAR
      FN main() RETURNS Void ->
        future:~ = BG { 7_i64; };
        value = NEXT future;
        ASSERT value == 7_i64, "inferred ~T handle";
        RETURN;
      END
    CLEAR
  when :finite_stream
    <<~CLEAR
      FN main() RETURNS Void ->
        stream:~ = BG STREAM { YIELD 11_i64; CLOSE; };
        IF NEXT stream EXISTS AS item THEN
          ASSERT item == 11_i64, "inferred [~]T handle";
        ELSE
          ASSERT FALSE, "finite stream yields its item";
        END
        RETURN;
      END
    CLEAR
  when :finite_optional_item
    <<~CLEAR
      FN main() RETURNS Void ->
        stream: [~]?Int64 = BG STREAM YIELDS ?Int64 { YIELD 13_i64; YIELD NIL; CLOSE; };
        IF NEXT stream EXISTS AS item THEN
          IF item EXISTS AS value THEN ASSERT value == 13_i64, "NEXT [~]?T item"; END
        END
        RETURN;
      END
    CLEAR
  when :finite_fallible_item
    <<~CLEAR
      FN main() RETURNS !Void ->
        stream: [~]!Int64 = BG STREAM YIELDS !Int64 { YIELD "17".toInt(); CLOSE; };
        IF NEXT stream EXISTS AS item THEN
          value = TRY item;
          ASSERT value == 17_i64, "NEXT [~]!T item";
        END
        RETURN;
      END
    CLEAR
  when :open_stream_optional_item
    <<~CLEAR
      FN main() RETURNS Void ->
        stream: ~?Int64[] = BG STREAM { YIELD 13_i64; };
        item:? = NEXT stream;
        IF item EXISTS AS value THEN
          ASSERT value == 13_i64, "NEXT ~?T[] retains ?T explicitly";
        ELSE
          ASSERT FALSE, "open stream yields its item";
        END
        RETURN;
      END
    CLEAR
  when :implicit_future
    <<~CLEAR
      FN main() RETURNS Void ->
        future = BG { 17_i64; };
        RETURN;
      END
    CLEAR
  when :implicit_future_call
    <<~CLEAR
      FN identity(value: ~Int64) RETURNS ~Int64 -> RETURN value; END
      FN main() RETURNS Void ->
        source:~ = BG { 18_i64; };
        future = identity(source);
        RETURN;
      END
    CLEAR
  when :implicit_stream
    <<~CLEAR
      FN main() RETURNS Void ->
        stream = BG STREAM { YIELD 19_i64; CLOSE; };
        RETURN;
      END
    CLEAR
  when :implicit_stream_pipeline
    <<~CLEAR
      FN main() RETURNS Void ->
        stream:~ = BG STREAM { YIELD 23_i64; CLOSE; };
        result = stream |> SELECT _ + 1_i64;
        RETURN;
      END
    CLEAR
  else
    raise "unknown NEXT tense shape #{p.inspect}"
  end
end
