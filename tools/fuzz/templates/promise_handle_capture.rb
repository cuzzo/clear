# Template: plain promise handle captured across a BG boundary.
#
# This covers the affine future-handle case:
#
#   producer = BG { ... }
#   consumer = BG { NEXT producer }
#
# The positive cells ensure the capture is admitted as an ownership transfer.
# The negative cell ensures that transfer consumes the original binding, so a
# later NEXT of the producer in the spawning scope is rejected.

PROMISE_HANDLE_CAPTURE_CELLS = [
  { shape: :single },
  { shape: :single, outer_reuse: true, expected: :compile_error },
  { shape: :relay },
]

FuzzGenerator.register(:promise_handle_capture, cells: PROMISE_HANDLE_CAPTURE_CELLS) do |p|
  case p[:shape]
  when :single
    outer_reuse = p[:outer_reuse] ? "    leaked: Int64 = NEXT producer;\n" : ""
    <<~CHT
      FN main() RETURNS Void ->
          producer: ~Int64 = BG { 40_i64; };
          consumer: ~Int64 = BG {
              v: Int64 = NEXT producer;
              v + 2_i64;
          };
      #{outer_reuse}    result: Int64 = NEXT consumer;
          ASSERT result == 42_i64, "promise handle capture should transfer ownership";
          RETURN;
      END
    CHT
  when :relay
    <<~CHT
      FN main() RETURNS Void ->
          producer: ~Int64 = BG { 7_i64; };
          relay: ~Int64 = BG {
              v: Int64 = NEXT producer;
              v + 1_i64;
          };
          consumer: ~Int64 = BG {
              relay_value: Int64 = NEXT relay;
              relay_value + 1_i64;
          };

          result: Int64 = NEXT consumer;
          ASSERT result == 9_i64, "promise handle relay should transfer ownership";
          RETURN;
      END
    CHT
  end
end
