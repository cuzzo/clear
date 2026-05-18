# Template: COPY of a captured binding into a BG fiber, across the
# capture cross-product {source-origin x collection-shape x elem}.
#
# Stresses FiberCtxBuilder's FreshHeapCopy branch. The BG ctx field
# TYPE must describe the value the field stores (the deep-copied
# owned value), NOT the source it was copied from. For a *local*
# @list or a slice/String param @TypeOf(source) == @TypeOf(dupe) so
# the latent bug is masked; for an @list / struct-with-@list-field
# *parameter* the source is a borrowed `*const ArrayList`, so a
# source-derived field type yields `*const T` while the field holds
# an owned dupe -> generated Zig `expected '*T', found '*const T'`.
#
# Sibling of promise_handle_capture.rb: that template covers the
# affine future-HANDLE transfer scenario (producer=BG{}; consumer=
# BG{ NEXT producer }). This one covers the complementary, never-
# sampled DATA-collection capture-typing scenario (COPY of a list /
# struct-with-list across the BG boundary). Together they span the
# two capture dimensions; neither duplicates the other.
#
# See docs/agents/vm-bugs.md "Bug #7" and
# examples/minivm/docs/agents/compiler-bug-root-causes.md.
#
# All cells are POSITIVE (must compile AND run). Before the
# FiberCtxBuilder fix the `param`/`struct_field` cells fail to build;
# after it the whole matrix is clean -- this template is the
# regression that proves the bug and locks the fix.

BG_CAPTURE_TYPING_CELLS = []

# elem is :int only for now. The :string variant of bare
# `String[]@list` COPY-into-BG exposes a SEPARATE cleanup
# double-free (vm-bugs.md "Bug #8"), distinct from the ctx-field
# typing bug (Bug #7) this template/fix targets. :string cells are
# re-enabled when Bug #8 lands (its own standalone bug-fix commit).
[:int].each do |elem|
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
