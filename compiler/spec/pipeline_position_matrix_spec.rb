require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# Pipeline position matrix — spec/pipeline_position_matrix_spec.rb
#
# Combinatorial MIR-check coverage: every pipeline operation x every consuming
# POSITION x every element-ownership flavor. Motivated by the discovery that
# owned (cleanup-bearing) pipeline elements fail FRAME_NO_REWIND /
# CLEANUP_REQUIRED_WITHOUT_FINALIZER in whole POSITION CLASSES (local binding,
# foreach, mid-chain) while passing in others (heap terminals like join) —
# bugs that op-focused tests never see because they pin one position.
#
# Three element flavors drive the ownership axis:
#   :int       — Copy elements (Int64), no cleanup. Baseline.
#   :str_owned — heap-owned String elements (SELECT dup(_) allocates per item).
#                The flavor that exposes the owned-element placement bugs.
#   :composite — struct with an owned String field (transform::for shape).
#
# Positions cover where a pipeline RESULT can land: returned, bound to a local
# (at top level and inside IF / FOR / WHILE), consumed by FOR-each, fed to a
# following op (mid-chain), collapsed by a terminal (join/sum), passed as a
# borrowed argument.
#
# KNOWN_FAILURES is the exhaustive register of cells that currently fail, each
# with its exact error code. The assertions are strict BOTH ways:
#   - a listed cell that starts passing FAILS the suite ("remove the entry") so
#     the register can never go stale, and
#   - an unlisted cell that starts failing FAILS the suite (a regression).
# Fixing a bug class means deleting its entries here — the matrix itself does
# not change.
#
# Discovery mode: MATRIX_REPORT=1 bundle exec rspec <this file> prints a
# cell-by-cell report instead of asserting (for re-mapping after big changes).
#
# Runtime (leak-check) coverage for the owned-element cells lives in the fuzz
# matrix (tools/fuzz/templates/) — this spec is compile/MIR-check only.

