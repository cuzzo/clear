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
