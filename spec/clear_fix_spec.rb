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
end
