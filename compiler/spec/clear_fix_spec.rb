require "rspec"
require "tmpdir"
require "fileutils"
require "open3"

CLEAR_BIN = File.expand_path("../../clear", __dir__) unless defined?(CLEAR_BIN)

RSpec.describe "./clear fix", :integration do
  def run_clear(*argv)
    stdout, stderr, status = Open3.capture3(CLEAR_BIN, *argv)
    [stdout, stderr, status.exitstatus]
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @tmp = dir
      example.run
    end
  end

  def write(name, content)
    path = File.join(@tmp, name)
    File.write(path, content)
    path
  end

  it "--dry-run reports findings without modifying the source file" do
    source = "FN main() RETURNS Int64 ->\n  MUTABLE x = 42;\n  RETURN x;\nEND\n"
    path = write("dry.clear", source)

    out, _err, status = run_clear("fix", "--dry-run", path)

    expect(status).to eq(0)
    expect(out).to match(/MUTABLE 'x' is never reassigned/)
    expect(out).to match(/Remove MUTABLE keyword/)
    expect(File.read(path)).to eq(source)
  end

  it "applies an auto-fix and writes the file" do
    path = write("apply.clear", "FN main() RETURNS Int64 ->\n  MUTABLE x = 42;\n  RETURN x;\nEND\n")

    out, _err, status = run_clear("fix", path)

    expect(status).to eq(0)
    expect(out).to match(/applied 1 edit/)
    expect(File.read(path)).to eq("FN main() RETURNS Int64 ->\n  x = 42;\n  RETURN x;\nEND\n")
  end

  it "`build --fix` applies a representative parser fix and retries the build" do
    path = write("build_fix.clear", "FN main() RETURNS Int64 ->\n  x = 42\n  RETURN x;\nEND\n")

    _out, err, status = run_clear("build", "--fix", path)

    expect(status).to eq(0), "stderr:\n#{err}"
    expect(err).to match(/build failed — running `clear fix`/)
    expect(File.read(path)).to include("x = 42;\n")
  end
end
