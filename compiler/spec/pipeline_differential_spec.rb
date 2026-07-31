require "rspec"
require "open3"
require "tmpdir"

# Pipeline differential lane — spec/pipeline_differential_spec.rb
#
# Metamorphic/differential testing: for each semantic scenario, the SAME
# computation is written twice — as a pipeline and as the equivalent
# hand-written loop — and both programs carry IDENTICAL exact-value
# assertions. Both must compile AND pass at runtime under the testing
# allocator. This catches wrong-RESULT lowering bugs (inverted predicates,
# off-by-one SKIP/LIMIT, wrong UNNEST order, dropped elements) that memory
# oracles can never see, and pins pipeline semantics to their loop meaning.
#
# Tagged :integration (runs binaries; ~10 pairs x 2 programs).

RSpec.describe "Pipeline differential lane", :integration do
  ROOT = File.expand_path("../..", __dir__)

  PRELUDE = <<~CLEAR
    FN dup(s: String) RETURNS String -> RETURN COPY s; END
  CLEAR

  # Each pair: shared SETUP building `xs`, the pipeline form and the loop form
  # (both binding the result to `got`), and the shared exact CHECK.
  PAIRS = {
    "where_select" => {
      setup: "MUTABLE xs: String[] = List[];\n  &xs.push(dup(\"a\"));\n  &xs.push(dup(\"\"));\n  &xs.push(dup(\"cc\"));",
      pipeline: "got = xs |> WHERE !(_.empty?()) |> SELECT dup(_);",
      loop: "MUTABLE got: String[] = List[];\n  FOR e IN xs DO\n    IF !(e.empty?()) THEN\n      &got.push(dup(e));\n    END\n  END",
      check: "ASSERT (got).join(\"-\") == \"a-cc\", \"where_select exact\";",
    },
    "skip" => {
      setup: "MUTABLE xs: String[] = List[];\n  &xs.push(dup(\"a\"));\n  &xs.push(dup(\"b\"));\n  &xs.push(dup(\"c\"));",
      pipeline: "got = xs |> SKIP 1;",
      loop: "MUTABLE got: String[] = List[];\n  MUTABLE i: Int64 = 0_i64;\n  FOR e IN xs DO\n    IF i >= 1_i64 THEN\n      &got.push(COPY e);\n    END\n    i = i + 1_i64;\n  END",
      check: "ASSERT (got).join(\"\") == \"bc\", \"skip exact\";",
    },
    "limit" => {
      setup: "MUTABLE xs: String[] = List[];\n  &xs.push(dup(\"a\"));\n  &xs.push(dup(\"b\"));\n  &xs.push(dup(\"c\"));",
      pipeline: "got = xs |> LIMIT 2;",
      loop: "MUTABLE got: String[] = List[];\n  MUTABLE i: Int64 = 0_i64;\n  FOR e IN xs DO\n    IF i < 2_i64 THEN\n      &got.push(COPY e);\n    END\n    i = i + 1_i64;\n  END",
      check: "ASSERT (got).join(\"\") == \"ab\", \"limit exact\";",
    },
    "take_while" => {
      setup: "MUTABLE xs: String[] = List[];\n  &xs.push(dup(\"a\"));\n  &xs.push(dup(\"\"));\n  &xs.push(dup(\"c\"));",
      pipeline: "got = xs |> TAKE_WHILE !(_.empty?());",
      loop: "MUTABLE got: String[] = List[];\n  MUTABLE stop: Bool = FALSE;\n  FOR e IN xs DO\n    IF !stop THEN\n      IF !(e.empty?()) THEN\n        &got.push(COPY e);\n      ELSE\n        stop = TRUE;\n      END\n    END\n  END",
      check: "ASSERT (got).join(\"\") == \"a\", \"take_while exact\";",
    },
    "unnest" => {
      setup: "MUTABLE xs: String[] = List[];\n  &xs.push(dup(\"a:b\"));\n  &xs.push(dup(\"c\"));",
      pipeline: "got = xs |> UNNEST _.split(\":\");",
      loop: "MUTABLE got: String[] = List[];\n  FOR e IN xs DO\n    parts = e.split(\":\");\n    FOR p IN parts DO\n      &got.push(COPY p);\n    END\n  END",
      check: "ASSERT (got).join(\"-\") == \"a-b-c\", \"unnest exact + order\";",
    },
    "reduce_str" => {
      setup: "MUTABLE xs: String[] = List[];\n  &xs.push(dup(\"a\"));\n  &xs.push(dup(\"b\"));",
      pipeline: "got = xs |> REDUCE(\"\") acc $+ _;",
      loop: "MUTABLE got: String = \"\";\n  FOR e IN xs DO\n    got = got $+ e;\n  END",
      check: "ASSERT got == \"ab\", \"reduce exact + order\";",
    },
    "sum_after_where" => {
      setup: "MUTABLE xs: Int64[] = List[];\n  &xs.push(1_i64);\n  &xs.push(-2_i64);\n  &xs.push(3_i64);",
      pipeline: "got = xs |> WHERE _ > 0_i64 |> SUM _;",
      loop: "MUTABLE got: Int64 = 0_i64;\n  FOR e IN xs DO\n    IF e > 0_i64 THEN\n      got = got + e;\n    END\n  END",
      check: "ASSERT got == 4_i64, \"sum exact\";",
    },
    "select_transform_order" => {
      setup: "MUTABLE xs: Int64[] = List[];\n  &xs.push(3_i64);\n  &xs.push(1_i64);\n  &xs.push(2_i64);",
      pipeline: "got = xs |> SELECT _ * 10_i64;",
      loop: "MUTABLE got: Int64[] = List[];\n  FOR e IN xs DO\n    &got.push(e * 10_i64);\n  END",
      check: "ASSERT (got |> SUM _) == 60_i64, \"select sum\";\n  IF got[0] EXISTS AS first THEN\n    ASSERT first == 30_i64, \"select preserves order\";\n  ELSE\n    ASSERT FALSE, \"select empty\";\n  END",
    },
    "chain_skip_where" => {
      setup: "MUTABLE xs: Int64[] = List[];\n  &xs.push(5_i64);\n  &xs.push(-1_i64);\n  &xs.push(2_i64);\n  &xs.push(-3_i64);\n  &xs.push(7_i64);",
      pipeline: "got = xs |> SKIP 1 |> WHERE _ > 0_i64 |> SUM _;",
      loop: "MUTABLE got: Int64 = 0_i64;\n  MUTABLE i: Int64 = 0_i64;\n  FOR e IN xs DO\n    IF i >= 1_i64 AND e > 0_i64 THEN\n      got = got + e;\n    END\n    i = i + 1_i64;\n  END",
      check: "ASSERT got == 9_i64, \"chain exact (skip BEFORE where)\";",
    },
  }.freeze

  def run_program(body)
    Dir.mktmpdir do |dir|
      f = File.join(dir, "prog.clear")
      File.write(f, body)
      out, _ = Open3.capture2e(File.join(ROOT, "clear"), "test", f, chdir: ROOT)
      ok = out =~ /All \d+ tests? passed/ && out !~ /leaked|Invalid free/
      [ok, out]
    end
  end

  def program_for(pair, form)
    <<~CLEAR
      #{PRELUDE}
      FN t() RETURNS Void ->
          #{pair[:setup]}
          #{pair[form]}
          #{pair[:check]}
          RETURN;
      END

      TEST Diff DO
          t();
      END
    CLEAR
  end

  PAIRS.each do |name, pair|
    it "#{name}: pipeline and loop agree (both pass exact checks)" do
      pipe_ok, pipe_out = run_program(program_for(pair, :pipeline))
      loop_ok, loop_out = run_program(program_for(pair, :loop))
      expect(loop_ok).to be_truthy,
        "LOOP form failed (oracle itself broken?):\n#{loop_out.lines.last(8).join}"
      expect(pipe_ok).to be_truthy,
        "PIPELINE form failed where the equivalent loop passes:\n#{pipe_out.lines.last(8).join}"
    end
  end
end
