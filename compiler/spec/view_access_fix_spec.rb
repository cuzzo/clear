require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)
require_relative "../ruby/annotator/annotator" unless defined?(SemanticAnnotator)

RSpec.describe "scoped view access fixes" do
  before { FixCollector.enable! }
  after { FixCollector.disable! }

  def collect_finding(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    begin
      SemanticAnnotator.new(source_code: source).annotate!(ast)
    rescue CompilerError
      # Unsafe access diagnostics stop this annotation path after recording the
      # fix so later type consumers cannot cascade on an intentionally untyped node.
    end
    FixCollector.drain.fetch(0)
  end

  it "wraps direct foreign-pointer indexing in an interactive UNSAFE VIEW fix" do
    finding = collect_finding(<<~CLEAR)
      FN first(values: []@c Int64) RETURNS Int64 ->
        RETURN values[2];
      END
    CLEAR

    expect(finding.message).to include("Cannot index values directly")
    fix = finding.fixes.fetch(0)
    expect(fix.confidence).to eq(:interactive)
    expect(fix.edits.fetch(0).replacement).to include(
      "WITH UNSAFE VIEW values LENGTH 3 AS values_view { RETURN values_view[2]; }"
    )
  end

  it "converts WITH VIEW on a foreign pointer to UNSAFE VIEW with a safe length scaffold" do
    finding = collect_finding(<<~CLEAR)
      FN first(values: []@c Int64) RETURNS Void ->
        WITH VIEW values AS bounded {
          ASSERT bounded.length() == 0;
        }
      END
    CLEAR

    expect(finding.message).to include("WITH UNSAFE VIEW values LENGTH count")
    replacements = finding.fixes.fetch(0).edits.map(&:replacement)
    expect(replacements).to contain_exactly("UNSAFE VIEW", "LENGTH 0 ")
  end

  it "wraps direct observable indexing in WITH VIEW" do
    finding = collect_finding(<<~CLEAR)
      FN first(values: ~Int64[]@set:observable) RETURNS ?Int64 ->
        RETURN values[0];
      END
    CLEAR

    expect(finding.message).to include("Use `WITH VIEW values AS value")
    expect(finding.fixes.fetch(0).edits.fetch(0).replacement).to include(
      "WITH VIEW values AS values_view { RETURN values_view[0]; }"
    )
  end

  it "wraps direct observable scalar operations in WITH VIEW" do
    finding = collect_finding(<<~CLEAR)
      FN positive(value: ~Int64@observable) RETURNS Bool ->
        RETURN value > 0;
      END
    CLEAR

    expect(finding.message).to include("Use `WITH VIEW value AS value")
    expect(finding.fixes.fetch(0).edits.fetch(0).replacement).to include(
      "WITH VIEW value AS value_view { RETURN value_view > 0; }"
    )
  end

  it "wraps direct observable field access in WITH VIEW" do
    finding = collect_finding(<<~CLEAR)
      STRUCT Reading { value: Int64 }
      FN read(reading: ~Reading@observable) RETURNS Int64 ->
        RETURN reading.value;
      END
    CLEAR

    expect(finding.message).to include("Use `WITH VIEW reading AS value")
    expect(finding.fixes.fetch(0).edits.fetch(0).replacement).to include(
      "WITH VIEW reading AS reading_view { RETURN reading_view.value; }"
    )
  end

  it "wraps direct observable method calls in WITH VIEW" do
    finding = collect_finding(<<~CLEAR)
      FN size(values: ~Int64[]@set:observable) RETURNS Int64 ->
        RETURN values.length();
      END
    CLEAR

    expect(finding.message).to include("Use `WITH VIEW values AS value")
    expect(finding.fixes.fetch(0).edits.fetch(0).replacement).to include(
      "WITH VIEW values AS values_view { RETURN values_view.length(); }"
    )
  end
end
