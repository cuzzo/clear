require "rspec"
require "tmpdir"
require "fileutils"
require "open3"

# Integration tests for `./clear fix` (Phase A — infrastructure).
#
# Phase A ships the data model + collector + CLI skeleton with one
# migrated finding: `MUTABLE 'x' is never reassigned`. Later phases
# will add ownership / capability / escape fixes.

CLEAR_BIN = File.expand_path("../clear", __dir__) unless defined?(CLEAR_BIN)

RSpec.describe "./clear fix", :integration do
  # Uses Open3 instead of shell redirection to a fixed /tmp filename so
  # parallel_rspec workers don't race on the same stderr file.
  def run_fix(*args)
    stdout, stderr, status = Open3.capture3(CLEAR_BIN, "fix", *args)
    [stdout, stderr, status.exitstatus]
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

  it "reports no findings on a clean file" do
    path = write("clean.cht",
      "FN main() RETURNS Int64 ->\n  x = 42;\n  RETURN x;\nEND\n")
    out, _, status = run_fix(path)
    expect(status).to eq(0)
    expect(out).to include("no fixable findings")
  end

  it "reports a MUTABLE-never-reassigned finding with an auto-fix" do
    src = "FN main() RETURNS Int64 ->\n  MUTABLE x = 42;\n  RETURN x;\nEND\n"
    path = write("m.cht", src)
    out, _, status = run_fix("--dry-run", path)
    expect(status).to eq(0)
    expect(out).to match(/MUTABLE 'x' is never reassigned/)
    expect(out).to match(/Remove MUTABLE keyword/)
  end

  it "--dry-run does not modify the source file" do
    src = "FN main() RETURNS Int64 ->\n  MUTABLE x = 42;\n  RETURN x;\nEND\n"
    path = write("m.cht", src)
    run_fix("--dry-run", path)
    expect(File.read(path)).to eq(src)
  end

  it "applies the auto-fix and writes the file when run without --dry-run" do
    src = "FN main() RETURNS Int64 ->\n  MUTABLE x = 42;\n  RETURN x;\nEND\n"
    path = write("m.cht", src)
    out, _, status = run_fix(path)
    expect(status).to eq(0)
    expect(out).to match(/applied 1 edit/)
    expect(File.read(path)).to eq(
      "FN main() RETURNS Int64 ->\n  x = 42;\n  RETURN x;\nEND\n"
    )
  end

  it "applied output still compiles" do
    src = "FN main() RETURNS Int64 ->\n  MUTABLE x = 42;\n  RETURN x;\nEND\n"
    path = write("m.cht", src)
    run_fix(path)
    build_cmd = "#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1"
    build_out = `#{build_cmd}`
    expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
  end

  it "--only=lint restricts to lint findings (still matches here)" do
    src = "FN main() RETURNS Int64 ->\n  MUTABLE x = 42;\n  RETURN x;\nEND\n"
    path = write("m.cht", src)
    out, _, _ = run_fix("--dry-run", "--only=lint", path)
    expect(out).to match(/MUTABLE/)
  end

  it "--only=ownership suppresses lint findings" do
    src = "FN main() RETURNS Int64 ->\n  MUTABLE x = 42;\n  RETURN x;\nEND\n"
    path = write("m.cht", src)
    out, _, status = run_fix("--dry-run", "--only=ownership", path)
    expect(status).to eq(0)
    expect(out).to include("no fixable findings")
  end

  describe "ownership: assign-to-immutable (Phase B)" do
    let(:src) do
      "FN main() RETURNS Int64 ->\n  x = 1;\n  x = 2;\n  RETURN x;\nEND\n"
    end

    it "reports with an auto fix that declares the binding MUTABLE" do
      path = write("im.cht", src)
      out, _, status = run_fix("--dry-run", path)
      expect(status).to eq(0)
      expect(out).to match(/Variable 'x' is immutable/)
      expect(out).to match(/Declare 'x' as MUTABLE at its binding site \(line 2\)/)
    end

    it "applies the fix and the result still compiles" do
      path = write("im.cht", src)
      out, _, status = run_fix(path)
      expect(status).to eq(0)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to eq(
        "FN main() RETURNS Int64 ->\n  MUTABLE x = 1;\n  x = 2;\n  RETURN x;\nEND\n"
      )
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end

    it "--only=ownership matches the immutable-assignment finding" do
      path = write("im.cht", src)
      out, _, _ = run_fix("--dry-run", "--only=ownership", path)
      expect(out).to match(/Variable 'x' is immutable/)
    end
  end

  describe "registry: unknown error name (category 4)" do
    let(:src) do
      <<~CLEAR
        FN bad() RETURNS !Int64 -> RAISE Transient, "oops"; RETURN 0; END

        FN main() RETURNS Int64 ->
          x = bad() OR EXIT "boom";
          RETURN x;
        CATCH LockTimout
          RETURN -1;
        END
      CLEAR
    end

    it "reports a typo with a closest-match :auto fix" do
      path = write("reg.cht", src)
      out, _, status = run_fix("--dry-run", path)
      expect(status).to eq(0)
      expect(out).to match(/LockTimout/)
      expect(out).to match(/Replace 'LockTimout' with 'LockTimeout'/)
    end

    it "applies the fix and the result still compiles" do
      path = write("reg.cht", src)
      out, _, _ = run_fix(path)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to include("CATCH LockTimeout")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end
  end

  describe "method typo (typed collections)" do
    it "suggests closest method and applies the fix" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          m: HashMap<Int64> = {"a": 1};
          RETURN m.coutn();
        END
      CLEAR
      path = write("mc.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/Unknown method 'coutn'/)
      expect(out).to match(/Replace 'coutn' with 'count'/)
      out, _, _ = run_fix(path)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to include("m.count()")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end
  end

  describe "@local never-shared" do
    it "removes the @local capability when the variable never crosses fibers" do
      src = <<~CLEAR
        STRUCT Counter {value: Int64}
        FN main() RETURNS Int64 ->
          MUTABLE c = Counter {value: 0} @local;
          c.value = c.value + 1;
          RETURN c.value;
        END
      CLEAR
      path = write("local.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/@local but never shared/)
      out, _, _ = run_fix(path)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).not_to include("@local")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end
  end

  describe "immutable arg passed as MUTABLE" do
    it "declares the caller variable MUTABLE at its binding site" do
      src = <<~CLEAR
        FN bump!(MUTABLE x: Int64) RETURNS Int64 ->
          x = x + 1;
          RETURN x;
        END

        FN main() RETURNS Int64 ->
          y = 5;
          RETURN bump!(y);
        END
      CLEAR
      path = write("ia.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/Argument 1 \('x'\) is MUTABLE/)
      expect(out).to match(/Declare 'y' as MUTABLE/)
      out, _, _ = run_fix(path)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to include("MUTABLE y = 5")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end
  end

  describe "struct-literal field typo" do
    it "suggests the closest struct field" do
      src = <<~CLEAR
        STRUCT Point {x: Int64, y: Int64}
        FN main() RETURNS Int64 ->
          p = Point{x: 1, yy: 2};
          RETURN p.x;
        END
      CLEAR
      path = write("sl.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/Struct 'Point' has no field 'yy'/)
      expect(out).to match(/Replace 'yy' with 'y'/)
    end

    it "applies the fix and the result compiles" do
      src = <<~CLEAR
        STRUCT Point {x: Int64, y: Int64}
        FN main() RETURNS Int64 ->
          p = Point{x: 1, yy: 2};
          RETURN p.x;
        END
      CLEAR
      path = write("sl.cht", src)
      out, _, _ = run_fix(path)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to include("y: 2")
      expect(File.read(path)).not_to include("yy: 2")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end
  end

  describe "use-of-moved value" do
    let(:src) do
      <<~CLEAR
        STRUCT Config {id: Float64, data: HashMap<Float64>}

        FN main() RETURNS Void ->
          a = Config {id: 1.0, data: {"x": 1.0}};
          b = a;
          c = a;
          RETURN;
        END
      CLEAR
    end

    it "reports the move line and three candidate fixes" do
      path = write("m.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/Use of moved value 'a' \(moved at line 5\)/)
      expect(out).to match(/Wrap the consuming reference with COPY at line 5/)
      expect(out).to match(/Change 'a' to `@multiowned`/)
      expect(out).to match(/Change 'a' to `@shared`/)
    end

    it "applies the COPY fix at the move site and the result compiles" do
      path = write("m.cht", src)
      out, _, _ = run_fix("--yes", path)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to include("b = (COPY a);")
      expect(File.read(path)).to include("c = a;")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end
  end

  describe "integer-overflow annotation widening" do
    it "widens a type annotation when the literal doesn't fit" do
      src = "FN main() RETURNS UInt16 ->\n  x: Byte = 1000;\n  RETURN x;\nEND\n"
      path = write("ovf.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/overflows Byte/)
      expect(out).to match(/Widen annotation `Byte` to `UInt16`/)
      out, _, _ = run_fix(path)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to include("x: UInt16 = 1000")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end
  end

  describe "static method typo" do
    it "suggests the closest static method" do
      src = "FN main() RETURNS Void ->\n  f = File::oepn(\"/tmp/x\");\n  RETURN;\nEND\n"
      path = write("sm.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/No static method 'oepn' on 'File'/)
      expect(out).to match(/Replace 'oepn' with 'open'/)
    end
  end

  describe "enum / union variant typos" do
    it "suggests the closest enum variant" do
      src = <<~CLEAR
        ENUM Shape { Circle, Square, Triangle }
        FN main() RETURNS Shape ->
          RETURN Shape.Circl;
        END
      CLEAR
      path = write("e.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/Enum 'Shape' has no variant 'Circl'/)
      expect(out).to match(/Replace 'Circl' with 'Circle'/)
    end

    it "applies the enum fix and the result compiles" do
      src = "ENUM Shape { Circle, Square }\nFN main() RETURNS Shape ->\n  RETURN Shape.Squar;\nEND\n"
      path = write("e.cht", src)
      out, _, _ = run_fix(path)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to include("Shape.Square")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end

    it "suggests the closest inline-struct union variant" do
      src = <<~CLEAR
        UNION Shape {
          Circle { radius: Float64 },
          Square { side: Float64 }
        }

        FN main() RETURNS Shape ->
          RETURN Shape.Circl{radius: 2.0};
        END
      CLEAR
      path = write("u.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/Union 'Shape' has no variant 'Circl'/)
      expect(out).to match(/Replace 'Circl' with 'Circle'/)
    end

    it "applies the union-variant fix and the result compiles" do
      src = <<~CLEAR
        UNION Shape {
          Circle { radius: Float64 },
          Square { side: Float64 }
        }

        FN main() RETURNS Shape ->
          RETURN Shape.Circl{radius: 2.0};
        END
      CLEAR
      path = write("u.cht", src)
      out, _, _ = run_fix(path)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to include("Shape.Circle{radius: 2.0}")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end
  end

  describe "operator-typo rule table" do
    it "suggests `s>` for `|>`" do
      src = "FN main() RETURNS Int64 ->\n  v = [1] s> SUM _;\n  RETURN v;\nEND\n"
      # Swap the correct operator to `|>` to simulate the typo.
      src = src.sub('s>', '|>')
      path = write("op1.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/Unknown operator `\|>`/)
      expect(out).to match(/Replace `\|>` with `s>`/)
    end

    it "suggests `->` for `=>`" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          x = IF 1 > 0 => 1 ELSE 0 END;
          RETURN x;
        END
      CLEAR
      path = write("op2.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/Unknown operator `=>`/)
      expect(out).to match(/Replace `=>` with `->`/)
    end

    it "ignores typo patterns inside strings and line comments" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          -- pipeline: |> and arrow: =>
          msg = "|> and => in a string";
          RETURN;
        END
      CLEAR
      path = write("safe.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).not_to match(/Unknown operator/)
    end

    it "apply + build round-trip fixes a `|>` typo" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          total = [1, 2, 3] |> SUM _;
          RETURN total;
        END
      CLEAR
      path = write("ops.cht", src)
      out, _, _ = run_fix(path)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to include("[1, 2, 3] s> SUM _")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end

    it "apply + build round-trip fixes an `=>` typo" do
      src = <<~CLEAR
        FN greet(n: Int64) RETURNS Int64 => RETURN n; END
        FN main() RETURNS Int64 -> RETURN greet(5); END
      CLEAR
      path = write("ops2.cht", src)
      out, _, _ = run_fix(path)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to include("RETURNS Int64 ->")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end
  end

  describe "parser syntax fixes" do
    it "inserts a missing `;` at end of previous line" do
      src = "FN main() RETURNS Int64 ->\n  x = 42\n  RETURN x;\nEND\n"
      path = write("semi.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/Expected `;` at end of line 2/)
      out, _, _ = run_fix(path)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to include("x = 42;\n")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end

    it "inserts a missing `THEN` at end of an IF condition line" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          x = 5;
          IF x > 0
            RETURN 1;
          END
          RETURN 0;
        END
      CLEAR
      path = write("then.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/Expected `THEN`/)
      out, _, _ = run_fix(path)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to include("IF x > 0 THEN")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end

    it "end-to-end: `build --fix` applies a parser fix and rebuilds" do
      src = "FN main() RETURNS Int64 ->\n  x = 42\n  RETURN x;\nEND\n"
      path = write("bfp.cht", src)
      cmd = "#{CLEAR_BIN} build --fix #{path} 2>&1"
      out = `#{cmd}`
      expect($?.exitstatus).to eq(0), out
      expect(File.read(path)).to include("x = 42;\n")
    end
  end

  describe "typo suggestions (undefined var / fn)" do
    it "suggests the closest in-scope variable" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          message = "hi";
          RETURN messaje.length();
        END
      CLEAR
      path = write("v.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/Undefined variable 'messaje'/)
      expect(out).to match(/Replace 'messaje' with 'message'/)
    end

    it "suggests the closest declared function" do
      src = <<~CLEAR
        FN doThing() RETURNS Int64 -> RETURN 42; END
        FN main() RETURNS Int64 ->
          RETURN doTing();
        END
      CLEAR
      path = write("f.cht", src)
      out, _, _ = run_fix("--dry-run", path)
      expect(out).to match(/Undefined function 'doTing'/)
      expect(out).to match(/Replace 'doTing' with 'doThing'/)
    end
  end

  describe "error accumulation (LSP-style)" do
    it "collects multiple :error findings from a single pass" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          x = 1;
          x = 2;
          y = 10;
          y = 20;
          RETURN x + y;
        END
      CLEAR
      path = write("multi.cht", src)
      out, _, status = run_fix("--dry-run", path)
      expect(status).to eq(0)
      # Both immutable-assignment findings should show, not just the first.
      expect(out.scan(/Variable '.' is immutable/).length).to eq(2)
      expect(out).to match(/Variable 'x' is immutable/)
      expect(out).to match(/Variable 'y' is immutable/)
    end

    it "applies both fixes and the result compiles" do
      src = <<~CLEAR
        FN main() RETURNS Int64 ->
          x = 1;
          x = 2;
          y = 10;
          y = 20;
          RETURN x + y;
        END
      CLEAR
      path = write("multi.cht", src)
      out, _, _ = run_fix(path)
      expect(out).to match(/applied 2 edit/)
      expect(File.read(path)).to include("MUTABLE x = 1")
      expect(File.read(path)).to include("MUTABLE y = 10")
      build_out = `#{CLEAR_BIN} build #{path} -o #{path}.bin 2>&1`
      expect($?.exitstatus).to eq(0), "build failed: #{build_out}"
    end
  end

  describe "`clear build --fix` / `clear run --fix` (Phase C)" do
    let(:src) do
      "FN main() RETURNS Int64 ->\n  x = 1;\n  x = 2;\n  RETURN x;\nEND\n"
    end

    def run_cmd(*argv)
      out, err, status = Open3.capture3(CLEAR_BIN, *argv)
      [out, err, status.exitstatus]
    end

    it "`build --fix` auto-applies ownership fix and then builds" do
      path = write("b.cht", src)
      out, err, status = run_cmd("build", "--fix", path)
      expect(status).to eq(0), "stderr:\n#{err}"
      expect(err).to match(/build failed — running `clear fix`/)
      expect(out).to match(/applied 1 edit/)
      expect(File.read(path)).to include("MUTABLE x = 1")
    end

    it "`run --fix` auto-applies ownership fix and then runs" do
      path = write("r.cht", src)
      _, err, status = run_cmd("run", "--fix", path)
      expect(status).to eq(0), "stderr:\n#{err}"
      expect(err).to match(/run failed — running `clear fix`/)
      expect(File.read(path)).to include("MUTABLE x = 1")
    end

    it "`build --fix=auto` applies interactive fixes without prompting" do
      # Any fixable finding with only :interactive candidates would need
      # --fix=auto to proceed non-interactively. Immutable-assignment is
      # :auto so this just confirms the flag parses + flows through.
      path = write("b.cht", src)
      _, _, status = run_cmd("build", "--fix=auto", path)
      expect(status).to eq(0)
    end

    it "exits non-zero when `fix` produces no edits (build still broken)" do
      # A file whose only compile error has no fixable mapping — the
      # fixer will exit 0 with no edits, but the build retry still
      # fails, so the overall command exits non-zero.
      broken = "FN main() RETURNS Void ->\n  nonexistent_function();\n  RETURN;\nEND\n"
      path   = write("broken.cht", broken)
      _, _, status = run_cmd("build", "--fix", path)
      expect(status).not_to eq(0)
    end
  end
end
