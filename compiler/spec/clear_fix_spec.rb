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

  it "`autofix` is an alias for `fix`" do
    path = write("autofix.clear", "FN main() RETURNS Int64 ->\n  MUTABLE x = 42;\n  RETURN x;\nEND\n")

    out, _err, status = run_clear("autofix", path)

    expect(status).to eq(0)
    expect(out).to match(/applied 1 edit/)
    expect(File.read(path)).to eq("FN main() RETURNS Int64 ->\n  x = 42;\n  RETURN x;\nEND\n")
  end

  it "migrates every legacy Boolean glyph in one pass" do
    path = write("logical.clear", <<~CLEAR)
      FN main() RETURNS Void ->
        result = TRUE && FALSE || TRUE;
        ASSERT result;
      END
    CLEAR

    out, err, status = run_clear("autofix", "--only=syntax", path)

    expect(status).to eq(0), err
    expect(out).to include("applied 2 edit(s)")
    expect(File.read(path)).to include("TRUE AND FALSE OR TRUE")
  end

  it "inserts EXISTS for legacy IF and WHILE optional bindings" do
    path = write("exists.clear", <<~CLEAR)
      FN main(maybe: ?Int64) RETURNS Void ->
        IF maybe AS value THEN ASSERT value == 1_i64; END
        WHILE maybe AS value -> BREAK;
      END
    CLEAR

    out, err, status = run_clear("autofix", "--only=syntax", path)

    expect(status).to eq(0), err
    expect(out).to include("applied 2 edit(s)")
    fixed = File.read(path)
    expect(fixed).to include("IF maybe EXISTS AS value")
    expect(fixed).to include("WHILE maybe EXISTS AS value")

    out2, err2, status2 = run_clear("autofix", "--only=syntax", path)
    expect(status2).to eq(0), err2
    expect(out2).to include("no fixable findings")
    expect(File.read(path)).to eq(fixed)
  end

  it "rewrites legacy string + to $+ using operand types" do
    path = write("concat.clear", <<~CLEAR)
      FN main() RETURNS String ->
        left = "clear";
        right = "lang";
        RETURN left + right;
      END
    CLEAR

    out, err, status = run_clear("autofix", path)

    expect(status).to eq(0), err
    expect(out).to include("applied 1 edit")
    expect(File.read(path)).to include("left $+ right")
  end

  it "does not rewrite uppercase constructor names to in-scope variables" do
    path = write("constructor_name.clear", <<~CLEAR)
      FN main(src: String) RETURNS Void ->
        exp = 1;
        tokens = Lexer.new(src);
        RETURN;
      END
    CLEAR

    out, _err, status = run_clear("autofix", path)

    expect(status).to eq(0)
    expect(out).to include("no fixable findings")
    expect(File.read(path)).to include("Lexer.new(src)")
  end

  it "`build --fix` applies a representative parser fix and retries the build" do
    path = write("build_fix.clear", "FN main() RETURNS Int64 ->\n  x = 42\n  RETURN x;\nEND\n")

    _out, err, status = run_clear("build", "--fix", path)

    expect(status).to eq(0), "stderr:\n#{err}"
    expect(err).to match(/build failed — running `clear fix`/)
    expect(File.read(path)).to include("x = 42;\n")
  end
end
