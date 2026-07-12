# Template: cleanup / alloc / dealloc control-flow matrix.
#
# This complements branch_cleanup / loop_cleanup / error_cleanup. Those
# templates own a few allocator kinds deeply; this one owns the cross-product
# of cleanup-bearing value shape and control-flow position.

CCM_SHAPES = %i[string list hash struct union optional nested].freeze
CCM_FLOWS = %i[branch loop match catch return move give discard].freeze

CCM_CELLS = CCM_SHAPES.flat_map do |shape|
  CCM_FLOWS.map { |flow| { shape: shape, flow: flow } }
end

def ccm_spec(shape)
  case shape
  when :string
    ["", "String", 'COPY "abc"', "x.length()", "3_i64"]
  when :list
    ["", "Int64[]@list", "makeList() OR_ELSE RAISE", "x.length()", "2_i64"]
  when :hash
    ["", "HashMap<String>", '{"a": COPY "aa", "b": COPY "bb"}', "x.count()", "2_i64"]
  when :struct
    ["STRUCT Box { label: String }\n", "Box", 'Box{ label: COPY "abc" }', "x.label.length()", "3_i64"]
  when :union
    ["UNION Val { Empty, Text: String }\n", "Val", 'Val{ Text: COPY "abc" }', "1_i64", "1_i64"]
  when :optional
    ["", "?String", 'COPY "abc"', "1_i64", "1_i64"]
  when :nested
    ["STRUCT Inner { label: String }\nSTRUCT Box { items: Inner[]@list }\n", "Box", "makeBox() OR_ELSE RAISE", "(x.items[0_i64]?.label OR_ELSE \"\").length()", "3_i64"]
  end
end

def ccm_helpers(shape)
  helpers = +""
  if shape == :list
    helpers << <<~CHT
      FN makeList() RETURNS !Int64[]@list ->
          MUTABLE xs: Int64[]@list = [];
          xs.append(1_i64);
          xs.append(2_i64);
          RETURN xs;
      END
    CHT
  elsif shape == :nested
    helpers << <<~CHT
      FN makeBox() RETURNS !Box ->
          MUTABLE xs: Inner[]@list = [];
          xs.append(Inner{ label: COPY "abc" });
          RETURN Box{ items: xs };
      END
    CHT
  end
  helpers
end

def ccm_consume_body(shape)
  case shape
  when :union
    <<~CHT.chomp
      PARTIAL MATCH TAKES x START
          Val.Text AS s -> RETURN 1_i64;,
          DEFAULT -> RETURN 0_i64;
      END
    CHT
  when :optional
    <<~CHT.chomp
      IF x EXISTS AS s THEN
          RETURN 1_i64;
      ELSE
          RETURN 0_i64;
      END
    CHT
  else
    "RETURN #{ccm_spec(shape)[3]};"
  end
end

FuzzGenerator.register(:cleanup_control_matrix, cells: CCM_CELLS) do |p|
  prelude, ty, expr, observe, expected = ccm_spec(p[:shape])
  helpers = ccm_helpers(p[:shape])

  case p[:flow]
  when :branch
    <<~CHT
      #{prelude}#{helpers}
      FN main() RETURNS !Void ->
          MUTABLE total: Int64 = 0_i64;
          IF TRUE THEN
              x: #{ty} = #{expr};
              total = #{observe};
          ELSE
              x: #{ty} = #{expr};
              total = #{observe};
          END
          ASSERT total == #{expected}, "cleanup branch";
          RETURN;
      END
    CHT
  when :loop
    <<~CHT
      #{prelude}#{helpers}
      FN main() RETURNS !Void ->
          MUTABLE total: Int64 = 0_i64;
          FOR i IN (1_i64 ..= 2_i64) DO
              x: #{ty} = #{expr};
              total = total + #{observe};
          END
          ASSERT total == #{expected.sub('_i64', '').to_i * 2}_i64, "cleanup loop";
          RETURN;
      END
    CHT
  when :match
    match_body = if p[:shape] == :union
      <<~CHT.chomp
        PARTIAL MATCH x START
                  Val.Text AS s -> total = 1_i64;,
                  DEFAULT -> total = 0_i64;
              END
      CHT
    elsif p[:shape] == :optional
      <<~CHT.chomp
        IF x EXISTS AS s THEN
                  total = 1_i64;
              ELSE
                  total = 0_i64;
              END
      CHT
    else
      "total = #{observe};"
    end
    <<~CHT
      #{prelude}#{helpers}
      FN main() RETURNS !Void ->
          x: #{ty} = #{expr};
          MUTABLE total: Int64 = 0_i64;
          #{match_body}
          ASSERT total == #{expected}, "cleanup match";
          RETURN;
      END
    CHT
  when :catch
    <<~CHT
      #{prelude}#{helpers}
      FN run(flag: Bool) RETURNS !Int64 ->
          x: #{ty} = #{expr};
          IF flag THEN RAISE "stop"; END
          RETURN #{observe};
      END

      FN main() RETURNS Void ->
          ok: Int64 = run(FALSE) OR_ELSE 0_i64;
          bad: Int64 = run(TRUE) OR_ELSE 0_i64;
          ASSERT ok == #{expected}, "cleanup catch ok";
          ASSERT bad == 0_i64, "cleanup catch fallback";
          RETURN;
      END
    CHT
  when :return
    <<~CHT
      #{prelude}#{helpers}
      FN build() RETURNS !#{ty} ->
          x: #{ty} = #{expr};
          RETURN x;
      END

      FN main() RETURNS !Void ->
          x: #{ty} = build() OR_ELSE RAISE;
          ASSERT #{observe} == #{expected}, "cleanup return";
          RETURN;
      END
    CHT
  when :move
    <<~CHT
      #{prelude}#{helpers}
      FN consume(TAKES x: #{ty}) RETURNS Int64 ->
          #{ccm_consume_body(p[:shape])}
      END

      FN main() RETURNS !Void ->
          x: #{ty} = #{expr};
          ASSERT consume(GIVE x) == #{expected}, "cleanup move";
          RETURN;
      END
    CHT
  when :give
    <<~CHT
      #{prelude}#{helpers}
      FN consume(TAKES x: #{ty}) RETURNS Int64 ->
          #{ccm_consume_body(p[:shape])}
      END

      FN main() RETURNS !Void ->
          x: #{ty} = #{expr};
          result: Int64 = consume(GIVE x);
          ASSERT result == #{expected}, "cleanup give";
          RETURN;
      END
    CHT
  when :discard
    <<~CHT
      #{prelude}#{helpers}
      FN main() RETURNS !Void ->
          x: #{ty} = #{expr};
          _ = #{observe};
          RETURN;
      END
    CHT
  end
end
