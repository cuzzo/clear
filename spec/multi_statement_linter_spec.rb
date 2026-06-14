require "rspec"
require_relative "../src/tools/multi_statement_linter" unless defined?(MultiStatementLinter)

# `MultiStatementLinter.lint!` warns when a single source line contains
# more than one `;`-terminated statement. Surfaced via FixCollector
# during `clear fix`. No auto-fix because splitting `a; b; c;` into
# three lines requires layout judgement (indent, blank lines, comment
# placement) that fmt shouldn't make automatically.

RSpec.describe "MultiStatementLinter.lint!" do
  def lint(src)
    FixCollector.enable!
    MultiStatementLinter.lint!(src)
    FixCollector.drain
  ensure
    FixCollector.disable!
  end

  it "warns on three statements on one line" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        lo_stk[sp] = lo; hi_stk[sp] = pi - 1; sp += 1;
        RETURN;
      END
    CLEAR
    findings = lint(src)
    expect(findings.size).to eq(1)
    expect(findings.first.level).to eq(:warning)
    expect(findings.first.category).to eq(:lint)
    expect(findings.first.message).to match(/multiple statements/i)
  end

  it "warns on two statements on one line" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        a = 1; b = 2;
        RETURN;
      END
    CLEAR
    expect(lint(src).size).to eq(1)
  end

  it "does NOT warn on a single statement per line" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        a = 1;
        b = 2;
        RETURN;
      END
    CLEAR
    expect(lint(src)).to be_empty
  end

  it "does NOT warn on `;` inside a struct decl on one line" do
    # Trailing `;` inside `STRUCT { ... }` is field separator, not
    # statement terminator — and depth tracking ignores them anyway
    # because they're inside `{ }`.
    src = <<~CLEAR
      STRUCT P { x: Int64, y: Int64 }
      FN main() RETURNS Void -> RETURN; END
    CLEAR
    expect(lint(src)).to be_empty
  end

  it "is a no-op when FixCollector is disabled" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        a = 1; b = 2;
        RETURN;
      END
    CLEAR
    expect { MultiStatementLinter.lint!(src) }.not_to raise_error
    expect(FixCollector.enabled?).to be false
  end

  it "ignores `;` inside string literals" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        s = "a; b; c;";
        RETURN;
      END
    CLEAR
    expect(lint(src)).to be_empty
  end

  it "ignores escaped quotes inside string literals" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        s = "a\\"; still in string;";
        RETURN;
      END
    CLEAR
    expect(lint(src)).to be_empty
  end

  it "ignores semicolons inside triple-quoted strings" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        s = """
          a; b; c;
        """;
        RETURN;
      END
    CLEAR
    expect(lint(src)).to be_empty
  end

  it "ignores `;` inside comments" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        a = 1;  # legacy: a; b; c;
        RETURN;
      END
    CLEAR
    expect(lint(src)).to be_empty
  end
end
