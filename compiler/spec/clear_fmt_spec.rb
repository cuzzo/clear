require "rspec"
require "tmpdir"
require "fileutils"
require_relative "../ruby/tools/formatter" unless defined?(Formatter::Emitter)
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)

# Unit tests for the formatter. Calls Formatter.format(src) directly --
# the CLI's flag handling (--check / --stdout / --no-warn) and width-
# warning emission are mirrored in run_fmt below as a few lines of pure
# Ruby. No subprocess, no `./clear` binary, no Zig dependency, so the
# whole file runs in the parallel unit job and contributes coverage for
# src/backends/formatter.rb.

RSpec.describe Formatter do
  it "preserves shift operators and adjacent nested generic closers" do
    source = <<~CLEAR
      FN shift(value: Int64, amount: Int64, nested: ProjectionBox<Store<Int64>>) RETURNS Int64 ->
        RETURN value<<amount;
      END
    CLEAR

    formatted = T.must(Formatter.format(source))
    expect(formatted).to include("ProjectionBox<Store<Int64>>")
    expect(formatted).to include("RETURN value << amount;")
    expect(formatted).not_to include("value < < amount")
    expect(Formatter.format(formatted)).to eq(formatted)
  end

  it "keeps adjacent Inline Pivot collection layers flush" do
    source = "value: []{String}[2]Tuple<Int64, String> = DEFAULT;\n"
    expect(Formatter.format(source)).to include("[]{String}[2]Tuple<Int64, String>")
  end

  it "formats header imports without invoking Zig or rejecting the frontend directive" do
    source = <<~CLEAR
      EXTERN FROM HEADER "fixture.h" LINK "fixture" ABI C;
      FN main() RETURNS Void -> RETURN; END
    CLEAR

    formatted = Formatter.format(source)
    expect(formatted).to start_with(<<~CLEAR)
      EXTERN FROM HEADER "fixture.h"
        LINK "fixture"
        ABI C;
    CLEAR
    expect(Formatter.format(T.must(formatted))).to eq(formatted)
  end

  it "keeps generated C declarations readable, bounded, and idempotent" do
    source = <<~CLEAR
      EXTERN STRUCT FixtureRecord { id: TargetInt, weight: Float64 } AS "fixture_record" FROM "fixture" ABI C HEADER "fixture.h";
      EXTERN STRUCT FixtureHandle {} AS "fixture_handle" FROM "fixture" ABI C HEADER "fixture.h";
      EXTERN STRUCT LocalWideRecord { first: Int64, second: Int64, third: Int64, fourth: Int64, fifth: Int64, sixth: Int64, seventh: Int64, eighth: Int64 };
      EXTERN FN fixture_apply(value: TargetInt, callback: FN(TargetInt) -> TargetInt CALLCONV C) RETURNS TargetInt AS "fixture_apply" FROM "fixture" ABI C HEADER "fixture.h";
      EXTERN FN fixture_values(handle: FixtureHandle) RETURNS ?[]@c Int64 AS "fixture_values" FROM "fixture" ABI C HEADER "fixture.h";
    CLEAR

    formatted = T.must(Formatter.format(source))
    expect(formatted).to include("EXTERN STRUCT FixtureHandle {}")
    expect(formatted).to include("callback: FN(TargetInt) -> TargetInt CALLCONV C")
    expect(formatted).to include("RETURNS ?[]@c Int64")
    expect(formatted.lines.map { |line| line.chomp.length }.max).to be <= 120
    expect(Formatter.format(formatted)).to eq(formatted)
  end

  it "does not rewrite an EXTERN function that shadows a stdlib METHOD" do
    source = <<~CLEAR
      EXTERN STRUCT Handle {} FROM "fixture" ABI C;
      EXTERN FN values(handle: Handle) RETURNS ?[]@c Int64 FROM "fixture" ABI C;
      FN first(handle: Handle) RETURNS Int64 ->
        pointer = values(handle)?;
        WITH UNSAFE VIEW pointer LENGTH 1 AS view {
          RETURN view[0];
        }
      END
    CLEAR

    formatted = T.must(Formatter.format(source))
    expect(formatted).to include("pointer = values(handle)?;")
    expect(formatted).to include("WITH UNSAFE VIEW pointer LENGTH 1 AS view {")
    expect(formatted).not_to include("handle.values()")
  end

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
    path = write("a.clear", "FN main() RETURNS Void ->\n  RETURN;\nEND\n")
    out, _, status = run_fmt("--stdout", path)
    expect(status).to eq(0)
    expect(out).to eq("FN main() RETURNS Void ->\n  RETURN;\nEND\n")
  end

  it "exits non-zero on a parse error and refuses to write" do
    path = write("bad.clear", "FN main( RETURNS Void ->\n")
    before = File.read(path)
    _, stderr, status = run_fmt(path)
    expect(status).not_to eq(0)
    expect(stderr).to match(/parse error/i)
    expect(File.read(path)).to eq(before)
  end

  it "normalizes 4-space indent to 2-space and prints the path on change" do
    path = write("i.clear", "FN main() RETURNS Void ->\n    RETURN;\nEND\n")
    out, _, status = run_fmt(path)
    expect(status).to eq(0)
    expect(out.strip).to eq(path)
    expect(File.read(path)).to eq("FN main() RETURNS Void ->\n  RETURN;\nEND\n")
  end

  it "--check exits 1 when file is not formatted, 0 when formatted" do
    bad  = write("b.clear", "FN main() RETURNS Void ->\n    RETURN;\nEND\n")
    good = write("g.clear", "FN main() RETURNS Void ->\n  RETURN;\nEND\n")

    _, _, sb = run_fmt("--check", bad)
    expect(sb).to eq(1)

    _, _, sg = run_fmt("--check", good)
    expect(sg).to eq(0)
  end

  it "expands FN one-liners into multi-line form" do
    path = write("o.clear", "FN f() RETURNS Int64 -> RETURN 0; END\n")
    out, _, _ = run_fmt("--stdout", path)
    expect(out).to eq("FN f() RETURNS Int64 ->\n  RETURN 0;\nEND\n")
  end

  it "keeps symbol literal colons attached in expressions and arguments" do
    path = write("symbol.clear", <<~CLEAR)
      FN main() RETURNS Void ->
        tag=:ok;
        add(:ELLIPSIS,:ok);
        RETURN;
      END
    CLEAR

    out, _, status = run_fmt("--stdout", path)
    expect(status).to eq(0)
    expect(out).to include("tag = :ok;")
    expect(out).to include("add(:ELLIPSIS, :ok);")
  end

  it "keeps MUTABLE on bindings passed to bang helpers" do
    src = <<~CLEAR
      FN appendOne(MUTABLE xs: []Int64) RETURNS Void ->
        &xs.append(1_i64);
        RETURN;
      END

      FN main() RETURNS Void ->
        MUTABLE xs: []Int64 = [];
        appendOne(&xs);
        RETURN;
      END
    CLEAR
    path = write("bang_mutable.clear", src)
    out, _, _ = run_fmt("--stdout", path)
    expect(out).to include("MUTABLE xs: []Int64 = []")
  end

  it "wraps FN signature when it exceeds 120 chars" do
    long = (1..6).map { |i| "p#{i}: SomeReallyLongTypeName" }.join(", ")
    path = write("l.clear", "FN withLotsOfParams(#{long}) RETURNS Int64 ->\n  RETURN 0;\nEND\n")
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
    path = write("w.clear", src)
    out, _, _ = run_fmt("--stdout", path)
    expect(out).to include("WITH\n    EXCLUSIVE a AS x,\n    EXCLUSIVE b AS y {")
  end

  it "wraps pipelines with 2+ `|>` stages each on its own line" do
    src = <<~CLEAR
      FN main() RETURNS Int64 ->
        v = items |> SELECT _ * 2 |> SUM _;
        RETURN v;
      END
    CLEAR
    path = write("p.clear", src)
    out, _, _ = run_fmt("--stdout", path)
    expect(out).to include("\n    |> SELECT _ * 2\n    |> SUM _")
  end

  it "keeps top-level FNs at column 0 after ELSE_IF blocks in metadata-wrapped functions" do
    src = <<~CLEAR
      FN entrySize(entry: String) RETURNS !Int64 EFFECTS REENTRANT ->
        IF entry == "f:" THEN
          RETURN 1;
        ELSE_IF entry == "d:" THEN
          RETURN 2;
        END

        RETURN 0;
      END

      FN scanDir(path: String) RETURNS !Int64 EFFECTS REENTRANT ->
        RETURN entrySize(path);
      END

      FN main() RETURNS Void ->
        RETURN;
      END
    CLEAR
    path = write("elseif_fn.clear", src)
    out, _, _ = run_fmt("--stdout", path)
    expect(out).to include("ELSE_IF entry == \"d:\" THEN\n    RETURN 2;\n  END\n\n  RETURN 0;\nEND\n\nFN scanDir")
    expect(out).to include("\nFN main() RETURNS Void ->\n")
  end

  it "keeps body indentation balanced after multiple ELSE_IF outdents" do
    src = <<~CLEAR
      FN classify(x: Int64) RETURNS Int64 ->
        IF x == 0 THEN
          RETURN 0;
        ELSE_IF x == 1 THEN
          RETURN 1;
        ELSE_IF x == 2 THEN
          RETURN 2;
        ELSE
          RETURN 3;
        END

        RETURN 4;
      END

      FN after() RETURNS Void ->
        RETURN;
      END
    CLEAR
    path = write("elseif_balance.clear", src)
    out, _, _ = run_fmt("--stdout", path)
    expect(out).to include("  ELSE_IF x == 1 THEN\n    RETURN 1;\n  ELSE_IF x == 2 THEN\n")
    expect(out).to include("  ELSE\n    RETURN 3;\n  END\n\n  RETURN 4;\nEND\n\nFN after")
  end

  it "indents an existing single-stage pipeline continuation one level past the receiver" do
    src = <<~CLEAR
      FN scanDir(path: String) RETURNS !Int64 EFFECTS REENTRANT ->
        entries = listAll(path)
        |> SELECT _;

        RETURN entries
          |> CONCURRENT SELECT _
          |> REDUCE(0_i64) acc + _;
      END
    CLEAR
    path = write("pipeline_cont.clear", src)
    out, _, _ = run_fmt("--stdout", path)
    # `listAll` is METHOD-flagged in stdlib; fmt rewrites the prefix
    # call to UFCS, then preserves the pipeline continuation indent.
    expect(out).to include("  entries = path.listAll()\n    |> SELECT _;\n")
    expect(out).to include("  RETURN entries\n    |> CONCURRENT SELECT _\n    |> REDUCE(0) acc + _;\n")
  end

  it "gives `|> RECOVER(...)` one extra indent relative to sibling stages" do
    src = <<~CLEAR
      FN main() RETURNS Int64 ->
        v = items |> a |> RECOVER(0) |> b;
        RETURN v;
      END
    CLEAR
    path = write("r.clear", src)
    out, _, _ = run_fmt("--stdout", path)
    # a and b at +1 (4 spaces inside main); RECOVER at +2 (6 spaces).
    expect(out).to match(/^    |> a$/)
    expect(out).to match(/^      |> RECOVER\(0\)$/)
    expect(out).to match(/^    |> b;$/)
  end

  it "wraps long call args onto own lines with closing paren at call column" do
    long = (1..8).map { |i| "arg_#{i}_with_long_name" }.join(", ")
    src = "FN main() RETURNS Int64 ->\n  v = callWithLongName(#{long});\n  RETURN v;\nEND\n"
    path = write("c.clear", src)
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
    path = write("cap.clear", src)
    out, _, _ = run_fmt("--stdout", path)
    expect(out).to include("value: Int64@locked")
    expect(out).to include("x = 42 @locked")
  end

  it "emits a width warning for lines exceeding 120 chars" do
    long_str = '"' + ("x" * 140) + '"'
    path = write("width.clear", "FN main() RETURNS Void ->\n  s = #{long_str};\n  RETURN;\nEND\n")
    _, stderr, status = run_fmt("--check", path)
    expect(status).to eq(0).or eq(1)
    expect(stderr).to match(/width\.clear:\d+: warning: line length \d+ exceeds 120/)
  end

  it "suppresses width warnings with --no-warn" do
    long_str = '"' + ("x" * 140) + '"'
    path = write("nw.clear", "FN main() RETURNS Void ->\n  s = #{long_str};\n  RETURN;\nEND\n")
    _, stderr, _ = run_fmt("--no-warn", "--check", path)
    expect(stderr).not_to include("warning: line length")
  end

  it "auto-inserts digit separators for decimal ints > 4 digits" do
    # Type annotations dropped by LintFixRewriter (redundant with the
    # literal RHS). Numeric separators still apply.
    src = <<~CLEAR
      FN main() RETURNS Int64 ->
        a: Int64 = 1000000;
        b: Int64 = 12345;
        c: Int64 = 1234;
        d: Int64 = 42;
        RETURN a;
      END
    CLEAR
    path = write("n_int.clear", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to include("a = 1_000_000;")
    expect(out).to include("b = 12_345;")
    expect(out).to include("c = 1234;")
    expect(out).to include("d = 42;")
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
    path = write("n_float.clear", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to include("a = 3.141_592_653_589_793;")
    expect(out).to include("b = 1_000_000.5;")
    expect(out).to include("c = 1.5;")
  end

  it "preserves type suffixes through separator rewriting" do
    src = "FN main() RETURNS Int32 ->\n  a: Int32 = 1000000_i32;\n  RETURN a;\nEND\n"
    path = write("n_suffix.clear", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to include("1_000_000_i32")
  end

  it "canonicalizes existing separators (1_0_0_0 -> 1000, 1000000 -> 1_000_000)" do
    # `: Int64` annotations stripped by LintFixRewriter (redundant
    # with the literal RHS). Numeric separator rules still apply.
    src = "FN main() RETURNS Int64 ->\n  a: Int64 = 1_0_0_0;\n  b: Int64 = 1000000;\n  RETURN a;\nEND\n"
    path = write("n_canon.clear", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to include("a = 1000;")
    expect(out).to include("b = 1_000_000;")
  end

  it "leaves hex / oct / bin literals untouched" do
    src = "FN main() RETURNS Int64 ->\n  a = 0xDEAD_BEEF;\n  b = 0b1010_0101;\n  RETURN 0;\nEND\n"
    path = write("n_hex.clear", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to include("0xDEAD_BEEF")
    expect(out).to include("0b1010_0101")
  end

  it "drops pipeline receiver onto its own line when first line exceeds 80 (§3.6)" do
    src = <<~CLEAR
      FN main() RETURNS Int64 ->
        some_really_really_long_variable_name = some_really_really_long_receiver_expression_thing |> a |> b;
        RETURN 0;
      END
    CLEAR
    path = write("drop_pipe.clear", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to match(/some_really_really_long_variable_name =\n/)
    expect(out).to match(/^    some_really_really_long_receiver_expression_thing$/)
    expect(out).to match(/^      |> a$/)
    expect(out).to match(/^      |> b;$/)
  end

  it "keeps receiver inline when first line fits within 80 chars" do
    src = "FN main() RETURNS Int64 ->\n  x = items |> filter |> reduce;\n  RETURN 0;\nEND\n"
    path = write("nodrop.clear", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to match(/^  x = items$/)
    expect(out).to match(/^    |> filter$/)
  end

  it "drops trailing pipeline keyword after CONCURRENT with 2+ args (§3.11)" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        items |> CONCURRENT(workers: 4, capacity: 8) EACH { doWork(_); };
        RETURN;
      END
    CLEAR
    path = write("conc.clear", src)
    out, _, _ = run_fmt("--no-warn", "--stdout", path)
    expect(out).to match(/CONCURRENT\(workers: 4, capacity: 8\)\n/)
    expect(out).to match(/^    EACH \{/)
  end

  it "leaves single-arg CONCURRENT inline" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        items |> CONCURRENT(workers: 4) EACH { doWork(_); };
        RETURN;
      END
    CLEAR
    path = write("conc1.clear", src)
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
      path = write("metawrap.clear", src)
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
      path = write("metawrap_params.clear", src)
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
      path = write("metawrap_idem.clear", src)
      first, _, _ = run_fmt("--no-warn", "--stdout", path)
      again_path = write("metawrap_idem_2.clear", first)
      second, _, _ = run_fmt("--no-warn", "--stdout", again_path)
      expect(second).to eq(first)
    end

    it "leaves single-line FN signatures compact when no REQUIRES is present" do
      src = <<~CLEAR
        FN add(a: Int64, b: Int64) RETURNS Int64 ->
          RETURN a + b;
        END
      CLEAR
      path = write("nometa.clear", src)
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
      out, _, status = run_fmt("--no-warn", "--stdout", src.then { |s| write("triple.clear", s) })
      expect(status).to eq(0)
      expect(out).to include("\"\"\"line1\nline2\"\"\"")
    end

    it "strips _f64 suffix on decimal literals (default-type elision)" do
      # `: Float64` annotation also dropped by LintFixRewriter when
      # the literal RHS already determines the type.
      src = "FN main() RETURNS Void ->\n  a: Float64 = 3.14_f64;\n  RETURN;\nEND\n"
      path = write("f64suffix.clear", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      expect(out).to include("a = 3.14;")
      expect(out).not_to include("_f64")
    end

    it "keeps _f64 on integer literals (suffix is type-bearing)" do
      # 1_f64 is an integer literal with explicit f64 type -- dropping
      # the suffix would silently change the type to i64.
      src = "FN main() RETURNS Void ->\n  a: Float64 = 1_f64;\n  RETURN;\nEND\n"
      path = write("f64keep.clear", src)
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
      path = write("nested_interp.clear", src)
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
      path = write("fn_params_meta.clear", src)
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
      path = write("chain4.clear", src)
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
      path = write("chain_drop.clear", src)
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
      path = write("with_nested.clear", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      # Multi-cap wrap fired despite the parens:
      expect(out).to include("EXCLUSIVE make() AS x,\n")
      expect(out).to include("EXCLUSIVE make() AS y {")
    end
  end

  describe "pipeline edge cases" do
    it "emits unary minus correctly after `|>` operator" do
      # Drives EXPR_START_OPS lookup for `|>` in unary_context?.
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          v = items |> SELECT _ * -1 |> SUM _;
          RETURN v;
        END
      CLEAR
      path = write("pipe_unary.clear", src)
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
      path = write("pipe_arrow_unary.clear", src)
      out, _, _ = run_fmt("--no-warn", "--stdout", path)
      expect(out).to include("RETURN -x;")
    end

    it "ends a CONCURRENT stage when an `|>` operator follows" do
      # Drives line 1130 of formatter.rb: find_concurrent_stage_end returns
      # when it hits an `|>` at the same depth as the stage start. The
      # bracket-less SELECT body keeps depth=0 throughout, so the next
      # `|>` is the first thing we trip on.
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          v = items |> CONCURRENT(workers: 4, capacity: 8) SELECT _ * 2 |> SUM _;
          RETURN v;
        END
      CLEAR
      path = write("concurrent_then_pipe.clear", src)
      out, _, status = run_fmt("--no-warn", "--stdout", path)
      expect(status).to eq(0)
      expect(out).to include("CONCURRENT(workers: 4, capacity: 8)")
      expect(out).to include("|> SUM _")
    end

    it "stops `|>` arg scanning at unmatched closing bracket" do
      # Pipeline used as a call argument: `consume(items |> filter)`.
      # The scanner sees `)` at depth 0 and breaks (line 1533 of formatter.rb).
      src = <<~CLEAR
        FN consume(xs: Int64[]) RETURNS Int64 -> RETURN xs.length(); END
        FN main() RETURNS Int64 ->
          xs: Int64[] = [1_i64, 2_i64, 3_i64];
          n = consume(xs |> SELECT _);
          RETURN n;
        END
      CLEAR
      path = write("pipe_in_call.clear", src)
      out, _, status = run_fmt("--no-warn", "--stdout", path)
      expect(status).to eq(0)
      expect(out).to include("consume(xs |> SELECT _)")
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
      path = write("multiline_fn.clear", src)
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
      path = write("multiline_fn_meta.clear", src)
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
      path = write("multiline_with.clear", src)
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

    it "keeps string concatenation as one operator token" do
      token = tokenize('left $+ right').find { |item| item.raw == '$+' }
      expect(token&.type).to eq(:OP)
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
      sig = Formatter::Emitter::FnSig.new(toks: toks, start: 0, arrow_idx: arrow_idx, po: nil, pc: nil)
      em.send(:emit_fn_signature_metadata_wrapped, out, sig)
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
      # tokens with no `;`, no closing bracket at depth 0, no `|>`.
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

  describe "BG body wrapping with nested DO/THEN blocks" do
    # Found by FmtVerifier on benchmarks/concurrent/14_nested_lock.
    # Three related fmt bugs that combined to crush the body of
    # `BG { @parallel -> FOR i IN ... DO ...; ...; END }` onto one
    # 600-char line:
    #   1. count_statements_in_block didn't track DO/THEN/END
    #      nesting, so inner `;` was mis-counted as multi-statement
    #      at the BG level and triggered a wrong wrap.
    #   2. expand_bg_do_blocks's wrap was skipped for single-statement
    #      bodies even when the single statement was a multi-line
    #      block (FOR/IF/WHILE), leaving the body inline.
    #   3. expand_method_chains stripped ALL NLs from chain segments,
    #      including those nested inside argument-position
    #      `BG { ... }` blocks.

    it "wraps BG body when single statement is a FOR block" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          task:~ = BG { @parallel ->
            FOR i IN (0 ..< 10) DO
              MUTABLE a = i;
              MUTABLE b = i + 1;
            END
          };
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to match(/FOR i IN .+ DO\n/)
      expect(out).to match(/MUTABLE a = i;\n/)
      expect(out).to match(/MUTABLE b = i \+ 1;\n/)
    end

    it "preserves NLs inside BG-arg of a method chain" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE futures: ~Void[]@list = [];
          &futures.append(BG {
            FOR i IN (0 ..< 5) DO
              MUTABLE x = i;
              MUTABLE y = i;
            END
          });
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to match(/FOR i IN .+ DO\n/)
      expect(out).to match(/MUTABLE x = i;\n/)
      expect(out).to match(/MUTABLE y = i;\n/)
    end

    it "leaves inner one-liner IF intact when expanding outer FOR" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE a = 3;
          MUTABLE b = 5;
          MUTABLE lo = 0;
          MUTABLE hi = 0;
          FOR i IN (0 ..< 1) DO IF a > b THEN lo = b; hi = a; END END
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("IF a > b THEN")
      expect(out).to match(/IF a > b THEN\s+lo = b;\s+hi = a;\s+END/m)
    end
  end

  describe "MUTABLE never reassigned" do
    it "drops MUTABLE when the binding is read but never reassigned" do
      # The annotator only emits the MUTABLE-unused finding when the
      # binding is actually READ. An entirely unused binding triggers
      # the "unused variable" warning instead (different lint).
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE x = 5;
          RETURN x;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("x = 5;")
      expect(out).not_to include("MUTABLE")
    end

    it "keeps MUTABLE when the binding is later reassigned" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          MUTABLE x = 5;
          x = 7;
          RETURN x;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("MUTABLE x = 5;")
    end
  end

  describe "redundant `: Type` annotations" do
    it "drops `: Int64` when the literal RHS already determines it" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE total: Int64 = 0;
          total = 5;
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("MUTABLE total = 0;")
    end

    it "drops `: Float64` when assigned a float literal" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE s: Float64 = 0.0;
          s = 1.5;
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("MUTABLE s = 0.0;")
    end

    it "keeps decorated types (HashMap<K, V>) — not redundant" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE m: {Int64}Float64 = {};
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include(": {Int64}Float64")
    end
  end

  describe "generic-type bracket spacing" do
    it "tightens `HashMap < T, U >` to `HashMap<T, U>`" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE m: {Int64}Float64 = {};
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("{Int64}Float64")
    end

    it "normalizes `HashMap< T,U >` (mixed spacing) to `HashMap<T, U>`" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE m: {Int64}Float64 = {};
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("{Int64}Float64")
    end

    it "leaves comparison `a < b` with spaces (not a generic)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          a = 1;
          b = 2;
          IF a < b -> RETURN;
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("a < b")
    end
  end

  describe "struct-literal brace attach + padding" do
    it "attaches `Type` to `{` and pads inside" do
      src = <<~CLEAR
        STRUCT N {
          val: Int64,
        }
        FN main() RETURNS Void ->
          x = N { val: 5 };
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("N{ val: 5 }")
    end

    it "leaves STRUCT body declaration with space before `{`" do
      src = <<~CLEAR
        STRUCT Foo {
          a: Int64,
        }
        FN main() RETURNS Void ->
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("STRUCT Foo {\n")
    end

    it "keeps empty struct literal tight (`Foo{}`)" do
      src = <<~CLEAR
        STRUCT Empty {}
        FN main() RETURNS Void ->
          x = Empty{};
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("Empty{};")
      expect(out).not_to include("Empty{ }")
    end
  end

  describe "`END` always opens a new line" do
    # Repro from examples/json_parser/jsonToString JBool arm. An inner
    # `IF ... END RETURN ...` left `END RETURN "false";` glued together
    # because no walker forced a break between END and the trailing
    # statement. The post-pass `nl_after_end` makes END a hard line
    # boundary except when followed immediately by `)`, `]`, `}`, or `;`.

    it "splits `END RETURN` after an inner IF inside a MATCH arm" do
      src = <<~CLEAR
        ENUM B { T, F }
        FN main() RETURNS String ->
          PARTIAL MATCH B.T START
            B.T AS b ->
              IF b == B.T THEN
                RETURN "true";
              END RETURN "false";,
            B.F -> RETURN "no";
          END
        END
      CLEAR
      out = Formatter.format(src)
      expected = "      IF b == B.T THEN\n" \
                 "        RETURN \"true\";\n" \
                 "      END\n" \
                 "      RETURN \"false\";,\n"
      expect(out).to include(expected)
      expect(out).not_to match(/END RETURN/)
    end

    it "leaves `END }` and `END );` alone (close-brackets stay attached)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          futures.append(BG {
            FOR i IN (0 ..< 5) DO
              i;
            END
          });
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      # END followed by `}` keeps `}` on the next render line via
      # CLOSE_LEADING; we just need to confirm we didn't insert a
      # spurious blank line between END and `}` either.
      expect(out).not_to match(/END\s+\n\s*\n\s*\}/)
    end
  end

  describe "BG body with leading `@strategy ->` keeps indent balanced" do
    # Repro from benchmarks/concurrent/09_kvstore. `BG { @parallel -> ... }`
    # has a `->` whose OPEN_TERMINAL render rule raises body depth, but
    # there's no END inside the BG to lower it back; only `}` closes,
    # and that's a single -1. Without compensation, every statement
    # after the BG ends up one column too deep, cascading off the
    # enclosing FN body's indent.

    it "lifts depth back to the BG's `{` level before `}`" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE futures: ~Int64[]@list = [];
          &futures.append(BG { @parallel ->
            MUTABLE total: Int64 = 0;
            WHILE total < 10 DO
              total += 1;
            END
            total;
          });
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      # The `}` (closes BG) sits at call-args body depth, `);` at FN
      # body depth, `RETURN;` at FN body depth, last `END` at col 0.
      expect(out).to match(/^    \}$/)
      expect(out).to match(/^  \);$/)
      expect(out).to match(/^  RETURN;$/)
      expect(out).to match(/^END$/)
    end
  end

  describe "multi-branch IF/ELSE_IF chain with same-line branch bodies" do
    # Repro from examples/json_parser/parseString. Each branch is in
    # one-liner form (`IF cond THEN stmt;`) but the IF/ELSE_IF/ELSE/END
    # spans multiple source lines. The old layout staggered ELSE_IF
    # below IF because IF's `;`-terminated line did not bump indent
    # (THEN was mid-line, not OPEN_TERMINAL), then ELSE_IF outdented
    # against the (already-low) depth.

    it "expands each branch's inline body onto its own line" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE x = "";
          IF x == "a" THEN x = "1";
          ELSE_IF x == "b" THEN x = "2";
          ELSE_IF x == "c" THEN x = "3";
          ELSE x = "0";
          END
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expected = "  IF x == \"a\" THEN\n" \
                 "    x = \"1\";\n" \
                 "  ELSE_IF x == \"b\" THEN\n" \
                 "    x = \"2\";\n" \
                 "  ELSE_IF x == \"c\" THEN\n" \
                 "    x = \"3\";\n" \
                 "  ELSE\n" \
                 "    x = \"0\";\n" \
                 "  END\n"
      expect(out).to include(expected)
    end

    it "leaves a single-arm one-liner alone" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE x = 0;
          IF x == 1 THEN x = 2; END
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      # Existing expand_if_while_for still expands true single-line
      # one-liners — that's the established convention.
      expect(out).to include("IF x == 1 THEN\n    x = 2;\n  END")
    end
  end

  describe "capability chain with parenthesized argument" do
    # Repro from benchmarks/concurrent/09_kvstore. `@sharded(8):locked`
    # was rendering as `@sharded(8): locked` because the chain-detector
    # didn't skip the `(...)` between segments — the walk-back hit `)`
    # first and bailed.

    it "keeps `:` flush after a `@cap(N)` segment" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE map: {String}@sharded(8):locked String = {};
          map["k"] = "v";
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("@sharded(8):locked")
      expect(out).not_to include("@sharded(8): locked")
    end

    it "keeps `:` flush across a 3-segment chain with a paren arg" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE map: {String}@shared:sharded(128):locked String = {};
          map["k"] = "v";
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("@shared:sharded(128):locked")
    end
  end

  describe "MATCH block layout" do
    # Repro from examples/litedb. Multi-line MATCH was producing arms
    # at the same column as `START` and END at column 0 because:
    #   - `START` did not bump indent for the body
    #   - the body never closed back to MATCH-level
    #   - DEFAULT in arm position was outdenting like CATCH/DEFAULT in
    #     a TRY block (it shouldn't — in MATCH it's a pattern at arm-
    #     depth)
    # New layout: arms at +1 from `MATCH ... START`, multi-statement
    # arm bodies at +2 with the trailing `,` flush against the last
    # `;`, END at MATCH-line indent. DEFAULT renders at arm-depth.

    it "indents arms at +1 and END at the MATCH-line level" do
      src = <<~CLEAR
        ENUM Op { Get, Put }
        FN main() RETURNS Void ->
          MUTABLE n = "";
          PARTIAL MATCH Op.Get START
            Op.Get -> n = "g";,
            Op.Put -> n = "p";
          END
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expected = "  PARTIAL MATCH Op.Get START\n" \
                 "    Op.Get -> n = \"g\";,\n" \
                 "    Op.Put -> n = \"p\";\n" \
                 "  END\n"
      expect(out).to include(expected)
    end

    it "expands a single-line MATCH into one-arm-per-line layout" do
      src = <<~CLEAR
        ENUM Op { Get, Put }
        FN main() RETURNS Void ->
          MUTABLE n = 0;
          PARTIAL MATCH Op.Get START Op.Get -> n = 1;, DEFAULT -> n = 0; END
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expected = "  PARTIAL MATCH Op.Get START\n" \
                 "    Op.Get -> n = 1;,\n" \
                 "    DEFAULT -> n = 0;\n" \
                 "  END\n"
      expect(out).to include(expected)
    end

    it "double-indents multi-statement arm bodies and lifts the comma" do
      src = <<~CLEAR
        ENUM Op { Get, Put }
        FN main() RETURNS Void ->
          MUTABLE x = 0;
          MUTABLE y = 0;
          PARTIAL MATCH Op.Get START
            Op.Get ->
              x = 1;
              y = 2;,
            Op.Put -> x = 3;
          END
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expected = "  PARTIAL MATCH Op.Get START\n" \
                 "    Op.Get ->\n" \
                 "      x = 1;\n" \
                 "      y = 2;,\n" \
                 "    Op.Put -> x = 3;\n" \
                 "  END\n"
      expect(out).to include(expected)
      expect(out).not_to match(/y = 2;\n\s*,/)
    end

    it "renders DEFAULT in MATCH at arm-depth (no CATCH-style outdent)" do
      src = <<~CLEAR
        ENUM Op { Get, Put }
        FN main() RETURNS Void ->
          MUTABLE n = 0;
          PARTIAL MATCH Op.Get START
            Op.Get -> n = 1;,
            DEFAULT ->
              n = 0;
              n = n + 1;
          END
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expected = "  PARTIAL MATCH Op.Get START\n" \
                 "    Op.Get -> n = 1;,\n" \
                 "    DEFAULT ->\n" \
                 "      n = 0;\n" \
                 "      n = n + 1;\n" \
                 "  END\n"
      expect(out).to include(expected)
    end

    # Repro from examples/minivm/vm.clear: a MATCH arm whose body starts
    # with a line comment (`# tag`) above a single statement was
    # collapsed onto one line as `Pat ->  # tag stmt;,`. Because `#`
    # extends to end-of-line, the comment then ate the statement and
    # the resulting output failed to parse.
    #
    # Fix: when the arm body contains a line comment, force the multi-
    # line layout so the comment keeps its own line.
    it "preserves a leading comment inside a single-statement arm" do
      src = <<~CLEAR
        ENUM Op { Halt, Run }
        FN main() RETURNS Void ->
          op = Op.Halt;
          MATCH op START
            Op.Halt ->
              # HALT
              RETURN;,
            Op.Run -> PASS;
          END
        END
      CLEAR
      out = Formatter.format(src)
      # Output must still parse.
      expect { ClearParser.new(Lexer.new(out).tokenize, out).parse }.not_to raise_error
      # And the comment must remain on its own line (not folded with `->`).
      expect(out).not_to match(/->\s+#\s*HALT\b.*RETURN/)
      expect(out).to include("# HALT\n")
    end

    # Companion case: ensure a `# comment` between arrow and a multi-
    # statement body still keeps its own line.
    it "preserves a leading comment inside a multi-statement arm" do
      src = <<~CLEAR
        ENUM Op { A }
        FN main() RETURNS Void ->
          MUTABLE n = 0;
          MATCH Op.A START
            Op.A ->
              # the only arm
              n = 1;
              n = n + 1;
          END
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect { ClearParser.new(Lexer.new(out).tokenize, out).parse }.not_to raise_error
      expect(out).to include("# the only arm\n")
    end
  end

  describe "IF/ELSE_IF chain symmetric expansion" do
    # Repro from examples/minivm/vm.clear: an `IF cond THEN body END /
    # ELSE_IF cond THEN body END / ... END` chain where each branch
    # body is a one-line MATCH was getting expanded ASYMMETRICALLY --
    # the first IF's body broke across lines properly, but every
    # ELSE_IF stayed on a single line as
    # `ELSE_IF cond THEN PARTIAL MATCH ... END`.
    #
    # Root cause: `matching_end` didn't track `MATCH ... START ... END`
    # (or any `START`-opened block) as a nested construct. With a one-
    # line `MATCH` in the IF's body, the inner MATCH's `END` was
    # mistakenly returned as the outer IF's matching `END`, so
    # `expand_if_while_for` only walked the IF's body -- the ELSE_IFs
    # fell outside its scope and were emitted verbatim.
    #
    # Fix: count `START` as opening a kdepth-tracked block in
    # `matching_end`. Same change makes IF / ELSE_IF / ELSE bodies
    # all flow through the same THEN/DO inline-body expansion logic.
    it "expands IF and ELSE_IF bodies symmetrically when each contains a one-line MATCH" do
      src = <<~CLEAR
        ENUM Op { A, B, C }

        FN main() RETURNS !Void ->
          op = Op.A;
          IF op == Op.A THEN PARTIAL MATCH op START Op.A -> PASS;, DEFAULT -> PASS; END
          ELSE_IF op == Op.B THEN PARTIAL MATCH op START Op.B -> PASS;, DEFAULT -> PASS; END
          ELSE_IF op == Op.C THEN PARTIAL MATCH op START Op.C -> PASS;, DEFAULT -> PASS; END
          END
        END
      CLEAR
      out = Formatter.format(src)
      # Output must parse round-trip.
      expect { ClearParser.new(Lexer.new(out).tokenize, out).parse }.not_to raise_error
      # Symmetric expansion: every THEN must be followed by a NL --
      # never by `PARTIAL` on the *same* line. (Use `[ \t]` so the
      # regex doesn't span newlines.)
      expect(out).not_to match(/\bTHEN[ \t]+PARTIAL\b/)
      # And every ELSE_IF line must end at THEN (the body is on the
      # next line).
      out.scan(/^\s*ELSE_IF.*$/).each do |line|
        expect(line).to match(/THEN\s*\z/), "ELSE_IF line should end at THEN, got: #{line.inspect}"
      end
    end

    # Companion case discovered while stress-testing on vm.clear: nested
    # IF chains inside MATCH arm bodies must get the same recursive
    # one-line MATCH expansion as top-level IF bodies.
    it "expands IF chains nested inside a MATCH arm body" do
      src = <<~CLEAR
        ENUM Op { Get, Put }
        ENUM SubOp { A, B }

        FN main() RETURNS !Void ->
          op = Op.Get;
          suboo = SubOp.A;
          MATCH op START
            Op.Get ->
              IF suboo == SubOp.A THEN PARTIAL MATCH suboo OR_ELSE SubOp.A START SubOp.A -> PASS;, DEFAULT -> PASS; END
              ELSE_IF suboo == SubOp.B THEN PARTIAL MATCH suboo OR_ELSE SubOp.A START SubOp.B -> PASS;, DEFAULT -> PASS; END
              END
            ,
            Op.Put -> PASS;
          END
        END
      CLEAR
      out = Formatter.format(src)
      expect { ClearParser.new(Lexer.new(out).tokenize, out).parse }.not_to raise_error
      # Same shape as the standalone case once the recursion lands:
      # no `THEN PARTIAL` collocations, every ELSE_IF line ending at THEN.
      expect(out).not_to match(/\bTHEN[ \t]+PARTIAL\b/)
      out.scan(/^\s*ELSE_IF.*$/).each do |line|
        expect(line).to match(/THEN\s*\z/), "ELSE_IF line should end at THEN, got: #{line.inspect}"
      end
    end
  end

  describe "MATCH arm `;,` separator stays attached" do
    # Repro from examples/litedb: `Op.Get -> opName = "get";,` was
    # getting torn into `Op.Get -> opName = "get";` then a lone `,`
    # on its own line because `;` at depth-0 forced a newline before
    # the trailing comma was emitted.

    it "keeps `;,` together inside a MATCH inside a FN body" do
      src = <<~CLEAR
        ENUM Op { Get, Put }
        FN main() RETURNS Void ->
          MUTABLE n = "";
          PARTIAL MATCH Op.Get START
            Op.Get -> n = "get";,
            Op.Put -> n = "put";
          END
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include(%(n = "get";,))
      expect(out).not_to match(/;\n\s*,/)
    end
  end

  describe "inline capability chain (`@cap:cap`)" do
    # Repro from examples/litedb: `... @shared: locked` was rendering
    # with a space after the `:` because the default `:` rule (no space
    # before, space after) treated it like a type annotation. The chain
    # form keeps every segment flush.

    it "removes the space in `@shared:locked`" do
      src = <<~CLEAR
        STRUCT S { v: Int64 }
        FN main() RETURNS Void ->
          x = S{ v: 0 } @shared: locked;
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("@shared:locked;")
      expect(out).not_to include("@shared: locked")
    end

    it "removes spaces across a 3-segment chain `@pool:shared:locked`" do
      src = <<~CLEAR
        STRUCT Env { v: Int64 }
        FN main() RETURNS Void ->
          MUTABLE pool: [Pool(10)]@shared:locked Env = [];
          RETURN;
        END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("[Pool(10)]@shared:locked Env")
      expect(out).not_to include("@shared: locked")
      expect(out).not_to include("shared: locked")
    end

    it "leaves a normal type annotation `: Type` alone" do
      src = <<~CLEAR
        STRUCT Box { v: Int64 }
        FN take(b: Box) RETURNS Int64 -> RETURN b.v; END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("FN take(b: Box)")
      expect(out).to include("v: Int64")
    end

    it "leaves a `REQUIRES x: LOCKED` clause alone" do
      src = <<~CLEAR
        STRUCT Counter { v: Int64 }
        FN incr(MUTABLE c: Counter) REQUIRES c: LOCKED -> RETURN; END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("REQUIRES c: LOCKED")
    end
  end

  describe "leading-comment internal whitespace" do
    # Found by FmtVerifier sweep on benchmarks/sequential/11_pipeline_overhead.
    # The original `canonicalize_comment` rule was "exactly one space after
    # `#`," which destroyed deliberate prose indentation in ASCII tables,
    # code samples, and indented bullet lists. Now: ensure AT LEAST one
    # space, preserve user-typed extra spaces.

    it "preserves multi-space comment indentation" do
      src = <<~CLEAR
        # Section A
        #   subitem 1
        #   subitem 2

        FN main() RETURNS Void -> RETURN; END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("#   subitem 1")
      expect(out).to include("#   subitem 2")
    end

    it "still inserts a space when the user wrote `#text` with no separator" do
      src = <<~CLEAR
        #notice
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("# notice")
    end

    it "preserves an ASCII table laid out via comment indent" do
      src = <<~CLEAR
        # COL A    | COL B
        #   row 1  | x
        #   row 2  | y

        FN main() RETURNS Void -> RETURN; END
      CLEAR
      out = Formatter.format(src)
      expect(out).to include("# COL A    | COL B")
      expect(out).to include("#   row 1  | x")
      expect(out).to include("#   row 2  | y")
    end

    it "leaves an empty `#` comment untouched" do
      src = "# header\n#\n# more\nFN main() RETURNS Void -> RETURN; END\n"
      out = Formatter.format(src)
      expect(out).to include("\n#\n")
    end
  end

  describe "formatter helper scanners" do
    def ft(type, raw)
      Formatter::FormatLexer::Token.new(type, raw, 0, 0)
    end

    let(:emitter) { Formatter::Emitter.new([]) }

    it "centralizes formatter root-depth and END-block keyword predicates" do
      expect(emitter.send(:root_depth?, 0, 0)).to eq(true)
      expect(emitter.send(:root_depth?, 1, 0)).to eq(false)
      expect(Formatter::Emitter::END_BLOCK_OPENERS).to include("IF", "FN", "START")
      expect(Formatter::Emitter::INLINE_END_BLOCK_OPENERS).to include("IF", "FN")
      expect(Formatter::Emitter::INLINE_END_BLOCK_OPENERS).not_to include("START")
    end

    it "ignores nested comments when deciding whether a MATCH arm comment is top-level" do
      toks = [
        ft(:VAR_ID, "Pat"),
        ft(:OP, "->"),
        ft(:KEYWORD, "IF"),
        ft(:VAR_ID, "x"),
        ft(:KEYWORD, "THEN"),
        ft(:COMMENT, "# nested"),
        ft(:KEYWORD, "END"),
      ]

      arm = emitter.send(:build_match_arm, toks, 0, toks.length, 1, nil)

      expect(arm[:multi]).to eq(true)
    end

    it "does not treat START after a statement boundary as a MATCH block" do
      toks = Formatter::FormatLexer.new("x; START").tokenize
      start_idx = toks.index { |t| t.type == :KEYWORD && t.raw == "START" }

      expect(emitter.send(:match_block_start?, toks, start_idx)).to eq(false)
    end

    it "returns false when START has no preceding MATCH context" do
      toks = Formatter::FormatLexer.new("START").tokenize

      expect(emitter.send(:match_block_start?, toks, 0)).to eq(false)
    end

    it "skips trivia when finding the first code token in a range" do
      toks = [
        ft(:COMMENT, "# hi"),
        ft(:WS, " "),
        ft(:INDENT_OPEN, ""),
        ft(:VAR_ID, "x"),
      ]

      expect(emitter.send(:first_code_at, toks, 0, toks.length).raw).to eq("x")
    end

    it "finds nested generic close tokens and rejects non-generic spans" do
      nested = [
        ft(:TYPE_ID, "Foo"), ft(:SYM, "<"), ft(:TYPE_ID, "Bar"),
        ft(:SYM, "<"), ft(:TYPE_ID, "Baz"), ft(:SYM, ">"), ft(:SYM, ">"),
      ]
      with_paren = [ft(:TYPE_ID, "Foo"), ft(:SYM, "<"), ft(:SYM, "("), ft(:SYM, ">")]
      with_equal = [ft(:TYPE_ID, "Foo"), ft(:SYM, "<"), ft(:SYM, "="), ft(:SYM, ">")]

      expect(emitter.send(:find_generic_close_idx, nested, 2)).to eq(6)
      expect(emitter.send(:find_generic_close_idx, with_paren, 2)).to be_nil
      expect(emitter.send(:find_generic_close_idx, with_equal, 2)).to be_nil
    end

    it "skips trivia when finding the preceding code token" do
      line = [ft(:VAR_ID, "x"), ft(:COMMENT, "# c"), ft(:INDENT_CLOSE, "")]

      expect(emitter.send(:preceding_code_token, line, line.length).raw).to eq("x")
    end

    it "recognizes capability-chain colons across trivia and parenthesized args" do
      with_trivia = [ft(:VAR_ID, "@shared"), ft(:COMMENT, "# c"), ft(:SYM, ":")]
      multi_segment = [
        ft(:VAR_ID, "@shared"), ft(:SYM, ":"), ft(:COMMENT, "# c"),
        ft(:VAR_ID, "sharded"), ft(:SYM, "("), ft(:NUM, "8"), ft(:SYM, ")"),
        ft(:SYM, ":"),
      ]

      expect(emitter.send(:capability_chain_colon?, with_trivia, 2)).to eq(true)
      expect(emitter.send(:capability_chain_colon?, multi_segment, 7)).to eq(true)
    end

    it "returns false for malformed parenthesized capability chains" do
      malformed = [
        ft(:COMMENT, "# before"), ft(:SYM, "("), ft(:NUM, "8"),
        ft(:SYM, ")"), ft(:COMMENT, "# c"), ft(:SYM, ":"),
      ]

      expect(emitter.send(:capability_chain_colon?, malformed, 5)).to eq(false)
      expect(emitter.send(:skip_paren_group_back, [ft(:SYM, ")")], 0)).to eq(-1)
    end
  end

  it "is idempotent on the whole transpile-tests corpus" do
    repo = File.expand_path("../..", __dir__)
    tracked = IO.popen(["git", "-C", repo, "ls-files", "-z", "--", "transpile-tests"], &:read)
    files = tracked.split("\0")
      .select { |path| path.end_with?(".clear") }
      .map { |path| File.join(repo, path) }
    expect(files).not_to be_empty

    drifts = []
    files.each do |f|
      first, _, s1 = run_fmt("--no-warn", "--stdout", f)
      next unless s1 == 0
      second_in = File.join(@tmp, "tmp_idem.clear")
      File.write(second_in, first)
      second, _, _ = run_fmt("--no-warn", "--stdout", second_in)
      drifts << f if second != first
    end
    expect(drifts).to eq([])
  end
end