module PipelinePositionMatrix
  extend self

  PRELUDE = <<~CLEAR
    ENUM Mode { A, B }
    STRUCT Row { label: String }
    STRUCT Holder { items: String[] }

    FN dup(s: String) RETURNS String ->
        RETURN COPY s;
    END

    FN takeStrs(ys: String[]) RETURNS Int64 -> RETURN ys.length(); END
    FN takeInts(ys: Int64[]) RETURNS Int64 -> RETURN ys.length(); END
    FN takeRows(ys: Row[]) RETURNS Int64 -> RETURN ys.length(); END
    FN sinkStrs(TAKES ys: String[]) RETURNS Int64 -> RETURN ys.length(); END
    FN sinkInts(TAKES ys: Int64[]) RETURNS Int64 -> RETURN ys.length(); END

    FN mk() RETURNS String[] ->
        MUTABLE out: String[] = List[];
        &out.push("a:b");
        &out.push("c");
        RETURN out;
    END
  CLEAR

  # ---- ops -------------------------------------------------------------
  # Each op: { frag: pipeline fragment over `xs`, elem: element flavor of the
  # RESULT, src: source flavor }. All yield a list of `elem`.
  OPS = {
    # String source, String[] result
    "select_owned"   => { frag: "xs |> SELECT dup(_)",                          elem: :str, src: :str },
    "select_copy"    => { frag: "xs |> SELECT COPY _",                          elem: :str, src: :str },
    "where_str"      => { frag: "xs |> WHERE !(_.empty?())",                    elem: :str, src: :str },
    "skip_str"       => { frag: "xs |> SKIP 1",                                 elem: :str, src: :str },
    "limit_str"      => { frag: "xs |> LIMIT 2",                                elem: :str, src: :str },
    "take_while_str" => { frag: "xs |> TAKE_WHILE !(_.empty?())",               elem: :str, src: :str },
    "unnest_split"   => { frag: "xs |> UNNEST _.split(\":\")",                  elem: :str, src: :str },
    "order_by_str"   => { frag: "xs |> ORDER_BY _",                             elem: :str, src: :str },
    # DISTINCT yields a set (not T[]): only length/iteration positions apply.
    "distinct_str"   => { frag: "xs |> DISTINCT _",                             elem: :str, src: :str,
                          exclude: %w[ret arg_borrow terminal_join each_terminal arg_takes struct_field push_outer] },
    "where_unnest"   => { frag: "xs |> WHERE !(_.empty?()) |> UNNEST _.split(\":\")", elem: :str, src: :str },
    "skip_sel_owned" => { frag: "(xs |> SKIP 1) |> SELECT dup(_)",              elem: :str, src: :str },
    "unnest_select"  => { frag: "xs |> UNNEST _.split(\":\") |> SELECT dup(_)", elem: :str, src: :str },

    # Owned CALL RESULT as the pipeline source (exercises pipe_src_list cleanup)
    "srccall_where"  => { frag: "mk() |> WHERE !(_.empty?())",                 elem: :str, src: :str },
    "srccall_select" => { frag: "mk() |> SELECT dup(_)",                       elem: :str, src: :str },

    # Nested pipeline inside the SELECT element expression
    "nested_pipe"    => { frag: "xs |> SELECT ((_.split(\":\") |> WHERE !(_.empty?())).join(\"-\"))", elem: :str, src: :str },

    # Int source, Int64[] result
    "select_int"     => { frag: "xs |> SELECT _ * 2_i64",                       elem: :int, src: :int },
    "where_int"      => { frag: "xs |> WHERE _ > 0_i64",                        elem: :int, src: :int },
    "skip_int"       => { frag: "xs |> SKIP 1",                                 elem: :int, src: :int },
    "limit_int"      => { frag: "xs |> LIMIT 2",                                elem: :int, src: :int },
    "take_while_int" => { frag: "xs |> TAKE_WHILE _ < 3_i64",                   elem: :int, src: :int },
    "unnest_lit"     => { frag: "xs |> UNNEST [_, _]",                          elem: :int, src: :int },
    "order_by_int"   => { frag: "xs |> ORDER_BY _",                             elem: :int, src: :int },
    "distinct_int"   => { frag: "xs |> DISTINCT _",                             elem: :int, src: :int,
                          exclude: %w[ret arg_borrow terminal_sum each_terminal arg_takes] },

    # String source, composite (owned-field struct) result
    "select_row"     => { frag: "xs |> SELECT Row{ label: COPY dup(_) }",       elem: :row, src: :str },
  }.freeze

  # Scalar-result pipelines (REDUCE / terminals) probed across binding contexts
  # — the owned REDUCE accumulator inside an enclosing loop is its own shape.
  SCALAR_OPS = {
    "reduce_str" => { frag: "xs |> REDUCE(\"\") acc $+ _",       ty: "String", use: ->(v) { "#{v}.length()" }, src: :str },
    "reduce_int" => { frag: "xs |> REDUCE(0_i64) acc + _",       ty: "Int64",  use: ->(v) { v },               src: :int },
    "join_str"   => { frag: "(xs |> WHERE !(_.empty?())).join(\",\")", ty: "String", use: ->(v) { "#{v}.length()" }, src: :str },
    "sum_int"    => { frag: "xs |> WHERE _ > 0_i64 |> SUM _",    ty: "Int64",  use: ->(v) { v },               src: :int },
  }.freeze

  SCALAR_POSITIONS = {
    "ret"      => ->(frag, _u) { "RETURN #{frag};" },
    "local"    => ->(frag, u)  { "v = #{frag};\n  RETURN #{u.call('v')};" },
    "in_if"    => ->(frag, u)  { "IF xs.length() > 0_i64 THEN\n    v = #{frag};\n    RETURN #{u.call('v')};\n  END\n  RETURN 0_i64;" },
    "in_for"   => ->(frag, u)  { "MUTABLE n: Int64 = 0_i64;\n  FOR i IN [1_i64, 2_i64] DO\n    v = #{frag};\n    n = n + #{u.call('v')};\n  END\n  RETURN n;" },
    "in_while" => ->(frag, u)  { "MUTABLE n: Int64 = 0_i64;\n  MUTABLE i: Int64 = 0_i64;\n  WHILE i < 2_i64 DO\n    v = #{frag};\n    n = n + #{u.call('v')};\n    i = i + 1_i64;\n  END\n  RETURN n;" },
  }.freeze

  SRC = {
    str: { param: "xs: String[]", args: "[\"a:b\", \"c\"]" },
    int: { param: "xs: Int64[]",  args: "[1_i64, 2_i64, 3_i64]" },
  }.freeze

  ELEM = {
    str: { list_ty: "String[]", use: ->(v) { "#{v}.length()" }, take: "takeStrs" },
    int: { list_ty: "Int64[]",  use: ->(v) { v },               take: "takeInts" },
    row: { list_ty: "Row[]",    use: ->(v) { "#{v}.label.length()" }, take: "takeRows" },
  }.freeze

  # ---- positions -------------------------------------------------------
  # Each position: { elems: element flavors it can consume, gen: (frag, elem) ->
  # the body of `FN f(<src param>) RETURNS Int64` }. Every generated program is
  # a full compile unit: PRELUDE + f + main calling f.
  POSITIONS = {
    "ret" => {
      elems: %i[str int row],
      gen: ->(frag, e) { "ys = #{frag};\n  RETURN ys.length();" },
      ret_list: true,
    },
    "local_len" => {
      elems: %i[str int row],
      gen: ->(frag, _e) { "ys = #{frag};\n  RETURN ys.length();" },
    },
    "local_in_if" => {
      elems: %i[str int row],
      gen: ->(frag, _e) { "IF xs.length() > 0_i64 THEN\n    ys = #{frag};\n    RETURN ys.length();\n  END\n  RETURN 0_i64;" },
    },
    "local_in_for" => {
      elems: %i[str int row],
      gen: ->(frag, _e) { "MUTABLE n: Int64 = 0_i64;\n  FOR i IN [1_i64, 2_i64] DO\n    ys = #{frag};\n    n = n + ys.length();\n  END\n  RETURN n;" },
    },
    "local_in_while" => {
      elems: %i[str int row],
      gen: ->(frag, _e) { "MUTABLE n: Int64 = 0_i64;\n  MUTABLE i: Int64 = 0_i64;\n  WHILE i < 2_i64 DO\n    ys = #{frag};\n    n = n + ys.length();\n    i = i + 1_i64;\n  END\n  RETURN n;" },
    },
    "foreach" => {
      elems: %i[str int row],
      gen: ->(frag, e) { "MUTABLE n: Int64 = 0_i64;\n  FOR e IN #{frag} DO\n    n = n + #{ELEM.fetch(e)[:use].call('e')};\n  END\n  RETURN n;" },
    },
    "foreach_in_if" => {
      elems: %i[str int row],
      gen: ->(frag, e) { "MUTABLE n: Int64 = 0_i64;\n  IF xs.length() > 0_i64 THEN\n    FOR e IN #{frag} DO\n      n = n + #{ELEM.fetch(e)[:use].call('e')};\n    END\n  END\n  RETURN n;" },
    },
    "mid_select_owned" => {
      elems: %i[str],
      gen: ->(frag, _e) { "ys = #{frag} |> SELECT dup(_);\n  RETURN ys.length();" },
    },
    "mid_where" => {
      elems: %i[str int],
      gen: ->(frag, e) {
        pred = e == :str ? "!(_.empty?())" : "_ > 0_i64"
        "ys = #{frag} |> WHERE #{pred};\n  RETURN ys.length();"
      },
    },
    "terminal_join" => {
      elems: %i[str],
      gen: ->(frag, _e) { "s = (#{frag}).join(\",\");\n  RETURN s.length();" },
    },
    "terminal_sum" => {
      elems: %i[int],
      gen: ->(frag, _e) { "RETURN #{frag} |> SUM _;" },
    },
    "arg_borrow" => {
      elems: %i[str int row],
      gen: ->(frag, e) { "RETURN #{ELEM.fetch(e)[:take]}(#{frag});" },
    },
    "each_terminal" => {
      elems: %i[str int],
      gen: ->(frag, e) { "MUTABLE n: Int64 = 0_i64;\n  #{frag} |> EACH {\n    n = n + #{ELEM.fetch(e)[:use].call('_')};\n  };\n  RETURN n;" },
    },
    # Escaping consumers: the pipeline result leaves the frame.
    "arg_takes" => {
      elems: %i[str int],
      gen: ->(frag, e) { "RETURN #{e == :str ? 'sinkStrs' : 'sinkInts'}(#{frag});" },
    },
    "struct_field" => {
      elems: %i[str],
      gen: ->(frag, _e) { "h = Holder{ items: #{frag} };\n  RETURN h.items.length();" },
    },
    "push_outer" => {
      elems: %i[str],
      gen: ->(frag, _e) { "MUTABLE all: String[][] = List[];\n  &all.push(#{frag});\n  RETURN all.length();" },
    },
    "if_cond" => {
      elems: %i[str int row],
      gen: ->(frag, _e) { "IF (#{frag}).length() > 0_i64 THEN\n    RETURN 1_i64;\n  END\n  RETURN 0_i64;" },
    },
    # Pipeline local in a MATCH arm inside an enclosing loop: the loop-rewind
    # synthesis must see pipeline bindings through MATCH-arm containers.
    "local_in_match_for" => {
      elems: %i[str int],
      gen: ->(frag, _e) {
        "m: Mode = Mode.A;\n  MUTABLE n: Int64 = 0_i64;\n  FOR i IN (1_i64..=2_i64) DO\n" \
        "    PARTIAL MATCH m START\n        Mode.A ->\n          ys = #{frag};\n          n = n + ys.length();,\n" \
        "        DEFAULT -> n = n + 0_i64;\n    END\n  END\n  RETURN n;"
      },
    },
  }.freeze

  # ---- stream pipelines ([~]T sources) ----------------------------------
  # Transpile-level stream cells. The selector-ownership axis mirrors the list
  # matrix: a borrowed/identity selector vs one producing a fresh owned String.
  # (The unfused NEXT-consumer variant transpiles clean but is memory-broken at
  # runtime — that lives in pipeline_downstream_register_spec.rb, which runs
  # the full build/test toolchain.)
  STREAM_CELLS = {
    "stream_each_borrow"    => "gen |> EACH { n = n + _.length(); };",
    "stream_where_each"     => "gen |> WHERE !(_.empty?()) |> EACH { n = n + _.length(); };",
    "stream_select_own_each" => "gen |> SELECT dup(_) |> EACH { n = n + _.length(); };",
    "stream_select_own_sum" => "running: ~Int64@observable = gen |> SELECT dup(_) |> SUM _.length();\n    n = NEXT running;",
    "stream_limit_each"     => "gen |> LIMIT 2 |> EACH { n = n + _.length(); };",
  }.freeze

  StreamCell = Struct.new(:id, :stmt) do
    def program
      <<~CLEAR
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
            #{stmt}
            ASSERT n >= 0, "stream cell";
            RETURN;
        END
      CLEAR
    end
  end

  Cell = Struct.new(:id, :op, :pos, :src) do
    def program
      op = OPS.fetch(self.op)
      pos = POSITIONS.fetch(self.pos)
      src_info = SRC.fetch(op[:src])
      elem = op[:elem]
      if pos[:ret_list]
        list_ty = ELEM.fetch(elem)[:list_ty]
        body = "RETURN #{op[:frag]};"
        f = "FN f(#{src_info[:param]}) RETURNS #{list_ty} ->\n  #{body}\nEND\n" \
            "FN g(#{src_info[:param]}) RETURNS Int64 -> ys = f(xs); RETURN ys.length(); END"
        call = "g(#{src_info[:args]})"
      else
        body = pos[:gen].call(op[:frag], elem)
        f = "FN f(#{src_info[:param]}) RETURNS Int64 ->\n  #{body}\nEND"
        call = "f(#{src_info[:args]})"
      end
      <<~CLEAR
        #{PRELUDE}
        #{f}

        FN main() RETURNS Void ->
            ASSERT #{call} >= 0_i64, "matrix cell";
            RETURN;
        END
      CLEAR
    end
  end

  ScalarCell = Struct.new(:id, :op, :pos) do
    def program
      op = SCALAR_OPS.fetch(self.op)
      src_info = SRC.fetch(op[:src])
      body = SCALAR_POSITIONS.fetch(pos).call(op[:frag], op[:use])
      body = body.sub("RETURN #{op[:frag]};", "RETURN #{op[:frag]};") # ret keeps scalar type
      f = if pos == "ret"
        "FN f(#{src_info[:param]}) RETURNS #{op[:ty]} ->\n  #{body}\nEND\n" \
        "FN g(#{src_info[:param]}) RETURNS Int64 -> v = f(xs); RETURN #{op[:use].call('v')}; END"
      else
        "FN f(#{src_info[:param]}) RETURNS Int64 ->\n  #{body}\nEND"
      end
      call = pos == "ret" ? "g(#{src_info[:args]})" : "f(#{src_info[:args]})"
      <<~CLEAR
        #{PRELUDE}
        #{f}

        FN main() RETURNS Void ->
            ASSERT #{call} >= 0_i64, "matrix cell";
            RETURN;
        END
      CLEAR
    end
  end

  def cells
    out = []
    OPS.each do |op_name, op|
      POSITIONS.each do |pos_name, pos|
        next unless pos[:elems].include?(op[:elem] == :row ? :row : op[:elem])
        next if op[:exclude]&.include?(pos_name)

        out << Cell.new("#{op_name}/#{pos_name}", op_name, pos_name, op[:src])
      end
    end
    SCALAR_OPS.each_key do |op_name|
      SCALAR_POSITIONS.each_key do |pos_name|
        out << ScalarCell.new("#{op_name}/#{pos_name}", op_name, pos_name)
      end
    end
    STREAM_CELLS.each { |id, stmt| out << StreamCell.new(id, stmt) }
    out
  end

  # Transpile one cell in-process; returns nil on success or the compact error
  # code/message on failure.
  def check(cell)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(
      cell.program, source_dir: Dir.pwd, ownership_mode: :default
    )
    nil
  rescue StandardError => e
    e.message[/\[([A-Z_0-9]+)\]/, 1] || e.message.lines.first.to_s.strip[0, 80].to_s.rstrip
  end
end

RSpec.describe "Pipeline position matrix" do
  # Every currently-failing cell, with its exact error code. Deleting a fixed
  # bug's entries is the ONLY way this list shrinks; the matrix never changes.
  # (Cells absent from this list MUST transpile clean.)
  KNOWN_FAILURES = T.let({}.freeze, T::Hash[String, String])

  if ENV["MATRIX_REPORT"]
    it "reports every cell (discovery mode)" do
      PipelinePositionMatrix.cells.each do |cell|
        err = PipelinePositionMatrix.check(cell)
        puts format("%-40s %s", cell.id, err || "ok")
      end
    end
  else
    PipelinePositionMatrix.cells.each do |cell|
      expected = KNOWN_FAILURES[cell.id]
      it "#{cell.id}#{expected ? " (known: #{expected})" : ""}" do
        err = PipelinePositionMatrix.check(cell)
        if expected
          expect(err).to eq(expected),
            err.nil? ? "cell now PASSES — remove '#{cell.id}' from KNOWN_FAILURES" :
                       "expected #{expected}, got #{err}"
        else
          expect(err).to be_nil, "cell regressed: #{err}\n---\n#{cell.program}"
        end
      end
    end
  end
end
