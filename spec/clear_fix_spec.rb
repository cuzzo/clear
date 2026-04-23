require "rspec"
require "tmpdir"
require "fileutils"

# Integration tests for `./clear fix` (Phase A — infrastructure).
#
# Phase A ships the data model + collector + CLI skeleton with one
# migrated finding: `MUTABLE 'x' is never reassigned`. Later phases
# will add ownership / capability / escape fixes.

CLEAR_BIN = File.expand_path("../clear", __dir__) unless defined?(CLEAR_BIN)

RSpec.describe "./clear fix", :integration do
  def run_fix(*args)
    cmd = "#{CLEAR_BIN} fix #{args.join(' ')}"
    stdout = `#{cmd} 2>/tmp/clear_fix_stderr`
    stderr = File.read("/tmp/clear_fix_stderr")
    File.delete("/tmp/clear_fix_stderr") rescue nil
    [stdout, stderr, $?.exitstatus]
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
      cmd = "#{CLEAR_BIN} #{argv.join(' ')}"
      out = `#{cmd} 2>/tmp/clear_cmd_stderr`
      err = File.read("/tmp/clear_cmd_stderr")
      File.delete("/tmp/clear_cmd_stderr") rescue nil
      [out, err, $?.exitstatus]
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
