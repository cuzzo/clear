require "rspec"
require "tmpdir"
require "fileutils"
require_relative "../src/tools/formatter"

# Unit tests for the formatter. Calls Formatter.format(src) directly --
# the CLI's flag handling (--check / --stdout / --no-warn) and width-
# warning emission are mirrored in run_fmt below as a few lines of pure
# Ruby. No subprocess, no `./clear` binary, no Zig dependency, so the
# whole file runs in the parallel unit job and contributes coverage for
# src/backends/formatter.rb.

RSpec.describe Formatter do
  # Mirrors the CLI's behaviour from `clear` (case 'fmt'):
  #   - default:  format every file in place; emit path on change
  #   - --stdout: print formatted output for the file
  #   - --check:  exit 1 if any file would be rewritten
  #   - --no-warn / warn_width: width-warning emission
  # Returns [stdout, stderr, status] just like the old shell helper.
  def run_fmt(*args)
    check_only = false
    to_stdout  = false
    warn_width = true
    paths      = []
    args.each do |a|
      case a
      when "--check"   then check_only = true
      when "--stdout"  then to_stdout = true
      when "--no-warn" then warn_width = false
      else                  paths << a
      end
    end

    stdout = +""
    stderr = +""
    changed = false
    failed  = false

    paths.each do |path|
      src = File.read(path)
      out =
        begin
          Formatter.format(src)
        rescue Formatter::Error => e
          stderr << "#{path}: #{e.message}\n"
          failed = true
          next
        end

      if warn_width
        out.each_line.with_index(1) do |ln, idx|
          stripped = ln.sub(/\n\z/, "")
          if stripped.length > 120
            stderr << "#{path}:#{idx}: warning: line length #{stripped.length} exceeds 120\n"
          end
        end
      end

      if to_stdout
        stdout << out
      elsif check_only
        changed = true if out != src
      else
        if out != src
          File.write(path, out)
          stdout << "#{path}\n"
        end
      end
    end

    status = 0
    status = 1 if failed
    status = 1 if check_only && changed
    [stdout, stderr, status]
  end

  around do |ex|
    Dir.mktmpdir do |dir|
      @tmp = dir
      ex.run
    end
  end

  def write(name, content)
    path = File.join(@tmp, name)
    File.write(path, content)
    path
  end

  it "parses and prints a well-formed file to stdout" do
    path = write("a.cht", "FN main() RETURNS Void ->\n  RETURN;\nEND\n")
    out, _, status = run_fmt("--stdout", path)
    expect(status).to eq(0)
    expect(out).to eq("FN main() RETURNS Void ->\n  RETURN;\nEND\n")
  end

  it "exits non-zero on a parse error and refuses to write" do
    path = write("bad.cht", "FN main( RETURNS Void ->\n")
    before = File.read(path)
    _, stderr, status = run_fmt(path)
    expect(status).not_to eq(0)
    expect(stderr).to match(/parse error/i)
    expect(File.read(path)).to eq(before)
  end

  it "normalizes 4-space indent to 2-space and prints the path on change" do
    path = write("i.cht", "FN main() RETURNS Void ->\n    RETURN;\nEND\n")
    out, _, status = run_fmt(path)
    expect(status).to eq(0)
    expect(out.strip).to eq(path)
    expect(File.read(path)).to eq("FN main() RETURNS Void ->\n  RETURN;\nEND\n")
  end

  it "--check exits 1 when file is not formatted, 0 when formatted" do
    bad  = write("b.cht", "FN main() RETURNS Void ->\n    RETURN;\nEND\n")
    good = write("g.cht", "FN main() RETURNS Void ->\n  RETURN;\nEND\n")

    _, _, sb = run_fmt("--check", bad)
    expect(sb).to eq(1)

    _, _, sg = run_fmt("--check", good)
    expect(sg).to eq(0)
  end

  it "expands FN one-liners into multi-line form" do
    path = write("o.cht", "FN f() RETURNS Int64 -> RETURN 0; END\n")
    out, _, _ = run_fmt("--stdout", path)
    expect(out).to eq("FN f() RETURNS Int64 ->\n  RETURN 0;\nEND\n")
  end

  it "wraps FN signature when it exceeds 120 chars" do
    long = (1..6).map { |i| "p#{i}: SomeReallyLongTypeName" }.join(", ")
    path = write("l.cht", "FN withLotsOfParams(#{long}) RETURNS Int64 ->\n  RETURN 0;\nEND\n")
    out, _, _ = run_fmt("--stdout", path)
    expect(out).to include("FN withLotsOfParams(\n")
    expect(out).to include("\n)\nRETURNS Int64 ->\n")
  end

  it "wraps WITH with 2+ captures onto their own lines" do
    src = <<~CLEAR
      STRUCT C {v: Int64}
      FN main() RETURNS Void ->
        a = C {v: 0} @locked;
        b = C {v: 0} @locked;
        WITH EXCLUSIVE a AS x, EXCLUSIVE b AS y {
          x.v = x.v + 1;
        }
        RETURN;
      END
    CLEAR
    path = write("w.cht", src)
    out, _, _ = run_fmt("--stdout", path)
    expect(out).to include("WITH\n    EXCLUSIVE a AS x,\n    EXCLUSIVE b AS y {")
  end

  it "wraps pipelines with 2+ `s>` stages each on its own line" do
    src = <<~CLEAR
      FN main() RETURNS Int64 ->
        v = items s> SELECT _ * 2 s> SUM _;
        RETURN v;
      END
    CLEAR
    path = write("p.cht", src)
    out, _, _ = run_fmt("--stdout", path)
    expect(out).to include("\n    s> SELECT _ * 2\n    s> SUM _")
  end

  it "gives `s> RECOVER(...)` one extra indent relative to sibling stages" do
    src = <<~CLEAR
      FN main() RETURNS Int64 ->
        v = items s> a s> RECOVER(0) s> b;
        RETURN v;
      END
    CLEAR
    path = write("r.cht", src)
    out, _, _ = run_fmt("--stdout", path)
    # a and b at +1 (4 spaces inside main); RECOVER at +2 (6 spaces).
    expect(out).to match(/^    s> a$/)
    expect(out).to match(/^      s> RECOVER\(0\)$/)
    expect(out).to match(/^    s> b;$/)
  end

  it "wraps long call args onto own lines with closing paren at call column" do
    long = (1..8).map { |i| "arg_#{i}_with_long_name" }.join(", ")
    src = "FN main() RETURNS Int64 ->\n  v = callWithLongName(#{long});\n  RETURN v;\nEND\n"
    path = write("c.cht", src)
    out, _, _ = run_fmt("--stdout", path)
    expect(out).to include("v = callWithLongName(\n")
    expect(out).to match(/\n  \);\n/)
  end

  it "flush-attaches @capability in type position and keeps space in value position" do
    src = <<~CLEAR
      STRUCT Counter {value: Int64@locked}
      FN main() RETURNS Int64 ->
        x = 42 @locked;
        RETURN x;
      END
    CLEAR
    path = write("cap.cht", src)
    out, _, _ = run_fmt("--stdout", path)
    expect(out).to include("value: Int64@locked")
    expect(out).to include("x = 42 @locked")
  end

  it "emits a width warning for lines exceeding 120 chars" do
    long_str = '"' + ("x" * 140) + '"'
    path = write("width.cht", "FN main() RETURNS Void ->\n  s = #{long_str};\n  RETURN;\nEND\n")
    _, stderr, status = run_fmt("--check", path)
    expect(status).to eq(0).or eq(1)
    expect(stderr).to match(/width\.cht:\d+: warning: line length \d+ exceeds 120/)
  end

  it "suppresses width warnings with --no-warn" do
    long_str = '"' + ("x" * 140) + '"'
    path = write("nw.cht", "FN main() RETURNS Void ->\n  s = #{long_str};\n  RETURN;\nEND\n")
    _, stderr, _ = run_fmt("--no-warn", "--check", path)
    expect(stderr).not_to include("warning: line length")
  end

  it "auto-inserts digit separators for decimal ints > 4 digits" do
    src = <<~CLEAR
      FN main() RETURNS Int64 ->
        a: Int64 = 1000000;
        b: Int64 = 12345;
        c: Int64 = 1234;
        d: Int64 = 42;
        RETURN a;
      END
    CLEAR
    path = write("n_int.cht", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to include("a: Int64 = 1_000_000;")
    expect(out).to include("b: Int64 = 12_345;")
    expect(out).to include("c: Int64 = 1234;")
    expect(out).to include("d: Int64 = 42;")
  end

  it "auto-inserts digit separators for floats with >4 digits on either side" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        a: Float64 = 3.141592653589793;
        b: Float64 = 1000000.5;
        c: Float64 = 1.5;
        RETURN;
      END
    CLEAR
    path = write("n_float.cht", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to include("a: Float64 = 3.141_592_653_589_793;")
    expect(out).to include("b: Float64 = 1_000_000.5;")
    expect(out).to include("c: Float64 = 1.5;")
  end

  it "preserves type suffixes through separator rewriting" do
    src = "FN main() RETURNS Int32 ->\n  a: Int32 = 1000000_i32;\n  RETURN a;\nEND\n"
    path = write("n_suffix.cht", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to include("1_000_000_i32")
  end

  it "canonicalizes existing separators (1_0_0_0 -> 1000, 1000000 -> 1_000_000)" do
    src = "FN main() RETURNS Int64 ->\n  a: Int64 = 1_0_0_0;\n  b: Int64 = 1000000;\n  RETURN a;\nEND\n"
    path = write("n_canon.cht", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to include("a: Int64 = 1000;")
    expect(out).to include("b: Int64 = 1_000_000;")
  end

  it "leaves hex / oct / bin literals untouched" do
    src = "FN main() RETURNS Int64 ->\n  a = 0xDEAD_BEEF;\n  b = 0b1010_0101;\n  RETURN 0;\nEND\n"
    path = write("n_hex.cht", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to include("0xDEAD_BEEF")
    expect(out).to include("0b1010_0101")
  end

  it "drops pipeline receiver onto its own line when first line exceeds 80 (§3.6)" do
    src = <<~CLEAR
      FN main() RETURNS Int64 ->
        some_really_really_long_variable_name = some_really_really_long_receiver_expression_thing s> a s> b;
        RETURN 0;
      END
    CLEAR
    path = write("drop_pipe.cht", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to match(/some_really_really_long_variable_name =\n/)
    expect(out).to match(/^    some_really_really_long_receiver_expression_thing$/)
    expect(out).to match(/^      s> a$/)
    expect(out).to match(/^      s> b;$/)
  end

  it "keeps receiver inline when first line fits within 80 chars" do
    src = "FN main() RETURNS Int64 ->\n  x = items s> filter s> reduce;\n  RETURN 0;\nEND\n"
    path = write("nodrop.cht", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to match(/^  x = items$/)
    expect(out).to match(/^    s> filter$/)
  end

  it "drops trailing pipeline keyword after CONCURRENT with 2+ args (§3.11)" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        items s> CONCURRENT(workers: 4, capacity: 8) EACH { doWork(_); };
        RETURN;
      END
    CLEAR
    path = write("conc.cht", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to match(/CONCURRENT\(workers: 4, capacity: 8\)\n/)
    expect(out).to match(/^    EACH \{/)
  end

  it "leaves single-arg CONCURRENT inline" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        items s> CONCURRENT(workers: 4) EACH { doWork(_); };
        RETURN;
      END
    CLEAR
    path = write("conc1.cht", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to include("CONCURRENT(workers: 4) EACH")
  end

  describe "FN signature metadata-wrap (REQUIRES / EFFECTS)" do
    it "drops RETURNS and REQUIRES to their own 1-space-indented lines when REQUIRES is present" do
      src = <<~CLEAR
        STRUCT Counter { value: Int64 }

        FN bumpIt(c: Counter) RETURNS Void
          REQUIRES c: LOCKED
        ->
            WITH EXCLUSIVE c AS inner {
                inner.value = inner.value + 1;
            }
        END

        FN main() RETURNS Void ->
        END
      CLEAR
      path = write("metawrap.cht", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      expect(out).to include("FN bumpIt(c: Counter)\n RETURNS Void\n REQUIRES c: LOCKED\n->\n")
      expect(out).to include("FN main() RETURNS Void ->")
    end

    it "renders metadata at 1-space indent for grouped REQUIRES" do
      src = <<~CLEAR
        STRUCT Account { balance: Int64 }

        FN transact(x: Account, y: Account, amount: Int64, audit: Bool) RETURNS Bool
          REQUIRES x, y: LOCKED
        ->
          RETURN TRUE;
        END
      CLEAR
      path = write("metawrap_params.cht", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      expect(out).to include("FN transact(x: Account, y: Account, amount: Int64, audit: Bool)\n RETURNS Bool\n REQUIRES x, y: LOCKED\n->\n")
    end

    it "is idempotent across two format passes" do
      src = <<~CLEAR
        STRUCT Counter { value: Int64 }

        FN bumpIt(c: Counter) RETURNS Void
          REQUIRES c: LOCKED
        ->
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; }
        END
      CLEAR
      path = write("metawrap_idem.cht", src)
      first, _, _ = run_fmt("--no-warn", "--stdout", path)
      again_path = write("metawrap_idem_2.cht", first)
      second, _, _ = run_fmt("--no-warn", "--stdout", again_path)
      expect(second).to eq(first)
    end

    it "leaves single-line FN signatures compact when no REQUIRES is present" do
      src = <<~CLEAR
        FN add(a: Int64, b: Int64) RETURNS Int64 ->
          RETURN a + b;
        END
      CLEAR
      path = write("nometa.cht", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      expect(out).to include("FN add(a: Int64, b: Int64) RETURNS Int64 ->")
      expect(out).not_to match(/^ RETURNS/)
      expect(out).not_to match(/^ REQUIRES/)
    end
  end

  # ----------------------------------------------------------------
  # Targeted coverage backfill for src/tools/formatter.rb.
  # Each `it` below was written to drive an otherwise-uncovered branch
  # in the formatter; together they take line coverage from ~93% -> ~99%.
  # ----------------------------------------------------------------

  describe "tokenizer edge cases" do
    it "preserves triple-quoted strings as a single STRING token" do
      src = "FN main() RETURNS Void ->\n  s = \"\"\"line1\nline2\"\"\";\n  RETURN;\nEND\n"
      out, _, status = run_fmt("--no-warn", "--stdout", src.then { |s| write("triple.cht", s) })
      expect(status).to eq(0)
      expect(out).to include("\"\"\"line1\nline2\"\"\"")
    end

    it "strips _f64 suffix on decimal literals (default-type elision)" do
      src = "FN main() RETURNS Void ->\n  a: Float64 = 3.14_f64;\n  RETURN;\nEND\n"
      path = write("f64suffix.cht", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      expect(out).to include("a: Float64 = 3.14;")
      expect(out).not_to include("_f64")
    end

    it "keeps _f64 on integer literals (suffix is type-bearing)" do
      # 1_f64 is an integer literal with explicit f64 type -- dropping
      # the suffix would silently change the type to i64.
      src = "FN main() RETURNS Void ->\n  a: Float64 = 1_f64;\n  RETURN;\nEND\n"
      path = write("f64keep.cht", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      expect(out).to include("1_f64")
    end

    it "handles literal { inside ${} interpolation (e.g., struct literal)" do
      # Drives the depth>0 + raw '{' branch in consume_string. Without
      # it, the formatter would terminate the interpolation at the
      # inner '{'.
      src = <<~CLEAR
        STRUCT Pair { a: Int64, b: Int64 }
        FN main() RETURNS Void ->
          p = Pair { a: 1, b: 2 };
          s = "shape=${ Pair { a: 1, b: 2 } }";
          RETURN;
        END
      CLEAR
      path = write("nested_interp.cht", src)
      out, _, status = run_fmt("--no-warn", "--stdout", path)
      expect(status).to eq(0)
      expect(out).to include("\"shape=${ Pair { a: 1, b: 2 } }\"")
    end
  end

  describe "FN signature wrap variants" do
    it "wraps params AND drops RETURNS / REQUIRES when both are present" do
      # Drives emit_fn_params_only_wrapped + emit_fn_signature_metadata_wrapped.
      long_params = (1..6).map { |i| "p#{i}: SomeReallyLongTypeName" }.join(", ")
      src = <<~CLEAR
        STRUCT Counter { value: Int64 }
        FN bumpItLots(#{long_params}, c: Counter) RETURNS Void
          REQUIRES c: LOCKED
        ->
          RETURN;
        END
      CLEAR
      path = write("fn_params_meta.cht", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      # Param-list wrap fired (open paren on its own line):
      expect(out).to include("FN bumpItLots(\n")
      # Metadata block kept on its own lines:
      expect(out).to include(" RETURNS Void")
      expect(out).to include(" REQUIRES c: LOCKED")
    end
  end

  describe "method chain wrap (§3.5)" do
    it "wraps a 4+ segment chain so each .segment lands on its own line" do
      # Drives expand_method_chains -- segments.length >= 4 path.
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          r = items.first().filter().map().reduce();
          RETURN r;
        END
      CLEAR
      path = write("chain4.cht", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      expect(out).to match(/^    \.first\(\)$/)
      expect(out).to match(/^    \.filter\(\)$/)
      expect(out).to match(/^    \.map\(\)$/)
      expect(out).to match(/^    \.reduce\(\);$/)
    end

    it "drops the assignment receiver onto its own line when first chain line exceeds 80" do
      # Drives the maybe_drop_assignment_rhs branch (lines around 1149-1162):
      # current line >80 chars at the moment the chain decides to wrap, so
      # the receiver drops to its own line at +1 from the assignment.
      src = "FN main() RETURNS Int64 ->\n  some_really_long_var_name = some_really_really_really_really_long_receiver_expression_name_here.first().second().third().fourth();\n  RETURN 0;\nEND\n"
      path = write("chain_drop.cht", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      # receiver dropped to its own line:
      expect(out).to match(/some_really_long_var_name =\n/)
      expect(out).to include("some_really_really_really_really_long_receiver_expression_name_here")
    end
  end

  describe "WITH block edge cases" do
    it "tracks nested parens in capture clauses (e.g. function-call captures)" do
      # Drives depth tracking on `(` `)` inside the WITH cap-walking loop.
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN make() RETURNS C@locked -> RETURN C { v: 0 } @locked; END
        FN main() RETURNS Void ->
          WITH EXCLUSIVE make() AS x, EXCLUSIVE make() AS y {
            x.v = x.v + y.v;
          }
          RETURN;
        END
      CLEAR
      path = write("with_nested.cht", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      # Multi-cap wrap fired despite the parens:
      expect(out).to include("EXCLUSIVE make() AS x,\n")
      expect(out).to include("EXCLUSIVE make() AS y {")
    end
  end

  describe "pipeline edge cases" do
    it "emits unary minus correctly after `s>` operator" do
      # Drives EXPR_START_OPS lookup for `s>` in unary_context?.
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          v = items s> SELECT _ * -1 s> SUM _;
          RETURN v;
        END
      CLEAR
      path = write("pipe_unary.cht", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      expect(out).to include("-1")
    end

    it "respects unary context after the `->` operator" do
      # Drives unary_context? returning true via OP path (EXPR_START_OPS
      # includes `->`). Without it, the `-` would render as a binary op.
      src = <<~CLEAR
        FN neg(x: Int64) RETURNS Int64 -> RETURN -x; END
        FN main() RETURNS Void ->
          v = neg(5);
          RETURN;
        END
      CLEAR
      path = write("pipe_arrow_unary.cht", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      expect(out).to include("RETURN -x;")
    end

    it "ends a CONCURRENT stage when an `s>` operator follows" do
      # Drives line 1130 of formatter.rb: find_concurrent_stage_end returns
      # when it hits an `s>` at the same depth as the stage start. The
      # bracket-less SELECT body keeps depth=0 throughout, so the next
      # `s>` is the first thing we trip on.
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          v = items s> CONCURRENT(workers: 4, capacity: 8) SELECT _ * 2 s> SUM _;
          RETURN v;
        END
      CLEAR
      path = write("concurrent_then_pipe.cht", src)
      out, _, status = run_fmt("--no-warn", "--stdout", path)
      expect(status).to eq(0)
      expect(out).to include("CONCURRENT(workers: 4, capacity: 8)")
      expect(out).to include("s> SUM _")
    end

    it "stops `s>` arg scanning at unmatched closing bracket" do
      # Pipeline used as a call argument: `consume(items s> filter)`.
      # The scanner sees `)` at depth 0 and breaks (line 1533 of formatter.rb).
      src = <<~CLEAR
        FN consume(xs: Int64[]) RETURNS Int64 -> RETURN xs.length(); END
        FN main() RETURNS Int64 ->
          xs: Int64[] = [1_i64, 2_i64, 3_i64];
          n = consume(xs s> SELECT _);
          RETURN n;
        END
      CLEAR
      path = write("pipe_in_call.cht", src)
      out, _, status = run_fmt("--no-warn", "--stdout", path)
      expect(status).to eq(0)
      expect(out).to include("consume(xs s> SELECT _)")
    end
  end

  describe "pre-multiline source (NL preservation)" do
    it "renormalizes a FN signature whose source is already split across lines" do
      # Multi-line input -> NL tokens inside the param list. Drives the
      # NL-skipping branch in emit_fn_signature_wrapped (lines 548-549).
      # Array-type params (`Int64[]`) drive the SYM `[` / `]` depth-tracking
      # branch (lines 536-537) too.
      src = <<~CLEAR
        FN withLotsOfParams(
          p1: SomeReallyLongTypeName, p2: Int64[], p3: SomeReallyLongTypeName,
          p4: Int64[], p5: SomeReallyLongTypeName, p6: Int64[]
        )
        RETURNS Int64
        ->
          RETURN 0;
        END

        FN main() RETURNS Void ->
          RETURN;
        END
      CLEAR
      path = write("multiline_fn.cht", src)
      out, _, status = run_fmt("--no-warn", "--stdout", path)
      expect(status).to eq(0)
      # Each param on its own line.
      expect(out).to include("p1: SomeReallyLongTypeName,\n")
    end

    it "renormalizes FN with REQUIRES when source has multi-line params + bracketed types" do
      # Drives emit_fn_params_only_wrapped's NL-skip and `[`/`]` depth track
      # (lines 639-640, 651-652).
      src = <<~CLEAR
        STRUCT Counter { value: Int64 }
        FN bumpItLots(
          p1: SomeReallyLongTypeName, p2: Int64[], p3: SomeReallyLongTypeName,
          p4: Int64[], p5: SomeReallyLongTypeName, p6: Counter
        ) RETURNS Void
          REQUIRES p6: LOCKED
        ->
          RETURN;
        END
      CLEAR
      path = write("multiline_fn_meta.cht", src)
      out, _, status = run_fmt("--no-warn", "--stdout", path)
      expect(status).to eq(0)
      expect(out).to include("FN bumpItLots(\n")
      expect(out).to include(" REQUIRES p6: LOCKED")
    end

    it "renormalizes a multi-line WITH-multi-cap source" do
      # Multi-line WITH input -> NL tokens inside the cap-walk. Drives
      # the NL skip in emit_with_block (lines 906-907 of formatter.rb).
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          a = C { v: 0 } @locked;
          b = C { v: 0 } @locked;
          WITH
            EXCLUSIVE a AS x,
            EXCLUSIVE b AS y
          {
            x.v = x.v + 1;
          }
          RETURN;
        END
      CLEAR
      path = write("multiline_with.cht", src)
      out, _, status = run_fmt("--no-warn", "--stdout", path)
      expect(status).to eq(0)
      # Idempotent re-wrap.
      expect(out).to include("WITH\n    EXCLUSIVE a AS x,\n    EXCLUSIVE b AS y {")
    end
  end

  describe "private helper paths (constructed token streams)" do
    let(:fmt) { Formatter.new("") }

    def tokenize(src)
      Formatter::FormatLexer.new(src).tokenize
    end

    it "FormatLexer raises Formatter::Error on unrecognised tokens" do
      # Drives line 166 of formatter.rb. The main Lexer would catch most
      # garbage first, so we go through FormatLexer directly: backtick is
      # not a CLEAR token.
      expect {
        Formatter::FormatLexer.new("`").tokenize
      }.to raise_error(Formatter::Error, /lex error/)
    end

    it "find_fn_arrow returns nil when a `;` interrupts the signature" do
      # Drives the `{` / `}` / `;` early-return at depth 0 in find_fn_arrow.
      toks = tokenize("FN foo();\n")
      em = Formatter::Emitter.new(toks)
      fn_idx = toks.index { |t| t.type == :KEYWORD && t.raw == 'FN' }
      expect(em.send(:find_fn_arrow, toks, fn_idx)).to be_nil
    end

    it "find_fn_arrow returns nil when END appears before any `->`" do
      # Drives line 700 (return nil at END at depth 0).
      toks = tokenize("FN foo() END\n")
      em = Formatter::Emitter.new(toks)
      fn_idx = toks.index { |t| t.type == :KEYWORD && t.raw == 'FN' }
      expect(em.send(:find_fn_arrow, toks, fn_idx)).to be_nil
    end

    it "one_liner_end tracks nested IF/WHILE/FOR depth" do
      # Drives lines 744 (depth += 1 on inner IF) and 747 (depth -= 1
      # on the inner END).
      toks = tokenize("IF a THEN IF b THEN c END END")
      em = Formatter::Emitter.new(toks)
      end_idx = em.send(:one_liner_end, toks, 0)
      # Outer END is the LAST token (index = length - 1 since there's no
      # trailing NL after it).
      expect(end_idx).to eq(toks.length - 1)
      expect(toks[end_idx].raw).to eq("END")
    end

    it "emit_with_block bails when WITH has `{` but no matching `}`" do
      # Drives lines 868-869 (find_matching_close_brace returns nil).
      toks = tokenize("WITH x AS y {\n")
      em   = Formatter::Emitter.new([])
      out  = []
      next_i = em.send(:emit_with_block, out, toks, 0)
      expect(next_i).to eq(1)
      expect(out.first.raw).to eq("WITH")
    end

    it "expand_if_while_for falls through when no THEN/DO terminator is found" do
      # Drives lines 780-781 (no terminator -> emit `IF` token as-is and bail).
      em = Formatter::Emitter.new([])
      toks = tokenize("IF x END")
      out  = []
      next_i = em.send(:expand_if_while_for, out, toks, 0, toks.length - 1)
      expect(next_i).to eq(1)
      expect(out.length).to eq(1)
      expect(out.first.raw).to eq("IF")
    end

    it "emit_with_block bails when WITH is followed by no opening brace" do
      # Drives lines 863-864 (find_with_open_brace returns nil).
      em = Formatter::Emitter.new([])
      toks = tokenize("WITH x AS y\n")
      out  = []
      next_i = em.send(:emit_with_block, out, toks, 0)
      expect(next_i).to eq(1)
      expect(out.first.raw).to eq("WITH")
    end

    it "skip_matched_brackets returns end-of-input when there is no closer" do
      # Drives line 1227. Construct a `(` with no matching `)`.
      em = Formatter::Emitter.new([])
      toks = tokenize("foo(a, b")
      paren_idx = toks.index { |t| t.type == :SYM && t.raw == '(' }
      expect(em.send(:skip_matched_brackets, toks, paren_idx)).to eq(toks.length)
    end

    it "consume_on_segment returns end-of-input when no NL closes the clause" do
      # Drives line 1036.
      em = Formatter::Emitter.new([])
      toks = tokenize("ON foo")
      expect(em.send(:consume_on_segment, toks, 0)).to eq(toks.length)
    end

    it "emit_fn_signature_metadata_wrapped falls through when there is no `)`" do
      # Drives line 606. Construct a FN signature with no parens between
      # `FN name` and `->`. The else-branch emits the FN keyword + name.
      em   = Formatter::Emitter.new([])
      toks = tokenize("FN foo -> END\n")
      arrow_idx = toks.index { |t| t.type == :OP && t.raw == '->' }
      out  = []
      em.send(:emit_fn_signature_metadata_wrapped, out, toks, 0, arrow_idx, nil, nil)
      expect(out.first.raw).to eq("FN")
      expect(out.map(&:raw).join("")).to include("FN")
      expect(out.map(&:raw).join("")).to include("foo")
    end

    it "count_depth0_commas tracks nested () [] {} and ignores commas inside" do
      # Drives lines 1100-1101 (depth tracking on nested brackets in
      # CONCURRENT-style argument lists). With nesting, only the depth-0
      # commas are counted.
      em   = Formatter::Emitter.new([])
      toks = tokenize("(a, foo(b, c), d)")
      open_idx  = toks.index { |t| t.type == :SYM && t.raw == '(' }
      close_idx = toks.length - 1
      while toks[close_idx].type != :SYM || toks[close_idx].raw != ')'
        close_idx -= 1
      end
      expect(em.send(:count_depth0_commas, toks, open_idx, close_idx)).to eq(2)
    end

    it "find_concurrent_stage_end falls through to end-of-input when nothing terminates" do
      # Drives line 1134 (return j after the loop). Construct a stream of
      # tokens with no `;`, no closing bracket at depth 0, no `s>`.
      em   = Formatter::Emitter.new([])
      toks = tokenize("EACH foo bar")
      expect(em.send(:find_concurrent_stage_end, toks, 0)).to eq(toks.length)
    end

    it "last_nontrivial_in_out skips trailing phantoms back to a real token" do
      # Drives line 1184 (`j -= 1` for phantom skipping). Build an output
      # with [VAR_ID, INDENT_OPEN, NL, INDENT_CLOSE] -- the helper should
      # see VAR_ID as the last non-trivial token.
      em       = Formatter::Emitter.new([])
      var_tok  = Formatter::FormatLexer::Token.new(:VAR_ID, 'x', 0, 0)
      open_tok = Formatter::FormatLexer::Token.new(:INDENT_OPEN, '', 0, 0)
      nl_tok   = Formatter::FormatLexer::Token.new(:NL, "\n", 0, 0)
      close_tok = Formatter::FormatLexer::Token.new(:INDENT_CLOSE, '', 0, 0)
      out = [var_tok, open_tok, nl_tok, close_tok]
      result = em.send(:last_nontrivial_in_out, out)
      expect(result).to eq(var_tok)
    end

    it "find_assignment_eq_on_current_line tracks `[`/`]` depth on indexed-assignment LHS" do
      # Drives lines 1633-1634 (depth tracking on the LHS of an indexed
      # assignment like `arr[0] = ...`). Construct an `out` whose last
      # NL is at index 0 so the helper iterates the trailing tokens.
      em       = Formatter::Emitter.new([])
      nl_tok   = Formatter::FormatLexer::Token.new(:NL, "\n", 0, 0)
      arr_tok  = Formatter::FormatLexer::Token.new(:VAR_ID, 'arr', 0, 0)
      open_tok = Formatter::FormatLexer::Token.new(:SYM, '[', 0, 0)
      idx_tok  = Formatter::FormatLexer::Token.new(:NUM, '0', 0, 0)
      close_tok = Formatter::FormatLexer::Token.new(:SYM, ']', 0, 0)
      eq_tok   = Formatter::FormatLexer::Token.new(:SYM, '=', 0, 0)
      one_tok  = Formatter::FormatLexer::Token.new(:NUM, '1', 0, 0)
      out = [nl_tok, arr_tok, open_tok, idx_tok, close_tok, eq_tok, one_tok]
      eq_idx = em.send(:find_assignment_eq_on_current_line, out)
      expect(eq_idx).to eq(5)
    end

    it "in_type_context? returns false at depth 0 on assignment / comma / semicolon" do
      # Drives line 1961.
      em   = Formatter::Emitter.new([])
      # Scanning back from after the `=`: nearest separator is `=` at depth 0
      # -> not a type position.
      toks = tokenize("x = 5\n")
      expect(em.send(:in_type_context?, toks, toks.length - 1)).to be_falsey
    end

    it "in_type_context? returns false on bare expression with no `:` / `RETURNS`" do
      # Drives line 1969 (default-return false at end of scan).
      em   = Formatter::Emitter.new([])
      toks = tokenize("x")
      expect(em.send(:in_type_context?, toks, toks.length - 1)).to be_falsey
    end

    it "unary_context? returns false on an OP not in EXPR_START_OPS (e.g., `...`)" do
      # Drives line 1991. The variadic `...` is not in EXPR_START_OPS, so
      # the previous-OP check returns false. We strip :WS to mirror what
      # the formatter pipeline sees post-`reject(:WS)`.
      em   = Formatter::Emitter.new([])
      toks = tokenize("a ... b").reject { |t| t.type == :WS }
      idx  = toks.length - 1   # position of `b`
      expect(em.send(:unary_context?, toks, idx)).to be_falsey
    end
  end

  it "is idempotent on the whole transpile-tests corpus" do
    root = File.expand_path("../transpile-tests", __dir__)
    files = Dir.glob(File.join(root, "**", "*.cht"))
    expect(files).not_to be_empty

    drifts = []
    files.each do |f|
      first, _, s1 = run_fmt("--no-warn", "--stdout", f)
      next unless s1 == 0
      second_in = File.join(@tmp, "tmp_idem.cht")
      File.write(second_in, first)
      second, _, _ = run_fmt("--no-warn", "--stdout", second_in)
      drifts << f if second != first
    end
    expect(drifts).to eq([])
  end
end
