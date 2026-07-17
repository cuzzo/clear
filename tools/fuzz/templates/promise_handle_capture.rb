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

PROMISE_HANDLE_CAPTURE_CELLS = []
%i[int string list].each do |value|
  PROMISE_HANDLE_CAPTURE_CELLS << { shape: :single, value: value }
  PROMISE_HANDLE_CAPTURE_CELLS << { shape: :single, value: value, outer_reuse: true, expected: :compile_error }
  PROMISE_HANDLE_CAPTURE_CELLS << { shape: :relay, value: value }
end

def phc_prelude(value)
  value == :list ? "STRUCT Payload { items: Int64[]@list }\n\n" : ""
end

def phc_type(value)
  case value
  when :int then "Int64"
  when :string then "String"
  when :list then "Payload"
  end
end

def phc_producer_body(value)
  case value
  when :int then "40_i64;"
  when :string then "COPY \"forty\";"
  when :list
    "MUTABLE xs: Int64[]@list = [];\n              &xs.append(40_i64);\n              Payload{ items: xs };"
  end
end

def phc_observe_expr(value, var)
  case value
  when :int then "#{var} + 2_i64"
  when :string then "#{var}.length()"
  when :list then "#{var}.items.length() + 1_i64"
  end
end

def phc_expected(value)
  case value
  when :int then "42_i64"
  when :string then "5_i64"
  when :list then "2_i64"
  end
end

FuzzGenerator.register(:promise_handle_capture, cells: PROMISE_HANDLE_CAPTURE_CELLS) do |p|
  ty = phc_type(p[:value])
  prelude = phc_prelude(p[:value])
  case p[:shape]
  when :single
    outer_reuse = p[:outer_reuse] ? "    leaked: #{ty} = NEXT producer;\n" : ""
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          producer: ~#{ty} = BG {
              #{phc_producer_body(p[:value])}
          };
          consumer: ~Int64 = BG {
              v: #{ty} = NEXT producer;
              #{phc_observe_expr(p[:value], 'v')};
          };
      #{outer_reuse}    result: Int64 = NEXT consumer;
          ASSERT result == #{phc_expected(p[:value])}, "promise handle capture should transfer ownership";
          RETURN;
      END
    CHT
  when :relay
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          producer: ~#{ty} = BG {
              #{phc_producer_body(p[:value])}
          };
          relay: ~#{ty} = BG {
              v: #{ty} = NEXT producer;
              v;
          };
          consumer: ~Int64 = BG {
              relay_value: #{ty} = NEXT relay;
              #{phc_observe_expr(p[:value], 'relay_value')};
          };

          result: Int64 = NEXT consumer;
          ASSERT result == #{phc_expected(p[:value])}, "promise handle relay should transfer ownership";
          RETURN;
      END
    CHT
  end
end
