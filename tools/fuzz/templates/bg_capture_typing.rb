# COPY of a captured binding into a BG fiber, across
# {source-origin x collection-shape x elem}. All cells positive.

BG_CAPTURE_TYPING_CELLS = []

[:int, :string].each do |elem|
  [:local, :param].each do |origin|
    [:bare_list, :struct_field].each do |shape|
      BG_CAPTURE_TYPING_CELLS << { elem: elem, origin: origin, shape: shape }
    end
  end
end

FuzzGenerator.register(:bg_capture_typing, cells: BG_CAPTURE_TYPING_CELLS) do |p|
  zig = (p[:elem] == :int) ? "Int64" : "String"
  list_t = "#{zig}[]@list"
  push = (p[:elem] == :int) ? "1_i64" : '"a"'

  if p[:shape] == :bare_list
    consume = "FN consume(xs: #{list_t}) RETURNS Int64 -> RETURN xs.length(); END"
    ctor    = "MUTABLE c0: #{list_t} = List[];\n        c0.append(#{push});"
    if p[:origin] == :local
      body = <<~CHT.chomp
        FN runit() RETURNS !Int64 ->
            #{ctor}
            f: ~Int64 = BG { consume(COPY c0); };
            RETURN NEXT f;
        END
      CHT
      call = "runit() OR RAISE"
    else
      body = <<~CHT.chomp
        FN runit(ops: #{list_t}) RETURNS !Int64 ->
            f: ~Int64 = BG { consume(COPY ops); };
            RETURN NEXT f;
        END
      CHT
      call = "{ #{ctor}\n        n = runit(GIVE c0) OR RAISE; }"
    end
  else # :struct_field -- struct with a nested @list field
    consume = "STRUCT Bag { items: #{list_t} }\n    FN consume(b: Bag) RETURNS Int64 -> RETURN b.items.length(); END"
    ctor    = "MUTABLE inner: #{list_t} = List[];\n        inner.append(#{push});\n        MUTABLE bg0: Bag = Bag{ items: inner };"
    if p[:origin] == :local
      body = <<~CHT.chomp
        FN runit() RETURNS !Int64 ->
            #{ctor}
            f: ~Int64 = BG { consume(COPY bg0); };
            RETURN NEXT f;
        END
      CHT
      call = "runit() OR RAISE"
    else
      body = <<~CHT.chomp
        FN runit(ops: Bag) RETURNS !Int64 ->
            f: ~Int64 = BG { consume(COPY ops); };
            RETURN NEXT f;
        END
      CHT
      call = "{ #{ctor}\n        n = runit(GIVE bg0) OR RAISE; }"
    end
  end

  consume_fn = consume

  main_body =
    if call.start_with?("{")
      # param origin: construct + GIVE in main, then call.
      inner = call[1..-2].strip
      "    MUTABLE n: Int64 = 0_i64;\n    #{inner}"
    else
      "    n: Int64 = #{call};"
    end

  <<~CHT
    #{consume_fn}

    #{body}

    FN main() RETURNS !Void ->
    #{main_body}
        ASSERT n == 1_i64, "BG-captured COPY sees the one element";
        RETURN;
    END
  CHT
end
